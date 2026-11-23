import CryptoKit
import Foundation
import NoodleCore
import NoodleToolConnections

/// Google Cloud Containment: acting on one organisation, folder or project to contain an incident, through a sign-in of
/// its own, kept apart from Google Cloud Audit's so the audit sign-in never holds the cloud-platform scope. It signs in
/// as a person, as Audit does, never as a service account. Every resource it acts on is checked for its type and to lie
/// inside the account's scope before anything changes; what cuts off or restores access, stops a VM or opens a bucket
/// again waits for the champion's approval. Each change is conditional where Google allows it, on the etag, fingerprint
/// or metageneration Pion read, and what Pion makes carries its name and description, so an undo removes only Pion's own.
extension GoogleCloud {
    public static let containment = ToolDefinition(
        id: "ee0b4a89-e432-4f01-a4a2-6779eb39a7cd", name: "Google Cloud Containment",
        summary: "Disable a service account or one of its keys, remove one member from an IAM role, enforce public access prevention on a bucket, and snapshot, stop or isolate a VM, inside one organisation, folder or project.",
        defaultInstructions: """
        Use Google Cloud Containment to contain an incident inside the organisation, folder or project the account is \
        set to. Find what to act on with Google Cloud Audit first, and give each resource by its full name. \
        disable-sa-key turns off one user-managed service account key, ending what uses it, and enable-sa-key turns it \
        back on; tokens already minted with the key are not revoked and last until they expire, usually an hour. \
        disable-service-account stops a service account authenticating at all, every key and workload of it, and \
        enable-service-account restores it as it was. remove-iam-member takes one member out of one role binding of a \
        project, folder or organisation, keeping every other member and condition, and only if the policy has not \
        changed since Pion read it; give condition when the member holds the role in more than one binding, none for the \
        one without a condition. It refuses the account signed in, which it checks with Google is the account entered, \
        its domain, and the last owner unless told to; access \
        through a group, another role, or a folder or organisation above stays, so check with Google Cloud Audit's \
        iam-policies. enforce-public-access-prevention stops a bucket being reached by allUsers or allAuthenticatedUsers, \
        returning the setting before and the metageneration after; revert-public-access-prevention takes the bucket, \
        that setting and that metageneration as you give them, copied from enforce's result, and acts only while the \
        bucket is at that metageneration: it cannot tell who made the change, so give exactly what enforce returned. \
        snapshot-disks copies a VM's \
        persistent disks as evidence. stop-instance stops a VM, losing what is only in its memory: give snapshotFirst to \
        snapshot its disks first. isolate-instance adds deny-all inbound and outbound firewall rules at the highest \
        priority, named pion-isolate and a digest of the VM's ID, targeting a network tag of the same name, then adds the \
        tag to the VM, saying isolated only once Compute Engine confirms each change, and pending, with the operations \
        to read, until then; connections already open may continue until they close, the VM can still reach its metadata \
        server, and allow rules in hierarchical firewall policies above the network are evaluated first, so tell the \
        champion to check those. unisolate-instance removes only that tag and those rules, after checking each is Pion's. \
        Compute Engine works in the background: read each operation returned with operation-status until it is DONE. \
        disable-sa-key, enable-sa-key, disable-service-account, enable-service-account, remove-iam-member, \
        enforce-public-access-prevention, revert-public-access-prevention, stop-instance, isolate-instance and \
        unisolate-instance are held for the champion's approval: give the exact resource, and in --approval-reason why, \
        the expected effect and how to undo it, with the Investigation as --approval-conversation. Every result says \
        exactly what changed, including when only part of a change was made, and how to undo it; record it as evidence. \
        This tool cannot grant access or delete anything. To end a person's stolen gcloud sign-in, use Google Workspace \
        Containment's revoke-token. Run check-access when something is refused, and tell the champion exactly what it \
        says to add to the Pion Containment role.
        """,
        iconName: "google-cloud",
        configuration: .connection(.init(endpointTemplate: "https://googleapis.com",
            fields: [ToolField(key: "level", title: "Scope", placeholder: "organizations", kind: .choice([
                         .init(value: "organizations", title: "Organization"), .init(value: "folders", title: "Folder"),
                         .init(value: "projects", title: "Project")])),
                     ToolField(key: "id", title: "Organization, folder or project ID", placeholder: "123456789012", kind: .identifier),
                     ToolField(key: "clientID", title: "Client ID", placeholder: "1234-abc.apps.googleusercontent.com", kind: .identifier),
                     ToolField(key: "signer", title: "Account that signs in", placeholder: "pion-containment@example.com", kind: .text)],
            // IAM, Resource Manager's policy changes and Compute Engine's actions take no narrower scope, so only this
            // tool asks for all of Google Cloud, at a sign-in of its own; the custom role of the account that signs in
            // is what limits it. The email scope lets it ask Google which account signed in, and so check the one
            // entered before removing access.
            oauth: .google(scopes: [platformScope, emailScope], clients: []),
            oauthClientField: "clientID", adapter: "google-cloud-containment")),
        setup: containmentSetup)

    static let platformScope = "https://www.googleapis.com/auth/cloud-platform"
    static let emailScope = "https://www.googleapis.com/auth/userinfo.email"

    static let containmentSetup = [
        "In the Google Cloud project that holds your Google Cloud Audit client, also enable the [Identity and Access Management (IAM) API](https://console.cloud.google.com/apis/library/iam.googleapis.com), the [Cloud Resource Manager API](https://console.cloud.google.com/apis/library/cloudresourcemanager.googleapis.com), the [Compute Engine API](https://console.cloud.google.com/apis/library/compute.googleapis.com) and the [Cloud Storage API](https://console.cloud.google.com/apis/library/storage-api.googleapis.com). Pion's requests count against this project.",
        "Under Google Auth Platform's [Data Access](https://console.cloud.google.com/auth/scopes), add the scopes `https://www.googleapis.com/auth/cloud-platform` and `https://www.googleapis.com/auth/userinfo.email`, by which Pion asks Google which account signed in. Only Google Cloud Containment asks for cloud-platform, at a sign-in of its own; Google Cloud Audit keeps its narrower scopes.",
        "Paste that same iOS client's **Client ID** here, or create one under [Clients](https://console.cloud.google.com/auth/clients) of the type **iOS** with the bundle ID `com.pdparchitect.pion` (`com.pdparchitect.pion.local` for Pion Dev).",
        "In [Roles](https://console.cloud.google.com/iam-admin/roles), on the organisation, choose **Create role**, name it Pion Containment and add only these permissions: \(containmentPermissions.map { "`\($0)`" }.joined(separator: ", ")). For a project's account, make it on the project and leave out the folder and organisation ones. Leave out any whose action you do not want agents to have: setIamPolicy lets whoever holds it change any binding, granting as well as removing, though Pion only removes.",
        "Grant that role, and nothing else, to a Google account kept for containment, on the organisation, folder or project to act on. Never sign in with an Owner, Editor or Security Admin: the cloud-platform scope lets this sign-in do whatever the account can, so its role is what limits it.",
        "Set Scope and its ID as for Google Cloud Audit, and **Account that signs in** to that account's email: before removing access, Pion asks Google which account signed in, refuses if it is not this one, and refuses to remove that account's own access. Choose **Add & Connect**, sign in as that account, and ask an agent to run check-access.",
    ]

    /// Every permission the containment operations use, for the custom role its setup makes: reads that check each
    /// target and its place first, then only the changes the operations make.
    static let containmentPermissions = [
        "resourcemanager.projects.get", "resourcemanager.folders.get",
        "resourcemanager.projects.getIamPolicy", "resourcemanager.projects.setIamPolicy",
        "resourcemanager.folders.getIamPolicy", "resourcemanager.folders.setIamPolicy",
        "resourcemanager.organizations.getIamPolicy", "resourcemanager.organizations.setIamPolicy",
        "iam.serviceAccounts.get", "iam.serviceAccounts.disable", "iam.serviceAccounts.enable",
        "iam.serviceAccountKeys.get", "iam.serviceAccountKeys.disable", "iam.serviceAccountKeys.enable",
        "storage.buckets.get", "storage.buckets.update",
        "compute.instances.get", "compute.instances.stop", "compute.instances.setTags",
        "compute.disks.createSnapshot", "compute.snapshots.create", "compute.snapshots.setLabels",
        "compute.firewalls.get", "compute.firewalls.create", "compute.firewalls.delete", "compute.networks.updatePolicy",
        "compute.zoneOperations.get", "compute.regionOperations.get", "compute.globalOperations.get",
    ]

    public static let containmentAdapter = OperationAdapter(operations: [
        DisableKey(), EnableKey(), DisableServiceAccount(), EnableServiceAccount(), RemoveIAMMember(), EnforcePublicAccessPrevention(),
        RevertPublicAccessPrevention(), SnapshotDisks(), StopInstance(), IsolateInstance(), UnisolateInstance(), ComputeOperationStatus(),
        ContainmentCheckAccess(),
    ])

    // MARK: Hosts

    /// The only Google hosts containment reaches. The sign-in's token is good on any googleapis.com host its scope
    /// allows, so each request names one of these rather than a host from a value given or read.
    enum ContainmentHost: String, CaseIterable {
        case iam = "iam.googleapis.com", resourceManager = "cloudresourcemanager.googleapis.com"
        case compute = "compute.googleapis.com", storage = "storage.googleapis.com"
        /// Google's OpenID Connect user info, for which account signed in.
        case identity = "openidconnect.googleapis.com"
    }

    static func on(_ host: ContainmentHost, _ service: ServiceClient) throws -> ServiceClient { try service.at(host: host.rawValue) }

    // MARK: Refusals

    static func containmentNeed(_ title: String, api: String, apiID: String, _ permissions: [String]) -> Need {
        Need(title: title, api: api, apiID: apiID, scope: platformScope,
             role: "the Pion Containment custom role, with \(permissions.joined(separator: ", ")),")
    }

    static let placeNeed = containmentNeed("The resource's place", api: "Cloud Resource Manager API", apiID: "cloudresourcemanager.googleapis.com",
                                           ["resourcemanager.projects.get", "resourcemanager.folders.get"])
    static let keyNeed = containmentNeed("Service account keys", api: "Identity and Access Management (IAM) API", apiID: "iam.googleapis.com",
                                         ["iam.serviceAccounts.get", "iam.serviceAccountKeys.get", "iam.serviceAccountKeys.disable", "iam.serviceAccountKeys.enable"])
    static let accountNeed = containmentNeed("Service accounts", api: "Identity and Access Management (IAM) API", apiID: "iam.googleapis.com",
                                             ["iam.serviceAccounts.get", "iam.serviceAccounts.disable", "iam.serviceAccounts.enable"])
    static func policyNeed(_ kind: String) -> Need {
        containmentNeed("The IAM policy", api: "Cloud Resource Manager API", apiID: "cloudresourcemanager.googleapis.com",
                        ["resourcemanager.\(kind).getIamPolicy", "resourcemanager.\(kind).setIamPolicy"])
    }
    static let bucketNeed = containmentNeed("The bucket", api: "Cloud Storage API", apiID: "storage-api.googleapis.com", ["storage.buckets.get", "storage.buckets.update"])
    static let instanceNeed = containmentNeed("The VM", api: "Compute Engine API", apiID: "compute.googleapis.com",
                                              ["compute.instances.get", "compute.instances.stop", "compute.instances.setTags"])
    static let snapshotNeed = containmentNeed("Snapshots", api: "Compute Engine API", apiID: "compute.googleapis.com",
                                              ["compute.disks.createSnapshot", "compute.snapshots.create", "compute.snapshots.setLabels"])
    static let firewallNeed = containmentNeed("Firewall rules", api: "Compute Engine API", apiID: "compute.googleapis.com",
                                              ["compute.firewalls.get", "compute.firewalls.create", "compute.firewalls.delete", "compute.networks.updatePolicy"])
    static let operationNeed = containmentNeed("Compute Engine operations", api: "Compute Engine API", apiID: "compute.googleapis.com",
                                               ["compute.zoneOperations.get", "compute.regionOperations.get", "compute.globalOperations.get"])

    /// Why a change failed: what to change when Google refused it, or unknown when Google gave no clear answer, as a
    /// change it could not answer may still have been made.
    struct Failure { let text: String; let unsure: Bool }

    static func failure(_ error: Error, _ what: String, _ need: Need, _ own: String) -> Failure {
        var unsure = !(error is ServiceError)
        if case ServiceError.status(let code, _) = error, code >= 500 { unsure = true }
        if unsure {
            return Failure(text: "Google gave no clear answer to \(what) (\(error.localizedDescription)), so it may or may not have been done: read it again before deciding", unsure: true)
        }
        let said = fix(for: error, need, on: own).map { "Google refused it: \($0)" } ?? error.localizedDescription
        return Failure(text: "\(what) failed: \(said)", unsure: false)
    }

