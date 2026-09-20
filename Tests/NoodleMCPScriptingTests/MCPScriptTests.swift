import XCTest
import NoodleCore
@testable import NoodleMCPScripting

final class MCPScriptTests: XCTestCase {
    func testChainsCallsAndPrintsOnlySelectedJSON() throws {
        var values: [Int] = []
        var output: [String] = []
        try MCPScript.run("""
        const results = [1, 2, 3].map(value => mcp.call('echo', {value}));
        print(results.filter(r => r.structuredContent.value > 1).map(r => r.structuredContent.value));
        42;
        """, perform: { action, tool, arguments, uri, raw in
            XCTAssertEqual(action, .call); XCTAssertEqual(tool, "echo"); XCTAssertNil(uri); XCTAssertFalse(raw)
            let input = try JSONDecoder().decode([String: Int].self, from: XCTUnwrap(arguments))
            values.append(try XCTUnwrap(input["value"]))
            return try JSONSerialization.data(withJSONObject: ["structuredContent": input])
        }, output: { data, diagnostic in
            XCTAssertFalse(diagnostic)
            output.append(String(decoding: data, as: UTF8.self))
        })
        XCTAssertEqual(values, [1, 2, 3])
        XCTAssertEqual(output, ["[2,3]\n"])
    }

    func testOneScriptCanCallAnyProviderAndChainTheirResults() throws {
        var seen: [String] = []
        var output: [String] = []
        try MCPScript.run("""
        const names = tools.providers().providers.map(p => p.id);
        const text = tools.call('vision', 'ocr', {image: 'page.png'}).structuredContent.text;
        const notion = tools.provider('mcp-notion');
        notion.call('create-page', {title: text});
        tools.list('browser'); tools.inspect('browser', 'click'); notion.resources(); notion.readResource('notion://1', {raw: true});
        print({names, text});
        """, provider: nil, request: { request in
            switch request {
            case .providers: seen.append("providers"); return Data(#"{"providers":[{"id":"vision"},{"id":"mcp-notion"}]}"#.utf8)
            case .operation(let provider, let action, let tool, let arguments, let uri, let raw):
                seen.append([provider, action.rawValue, tool ?? uri ?? "", raw ? "raw" : ""].filter { !$0.isEmpty }.joined(separator: " "))
                if tool == "create-page" { XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: XCTUnwrap(arguments)), ["title": "Pricing"]) }
                return Data(#"{"structuredContent":{"text":"Pricing"}}"#.utf8)
            }
        }, output: { data, _ in output.append(String(decoding: data, as: UTF8.self)) })
        XCTAssertEqual(seen, ["providers", "vision call ocr", "mcp-notion call create-page", "browser tools", "browser inspect click",
                              "mcp-notion resources", "mcp-notion read-resource notion://1 raw"])
        XCTAssertEqual(output, ["{\"names\":[\"vision\",\"mcp-notion\"],\"text\":\"Pricing\"}\n"])
    }

