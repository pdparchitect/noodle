import Foundation
import NoodleCore
import NoodleToolConnections

/// Microsoft Azure Containment: acting on one subscription to contain an incident, through an app registration of its
/// own, kept apart from Microsoft Azure Audit's so the audit app stays read-only. Every resource it acts on must be
/// inside the account's subscription, and what cuts off access, stops a VM or deletes something waits for the
/// champion's approval.
extension Azure {
    public static let containment = ToolDefinition(
        id: "116a2a76-6172-4054-bef0-739517b2ecb9", name: "Microsoft Azure Containment",
        summary: "Remove a role assignment, deallocate or isolate a VM, rotate a storage key, close a storage account to public and shared key access, lock a resource, snapshot a disk and set or close a Defender for Cloud alert.",
        defaultInstructions: """
        Use Microsoft Azure Containment to contain an incident in one subscription. Find what to act on with Microsoft \
        Azure Audit first, and give each resource by its full ID. remove-role-assignment takes away access, saying what \
        the assignment was, so record that as evidence; it cannot remove access inherited from a management group or \
        held through a group's membership. isolate-vm adds deny-all inbound and outbound rules, named after the VM, at \
        priority 100 to the network security group of each of the VM's network interfaces, refusing one shared with \
        other interfaces or subnets unless allowShared is set, and refusing when a rule already holds priority 100; it \
        returns the isolation's ID and the exact rules added, so record them. Connections already open may continue until \
        they close, so deallocate-vm stops the VM when it must stop now, losing what is only in its memory: snapshot its \
        disks first with snapshot-disk. unisolate-vm removes only rules isolate-vm added for that VM, from the groups \
        isolate-vm reported when given them. rotate-storage-key replaces one access key, ending what uses it and the SAS \
        tokens it signed; rotate both if both may be known. restrict-storage turns off anonymous public blob access and \
        shared key access, which stops every key and SAS token at once. add-lock stops a resource, its resource group or \
        the subscription being deleted, such as evidence or logging an attacker may remove. set-alert-status marks a \
        Defender for Cloud alert active or in progress; close-alert resolves or dismisses one, which takes it out of the \
        alert watch. Long operations return a status path: read it with operation-status. remove-role-assignment, \
        deallocate-vm, isolate-vm, unisolate-vm, rotate-storage-key, restrict-storage and close-alert are held for the \
        champion's approval: give the exact resource, and in --approval-reason why, the expected effect and how to undo \
        it, with the Investigation as --approval-conversation. Run check-access when something is refused, and tell the \
        champion exactly what it says to add to the app's role.
        """,
        iconName: "azure",
        configuration: .connection(.init(endpointTemplate: "https://management.azure.com",
            fields: [ToolField(key: "tenant", title: "Directory (tenant) ID", placeholder: "contoso.onmicrosoft.com", kind: .identifier),
                     ToolField(key: "subscription", title: "Subscription ID", placeholder: "8a7f3c2e-0000-4000-8000-000000000002", kind: .identifier)],
            clientCredentials: ClientCredentialsPreset(tokenEndpointTemplate: "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token",
                                                       scope: "https://management.azure.com/.default"),
            adapter: "azure-containment")),
        setup: containmentSetup)

    static let containmentSetup = [
        "In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** and register a new app for containment alone, such as Pion Containment, apart from Microsoft Azure Audit's. Keep **Single tenant**, leave the redirect URI empty, and add a client secret under **Certificates & secrets**, copying its **Value**.",
        "In the [Azure portal](https://portal.azure.com), open the subscription's **Access control (IAM)** and choose **Add › Add custom role**. Name it Pion Containment and, under **JSON**, give it only these actions: \(containmentActions.map { "`\($0)`" }.joined(separator: ", ")). Leave out any whose action you do not want agents to have.",
        "Assign that role to the app on the subscription. Never give it Owner or Contributor: its role, not Pion, limits what it can do.",
        "Copy the **Subscription ID**, and the app's **Directory (tenant) ID** and **Application (client) ID**. Choose **Add & Connect** and ask an agent to run check-access.",
    ]

    /// Every action the containment operations take, for the custom role its setup makes.
    static let containmentActions = [
        "Microsoft.Authorization/*/read", "Microsoft.Authorization/roleAssignments/delete", "Microsoft.Authorization/locks/write",
        "Microsoft.Compute/virtualMachines/read", "Microsoft.Compute/virtualMachines/deallocate/action",
        "Microsoft.Compute/disks/read", "Microsoft.Compute/snapshots/read", "Microsoft.Compute/snapshots/write", "Microsoft.Compute/locations/*/read",
        "Microsoft.Network/networkInterfaces/read", "Microsoft.Network/networkSecurityGroups/read",
        "Microsoft.Network/networkSecurityGroups/securityRules/read", "Microsoft.Network/networkSecurityGroups/securityRules/write",
        "Microsoft.Network/networkSecurityGroups/securityRules/delete", "Microsoft.Network/locations/*/read",
        "Microsoft.Storage/storageAccounts/read", "Microsoft.Storage/storageAccounts/write", "Microsoft.Storage/storageAccounts/regeneratekey/action",
        "Microsoft.Security/locations/alerts/*",
    ]

