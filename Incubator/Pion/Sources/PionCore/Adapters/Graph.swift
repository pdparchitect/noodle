import Foundation
import NoodleCore
import NoodleToolConnections

/// What the Microsoft Graph tools share. Each account is one tenant, signed in as an admin; see Entra.
enum Graph {
    /// Graph wraps every list.
    struct List<Item: Decodable>: Decodable { let value: [Item] }

    /// A value as an OData string literal: quoted, with its quotes doubled.
    static func literal(_ value: String, _ name: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ServiceError.input("Give \(name).")
        }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// How many items, between 1 and `maximum`.
    static func limit(_ value: Int?, default fallback: Int, maximum: Int) throws -> String {
        let limit = value ?? fallback
        guard (1...maximum).contains(limit) else { throw ServiceError.input("Ask for between 1 and \(maximum).") }
        return String(limit)
    }

    /// A user named by its object ID or user principal name, as Graph's paths take it.
    static func user(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { throw ServiceError.input("Give the user's object ID or user principal name.") }
        return value
    }

    /// "#microsoft.graph.directoryRole" → "directoryRole".
    static func kind(_ type: String?) -> String? { type?.split(separator: ".").last.map(String.init) }
}