    /// A change that stopped, said precisely: what was done before it, what failed, and how to undo what was done.
    static func stopped(_ done: [String], _ failure: Failure, undo: String) -> ServiceError {
        if failure.unsure {
            return .input((done.isEmpty ? "" : "Done before it: \(done.joined(separator: "; ")). ") + failure.text + "." + (undo.isEmpty ? "" : " " + undo))
        }
        return .input(done.isEmpty ? "Nothing was changed: \(failure.text)." : "Only partly done: \(done.joined(separator: "; ")); then \(failure.text). \(undo)")
    }

    /// A change sent to Google, its refusal or silence said as `stopped` does.
    static func change<Value>(_ what: String, _ need: Need, _ own: String, done: [String] = [], undo: String = "",
                              _ body: () async throws -> Value) async throws -> Value {
        do { return try await body() } catch { throw stopped(done, failure(error, what, need, own), undo: undo) }
    }

    /// Text Google gave that anyone may have written, such as an error's message or a policy's condition, on one short
    /// line and marked as Google's, so nothing in it reads as Pion's own words.
    static func fromGoogle(_ text: String?, limit: Int = 200) -> String {
        let line = (text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let short = line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        return "[from Google: \"\(short.replacingOccurrences(of: "\"", with: "'"))\"]"
    }

    /// `value` when it matches `pattern` whole, so only values of a known shape are repeated.
    static func shaped(_ value: String?, _ pattern: String) -> String? {
        guard let value, value.range(of: "^(?:" + pattern + ")$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func digest(_ value: String, _ length: Int) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
    }

    // MARK: Names

    static let projectPattern = #"(?:[a-z][a-z0-9.-]{0,61}[a-z0-9]:)?[a-z][a-z0-9-]{4,28}[a-z0-9]"#
    static let numberPattern = #"[0-9]{1,20}"#
    static let zonePattern = #"[a-z]+-[a-z]+[0-9]+-[a-z]"#
    static let regionPattern = #"[a-z]+-[a-z]+[0-9]+"#
    static let computeNamePattern = #"[a-z](?:[-a-z0-9]{0,61}[a-z0-9])?"#
    static let operationPattern = #"[A-Za-z0-9][A-Za-z0-9_-]{0,127}"#

    /// A project, folder or organisation, by the name Resource Manager takes for it.
    enum Place: Equatable {
        case project(String), folder(String), organization(String)

        var name: String {
            switch self {
            case .project(let id): "projects/\(id)"
            case .folder(let id): "folders/\(id)"
            case .organization(let id): "organizations/\(id)"
            }
        }
        var path: [String] { name.split(separator: "/").map(String.init) }
        /// Resource Manager's word for its kind, as its permissions name it.
        var kind: String {
            switch self { case .project: "projects"; case .folder: "folders"; case .organization: "organizations" }
        }
        /// gcloud's command for its policy, to say how to grant again what was removed.
        var gcloud: String {
            switch self {
            case .project(let id): "gcloud projects add-iam-policy-binding \(id)"
            case .folder(let id): "gcloud resource-manager folders add-iam-policy-binding \(id)"
            case .organization(let id): "gcloud organizations add-iam-policy-binding \(id)"
            }
        }
    }

    /// A project, folder or organisation as given, such as projects/kestrel-prod or
    /// //cloudresourcemanager.googleapis.com/folders/123.
    static func place(_ value: String) throws -> Place {
        var name = value.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("//cloudresourcemanager.googleapis.com/") { name.removeFirst("//cloudresourcemanager.googleapis.com/".count) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 {
            if parts[0] == "projects", shaped(parts[1], projectPattern) != nil { return .project(parts[1]) }
            if parts[0] == "folders", shaped(parts[1], numberPattern) != nil { return .folder(parts[1]) }
            if parts[0] == "organizations", shaped(parts[1], numberPattern) != nil { return .organization(parts[1]) }
        }
        throw ServiceError.input("Give the resource as projects/PROJECT-ID, folders/NUMBER or organizations/NUMBER.")
    }

    struct ManagedProject: Decodable { let name: String?, parent: String?, projectId: String? }
    struct ManagedFolder: Decodable { let name: String?, parent: String? }

    /// `place` by its canonical name, a project by its ID, once established as inside the account's scope: a project's
    /// account acts on that project alone; an organisation's or folder's, on itself and what Resource Manager says lies
    /// under it, parent by parent. Anything not established as inside is refused before anything is changed.
    static func inside(_ place: Place, _ service: ServiceClient) async throws -> Place {
        let scope = try GoogleCloud.scope(service), own = "\(scope.level)/\(scope.id)"
        let manager = try on(.resourceManager, service)
        func refuse(_ why: String) -> ServiceError {
            .input("Nothing was changed: \(place.name) \(why). This tool acts only inside \(own), the account's scope; set the account's Scope, in Settings › Tools, to the organisation or a folder that holds it.")
        }
        func lookUp<Value: Decodable>(_ path: [String], as type: Value.Type) async throws -> Value {
            do {
                return try await read(placeNeed, own) { try await manager.get(path, as: Value.self) }
            } catch ServiceError.notFound {
                let what = path.dropFirst().joined(separator: "/")
                throw refuse(what == place.name ? "could not be found, so whether it is inside the scope is unknown"
                                                : "has a parent, \(what), that could not be found, so whether it is inside the scope is unknown")
            }
        }
        /// Up the parents from `start`, at most a project's folders deep, until the scope is reached.
        func walk(from start: String) async throws {
            var current = start, chain: [String] = []
            for _ in 0..<12 {
                if current == own { return }
                chain.append(current)
                guard current.hasPrefix("folders/") else { break }
                let folder = try await lookUp(["v3"] + current.split(separator: "/").map(String.init), as: ManagedFolder.self)
                guard let parent = shaped(folder.parent, #"(folders|organizations)/[0-9]{1,20}"#) else {
                    throw refuse((current == place.name ? "has no parent Google named" : "has a parent, \(current), whose own parent Google did not name")
                                 + ", so whether it is inside is unknown")
                }
                current = parent
            }
            throw refuse("is not under \(own): above it are \(chain.joined(separator: " › "))")
        }
        switch place {
        case .organization(let id):
            guard scope.level == "organizations", id == scope.id else { throw refuse("is not \(own)") }
            return place
        case .folder(let id):
            if scope.level == "folders", id == scope.id { return place }
            guard scope.level != "projects" else { throw refuse("is a folder, and the account acts on the project \(own) alone") }
            try await walk(from: place.name)
            return place
        case .project(let id):
            if scope.level == "projects", id == scope.id { return place }
            // A project's account is set by its ID; only a number given or set needs Resource Manager to compare them.
            let numbered = { (value: String) in shaped(value, numberPattern) != nil }
            if scope.level == "projects", !numbered(id), !numbered(scope.id) { throw refuse("is not \(own), the only project the account acts on") }
            let project = try await lookUp(["v3", "projects", id], as: ManagedProject.self)
            guard let projectID = shaped(project.projectId, projectPattern),
                  let number = shaped(project.name, "projects/" + numberPattern).map({ String($0.dropFirst("projects/".count)) }) else {
                throw refuse("was read without its ID and number, so whether it is inside is unknown")
            }
            if scope.level == "projects" {
                guard projectID == scope.id || number == scope.id else { throw refuse("is not \(own), the only project the account acts on") }
                return .project(projectID)
            }
            guard let parent = shaped(project.parent, #"(folders|organizations)/[0-9]{1,20}"#) else {
                throw refuse("has no parent Google named, so whether it is inside is unknown")
            }
            try await walk(from: parent)
            return .project(projectID)
        }
    }

    static func own(_ service: ServiceClient) throws -> String {
        let scope = try GoogleCloud.scope(service)
        return "\(scope.level)/\(scope.id)"
    }
}

// MARK: Service accounts

extension GoogleCloud {
    static let accountPattern = #"[a-z0-9][a-z0-9._%+-]{0,99}@[a-z0-9][a-z0-9.-]{0,99}\.gserviceaccount\.com|[0-9]{10,30}"#
    static let keyIDPattern = #"[0-9a-fA-F]{16,64}"#

    /// A service account, or one of its keys, by the name IAM gives it: projects/PROJECT/serviceAccounts/ACCOUNT, by
    /// email or unique ID, then /keys/KEY for a key.
    struct AccountName {
        let project: String, account: String, key: String?
        var accountPath: [String] { ["v1", "projects", project, "serviceAccounts", account] }
        var keyPath: [String]? { key.map { accountPath + ["keys", $0] } }
        var said: String { "projects/\(project)/serviceAccounts/\(account)" + (key.map { "/keys/\($0)" } ?? "") }
    }

    static func accountName(_ value: String, key wanted: Bool) throws -> AccountName {
        var name = value.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("//iam.googleapis.com/") { name.removeFirst("//iam.googleapis.com/".count) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let example = wanted ? "projects/PROJECT-ID/serviceAccounts/EMAIL/keys/KEY-ID" : "projects/PROJECT-ID/serviceAccounts/EMAIL"
        guard parts.count == (wanted ? 6 : 4), parts[0] == "projects", shaped(parts[1], projectPattern) != nil, parts[2] == "serviceAccounts",
              shaped(parts[3].lowercased(), accountPattern) != nil, !wanted || (parts[4] == "keys" && shaped(parts[5], keyIDPattern) != nil) else {
            throw ServiceError.input("Give the \(wanted ? "key" : "service account") by its full name, \(example), as Google Cloud Audit's sa-keys lists it.")
        }
        return AccountName(project: parts[1], account: parts[3].lowercased(), key: wanted ? parts[5] : nil)
    }

    struct ServiceAccount: Decodable { let email: String?, projectId: String?, uniqueId: String?, disabled: Bool? }
    struct AccountKey: Decodable { let keyType: String?, validAfterTime: String?, disabled: Bool? }

    /// The service account, read and checked to be in the project its name gives, which is inside the account's scope.
    static func account(_ name: AccountName, _ service: ServiceClient) async throws -> (account: ServiceAccount, email: String) {
        let own = try own(service)
        _ = try await inside(.project(name.project), service)
        let iam = try on(.iam, service)
        let read = try await GoogleCloud.read(accountNeed, own) { try await iam.get(name.accountPath, as: ServiceAccount.self) }
        guard read.projectId == name.project, let email = shaped(read.email, accountPattern) else {
            throw ServiceError.input("Nothing was changed: Google says \(name.said) belongs to another project than \(name.project), or did not say which, so it is not acted on here. Give it by the name its own project gives it.")
        }
        return (read, email)
    }

    struct KeyInput: Decodable, Sendable { let key: String }
    static let keyInputSchema = JSONSchema.object(["key": .string("The key's full name, projects/PROJECT-ID/serviceAccounts/EMAIL/keys/KEY-ID, as Google Cloud Audit's sa-keys lists it.")],
                                                 required: ["key"])

    /// One key of a service account, read, and turned on or off when it is not already so.
    static func setKey(_ input: KeyInput, disabled: Bool, on service: ServiceClient) async throws -> ServiceResult {
        let own = try own(service)
        let name = try accountName(input.key, key: true)
        let (_, email) = try await account(name, service)
        let iam = try on(.iam, service), path = name.keyPath!
        let before = try await GoogleCloud.read(keyNeed, own) { try await iam.get(path, as: AccountKey.self) }
        let type = shaped(before.keyType, "USER_MANAGED|SYSTEM_MANAGED") ?? "unknown"
        let made = before.validAfterTime.flatMap { try? ServiceInput.time($0) }.map { ", made \($0)" } ?? ""
        guard type != "SYSTEM_MANAGED" else {
            throw ServiceError.input("Nothing was changed: \(name.key!) of \(email) is a key Google manages, which cannot be turned off; disable-service-account stops the account itself.")
        }
        let was = before.disabled == true
        struct Kept: Encodable { let key: String, serviceAccount: String, before: String, after: String, changed: Bool }
        if was == disabled {
            return try ServiceResult(text: "Key \(name.key!) of \(email) is already \(disabled ? "disabled" : "enabled"); nothing was changed.",
                                     structured: Kept(key: name.said, serviceAccount: email, before: was ? "disabled" : "enabled", after: was ? "disabled" : "enabled", changed: false))
        }
        let verb = disabled ? "disable" : "enable"
        _ = try await change("turning key \(name.key!) \(disabled ? "off" : "on")", keyNeed, own) {
            try await iam.data(Array(path.dropLast()) + ["\(path.last!):\(verb)"], method: "POST", body: Data("{}".utf8))
        }
        let after = try? await iam.get(path, as: AccountKey.self)
        let confirmed = after.map { ($0.disabled == true) == disabled }
        let check = confirmed == true ? "" : confirmed == false
            ? " Read again, it is \(disabled ? "still enabled" : "still disabled"): someone may have changed it meanwhile, so check it."
            : " It could not be read again to confirm it, so check it in the console."
        let text = disabled
            ? "Disabled key \(name.key!) of \(email)\(made); it was enabled. Whatever authenticates with it now fails. Tokens already minted with it are not revoked and last until they expire, usually within an hour; other keys of the account, and the account itself, are untouched: disable-service-account stops those.\(check) To undo: enable-sa-key with the same key name turns it back on, as it was; nothing else was changed."
            : "Enabled key \(name.key!) of \(email)\(made); it was disabled, and whatever holds the key, an attacker included if it leaked, can authenticate with it again.\(check) To undo: disable-sa-key with the same key name turns it off again; tokens minted with it meanwhile last until they expire."
        return try ServiceResult(text: text, structured: Kept(key: name.said, serviceAccount: email, before: was ? "disabled" : "enabled",
                                                              after: confirmed == nil ? "unknown" : (after?.disabled == true ? "disabled" : "enabled"), changed: true))
    }

    struct DisableKey: ServiceOperation {
        typealias Input = KeyInput
        static let name = "disable-sa-key"
        static let summary = "Turn off one user-managed service account key, ending whatever authenticates with it, saying when it was made. Tokens already minted with it last until they expire. To undo: enable-sa-key with the same key name turns it back on as it was."
        static let input = GoogleCloud.keyInputSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await GoogleCloud.setKey(input, disabled: true, on: service)
        }
    }

    /// Turning a key back on lets whoever holds it back in, so it waits for approval as turning it off does.
    struct EnableKey: ServiceOperation {
        typealias Input = KeyInput
        static let name = "enable-sa-key"
        static let summary = "Undo disable-sa-key: turn a disabled service account key back on, so whatever holds it, an attacker included if it leaked, can authenticate again. To undo: disable-sa-key with the same key name."
        static let input = GoogleCloud.keyInputSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await GoogleCloud.setKey(input, disabled: false, on: service)
        }
    }

    struct AccountInput: Decodable, Sendable { let serviceAccount: String }
    static let accountInputSchema = JSONSchema.object(["serviceAccount": .string("The service account's full name, projects/PROJECT-ID/serviceAccounts/EMAIL.")],
                                                     required: ["serviceAccount"])

    static func setAccount(_ input: AccountInput, disabled: Bool, on service: ServiceClient) async throws -> ServiceResult {
        let own = try own(service)
        let name = try accountName(input.serviceAccount, key: false)
        let (before, email) = try await account(name, service)
        let iam = try on(.iam, service)
        let was = before.disabled == true
        struct Kept: Encodable { let serviceAccount: String, email: String, before: String, after: String, changed: Bool }
        if was == disabled {
            return try ServiceResult(text: "\(email) is already \(disabled ? "disabled" : "enabled"); nothing was changed.",
                                     structured: Kept(serviceAccount: name.said, email: email, before: was ? "disabled" : "enabled", after: was ? "disabled" : "enabled", changed: false))
        }
        let verb = disabled ? "disable" : "enable"
        _ = try await change("\(disabled ? "disabling" : "enabling") \(email)", accountNeed, own) {
            try await iam.data(Array(name.accountPath.dropLast()) + ["\(name.account):\(verb)"], method: "POST", body: Data("{}".utf8))
        }
        let after = try? await iam.get(name.accountPath, as: ServiceAccount.self)
        let confirmed = after.map { ($0.disabled == true) == disabled }
        let check = confirmed == true ? "" : confirmed == false
            ? " Read again, it is \(disabled ? "still enabled" : "still disabled"): someone may have changed it meanwhile, so check it."
            : " It could not be read again to confirm it, so check it in the console."
        let text = disabled
            ? "Disabled \(email); it was enabled. It can no longer authenticate: every key of it, and every VM, function or job that runs as it, loses its access, which can break those workloads. Its keys, roles and resources are kept.\(check) To undo: enable-service-account restores it as it was, with its enabled keys working again."
            : "Enabled \(email); it was disabled, and its enabled keys, and whatever runs as it, can authenticate again.\(check) To undo: disable-service-account."
        return try ServiceResult(text: text, structured: Kept(serviceAccount: name.said, email: email, before: was ? "disabled" : "enabled",
                                                              after: confirmed == nil ? "unknown" : (after?.disabled == true ? "disabled" : "enabled"), changed: true))
    }

    struct DisableServiceAccount: ServiceOperation {
        typealias Input = AccountInput
        static let name = "disable-service-account"
        static let summary = "Stop a service account authenticating at all: every key of it, and every workload that runs as it, loses its access; its keys, roles and resources are kept. To undo: enable-service-account restores it as it was."
        static let input = GoogleCloud.accountInputSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await GoogleCloud.setAccount(input, disabled: true, on: service)
        }
    }

    /// Restoring an account lets whatever holds its keys back in, so it waits for approval as disabling does.
    struct EnableServiceAccount: ServiceOperation {
        typealias Input = AccountInput
        static let name = "enable-service-account"
        static let summary = "Undo disable-service-account: let a disabled service account authenticate again, with its enabled keys and the workloads that run as it. To undo: disable-service-account."
        static let input = GoogleCloud.accountInputSchema
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            try await GoogleCloud.setAccount(input, disabled: false, on: service)
        }
    }
}