    func testMcpIsTheBoundProviderAndSaysSoWhenThereIsNone() throws {
        var providers: [String] = []
        try MCPScript.run("mcp.tools(); tools.call('vision', 'ocr');", provider: "mcp-notion", request: { request in
            if case .operation(let provider, _, _, _, _, _) = request { providers.append(provider) }
            return Data("{}".utf8)
        }, output: { _, _ in })
        XCTAssertEqual(providers, ["mcp-notion", "vision"], "a bound script can still reach every other provider")
        XCTAssertThrowsError(try MCPScript.run("mcp.tools()", provider: nil, request: { _ in Data("{}".utf8) }, output: { _, _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("tools.call(provider"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try MCPScript.run("tools.call('', 'x')", provider: nil, request: { _ in Data("{}".utf8) }, output: { _, _ in }))
    }

    func testEveryOperationAndRawOptions() throws {
        var actions: [MCPBridgeAction] = []
        try MCPScript.run("""
        mcp.tools(); mcp.inspect('echo'); mcp.call('echo');
        mcp.resources(); mcp.readResource('reports://file');
        mcp.call('raw', {}, {raw: true}); mcp.readResource('reports://raw', {raw: true});
        """, perform: { action, tool, arguments, uri, raw in
            actions.append(action)
            XCTAssertEqual(raw, tool == "raw" || uri == "reports://raw")
            if action == .inspect { XCTAssertEqual(tool, "echo"); XCTAssertNil(arguments) }
            if action == .call { XCTAssertEqual(arguments, Data("{}".utf8)) }
            return Data("{}".utf8)
        }, output: { _, _ in XCTFail("Results must not print implicitly") })
        XCTAssertEqual(actions, [.tools, .inspect, .call, .resources, .readResource, .call, .readResource])
    }

    func testToolErrorsThrowWithCompleteResultAndCanBeHandled() throws {
        var printed = ""
        let result = Data(#"{"isError":true,"content":[{"type":"text","text":"Missing item"}],"structuredContent":{"code":404}}"#.utf8)
        try MCPScript.run("""
        try { mcp.call('missing'); throw new Error('Expected tool failure'); }
        catch (error) { print(error.result); }
        """, perform: { _, _, _, _, _ in result }, output: { data, _ in printed += String(decoding: data, as: UTF8.self) })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any])
        XCTAssertEqual(object["isError"] as? Bool, true)
        XCTAssertEqual(object["structuredContent"] as? [String: Int], ["code": 404])
        XCTAssertThrowsError(try MCPScript.run("mcp.call('missing')", perform: { _, _, _, _, _ in result }, output: { _, _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("MCP tool returned an error"))
        }
    }

    func testTransportErrorsAreCatchableWithoutImplicitRetries() throws {
        var calls = 0
        var printed = ""
        try MCPScript.run("try { mcp.tools(); } catch (error) { print(error.message); }", perform: { _, _, _, _, _ in
            calls += 1
            throw MCPConnectionError.message("Connection revoked")
        }, output: { data, _ in printed += String(decoding: data, as: UTF8.self) })
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(printed, "\"Connection revoked\"\n")
    }

    func testPrintAndDiagnosticsUseSeparateStreams() throws {
        var output: [String] = [], diagnostics: [String] = []
        try MCPScript.run("console.log('Found', {count: 2}); print('hello'); print(null)", perform: unused,
            output: { data, diagnostic in
                if diagnostic { diagnostics.append(String(decoding: data, as: UTF8.self)) }
                else { output.append(String(decoding: data, as: UTF8.self)) }
            })
        XCTAssertEqual(output, ["\"hello\"\n", "null\n"])
        XCTAssertEqual(diagnostics, ["Found {\"count\":2}\n"])
    }

    func testInvalidArgumentsDoNotReachBridge() throws {
        for source in ["mcp.call('', {})", "mcp.call('echo', [])", "mcp.call('echo', null)",
                       "mcp.call('echo', {}, {raw: 'yes'})", "mcp.call('echo', {}, {connection: 'other'})",
                       "mcp.inspect(1)", "mcp.readResource('')", "print(undefined)",
                       "mcp.call('echo', {toJSON() { return null; }})",
                       "mcp.call('echo', {toJSON() { return 'text'; }})",
                       "mcp.call('echo', {toJSON() { return undefined; }})",
                       "const x = {}; x.x = x; mcp.call('echo', x)"] {
            XCTAssertThrowsError(try MCPScript.run(source, perform: unused, output: { _, _ in }), source)
        }
    }

    func testConsoleMethodsHandleDiagnosticValuesAndFormatting() throws {
        var messages: [String] = []
        try MCPScript.run("""
        console.log();
        console.info('hello %s, %d / %i / %f / %%', 'world', 2.5, 3.9, '4.2');
        console.warn(undefined, null, NaN, 1n, Symbol('test'));
        console.debug('%o %O', {count: 2}, ['item']);
        const cycle = {value: 1}; cycle.self = cycle;
        console.dir(cycle);
        const shared = {}; console.log({a: shared, b: shared});
        console.log({toJSON() { throw new Error('cannot inspect'); }});
        console.assert(true, 'hidden'); console.assert(false, 'expected %s', 'value');
        console.error('failure', new Error('detail'));
        """, sourceURL: URL(fileURLWithPath: "/workspace/console.js"), perform: unused, output: { data, diagnostic in
            XCTAssertTrue(diagnostic)
            messages.append(String(decoding: data, as: UTF8.self))
        })
        XCTAssertEqual(messages.count, 9)
        XCTAssertEqual(messages[0], "\n")
        XCTAssertEqual(messages[1], "hello world, 2.5 / 3 / 4.2 / %\n")
        XCTAssertEqual(messages[2], "undefined null NaN 1 Symbol(test)\n")
        XCTAssertEqual(messages[3], "{\"count\":2} [\"item\"]\n")
        XCTAssertEqual(messages[4], "{\"value\":1,\"self\":\"[Circular]\"}\n")
        XCTAssertEqual(messages[5], "{\"a\":{},\"b\":{}}\n")
        XCTAssertEqual(messages[6], "[Uninspectable]\n")
        XCTAssertEqual(messages[7], "Assertion failed: expected value\n")
        XCTAssertTrue(messages[8].contains("failure Error: detail"))
        XCTAssertTrue(messages[8].contains("console.js:"))
    }

    func testConsoleTraceIncludesUserCallStack() throws {
        var diagnostic = ""
        try MCPScript.run("function inner() { console.trace('checkpoint'); }\nfunction outer() { inner(); }\nouter();",
            sourceURL: URL(fileURLWithPath: "/workspace/trace.js"), perform: unused, output: { data, isDiagnostic in
                XCTAssertTrue(isDiagnostic)
                diagnostic += String(decoding: data, as: UTF8.self)
            })
        XCTAssertTrue(diagnostic.contains("Trace: checkpoint"))
        XCTAssertTrue(diagnostic.contains("inner@file:///workspace/trace.js:1:"))
        XCTAssertTrue(diagnostic.contains("outer@file:///workspace/trace.js:2:"))
        XCTAssertFalse(diagnostic.contains("messenger-tool:///runtime.js"))
    }

    func testCallLimitCannotBeCaughtAndBypassed() throws {
        var calls = 0
        XCTAssertThrowsError(try MCPScript.run("for (let i = 0; i < 5; i++) { try { mcp.tools(); } catch (_) {} }",
            maxCalls: 2, maxOutputBytes: 100, perform: { _, _, _, _, _ in calls += 1; return Data("{}".utf8) }, output: { _, _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("2-call limit"))
        }
        XCTAssertEqual(calls, 2)
    }

    func testCombinedOutputLimitCannotBeCaughtAndBypassed() throws {
        var output = Data()
        XCTAssertThrowsError(try MCPScript.run("print('1234'); try { console.log('1234'); } catch (_) {} try { print(0); } catch (_) {}",
            maxCalls: 2, maxOutputBytes: 10, perform: unused, output: { data, _ in output.append(data) })) {
            XCTAssertTrue($0.localizedDescription.contains("output exceeds"))
        }
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "\"1234\"\n")
    }

    func testFreshContextsAndNoAmbientHostAPIs() throws {
        try MCPScript.run("globalThis.previous = 1", perform: unused, output: { _, _ in })
        var output = ""
        try MCPScript.run("print([typeof previous, typeof fetch, typeof require, typeof process, typeof setTimeout, typeof __mcpRequest, typeof __mcpWrite])",
            perform: unused, output: { data, _ in output += String(decoding: data, as: UTF8.self) })
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(output.utf8)), Array(repeating: "undefined", count: 7))
    }

    func testSyntaxAndRuntimeErrorsIncludeSourceLocation() throws {
        let url = URL(fileURLWithPath: "/workspace/workflow.js")
        XCTAssertThrowsError(try MCPScript.run("\nconst =", sourceURL: url, perform: unused, output: { _, _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("SyntaxError"))
            XCTAssertTrue($0.localizedDescription.contains("workflow.js:2"))
        }
        for source in ["throw null", "throw undefined", "throw 'plain'", "throw 42"] {
            XCTAssertThrowsError(try MCPScript.run(source, sourceURL: url, perform: unused, output: { _, _ in })) {
                XCTAssertTrue($0.localizedDescription.contains("workflow.js"))
            }
        }
        XCTAssertThrowsError(try MCPScript.run("function inner() { mcp.call('missing'); }\nfunction outer() { inner(); }\nouter();",
            sourceURL: url, perform: { _, _, _, _, _ in throw MCPConnectionError.message("Connection unavailable") }, output: { _, _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("Connection unavailable"))
            XCTAssertTrue($0.localizedDescription.contains("inner@file:///workspace/workflow.js:1:"))
            XCTAssertTrue($0.localizedDescription.contains("outer@file:///workspace/workflow.js:2:"))
            XCTAssertFalse($0.localizedDescription.contains("messenger-tool:///runtime.js"))
        }
        XCTAssertThrowsError(try MCPScript.run("\nthrow new Error('broken')", sourceURL: url, perform: unused, output: { _, _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("broken"))
            XCTAssertTrue($0.localizedDescription.contains("workflow.js:2"))
        }
    }

    func testOversizedSourceAndPromiseCompletionAreRejected() throws {
        XCTAssertThrowsError(try MCPScript.run(String(repeating: " ", count: MCPScript.maxSourceBytes + 1), perform: unused, output: { _, _ in }))
        XCTAssertThrowsError(try MCPScript.run("Promise.resolve(1)", perform: unused, output: { _, _ in })) {
            XCTAssertTrue($0.localizedDescription.contains("synchronous"))
        }
    }

    private var unused: MCPScript.Perform {
        { _, _, _, _, _ in XCTFail("Unexpected MCP request"); return Data("{}".utf8) }
    }
}
