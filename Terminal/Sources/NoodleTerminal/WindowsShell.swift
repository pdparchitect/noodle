#if os(Windows)
import Foundation
import WinSDK

/// Opens a link, or a file by its Windows path, with the app Windows chooses for it.
func shellOpen(_ url: URL) {
    let target = url.isFileURL ? url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
                               : url.absoluteString
    _ = target.withCString(encodedAs: UTF16.self) { target in
        "open".withCString(encodedAs: UTF16.self) { verb in
            ShellExecuteW(nil, verb, target, nil, nil, SW_SHOWNORMAL)
        }
    }
}
#endif
