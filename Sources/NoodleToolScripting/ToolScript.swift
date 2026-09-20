import Foundation
import JavaScriptCore
import NoodleCore

/// A fresh JavaScriptCore context with only JSON bridge operations and output.
/// The CLI owns the process deadline, including time spent in JavaScript loops.
public enum ToolScript {
    public static let maxSourceBytes = 1_048_576
    public static let maxCalls = 100
    public static let maxOutputBytes = 8 * 1_048_576
    public typealias Perform = (MCPBridgeAction, String?, Data?, String?, Bool) throws -> Data
    public typealias Output = (Data, Bool) throws -> Void

    /// What a script asks for. Every operation names its provider, so one script can use
    /// any tool Noodle provides to the bot; each request is still authorized on its own.
    public enum Request {
        case providers
        case operation(provider: String, action: MCPBridgeAction, tool: String?, arguments: Data?, uri: String?, raw: Bool)
    }
    public typealias Requester = (Request) throws -> Data

    /// A script bound to one provider, as `messenger tool PROVIDER --run` starts it.
    public static func run(_ source: String, sourceURL: URL? = nil,
                           perform: @escaping Perform, output: @escaping Output) throws {
        try run(source, sourceURL: sourceURL, maxCalls: maxCalls, maxOutputBytes: maxOutputBytes,
                perform: perform, output: output)
    }

    static func run(_ source: String, sourceURL: URL? = nil, maxCalls: Int, maxOutputBytes: Int,
                    perform: @escaping Perform, output: @escaping Output) throws {
        try run(source, sourceURL: sourceURL, maxCalls: maxCalls, maxOutputBytes: maxOutputBytes, provider: "", request: { request in
            guard case .operation(_, let action, let tool, let arguments, let uri, let raw) = request else {
                throw failure("This script is bound to one provider.")
            }
            return try perform(action, tool, arguments, uri, raw)
        }, output: output)
    }

    /// `provider` is what the `mcp` global is bound to; nil leaves only `tools`.
    public static func run(_ source: String, sourceURL: URL? = nil, provider: String?,
                           request: @escaping Requester, output: @escaping Output) throws {
        try run(source, sourceURL: sourceURL, maxCalls: maxCalls, maxOutputBytes: maxOutputBytes, provider: provider, request: request, output: output)
    }

