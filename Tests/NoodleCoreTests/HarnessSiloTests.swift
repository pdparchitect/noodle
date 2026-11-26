import XCTest
@testable import NoodleCore

final class HarnessSiloTests: XCTestCase {
    private func workspace() throws -> (root: URL, workspace: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let repository = WorkspaceRepository(rootURL: root)
        let agent = try repository.createAgent(named: "Silo").agent
        return (root, repository.directory(for: agent))
    }

    private func ruby(_ script: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["--disable-gems", "-e", script] + arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    /// Outside the silo nothing stops a harness reporting home, so each is told not to, in the words it reads.
    func testEveryHarnessIsToldNotToReportUsage() {
        for provider in HarnessProvider.allCases where provider != .apple {
            XCTAssertEqual(provider.reportingOffEnvironment["DO_NOT_TRACK"], "1", provider.rawValue)
        }
        XCTAssertEqual(HarnessProvider.apple.reportingOffEnvironment, [:])
        XCTAssertEqual(HarnessProvider.claudeCode.reportingOffEnvironment["DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(HarnessProvider.claudeCode.reportingOffEnvironment["DISABLE_ERROR_REPORTING"], "1")
        XCTAssertEqual(HarnessProvider.grokBuild.reportingOffEnvironment["DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(HarnessProvider.grokBuild.reportingOffEnvironment["DISABLE_ERROR_REPORTING"], "1")
        XCTAssertEqual(HarnessProvider.muse.reportingOffEnvironment["TBH_DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(HarnessProvider.copilot.reportingOffEnvironment["COPILOT_TELEMETRY_DISABLED"], "true")
        let codex = CodexLaunch.appServerArguments()
        XCTAssertEqual(Array(codex.prefix(3)), ["app-server", "-c", "analytics.enabled=false"])
    }

    /// Two loopback servers run outside Seatbelt. A siloed process may reach only the one
    /// standing in for the Agent Host's proxy, and cannot look names up itself.
    func testSiloedHarnessesReachOnlyTheProxyPort() throws {
        let (root, workspace) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = #"""
        require 'socket'
        require 'timeout'
        proxy = TCPServer.new('127.0.0.1', 0)
        other = TCPServer.new('127.0.0.1', 0)
        policy = ARGV[0].gsub('EGRESS_PORT', proxy.addr[1].to_s)
        workers = [proxy, other].map { |server| Thread.new { loop { c = server.accept; c.write('reached'); c.close } } }
        child = <<~RUBY
          require 'socket'
          require 'timeout'
          Timeout.timeout(5) do
            raise 'proxy port unreachable' unless TCPSocket.new('127.0.0.1', ARGV[0].to_i).read == 'reached'
            begin
              TCPSocket.new('127.0.0.1', ARGV[1].to_i)
              raise 'another loopback port was reachable'
            rescue Errno::EPERM, Errno::EACCES, Errno::ECONNREFUSED
            end
            begin
              Addrinfo.getaddrinfo('example.com', 443)
              raise 'name lookup was possible'
            rescue SocketError
            end
          end
          puts 'siloed'
        RUBY
        pid = nil
        begin
          Timeout.timeout(15) do
            pid = Process.spawn('/usr/bin/sandbox-exec', '-p', policy, '/usr/bin/ruby', '--disable-gems', '-e', child,
                                proxy.addr[1].to_s, other.addr[1].to_s)
            Process.wait(pid)
            status = $?.exitstatus || 1
            pid = nil
            exit(status)
          end
        ensure
          Process.kill('KILL', pid) rescue nil if pid
          workers.each(&:kill)
        end
        """#
        // The real port is only known to the script, so the policy carries a placeholder number first.
        let placeholder: UInt16 = 65_000
        for provider: HarnessProvider in [.codex, .claudeCode, .fx, .grokBuild, .muse, .openCode, .antigravity, .copilot, .devin] {
            // OpenCode's and Antigravity's own executables reach their local servers on any loopback port,
            // so ruby stands in for one of their tools here, not for the harness.
            let harness = URL(fileURLWithPath: [.openCode, .antigravity].contains(provider) ? "/usr/bin/true" : "/usr/bin/ruby")
            let policy = provider == .codex
                ? RestrictedAgentSandbox.profile(workspace: workspace, repository: root, codexHome: workspace,
                    executableDirectory: URL(fileURLWithPath: "/usr/bin"), application: workspace, temporary: workspace,
                    egressPort: placeholder)
                : try RestrictedAgentSandbox.profile(provider: provider, workspace: workspace, repository: root,
                    home: root, executable: harness, application: workspace, temporary: workspace,
                    egressPort: placeholder)
            XCTAssertFalse(policy.contains("mDNSResponder"), "\(provider)")
            let result = try ruby(script, [policy.replacingOccurrences(of: "\(placeholder)", with: "EGRESS_PORT")])
            XCTAssertEqual(result.status, 0, "\(provider): \(result.output)")
            XCTAssertTrue(result.output.contains("siloed"), "\(provider): \(result.output)")
        }
    }

    func testSiloedAppleReachesTheNetworkOnlyThroughTheProxy() {
        let application = URL(fileURLWithPath: "/Applications/Noodle.app")
        let client = URL(fileURLWithPath: "/Applications/Noodle.app/Contents/Helpers/NoodleAppleAgent")
        let open = AppleAgentSandbox.profile(application: application, remoteClient: client)
        let siloed = AppleAgentSandbox.profile(application: application, remoteClient: client, egressPort: 41_000)
        XCTAssertTrue(open.contains("(allow network-outbound (process-path"))
        XCTAssertFalse(siloed.contains("(allow network-outbound (process-path"))
        XCTAssertTrue(siloed.contains("(remote ip \"localhost:41000\")"))
    }

    /// A CONNECT to an allowed address is tunnelled; anything else is refused before any connection is made.
    func testProxyTunnelsOnlyAllowedAddresses() throws {
        let script = #"""
        require 'socket'
        require 'timeout'
        target = TCPServer.new('127.0.0.1', Integer(ARGV[1]))
        Thread.new { loop { c = target.accept; c.write(c.readpartial(64).upcase); c.close } }
        Timeout.timeout(10) do
          tunnel = TCPSocket.new('127.0.0.1', Integer(ARGV[0]))
          tunnel.write("CONNECT 127.0.0.1:#{ARGV[1]} HTTP/1.1\r\nHost: 127.0.0.1:#{ARGV[1]}\r\n\r\n")
          raise 'allowed CONNECT failed' unless tunnel.gets.start_with?('HTTP/1.1 200')
          tunnel.gets
          tunnel.write('ping')
          raise 'tunnel did not carry data' unless tunnel.read == 'PING'
          refused = TCPSocket.new('127.0.0.1', Integer(ARGV[0]))
          refused.write("CONNECT example.com:443 HTTP/1.1\r\n\r\n")
          raise 'refused CONNECT was answered wrongly' unless refused.gets.start_with?('HTTP/1.1 403')
          plain = TCPSocket.new('127.0.0.1', Integer(ARGV[0]))
          plain.write("GET http://127.0.0.1:#{ARGV[1]}/ HTTP/1.1\r\n\r\n")
          raise 'plain HTTP was forwarded' unless plain.gets.start_with?('HTTP/1.1 403')
        end
        puts 'tunnelled'
        """#
        let probe = try TCPProbePort.free()
        let requests = RequestLog()
        let proxy = try HarnessEgressProxy(allowed: ["127.0.0.1:\(probe)"]) { requests.add($0, $1) }
        defer { proxy.stop() }
        let result = try ruby(script, ["\(proxy.port)", "\(probe)"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(requests.entries, ["127.0.0.1:\(probe) allowed", "example.com:443 refused"])
    }

    func testEveryHarnessDefinesWhereItMayReach() {
        for provider in HarnessProvider.allCases where provider != .apple {
            XCTAssertFalse(provider.siloAllowlist(appsEnabled: false).isEmpty, "\(provider)")
        }
        XCTAssertTrue(HarnessProvider.apple.siloAllowlist(appsEnabled: false).isEmpty)
        XCTAssertFalse(HarnessProvider.claudeCode.siloAllowlist(appsEnabled: false).contains("mcp-proxy.anthropic.com:443"))
        XCTAssertTrue(HarnessProvider.claudeCode.siloAllowlist(appsEnabled: true).contains("mcp-proxy.anthropic.com:443"))
    }

    /// A star stands for part of one name label, never a dot, so a pattern cannot widen to a whole domain.
    func testWildcardsMatchWithinOneLabel() {
        let allowed: Set<String> = ["api.openai.com:443", "*.openai.azure.com:443", "bedrock-runtime.*.amazonaws.com:443",
                                    "*-aiplatform.googleapis.com:443"]
        for address in ["api.openai.com:443", "mine.openai.azure.com:443", "bedrock-runtime.us-east-1.amazonaws.com:443",
                        "us-central1-aiplatform.googleapis.com:443"] {
            XCTAssertTrue(HarnessEgressProxy.permits(address, allowed: allowed), address)
        }
        for address in ["api.openai.com:80", "openai.azure.com:443", "a.b.openai.azure.com:443", "evil.com/.openai.azure.com:443",
                        "bedrock-runtime.us-east-1.s3.amazonaws.com:443", "s3.us-east-1.amazonaws.com:443",
                        "storage.googleapis.com:443", "x.openai.com:443"] {
            XCTAssertFalse(HarnessEgressProxy.permits(address, allowed: allowed), address)
        }
    }

    func testProxyEnvironmentKeepsLoopbackDirect() {
        let environment = HarnessEgressProxy.environment(port: 41_000)
        for key in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"] {
            XCTAssertEqual(environment[key], "http://127.0.0.1:41000", key)
        }
        XCTAssertEqual(environment["NO_PROXY"], "localhost,127.0.0.1,::1")
        // Apple Intelligence's remote models use URLSession, which ignores the variables above.
        let proxies = URLSessionRemoteTransport.configuration(environment: environment).connectionProxyDictionary
        XCTAssertEqual(proxies?["HTTPSProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(proxies?["HTTPSPort"] as? Int, 41_000)
        XCTAssertNil(URLSessionRemoteTransport.configuration(environment: [:]).connectionProxyDictionary)
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ address: String, _ allowed: Bool) { lock.withLock { values.append("\(address) \(allowed ? "allowed" : "refused")") } }
    var entries: [String] { lock.withLock { values } }
}

private enum TCPProbePort {
    /// A loopback port nothing listens on, for the script's own server.
    static func free() throws -> UInt16 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        guard bound else { throw XCTSkip("No loopback port is free.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
