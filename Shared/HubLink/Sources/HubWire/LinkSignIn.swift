import Foundation

/// A sign-in field on the page of a browser someone watches live, for the device to offer its own.
public struct LinkSignInField: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case username, email, password
        case newPassword = "new-password"
        case oneTimeCode = "one-time-code"
    }
    public var kind: Kind
    /// What the page calls the field. The page wrote it, so it is never the only thing saying what goes in.
    public var label: String?
    /// How many boxes a code is split across, one character in each.
    public var length: Int?

    public init(kind: Kind, label: String? = nil, length: Int? = nil) {
        self.kind = kind
        self.label = label
        self.length = length
    }
}

/// The sign-in fields of the page someone watches live, found once as they asked. Answers `signInForm`.
public struct LinkSignInForm: Codable, Equatable, Sendable {
    /// Names this form to `fillSignIn`.
    public var token: UUID
    /// The site whose fields they are; empty for a frame with no site of its own.
    public var host: String
    /// The site of the page shown, which differs from `host` for a form in a frame of another site.
    public var pageHost: String
    /// Whether the fields' page was loaded over HTTPS.
    public var secure: Bool
    /// Whether the fields are in a frame of another site than the page.
    public var crossOrigin: Bool
    /// The fields, leaving out kinds this app does not know yet.
    public var fields: [LinkSignInField]

    public init(token: UUID, host: String, pageHost: String, secure: Bool, crossOrigin: Bool, fields: [LinkSignInField]) {
        self.token = token
        self.host = host
        self.pageHost = pageHost
        self.secure = secure
        self.crossOrigin = crossOrigin
        self.fields = fields
    }

    private enum CodingKeys: String, CodingKey { case token, host, pageHost, secure, crossOrigin, fields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(UUID.self, forKey: .token)
        host = try c.decode(.host, or: "")
        pageHost = try c.decode(.pageHost, or: "")
        secure = try c.decode(.secure, or: false)
        crossOrigin = try c.decode(.crossOrigin, or: true)
        fields = try c.decode([Lossy<LinkSignInField>].self, forKey: .fields).compactMap(\.value)
    }

    /// One element of a list, or nil for one this app cannot read.
    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

/// What someone watching a browser live typed or picked from their passwords, sent once to fill the
/// form `signInForm` found. The Hub hands it to the browser and keeps nothing; descriptions and mirrors
/// of it leave the values out, so they cannot reach a log.
public struct LinkSignInFill: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The live view's conversation and attachment, as `openSurface` named them.
    public var conversationID: UUID
    public var attachmentID: UUID
    public var token: UUID
    /// Goes into username and email fields.
    public var username: String?
    public var password: String?
    public var newPassword: String?
    public var oneTimeCode: String?
    /// Submits the form once filled.
    public var submit: Bool

    public init(conversationID: UUID, attachmentID: UUID, token: UUID, username: String? = nil, password: String? = nil,
                newPassword: String? = nil, oneTimeCode: String? = nil, submit: Bool = false) {
        self.conversationID = conversationID
        self.attachmentID = attachmentID
        self.token = token
        self.username = username
        self.password = password
        self.newPassword = newPassword
        self.oneTimeCode = oneTimeCode
        self.submit = submit
    }

    private enum CodingKeys: String, CodingKey {
        case conversationID, attachmentID, token, username, password, newPassword, oneTimeCode, submit
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = try c.decode(UUID.self, forKey: .conversationID)
        attachmentID = try c.decode(UUID.self, forKey: .attachmentID)
        token = try c.decode(UUID.self, forKey: .token)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        newPassword = try c.decodeIfPresent(String.self, forKey: .newPassword)
        oneTimeCode = try c.decodeIfPresent(String.self, forKey: .oneTimeCode)
        submit = try c.decode(.submit, or: false)
    }

    public var description: String {
        "LinkSignInFill(conversationID: \(conversationID), attachmentID: \(attachmentID), token: \(token), values: redacted, submit: \(submit))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["conversationID": conversationID, "attachmentID": attachmentID, "token": token, "submit": submit],
               displayStyle: .struct)
    }
}

/// What a person types or picks from their passwords to sign in to a page they watch live, on the
/// iPhone and on the Mac alike. Only the fields the page has are offered, and only what was entered goes to it.
public struct LinkSignInEntry: Equatable, Sendable {
    public var username = ""
    public var password = ""
    public var newPassword = ""
    public var oneTimeCode = ""
    public var submit = false

    public init() {}

    public func fill(_ form: LinkSignInForm, conversationID: UUID, attachmentID: UUID) -> LinkSignInFill {
        let kinds = Set(form.fields.map(\.kind))
        func value(_ text: String, _ wanted: LinkSignInField.Kind...) -> String? {
            !text.isEmpty && !kinds.isDisjoint(with: wanted) ? text : nil
        }
        return LinkSignInFill(conversationID: conversationID, attachmentID: attachmentID, token: form.token,
                              username: value(username, .username, .email), password: value(password, .password),
                              newPassword: value(newPassword, .newPassword),
                              oneTimeCode: value(oneTimeCode.trimmingCharacters(in: .whitespaces), .oneTimeCode), submit: submit)
    }

    public var isEmpty: Bool { username.isEmpty && password.isEmpty && newPassword.isEmpty && oneTimeCode.isEmpty }
}

extension LinkSignInForm {
    /// Whether the page has a field of any of `kinds`.
    public func has(_ kinds: LinkSignInField.Kind...) -> Bool { fields.contains { kinds.contains($0.kind) } }

    /// The field to type in first: the username for an email field, as both go in one.
    public var firstField: LinkSignInField.Kind? { fields.first.map { $0.kind == .email ? .username : $0.kind } }
}
