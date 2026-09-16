import Foundation
import JavaScriptCore
import NoodleCore

/// A fresh JavaScriptCore context with only JSON bridge operations and output.
/// The CLI owns the process deadline, including time spent in JavaScript loops.
public enum MCPScript {
    public static let maxSourceBytes = 1_048_576
    public static let maxCalls = 100
    public static let maxOutputBytes = 8 * 1_048_576
    public typealias Perform = (MCPBridgeAction, String?, Data?, String?, Bool) throws -> Data
    public typealias Output = (Data, Bool) throws -> Void

    public static func run(_ source: String, sourceURL: URL? = nil,
                           perform: @escaping Perform, output: @escaping Output) throws {
        try run(source, sourceURL: sourceURL, maxCalls: maxCalls, maxOutputBytes: maxOutputBytes,
                perform: perform, output: output)
    }

    static func run(_ source: String, sourceURL: URL? = nil, maxCalls: Int, maxOutputBytes: Int,
                    perform: @escaping Perform, output: @escaping Output) throws {
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
                      let name = fields["action"] as? String, let action = MCPBridgeAction(rawValue: name) else {
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
                let result = try perform(action, fields["tool"] as? String, arguments, fields["uri"] as? String,
                                         fields["raw"] as? Bool ?? false)
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
        context.setObject(request, forKeyedSubscript: "__mcpRequest" as NSString)
        context.setObject(write, forKeyedSubscript: "__mcpWrite" as NSString)
        context.evaluateScript(bootstrap, withSourceURL: URL(string: "mcpshim:///runtime.js"))
        if let exception = context.exception { throw failure(exception.toString() ?? "JavaScript setup failed.") }
        let promise = context.objectForKeyedSubscript("Promise")
        let scriptURL = sourceURL ?? URL(string: "mcpshim:///eval.js")!
        let result = context.evaluateScript(source, withSourceURL: scriptURL)
        if let terminalError { throw terminalError }
        if let exception = context.exception {
            let message = exception.toString() ?? "JavaScript failed."
            let stack = exception.isObject ? exception.forProperty("stack")?.toString() ?? "" : ""
            let frames = stack.components(separatedBy: "\n").filter {
                !$0.isEmpty && $0 != "undefined" && !$0.contains("@mcpshim:///runtime.js:")
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
    ((request, write) => {
        delete globalThis.__mcpRequest;
        delete globalThis.__mcpWrite;
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
                .filter(line => !line.includes('@mcpshim:///runtime.js:')).join('\n') : '';
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
        Object.defineProperties(globalThis, {
            mcp: { value: Object.freeze({
                tools: () => invoke({action: 'tools'}),
                inspect: name => invoke({action: 'inspect', tool: string(name, 'Tool name')}),
                call: (name, input = {}, options = {}) => invoke({action: 'call',
                    tool: string(name, 'Tool name'), arguments: object(input, 'Arguments'), raw: raw(options)}),
                resources: () => invoke({action: 'resources'}),
                readResource: (uri, options = {}) => invoke({action: 'read-resource',
                    uri: string(uri, 'Resource URI'), raw: raw(options)})
            }) },
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
    })(__mcpRequest, __mcpWrite);
    """#
}
