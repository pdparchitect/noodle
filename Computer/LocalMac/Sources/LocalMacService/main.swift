import Foundation
import LocalMacCore
import LocalMacPrivate
import OpenDirectory
import Security
import Darwin
import MachO
import OSLog

private let executable: URL = {
    // launchd may provide a bundle-relative argv[0]. Resolve the running Mach-O
    // image instead of interpreting its command name relative to the daemon's cwd.
    var count: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &count)
    var path = [CChar](repeating: 0, count: Int(count))
    guard _NSGetExecutablePath(&path, &count) == 0 else { exit(1) }
    return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath()
}()
private let setupAppURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let appURL = setupAppURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let app = Bundle(url: appURL)
private let team = app?.object(forInfoDictionaryKey: "NoodleSigningTeam") as? String ?? ""
private let providerID = app?.bundleIdentifier ?? ""
private let identity: LocalMacIdentity = {
    guard let identity = LocalMacIdentity(providerID: providerID) else { exit(1) }
    return identity
}()
private let serviceID = identity.serviceID
private let log = Logger(subsystem: serviceID, category: "lifecycle")
private let machName = (app?.object(forInfoDictionaryKey: "NoodleComputerGroup") as? String ?? "") + ".localmac"

private func sessions() -> [[String: Any]] { NLMCopySessions() as! [[String: Any]] }
private func uid(_ record: [String: Any]) -> UInt32? { (record["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value }
private func sid(_ record: [String: Any]) -> UInt32? { (record["kCGSSessionIDKey"] as? NSNumber)?.uint32Value }
private func console() throws -> [String: Any] {
    guard let value = sessions().first(where: { $0["kCGSSessionOnConsoleKey"] as? Bool == true }), uid(value) != nil, sid(value) != nil else {
        throw LocalMacError("No active desktop session is available. Sign in before starting a Local Mac.")
    }
    return value
}

/// Generated account credentials remain in the System keychain. They are never
/// returned over XPC, passed on a command line, or included in diagnostic output.
private enum Passwords {
    static func query(_ id: UUID) throws -> [String: Any] {
        var keychain: SecKeychain?
        let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)
        guard status == errSecSuccess, let keychain else { throw LocalMacError("Cannot open the system credential store (\(status)).") }
        return [kSecClass as String: kSecClassGenericPassword, kSecUseKeychain as String: keychain,
                kSecAttrService as String: serviceID, kSecAttrAccount as String: id.uuidString]
    }
    static func get(_ id: UUID) throws -> String {
        var query = try query(id); query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecInteractionNotAllowed {
            throw LocalMacError("macOS blocked access to the saved account password. In Keychain Access → System, allow the installed LocalMacService to access \(serviceID), then retry Start. Keep the existing password and account.")
        }
        guard status == errSecSuccess, let data = value as? Data, let password = String(data: data, encoding: .utf8) else {
            throw LocalMacError("The Local Mac credential is unavailable (\(status)). Its account has been retained.")
        }
        return password
    }
    static func create(_ id: UUID) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LocalMacError("Cannot generate an account credential.") }
        let password = Data(bytes).base64EncodedString()
        var query = try query(id); query[kSecValueData as String] = Data(password.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw LocalMacError("Cannot store the Local Mac credential (\(status)).") }
        return password
    }
    static func remove(_ id: UUID) throws {
        let status = SecItemDelete(try query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LocalMacError("Cannot remove the Local Mac credential (\(status)).") }
    }
}

