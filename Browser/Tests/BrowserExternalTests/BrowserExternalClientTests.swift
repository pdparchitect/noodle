import BrowserBridge
@testable import BrowserExternal
import Foundation
import Testing

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [BrowserRequest] = []
    func append(_ request: BrowserRequest) { lock.withLock { requests.append(request) } }
    var all: [BrowserRequest] { lock.withLock { requests } }
}

private let work = RemoteBrowser(id: UUID(), name: "Work")
private let shop = RemoteBrowser(id: UUID(), name: "Shopping")

private func client(_ browsers: [RemoteBrowser], environment: [String: String] = [:], root: URL? = nil, calls: Calls = Calls(),
                    answer: @escaping @Sendable (BrowserRequest, URL?) throws -> BrowserResponse = { _, _ in BrowserResponse() }) -> BrowserExternalClient {
    BrowserExternalClient(environment: environment, directory: URL(fileURLWithPath: "/tmp"),
        stagingRoot: { try root ?? { throw BrowserError("No staging in this test.") }() }) { request in
        calls.append(request)
        if request.operation == .list { var response = BrowserResponse(); response.browsers = browsers; return response }
        let payload = try request.transferID.map { try BrowserTransferFiles.staging(root: root!, id: $0, create: false) }
        return try answer(request, payload)
    }
}

@Suite struct BrowserExternalClientTests {
    @Test func commandLineArgumentsBecomeAnOperationAndOptions() throws {
        let (operation, options) = try BrowserExternalClient.parse(["navigate", "--browser", "Work", "--tab", "T", "--url", "https://example.com"])
        #expect(operation == .navigate)
        #expect(options["browser"] as? String == "Work")
        #expect(options["url"] as? String == "https://example.com")
        #expect(throws: BrowserError.self) { try BrowserExternalClient.parse(["present", "--browser", "Work"]) }
        #expect(throws: BrowserError.self) { try BrowserExternalClient.parse(["navigate", "--conversation", "C"]) }
        #expect(throws: BrowserError.self) { try BrowserExternalClient.parse(["navigate", "--url"]) }
        #expect(throws: BrowserError.self) { try BrowserExternalClient.parse(["browser-set-owner"]) }
    }