    static func run(_ source: String, sourceURL: URL? = nil, maxCalls: Int, maxOutputBytes: Int, provider bound: String?,
                    request perform: @escaping Requester, output: @escaping Output) throws {
        guard source.utf8.count <= maxSourceBytes else { throw failure("JavaScript source exceeds 1 MiB.") }
        guard let context = JSContext() else { throw failure("Could not create a JavaScript context.") }
        var calls = 0
        var outputBytes = 0
        var terminalError: Error?
        let request: @convention(block) (String) -> String = { json in
            do {
                if let terminalError { throw terminalError }
                guard calls < maxCalls else {
                    let error = failure("MCP script exceeds its \(maxCalls)-call limit.")
                    terminalError = error
                    throw error
                }
                guard json.utf8.count <= MCPBridgeFiles.maxRequestBytes + 8192,
                      let fields = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let name = fields["action"] as? String else {
                    throw failure("Invalid or oversized MCP script request.")
                }
                if name == "providers" {
                    calls += 1
                    return try envelope(["value": try JSONSerialization.jsonObject(with: perform(.providers))])
                }
                guard let action = MCPBridgeAction(rawValue: name), let provider = fields["provider"] as? String else {
                    throw failure("Invalid or oversized MCP script request.")
                }
                let arguments: Data?
                if action == .call {
                    // toJSON can change a validated JS object into any JSON value.
                    guard let input = fields["arguments"] as? [String: Any] else {
                        throw failure("Tool arguments must be a JSON object.")
                    }
                    arguments = try JSONSerialization.data(withJSONObject: input)
                } else { arguments = nil }
                calls += 1
                let result = try perform(.operation(provider: provider, action: action, tool: fields["tool"] as? String, arguments: arguments,
                                                    uri: fields["uri"] as? String, raw: fields["raw"] as? Bool ?? false))
                // The bridge applies the result limit before attachment extraction.
                // File metadata may make its returned JSON slightly larger.
                let object = try JSONSerialization.jsonObject(with: result)
                if (object as? [String: Any])?["isError"] as? Bool == true {
                    return try envelope(["error": "MCP tool returned an error. See error.result for the full result.", "result": object])
                }
                return try envelope(["value": object])
            } catch {
                return (try? envelope(["error": error.localizedDescription])) ?? "{\"error\":\"MCP script request failed.\"}"
            }
        }
        let write: @convention(block) (String, Bool) -> String = { text, diagnostic in
            do {
                if let terminalError { throw terminalError }
                guard text.utf8.count < maxOutputBytes - outputBytes else {
                    throw failure("MCP script output exceeds \(maxOutputBytes) bytes.")
                }
                let data = Data((text + "\n").utf8)
                outputBytes += data.count
                try output(data, diagnostic)
                return ""
            } catch {
                terminalError = error
                return error.localizedDescription
            }
        }
        context.setObject(bound as Any, forKeyedSubscript: "__mcpProvider" as NSString)
        context.setObject(request, forKeyedSubscript: "__mcpRequest" as NSString)
        context.setObject(write, forKeyedSubscript: "__mcpWrite" as NSString)
        context.evaluateScript(bootstrap, withSourceURL: URL(string: "messenger-tool:///runtime.js"))
        if let exception = context.exception { throw failure(exception.toString() ?? "JavaScript setup failed.") }
        let promise = context.objectForKeyedSubscript("Promise")
        let scriptURL = sourceURL ?? URL(string: "messenger-tool:///eval.js")!
        let result = context.evaluateScript(source, withSourceURL: scriptURL)
        if let terminalError { throw terminalError }
        if let exception = context.exception {
            let message = exception.toString() ?? "JavaScript failed."
            let stack = exception.isObject ? exception.forProperty("stack")?.toString() ?? "" : ""
            let frames = stack.components(separatedBy: "\n").filter {
                !$0.isEmpty && $0 != "undefined" && !$0.contains("@messenger-tool:///runtime.js:")
            }
            if !frames.isEmpty { throw failure(message + "\n" + frames.joined(separator: "\n")) }
            // Syntax errors have no stack in JavaScriptCore, but carry a source
            // URL and line. Thrown primitives still identify the source file.
            let line = exception.isObject ? exception.forProperty("line")?.toInt32() ?? 0 : 0
            let column = exception.isObject ? exception.forProperty("column")?.toInt32() ?? 0 : 0
            let location = scriptURL.absoluteString + (line > 0 ? ":\(line)" : "") + (column > 0 ? ":\(column)" : "")
            throw failure(message + "\n" + location)
        }
        if let promise, result?.isInstance(of: promise) == true {
            throw failure("MCP scripts are synchronous; do not return a Promise or use async workflows.")
        }
    }

