import AppKit
import BrowserBridge
import Foundation

extension BrowserSmokeTest {
    #if NOODLE_DEV_HOOKS
    /// Optional external compatibility smoke. Never uses a real account or
    /// provider key; these public demos perform only local page interactions.
    @MainActor static func verifyPublicWebMCPDemos(_ runtime: BrowserRuntime, browserID: UUID) async throws {
        let tab = try runtime.makeTab(browserID: browserID)
        defer { try? runtime.closeTab(browserID: browserID, tabID: tab.id) }
        func list() async throws -> [String: Any] {
            let response = try await runtime.perform(.init(.webMCPList, browserID: browserID, tabID: tab.id))
            return try JSONSerialization.jsonObject(with: Data(response.text!.utf8)) as! [String: Any]
        }
        func call(_ name: String, args: [String: Any]) async throws -> [String: Any] {
            let catalogue = try await list()
            try require(catalogue["implementation"] as? String == "compatibility", "Demo did not use the Noodle compatibility runtime")
            guard let tool = (catalogue["tools"] as? [[String: Any]])?.first(where: { $0["name"] as? String == name }), let id = tool["id"] as? String else { throw BrowserError("Public demo tool not discovered: " + name) }
            var request = BrowserRequest(.webMCPCall, browserID: browserID, tabID: tab.id)
            request.toolID = id; request.arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            let response = try await runtime.perform(request)
            let result = try JSONSerialization.jsonObject(with: Data(response.text!.utf8)) as! [String: Any]
            try require(result["status"] as? String == "completed", "Public demo call failed: \(result)")
            return result
        }
        tab.navigate(URL(string: "https://googlechromelabs.github.io/webmcp-tools/demos/pizza-maker/")!)
        try await eventually("public Pizza Maker registration") {
            let result = try await list()
            return (result["tools"] as? [[String: Any]])?.contains(where: { $0["name"] as? String == "set_pizza_size" }) == true
        }
        _ = try await call("set_pizza_size", args: ["size": "Large"])
        _ = try await call("add_topping", args: ["topping": "🍄", "count": 3])
        try await eventually("public Pizza Maker result") {
            try await tab.evaluate("return document.querySelector('#size-text')?.textContent.includes('Large') && Array.from(document.querySelectorAll('.topping')).filter(e=>e.textContent.includes('🍄')).length>=3;") as? Bool == true
        }
        tab.navigate(URL(string: "https://googlechromelabs.github.io/webmcp-tools/demos/french-bistro/?toolautosubmit")!)
        try await eventually("public Bistro form") {
            try await tab.evaluate("return document.querySelector('#reservationForm')?.hasAttribute('toolautosubmit')===true && !!document.querySelector('#date')?.getAttribute('min');") as? Bool == true
        }
        let date = try await tab.evaluate("return new Date(Date.now()+86400000).toISOString().slice(0,10);") as! String
        let result = try await call("book_table_le_petit_bistro", args: ["name": "Noodle Test", "phone": "0000000000", "date": date, "time": "19:00", "guests": "2", "seating": "Main Dining", "requests": "Compatibility test"])
        try require((result["result"] as? String)?.contains("Noodle Test") == true, "Bistro respondWith result missing: \(result)")
        print("PASS public Google Chrome Labs Pizza Maker and Le Petit Bistro demos using the bundled WebMCP runtime")
    }
    #endif

