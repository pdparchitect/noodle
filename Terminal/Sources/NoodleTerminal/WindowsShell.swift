#if os(Windows)
import Foundation
import WinSDK

/// Shell handlers can be shell extensions, which Windows asks to be given COM first, once per process.
@MainActor private let comStarted: Void = {
    _ = CoInitializeEx(nil, DWORD(bitPattern: COINIT_APARTMENTTHREADED.rawValue | COINIT_DISABLE_OLE1DDE.rawValue))
}()

/// Opens a link, or a file by its Windows path, with the app Windows chooses for it.
@MainActor func shellOpen(_ url: URL) throws {
    _ = comStarted
    let target = url.isFileURL ? url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
                               : url.absoluteString
    let result = target.withCString(encodedAs: UTF16.self) { target in
        "open".withCString(encodedAs: UTF16.self) { verb in
            ShellExecuteW(nil, verb, target, nil, nil, SW_SHOWNORMAL)
        }
    }
    // Above 32 is success; the rest are its own error numbers.
    let code = Int(bitPattern: result)
    guard code <= 32 else { return }
    let name = url.isFileURL ? url.lastPathComponent : url.absoluteString
    throw DesktopError(code == SE_ERR_NOASSOC ? "Windows has no app set to open \(name)."
                                              : "Windows could not open \(name) (error \(code)).")
}
#endif
