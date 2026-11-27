import Foundation
import WinSDK

/// Finds the Windows App Runtime for an app that is not installed as a package, through the Bootstrap DLL,
/// for as long as the app runs. A packaged app has the runtime already and skips it.
enum WindowsAppRuntime {
    /// Windows App SDK 1.8, as generate-bindings.ps1 projects it.
    private static let majorMinor: UInt32 = 0x0001_0008

    private typealias Initialize = @convention(c) (UInt32, UnsafePointer<UInt16>?, PACKAGE_VERSION, Int32) -> HRESULT

    static func start() throws {
        var length: UInt32 = 0
        guard GetCurrentPackageFullName(&length, nil) == APPMODEL_ERROR_NO_PACKAGE else { return }
        guard let module = bootstrapDLL().withUnsafeFileSystemRepresentation({ String(cString: $0!) })
                .withCString(encodedAs: UTF16.self, LoadLibraryW),
              let initialize = GetProcAddress(module, "MddBootstrapInitialize2") else {
            throw RuntimeError("Microsoft.WindowsAppRuntime.Bootstrap.dll was not found. Run generate-bindings.ps1.")
        }
        // Any installed 1.8 runtime; with no tag, a stable one. 0 asks for no UI when none is installed.
        let result = unsafeBitCast(initialize, to: Initialize.self)(majorMinor, nil, PACKAGE_VERSION(), 0)
        guard result >= 0 else {
            throw RuntimeError("Windows App Runtime 1.8 is not installed (0x\(String(UInt32(bitPattern: result), radix: 16))).")
        }
    }

    /// Beside the app once it is shipped; in Bindings while it runs from .build.
    private static func bootstrapDLL() -> URL {
        let name = "Microsoft.WindowsAppRuntime.Bootstrap.dll"
        let beside = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name)
        if (try? beside.checkResourceIsReachable()) == true { return beside }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Bindings").appendingPathComponent(name)
    }

    struct RuntimeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