    private static func failure(_ message: String) -> MCPConnectionError { .message(message) }
    private static func envelope(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    private static let bootstrap = #"""
    ((request, write, boundProvider) => {
        delete globalThis.__mcpRequest;
        delete globalThis.__mcpWrite;
        delete globalThis.__mcpProvider;
        const stringify = JSON.stringify, parse = JSON.parse, ErrorType = Error;
        function json(value) {
            const text = stringify(value);
            if (text === undefined) throw new TypeError('Expected a JSON value.');
            return text;
        }
        function string(value, name) {
            if (typeof value !== 'string' || value.length === 0)
                throw new TypeError(name + ' must be a nonempty string.');
            return value;
        }
        function object(value, name) {
            if (value === null || typeof value !== 'object' || Array.isArray(value))
                throw new TypeError(name + ' must be a JSON object.');
            return value;
        }
        function raw(options) {
            object(options, 'Options');
            if (Object.keys(options).some(key => key !== 'raw') ||
                (options.raw !== undefined && typeof options.raw !== 'boolean'))
                throw new TypeError('Options accept only raw: true or false.');
            return options.raw === true;
        }
        function invoke(fields) {
            const reply = parse(request(json(fields)));
            if (reply.error !== undefined) {
                const error = new ErrorType(reply.error);
                if (reply.result !== undefined) error.result = reply.result;
                throw error;
            }
            return reply.value;
        }
        function emit(text, diagnostic) {
            const error = write(text, diagnostic);
            if (error) throw new ErrorType(error);
        }
        function stack(error) {
            return typeof error.stack === 'string' ? error.stack.split('\n')
                .filter(line => !line.includes('@messenger-tool:///runtime.js:')).join('\n') : '';
        }
        function inspect(value) {
            try {
                if (value instanceof ErrorType) {
                    const frames = stack(value);
                    return String(value) + (frames ? '\n' + frames : '');
                }
                if (value === null || typeof value !== 'object') return String(value);
                const ancestors = [];
                return stringify(value, function(key, item) {
                    if (item instanceof ErrorType) return inspect(item);
                    if (typeof item === 'bigint') return String(item) + 'n';
                    if (typeof item === 'undefined' || typeof item === 'function' || typeof item === 'symbol')
                        return String(item);
                    if (item !== null && typeof item === 'object') {
                        while (ancestors.length && ancestors[ancestors.length - 1] !== this) ancestors.pop();
                        if (ancestors.includes(item)) return '[Circular]';
                        ancestors.push(item);
                    }
                    return item;
                }) ?? String(value);
            } catch (_) { return '[Uninspectable]'; }
        }
        function format(values) {
            if (!values.length) return '';
            let used = 1;
            const first = typeof values[0] === 'string' && values.length > 1
                ? values[0].replace(/%[%sdifoO]/g, specifier => {
                    if (specifier === '%%') return '%';
                    if (used === values.length) return specifier;
                    const value = values[used++];
                    try {
                        switch (specifier) {
                            case '%s': return String(value);
                            case '%d': return String(Number(value));
                            case '%i': return String(parseInt(value, 10));
                            case '%f': return String(parseFloat(value));
                            default: return inspect(value);
                        }
                    } catch (_) { return inspect(value); }
                }) : inspect(values[0]);
            return [first, ...values.slice(used).map(inspect)].join(' ');
        }
        const log = (...values) => emit(format(values), true);
        // One provider's operations. Every request names its provider, so Noodle authorizes each on its own.
        const bind = provider => Object.freeze({
            tools: () => invoke({provider, action: 'tools'}),
            inspect: name => invoke({provider, action: 'inspect', tool: string(name, 'Tool name')}),
            call: (name, input = {}, options = {}) => invoke({provider, action: 'call',
                tool: string(name, 'Tool name'), arguments: object(input, 'Arguments'), raw: raw(options)}),
            resources: () => invoke({provider, action: 'resources'}),
            readResource: (uri, options = {}) => invoke({provider, action: 'read-resource',
                uri: string(uri, 'Resource URI'), raw: raw(options)})
        });
        const named = provider => bind(string(provider, 'Provider'));
        const unbound = () => { throw new ErrorType('This script is not bound to one provider. Use tools.call(provider, name, input), or run it with messenger tool PROVIDER --run.'); };
        Object.defineProperties(globalThis, {
            tools: { value: Object.freeze({
                providers: () => invoke({action: 'providers'}),
                provider: named,
                list: provider => named(provider).tools(),
                inspect: (provider, name) => named(provider).inspect(name),
                call: (provider, name, input = {}, options = {}) => named(provider).call(name, input, options)
            }) },
            mcp: typeof boundProvider === 'string'
                ? { value: bind(boundProvider) }
                : { get: unbound },
            print: { value: value => emit(json(value), false) },
            console: { value: Object.freeze({
                log, info: log, debug: log, warn: log, error: log,
                dir: value => emit(inspect(value), true),
                trace: (...values) => {
                    const frames = stack(new ErrorType());
                    emit('Trace' + (values.length ? ': ' + format(values) : '') + (frames ? '\n' + frames : ''), true);
                },
                assert: (condition, ...values) => {
                    if (!condition) emit('Assertion failed' + (values.length ? ': ' + format(values) : ''), true);
                }
            }) }
        });
    })(__mcpRequest, __mcpWrite, __mcpProvider);
    """#
}
