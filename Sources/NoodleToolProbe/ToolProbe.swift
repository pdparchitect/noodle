import Foundation
import NoodleCore
@_spi(ToolProbe) import NoodleMCP

/// A developer's tool probe: runs one of an app's catalogue tools against its real service with the sign-in or key
/// that app keeps, through the same tool connection service the app uses, so a change can be tried without
/// rebuilding the app and asking an agent. Each app has a small program that hands it its own catalogue and adapters;
/// the apps never include it.
///
///     <probe> <entry> [--value key=value]… [--account id] [--namespace id] [--json] (--tools | <tool> [arguments])
///
/// `entry` is a catalogue tool's name or ID. Each `--value` fills one of its fields, as the add form does; a field
/// left out takes the form's example, which is enough where it only names something the sign-in keeps, such as a
/// client ID. `--account` picks the saved item by the connection's ID when several could match; `--namespace`
/// reads another build's items, such as a development build's; `--json` prints the structured result too.
///
/// macOS asks before each saved item is read: answer Allow, never Always Allow, which would let any script read it
/// silently. Nothing secret is printed or written, nothing the app keeps is changed, and a sign-in whose access token
/// has expired is renewed only where that leaves the app's own refresh token valid.
public enum ToolProbe {
    struct Failure: LocalizedError { let description: String; var errorDescription: String? { description } }

    public static func main(arguments: [String], entries: [ToolDefinition], adapters: [String: any ToolConnectionAdapter],
                            namespace: String) async -> Int32 {
        do {
            try await run(arguments: arguments, entries: entries, adapters: adapters, namespace: namespace)
            return 0
        } catch {
            FileHandle.standardError.write(Data("tool probe: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func run(arguments: [String], entries: [ToolDefinition], adapters: [String: any ToolConnectionAdapter],
                    namespace defaultNamespace: String) async throws {
        var rest = arguments[...], positional: [String] = [], values: [String: String] = [:]
        var account: UUID?, namespace = defaultNamespace, listTools = false, json = false
        while let next = rest.popFirst() {
            switch next {
            case "--value":
                guard let pair = rest.popFirst(), let equals = pair.firstIndex(of: "=") else { throw Failure(description: "--value takes key=value.") }
                values[String(pair[..<equals])] = String(pair[pair.index(after: equals)...])
            case "--account":
                guard let id = rest.popFirst().flatMap(UUID.init(uuidString:)) else { throw Failure(description: "--account takes a connection's ID.") }
                account = id
            case "--namespace": namespace = rest.popFirst() ?? namespace
            case "--tools": listTools = true
            case "--json": json = true
            default: positional.append(next)
            }
        }
        guard let name = positional.first, listTools || positional.count >= 2 else {
            throw Failure(description: "Usage: <entry> [--value key=value]… [--account id] [--namespace id] [--json] (--tools | <tool> [arguments])")
        }
        guard let entry = entries.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }) else {
            throw Failure(description: "The catalogue has no tool called \(name). It has: " + entries.map(\.name).sorted().joined(separator: ", "))
        }
        // The service finds a tool's sign-in settings in the catalogue by its address, as in the app.
        ToolCatalog.use(entries)
        guard case .connection(let configuration) = entry.configuration else { throw Failure(description: "\(entry.name) has no connection.") }
        // A client ID comes from the sign-in made with it, and is the one the service checks the sign-in against.
        let clientField = configuration.oauthClientField
        for field in configuration.fields where values[field.key] == nil && field.key != clientField {
            values[field.key] = field.placeholder
            FileHandle.standardError.write(Data("No --value \(field.key)=…; using \(field.placeholder).\n".utf8))
        }
        if let clientField, values[clientField] == nil { values[clientField] = configuration.fields.first { $0.key == clientField }?.placeholder }
        let probe = ToolConnectionProbe(namespace: namespace)
        await probe.useAdapters(adapters)
        let draft = try entry.makeConnection(name: "Probe", values: values)
        // A tool that needs no sign-in or key has nothing saved to find.
        if !draft.keepsSecret && !ToolConnectionService.signsInThroughBrowser(draft) {
            return try await call(probe, draft, positional: positional, listTools: listTools, json: json)
        }
        guard let saved = try probe.saved(for: draft, id: account) else {
            throw Failure(description: "Nothing saved under \(namespace) was given for \(draft.endpoint.absoluteString). "
                          + "Connect \(entry.name) in the app first, or check the --value fields.")
        }
        FileHandle.standardError.write(Data("Using the saved item for connection \(saved.id.uuidString.lowercased()).\n".utf8))
        if let clientField, let clientID = saved.clientID { values[clientField] = clientID }
        let connection = try entry.makeConnection(id: saved.id, name: "Probe", values: values)
        try await call(probe, connection, positional: positional, listTools: listTools, json: json)
    }

    static func call(_ probe: ToolConnectionProbe, _ connection: ToolConnection, positional: [String], listTools: Bool, json: Bool) async throws {
        let request = MCPBridgeRequest(session: "", connectionID: connection.id, action: listTools ? .tools : .call,
                                       tool: listTools ? nil : positional[1], arguments: Data((positional.count > 2 ? positional[2] : "{}").utf8))
        let data = try await probe.perform(request, connection: connection)
        guard !listTools else { return print(String(decoding: data, as: UTF8.self)) }
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        print((result["isError"] as? Bool == true ? "ERROR: " : "") + text)
        if json, let structured = result["structuredContent"] {
            print(String(decoding: try JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        }
    }
}