private final class Accounts {
    let root = identity.storageDirectory
    let node: ODNode
    init() throws {
        node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeLocalNodes))
        for path in ["/Library", "/Library/Application Support", root.deletingLastPathComponent().path, root.path] {
            var info = stat()
            if lstat(path, &info) != 0 {
                guard errno == ENOENT, mkdir(path, 0o700) == 0, lstat(path, &info) == 0 else { throw LocalMacError("Cannot prepare Local Mac service storage.") }
            }
            guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o022 == 0 else {
                throw LocalMacError("The Local Mac service storage has unsafe ownership or permissions.")
            }
            if path == root.path, info.st_mode & 0o077 != 0 { throw LocalMacError("Local Mac ownership records must be private to the service.") }
        }
    }
    func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    func existing(_ id: UUID, owner: UInt32) throws -> LocalMacAccount? {
        var info = stat()
        if lstat(url(id).path, &info) != 0 {
            guard errno == ENOENT else { throw LocalMacError("Cannot inspect the managed account record.") }
            return nil
        }
        return try load(id, owner: owner)
    }
    /// Every valid ownership record, for service-initiated maintenance only.
    /// Each record is validated against its own recorded owner.
    func all() -> [LocalMacAccount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))) else { return nil }
            do { return try load(id, owner: nil) }
            catch { log.error("Skipping Local Mac record \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"); return nil }
        }
    }
    func load(_ id: UUID, owner: UInt32?) throws -> LocalMacAccount {
        let path = url(id)
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw LocalMacError("Local Mac is not set up. Use Start in Noodle Computer.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0, info.st_size < 16_384 else {
            throw LocalMacError("The Local Mac ownership record is invalid.")
        }
        let value = try JSONDecoder().decode(LocalMacAccount.self, from: handle.readToEnd() ?? Data())
        guard value.computerID == id else { throw LocalMacError("Local Mac record has a mismatched identifier.") }
        try value.validate(owner: owner ?? value.ownerUID)
        return value
    }
    func record(_ account: LocalMacAccount) throws -> ODRecord {
        let record = try node.record(withRecordType: kODRecordTypeUsers, name: account.name, attributes: kODAttributeTypeAllAttributes)
        func one(_ attribute: String) throws -> String? { (try record.values(forAttribute: attribute) as? [String])?.first }
        guard try one(kODAttributeTypeUniqueID) == String(account.uid),
              try one(kODAttributeTypeGUID).flatMap(UUID.init(uuidString:)) == account.directoryID,
              try one(kODAttributeTypeNFSHomeDirectory) == account.home,
              try one(kODAttributeTypePrimaryGroupID) == "20" else { throw LocalMacError("The managed account identity changed. No account action was performed.") }
        if let admin = try? node.record(withRecordType: kODRecordTypeGroups, name: "admin", attributes: kODAttributeTypeAllAttributes),
           (try? admin.isMemberRecord(record)) != nil { throw LocalMacError("Local Mac must remain a standard account.") }
        return record
    }
    func prepare(_ id: UUID, owner: UInt32, display: LocalMacDisplay) throws -> LocalMacAccount {
        try display.validate()
        if let account = try existing(id, owner: owner) { return try resume(account) }
        guard owner >= 501, getpwnam(LocalMacAccount.name(for: id)) == nil,
              !FileManager.default.fileExists(atPath: "/Users/" + LocalMacAccount.name(for: id)) else { throw LocalMacError("An account or home with this name already exists. It was not adopted or changed.") }
        var newUID: UInt32 = 501
        while getpwuid(newUID) != nil { newUID += 1 }
        let account = LocalMacAccount(computerID: id, ownerUID: owner, uid: newUID, directoryID: UUID(), display: display)
        try account.validate(owner: owner)
        // Persist ownership before the first account mutation, so a failed setup
        // remains recoverable. Never automatically delete an account on failure.
        let data = try JSONEncoder().encode(account)
        guard FileManager.default.createFile(atPath: url(id).path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw LocalMacError("Cannot save Local Mac ownership.")
        }
        return try resume(account)
    }
    private func resume(_ account: LocalMacAccount) throws -> LocalMacAccount {
        let id = account.computerID, newUID = account.uid
        let exists = getpwnam(account.name) != nil
        if exists {
            let user = try record(account)
            let password = try Passwords.get(id)
            if account.provisioned { try user.verifyPassword(password); return account }
            guard !sessions().contains(where: { uid($0) == account.uid }) else { throw LocalMacError("Account setup is incomplete but a session is running. Stop it before resuming setup.") }
            do { try user.verifyPassword(password) }
            catch {
                // Only an unfinished, exact owned account may complete its
                // initial password assignment. Never reset a provisioned user.
                try user.changePassword(nil, toPassword: password)
                try user.verifyPassword(password)
            }
            try createHome(account)
            return try finish(account)
        }
        guard getpwuid(newUID) == nil else { throw LocalMacError("The reserved account UID was taken. No existing account was changed.") }
        let password: String
        do { password = try Passwords.get(id) }
        catch { password = try Passwords.create(id) }
        let attributes: [String: [String]] = [kODAttributeTypeUniqueID: [String(newUID)], kODAttributeTypePrimaryGroupID: ["20"],
            kODAttributeTypeGUID: [account.directoryID.uuidString], kODAttributeTypeNFSHomeDirectory: [account.home],
            kODAttributeTypeUserShell: ["/bin/zsh"], kODAttributeTypeFullName: ["Noodle Local Mac"],
            kODAttributeTypeComment: ["Managed by Noodle Computer: " + id.uuidString]]
        let user = try node.createRecord(withRecordType: kODRecordTypeUsers, name: account.name, attributes: attributes)
        try user.changePassword(nil, toPassword: password)
        try user.verifyPassword(password)
        try createHome(account)
        _ = try record(account)
        return try finish(account)
    }
    private func finish(_ account: LocalMacAccount) throws -> LocalMacAccount {
        var account = account; account.provisioned = true
        try JSONEncoder().encode(account).write(to: url(account.computerID), options: .atomic)
        guard chmod(url(account.computerID).path, 0o600) == 0 else { throw LocalMacError("Cannot secure the completed account record.") }
        return account
    }
    private func createHome(_ account: LocalMacAccount) throws {
        for folder in ["", "Desktop", "Documents", "Downloads", "Library", "Library/Preferences", "workspace"] {
            let path = URL(fileURLWithPath: account.home).appendingPathComponent(folder)
            var info = stat()
            if lstat(path.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == account.uid else { throw LocalMacError("A managed home folder has unexpected ownership or type.") }
            } else {
                guard errno == ENOENT, mkdir(path.path, 0o700) == 0 else { throw LocalMacError("Cannot create the managed home directory.") }
                guard chown(path.path, account.uid, 20) == 0 else { throw LocalMacError("Cannot assign the managed home directory.") }
            }
        }
    }
    func remove(_ account: LocalMacAccount) throws {
        guard !sessions().contains(where: { uid($0) == account.uid }) else { throw LocalMacError("Stop this Local Mac before deleting its account.") }
        let user: ODRecord?
        if getpwnam(account.name) != nil { user = try record(account) }
        else {
            guard getpwuid(account.uid) == nil else { throw LocalMacError("The managed UID now belongs to another account. Deletion was refused.") }
            user = nil
        }
        // Deletion is an explicit operation. Guard the exact home against path
        // substitution; never follow a symlink supplied by the managed user.
        // The descriptor-based remover verifies ownership and distinguishes an
        // absent home from permission failures. Preflight must finish before
        // deleting any files, the directory record, credentials or owner record.
        var removalError: NSError?
        guard NLMRemoveHome(account.name, account.uid, &removalError) else {
            throw LocalMacRemovalFailure(removalError ?? NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)))
        }
        try user?.delete()
        try Passwords.remove(account.computerID)
        try FileManager.default.removeItem(at: url(account.computerID))
    }
}