    public static let containmentAdapter = OperationAdapter(operations: [
        RemoveRoleAssignment(), DeallocateVM(), IsolateVM(), UnisolateVM(), RotateStorageKey(), RestrictStorage(), AddLock(), SnapshotDisk(),
        SetAlertStatus(), CloseAlert(), OperationStatus(), ContainmentCheckAccess(),
    ])

    static let computeVersion = "2024-07-01", diskVersion = "2024-03-02", networkVersion = "2024-05-01", storageVersion = "2023-05-01", lockVersion = "2020-05-01"
    static let isolationPriority = 100
    static let lockName = "pion-containment"

    static func joined(_ parts: [String]) -> String { "/" + parts.joined(separator: "/") }

    /// Whether a path's parts are one of Azure's own places to read a long operation's progress:
    /// subscriptions/…/providers/NAMESPACE/locations/LOCATION/operations/ID, or operationResults, asyncoperations,
    /// operationStatuses or DiskOperations in place of operations.
    static func isStatus(_ parts: [String]) -> Bool {
        parts.count == 8 && parts[0].lowercased() == "subscriptions" && parts[2].lowercased() == "providers"
            && parts[3].range(of: #"^[A-Za-z0-9]+(\.[A-Za-z0-9]+)+$"#, options: .regularExpression) != nil && parts[4].lowercased() == "locations"
            && ["operations", "operationresults", "asyncoperations", "operationstatuses", "diskoperations"].contains(parts[6].lowercased())
    }

    /// Where to read a long operation's progress, from Azure's answer: the path and query of its Azure-AsyncOperation
    /// or Location header, only when it is on management.azure.com, inside the account's subscription and one of
    /// Azure's own places for an operation's progress.
    static func statusPath(_ response: HTTPURLResponse, subscription: String) -> String? {
        for header in ["Azure-AsyncOperation", "Location"] {
            guard let value = response.value(forHTTPHeaderField: header), let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == "management.azure.com", url.port == nil, url.user == nil,
                  url.percentEncodedPath.lowercased().hasPrefix("/subscriptions/\(subscription.lowercased())/"),
                  isStatus(url.path.split(separator: "/").map(String.init)) else { continue }
            return url.percentEncodedPath + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
        }
        return nil
    }

    static func started(_ what: String, _ response: HTTPURLResponse, _ service: ServiceClient) throws -> (text: String, status: String?) {
        let status = statusPath(response, subscription: try subscription(service))
        guard response.statusCode == 202 || response.statusCode == 201, let status else { return (what + ".", nil) }
        return ("\(what); Azure is still working on it. Read its progress with operation-status and status \(status).", status)
    }

    static func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

    /// A resource read as JSON, for the few fields an action needs.
    static func fetch(_ service: ServiceClient, _ parts: [String], version: String) async throws -> JSON {
        try await service.get(parts, query: ["api-version": version], as: JSON.self)
    }

    struct ResourceInput: Decodable, Sendable { let resource: String }

    struct RemoveRoleAssignment: ServiceOperation {
        struct Input: Decodable, Sendable { let assignment: String }
        static let name = "remove-role-assignment"
        static let summary = "Remove one role assignment, by its full ID from role-assignments, saying what it granted to whom and where."
        static let input = JSONSchema.object(["assignment": .string("The role assignment's full ID, such as /subscriptions/…/providers/Microsoft.Authorization/roleAssignments/GUID.")],
                                             required: ["assignment"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let parts = try Azure.resource(input.assignment, service, "the role assignment")
            guard parts.count >= 6, parts.suffix(4).dropLast().map({ $0.lowercased() }) == ["providers", "microsoft.authorization", "roleassignments"],
                  UUID(uuidString: parts.last ?? "") != nil else {
                throw ServiceError.input("Give the role assignment's full ID, ending in /providers/Microsoft.Authorization/roleAssignments/ and its GUID, as role-assignments lists it.")
            }
            let found = try await Azure.fetch(service, parts, version: Azure.authorizationVersion)
            let principal = Azure.field(found, ["properties", "principalId"])?.text ?? "?", role = Azure.field(found, ["properties", "roleDefinitionId"])?.text ?? "?"
            let scope = Azure.field(found, ["properties", "scope"])?.text ?? "?"
            _ = try await service.data(parts, query: ["api-version": Azure.authorizationVersion], method: "DELETE")
            return try ServiceResult(text: "Removed the assignment of role \(role) to \(principal) on \(scope). Access held through a group or inherited from a management group stays; re-create the assignment to undo.",
                                     structured: ["assignment": Azure.joined(parts), "principalId": principal, "roleDefinitionId": role, "scope": scope])
        }
    }

    struct DeallocateVM: ServiceOperation {
        struct Input: Decodable, Sendable { let vm: String }
        static let name = "deallocate-vm"
        static let summary = "Stop a VM and release its compute, ending everything running on it and what is only in its memory; its disks stay. Start it again in the Azure portal."
        static let input = JSONSchema.object(["vm": .string("The VM's full ID.")], required: ["vm"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let vm = try Azure.resource(input.vm, service, type: "Microsoft.Compute/virtualMachines", "the VM")
            let answer = try await service.exchange(vm + ["deallocate"], query: ["api-version": Azure.computeVersion], method: "POST")
            let said = try Azure.started("Deallocating \(vm.last ?? "the VM")", answer.response, service)
            return try ServiceResult(text: said.text, structured: ["vm": Azure.joined(vm), "status": said.status ?? "done"])
        }
    }

    /// A VM's network interfaces, each inside the subscription; one listed without its ID stops everything.
    static func interfaces(of vm: [String], _ service: ServiceClient) async throws -> [[String]] {
        let machine = try await fetch(service, vm, version: computeVersion)
        guard case .array(let listed)? = field(machine, ["properties", "networkProfile", "networkInterfaces"]), !listed.isEmpty else {
            throw ServiceError.input("Nothing was changed: the VM lists no network interfaces, so it cannot be isolated this way; deallocate-vm stops it instead.")
        }
        return try listed.map { interface in
            guard let id = field(interface, ["id"])?.text else {
                throw ServiceError.input("Nothing was changed: the VM lists a network interface without its ID; check the VM in the Azure portal, or deallocate-vm.")
            }
            return try resource(id, service, type: "Microsoft.Network/networkInterfaces", "the VM's network interface")
        }
    }

    /// The network security groups of those interfaces, each inside the subscription; an interface without one stops
    /// everything.
    static func securityGroups(on interfaces: [[String]], _ service: ServiceClient) async throws -> [[String]] {
        var groups: [[String]] = []
        for nic in interfaces {
            let read = try await fetch(service, nic, version: networkVersion)
            guard let groupID = field(read, ["properties", "networkSecurityGroup", "id"])?.text else {
                throw ServiceError.input("Nothing was changed: the VM's network interface \(joined(nic)) has no network security group; add one to it in the Azure portal, or deallocate-vm.")
            }
            let group = try resource(groupID, service, type: "Microsoft.Network/networkSecurityGroups", "the network security group")
            if !groups.contains(where: { same($0, group) }) { groups.append(group) }
        }
        return groups
    }

    static func same(_ first: [String], _ second: [String]) -> Bool { first.map { $0.lowercased() } == second.map { $0.lowercased() } }

    /// A network security group as read now: whether it also serves interfaces other than `own`, or subnets, and its rules.
    struct SecurityGroup { let parts: [String]; let shared: Bool; let rules: [JSON] }

    static func inspect(group: [String], own: [[String]], _ service: ServiceClient) async throws -> SecurityGroup {
        let read = try await fetch(service, group, version: networkVersion)
        let mine = Set(own.map { joined($0).lowercased() })
        var others = 0
        if case .array(let attached)? = field(read, ["properties", "networkInterfaces"]) {
            others += attached.filter { !mine.contains(field($0, ["id"])?.text?.lowercased() ?? "") }.count
        }
        if case .array(let subnets)? = field(read, ["properties", "subnets"]) { others += subnets.count }
        var rules: [JSON] = []
        if case .array(let listed)? = field(read, ["properties", "securityRules"]) { rules = listed }
        return SecurityGroup(parts: group, shared: others > 0, rules: rules)
    }

    /// What tells one VM's isolation rules from any other rule: a digest of the VM's ID, in their names and in the
    /// description each carries, by which unisolate-vm knows them as Pion's for that VM.
    static func isolationToken(_ vm: String) -> String { String(safeID("", vm.lowercased()).prefix(12)) }
    static func isolationRules(_ vm: String) -> [(direction: String, name: String)] {
        let token = isolationToken(vm)
        return [("Inbound", "pion-isolate-\(token)-in"), ("Outbound", "pion-isolate-\(token)-out")]
    }
    static func isolationMark(_ vm: String) -> String { "of VM \(isolationToken(vm))" }

    static func refusedShared(_ shared: [SecurityGroup]) -> ServiceError {
        let names = shared.map { joined($0.parts) }
        return ServiceError.input("Nothing was changed: \(GoogleCloud.listed(names)) also serve\(names.count == 1 ? "s" : "") other network interfaces or subnets, which this would affect too. Give allowShared to go ahead, or give the VM a network security group of its own.")
    }

    struct IsolateVM: ServiceOperation {
        struct Input: Decodable, Sendable { let vm: String, allowShared: Bool? }
        static let name = "isolate-vm"
        static let summary = "Cut a VM off the network: add deny-all inbound and outbound rules, named after the VM, at priority 100 to the network security group of each of its network interfaces, returning the isolation's ID and the rules added. It refuses a group shared with other interfaces or subnets unless allowShared, and any rule already at priority 100 or of the same name. Connections already open may continue until they close. Undo with unisolate-vm."
        static let input = JSONSchema.object([
            "vm": .string("The VM's full ID."),
            "allowShared": .boolean("Isolate even when a network security group also serves other network interfaces or subnets, which cuts them off too."),
        ], required: ["vm"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let vm = try Azure.resource(input.vm, service, type: "Microsoft.Compute/virtualMachines", "the VM")
            let id = Azure.joined(vm)
            let interfaces = try await Azure.interfaces(of: vm, service)
            var groups: [SecurityGroup] = []
            for group in try await Azure.securityGroups(on: interfaces, service) { groups.append(try await Azure.inspect(group: group, own: interfaces, service)) }
            let shared = groups.filter(\.shared)
            if !shared.isEmpty, input.allowShared != true { throw Azure.refusedShared(shared) }
            // Nothing is replaced: a rule of the same name, or one already first in either direction, stops it all.
            let rules = Azure.isolationRules(id)
            for group in groups {
                for rule in group.rules {
                    let name = Azure.field(rule, ["name"])?.text ?? "?", direction = Azure.field(rule, ["properties", "direction"])?.text?.lowercased()
                    if rules.contains(where: { $0.name.lowercased() == name.lowercased() }) {
                        throw ServiceError.input("Nothing was changed: \(Azure.joined(group.parts)) already has rule \(name), so this VM may already be isolated; run unisolate-vm first.")
                    }
                    guard case .number(let priority)? = Azure.field(rule, ["properties", "priority"]), Int(priority) == Azure.isolationPriority,
                          rules.contains(where: { $0.direction.lowercased() == direction }) else { continue }
                    throw ServiceError.input("Nothing was changed: rule \(name) of \(Azure.joined(group.parts)) already holds priority \(Azure.isolationPriority) for \(direction ?? "its") traffic, so a deny-all rule cannot come before it. Move or remove that rule, then try again, or deallocate-vm.")
                }
            }
            let isolation = String(UUID().uuidString.prefix(8)).lowercased()
            var added: [String] = [], statuses: [String] = []
            for group in groups {
                for rule in rules {
                    let path = group.parts + ["securityRules", rule.name]
                    let body = try Azure.json(["properties": [
                        "priority": Azure.isolationPriority, "direction": rule.direction, "access": "Deny", "protocol": "*",
                        "sourceAddressPrefix": "*", "sourcePortRange": "*", "destinationAddressPrefix": "*", "destinationPortRange": "*",
                        "description": "Pion isolation \(isolation) \(Azure.isolationMark(id)). Remove with unisolate-vm.",
                    ]])
                    // Only made, never replacing a rule of that name that appeared since the group was read.
                    var failure: String?
                    do {
                        let answer = try await service.exchange(path, query: ["api-version": Azure.networkVersion], method: "PUT", body: body,
                                                                headers: ["If-None-Match": "*"], returning: [412])
                        if answer.response.statusCode == 412 {
                            failure = "a rule named \(rule.name) appeared on \(Azure.joined(group.parts)) since it was read, and was not replaced"
                        } else {
                            added.append(Azure.joined(path))
                            if let status = Azure.statusPath(answer.response, subscription: try Azure.subscription(service)) { statuses.append(status) }
                        }
                    } catch {
                        failure = "adding \(rule.name) to \(Azure.joined(group.parts)) failed: \(error.localizedDescription)"
                    }
                    if let failure {
                        throw ServiceError.input(added.isEmpty
                            ? "Nothing was changed: \(failure)."
                            : "Isolation \(isolation) was only partly applied: added \(GoogleCloud.listed(added)); then \(failure). Run unisolate-vm to remove what was added, then try again, or deallocate-vm.")
                    }
                }
            }
            let names = groups.map { Azure.joined($0.parts) }
            struct Kept: Encodable { let isolation: String, vm: String, networkSecurityGroups: [String], rules: [String], status: [String] }
            return try ServiceResult(text: "Isolation \(isolation): added deny-all inbound and outbound rules at priority \(Azure.isolationPriority) to \(GoogleCloud.listed(names)): \(GoogleCloud.listed(added)). Connections already open may continue until they close; deallocate-vm stops the VM itself. Undo with unisolate-vm, giving these network security groups."
                                        + (statuses.isEmpty ? "" : " Azure is applying them; read progress with operation-status and \(statuses[0])."),
                                     structured: Kept(isolation: isolation, vm: id, networkSecurityGroups: names, rules: added, status: statuses))
        }
    }

    struct UnisolateVM: ServiceOperation {
        struct Input: Decodable, Sendable { let vm: String, networkSecurityGroups: [String]?, allowShared: Bool? }
        static let name = "unisolate-vm"
        static let summary = "Undo isolate-vm: remove the rules isolate-vm added for this VM, and only those, from the network security groups isolate-vm reported, or else those of the VM's network interfaces now, letting traffic back. A rule of that name Pion did not add for this VM stops it."
        static let input = JSONSchema.object([
            "vm": .string("The VM's full ID."),
            "networkSecurityGroups": .array(.string("A network security group's full ID."), "The groups isolate-vm reported, up to 8; those of the VM's network interfaces now when left out."),
            "allowShared": .boolean("Go ahead even when a network security group also serves other network interfaces or subnets, which lets their traffic back too."),
        ], required: ["vm"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let vm = try Azure.resource(input.vm, service, type: "Microsoft.Compute/virtualMachines", "the VM")
            let id = Azure.joined(vm)
            let named = try input.networkSecurityGroups.map { given in
                try ServiceInput.list(given, limit: 8) { $0 }.map {
                    try Azure.resource($0, service, type: "Microsoft.Network/networkSecurityGroups", "the network security group")
                }
            }
            let interfaces = try await Azure.interfaces(of: vm, service)
            var found = named ?? []
            if named == nil { found = try await Azure.securityGroups(on: interfaces, service) }
            var groups: [SecurityGroup] = []
            for group in found {
                groups.append(try await Azure.inspect(group: group, own: interfaces, service))
            }
            let shared = groups.filter(\.shared)
            if !shared.isEmpty, input.allowShared != true { throw Azure.refusedShared(shared) }
            // Each rule of this VM's names is checked as Pion's for it before any is removed.
            let mark = Azure.isolationMark(id)
            var owned: [(path: [String], etag: String)] = []
            for group in groups {
                for rule in Azure.isolationRules(id) {
                    guard let found = group.rules.first(where: { Azure.field($0, ["name"])?.text?.lowercased() == rule.name.lowercased() }) else { continue }
                    let description = Azure.field(found, ["properties", "description"])?.text ?? ""
                    guard description.contains(mark), Azure.field(found, ["properties", "access"])?.text?.lowercased() == "deny" else {
                        throw ServiceError.input("Nothing was changed: rule \(rule.name) of \(Azure.joined(group.parts)) was not added by Pion for this VM, as its description or access differs, so it is left for someone to check.")
                    }
                    // Removed only as it was read: its etag goes with the deletion, so a rule replaced since stays.
                    guard let etag = Azure.field(found, ["etag"])?.text, !etag.isEmpty else {
                        throw ServiceError.input("Nothing was changed: Azure gave rule \(rule.name) of \(Azure.joined(group.parts)) no etag, so it cannot be removed knowing it is the rule that was checked.")
                    }
                    owned.append((group.parts + ["securityRules", rule.name], etag))
                }
            }
            let names = groups.map { Azure.joined($0.parts) }
            guard !owned.isEmpty else {
                return try ServiceResult(text: "No isolation rules of this VM were found on \(GoogleCloud.listed(names)). If its network interfaces changed since isolate-vm, give networkSecurityGroups as isolate-vm reported them.",
                                         structured: ["removed": [String]()])
            }
            var removed: [String] = []
            for rule in owned {
                var failure: String?
                do {
                    let answer = try await service.exchange(rule.path, query: ["api-version": Azure.networkVersion], method: "DELETE",
                                                            headers: ["If-Match": rule.etag], returning: [412])
                    if answer.response.statusCode == 412 {
                        failure = "rule \(Azure.joined(rule.path)) changed since it was read, so it was not removed; read it again before deciding"
                    } else {
                        removed.append(Azure.joined(rule.path))
                    }
                } catch ServiceError.notFound {
                    removed.append(Azure.joined(rule.path))
                } catch {
                    failure = "removing \(Azure.joined(rule.path)) failed: \(error.localizedDescription)"
                }
                if let failure {
                    throw ServiceError.input((removed.isEmpty ? "Nothing was changed: " : "Only partly undone: removed \(GoogleCloud.listed(removed)); then ") + failure + ".")
                }
            }
            return try ServiceResult(text: "Removed \(GoogleCloud.listed(removed)).", structured: ["vm": [id], "removed": removed])
        }
    }

    struct RotateStorageKey: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String, key: String }
        static let name = "rotate-storage-key"
        static let summary = "Replace one of a storage account's two access keys, ending whatever uses it and every SAS token it signed. The new key is never shown."
        static let input = JSONSchema.object([
            "account": .string("The storage account's full ID."),
            "key": .string("Which key.", oneOf: ["key1", "key2"]),
        ], required: ["account", "key"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let account = try Azure.resource(input.account, service, type: "Microsoft.Storage/storageAccounts", "the storage account")
            let key = try ServiceInput.oneOf(input.key, ["key1", "key2"], "key")
            // Azure answers with both keys, which are never read, kept or shown.
            _ = try await service.data(account + ["regenerateKey"], query: ["api-version": Azure.storageVersion], method: "POST", body: try Azure.json(["keyName": key]))
            return try ServiceResult(text: "Replaced \(key) of \(account.last ?? "the account"). Apps using it need the new key from the Azure portal. The other key, and SAS tokens signed with it, still work: rotate it too if it may be known, or restrict-storage to stop shared key access altogether.",
                                     structured: ["account": Azure.joined(account), "key": key])
        }
    }

    struct RestrictStorage: ServiceOperation {
        struct Input: Decodable, Sendable { let account: String, publicBlobAccess: Bool?, sharedKeyAccess: Bool? }
        static let name = "restrict-storage"
        static let summary = "Turn off a storage account's anonymous public blob access, its shared key access, which every access key and SAS token signed with one relies on, or both. Apps that use keys stop working until it is turned back on."
        static let input = JSONSchema.object([
            "account": .string("The storage account's full ID."),
            "publicBlobAccess": .boolean("Turn off anonymous public access to its blobs."),
            "sharedKeyAccess": .boolean("Turn off shared key access, so only Microsoft Entra sign-ins work."),
        ], required: ["account"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let account = try Azure.resource(input.account, service, type: "Microsoft.Storage/storageAccounts", "the storage account")
            var properties: [String: Any] = [:]
            if input.publicBlobAccess == true { properties["allowBlobPublicAccess"] = false }
            if input.sharedKeyAccess == true { properties["allowSharedKeyAccess"] = false }
            guard !properties.isEmpty else { throw ServiceError.input("Give publicBlobAccess, sharedKeyAccess or both as true, for what to turn off.") }
            let answer = try await service.exchange(account, query: ["api-version": Azure.storageVersion], method: "PATCH", body: try Azure.json(["properties": properties]))
            let read = try? JSONDecoder().decode(JSON.self, from: answer.data)
            let now = ["allowBlobPublicAccess", "allowSharedKeyAccess"].compactMap { name in Azure.flag(Azure.field(read, ["properties", name])).map { "\(name) \($0)" } }
            let off = [input.publicBlobAccess == true ? "anonymous public blob access" : nil, input.sharedKeyAccess == true ? "shared key access" : nil].compactMap { $0 }
            return try ServiceResult(text: "Turned off \(GoogleCloud.listed(off)) for \(account.last ?? "the account")\(now.isEmpty ? "" : "; it now says \(now.joined(separator: ", "))"). Turn it back on in the Azure portal's Configuration to undo.",
                                     structured: ["account": Azure.joined(account), "turnedOff": off.joined(separator: ", ")])
        }
    }

    struct AddLock: ServiceOperation {
        struct Input: Decodable, Sendable { let resource: String, notes: String? }
        static let name = "add-lock"
        static let summary = "Stop a resource, a resource group or the subscription being deleted, with a CanNotDelete lock named pion-containment, such as evidence or logging an attacker may remove. Changes stay allowed. A lock of that name Pion did not add is left as it is. Azure's locks take no write condition, so a lock of that name someone makes between Pion's check and its write would be replaced."
        static let input = JSONSchema.object([
            "resource": .string("The full ID of the resource, the resource group, such as /subscriptions/…/resourceGroups/rg-prod, or the subscription."),
            "notes": .string("Why, kept with the lock, up to 500 characters."),
        ], required: ["resource"])
        static let readOnly = false
        /// How Pion's locks' notes begin, by which it knows its own.
        static let mark = "Pion: "

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let resource = try Azure.resource(input.resource, service)
            guard !resource.contains(where: { $0.lowercased() == "microsoft.authorization" }) else {
                throw ServiceError.input("Give the resource to lock, not a lock, assignment or other Microsoft.Authorization item.")
            }
            let notes = Self.mark + (try input.notes.map { try ServiceInput.quoted($0, "notes", limit: 500) } ?? "added during an investigation.")
            let path = resource + ["providers", "Microsoft.Authorization", "locks", Azure.lockName]
            // A lock of that name is not replaced: one that is not Pion's, or not CanNotDelete, such as a stricter
            // ReadOnly one, is left as it is. Microsoft.Authorization/locks carries no etag and takes no If-Match or
            // If-None-Match, so one made between this read and the write below would still be replaced; the summary
            // says so.
            do {
                let existing = try await Azure.fetch(service, path, version: Azure.lockVersion)
                let level = Azure.field(existing, ["properties", "level"])?.text ?? "?", said = Azure.field(existing, ["properties", "notes"])?.text ?? ""
                guard level.lowercased() == "cannotdelete", said.hasPrefix(Self.mark) else {
                    throw ServiceError.input("Nothing was changed: \(Azure.joined(resource)) already has a lock named \(Azure.lockName), at level \(level), that Pion did not add; it is left as it is.")
                }
                return try ServiceResult(text: "\(Azure.joined(resource)) is already locked against deletion by Pion's \(Azure.lockName); nothing was changed.",
                                         structured: ["resource": Azure.joined(resource), "lock": Azure.lockName])
            } catch ServiceError.notFound {}
            _ = try await service.data(path, query: ["api-version": Azure.lockVersion], method: "PUT",
                                       body: try Azure.json(["properties": ["level": "CanNotDelete", "notes": notes]]))
            return try ServiceResult(text: "Locked \(Azure.joined(resource)) against deletion with \(Azure.lockName). Remove the lock in the Azure portal's Locks to undo. Azure's locks take no write condition: had someone set a lock of that name at the same moment, this one replaced it, so check Locks if others are working on it now.",
                                     structured: ["resource": Azure.joined(resource), "lock": Azure.lockName])
        }
    }

    struct SnapshotDisk: ServiceOperation {
        struct Input: Decodable, Sendable { let disk: String, name: String? }
        static let name = "snapshot-disk"
        static let summary = "Copy a managed disk to a full snapshot in its resource group, as evidence before a VM is changed or stopped."
        static let input = JSONSchema.object([
            "disk": .string("The managed disk's full ID."),
            "name": .string("The snapshot's name: letters, digits, _, . and -, up to 80. pion- with the disk's name and the time when left out."),
        ], required: ["disk"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let disk = try Azure.resource(input.disk, service, type: "Microsoft.Compute/disks", "the disk")
            let stamp = ISO8601DateFormatter().string(from: Date()).filter(\.isNumber)
            let name = input.name?.trimmingCharacters(in: .whitespaces) ?? "pion-\(disk.last!.prefix(50))-\(stamp)"
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,78}[A-Za-z0-9_]$|^[A-Za-z0-9]$"#, options: .regularExpression) != nil else {
                throw ServiceError.input("Give the snapshot's name in letters, digits, _, . and -, up to 80, starting with a letter or digit.")
            }
            let read = try await Azure.fetch(service, disk, version: Azure.diskVersion)
            guard let location = Azure.field(read, ["location"])?.text else { throw ServiceError.unreadable }
            let snapshot = Array(disk.prefix(4)) + ["providers", "Microsoft.Compute", "snapshots", name]
            let body = try Azure.json(["location": location, "tags": ["createdBy": "Pion"],
                                       "properties": ["creationData": ["createOption": "Copy", "sourceResourceId": Azure.joined(disk)], "incremental": false]])
            let answer = try await service.exchange(snapshot, query: ["api-version": Azure.diskVersion], method: "PUT", body: body)
            let said = try Azure.started("Snapshotting \(disk.last!) to \(Azure.joined(snapshot))", answer.response, service)
            return try ServiceResult(text: said.text, structured: ["disk": Azure.joined(disk), "snapshot": Azure.joined(snapshot), "status": said.status ?? "done"])
        }
    }

    /// A Defender for Cloud alert's path, from its full ID as defender-alerts lists it.
    static func alertPath(_ value: String, _ service: ServiceClient) throws -> [String] {
        let alert = try resource(value, service, "the alert")
        let tail = alert.dropFirst(alert.count >= 4 && alert[2].lowercased() == "resourcegroups" ? 4 : 2).map { $0.lowercased() }
        guard tail.count == 6, Array(tail.prefix(3)) == ["providers", "microsoft.security", "locations"], tail[4] == "alerts" else {
            throw ServiceError.input("Give the alert's full ID, ending in /providers/Microsoft.Security/locations/LOCATION/alerts/NAME, as defender-alerts lists it.")
        }
        return alert
    }

    static let alertActions = ["Active": "activate", "InProgress": "inProgress", "Resolved": "resolve", "Dismissed": "dismiss"]

    /// Reopening an alert or marking it in hand changes nothing the watch relies on, so it runs on the bot's call.
    struct SetAlertStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let alert: String, status: String }
        static let name = "set-alert-status"
        static let summary = "Mark a Defender for Cloud alert Active or InProgress, by its full ID from Microsoft Azure Audit's defender-alerts. close-alert resolves or dismisses one."
        static let input = JSONSchema.object([
            "alert": .string("The alert's full ID, such as /subscriptions/…/providers/Microsoft.Security/locations/centralus/alerts/NAME."),
            "status": .string("The status.", oneOf: ["Active", "InProgress"]),
        ], required: ["alert", "status"])
        static let readOnly = false

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let alert = try Azure.alertPath(input.alert, service)
            let status = try ServiceInput.oneOf(input.status, ["Active", "InProgress"], "status")
            _ = try await service.data(alert + [Azure.alertActions[status]!], query: ["api-version": Azure.alertsVersion], method: "POST")
            return try ServiceResult(text: "Set \(alert.last!) to \(status).", structured: ["alert": Azure.joined(alert), "status": status])
        }
    }