    /// A model reads `required` to know what it must send; anything the browser always needs is listed.
    @Test func toolsListWhatTheyCannotDoWithout() throws {
        let required = Dictionary(uniqueKeysWithValues: BrowserExternalClient.tools().map {
            ($0["name"] as! String, Set(($0["inputSchema"] as? [String: Any])?["required"] as? [String] ?? []))
        })
        let expected: [String: Set<String>] = ["navigate": ["url"], "download": ["download", "output"], "webmcp-call": ["tool"],
            "bookmark-add": ["url"], "bookmark-update": ["bookmark"], "bookmark-remove": ["bookmark"], "fill": ["target", "text"],
            "key": ["text"], "dialog": ["accept"], "upload": ["source", "target"], "screenshot": ["output"],
            "browser-create": ["name"], "browser-update": ["name"]]
        for (tool, names) in expected { #expect(required[tool] == names, "\(tool)") }
    }

    @Test func eachCommandHasItsOwnHelp() {
        let open = BrowserExternalClient.usage(for: "open")
        #expect(open?.contains("--url") == true && open?.contains("--browser") == true)
        #expect(open?.contains("navigate") == false)
        #expect(BrowserExternalClient.usage(for: "present") == nil)
        #expect(BrowserExternalClient.usage(for: "frobnicate") == nil)
    }

    @Test func theBrowserCanBeLeftOutWhenThereIsOnlyOne() async throws {
        let calls = Calls()
        _ = try await client([work], calls: calls).run(.tabs, options: [:])
        #expect(calls.all.last?.browserID == work.id)
        await #expect(throws: BrowserError.self) { try await client([work, shop]).run(.tabs, options: [:]) }
        await #expect(throws: BrowserError.self) { try await client([]).run(.tabs, options: [:]) }
    }

    @Test func aBrowserIsNamedByItsNameOrIDOrTheEnvironment() async throws {
        let calls = Calls()
        _ = try await client([work, shop], calls: calls).run(.tabs, options: ["browser": "shopping"])
        #expect(calls.all.last?.browserID == shop.id)
        _ = try await client([work, shop], environment: ["NOODLE_BROWSER": "Work"], calls: calls).run(.tabs, options: [:])
        #expect(calls.all.last?.browserID == work.id)
        _ = try await client([], calls: calls).run(.tabs, options: ["browser": shop.id.uuidString])
        #expect(calls.all.last?.browserID == shop.id)
        await #expect(throws: BrowserError.self) { try await client([work]).run(.tabs, options: ["browser": "Bank"]) }
    }

    @Test func makingOneTakesItsNameAndNeedsNoBrowser() async throws {
        let calls = Calls()
        _ = try await client([], calls: calls).run(.create, options: ["name": "Research", "description": "Papers"])
        #expect(calls.all.last?.profile == BrowserDraft(name: "Research", description: "Papers"))
        #expect(calls.all.last?.browserID == nil)
        _ = try await client([], calls: calls).run(.borrow, options: [:])
        #expect(calls.all.last?.operation == .borrow)
    }

    @Test func commandLineValuesAreTyped() async throws {
        let calls = Calls()
        _ = try await client([work], calls: calls).run(.click, options: ["x": "10", "y": "20.5", "count": "2"])
        #expect(calls.all.last?.x == 10 && calls.all.last?.y == 20.5 && calls.all.last?.clickCount == 2)
        _ = try await client([work], calls: calls).run(.dialog, options: ["accept": "false"])
        #expect(calls.all.last?.accept == false)
        _ = try await client([work], calls: calls).run(.webMCPCall, options: ["tool": "t", "args": "{\"a\":1}"])
        #expect(calls.all.last?.arguments == "{\"a\":1}")
        await #expect(throws: BrowserError.self) { try await client([work]).run(.click, options: ["x": "left"]) }
    }

    @Test func aScreenshotLandsAtTheOutputPathAndNeverReplacesAFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("shot.png")
        let browser = client([work], root: root) { _, payload in
            try Data("png".utf8).write(to: payload!)
            var response = BrowserResponse(); response.byteCount = 3; response.filename = "screenshot.png"; return response
        }
        let result = try await browser.run(.screenshot, options: ["output": output.path])
        #expect(try Data(contentsOf: output) == Data("png".utf8))
        #expect(result["output"] as? String == output.path)
        await #expect(throws: BrowserError.self) { try await browser.run(.screenshot, options: ["output": output.path]) }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("file-transfers").path)
        #expect(leftovers.isEmpty)
    }

    @Test func anUploadIsStagedForTheBrowser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cv.pdf")
        try Data("resume".utf8).write(to: source)
        let calls = Calls()
        _ = try await client([work], root: root, calls: calls) { request, payload in
            let staged = try Data(contentsOf: payload!)
            #expect(staged == Data("resume".utf8))
            var response = BrowserResponse(); response.byteCount = 6; return response
        }.run(.upload, options: ["source": source.path, "target": "input[type=file]"])
        #expect(calls.all.last?.filename == "cv.pdf")
    }

    @Test func pageAnswersComeBackAsValues() async throws {
        let result = try await client([work]) { _, _ in var response = BrowserResponse(); response.text = "{\"title\":\"Hi\"}"; return response }
            .run(.eval, options: ["text": "return 1"])
        #expect((result["value"] as? [String: Any])?["title"] as? String == "Hi")
        #expect(result["text"] == nil && result["version"] == nil)
    }

    @Test func theToolsAreWhatOutsideAppsMayCall() throws {
        let tools = BrowserExternalClient.tools()
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names == Set(BrowserOperation.externalCases.map(\.rawValue)))
        #expect(!names.contains("present") && !names.contains("surface-stream") && !names.contains("browser-set-owner"))
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(!((schema["required"] as? [String]) ?? []).contains("browser"))
        }
    }

    @Test func mcpCallsAnswerWithStructuredContentOrAnError() async throws {
        let source = BrowserMCPSource(client: client([work]))
        let ok = try JSONSerialization.jsonObject(with: await source.call("tabs", arguments: Data("{}".utf8))) as? [String: Any]
        #expect(ok?["isError"] as? Bool == false)
        #expect(ok?["structuredContent"] is [String: Any])
        let failed = try JSONSerialization.jsonObject(with: await source.call("present", arguments: Data("{}".utf8))) as? [String: Any]
        #expect(failed?["isError"] as? Bool == true)
    }
}
