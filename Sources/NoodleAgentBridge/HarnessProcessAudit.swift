// Only the macOS Agent Host uses this.
#if canImport(Darwin)
import Darwin
import Foundation
import os

/// Records in the system log every process a bot's harness runs, so a runaway or
/// suspicious command can be traced back to its bot on Noodle and on Noodle Hub.
/// Only facts about the process are logged: executable, parent, lifetime and peak
/// memory. Command lines and output stay in the bot's transcript, which goes with
/// its conversation. Read with
/// `log show --predicate 'category == "audit"' --last 1d`.
public final class HarnessProcessAudit: @unchecked Sendable {
    public struct Process: Equatable, Sendable {
        public var parent: pid_t
        public var executable: String
        /// Highest physical footprint over the process's lifetime, in bytes.
        public var peakFootprint: UInt64

        public init(parent: pid_t, executable: String, peakFootprint: UInt64) {
            self.parent = parent
            self.executable = executable
            self.peakFootprint = peakFootprint
        }
    }

    private struct Tracked {
        var process: Process
        var started: Date
        var source: DispatchSourceProcess?
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NoodleAgentHost", category: "audit")

    private let prefix: String
    private let group: pid_t
    private let processes: (pid_t, Set<pid_t>) -> [pid_t: Process]
    private let now: () -> Date
    private let record: (String) -> Void
    private let queue = DispatchQueue(label: "Noodle.harness-process-audit")
    private var tracked: [pid_t: Tracked] = [:]
    private var timer: DispatchSourceTimer?
    private var watching = false
    private var scanPending = false
    private var finished = false

    /// `group` is the harness's process group; its commands are found there and
    /// among the children of processes already seen, which catches those that
    /// start a group of their own.
    public init(bot: String, name: String?, harness: String, group: pid_t,
                processes: @escaping (pid_t, Set<pid_t>) -> [pid_t: Process] = HarnessProcessAudit.system,
                now: @escaping () -> Date = Date.init,
                record: ((String) -> Void)? = nil) {
        let name = name.map { " name=" + $0.components(separatedBy: .newlines).joined(separator: " ") } ?? ""
        prefix = "bot=\(bot)\(name) harness=\(harness) "
        self.group = group
        self.processes = processes
        self.now = now
        self.record = record ?? { Self.logger.notice("\($0, privacy: .public)") }
    }

    /// Watches the group until `finish()`: kernel process events catch commands as
    /// they start, and a periodic pass updates peak memory.
    public func start() {
        queue.async { [self] in
            guard !finished else { return }
            watching = true
            scanNow()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.scanNow() }
            timer.resume()
            self.timer = timer
        }
    }

    public func scan() { queue.sync { scanNow() } }

    /// Records the processes that ended and stops watching.
    public func finish() {
        queue.sync {
            guard !finished else { return }
            scanNow()
            finished = true
            timer?.cancel()
            timer = nil
            tracked.values.forEach { $0.source?.cancel() }
            tracked = [:]
        }
    }

    private func scanNow() {
        guard !finished else { return }
        scanPending = false
        let current = processes(group, Set(tracked.keys))
        let time = now()
        for (pid, process) in current.sorted(by: { $0.key < $1.key }) {
            if var entry = tracked[pid] {
                if entry.process.executable != process.executable { emit("pid=\(pid) exec \(process.executable)") }
                entry.process.parent = process.parent
                entry.process.executable = process.executable
                entry.process.peakFootprint = max(entry.process.peakFootprint, process.peakFootprint)
                tracked[pid] = entry
            } else {
                emit("pid=\(pid) parent=\(process.parent) started \(process.executable)")
                tracked[pid] = Tracked(process: process, started: time, source: watch(pid))
            }
        }
        for pid in tracked.keys.sorted() where current[pid] == nil {
            guard let entry = tracked.removeValue(forKey: pid) else { continue }
            entry.source?.cancel()
            let seconds = Int(time.timeIntervalSince(entry.started))
            emit("pid=\(pid) ended \(entry.process.executable) after \(seconds)s peak \(entry.process.peakFootprint / 1_048_576) MB")
        }
    }

    private func watch(_ pid: pid_t) -> DispatchSourceProcess? {
        guard watching else { return nil }
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: [.fork, .exec, .exit], queue: queue)
        source.setEventHandler { [weak self] in self?.changed(pid) }
        source.resume()
        return source
    }

    private func changed(_ pid: pid_t) {
        // An exited process keeps its usage until its parent reaps it.
        if let peak = Self.peak(pid), var entry = tracked[pid] {
            entry.process.peakFootprint = max(entry.process.peakFootprint, peak)
            tracked[pid] = entry
        }
        guard !scanPending else { return }
        scanPending = true
        queue.async { [weak self] in self?.scanNow() }
    }

    private func emit(_ text: String) { record(prefix + text) }

    /// Live processes in the group, plus every descendant of them and of `known`.
    public static func system(group: pid_t, known: Set<pid_t>) -> [pid_t: Process] {
        var pids = Set(list(PROC_PGRP_ONLY, group)).union(known)
        var pending = Array(pids)
        while let pid = pending.popLast() {
            for child in list(PROC_PPID_ONLY, pid) where pids.insert(child).inserted { pending.append(child) }
        }
        var result: [pid_t: Process] = [:]
        for pid in pids { result[pid] = inspect(pid) }
        return result
    }

    private static func list(_ kind: Int32, _ value: pid_t) -> [pid_t] {
        let size = proc_listpids(UInt32(kind), UInt32(value), nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 16)
        let filled = pids.withUnsafeMutableBytes { proc_listpids(UInt32(kind), UInt32(value), $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func inspect(_ pid: pid_t) -> Process? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_status != UInt32(SZOMB) else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return Process(parent: pid_t(info.pbi_ppid), executable: executable, peakFootprint: peak(pid) ?? 0)
    }

    private static func peak(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? usage.ri_lifetime_max_phys_footprint : nil
    }
}
#endif
