import Foundation
import LocalMacCore
import Security
import Darwin

/// Screen Recording resolves nested helper apps to their enclosing application.
/// Keep a signed runtime copy in the managed account, outside any enclosing app.
/// This code runs only after the standard-user/session checks in main.swift.
func standaloneDesktop(session: LocalMacSession, reexecuted: Bool) throws -> URL {
    guard let identity = LocalMacIdentity.desktop(Bundle.main.bundleIdentifier), identity.permitsAccountService else {
        throw LocalMacError("The desktop helper has an unsupported build identity.")
    }
    let manager = FileManager.default
    let home = URL(fileURLWithPath: session.account.home, isDirectory: true)
    let directory = home.appendingPathComponent("Applications", isDirectory: true)
    let destination = directory.appendingPathComponent(identity.desktopAppName + ".app", isDirectory: true)
    let source = Bundle.main.bundleURL.standardizedFileURL
    let executablePath = "Contents/MacOS/LocalMacDesktop"

    func checkedCode(_ url: URL, requirement: SecRequirement? = nil) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw LocalMacError("The account's desktop helper failed signature verification.")
        }
        return code
    }
    func hash(_ code: SecStaticCode) throws -> Data {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let value = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else {
            throw LocalMacError("Cannot verify the desktop helper's installed version.")
        }
        return value
    }
    guard directory.resolvingSymlinksInPath().path == directory.path,
          destination.resolvingSymlinksInPath().path == destination.path else {
        throw LocalMacError("The account's desktop application folder must not be a symbolic link.")
    }
    if reexecuted {
        guard source == destination else { throw LocalMacError("The desktop helper is not in its assigned account application folder.") }
        _ = try checkedCode(source)
        return destination.appendingPathComponent(executablePath)
    }
    guard source != destination else {
        throw LocalMacError("The desktop helper must start from its installed signed launcher.")
    }
    let sourceCode = try checkedCode(source)
    var requirement: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(sourceCode, [], &requirement) == errSecSuccess, let requirement else {
        throw LocalMacError("Cannot identify the signed desktop helper.")
    }
    var isDirectory: ObjCBool = false
    if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else { throw LocalMacError("The account's Applications path is not a folder.") }
    } else {
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    try LocalMacRuntimeUpdate.install(source: source, destination: destination) {
        try hash(checkedCode($0, requirement: requirement))
    }
    return destination.appendingPathComponent(executablePath)
}