// MARK: IAM policies

extension GoogleCloud {
    static let rolePattern = #"roles/[A-Za-z0-9_.]{1,100}|(projects|organizations)/[a-z0-9.:-]{1,100}/roles/[A-Za-z0-9_.]{1,100}"#
    static let memberPattern = #"(user|serviceAccount|group|domain|deleted:user|deleted:serviceAccount|deleted:group):[^\s"'\\]{1,300}|principal(Set)?://[^\s"'\\]{1,500}|allUsers|allAuthenticatedUsers"#
    /// The roles whose last member an organisation or project cannot lose without losing its administrator.
    static func ownerRoles(_ place: Place) -> [String] {
        switch place {
        case .project: ["roles/owner"]
        case .organization: ["roles/owner", "roles/resourcemanager.organizationAdmin"]
        case .folder: []
        }
    }

    /// The account that signs in, as entered in the account's settings.
    static func signer(_ service: ServiceClient) throws -> String {
        guard let value = try? service.setting("signer"), let email = try? ServiceInput.email(value) else {
            throw ServiceError.input("Nothing was changed: the account has no valid Account that signs in, so Pion cannot tell whether this would remove its own access. Set it to the email of the account that signs in, in Settings › Tools.")
        }
        return email
    }

    struct UserInfo: Decodable { let email: String?; let email_verified: Bool? }

