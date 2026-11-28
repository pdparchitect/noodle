import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(AppKit)
import AppKit
#endif

/// The terminal the app draws in: raw keys, the alternate screen, its size, and everything put back on exit.
final class Console: @unchecked Sendable {
    private(set) var rows = 24
    private(set) var columns = 80

    /// What is sent on start and on stop: the alternate screen; no wrapping at the edge, so a line can never push
    /// the screen; pasted text marked as such; and the mouse wheel, reported in the extended form.
    private static let enter = "\u{1B}[?1049h\u{1B}[?7l\u{1B}[?2004h\u{1B}[?1000h\u{1B}[?1006h\u{1B}[0m\u{1B}[2J"
    private static let leave = "\u{1B}[0m\u{1B}[?1006l\u{1B}[?1000l\u{1B}[?2004l\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l"

    #if os(Windows)
    private let inputHandle = GetStdHandle(STD_INPUT_HANDLE)
    private let outputHandle = GetStdHandle(STD_OUTPUT_HANDLE)
    private var savedInput: DWORD = 0
    private var savedOutput: DWORD = 0
    private var savedCodePage: UINT = 0

    /// Whether both ends are a console, not a file or a pipe.
    static var isTerminal: Bool {
        var mode: DWORD = 0
        return GetConsoleMode(GetStdHandle(STD_INPUT_HANDLE), &mode) && GetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), &mode)
    }

    func start() {
        GetConsoleMode(inputHandle, &savedInput)
        GetConsoleMode(outputHandle, &savedOutput)
        savedCodePage = GetConsoleOutputCP()
        SetConsoleOutputCP(UINT(CP_UTF8))
        // Keys as the escape sequences other terminals send, each as it is typed, nothing echoed, and Control-C a
        // key like the others. Quick Edit would take the mouse for selecting in the old console window.
        var input = savedInput | DWORD(ENABLE_VIRTUAL_TERMINAL_INPUT) | DWORD(ENABLE_EXTENDED_FLAGS)
        input &= ~DWORD(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT | ENABLE_QUICK_EDIT_MODE)
        SetConsoleMode(inputHandle, input)
        SetConsoleMode(outputHandle, savedOutput | DWORD(ENABLE_PROCESSED_OUTPUT) | DWORD(ENABLE_VIRTUAL_TERMINAL_PROCESSING)
            | DWORD(DISABLE_NEWLINE_AUTO_RETURN))
        write(Self.enter)
        measure()
    }

    func stop() {
        write(Self.leave)
        SetConsoleMode(inputHandle, savedInput)
        SetConsoleMode(outputHandle, savedOutput)
        SetConsoleOutputCP(savedCodePage)
    }

    /// Reads the window's size again; true when it changed. Windows sends no word of a resize to a console in
    /// this mode, so the app asks now and then.
    @discardableResult func measure() -> Bool {
        var info = CONSOLE_SCREEN_BUFFER_INFO()
        guard GetConsoleScreenBufferInfo(outputHandle, &info) else { return false }
        let newRows = Int(info.srWindow.Bottom) - Int(info.srWindow.Top) + 1
        let newColumns = Int(info.srWindow.Right) - Int(info.srWindow.Left) + 1
        guard newRows > 0, newColumns > 0, newRows != rows || newColumns != columns else { return false }
        rows = newRows
        columns = newColumns
        return true
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            var written: DWORD = 0
            let ok = bytes.withUnsafeMutableBytes { buffer in
                WriteFile(outputHandle, buffer.baseAddress! + offset, DWORD(buffer.count - offset), &written, nil)
            }
            if !ok || written == 0 { return }
            offset += Int(written)
        }
    }

    /// Everything typed, as it arrives, read on a thread of its own. The console is read as UTF-16, which it
    /// gives whole whatever its code page, and handed on as UTF-8 like any other terminal's bytes.
    func input() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let thread = Thread {
                let handle = GetStdHandle(STD_INPUT_HANDLE)
                var buffer = [UInt16](repeating: 0, count: 1024)
                var held: [UInt16] = []
                while true {
                    var count: DWORD = 0
                    let ok = buffer.withUnsafeMutableBytes { ReadConsoleW(handle, $0.baseAddress, 1024, &count, nil) }
                    guard ok, count > 0 else { continuation.finish(); return }
                    var units = held + buffer[0..<Int(count)]
                    held = []
                    // Half of a pair that the next read completes.
                    if let last = units.last, UTF16.isLeadSurrogate(last) { held = [units.removeLast()] }
                    continuation.yield(Array(String(decoding: units, as: UTF16.self).utf8))
                }
            }
            thread.start()
        }
    }
    #else
    private var saved = termios()

    /// Whether both ends are a terminal, not a file or a pipe.
    static var isTerminal: Bool { isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0 }

    func start() {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write(Self.enter)
        measure()
    }

    func stop() {
        write(Self.leave)
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
    }

    /// Reads the window's size again; true when it changed.
    @discardableResult func measure() -> Bool {
        var size = winsize()
        #if canImport(Darwin)
        let result = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size)
        #else
        let result = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size)
        #endif
        guard result == 0, size.ws_row > 0, size.ws_col > 0, Int(size.ws_row) != rows || Int(size.ws_col) != columns else { return false }
        rows = Int(size.ws_row)
        columns = Int(size.ws_col)
        return true
    }

    func write(_ text: String) {
        var bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeMutableBytes { buffer in
                #if canImport(Darwin)
                Darwin.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                #else
                Glibc.write(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                #endif
            }
            if written < 0, errno == EINTR || errno == EAGAIN { continue }
            if written <= 0 { return }
            offset += written
        }
    }

    /// Everything typed, as it arrives, read on a thread of its own.
    func input() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            let thread = Thread {
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    if count <= 0 { continuation.finish(); return }
                    continuation.yield(Array(buffer[0..<count]))
                }
            }
            thread.start()
        }
    }
    #endif
}

/// Why the system could not open a link or file, as the notice says it.
struct DesktopError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// What Terminal hands the system: a link or file to open, text to copy. On a Mac through AppKit;
/// on Windows links and files open with the program Windows chooses for them, and on Linux with xdg-open;
/// copies go through the terminal itself, which works over SSH too.
@MainActor enum Desktop {
    /// How the app names the computer it runs on, in a sentence and starting one.
    #if os(macOS)
    static let computer = "this Mac", Computer = "This Mac"
    #else
    static let computer = "this computer", Computer = "This computer"
    #endif

    static func open(_ url: URL) throws {
        #if canImport(AppKit)
        guard NSWorkspace.shared.open(url) else {
            throw DesktopError("\(Computer) could not open \(url.isFileURL ? url.lastPathComponent : url.absoluteString).")
        }
        #elseif os(Windows)
        try shellOpen(url)
        #else
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        opener.arguments = ["xdg-open", url.isFileURL ? url.path : url.absoluteString]
        opener.standardInput = FileHandle.nullDevice
        opener.standardOutput = FileHandle.nullDevice
        opener.standardError = FileHandle.nullDevice
        try opener.run()
        #endif
    }

    static func copy(_ text: String, through console: Console) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        // The terminal's own clipboard request, which it passes to the clipboard of the computer it shows on.
        console.write("\u{1B}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}")
        #endif
    }
}
