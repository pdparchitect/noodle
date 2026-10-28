import Foundation
import NoodleCore

/// Asks the unsandboxed helper to start a program. There is no in-process fallback.
public enum MCPProgramHostLauncher {
    public static func spawn(_ launch: MCPProgramLaunch) throws -> MCPProgramSession {
        let connection = try MCPProgramHostConnection.connect()
        let started = try connection.launch(launch)
        let pid = started.pid
        return MCPProgramSession(
            processIdentifier: pid, input: started.input, output: started.output,
            error: started.error, secrets: launch.secrets
        ) { connection.stop(pid) }
    }
}

private final class HostReply: @unchecked Sendable {
    var pid: Int32 = 0
    var input: FileHandle?
    var output: FileHandle?
    var error: FileHandle?
    var message: String?
}

final class MCPProgramHostConnection: NSObject {
    private let connection: NSXPCConnection

    private init(connection: NSXPCConnection) {
        self.connection = connection
        super.init()
    }

    static func connect() throws -> MCPProgramHostConnection {
        guard let requirement = MCPProgramHostIdentity.requirement(for: MCPProgramHostIdentity.service) else {
            throw MCPConnectionError.message("The program host signing configuration is missing. Rebuild the signed app.")
        }
        let connection = NSXPCConnection(serviceName: MCPProgramHostIdentity.service)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: MCPProgramHostService.self)
        connection.resume()
        return MCPProgramHostConnection(connection: connection)
    }

    func launch(_ launch: MCPProgramLaunch) throws -> (pid: Int32, input: FileHandle, output: FileHandle, error: FileHandle) {
        guard let proxy = connection.remoteObjectProxy as? MCPProgramHostService else {
            throw MCPConnectionError.message("The program host is not available.")
        }
        let box = HostReply()
        let semaphore = DispatchSemaphore(value: 0)
        proxy.launch(
            executable: launch.executable.path, arguments: launch.arguments,
            environment: launch.environment, directory: launch.workingDirectory.path
        ) { pid, input, output, error, message in
            box.pid = pid
            box.input = input
            box.output = output
            box.error = error
            box.message = message
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            throw MCPConnectionError.message("The program host did not answer.")
        }
        guard box.pid > 1, let input = box.input, let output = box.output, let error = box.error else {
            throw MCPConnectionError.message(box.message ?? "The program did not start.")
        }
        return (box.pid, input, output, error)
    }

    func stop(_ processIdentifier: Int32) {
        (connection.remoteObjectProxy as? MCPProgramHostService)?.stop(processIdentifier)
    }
}