    @MainActor static func verifyWebMCP(_ runtime: BrowserRuntime, browserID: UUID, otherID: UUID, base: String) async throws {
        let tab = try runtime.makeTab(browserID: browserID)
        let isolated = try runtime.makeTab(browserID: otherID)
        defer {
            try? runtime.closeTab(browserID: browserID, tabID: tab.id)
            try? runtime.closeTab(browserID: otherID, tabID: isolated.id)
        }
        let focus = BrowserFocusProbe()
        defer { focus.stop() }
        let windows = NSApp.windows.filter(\.isVisible).count
        func ready(_ tab: BrowserTab, path: String = "/webmcp") async throws {
            let previous = (try? await tab.evaluate("return performance.timeOrigin;")) as? Double ?? 0
            tab.navigate(URL(string: base + path)!)
            try await eventually("WebMCP fixture loaded") {
                try await tab.evaluate("return performance.timeOrigin!==previous && location.pathname===path && await window.webMCPReady===true;", arguments: ["path": path, "previous": previous]) as? Bool == true
            }
        }
        func perform(_ operation: BrowserOperation, tab: BrowserTab, tool: String? = nil, args: String = "{}", frame: String? = nil) async throws -> [String: Any] {
            var request = BrowserRequest(operation, browserID: tab.browserID, tabID: tab.id)
            request.frame = frame
            if operation == .webMCPCall { request.toolID = tool; request.arguments = args }
            let response = try await runtime.perform(request)
            guard let text = response.text, let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw BrowserError("Invalid WebMCP JSON") }
            return value
        }
        func tools(_ tab: BrowserTab, frame: String? = nil) async throws -> [[String: Any]] {
            let response = try await perform(.webMCPList, tab: tab, frame: frame)
            guard let tools = response["tools"] as? [[String: Any]] else { throw BrowserError("No WebMCP tool list") }
            return tools
        }
        func id(_ name: String, in list: [[String: Any]]) throws -> String {
            guard let id = list.first(where: { $0["name"] as? String == name })?["id"] as? String else { throw BrowserError("Missing tool: " + name) }
            return id
        }
        func expectError(_ result: [String: Any], _ code: String) throws {
            try require(result["status"] as? String == "error" && (result["error"] as? [String: Any])?["code"] as? String == code, "Expected WebMCP \(code): \(result)")
        }
        try await ready(tab); try await ready(isolated)
        var list = try await tools(tab)
        let echo = try id("echo", in: list)
        let echoed = try await perform(.webMCPCall, tab: tab, tool: echo, args: #"{"text":"CLI marker","count":3}"#)
        let value = echoed["result"] as? [String: Any]
        try require(echoed["status"] as? String == "completed" && value?["authenticated"] as? Bool == true && value?["count"] as? Int == 3, "WebMCP lost fake account or JSON values")
        let isolatedList = try await tools(isolated)
        try expectError(try await perform(.webMCPCall, tab: isolated, tool: echo), "STALE_TOOL")
        let isolatedResult = try await perform(.webMCPCall, tab: isolated, tool: id("echo", in: isolatedList), args: #"{"text":"isolated"}"#)
        try require((isolatedResult["result"] as? [String: Any])?["authenticated"] as? Bool == false, "WebMCP leaked profile authentication")
        // Use eval's actual request path, returning only serializable metadata.
        var script = BrowserRequest(.eval, browserID: browserID, tabID: tab.id)
        script.text = "const tools=await document.modelContext.getTools(); const tool=tools.find(t=>t.name==='echo'); return JSON.parse(await document.modelContext.executeTool(tool,{text:'eval marker'}));"
        let evaluated = try await runtime.perform(script)
        let evalResult = try JSONSerialization.jsonObject(with: Data(evaluated.text!.utf8)) as? [String: Any]
        try require(evalResult?["authenticated"] as? Bool == true && evalResult?["text"] as? String == "eval marker", "Eval and CLI did not share WebMCP tools")
        let lifecycle = try await tab.evaluate("""
            let activations=0, changes=0;
            const mc=document.modelContext, registration=new AbortController();
            mc.ontoolactivated=()=>activations++;
            mc.ontoolchange=()=>changes++;
            await mc.registerTool({name:'self_removing',description:'Unregister during execution',execute:async()=>{
                registration.abort(); await Promise.resolve(); return 'finished';
            }},{signal:registration.signal});
            const tool=(await mc.getTools()).find(t=>t.name==='self_removing');
            const result=await mc.executeTool(tool);
            mc.ontoolactivated=null; mc.ontoolchange=null;
            return result==='finished' && activations===1 && changes>=2;
            """)
        try require(lifecycle as? Bool == true, "Registration cancellation interrupted an active execution or lost lifecycle events")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: echo, args: #"{"text":"invalid","count":0}"#), "INVALID_ARGUMENTS")
        try require(try await tab.evaluate("return calls===2;") as? Bool == true, "Invalid arguments executed a tool")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: id("unsupported_schema", in: list)), "UNSUPPORTED_SCHEMA")
        let schemaID = try id("json_schema", in: list)
        try require(try await perform(.webMCPCall, tab: tab, tool: schemaID, args: #"{"options":["small","large"]}"#)["status"] as? String == "completed", "Schema references failed")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: schemaID, args: #"{"options":["wrong"]}"#), "INVALID_ARGUMENTS")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: id("fail", in: list)), "Error")
        try runtime.setPaused(true, browserID: browserID)
        do { _ = try await perform(.webMCPCall, tab: tab, tool: echo); throw BrowserError("Paused WebMCP call ran") }
        catch let error as BrowserError { try require(error.message.contains("paused"), "Unexpected paused WebMCP error") }
        try runtime.setPaused(false, browserID: browserID)
        let booking = try id("book_table", in: list)
        let booked = try await perform(.webMCPCall, tab: tab, tool: booking, args: #"{"guest":"Fixture Guest","seats":2,"area":"outside"}"#)
        try require((booked["result"] as? [String: Any])?["agentInvoked"] as? Bool == true && (booked["result"] as? [String: Any])?["area"] as? String == "outside", "Declarative form invocation failed: \(booked)")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: booking, args: #"{"guest":"A","seats":0}"#), "INVALID_ARGUMENTS")
        try require(try await tab.evaluate("return submissions===1;") as? Bool == true, "Invalid form submitted")
        let manual = try await perform(.webMCPCall, tab: tab, tool: id("manual_search", in: list), args: #"{"query":"human review"}"#)
        try require(manual["status"] as? String == "needs-user-action", "Manual form did not return a handoff")
        try require(try await tab.evaluate("return manualSubmissions===0 && document.querySelector('#manual input').value==='human review';") as? Bool == true, "Manual form submitted automatically")
        _ = try await tab.evaluate("document.querySelector('#manual').requestSubmit(); return true;")
        try require(try await tab.evaluate("return manualSubmissions===1 && manualWasAgentInvoked===true;") as? Bool == true, "Human form submission lost agentInvoked")
        let asyncForm = try await perform(.webMCPCall, tab: tab, tool: id("async_form", in: list), args: #"{"text":"async response"}"#)
        try require(asyncForm["status"] as? String == "completed" && (asyncForm["result"] as? [String: Any])?["text"] as? String == "async response", "Async respondWith result confused with internal state")
        _ = try await tab.evaluate("document.querySelector('#booking input').setAttribute('minlength','4'); return true;")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: booking, args: #"{"guest":"Valid","seats":2}"#), "STALE_TOOL")
        _ = try await tab.evaluate("registration.abort(); await document.modelContext.registerTool({name:'echo',description:'Replacement',execute:()=> 'replacement'}); return true;")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: echo), "STALE_TOOL")
        list = try await tools(tab)
        try require(try await perform(.webMCPCall, tab: tab, tool: id("echo", in: list))["result"] as? String == "replacement", "Replacement registration failed")
        try await eventually("WebMCP frames") { tab.frames.values.filter { !$0.isMainFrame }.count >= 2 }
        guard let same = tab.frames.first(where: { !$0.value.isMainFrame && $0.value.request.url?.host == "127.0.0.1" })?.key,
              let cross = tab.frames.first(where: { $0.value.request.url?.host == "localhost" })?.key else { throw BrowserError("Missing WebMCP test frames") }
        let frameTools = try await tools(tab, frame: same)
        let framed = try await perform(.webMCPCall, tab: tab, tool: id("frame_echo", in: frameTools), frame: same)
        try require(framed["result"] as? String == base, "Frame tool ran in wrong origin")
        let crossTools = try await perform(.webMCPList, tab: tab, frame: cross)
        try require(crossTools["status"] as? String == "unsupported", "Cross-origin tool boundary was bypassed")
        try expectError(try await perform(.webMCPCall, tab: tab, tool: id("hang", in: list)), "TIMEOUT")
        try require(try await tab.evaluate("return toolAborted===true;") as? Bool == true, "Timed-out tool did not receive cancellation")
        let oldID = try id("echo", in: list)
        try await ready(tab)
        try expectError(try await perform(.webMCPCall, tab: tab, tool: oldID), "STALE_TOOL")
        for path in ["/webmcp-blocked", "/webmcp-domain"] {
            try await ready(tab, path: path)
            do { _ = try await tools(tab); throw BrowserError("Response policy ignored") }
            catch let error as BrowserError { try require(error.message.contains("policy"), "Unexpected response policy error: \(error)") }
        }
        try await ready(tab)
        let navigationTools = try await tools(tab)
        // Navigation can dispose the JS promise; either response must not retry.
        _ = try? await perform(.webMCPCall, tab: tab, tool: id("navigate_form", in: navigationTools), args: #"{"query":"next"}"#)
        try await eventually("WebMCP form navigation") { try await tab.evaluate("return !!document.querySelector('#webmcp-result');") as? Bool == true }
        let empty = try await perform(.webMCPList, tab: tab)
        try require(empty["status"] as? String == "empty", "Empty tool list confused with integration failure")
        try focus.verify()
        try require(NSApp.windows.filter(\.isVisible).count == windows, "WebMCP opened a window")
        print("PASS WebMCP document-start registration, CLI/eval parity, authenticated profile isolation, schema validation, async results/errors, registration replacement, declarative/manual forms, frames, response policy, pause, timeout cancellation, navigation and quiet operation")
    }
}