private struct ConsoleMetadata: Codable {
    let uid: uid_t
    let gid: gid_t
    let mode: mode_t
    let sessionID: UInt32
    let uniqueSession: String
    func matches(_ record: [String: Any]) -> Bool {
        (record["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid &&
        sid(record) == sessionID && record["CGSSessionUniqueSessionUUID"] as? String == uniqueSession
    }
}

private final class Service: NSObject, NSXPCListenerDelegate {
    let accounts: Accounts
    let queue = DispatchQueue(label: "NoodleLocalMac.lifecycle")
    var children: [UUID: Process] = [:]
    let fingerprint: Data
    let executableFileID: String
    var retirement: LocalMacServiceRetirement
    private var updateMonitor: DispatchSourceTimer?
    private var sessionMonitor: DispatchSourceTimer?
    var orphans = LocalMacOrphanSweep()
    var restarting: Bool { retirement.restarting }
    var consoleMetadata: ConsoleMetadata?
    init(accounts: Accounts) throws {
        self.accounts = accounts
        fingerprint = try LocalMacSignedCode.runningFingerprint()
        executableFileID = try LocalMacSignedCode.fileIdentity(at: executable)
        retirement = LocalMacServiceRetirement(running: fingerprint)
    }
    func monitorUpdates() {
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        monitor.setEventHandler { [weak self] in
            guard let self else { return }
            // This runs without an incoming XPC connection. Once the old code
            // is unlinked, macOS may reject that connection before serviceInfo.
            // The queue serializes this with all account operations.
            // Also finish a retirement whose reply barrier never ran because
            // XPC rejected the obsolete executable's response.
            if self.restarting || (try? self.retireIfUpdated()) == true {
                log.notice("Verified Local Mac service update; retiring the idle helper.")
                Darwin.exit(0)
            }
        }
        updateMonitor = monitor
        monitor.resume()
    }
    /// A crashed or force-quit app, or a quit that outlives its deadline, leaves
    /// the background login running with nothing attached. Start adopts such a
    /// login during the grace period; afterwards the service signs it out.
    func monitorSessions() {
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now(), repeating: 30, leeway: .seconds(5))
        monitor.setEventHandler { [weak self] in self?.releaseOrphans() }
        sessionMonitor = monitor
        monitor.resume()
    }
    /// A desktop helper exits when the app's pipe closes, but that pipe bypasses
    /// this service, so a helper can outlive a previous service instance.
    /// Count running helpers by account, not only this instance's children.
    private func desktopHelperUIDs() -> Set<UInt32> {
        var pids = [pid_t](repeating: 0, count: 16_384)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var result = Set<UInt32>()
        for pid in pids.prefix(max(0, min(count, pids.count))) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name == "LocalMacDesktop" { result.insert(info.pbi_uid) }
        }
        return result
    }
    private func releaseOrphans() {
        guard !restarting else { return }
        let owned = accounts.all()
        let live = Set(sessions().compactMap(uid))
        let signedIn = Set(owned.filter { live.contains($0.uid) }.map(\.computerID))
        let helpers = desktopHelperUIDs()
        let attached = Set(children.filter { $0.value.isRunning }.map(\.key))
            .union(owned.filter { helpers.contains($0.uid) }.map(\.computerID))
        let expired = orphans.expired(signedIn: signedIn, attached: attached)
        for account in owned where expired.contains(account.computerID) {
            do {
                try stop(account)
                log.notice("Signed out unattached Local Mac \(account.computerID.uuidString, privacy: .public).")
            } catch {
                log.error("Cannot sign out unattached Local Mac \(account.computerID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    private func retireIfUpdated() throws -> Bool {
        let requirement = "anchor apple generic and identifier \"\(serviceID)\" and certificate leaf[subject.OU] = \"\(team)\""
        let fileID = try LocalMacSignedCode.fileIdentity(at: executable)
        return try retirement.check(activeDesktop: children.values.contains(where: { $0.isRunning }),
                                    executableReplaced: fileID != executableFileID) {
            let installed = try LocalMacSignedCode.fingerprint(at: executable, requirement: requirement)
            guard fileID == (try LocalMacSignedCode.fileIdentity(at: executable)) else {
                throw LocalMacError("The Local Mac service changed during verification. Retry after the update finishes.")
            }
            return installed
        }
    }
    func requireAvailable() throws {
        guard !restarting else { throw LocalMacError("The Local Mac service is finishing an update. Retry the operation; the account has been retained.") }
    }
    func serviceInfo() throws -> LocalMacServiceInfo {
        // All lifecycle work uses this queue. Never exit during account mutation
        // or while any tracked desktop is running, including another owner's.
        _ = try retireIfUpdated()
        return LocalMacServiceInfo(fingerprint: fingerprint, restarting: restarting)
    }
    func rememberConsole(_ original: [String: Any]) throws {
        if consoleMetadata?.matches(original) == true { return }
        let path = accounts.root.appendingPathComponent("console.json")
        let fd = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_mode & 0o077 == 0, info.st_size < 4096 else { throw LocalMacError("The saved console metadata is invalid.") }
            let saved = try JSONDecoder().decode(ConsoleMetadata.self, from: handle.readToEnd() ?? Data())
            if saved.matches(original) { consoleMetadata = saved; return }
        } else if errno != ENOENT { throw LocalMacError("Cannot read the console recovery record.") }
        var info = stat()
        guard let owner = uid(original), let identifier = sid(original),
              let unique = original["CGSSessionUniqueSessionUUID"] as? String,
              lstat("/dev/console", &info) == 0, info.st_mode & S_IFMT == S_IFCHR, info.st_uid == owner else {
            throw LocalMacError("Console ownership does not match the active desktop. Startup was deferred.")
        }
        let saved = ConsoleMetadata(uid: info.st_uid, gid: info.st_gid, mode: info.st_mode & 0o7777,
                                    sessionID: identifier, uniqueSession: unique)
        try JSONEncoder().encode(saved).write(to: path, options: .atomic)
        guard chmod(path.path, 0o600) == 0 else { throw LocalMacError("Cannot secure the console recovery record.") }
        consoleMetadata = saved
    }
    func stopDesktop(_ id: UUID) throws {
        guard let process = children.removeValue(forKey: id), process.isRunning else { return }
        process.terminate()
        for _ in 0..<100 {
            if !process.isRunning { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        children[id] = process
        throw LocalMacError("The previous desktop helper is still closing. Its account has been retained.")
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let owner = connection.effectiveUserIdentifier
        guard owner >= 501 else { return false }
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"\(providerID)\" and certificate leaf[subject.OU] = \"\(team)\"")
        connection.exportedInterface = NSXPCInterface(with: LocalMacLifecycle.self)
        connection.exportedObject = Client(service: self, owner: owner)
        connection.resume()
        return true
    }
    func stop(_ account: LocalMacAccount) throws {
        if getpwnam(account.name) != nil { _ = try accounts.record(account) }
        else {
            guard getpwuid(account.uid) == nil else { throw LocalMacError("The managed UID now belongs to another account. Stop was refused.") }
            return
        }
        let current = sessions().filter { uid($0) == account.uid }
        guard !current.contains(where: { $0["kCGSSessionOnConsoleKey"] as? Bool == true }) else {
            throw LocalMacError("This account is the active desktop. Switch back before stopping it.")
        }
        try stopDesktop(account.computerID)
        let original = try console()
        try rememberConsole(original)
        defer { try? restoreConsole(original) }
        for record in current {
            guard let identifier = sid(record), NLMReleaseSession(identifier) else { throw LocalMacError("macOS could not release the background session.") }
        }
        for _ in 0..<100 {
            if !sessions().contains(where: { uid($0) == account.uid }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !sessions().contains(where: { uid($0) == account.uid }) else { throw LocalMacError("The background session is still stopping. Its account has been retained.") }
        try restoreConsole(original)
    }
    func restoreConsole(_ original: [String: Any]) throws {
        let now = try console()
        guard sid(now) == sid(original), uid(now) == uid(original) else { throw LocalMacError("The active session changed; console metadata was not modified.") }
        // loginwindow can leave /dev/console assigned to a background user.
        // Restore only this character device to the still-active console owner.
        var info = stat()
        guard lstat("/dev/console", &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { throw LocalMacError("Cannot verify the console device.") }
        if let saved = consoleMetadata, saved.matches(now) {
            if info.st_uid != saved.uid || info.st_gid != saved.gid {
                guard chown("/dev/console", saved.uid, saved.gid) == 0 else { throw LocalMacError("Cannot restore active console ownership.") }
            }
            if info.st_mode & 0o7777 != saved.mode {
                guard chmod("/dev/console", saved.mode) == 0 else { throw LocalMacError("Cannot restore active console permissions.") }
            }
        }
    }
    func verifiedDesktop() throws -> URL {
        // Installation may have replaced the old development location with an
        // alias after this service started. Launch from the current real path.
        let desktop = appURL.appendingPathComponent("Contents/Helpers/LocalMacDesktop.app/Contents/MacOS/LocalMacDesktop").resolvingSymlinksInPath()
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(desktop as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { throw LocalMacError("The desktop helper is missing.") }
        var requirement: SecRequirement?
        let text = "anchor apple generic and identifier \"\(providerID).desktop\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess else { throw LocalMacError("The desktop helper signature is invalid.") }
        return desktop
    }
    func checkDesktopAccess(_ account: LocalMacAccount, desktop: URL) throws {
        // Root can verify a bundle that the managed standard account cannot
        // traverse (for example, a dev build under the owner's Documents).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-u", account.name, "--", "/bin/test",
            "-r", desktop.path, "-a", "-x", desktop.path]
        let result = try runPreparation(process, timeoutMessage: "Checking the desktop helper's access timed out. Retry Start.")
        guard result == 0 else {
            throw LocalMacError("This account cannot access the desktop helper at the app’s current location. Install \(identity.build.appName) in /Applications, reopen it, then retry Start. The account has been retained.")
        }
    }
    private func runPreparation(_ process: Process, timeoutMessage: String) throws -> Int32 {
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard !process.isRunning else {
            process.terminate()
            throw LocalMacError(timeoutMessage)
        }
        return process.terminationStatus
    }
    func prepareOnboarding(_ account: LocalMacAccount, desktop: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n", "-u", account.name, "--", "/usr/bin/env", "HOME=" + account.home,
            "USER=" + account.name, "LOGNAME=" + account.name, desktop.path, "--prepare-onboarding",
            try JSONEncoder().encode(account).base64EncodedString()]
        let result = try runPreparation(process, timeoutMessage: "Account preparation timed out; background login was deferred.")
        guard result == 0 else { throw LocalMacError("The Local Mac desktop helper could not prepare this account (exit code \(result)). Its account and files have been retained.") }
    }
    func connect(_ account: LocalMacAccount) throws -> (LocalMacSession, FileHandle, FileHandle) {
        let user = try accounts.record(account)
        let desktop = try verifiedDesktop()
        let original = try console()
        guard uid(original) == account.ownerUID else { throw LocalMacError("Start this computer from its owner's active desktop.") }
        try checkDesktopAccess(account, desktop: desktop)
        try rememberConsole(original)
        defer { try? restoreConsole(original) }
        var current = sessions().first { uid($0) == account.uid }
        if current == nil {
            try prepareOnboarding(account, desktop: desktop)
            let password = try Passwords.get(account.computerID)
            try user.verifyPassword(password)
            var payload = try user.recordDetails(forAttributes: [kODAttributeTypeAllAttributes]) as! [String: Any]
            payload["username"] = account.name; payload["UserPasswordKey"] = password
            payload["SessionStartedBy"] = "ScreenSharing"
            let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
            var created: UInt32 = 0
            let result = NLMCreateSession(data, &created)
            guard result == 0, created != 0 else { throw LocalMacError("macOS background login failed (\(result)). The account has been retained.") }
            for _ in 0..<450 {
                let foreground = try console()
                guard sid(foreground) == sid(original), uid(foreground) == account.ownerUID else { throw LocalMacError("The active desktop changed during startup.") }
                current = sessions().first { sid($0) == created }
                if let current, (try? LocalMacSession(account: account, record: current)) != nil { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        guard let current else { throw LocalMacError("The account's background login is not ready. Retry Start; its setup has been retained.") }
        let session = try LocalMacSession(account: account, record: current)
        try restoreConsole(original)
        // The executable path is derived from this signed app, never from XPC.
        try stopDesktop(account.computerID)
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["asuser", String(account.uid), "/usr/bin/sudo", "-n", "-u", account.name, "/usr/bin/env",
            "HOME=" + account.home, "USER=" + account.name, "LOGNAME=" + account.name,
            desktop.path, try JSONEncoder().encode(session).base64EncodedString()]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        children[account.computerID] = process
        // Only descriptors are handed to the app. The root helper never parses
        // desktop operations, terminal commands, frames, or file contents.
        return (session, output.fileHandleForReading, input.fileHandleForWriting)
    }
}

private final class Client: NSObject, LocalMacLifecycle {
    let service: Service
    let owner: UInt32
    init(service: Service, owner: UInt32) { self.service = service; self.owner = owner }
    func check(reply: @escaping () -> Void) { reply() }
    func serviceInfo(reply: @escaping (Data?, String?) -> Void) {
        let connection = NSXPCConnection.current()
        service.queue.async {
            do {
                let info = try self.service.serviceInfo()
                reply(try JSONEncoder().encode(info), nil)
                if info.restarting {
                    // Drain this response, then let the existing launchd job
                    // load the replacement on demand. Its approval is untouched.
                    connection?.scheduleSendBarrierBlock { Darwin.exit(0) }
                }
            } catch { reply(nil, error.localizedDescription) }
        }
    }
    func prepare(_ id: UUID, display: Data, reply: @escaping (Data?, String?) -> Void) {
        service.queue.async {
            do {
                try self.service.requireAvailable()
                guard display.count < 1024 else { throw LocalMacError("Invalid display configuration.") }
                let config = try JSONDecoder().decode(LocalMacDisplay.self, from: display)
                let account = try self.service.accounts.prepare(id, owner: self.owner, display: config)
                reply(try JSONEncoder().encode(account), nil)
            } catch { reply(nil, error.localizedDescription) }
        }
    }
    func connect(_ id: UUID, reply: @escaping (Data?, FileHandle?, FileHandle?, String?) -> Void) {
        let connection = NSXPCConnection.current()
        service.queue.async {
            do {
                try self.service.requireAvailable()
                let account = try self.service.accounts.load(id, owner: self.owner)
                let (session, input, output) = try self.service.connect(account)
                reply(try JSONEncoder().encode(session), input, output, nil)
                connection?.scheduleSendBarrierBlock {
                    try? input.close(); try? output.close()
                }
            } catch { reply(nil, nil, nil, error.localizedDescription) }
        }
    }
    func stop(_ id: UUID, reply: @escaping (String?) -> Void) {
        service.queue.async {
            do {
                try self.service.requireAvailable()
                if let account = try self.service.accounts.existing(id, owner: self.owner) { try self.service.stop(account) }
                reply(nil)
            }
            catch { reply(error.localizedDescription) }
        }
    }
    func remove(_ id: UUID, reply: @escaping (String?) -> Void) {
        removeAccount(id) { _, error in reply(error) }
    }
    func removeAccount(_ id: UUID, reply: @escaping (Data?, String?) -> Void) {
        service.queue.async {
            do {
                try self.service.requireAvailable()
                if let account = try self.service.accounts.existing(id, owner: self.owner) {
                    // A failed desktop transport can leave a background login
                    // alive. Explicit deletion owns the stop as well; it never
                    // depends on a reply from the desktop's capture/input pipe.
                    try self.service.stop(account)
                    try self.service.accounts.remove(account)
                }
                reply(nil, nil)
            }
            catch let failure as LocalMacRemovalFailure {
                reply(try? JSONEncoder().encode(failure), failure.message(appName: identity.build.appName))
            }
            catch { reply(nil, error.localizedDescription) }
        }
    }
}

let validLayout = team.count == 10 &&
    machName == identity.group(team: team) + ".localmac" &&
    Bundle(url: setupAppURL)?.bundleIdentifier == identity.setupID
if CommandLine.arguments.dropFirst().elementsEqual(["--check-layout"]) {
    guard validLayout else { fputs("Invalid Local Mac service bundle layout.\n", stderr); exit(1) }
    do {
        let requirement = "anchor apple generic and identifier \"\(serviceID)\" and certificate leaf[subject.OU] = \"\(team)\""
        let loaded = try LocalMacSignedCode.runningFingerprint()
        guard loaded == (try LocalMacSignedCode.fingerprint(at: executable, requirement: requirement)) else {
            throw LocalMacError("The running and installed Local Mac service identities differ.")
        }
        print("Local Mac service bundle layout and update identity verified: " + providerID)
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
guard geteuid() == 0, validLayout, identity.permitsAccountService else {
    log.error("Service startup refused: uid=\(geteuid()), layout=\(validLayout), executable=\(executable.path, privacy: .public)")
    exit(1)
}
do {
    let service = try Service(accounts: Accounts())
    let listener = NSXPCListener(machServiceName: machName)
    listener.delegate = service
    listener.setConnectionCodeSigningRequirement("anchor apple generic and identifier \"\(providerID)\" and certificate leaf[subject.OU] = \"\(team)\"")
    listener.resume()
    service.monitorUpdates()
    service.monitorSessions()
    log.notice("Local Mac lifecycle service is ready.")
    RunLoop.current.run()
} catch { log.error("Local Mac service startup failed: \(error.localizedDescription, privacy: .public)"); exit(1) }