    /// The account Google says the sign-in belongs to, from its OpenID Connect user info, which the email scope
    /// allows. Nil when Google did not say, with why.
    static func signedIn(_ service: ServiceClient) async -> (email: String?, why: String?) {
        do {
            let info = try await on(.identity, service).get(["v1", "userinfo"], as: UserInfo.self)
            guard let given = info.email, let email = try? ServiceInput.email(given) else { return (nil, "Google's answer named no email") }
            // Only an email Google says is verified names the account; one it does not vouch for, or says nothing of, does not.
            guard info.email_verified == true else {
                return (nil, info.email_verified == false ? "Google says the account's email is not verified" : "Google did not say the account's email is verified")
            }
            return (email, nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    /// The account entered, once Google confirms the sign-in is that account's; otherwise a refusal before anything
    /// changes, as an address left over from an earlier sign-in would protect the wrong account.
    static func verifiedSigner(_ service: ServiceClient) async throws -> String {
        let entered = try signer(service)
        let found = await signedIn(service)
        guard let email = found.email else {
            throw ServiceError.input("Nothing was changed: Google did not say which account this tool is signed in as (\(found.why ?? "no answer")), so Pion cannot check it is \(entered), whose own access it must not remove. Sign the tool in again in Settings › Tools, with the scope \(emailScope) under Data Access, then try again.")
        }
        guard email == entered else {
            throw ServiceError.input("Nothing was changed: this tool is signed in as \(email), but Account that signs in is \(entered), so Pion would protect the wrong account. Set Account that signs in to the account you sign in with, or sign in as \(entered), in Settings › Tools.")
        }
        return email
    }

    struct IAMPolicy: Decodable { let version: Int?; let etag: String?; let bindings: [JSON]? }

    /// A binding's parts as read: its role, members, and condition's title and expression, which anyone with access
    /// to the policy may have written.
    static func role(of binding: JSON) -> String? { binding["role"]?.text }
    static func members(of binding: JSON) -> [String] {
        if case .array(let items)? = binding["members"] { return items.compactMap(\.text) }
        return []
    }
    static func condition(of binding: JSON) -> (title: String?, expression: String?)? {
        guard let condition = binding["condition"], case .object = condition else { return nil }
        return (condition["title"]?.text, condition["expression"]?.text)
    }
    static func describe(_ binding: JSON) -> String {
        guard let condition = condition(of: binding) else { return "the binding without a condition" }
        return "the binding with condition titled \(fromGoogle(condition.title)) and expression \(fromGoogle(condition.expression))"
    }

    struct RemoveIAMMember: ServiceOperation {
        struct Input: Decodable, Sendable {
            let resource: String, role: String, member: String, condition: String?, allowSelf: Bool?, allowLastOwner: Bool?
        }
        static let name = "remove-iam-member"
        static let summary = "Remove one member from one role binding of a project, folder or organisation's IAM policy, keeping every other member, binding and condition, written only if the policy is unchanged since Pion read it. Refuses the account signed in, checked with Google against the one entered, its domain and the last owner unless told to. Access through groups, other roles and folders or organisations above stays. To undo: grant the member the role again, with the same condition, as the result says; Pion does not grant access."
        static let input = JSONSchema.object([
            "resource": .string("projects/PROJECT-ID, folders/NUMBER or organizations/NUMBER."),
            "role": .string("The role, such as roles/editor or organizations/123/roles/custom."),
            "member": .string("The member exactly as the policy names it, such as user:mallory@example.com, serviceAccount:ci@p.iam.gserviceaccount.com, group:…, domain:…, principal://… or allUsers."),
            "condition": .string("Which binding, when the member holds the role in more than one: none for the binding without a condition, or the condition's exact title or expression."),
            "allowSelf": .boolean("Remove it even when it is the account signed in, or its whole domain, which could lock this tool out."),
            "allowLastOwner": .boolean("Remove it even when it is the last owner left without a condition, which can leave the project or organisation with no owner."),
        ], required: ["resource", "role", "member"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let own = try GoogleCloud.own(service)
            let given = try GoogleCloud.place(input.resource)
            guard let role = GoogleCloud.shaped(input.role.trimmingCharacters(in: .whitespaces), GoogleCloud.rolePattern) else {
                throw ServiceError.input("Give the role as roles/NAME, or a custom role's full name, such as organizations/123/roles/NAME.")
            }
            guard let member = GoogleCloud.shaped(input.member.trimmingCharacters(in: .whitespaces), GoogleCloud.memberPattern) else {
                throw ServiceError.input("Give the member exactly as the policy names it, with its kind, such as user:mallory@example.com or serviceAccount:ci@kestrel-prod.iam.gserviceaccount.com.")
            }
            let wanted = try input.condition.map { try ServiceInput.query($0, limit: 4_000) }
            // The account entered, and its domain, are refused first: nothing else is read for them. Once the resource is
            // placed, Google is asked which account signed in, which must be the one entered, so the guard protects the
            // account really in use.
            let signer = try GoogleCloud.signer(service)
            let domain = String(signer.split(separator: "@").last ?? "")
            if input.allowSelf != true, member.lowercased() == "user:" + signer || member.lowercased() == "domain:" + domain {
                throw ServiceError.input("Nothing was changed: \(member) is the account this tool signs in as, \(signer), or its whole domain, so removing it could lock this tool out. Give allowSelf to go ahead.")
            }
            let place = try await GoogleCloud.inside(given, service)
            _ = try await GoogleCloud.verifiedSigner(service)
            let need = GoogleCloud.policyNeed(place.kind)
            let manager = try GoogleCloud.on(.resourceManager, service)
            struct Options: Encodable { let requestedPolicyVersion: Int }
            struct Get: Encodable { let options: Options }
            // Version 3, so conditional bindings come back whole rather than flattened.
            let read = try await GoogleCloud.read(need, own) {
                try await manager.post(["v3"] + Array(place.path.dropLast()) + ["\(place.path.last!):getIamPolicy"], body: Get(options: Options(requestedPolicyVersion: 3)), as: IAMPolicy.self)
            }
            guard let etag = read.etag, !etag.isEmpty else {
                throw ServiceError.input("Nothing was changed: Google gave the policy of \(place.name) no etag, so it cannot be changed knowing it is the policy Pion read.")
            }
            let bindings = read.bindings ?? []
            // The member as the binding stores it: exactly as given, or else the one member that differs only in case.
            func stored(in binding: JSON) -> String? {
                let members = GoogleCloud.members(of: binding)
                if members.contains(member) { return member }
                let alike = members.filter { $0.lowercased() == member.lowercased() }
                return alike.count == 1 ? alike[0] : nil
            }
            func matches(_ binding: JSON) -> Bool {
                guard GoogleCloud.role(of: binding) == role, stored(in: binding) != nil else { return false }
                guard let wanted else { return true }
                let condition = GoogleCloud.condition(of: binding)
                if wanted.lowercased() == "none" { return condition == nil }
                return condition.map { $0.title == wanted || $0.expression?.trimmingCharacters(in: .whitespacesAndNewlines) == wanted } ?? false
            }
            let found = bindings.indices.filter { matches(bindings[$0]) }
            struct Kept: Encodable {
                let resource: String, role: String, member: String, changed: Bool
                var removedFrom: JSON? = nil, membersKept = 0, policyVersion = 0
            }
            guard let index = found.first else {
                let elsewhere = bindings.filter { GoogleCloud.role(of: $0) == role && stored(in: $0) != nil }
                let text = elsewhere.isEmpty
                    ? "\(member) holds no binding of \(role) in the policy of \(place.name); nothing was changed. Access through a group, another role, or a folder or organisation above is not in this policy: Google Cloud Audit's iam-policies finds it."
                    : "\(member) holds \(role) on \(place.name) only in " + elsewhere.map(GoogleCloud.describe).joined(separator: "; ") + ", which condition does not name; nothing was changed. Give condition to name one."
                return try ServiceResult(text: text, structured: Kept(resource: place.name, role: role, member: member, changed: false))
            }
            guard found.count == 1 else {
                throw ServiceError.input("Nothing was changed: \(member) holds \(role) on \(place.name) in \(found.count) bindings: " + found.map { GoogleCloud.describe(bindings[$0]) }.joined(separator: "; ")
                                         + ". Give condition as none, or as one condition's exact expression, to say which.")
            }
            // Only the one member of the one binding goes: every other binding is sent back exactly as read, and this
            // one with its other members and its condition; a binding left with no members is dropped.
            let target = bindings[index], removing = stored(in: target)!
            let remaining = GoogleCloud.members(of: target).filter { $0 != removing }
            var updated = bindings
            if remaining.isEmpty {
                updated.remove(at: index)
            } else if case .object(var fields) = target {
                fields["members"] = .array(remaining.map(JSON.string))
                updated[index] = .object(fields)
            }
            let owners = GoogleCloud.ownerRoles(place)
            if input.allowLastOwner != true, owners.contains(role), GoogleCloud.condition(of: target) == nil {
                let left = updated.filter { owners.contains(GoogleCloud.role(of: $0) ?? "") && GoogleCloud.condition(of: $0) == nil }
                    .flatMap(GoogleCloud.members).filter { !$0.hasPrefix("deleted:") }
                if left.isEmpty {
                    throw ServiceError.input("Nothing was changed: \(member) is the last member of \(GoogleCloud.listed(owners)) without a condition on \(place.name), so removing it would leave it with no owner. Give allowLastOwner to go ahead.")
                }
            }
            let conditional = updated.contains { GoogleCloud.condition(of: $0) != nil }
            let version = max(read.version ?? 1, conditional ? 3 : 1)
            struct Written: Encodable { let version: Int; let etag: String; let bindings: [JSON] }
            struct Request: Encodable { let policy: Written }
            let body = try JSONEncoder().encode(Request(policy: Written(version: version, etag: etag, bindings: updated)))
            let answer = try await GoogleCloud.change("writing the policy of \(place.name)", need, own) {
                try await manager.exchange(["v3"] + Array(place.path.dropLast()) + ["\(place.path.last!):setIamPolicy"], method: "POST", body: body, returning: [409, 412])
            }
            if answer.response.statusCode == 409 || answer.response.statusCode == 412 {
                // Google refuses a write whose etag is no longer the policy's with ABORTED.
                let reason = ServiceClient.reason(answer.data)
                let status = (try? JSONDecoder().decode([String: JSON].self, from: answer.data))?["error"]?["status"]?.text
                let raced = status == "ABORTED" || status == "FAILED_PRECONDITION" || (reason ?? "").lowercased().contains("concurrent") || (reason ?? "").lowercased().contains("etag")
                throw ServiceError.input(raced
                    ? "Nothing was changed: the policy of \(place.name) changed since Pion read it, so Google refused the write \(GoogleCloud.fromGoogle(reason)). Run remove-iam-member again to read it afresh, and check what else changed."
                    : "Nothing was changed: Google refused the write to the policy of \(place.name) (HTTP \(answer.response.statusCode)) \(GoogleCloud.fromGoogle(reason)).")
            }
            // What Google answers is the policy now, checked to have lost only that member.
            let now = try? JSONDecoder().decode(IAMPolicy.self, from: answer.data)
            var check = ""
            if let now {
                let kept = (now.bindings ?? []).filter { GoogleCloud.role(of: $0) == role && GoogleCloud.condition(of: $0)?.expression == GoogleCloud.condition(of: target)?.expression }
                    .flatMap(GoogleCloud.members)
                if kept.contains(removing) {
                    check = " Google's answer still shows \(member) in that binding, so check the policy."
                } else if !remaining.allSatisfy({ kept.contains($0) }) {
                    check = " Google's answer is missing other members of that binding, so check the policy at once."
                }
            } else {
                check = " Google's answer could not be read to confirm it, so check the policy."
            }
            let condition = GoogleCloud.condition(of: target)
            let undo = condition == nil
                ? "\(place.gcloud) --member=\(member) --role=\(role) --condition=None"
                : "\(place.gcloud) --member=\(member) --role=\(role) with the same condition, kept in this result as removedFrom"
            let text = "Removed \(member) from \(role) on \(place.name), from \(GoogleCloud.describe(target)); \(remaining.count) other member\(remaining.count == 1 ? "" : "s") of it \(remaining.count == 1 ? "was" : "were") kept\(remaining.isEmpty ? ", so the binding is gone" : ""), and every other binding and condition was sent back as read. Access the member holds through a group, another role, or a folder or organisation above stays.\(check) To undo: grant it again, \(undo); Pion does not grant access."
            return try ServiceResult(text: text, structured: Kept(resource: place.name, role: role, member: member, changed: true, removedFrom: target,
                                                                  membersKept: remaining.count, policyVersion: version))
        }
    }
}

// MARK: Buckets

extension GoogleCloud {
    static func bucket(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespaces)
        guard shaped(name, #"[a-z0-9][a-z0-9_.-]{1,220}[a-z0-9]"#) != nil, !name.contains(".."), !name.hasPrefix("goog") else {
            throw ServiceError.input("Give the bucket's name alone, such as payroll-exports, without gs://.")
        }
        return name
    }

    struct Bucket: Decodable {
        struct Configuration: Decodable { let publicAccessPrevention: String? }
        let name: String?, projectNumber: String?, metageneration: String?, iamConfiguration: Configuration?
    }

    static let bucketFields = "name,projectNumber,metageneration,iamConfiguration"

    /// The bucket, read and checked to be in a project inside the account's scope, with what its setting is now.
    static func readBucket(_ name: String, _ service: ServiceClient) async throws -> (bucket: Bucket, setting: String, metageneration: String) {
        let own = try own(service), storage = try on(.storage, service)
        let read = try await GoogleCloud.read(bucketNeed, own) {
            try await storage.get(["storage", "v1", "b", name], query: ["fields": bucketFields], as: Bucket.self)
        }
        guard let number = shaped(read.projectNumber, numberPattern), let metageneration = shaped(read.metageneration, numberPattern) else {
            throw ServiceError.input("Nothing was changed: Google gave bucket \(name) without its project or metageneration, so it cannot be checked or changed safely.")
        }
        _ = try await inside(.project(number), service)
        return (read, shaped(read.iamConfiguration?.publicAccessPrevention, "enforced|inherited|unspecified") ?? "unknown", metageneration)
    }

    /// Sets the bucket's public access prevention, only while the bucket is at `metageneration`, returning the setting
    /// and the metageneration Google's answer gives after the change. `stale` says what a bucket changed since means.
    static func setPrevention(_ name: String, to value: String, metageneration: String, stale: String, _ service: ServiceClient) async throws -> (setting: String?, metageneration: String?) {
        let own = try own(service), storage = try on(.storage, service)
        let body = try JSONEncoder().encode(["iamConfiguration": ["publicAccessPrevention": value]])
        let answer = try await change("setting bucket \(name)'s public access prevention", bucketNeed, own) {
            try await storage.exchange(["storage", "v1", "b", name], query: ["ifMetagenerationMatch": metageneration, "fields": bucketFields],
                                       method: "PATCH", body: body, returning: [412])
        }
        if answer.response.statusCode == 412 { throw ServiceError.input(stale) }
        let after = try? JSONDecoder().decode(Bucket.self, from: answer.data)
        return (shaped(after?.iamConfiguration?.publicAccessPrevention, "enforced|inherited|unspecified"), shaped(after?.metageneration, numberPattern))
    }

    struct BucketInput: Decodable, Sendable { let bucket: String }

    struct EnforcePublicAccessPrevention: ServiceOperation {
        typealias Input = BucketInput
        static let name = "enforce-public-access-prevention"
        static let summary = "Stop a bucket and its objects being reached by allUsers or allAuthenticatedUsers, by enforcing its public access prevention, only if the bucket is unchanged since Pion read it. Its grants stay in the policy but no longer work, which breaks a site served from it on purpose. It returns the setting before and the bucket's metageneration after Pion's change. To undo: revert-public-access-prevention with those, which only reverts while nobody has changed the bucket since."
        static let input = JSONSchema.object(["bucket": .string("The bucket's name alone, such as payroll-exports.")], required: ["bucket"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let name = try GoogleCloud.bucket(input.bucket)
            let (_, before, metageneration) = try await GoogleCloud.readBucket(name, service)
            struct Kept: Encodable { let bucket: String, previous: String, now: String, metageneration: String?, changed: Bool }
            if before == "enforced" {
                return try ServiceResult(text: "Bucket \(name) already enforces public access prevention; nothing was changed, so there is nothing for revert-public-access-prevention to undo.",
                                         structured: Kept(bucket: name, previous: before, now: before, metageneration: metageneration, changed: false))
            }
            let after = try await GoogleCloud.setPrevention(name, to: "enforced", metageneration: metageneration,
                                                            stale: "Nothing was changed: bucket \(name) changed since Pion read it, so Google refused the change. Run it again to read the bucket afresh.", service)
            let check = after.setting == "enforced" ? "" : " Google's answer did not show it enforced, so check the bucket."
            let undo = before == "unknown"
                ? "Google did not say what the setting was before, so revert-public-access-prevention cannot undo it: set it in the console."
                : after.metageneration.map { "revert-public-access-prevention on \(name) with previous \(before) and metageneration \($0), which makes those grants work again, and only if nobody has changed the bucket since." }
                    ?? "Google's answer did not give the bucket's metageneration after the change, so revert-public-access-prevention cannot undo it safely: set it back to \(before) in the console."
            return try ServiceResult(text: "Enforced public access prevention on bucket \(name); before, it was \(before). Grants to allUsers and allAuthenticatedUsers stay in its policy and ACLs but no longer work, so anything served from it publicly stops.\(check) To undo: \(undo)",
                                     structured: Kept(bucket: name, previous: before, now: after.setting ?? "unknown", metageneration: after.metageneration, changed: true))
        }
    }

    /// Opening a bucket to the public again is as serious as closing it, so it waits for approval too. It acts only on
    /// what it is given, which should be copied from enforce-public-access-prevention's result: the bucket must still be
    /// at the metageneration given. That guards against a change made since, not against values that did not come
    /// from Pion's change, which nothing on the bucket records.
    struct RevertPublicAccessPrevention: ServiceOperation {
        struct Input: Decodable, Sendable { let bucket: String, previous: String, metageneration: String }
        static let name = "revert-public-access-prevention"
        static let summary = "Undo enforce-public-access-prevention: set a bucket's public access prevention back to inherited, conditional on the bucket, prior setting and metageneration given, which must be copied from enforce-public-access-prevention's result: Google makes the change only while the bucket is still at that metageneration, so a change made since is not undone. It cannot prove Pion made the enforcement; it acts on the values supplied. Grants to allUsers or allAuthenticatedUsers the bucket holds then work again, unless an organisation policy enforces prevention. To undo: enforce-public-access-prevention."
        static let input = JSONSchema.object([
            "bucket": .string("The bucket's name alone."),
            "previous": .string("The previous setting, copied from enforce-public-access-prevention's result.", oneOf: ["inherited", "unspecified"]),
            "metageneration": .string("The metageneration after the change, copied from enforce-public-access-prevention's result."),
        ], required: ["bucket", "previous", "metageneration"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let name = try GoogleCloud.bucket(input.bucket)
            if input.previous == "enforced" {
                throw ServiceError.input("Nothing was changed: the bucket already enforced public access prevention before, so Pion changed nothing and there is nothing to undo.")
            }
            let previous = try ServiceInput.oneOf(input.previous, ["inherited", "unspecified"], "previous")
            guard let generation = GoogleCloud.shaped(input.metageneration.trimmingCharacters(in: .whitespaces), GoogleCloud.numberPattern) else {
                throw ServiceError.input("Give metageneration as enforce-public-access-prevention recorded it, a number.")
            }
            let stale = "Nothing was reverted: bucket \(name) is not at metageneration \(generation), the one given, so it changed since that point, or the value did not come from enforce-public-access-prevention's result; whoever changed it may have enforced prevention on purpose. Check it in the console and decide there."
            // Read for its project, to keep to the scope; the change itself is conditional on the metageneration given.
            let (_, now, current) = try await GoogleCloud.readBucket(name, service)
            guard current == generation, now == "enforced" else { throw ServiceError.input(stale) }
            let after = try await GoogleCloud.setPrevention(name, to: "inherited", metageneration: generation, stale: stale, service)
            let check = after.setting == "inherited" || after.setting == "unspecified" ? "" : " Google's answer did not show it inherited, so check the bucket."
            struct Kept: Encodable { let bucket: String, previous: String, now: String, changed: Bool }
            return try ServiceResult(text: "Set bucket \(name)'s public access prevention back to inherited, the prior setting given (\(previous)), as the bucket was still at metageneration \(generation), the one given. This undoes the enforcement those values were copied from; Pion cannot confirm who made it. Grants it holds to allUsers or allAuthenticatedUsers work again, unless an organisation policy enforces prevention above it.\(check) To undo: enforce-public-access-prevention on \(name).",
                                     structured: Kept(bucket: name, previous: "enforced", now: after.setting ?? "unknown", changed: true))
        }
    }
}

// MARK: VMs

extension GoogleCloud {
    /// What a Compute Engine name is given as: alone, as projects/…, or as the link Compute Engine gives it, on its own
    /// host or www.googleapis.com, or as Cloud Asset's //compute.googleapis.com/ name. Any other host is refused.
    static func computeParts(_ value: String) -> [String]? {
        var name = value.trimmingCharacters(in: .whitespaces)
        for prefix in ["https://www.googleapis.com/compute/v1/", "https://compute.googleapis.com/compute/v1/", "//compute.googleapis.com/"] where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        guard name.hasPrefix("projects/") else { return nil }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.allSatisfy({ !$0.isEmpty }) ? parts : nil
    }

    struct InstanceName {
        let project: String, zone: String, name: String
        var path: [String] { ["compute", "v1", "projects", project, "zones", zone, "instances", name] }
        var said: String { "projects/\(project)/zones/\(zone)/instances/\(name)" }
    }

    static func instanceName(_ value: String) throws -> InstanceName {
        guard let parts = computeParts(value), parts.count == 6, shaped(parts[1], projectPattern) != nil, parts[2] == "zones",
              shaped(parts[3], zonePattern) != nil, parts[4] == "instances", shaped(parts[5], computeNamePattern) != nil else {
            throw ServiceError.input("Give the VM by its full name, projects/PROJECT-ID/zones/ZONE/instances/NAME.")
        }
        return InstanceName(project: parts[1], zone: parts[3], name: parts[5])
    }

    struct Instance: Decodable {
        struct Tags: Decodable { let items: [String]?; let fingerprint: String? }
        struct Interface: Decodable {
            struct Access: Decodable { let type: String? }
            let network: String?, stackType: String?, ipv6Address: String?, ipv6AccessConfigs: [Access]?
            var ipv6: Bool { stackType == "IPV4_IPV6" || stackType == "IPV6_ONLY" || ipv6Address != nil || !(ipv6AccessConfigs ?? []).isEmpty }
        }
        struct Disk: Decodable { let source: String?, type: String?, deviceName: String? }
        let id: String?, status: String?, tags: Tags?, networkInterfaces: [Interface]?, disks: [Disk]?
    }

    /// The VM, checked to be in a project inside the account's scope, and read.
    static func readInstance(_ input: String, _ service: ServiceClient) async throws -> (name: InstanceName, instance: Instance, id: String) {
        let own = try own(service)
        let name = try instanceName(input)
        _ = try await inside(.project(name.project), service)
        let compute = try on(.compute, service)
        let read = try await GoogleCloud.read(instanceNeed, own) { try await compute.get(name.path, as: Instance.self) }
        guard let id = shaped(read.id, numberPattern) else {
            throw ServiceError.input("Nothing was changed: Google gave \(name.said) without its ID, so it cannot be acted on safely.")
        }
        return (name, read, id)
    }

    static let instanceStates = "PROVISIONING|STAGING|RUNNING|STOPPING|STOPPED|SUSPENDING|SUSPENDED|REPAIRING|TERMINATED"

    struct Operation: Decodable {
        struct Problem: Decodable { let code: String?; let message: String? }
        struct Problems: Decodable { let errors: [Problem]? }
        let kind: String?, name: String?, status: String?, operationType: String?, targetLink: String?, selfLink: String?, error: Problems?
    }

    /// Whether parts are one of Compute Engine's places for an operation's progress, in a zone, a region or global.
    static func isOperation(_ parts: [String]) -> Bool {
        guard parts.first == "projects", parts.count >= 5, shaped(parts[1], projectPattern) != nil, shaped(parts.last, operationPattern) != nil else { return false }
        if parts.count == 6 { return (parts[2] == "zones" && shaped(parts[3], zonePattern) != nil || parts[2] == "regions" && shaped(parts[3], regionPattern) != nil) && parts[4] == "operations" }
        return parts.count == 5 && parts[2] == "global" && parts[3] == "operations"
    }

    /// The operation a change started, by the path operation-status takes: from Compute Engine's own link to it when
    /// that is one of its places for operations, otherwise from where it was started and its name.
    static func operationPath(_ data: Data, fallback: [String]) -> String? {
        guard let operation = try? JSONDecoder().decode(Operation.self, from: data) else { return nil }
        if let link = operation.selfLink, let parts = computeParts(link), isOperation(parts) { return parts.joined(separator: "/") }
        guard let name = shaped(operation.name, operationPattern) else { return nil }
        let parts = fallback + ["operations", name]
        return isOperation(parts) ? parts.joined(separator: "/") : nil
    }

    /// An operation's errors, when Compute Engine already reports any, said with Google's words marked.
    static func operationErrors(_ data: Data) -> String? {
        guard let errors = (try? JSONDecoder().decode(Operation.self, from: data))?.error?.errors, !errors.isEmpty else { return nil }
        return errors.prefix(3).map { (shaped($0.code, "[A-Z0-9_]{1,80}") ?? "error") + " " + fromGoogle($0.message) }.joined(separator: "; ")
    }

    /// Snapshots of each persistent disk of the VM, as evidence, each started in turn; a disk that cannot be snapshotted
    /// stops the rest, saying which were started.
    static func snapshot(_ name: InstanceName, _ instance: Instance, id: String, notes: String, _ service: ServiceClient)
        async throws -> (snapshots: [String], operations: [String], skipped: [String]) {
        let own = try own(service), compute = try on(.compute, service)
        var snapshots: [String] = [], operations: [String] = [], skipped: [String] = [], disks: [[String]] = []
        for disk in instance.disks ?? [] {
            if disk.type == "SCRATCH" { skipped.append("a local SSD\(shaped(disk.deviceName, computeNamePattern).map { ", \($0)," } ?? "") which cannot be snapshotted"); continue }
            guard let parts = disk.source.flatMap(computeParts), parts.count == 6, parts[1] == name.project,
                  parts[2] == "zones" && shaped(parts[3], zonePattern) != nil || parts[2] == "regions" && shaped(parts[3], regionPattern) != nil,
                  parts[4] == "disks", shaped(parts[5], computeNamePattern) != nil else {
                throw ServiceError.input("Nothing was changed: \(name.said) has a disk Google named in a form Pion does not recognise, or in another project, so its disks were not snapshotted.")
            }
            disks.append(parts)
        }
        guard !disks.isEmpty else {
            throw ServiceError.input("Nothing was changed: \(name.said) has no persistent disk to snapshot\(skipped.isEmpty ? "" : "; it has \(skipped.joined(separator: ", "))").")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).filter(\.isNumber)
        for parts in disks {
            let snapshot = "pion-\(digest(parts.joined(separator: "/"), 12))-\(stamp.prefix(14))"
            struct Body: Encodable { let name: String, description: String, labels: [String: String] }
            let body = try JSONEncoder().encode(Body(name: snapshot, description: "Pion evidence of \(name.said): \(notes)", labels: ["pion-evidence": id]))
            let undo = "The snapshots started stay as evidence; delete them in the console when no longer needed."
            let answer = try await change("snapshotting \(parts.joined(separator: "/"))", snapshotNeed, own, done: snapshots.map { "started snapshot \($0)" }, undo: undo) {
                try await compute.data(["compute", "v1"] + parts + ["createSnapshot"], method: "POST", body: body)
            }
            if let errors = operationErrors(answer) {
                throw stopped(snapshots.map { "started snapshot \($0)" }, Failure(text: "snapshotting \(parts.joined(separator: "/")) failed: \(errors)", unsure: false), undo: undo)
            }
            snapshots.append("projects/\(name.project)/global/snapshots/\(snapshot) of \(parts.joined(separator: "/"))")
            if let operation = operationPath(answer, fallback: Array(parts.prefix(4))) { operations.append(operation) }
        }
        return (snapshots, operations, skipped)
    }

    struct SnapshotDisks: ServiceOperation {
        struct Input: Decodable, Sendable { let instance: String, notes: String? }
        static let name = "snapshot-disks"
        static let summary = "Snapshot each persistent disk of a VM, as evidence before it is changed or stopped, each labelled pion-evidence with the VM's ID, returning the operations to read with operation-status. Local SSDs cannot be snapshotted. The snapshots stay until deleted."
        static let input = JSONSchema.object([
            "instance": .string("The VM's full name, projects/PROJECT-ID/zones/ZONE/instances/NAME."),
            "notes": .string("Why, kept in each snapshot's description, up to 200 characters."),
        ], required: ["instance"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let notes = try input.notes.map { try ServiceInput.quoted($0, "notes") } ?? "taken during an investigation"
            let (name, instance, id) = try await GoogleCloud.readInstance(input.instance, service)
            let made = try await GoogleCloud.snapshot(name, instance, id: id, notes: notes, service)
            struct Kept: Encodable { let instance: String, snapshots: [String], operations: [String], skipped: [String] }
            return try ServiceResult(text: "Snapshotting \(name.said): \(made.snapshots.joined(separator: "; ")). They finish in the background\(made.operations.isEmpty ? "" : ": read \(GoogleCloud.listed(made.operations)) with operation-status").\(made.skipped.isEmpty ? "" : " Not snapshotted: \(made.skipped.joined(separator: "; ")).") They stay until deleted in the console.",
                                     structured: Kept(instance: name.said, snapshots: made.snapshots, operations: made.operations, skipped: made.skipped))
        }
    }

    struct StopInstance: ServiceOperation {
        struct Input: Decodable, Sendable { let instance: String, snapshotFirst: Bool?, notes: String? }
        static let name = "stop-instance"
        static let summary = "Stop a VM, ending everything running on it and what is only in its memory, snapshotting its persistent disks first when snapshotFirst is given. Its disks stay; an ephemeral external IP is released. It refuses a VM with a local SSD. To undo: start it again in the console or with gcloud compute instances start; it boots afresh."
        static let input = JSONSchema.object([
            "instance": .string("The VM's full name, projects/PROJECT-ID/zones/ZONE/instances/NAME."),
            "snapshotFirst": .boolean("Snapshot each persistent disk first, as snapshot-disks does; nothing is stopped if a snapshot cannot be started."),
            "notes": .string("Why, kept in each snapshot's description, up to 200 characters."),
        ], required: ["instance"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let notes = try input.notes.map { try ServiceInput.quoted($0, "notes") } ?? "taken before the VM was stopped"
            let own = try GoogleCloud.own(service)
            let (name, instance, id) = try await GoogleCloud.readInstance(input.instance, service)
            let status = GoogleCloud.shaped(instance.status, GoogleCloud.instanceStates) ?? "unknown"
            struct Kept: Encodable { let instance: String, before: String, operation: String?, snapshots: [String], snapshotOperations: [String], changed: Bool }
            guard ["RUNNING", "PROVISIONING", "STAGING", "REPAIRING"].contains(status) else {
                return try ServiceResult(text: "\(name.said) is \(status); nothing was changed.",
                                         structured: Kept(instance: name.said, before: status, operation: nil, snapshots: [], snapshotOperations: [], changed: false))
            }
            guard !(instance.disks ?? []).contains(where: { $0.type == "SCRATCH" }) else {
                throw ServiceError.input("Nothing was changed: \(name.said) has a local SSD, whose data stopping may discard, so Pion leaves it running; stop it in the console, choosing what happens to the local SSD, or isolate-instance it.")
            }
            var made: (snapshots: [String], operations: [String], skipped: [String]) = ([], [], [])
            if input.snapshotFirst == true {
                do { made = try await GoogleCloud.snapshot(name, instance, id: id, notes: notes, service) }
                catch { throw ServiceError.input("\(error.localizedDescription) \(name.said) was not stopped.") }
            }
            let compute = try GoogleCloud.on(.compute, service)
            let done = made.snapshots.map { "started snapshot \($0)" }
            let answer = try await GoogleCloud.change("stopping \(name.said)", GoogleCloud.instanceNeed, own, done: done, undo: done.isEmpty ? "" : "The snapshots stay as evidence.") {
                try await compute.data(name.path + ["stop"], method: "POST")
            }
            if let errors = GoogleCloud.operationErrors(answer) {
                throw GoogleCloud.stopped(done, Failure(text: "stopping \(name.said) failed: \(errors)", unsure: false), undo: "")
            }
            let operation = GoogleCloud.operationPath(answer, fallback: ["projects", name.project, "zones", name.zone])
            let snapshots = made.snapshots.isEmpty ? "" : "Snapshotting first: \(made.snapshots.joined(separator: "; "))\(made.operations.isEmpty ? "" : ", read with operation-status \(GoogleCloud.listed(made.operations))"). "
            return try ServiceResult(text: "\(snapshots)Stopping \(name.said); it was \(status)\(operation.map { ", read with operation-status \($0)" } ?? ""). What was only in its memory is gone and an ephemeral external IP is released; its disks stay. A VM in a managed instance group may be started again by its group. To undo: start it again in the console or with gcloud compute instances start \(name.name) --zone=\(name.zone) --project=\(name.project); it boots afresh.",
                                     structured: Kept(instance: name.said, before: status, operation: operation, snapshots: made.snapshots, snapshotOperations: made.operations, changed: true))
        }
    }
}

// MARK: Isolation

extension GoogleCloud {
    /// The network tag that marks one VM as isolated by Pion, from a digest of its unique ID, so no other VM, nor one
    /// made again with its name, carries it.
    static func isolationTag(_ id: String) -> String { "pion-isolate-" + digest(id, 12) }

    /// The description each of Pion's isolation rules carries, by which unisolate-instance knows it as Pion's for that VM.
    static func isolationMark(_ id: String) -> String { "Pion isolation of VM \(id)" }

    /// One deny-all rule of an isolation: in or out, for IPv4 or IPv6, on one network.
    struct IsolationRule {
        let project: String, network: String, name: String, direction: String, range: String
        var path: [String] { ["compute", "v1", "projects", project, "global", "firewalls", name] }
        var said: String { "projects/\(project)/global/firewalls/\(name)" }
    }

    /// The rules isolating a VM on each of its networks, named after its tag and the network, so two networks of one
    /// project never share a name.
    static func isolationRules(tag: String, networks: [(project: String, network: String, ipv6: Bool)]) -> [IsolationRule] {
        networks.flatMap { place -> [IsolationRule] in
            let base = "\(tag)-\(digest("projects/\(place.project)/global/networks/\(place.network)", 6))"
            let families = place.ipv6 ? [("4", "0.0.0.0/0"), ("6", "::/0")] : [("4", "0.0.0.0/0")]
            return families.flatMap { family in
                [IsolationRule(project: place.project, network: place.network, name: "\(base)-in\(family.0)", direction: "INGRESS", range: family.1),
                 IsolationRule(project: place.project, network: place.network, name: "\(base)-out\(family.0)", direction: "EGRESS", range: family.1)]
            }
        }
    }

    /// The networks of the VM's interfaces, each checked to be in a project inside the account's scope, as a Shared
    /// VPC's host project may not be.
    static func networks(of name: InstanceName, _ instance: Instance, _ service: ServiceClient) async throws -> [(project: String, network: String, ipv6: Bool)] {
        var found: [(project: String, network: String, ipv6: Bool)] = []
        for interface in instance.networkInterfaces ?? [] {
            guard let parts = interface.network.flatMap(computeParts), parts.count == 5, shaped(parts[1], projectPattern) != nil,
                  parts[2] == "global", parts[3] == "networks", shaped(parts[4], computeNamePattern) != nil else {
                throw ServiceError.input("Nothing was changed: \(name.said) has a network interface whose network Google named in a form Pion does not recognise, so it cannot be isolated this way; stop-instance stops it instead.")
            }
            if let index = found.firstIndex(where: { $0.project == parts[1] && $0.network == parts[4] }) {
                found[index].ipv6 = found[index].ipv6 || interface.ipv6
            } else {
                found.append((parts[1], parts[4], interface.ipv6))
            }
        }
        guard !found.isEmpty else {
            throw ServiceError.input("Nothing was changed: \(name.said) has no network interface to isolate; stop-instance stops it instead.")
        }
        for network in found where network.project != name.project {
            do { _ = try await inside(.project(network.project), service) }
            catch { throw ServiceError.input("\(error.localizedDescription) \(name.said)'s network \(network.network) is in that project, a Shared VPC's host, where the isolation's firewall rules would go.") }
        }
        return found
    }

    struct Firewall: Decodable {
        struct Traffic: Decodable { let IPProtocol: String? }
        let name: String?, description: String?, network: String?, priority: Int?, direction: String?, targetTags: [String]?
        let sourceRanges: [String]?, destinationRanges: [String]?, denied: [Traffic]?, allowed: [Traffic]?, disabled: Bool?
    }

    /// A network's canonical name, projects/PROJECT/global/networks/NAME, from however Compute Engine links it.
    static func networkName(_ link: String?) -> String? {
        guard let parts = link.flatMap(computeParts), parts.count == 5, shaped(parts[1], projectPattern) != nil, parts[2] == "global",
              parts[3] == "networks", shaped(parts[4], computeNamePattern) != nil else { return nil }
        return parts.joined(separator: "/")
    }

    /// What a rule read is: pion when it is exactly one Pion would have made for this VM, by its name, description,
    /// network, priority, direction, range, tag and deny-all, and enabled; pion-disabled when it is that but someone
    /// turned it off; other otherwise. Its network must be in the rule's own project and be the one its name's digest
    /// was made from, and the one asked about when that is known, so a rule of the same name and tag on another
    /// network is never taken for this one.
    static func state(of read: Firewall, _ rule: IsolationRule, id: String, tag: String) -> String {
        let ranges = rule.direction == "INGRESS" ? read.sourceRanges : read.destinationRanges
        guard let network = networkName(read.network), network.hasPrefix("projects/\(rule.project)/"),
              rule.name.hasPrefix("\(tag)-\(digest(network, 6))-"),
              rule.network.isEmpty || network == "projects/\(rule.project)/global/networks/\(rule.network)" else { return "other" }
        let exact = read.name == rule.name && (read.description ?? "").hasPrefix(isolationMark(id) + " ") && read.priority == 0
            && read.direction == rule.direction && ranges == [rule.range] && read.targetTags == [tag]
            && (read.denied ?? []).map(\.IPProtocol) == ["all"] && (read.allowed ?? []).isEmpty
        guard exact else { return "other" }
        return read.disabled == true ? "pion-disabled" : "pion"
    }

    /// Each rule as it is now: absent, Pion's for this VM, Pion's but turned off, or someone else's.
    static func existing(_ rules: [IsolationRule], id: String, tag: String, _ service: ServiceClient) async throws -> [(rule: IsolationRule, state: String)] {
        let own = try own(service), compute = try on(.compute, service)
        var states: [(rule: IsolationRule, state: String)] = []
        for rule in rules {
            do {
                let read = try await GoogleCloud.read(firewallNeed, own) { try await compute.get(rule.path, as: Firewall.self) }
                states.append((rule, state(of: read, rule, id: id, tag: tag)))
            } catch ServiceError.notFound {
                states.append((rule, "absent"))
            }
        }
        return states
    }

    /// The pauses between reads of operations not yet ended, in seconds: about twenty in all, as long as a bot waits.
    @TaskLocal static var operationPauses: [Double] = [2, 3, 5, 5, 5]

    /// How Compute Engine operations ended, read again on its own host until each is DONE or the pauses run out:
    /// those that ended without errors, those that ended with them, said with Google's words marked, and those still
    /// running or whose state could not be read.
    static func settle(_ paths: [String], _ service: ServiceClient) async -> (succeeded: Set<String>, failed: [String: String], pending: [String]) {
        var succeeded = Set<String>(), failed: [String: String] = [:], pending = paths
        guard let compute = try? on(.compute, service) else { return (succeeded, failed, pending) }
        for pause in [0] + operationPauses where !pending.isEmpty {
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
            var still: [String] = []
            for path in pending {
                guard let data = try? await compute.data(["compute", "v1"] + path.split(separator: "/").map(String.init)),
                      let read = try? JSONDecoder().decode(Operation.self, from: data), read.kind == "compute#operation", read.status == "DONE" else {
                    still.append(path)
                    continue
                }
                if let errors = operationErrors(data) { failed[path] = errors } else { succeeded.insert(path) }
            }
            pending = still
        }
        return (succeeded, failed, pending)
    }

    /// An operation a change started, and whether Compute Engine's first answer already said it ended well.
    static func started(_ data: Data, fallback: [String]) -> (path: String?, ended: Bool) {
        let read = try? JSONDecoder().decode(Operation.self, from: data)
        return (operationPath(data, fallback: fallback), read?.kind == "compute#operation" && read?.status == "DONE" && operationErrors(data) == nil)
    }

    struct InstanceInput: Decodable, Sendable { let instance: String }

    struct IsolateInstance: ServiceOperation {
        typealias Input = InstanceInput
        static let name = "isolate-instance"
        static let summary = "Cut a VM off the network: add deny-all inbound and outbound VPC firewall rules at priority 0, the highest, for IPv4 and, where the VM has it, IPv6, on each of its networks, targeting a network tag pion-isolate and a digest of the VM's ID, wait for Compute Engine to confirm each, then add that tag to the VM only if its tags are unchanged since Pion read them, and wait for that too. It says isolated only once every change is confirmed done, and pending, with the operations to read, while any is still running. It refuses a rule of that name Pion did not make or someone turned off, and says exactly what was added when only part could be. Connections already open may continue until they close, the metadata server stays reachable, and allow rules of hierarchical firewall policies are evaluated first. To undo: unisolate-instance removes only that tag and those rules."
        static let input = JSONSchema.object(["instance": .string("The VM's full name, projects/PROJECT-ID/zones/ZONE/instances/NAME.")], required: ["instance"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let own = try GoogleCloud.own(service)
            let (name, instance, id) = try await GoogleCloud.readInstance(input.instance, service)
            let tag = GoogleCloud.isolationTag(id)
            let rules = GoogleCloud.isolationRules(tag: tag, networks: try await GoogleCloud.networks(of: name, instance, service))
            // Everything is read and checked before the first change: each rule's name, and the VM's tags.
            let states = try await GoogleCloud.existing(rules, id: id, tag: tag, service)
            if let other = states.first(where: { $0.state == "other" }) {
                throw ServiceError.input("Nothing was changed: \(other.rule.said) already exists and is not a rule Pion made to isolate this VM on its network, so it is left as it is. Check it in the console.")
            }
            if let off = states.first(where: { $0.state == "pion-disabled" }) {
                throw ServiceError.input("Nothing was changed: Pion's rule \(off.rule.said) for this VM is turned off, so the VM may not be isolated; someone disabled it. Find out why, then run unisolate-instance and isolate-instance again.")
            }
            let tags = instance.tags?.items ?? []
            let tagged = tags.contains(tag)
            guard tagged || tags.count < 64 else {
                throw ServiceError.input("Nothing was changed: \(name.said) already has 64 network tags, the most Google allows, so Pion's cannot be added; stop-instance stops it instead.")
            }
            let fingerprint = instance.tags?.fingerprint ?? ""
            guard tagged || !fingerprint.isEmpty else {
                throw ServiceError.input("Nothing was changed: Google gave \(name.said)'s tags no fingerprint, so its tag cannot be added knowing its tags are as Pion read them.")
            }
            let missing = states.filter { $0.state == "absent" }.map(\.rule)
            struct Kept: Encodable { let instance: String, tag: String, status: String, rules: [String], added: [String], tagged: Bool, pending: [String], operations: [String] }
            if missing.isEmpty, tagged {
                return try ServiceResult(text: "\(name.said) is already isolated by Pion: it carries \(tag) and Pion's rules \(GoogleCloud.listed(rules.map(\.said))) are in place and on; nothing was changed. To undo: unisolate-instance.",
                                         structured: Kept(instance: name.said, tag: tag, status: "isolated", rules: rules.map(\.said), added: [], tagged: true, pending: [], operations: []))
            }
            let compute = try GoogleCloud.on(.compute, service)
            // Only what Compute Engine confirmed done is said as done; what it accepted and is still doing, as asked.
            var confirmed: [String] = [], asked: [(said: String, operation: String?)] = [], added: [String] = [], operations: [String] = []
            func done() -> [String] { confirmed + asked.map { "asked Compute Engine to add \($0.said)\($0.operation.map { " (operation \($0), not yet confirmed)" } ?? ", not yet confirmed")" } }
            let undo = "The VM's tag was not added, so it is not isolated. Run unisolate-instance to remove what was added, then try again, or stop-instance."
            for rule in missing {
                struct Denied: Encodable { let IPProtocol: String }
                struct Log: Encodable { let enable: Bool }
                struct Body: Encodable {
                    let name: String, description: String, network: String, priority: Int, direction: String
                    let denied: [Denied], targetTags: [String], sourceRanges: [String]?, destinationRanges: [String]?, logConfig: Log
                }
                let body = try JSONEncoder().encode(Body(
                    name: rule.name, description: "\(GoogleCloud.isolationMark(id)) (\(name.said)): denies all \(rule.direction == "INGRESS" ? "inbound" : "outbound") traffic. Remove with unisolate-instance.",
                    network: "projects/\(rule.project)/global/networks/\(rule.network)", priority: 0, direction: rule.direction, denied: [Denied(IPProtocol: "all")],
                    targetTags: [tag], sourceRanges: rule.direction == "INGRESS" ? [rule.range] : nil,
                    destinationRanges: rule.direction == "EGRESS" ? [rule.range] : nil, logConfig: Log(enable: true)))
                let answer = try await GoogleCloud.change("adding rule \(rule.said)", GoogleCloud.firewallNeed, own, done: done(), undo: undo) {
                    try await compute.data(["compute", "v1", "projects", rule.project, "global", "firewalls"], method: "POST", body: body)
                }
                if let errors = GoogleCloud.operationErrors(answer) {
                    throw GoogleCloud.stopped(done(), Failure(text: "adding rule \(rule.said) failed: \(errors)", unsure: false), undo: undo)
                }
                let begun = GoogleCloud.started(answer, fallback: ["projects", rule.project, "global"])
                if let path = begun.path { operations.append(path) }
                if begun.ended { confirmed.append("added rule \(rule.said)"); added.append(rule.said) }
                else { asked.append(("rule \(rule.said)", begun.path)) }
            }
            // The rules must be in force before the tag goes on, and each is confirmed done, or said otherwise.
            if !asked.isEmpty {
                let waiting = asked
                let settled = await GoogleCloud.settle(waiting.compactMap(\.operation), service)
                asked = []
                var failures: [String] = []
                for item in waiting {
                    if let path = item.operation, settled.succeeded.contains(path) {
                        confirmed.append("added \(item.said)"); added.append(String(item.said.dropFirst("rule ".count)))
                    } else if let path = item.operation, let errors = settled.failed[path] {
                        failures.append("adding \(item.said) failed: \(errors)")
                    } else {
                        asked.append(item)
                    }
                }
                if !failures.isEmpty {
                    throw GoogleCloud.stopped(done(), Failure(text: failures.joined(separator: "; "), unsure: false), undo: undo)
                }
                if !asked.isEmpty {
                    let pending = asked.compactMap(\.operation)
                    let text = "Isolation of \(name.said) is not complete, and the VM is not isolated yet: \(done().joined(separator: "; ")). Pion has not added the tag \(tag), as the rules must be in force first. Read \(pending.isEmpty ? "the rules in the console" : GoogleCloud.listed(pending) + " with operation-status") until each is DONE, then run isolate-instance again, which keeps Pion's rules and adds the tag. To undo: unisolate-instance."
                    return try ServiceResult(text: text, structured: Kept(instance: name.said, tag: tag, status: "pending", rules: rules.map(\.said), added: added, tagged: false, pending: pending, operations: operations))
                }
            }
            var pending: [String] = []
            if !tagged {
                struct Body: Encodable { let items: [String]; let fingerprint: String }
                let body = try JSONEncoder().encode(Body(items: tags + [tag], fingerprint: fingerprint))
                let answer = try await GoogleCloud.change("adding tag \(tag) to \(name.said)", GoogleCloud.instanceNeed, own, done: done(), undo: undo) {
                    try await compute.exchange(name.path + ["setTags"], method: "POST", body: body, returning: [412])
                }
                if answer.response.statusCode == 412 {
                    throw GoogleCloud.stopped(done(), Failure(text: "\(name.said)'s tags changed since Pion read them, so Google refused to add \(tag)", unsure: false), undo: undo)
                }
                if let errors = GoogleCloud.operationErrors(answer.data) {
                    throw GoogleCloud.stopped(done(), Failure(text: "adding tag \(tag) to \(name.said) failed: \(errors)", unsure: false), undo: undo)
                }
                let begun = GoogleCloud.started(answer.data, fallback: ["projects", name.project, "zones", name.zone])
                if let path = begun.path { operations.append(path) }
                if begun.ended {
                    confirmed.append("added tag \(tag) to \(name.said)")
                } else if let path = begun.path {
                    let settled = await GoogleCloud.settle([path], service)
                    if let errors = settled.failed[path] {
                        throw GoogleCloud.stopped(done(), Failure(text: "adding tag \(tag) to \(name.said) failed: \(errors)", unsure: false), undo: undo)
                    }
                    if settled.succeeded.contains(path) { confirmed.append("added tag \(tag) to \(name.said)") } else { pending.append(path) }
                } else {
                    pending.append("the tag on \(name.said)")
                }
            }
            let limits = "Every rule denies all traffic at priority 0, logged, for VMs tagged \(tag) alone. Connections already open may continue until they close, the VM can still reach its metadata server, and an allow rule in a hierarchical firewall policy above the network, or a network firewall policy evaluated first, still lets its traffic through, so check those. To undo: unisolate-instance on \(name.said) removes the tag and these rules, and only them."
            if !pending.isEmpty {
                let text = "Isolation of \(name.said) is not confirmed yet: \(confirmed.joined(separator: "; ")), and Compute Engine is still adding the tag \(tag); the VM is isolated only once that is DONE: read \(GoogleCloud.listed(pending)) with operation-status. \(limits)"
                return try ServiceResult(text: text, structured: Kept(instance: name.said, tag: tag, status: "pending", rules: rules.map(\.said), added: added, tagged: false, pending: pending, operations: operations))
            }
            let text = "Isolated \(name.said), each change confirmed done by Compute Engine: \(confirmed.joined(separator: "; "))\(added.count < rules.count ? ", with Pion's other rules already in place" : ""). \(limits)"
            return try ServiceResult(text: text, structured: Kept(instance: name.said, tag: tag, status: "isolated", rules: rules.map(\.said), added: added, tagged: true, pending: [], operations: operations))
        }
    }

    struct UnisolateInstance: ServiceOperation {
        struct Input: Decodable, Sendable { let instance: String, firewallRules: [String]? }
        static let name = "unisolate-instance"
        static let summary = "Undo isolate-instance: remove Pion's isolation tag from the VM, only if its tags are unchanged since Pion read them, then delete Pion's isolation rules for it, each checked first to be exactly a rule Pion made for this VM on the network its name was made for, from the rules isolate-instance reported when given them, else those of the VM's networks now. Compute Engine takes no condition on deleting a rule, so Pion reads each just before deleting it. To undo: isolate-instance."
        static let input = JSONSchema.object([
            "instance": .string("The VM's full name, projects/PROJECT-ID/zones/ZONE/instances/NAME."),
            "firewallRules": .array(.string("A rule isolate-instance reported, projects/PROJECT-ID/global/firewalls/NAME."),
                                    "The rules isolate-instance reported, up to 16; those of the VM's networks now when left out."),
        ], required: ["instance"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let own = try GoogleCloud.own(service)
            let name = try GoogleCloud.instanceName(input.instance)
            // The rules named are checked before anything is read: Pion's own names, inside the scope.
            let given = try input.firewallRules.map { names in
                try ServiceInput.list(names, limit: 16) { $0 }.map { value -> (project: String, name: String) in
                    guard let parts = GoogleCloud.computeParts(value), parts.count == 5, GoogleCloud.shaped(parts[1], GoogleCloud.projectPattern) != nil,
                          parts[2] == "global", parts[3] == "firewalls", GoogleCloud.shaped(parts[4], GoogleCloud.computeNamePattern) != nil,
                          parts[4].hasPrefix("pion-isolate-") else {
                        throw ServiceError.input("Give each rule as isolate-instance reported it, projects/PROJECT-ID/global/firewalls/pion-isolate-….")
                    }
                    return (parts[1], parts[4])
                }
            }
            let (_, instance, id) = try await GoogleCloud.readInstance(input.instance, service)
            let tag = GoogleCloud.isolationTag(id)
            var candidates: [IsolationRule]
            if let given {
                candidates = []
                for rule in given {
                    // Only the names Pion gives this VM's rules: its tag, a network's digest, and in or out for v4 or v6.
                    guard rule.name.range(of: "^\(tag)-[0-9a-f]{6}-(in|out)(4|6)$", options: .regularExpression) != nil else {
                        throw ServiceError.input("Nothing was changed: \(rule.name) is not the name of a rule Pion makes to isolate \(name.said), whose rules begin \(tag)-.")
                    }
                    _ = try await GoogleCloud.inside(.project(rule.project), service)
                    candidates.append(IsolationRule(project: rule.project, network: "", name: rule.name, direction: rule.name.range(of: "-in[46]$", options: .regularExpression) != nil ? "INGRESS" : "EGRESS",
                                                    range: rule.name.hasSuffix("6") ? "::/0" : "0.0.0.0/0"))
                }
            } else {
                let networks = try await GoogleCloud.networks(of: name, instance, service).map { (project: $0.project, network: $0.network, ipv6: true) }
                candidates = GoogleCloud.isolationRules(tag: tag, networks: networks)
            }
            let states = try await GoogleCloud.existing(candidates, id: id, tag: tag, service)
            if let other = states.first(where: { $0.state == "other" }) {
                throw ServiceError.input("Nothing was changed: \(other.rule.said) is not exactly a rule Pion made to isolate this VM, as its description, network, tag, priority or traffic differs, so it is left for someone to check.")
            }
            // A rule of Pion's someone turned off is still Pion's to remove.
            let owned = states.filter { $0.state.hasPrefix("pion") }.map(\.rule)
            let tags = instance.tags?.items ?? []
            struct Kept: Encodable { let instance: String, tag: String, removedTag: Bool, deleted: [String], operations: [String] }
            guard tags.contains(tag) || !owned.isEmpty else {
                return try ServiceResult(text: "\(name.said) carries no isolation tag of Pion's and no rule of Pion's isolates it\(input.firewallRules == nil ? " on its networks now" : ""); nothing was changed. If its networks changed since isolate-instance, give firewallRules as it reported them.",
                                         structured: Kept(instance: name.said, tag: tag, removedTag: false, deleted: [], operations: []))
            }
            let compute = try GoogleCloud.on(.compute, service)
            var done: [String] = [], deleted: [String] = [], operations: [String] = []
            // The tag goes first, ending the isolation, and only if the VM's tags are as read.
            if tags.contains(tag) {
                guard let fingerprint = instance.tags?.fingerprint, !fingerprint.isEmpty else {
                    throw ServiceError.input("Nothing was changed: Google gave \(name.said)'s tags no fingerprint, so its tag cannot be removed knowing its tags are as Pion read them.")
                }
                struct Body: Encodable { let items: [String]; let fingerprint: String }
                let body = try JSONEncoder().encode(Body(items: tags.filter { $0 != tag }, fingerprint: fingerprint))
                let answer = try await GoogleCloud.change("removing tag \(tag) from \(name.said)", GoogleCloud.instanceNeed, own) {
                    try await compute.exchange(name.path + ["setTags"], method: "POST", body: body, returning: [412])
                }
                if answer.response.statusCode == 412 {
                    throw ServiceError.input("Nothing was changed: \(name.said)'s tags changed since Pion read them, so Google refused to remove \(tag). Run unisolate-instance again to read them afresh.")
                }
                if let errors = GoogleCloud.operationErrors(answer.data) {
                    throw ServiceError.input("Nothing was changed: removing tag \(tag) from \(name.said) failed: \(errors).")
                }
                done.append("removed tag \(tag) from \(name.said)")
                if let operation = GoogleCloud.operationPath(answer.data, fallback: ["projects", name.project, "zones", name.zone]) { operations.append(operation) }
            }
            let undo = "The rules left deny traffic only to VMs tagged \(tag), which none now is; run unisolate-instance again, or delete them in the console."
            for rule in owned {
                // Compute Engine takes no condition on deleting a rule, so it is read again, as close to the deletion as
                // can be, and deleted only while it is still exactly Pion's.
                let again = try await GoogleCloud.change("reading \(rule.said) again", GoogleCloud.firewallNeed, own, done: done, undo: undo) {
                    try await GoogleCloud.existing([rule], id: id, tag: tag, service)
                }
                if again.first?.state == "absent" { continue }
                guard again.first?.state.hasPrefix("pion") == true else {
                    throw GoogleCloud.stopped(done, Failure(text: "\(rule.said) changed since Pion read it and is no longer exactly Pion's, so it was not deleted", unsure: false), undo: undo)
                }
                let answer = try await GoogleCloud.change("deleting \(rule.said)", GoogleCloud.firewallNeed, own, done: done, undo: undo) {
                    try await compute.exchange(rule.path, method: "DELETE", returning: [404])
                }
                // A rule gone meanwhile is as wanted.
                if answer.response.statusCode != 404 {
                    if let errors = GoogleCloud.operationErrors(answer.data) {
                        throw GoogleCloud.stopped(done, Failure(text: "deleting \(rule.said) failed: \(errors)", unsure: false), undo: undo)
                    }
                    if let operation = GoogleCloud.operationPath(answer.data, fallback: ["projects", rule.project, "global"]) { operations.append(operation) }
                }
                done.append("deleted rule \(rule.said)")
                deleted.append(rule.said)
            }
            guard !done.isEmpty else {
                return try ServiceResult(text: "Pion's rules for \(name.said) were gone by the time they were read again, and it carries no tag of Pion's; nothing was changed.",
                                         structured: Kept(instance: name.said, tag: tag, removedTag: false, deleted: [], operations: []))
            }
            let progress = operations.isEmpty ? "" : " once Compute Engine finishes: read \(GoogleCloud.listed(operations)) with operation-status"
            let text = "Undid \(name.said)'s isolation: \(done.joined(separator: "; ")). Its traffic follows its other firewall rules again\(progress). Compute Engine takes no condition on deleting a rule: Pion read each just before deleting it and checked it was still exactly its own. To undo: isolate-instance."
            return try ServiceResult(text: text, structured: Kept(instance: name.said, tag: tag, removedTag: tags.contains(tag), deleted: deleted, operations: operations))
        }
    }

    struct ComputeOperationStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let operation: String }
        static let name = "operation-status"
        static let summary = "How a Compute Engine operation this tool started is going, by the path it returned: pending, running, done, or done with errors."
        static let input = JSONSchema.object(["operation": .string("The operation's path an action returned, such as projects/PROJECT-ID/zones/ZONE/operations/NAME, or projects/PROJECT-ID/global/operations/NAME.")],
                                             required: ["operation"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let own = try GoogleCloud.own(service)
            // Only Compute Engine's own places for operations, read on its own host whatever host a link named.
            guard let parts = GoogleCloud.computeParts(input.operation), GoogleCloud.isOperation(parts) else {
                throw ServiceError.input("Give the operation's path as an action returned it, projects/PROJECT-ID/zones/ZONE/operations/NAME, …/regions/REGION/operations/NAME or …/global/operations/NAME; other paths are not read here.")
            }
            _ = try await GoogleCloud.inside(.project(parts[1]), service)
            let compute = try GoogleCloud.on(.compute, service)
            let data = try await GoogleCloud.read(GoogleCloud.operationNeed, own) { try await compute.data(["compute", "v1"] + parts) }
            struct Kept: Encodable { let operation: String, status: String, errors: String?, target: String? }
            let path = parts.joined(separator: "/")
            guard let read = try? JSONDecoder().decode(Operation.self, from: data), read.kind == "compute#operation",
                  let status = GoogleCloud.shaped(read.status, "PENDING|RUNNING|DONE") else {
                return try ServiceResult(text: "Google's answer did not say how \(path) is going; check the resource in the console.",
                                         structured: Kept(operation: path, status: "unknown", errors: nil, target: nil))
            }
            let errors = GoogleCloud.operationErrors(data)
            let target = read.targetLink.flatMap(GoogleCloud.computeParts).map { $0.joined(separator: "/") }.flatMap { GoogleCloud.shaped($0, #"projects/[A-Za-z0-9.:/_-]{1,400}"#) }
            let type = GoogleCloud.shaped(read.operationType, "[A-Za-z]{1,40}").map { "\($0) " } ?? ""
            let said = status == "DONE" ? (errors == nil ? "done" : "done with errors: \(errors!)") : status.lowercased()
            return try ServiceResult(text: "The \(type)operation \(path)\(target.map { " on \($0)" } ?? "") is \(said).",
                                     structured: Kept(operation: path, status: errors == nil ? status : "FAILED", errors: errors, target: target))
        }
    }
}

// MARK: Checking access

extension GoogleCloud {
    /// Tries what containment can without changing anything: which of its permissions the account signed in holds on
    /// the scope, and whether the APIs it uses answer.
    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable { let project: String? }
        static let name = "check-access"
        static let summary = "Asks Google which of the Pion Containment role's permissions the account signed in holds on the scope, and on a project when given, and whether the APIs containment uses are enabled, saying exactly what to add for each action that lacks something, and warning when the account can do far more. It changes nothing."
        static let input = JSONSchema.object(["project": .string("A project inside the scope, as projects/PROJECT-ID, to check the Compute Engine and Cloud Storage APIs and the permissions held there; the scope's own project for a project's account when left out.")])

        /// What each action needs, and for which scopes it applies.
        static func needs(_ level: String) -> [(operation: String, permissions: [String])] {
            var needs: [(operation: String, permissions: [String])] = [
                ("every action, to check where a resource lies", level == "projects" ? ["resourcemanager.projects.get"] : ["resourcemanager.projects.get", "resourcemanager.folders.get"]),
                ("\(DisableKey.name) and \(EnableKey.name)", ["iam.serviceAccounts.get", "iam.serviceAccountKeys.get", "iam.serviceAccountKeys.disable", "iam.serviceAccountKeys.enable"]),
                ("\(DisableServiceAccount.name) and \(EnableServiceAccount.name)", ["iam.serviceAccounts.get", "iam.serviceAccounts.disable", "iam.serviceAccounts.enable"]),
                ("\(RemoveIAMMember.name) on projects", ["resourcemanager.projects.getIamPolicy", "resourcemanager.projects.setIamPolicy"]),
            ]
            if level != "projects" { needs.append(("\(RemoveIAMMember.name) on folders", ["resourcemanager.folders.getIamPolicy", "resourcemanager.folders.setIamPolicy"])) }
            if level == "organizations" { needs.append(("\(RemoveIAMMember.name) on the organisation", ["resourcemanager.organizations.getIamPolicy", "resourcemanager.organizations.setIamPolicy"])) }
            needs += [
                ("\(EnforcePublicAccessPrevention.name) and \(RevertPublicAccessPrevention.name)", ["storage.buckets.get", "storage.buckets.update"]),
                (SnapshotDisks.name, ["compute.instances.get", "compute.disks.createSnapshot", "compute.snapshots.create", "compute.snapshots.setLabels"]),
                (StopInstance.name, ["compute.instances.get", "compute.instances.stop"]),
                ("\(IsolateInstance.name) and \(UnisolateInstance.name)", ["compute.instances.get", "compute.instances.setTags", "compute.firewalls.get", "compute.firewalls.create",
                                                                          "compute.firewalls.delete", "compute.networks.updatePolicy"]),
                (ComputeOperationStatus.name, ["compute.zoneOperations.get", "compute.regionOperations.get", "compute.globalOperations.get"]),
            ]
            return needs
        }

        /// Permissions far beyond containment, which the Pion Containment role never holds.
        static let beyond = ["resourcemanager.projects.delete", "iam.serviceAccountKeys.create", "iam.serviceAccounts.actAs", "iam.roles.update",
                             "compute.instances.delete", "compute.instances.setMetadata", "storage.buckets.delete", "storage.objects.get"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let scope = try GoogleCloud.scope(service), own = "\(scope.level)/\(scope.id)"
            let manager = try GoogleCloud.on(.resourceManager, service)
            var lines: [String] = []
            var project: Place? = scope.level == "projects" ? .project(scope.id) : nil
            if let given = input.project {
                let place = try GoogleCloud.place(given)
                guard case .project = place else { throw ServiceError.input("Give project as projects/PROJECT-ID.") }
                project = try await GoogleCloud.inside(place, service)
            }
            let found = await GoogleCloud.signedIn(service)
            if let signer = try? GoogleCloud.signer(service) {
                if let email = found.email {
                    lines.append(email == signer ? "✓ Signed in as \(email), the Account that signs in entered; remove-iam-member refuses to remove its own access."
                        : "✗ Signed in as \(email), but Account that signs in is \(signer): remove-iam-member refuses everything until they match; fix one in Settings › Tools.")
                } else {
                    lines.append("✗ Which account signed in could not be confirmed (\(found.why ?? "no answer")), so remove-iam-member refuses everything: add the scope \(GoogleCloud.emailScope) under Data Access and sign the tool in again.")
                }
            } else {
                lines.append("✗ Account that signs in: not set to an email, so remove-iam-member refuses everything until it is; set it in Settings › Tools.")
            }
            let needs = Self.needs(scope.level)
            let asked = Array(Set(needs.flatMap(\.permissions) + Self.beyond)).sorted()
            struct Permissions: Codable { let permissions: [String]? }
            func held(on place: Place) async throws -> Set<String> {
                let answer = try await GoogleCloud.read(GoogleCloud.placeNeed, own) {
                    try await manager.post(["v3"] + Array(place.path.dropLast()) + ["\(place.path.last!):testIamPermissions"], body: Permissions(permissions: asked), as: Permissions.self)
                }
                // Only the permissions asked about are taken from the answer.
                return Set(answer.permissions ?? []).intersection(asked)
            }
            let scopePlace: Place = scope.level == "projects" ? .project(scope.id) : scope.level == "folders" ? .folder(scope.id) : .organization(scope.id)
            var onScope: Set<String> = [], onProject: Set<String> = []
            do {
                onScope = try await held(on: scopePlace)
                lines.append("✓ Cloud Resource Manager API answers, for \(own).")
            } catch {
                lines.append("✗ Which permissions the account holds on \(own) could not be read: \(error.localizedDescription)")
                return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
            }
            if let project, project != scopePlace {
                do { onProject = try await held(on: project) }
                catch { lines.append("✗ Which permissions the account holds on \(project.name) could not be read: \(error.localizedDescription)") }
            }
            for need in needs {
                let missing = need.permissions.filter { !onScope.contains($0) }
                if missing.isEmpty { lines.append("✓ \(need.operation)"); continue }
                let there = missing.filter { !onProject.contains($0) }
                if there.isEmpty, let project {
                    lines.append("· \(need.operation): held on \(project.name) only, not on all of \(own); add \(missing.joined(separator: ", ")) to the Pion Containment role on \(own) for the rest.")
                } else {
                    lines.append("✗ \(need.operation): add \(missing.joined(separator: ", ")) to the Pion Containment role granted on \(own).")
                }
            }
            let excess = Self.beyond.filter { onScope.contains($0) || onProject.contains($0) }
            if !excess.isEmpty {
                lines.append("⚠ The account signed in can do far more than containment, such as \(excess.joined(separator: ", ")): the cloud-platform scope lets this sign-in do the same. Sign in instead with an account holding only the Pion Containment custom role.")
            }
            if onScope.contains("resourcemanager.projects.setIamPolicy") || onScope.contains("resourcemanager.folders.setIamPolicy") || onScope.contains("resourcemanager.organizations.setIamPolicy") {
                lines.append("· remove-iam-member's setIamPolicy permission lets this sign-in change any binding on \(own), granting as well as removing; Pion only removes, but leave it out of the role if agents should not remove access.")
            }
            // Whether each API answers: anything but Google saying it is turned off shows it is on.
            func api(_ title: String, _ apiID: String, _ probe: () async throws -> Void) async -> String {
                do { try await probe(); return "✓ \(title) is enabled." } catch {
                    let need = GoogleCloud.containmentNeed(title, api: title, apiID: apiID, [])
                    let said = error.localizedDescription.lowercased()
                    if said.contains("has not been used in project") || said.contains("service_disabled") || said.contains("it is disabled") {
                        return "✗ \(title): " + (GoogleCloud.fix(for: error, need, on: own) ?? error.localizedDescription)
                    }
                    if case ServiceError.forbidden = error { return "✓ \(title) is enabled; the probe itself was refused, which the permissions above cover." }
                    if case ServiceError.notFound = error { return "✓ \(title) is enabled." }
                    return "· \(title): could not be checked: \(error.localizedDescription)"
                }
            }
            let iam = try GoogleCloud.on(.iam, service)
            lines.append(await api("Identity and Access Management (IAM) API", "iam.googleapis.com") { _ = try await iam.data(["v1", "roles"], query: ["pageSize": "1"]) })
            if case .project(let id)? = project {
                let compute = try GoogleCloud.on(.compute, service), storage = try GoogleCloud.on(.storage, service)
                lines.append(await api("Compute Engine API", "compute.googleapis.com") { _ = try await compute.data(["compute", "v1", "projects", id]) })
                lines.append(await api("Cloud Storage API", "storage-api.googleapis.com") { _ = try await storage.data(["storage", "v1", "b"], query: ["project": id, "maxResults": "1"]) })
            } else {
                lines.append("· Compute Engine and Cloud Storage APIs: not checked; give check-access a project inside \(own) to check them.")
            }
            lines.append("· What the account can do is asked of Google, not tried: an action can still be refused by a deny policy, an organisation policy or VPC Service Controls.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