    /// Resolving or dismissing an alert takes it out of the alert watch and Defender's open alerts, as an attacker would
    /// want, so it waits for the champion's approval.
    struct CloseAlert: ServiceOperation {
        struct Input: Decodable, Sendable { let alert: String, status: String }
        static let name = "close-alert"
        static let summary = "Resolve or dismiss a Defender for Cloud alert, by its full ID from Microsoft Azure Audit's defender-alerts, which takes it out of the alert watch and Defender's open alerts. Reopen it with set-alert-status."
        static let input = JSONSchema.object([
            "alert": .string("The alert's full ID, such as /subscriptions/…/providers/Microsoft.Security/locations/centralus/alerts/NAME."),
            "status": .string("Resolved, for one dealt with, or Dismissed, for one that was not a threat.", oneOf: ["Resolved", "Dismissed"]),
        ], required: ["alert", "status"])
        static let readOnly = false
        static let destructive = true

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let alert = try Azure.alertPath(input.alert, service)
            let status = try ServiceInput.oneOf(input.status, ["Resolved", "Dismissed"], "status")
            _ = try await service.data(alert + [Azure.alertActions[status]!], query: ["api-version": Azure.alertsVersion], method: "POST")
            return try ServiceResult(text: "Set \(alert.last!) to \(status). Reopen it with set-alert-status.", structured: ["alert": Azure.joined(alert), "status": status])
        }
    }

    struct OperationStatus: ServiceOperation {
        struct Input: Decodable, Sendable { let status: String }
        static let name = "operation-status"
        static let summary = "How a long operation this tool started is going, by the status path it returned."
        static let input = JSONSchema.object(["status": .string("The status path an action returned, such as /subscriptions/…/providers/Microsoft.Compute/locations/westeurope/operations/ID?api-version=….")], required: ["status"])

        static let states = ["inprogress": "InProgress", "running": "InProgress", "accepted": "InProgress", "succeeded": "Succeeded",
                             "failed": "Failed", "canceled": "Canceled", "cancelled": "Canceled"]

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let value = input.status.trimmingCharacters(in: .whitespaces)
            // Only a path is taken, read on the connection's own host, and only one of Azure's places for progress.
            guard value.hasPrefix("/"), !value.hasPrefix("//"), let url = URLComponents(string: "https://management.azure.com" + value),
                  url.host == "management.azure.com" else {
                throw ServiceError.input("Give the status path as the action returned it, starting /subscriptions/.")
            }
            let parts = try Azure.resource(url.path, service, "the status path")
            guard Azure.isStatus(parts) else {
                throw ServiceError.input("Give a status path an action returned, such as /subscriptions/…/providers/NAMESPACE/locations/LOCATION/operations/ID?api-version=…; other paths are not read here.")
            }
            var query: [String: String?] = [:]
            for item in url.queryItems ?? [] where item.name.range(of: #"^[A-Za-z0-9_.-]{1,40}$"#, options: .regularExpression) != nil {
                query[item.name] = item.value
            }
            guard query["api-version"] != nil else { throw ServiceError.input("Give the status path whole, with its api-version.") }
            let answer = try await service.exchange(parts, query: query)
            let read = try? JSONDecoder().decode(JSON.self, from: answer.data)
            let code = answer.response.statusCode
            let state: String
            if code == 202 { state = "InProgress" }
            else if let said = Azure.field(read, ["status"])?.text { state = Self.states[said.lowercased()] ?? "unknown" }
            // A Location poll ends with the operation's result, or nothing, once it is done.
            else if parts[6].lowercased() == "operationresults", code == 200 || code == 204 { state = "Succeeded" }
            else { state = "unknown" }
            let error = [Azure.field(read, ["error", "code"])?.text, Azure.field(read, ["error", "message"])?.text].compactMap { $0 }.joined(separator: ": ")
            let text = state == "unknown" ? "Azure's answer did not say how the operation is going; check the resource and the activity log." : "The operation is \(state)\(error.isEmpty ? "" : ": \(error)")."
            return try ServiceResult(text: text, structured: ["status": state, "error": error])
        }
    }

    /// Reads the app's own permissions on the subscription and says, for each action, whether its role allows it,
    /// without trying any.
    struct ContainmentCheckAccess: ServiceOperation {
        struct Input: Decodable, Sendable {}
        static let name = "check-access"
        static let summary = "Reads the app's permissions on the subscription and says which actions its role allows and exactly what to add for those it does not, warning when it allows far more. It changes nothing."
        static let input = JSONSchema.object([:])

        static let needs: [(operation: String, actions: [String])] = [
            (RemoveRoleAssignment.name, ["Microsoft.Authorization/roleAssignments/read", "Microsoft.Authorization/roleAssignments/delete"]),
            (DeallocateVM.name, ["Microsoft.Compute/virtualMachines/deallocate/action"]),
            (IsolateVM.name + " and " + UnisolateVM.name, ["Microsoft.Compute/virtualMachines/read", "Microsoft.Network/networkInterfaces/read",
                                                          "Microsoft.Network/networkSecurityGroups/read", "Microsoft.Network/networkSecurityGroups/securityRules/read",
                                                          "Microsoft.Network/networkSecurityGroups/securityRules/write",
                                                          "Microsoft.Network/networkSecurityGroups/securityRules/delete"]),
            (RotateStorageKey.name, ["Microsoft.Storage/storageAccounts/regeneratekey/action"]),
            (RestrictStorage.name, ["Microsoft.Storage/storageAccounts/write"]),
            (AddLock.name, ["Microsoft.Authorization/locks/read", "Microsoft.Authorization/locks/write"]),
            (SnapshotDisk.name, ["Microsoft.Compute/disks/read", "Microsoft.Compute/snapshots/write"]),
            (SetAlertStatus.name, ["Microsoft.Security/locations/alerts/activate/action"]),
            (CloseAlert.name, ["Microsoft.Security/locations/alerts/dismiss/action", "Microsoft.Security/locations/alerts/resolve/action"]),
        ]

        struct Permission: Decodable { let actions: [String]?, notActions: [String]? }

        /// Whether one of `held`, each a role's actions less its notActions, allows `action`; `*` matches any run.
        static func allows(_ held: [Permission], _ action: String) -> Bool {
            func matches(_ pattern: String) -> Bool {
                let expression = "^" + NSRegularExpression.escapedPattern(for: pattern.lowercased()).replacingOccurrences(of: "\\*", with: ".*") + "$"
                return action.lowercased().range(of: expression, options: .regularExpression) != nil
            }
            return held.contains { ($0.actions ?? []).contains(where: matches) && !($0.notActions ?? []).contains(where: matches) }
        }

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let held: [Permission]
            do {
                held = try await service.get(Azure.path(service, "Microsoft.Authorization", "permissions"), query: ["api-version": Azure.authorizationVersion],
                                             as: List<Permission>.self).value
            } catch {
                let fix = Azure.fix(for: error, Need(title: "Permissions", role: "the Pion Containment custom role")) ?? error.localizedDescription
                return try ServiceResult(text: "✗ The app's permissions could not be read: \(fix)", structured: ["checks": ["✗ permissions: \(fix)"]])
            }
            var lines = Self.needs.map { need -> String in
                let missing = need.actions.filter { !Self.allows(held, $0) }
                return missing.isEmpty ? "✓ \(need.operation)" : "✗ \(need.operation): add \(missing.joined(separator: ", ")) to the app's custom role on the subscription."
            }
            if Self.allows(held, "Microsoft.Resources/subscriptions/resourceGroups/delete") || Self.allows(held, "Microsoft.Authorization/roleAssignments/write") {
                lines.append("⚠ The app's role allows far more than containment, such as deleting resource groups or granting access: give it only the Pion Containment custom role from Setup Steps, never Owner or Contributor.")
            }
            lines.append("· What it can do is read from its role, not tried: an action can still be refused by a lock, a deny assignment or Azure Policy.")
            return try ServiceResult(text: lines.joined(separator: "\n"), structured: ["checks": lines])
        }
    }
}
