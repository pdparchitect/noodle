import Foundation
import NoodleCore
import NoodleToolConnections

/// Cloudflare Detection's reads for auditing how the account is set up: each zone's security settings at the edge,
/// with DNSSEC and the WAF's managed rules, and a zone's DNS records that point outside it, by provider, with those
/// whose target no longer resolves.
///
/// dns-exposure is the one read that reaches past api.cloudflare.com: Cloudflare's API resolves no name, so it looks up
/// the targets of a zone's records at Cloudflare's own DNS-over-HTTPS resolver, cloudflare-dns.com, which already holds
/// them. The lookups carry no token and nothing of the connection; they are bounded, and a run says how many it made
/// and which it left out.
extension Cloudflare {
    static let zoneSettingsNeed = Need(title: "Zone settings", permission: "Zone › Zone Settings › Read", zone: true)
    static let dnssecNeed = Need(title: "DNSSEC", permission: "Zone › DNS › Read", zone: true)
    static let wafNeed = Need(title: "WAF managed rules", permission: "Zone › Zone WAF › Read", zone: true)

    /// The settings zone-settings reads, by Cloudflare's ID for each
    /// (https://developers.cloudflare.com/api/resources/zones/subresources/settings/methods/get/).
    static let auditedSettings = ["ssl", "ssl_automatic_mode", "min_tls_version", "always_use_https", "automatic_https_rewrites", "security_header",
                                   "tls_1_3", "opportunistic_encryption", "security_level", "browser_check"]

    /// Cloudflare's managed rulesets by ID (https://developers.cloudflare.com/waf/managed-rules/).
    static let managedRulesets = ["efb7b8c949ac4650a09736fc376e9aee": "Cloudflare Managed Ruleset", "4814384a9e5d4991b9815dcfc25d2f1f": "Cloudflare OWASP Core Ruleset",
                                  "77454fe2d30c4220b5701f6fdfb893ba": "Cloudflare Free Managed Ruleset", "c2e184081120413c86c3ab7e14069605": "Exposed Credentials Check"]

    /// One zone's settings as read: what each part said, what is weak, what is worth a look, and what could not be read.
    struct ZoneAudit: Encodable, Sendable {
        let zone: String, id: String, status: String?, plan: String?, type: String?, paused: Bool
        var settings: [String: String] = [:]
        var hsts: String?
        var dnssec: String?
        /// The managed rulesets the zone's entry point runs, with whether each is on; nil when they were not read.
        var managedRules: [String]?
        var weak: [String] = [], notes: [String] = [], notRead: [String] = []
        var settingsRead = false

        /// The zone on one line, every setting said, or said not given.
        var line: String {
            func setting(_ id: String) -> String? { settings[id] }
            var parts: [String] = []
            let mode: String? = switch setting("ssl")?.lowercased() {
            case "off": "Off"
            case "flexible": "Flexible"
            case "full": "Full"
            case "strict": "Full (strict)"
            case "origin_pull": "Strict (SSL-only origin pull)"
            case let other: other
            }
            parts.append("SSL/TLS \(mode ?? "not given")\(setting("ssl_automatic_mode")?.lowercased() == "auto" ? " (chosen by Automatic SSL/TLS)" : "")")
            parts.append("minimum TLS \(setting("min_tls_version") ?? "not given")")
            parts.append("Always Use HTTPS \(setting("always_use_https") ?? "not given")")
            parts.append("Automatic HTTPS Rewrites \(setting("automatic_https_rewrites") ?? "not given")")
            parts.append("HSTS \(hsts ?? "not given")")
            parts.append("TLS 1.3 \(setting("tls_1_3").map { $0 == "zrt" ? "on with 0-RTT" : $0 } ?? "not given")")
            parts.append("DNSSEC \(dnssec ?? "not read")")
            parts.append("Opportunistic Encryption \(setting("opportunistic_encryption") ?? "not given")")
            parts.append("Security Level \(setting("security_level") ?? "not given")")
            parts.append("Browser Integrity Check \(setting("browser_check") ?? "not given")")
            parts.append("WAF managed rules " + (managedRules.map { $0.isEmpty ? "none deployed at the zone" : $0.joined(separator: ", ") } ?? "not read"))
            let about = [status, plan.map { "plan \($0)" }, type.map { "\($0) setup" }, paused ? "paused" : nil].compactMap { $0 }
            return "\(zone) [\(id)]\(about.isEmpty ? "" : " (\(about.joined(separator: ", ")))"): " + parts.joined(separator: "; ")
        }
    }

    /// What is weak and what is worth a look in a zone's settings as read. Weak is what lets traffic go unencrypted,
    /// on old TLS or with unsigned DNS; worth a look is what is commonly tightened.
    static func judge(_ zone: inout ZoneAudit) {
        var weak: [String] = [], notes: [String] = []
        if zone.paused { weak.append("paused, so Cloudflare passes its traffic through without its protection") }
        switch zone.settings["ssl"]?.lowercased() {
        case "off": weak.append("SSL/TLS Off: Cloudflare serves the zone's proxied hostnames over plain HTTP only")
        case "flexible": weak.append("SSL/TLS Flexible: visitors connect over HTTPS, but Cloudflare reaches the origin over plain HTTP")
        case "full": notes.append("SSL/TLS Full: Cloudflare encrypts to the origin but does not check its certificate; Full (strict) does")
        default: break
        }
        if let minimum = zone.settings["min_tls_version"], ["1.0", "1.1"].contains(minimum) {
            weak.append("minimum TLS \(minimum): clients may connect with TLS older than 1.2")
        }
        let hstsOn = zone.hsts?.hasPrefix("on") == true
        if zone.settings["always_use_https"]?.lowercased() == "off" {
            weak.append("HTTPS not enforced: Always Use HTTPS is off, so requests over plain HTTP are answered"
                        + (hstsOn ? ", though HSTS has browsers that visited before use HTTPS" : ""))
        }
        switch zone.dnssec?.lowercased() {
        case "disabled"?:
            if zone.type?.lowercased() == "partial" { notes.append("DNSSEC is not on at Cloudflare; in a partial setup it is set where the zone's DNS is hosted") }
            else { weak.append("DNSSEC off: answers for the zone are not signed") }
        case "pending"?: weak.append("DNSSEC pending: Cloudflare signs the zone, but the DS record is not yet at the registrar, so resolvers do not check it")
        case "pending-disabled"?: weak.append("DNSSEC being turned off")
        case "error"?: weak.append("DNSSEC in error: Cloudflare says the DS record at the registrar does not match")
        default: break
        }
        if zone.hsts?.hasPrefix("off") == true { notes.append("HSTS off: browsers are not told to use HTTPS only") }
        if zone.settings["tls_1_3"]?.lowercased() == "off" { notes.append("TLS 1.3 off") }
        if zone.settings["browser_check"]?.lowercased() == "off" { notes.append("Browser Integrity Check off") }
        if zone.settings["automatic_https_rewrites"]?.lowercased() == "off" { notes.append("Automatic HTTPS Rewrites off: pages may load parts over plain HTTP") }
        if let rules = zone.managedRules {
            if rules.isEmpty { notes.append("no WAF managed ruleset deployed at the zone (one deployed for the whole account is not read)") }
            else if rules.allSatisfy({ $0.hasSuffix("(off)") }) { notes.append("every WAF managed ruleset deployed at the zone is turned off") }
        }
        zone.weak = weak
        zone.notes = notes
    }

    /// A setting's value said shortly: text as Cloudflare gives it, or HSTS's fields.
    static func settingText(_ id: String, _ value: Value) -> String? {
        if id == "security_header" { return nil }
        return value.text ?? value["value"]?.text
    }

    /// HSTS from the security_header setting: on with its max-age and options, or off.
    static func hsts(_ value: Value) -> String? {
        guard let strict = value["strict_transport_security"]?.object else { return nil }
        guard strict["enabled"]?.flag == true else { return "off" }
        var parts: [String] = []
        if let age = strict["max_age"]?.number { parts.append(age >= 86_400 ? "max-age \(age / 86_400) days" : "max-age \(age) seconds") }
        if strict["include_subdomains"]?.flag == true { parts.append("includeSubDomains") }
        if strict["preload"]?.flag == true { parts.append("preload") }
        return "on" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
    }

    /// Whether a part's failure is a refusal that reading it again, setting by setting, would meet too.
    static func refusal(_ error: Error) -> Bool {
        switch error {
        case ServiceError.forbidden, ServiceError.rejected, ServiceError.rateLimited: true
        default: unlicensed(error)
        }
    }

    /// What could not be read of a part, said as what to change where Cloudflare refused it.
    static func notRead(_ need: Need, _ error: Error) -> String {
        "\(need.title): " + (fix(for: error, need) ?? error.localizedDescription)
    }

    /// One zone's settings, DNSSEC and managed rules, each read on its own so one refused leaves the others. The
    /// settings are asked for all at once, which Cloudflare still answers though it marks it deprecated; any not in
    /// that answer, or all of them when it fails for anything but a refusal, are asked for one by one.
    static func audit(_ zone: Item, _ service: ServiceClient) async -> (ZoneAudit, settingsError: Error?) {
        var read = ZoneAudit(zone: zone.text("name") ?? zone.id, id: zone.id, status: zone.text("status"), plan: zone.text("plan.name"),
                                  type: zone.text("type"), paused: zone.flag("paused") == true)
        var values: [String: Value] = [:]
        var settingsError: Error?
        do {
            let all = try await get(service, ["zones", zone.id, "settings"], as: Value.self)
            for setting in all.items ?? [] {
                if let id = setting["id"]?.text, auditedSettings.contains(id), let value = setting["value"] { values[id] = value }
            }
        } catch where refusal(error) {
            settingsError = error
        } catch {}
        if settingsError == nil {
            for id in auditedSettings where values[id] == nil {
                do {
                    let one = try await get(service, ["zones", zone.id, "settings", id], as: Value.self)
                    if let value = one["value"] { values[id] = value }
                } catch where refusal(error) {
                    settingsError = error
                    break
                } catch {
                    // A setting the zone's plan lacks is not given; it is shown as such.
                }
            }
        }
        if let settingsError { read.notRead.append(notRead(zoneSettingsNeed, settingsError)) }
        for (id, value) in values {
            if id == "security_header" { read.hsts = hsts(value) } else if let text = settingText(id, value) { read.settings[id] = text }
        }
        read.settingsRead = !values.isEmpty
        do {
            let dnssec = try await get(service, ["zones", zone.id, "dnssec"], as: Value.self)
            read.dnssec = dnssec["status"]?.text ?? "status not given"
        } catch {
            read.notRead.append(notRead(dnssecNeed, error))
        }
        do {
            let entry = try await get(service, ["zones", zone.id, "rulesets", "phases", "http_request_firewall_managed", "entrypoint"], as: Value.self)
            read.managedRules = (entry["rules"]?.items ?? []).filter { $0["action"]?.text == "execute" }.map { rule in
                let id = rule["action_parameters.id"]?.text ?? "?"
                let name = managedRulesets[id] ?? rule["description"]?.text.map { String($0.prefix(100)) } ?? "ruleset \(id)"
                return name + (rule["enabled"]?.flag == false ? " (off)" : "")
            }
        } catch ServiceError.notFound {
            // Cloudflare answers 404 for a zone whose managed-rules phase has no entry point: none was ever deployed there.
            read.managedRules = []
        } catch {
            read.notRead.append(notRead(wafNeed, error))
        }
        judge(&read)
        return (read, settingsError)
    }

    struct ZoneSettings: ServiceOperation {
        struct Input: Decodable, Sendable { let zone: String?, limit: Int? }
        static let name = "zone-settings"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "Each zone's security settings at the edge, weak ones first: SSL/TLS mode, minimum TLS version, Always Use HTTPS, Automatic HTTPS Rewrites, HSTS, TLS 1.3, DNSSEC, Opportunistic Encryption, Security Level, Browser Integrity Check and the WAF managed rulesets deployed at the zone, led by zones served over Flexible or Off SSL, allowing TLS below 1.2, not enforcing HTTPS or without DNSSEC; one zone, or every zone the token sees. Says what it could not read and which permission that needs."
        static let input = JSONSchema.object([
            "zone": .string("Only this zone, by its domain, such as example.com. Every zone the token sees when left out."),
            "limit": .integer("How many zones to read, at most, when no zone is given. 25 when left out.", minimum: 1, maximum: 100),
        ])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let limit = try Cloudflare.limit(input.limit, default: 25, maximum: 100, "zones")
            var query: [String: String?] = ["account.id": try Cloudflare.account(service)]
            let domain = try input.zone.map(ServiceInput.domain)
            if let domain { query["name"] = domain }
            let listing = try await Cloudflare.read(Cloudflare.zonesNeed) {
                try await Cloudflare.list(service, ["zones"], query: query, as: Item.self, size: 50, pages: domain == nil ? 3 : 2, limit: limit, partial: domain == nil)
            }
            var zones = listing.value
            if let domain {
                zones = zones.filter { $0.text("name")?.lowercased() == domain }
                guard zones.count == 1, zones.count == listing.value.count else {
                    throw ServiceError.input(zones.isEmpty ? "This account has no zone \(domain) that the token can see: check the name, or that the token's Zone Resources include it."
                                                           : "Cloudflare's answer for zone \(domain) named other zones too, so which one is meant could not be told.")
                }
            }
            let read = Array(zones.prefix(limit))
            let results = await withTaskGroup(of: (Int, ZoneAudit, Error?).self) { group in
                for (index, zone) in read.enumerated() {
                    group.addTask { let (audited, error) = await Cloudflare.audit(zone, service); return (index, audited, error) }
                }
                return await group.reduce(into: [(Int, ZoneAudit, Error?)]()) { $0.append($1) }
            }.sorted { $0.0 < $1.0 }
            // When no zone's settings could be read for a refusal, the whole read is refused, in the same words as any other.
            if !results.isEmpty, results.allSatisfy({ !$0.1.settingsRead }), let refused = results.compactMap(\.2).first {
                _ = try await Cloudflare.read(Cloudflare.zoneSettingsNeed) { () async throws -> Int in throw refused }
            }
            let audited = results.map(\.1).sorted { a, b in
                a.weak.count != b.weak.count ? a.weak.count > b.weak.count : a.zone < b.zone
            }
            var lines: [String] = []
            if audited.isEmpty {
                lines.append("The token sees no zone in this account\(listing.complete ? "" : " in what was read").")
            } else {
                lines.append(domain == nil ? "The security settings of \(Cloudflare.plural(audited.count, "zone")):" : "The security settings of \(audited[0].zone):")
                let weak = audited.filter { !$0.weak.isEmpty }
                if weak.isEmpty {
                    lines.append("No zone shows a weak setting of those checked first: SSL/TLS Off or Flexible, minimum TLS below 1.2, HTTPS not enforced, DNSSEC not in force, or paused"
                                 + (audited.contains { !$0.notRead.isEmpty } ? ", in what could be read." : "."))
                } else {
                    lines.append("Weak settings in \(weak.count) of \(Cloudflare.plural(audited.count, "zone")):")
                    lines += weak.map { "⚠ \($0.zone): " + $0.weak.joined(separator: "; ") }
                }
                let notes = audited.filter { !$0.notes.isEmpty }
                if !notes.isEmpty {
                    lines.append("Worth a look:")
                    lines += notes.map { "· \($0.zone): " + $0.notes.joined(separator: "; ") }
                }
                lines.append("Zone by zone:")
                lines += audited.map(\.line)
                // The same part refused for many zones is said once, with the zones it was refused for.
                var refused: [(String, [String])] = []
                for zone in audited {
                    for said in zone.notRead {
                        if let index = refused.firstIndex(where: { $0.0 == said }) { refused[index].1.append(zone.zone) } else { refused.append((said, [zone.zone])) }
                    }
                }
                for (said, zones) in refused {
                    lines.append("Not read for \(zones.count == audited.count && zones.count > 1 ? "any zone" : zones.prefix(10).joined(separator: ", ") + (zones.count > 10 ? " and \(zones.count - 10) more" : "")): \(said)")
                }
                lines.append("Edge settings reach only the hostnames Cloudflare proxies; a DNS-only record reaches its origin directly.")
            }
            let cut = listing.value.count > read.count || (listing.more && listing.stopped == nil)
            if cut { lines.append("More zones match than the \(read.count) read\(listing.total.map { " (Cloudflare says \($0))" } ?? ""): give a zone, or raise limit.") }
            else if !listing.complete { lines.append(Cloudflare.stopped(listing, "zones").trimmingCharacters(in: .whitespacesAndNewlines)) }
            struct Kept: Encodable { let zones: [ZoneAudit]; let weakZones: Int; let total: Int?; let complete: Bool }
            return try ServiceResult(text: lines.joined(separator: "\n"),
                                     structured: Kept(zones: audited, weakZones: audited.filter { !$0.weak.isEmpty }.count, total: listing.total,
                                                      complete: listing.complete && !cut && audited.allSatisfy { $0.notRead.isEmpty }))
        }
    }
}

// MARK: - DNS exposure

extension Cloudflare {
    /// What looking a name up found, with the CNAMEs it led through: it resolves to an address; it doesn't, as the
    /// resolver said the name does not exist (NXDOMAIN) or exists with no address (NOERROR, no answer); or the lookup
    /// could not tell, as for SERVFAIL, any other answer, or no answer in time, which is never taken for not resolving.
    enum Resolution: Sendable, Equatable {
        case resolves(chain: [String])
        case doesNotResolve(String, chain: [String])
        case unknown(String)
    }

    /// Cloudflare's own DNS-over-HTTPS resolver, which already holds the zone's records, so looking their targets up
    /// tells no one else of them (https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/make-api-requests/dns-json/).
    static let resolverHost = "cloudflare-dns.com"
    /// How long one lookup waits for an answer.
    static let lookupTimeout = 5.0

    /// How dns-exposure reaches the resolver: with no credentials, the connection's token never among them, only at
    /// its host, and no redirect followed. Tests answer in its place.
    @TaskLocal static var resolver: any ServiceAccess = ToolConnectionAccess.anonymous(URL(string: "https://\(resolverHost)")!, timeout: lookupTimeout)

    /// One question to the resolver, in its JSON form.
    static func ask(_ name: String, _ type: String, _ client: ServiceClient) async throws -> DNS.Answer {
        let data = try await client.data(["dns-query"], query: ["name": name, "type": type], headers: ["Accept": "application/dns-json"])
        do { return try JSONDecoder().decode(DNS.Answer.self, from: data) } catch { throw ServiceError.unreadable }
    }

    /// Whether a name resolves to an address: its A records, then, when it has none, its AAAA records. Only NXDOMAIN,
    /// or NOERROR with no address, says it doesn't resolve; anything else leaves it unknown.
    static func lookUp(_ name: String) async -> Resolution {
        let client = ServiceClient(base: URL(string: "https://\(resolverHost)")!, access: resolver)
        var chain: [String] = []
        for (type, number) in [("A", 1), ("AAAA", 28)] {
            let answer: DNS.Answer
            do { answer = try await ask(name, type, client) } catch { return .unknown(error.localizedDescription) }
            let records = answer.Answer ?? []
            for record in records where record.type == 5 {
                var target = record.data.lowercased()
                while target.hasSuffix(".") { target.removeLast() }
                if !chain.contains(target) { chain.append(target) }
            }
            switch answer.Status {
            case 0 where records.contains(where: { $0.type == number }): return .resolves(chain: chain)
            case 0: continue
            case 3: return .doesNotResolve("NXDOMAIN" + (chain.last.map { " at \($0)" } ?? ""), chain: chain)
            case 2: return .unknown("the resolver answered SERVFAIL")
            case let code: return .unknown("the resolver answered with DNS error code \(code)")
            }
        }
        return .doesNotResolve("no address (NOERROR, no answer)" + (chain.last.map { " at \($0)" } ?? ""), chain: chain)
    }

    /// Who hosts what a record points at, as its target's name or address shows it, and whether others have claimed a
    /// name left pointing at one of its deleted resources, as the community's list of takeover reports gives it
    /// (https://github.com/EdOverflow/can-i-take-over-xyz) and, for Azure, Microsoft's guidance on dangling DNS. That a
    /// provider allows it says nothing of any one record.
    struct Provider: Sendable {
        /// Reported: listed as vulnerable. Some cases: listed as an edge case, claimed only under some conditions.
        enum Takeover: String, Sendable, Encodable { case reported, someCases = "some-cases", none }
        let name: String
        let suffixes: [String]
        var takeover = Takeover.none
        /// Whether a deleted resource's name stops resolving, rather than resolving to a page that says it is gone.
        var stopsResolving = false
    }

    static let providers: [Provider] = [
        Provider(name: "AWS S3", suffixes: [], takeover: .reported),
        Provider(name: "AWS Elastic Beanstalk", suffixes: ["elasticbeanstalk.com"], takeover: .reported, stopsResolving: true),
        Provider(name: "AWS CloudFront", suffixes: ["cloudfront.net"]),
        Provider(name: "AWS load balancer", suffixes: ["elb.amazonaws.com"]),
        Provider(name: "AWS", suffixes: ["amazonaws.com", "awsglobalaccelerator.com", "awsapprunner.com", "amplifyapp.com"]),
        Provider(name: "Microsoft Azure", suffixes: ["azurewebsites.net", "cloudapp.net", "cloudapp.azure.com", "trafficmanager.net", "blob.core.windows.net",
                                                    "azureedge.net", "azure-api.net", "azurecontainer.io", "azurefd.net", "azurehdinsight.net",
                                                    "database.windows.net", "search.windows.net", "azurecr.io", "redis.cache.windows.net",
                                                    "servicebus.windows.net", "visualstudio.com"], takeover: .reported, stopsResolving: true),
        Provider(name: "Azure Static Web Apps", suffixes: ["azurestaticapps.net"]),
        Provider(name: "Microsoft 365", suffixes: ["outlook.com", "onmicrosoft.com", "lync.com", "office.com", "microsoftonline.com", "sharepoint.com"]),
        Provider(name: "Heroku", suffixes: ["herokuapp.com", "herokudns.com", "herokussl.com"], takeover: .someCases),
        Provider(name: "GitHub Pages", suffixes: ["github.io"], takeover: .someCases),
        Provider(name: "GitLab Pages", suffixes: ["gitlab.io"]),
        Provider(name: "Bitbucket", suffixes: ["bitbucket.io"], takeover: .reported),
        Provider(name: "Netlify", suffixes: ["netlify.app", "netlify.com"], takeover: .someCases),
        Provider(name: "Vercel", suffixes: ["vercel.app", "vercel-dns.com", "now.sh"], takeover: .someCases),
        Provider(name: "Fly.io", suffixes: ["fly.dev"]),
        Provider(name: "Render", suffixes: ["onrender.com"]),
        Provider(name: "Firebase", suffixes: ["web.app", "firebaseapp.com"]),
        Provider(name: "Google", suffixes: ["ghs.googlehosted.com", "googlehosted.com", "appspot.com", "c.storage.googleapis.com", "googleapis.com", "google.com"]),
        Provider(name: "Cloudflare Pages and Workers", suffixes: ["pages.dev", "workers.dev"]),
        Provider(name: "DigitalOcean", suffixes: ["ondigitalocean.app"]),
        Provider(name: "Fastly", suffixes: ["fastly.net", "fastlylb.net"]),
        Provider(name: "Akamai", suffixes: ["edgekey.net", "edgesuite.net", "akamaiedge.net", "akamai.net"]),
        Provider(name: "Shopify", suffixes: ["myshopify.com"], takeover: .someCases),
        Provider(name: "Squarespace", suffixes: ["squarespace.com"]),
        Provider(name: "Wix", suffixes: ["wixdns.net"], takeover: .someCases),
        Provider(name: "Webflow", suffixes: ["webflow.io", "webflow.com"], takeover: .someCases),
        Provider(name: "WordPress.com", suffixes: ["wordpress.com"], takeover: .reported),
        Provider(name: "WP Engine", suffixes: ["wpengine.com"]),
        Provider(name: "Ghost", suffixes: ["ghost.io"], takeover: .reported),
        Provider(name: "Pantheon", suffixes: ["pantheonsite.io"], takeover: .reported),
        Provider(name: "Surge", suffixes: ["surge.sh"], takeover: .reported),
        Provider(name: "Read the Docs", suffixes: ["readthedocs.io"], takeover: .reported),
        Provider(name: "ReadMe", suffixes: ["readme.io"], takeover: .reported),
        Provider(name: "Zendesk", suffixes: ["zendesk.com"]),
        Provider(name: "Freshdesk", suffixes: ["freshdesk.com"]),
        Provider(name: "Help Scout", suffixes: ["helpscoutdocs.com"], takeover: .reported),
        Provider(name: "Intercom", suffixes: ["intercom.help", "intercom.io"], takeover: .someCases),
        Provider(name: "HubSpot", suffixes: ["hubspot.net", "hs-sites.com", "hubspot.com", "hubspotemail.net"]),
        Provider(name: "Kit (ConvertKit)", suffixes: ["ck.page", "kit.com", "convertkit.com"]),
        Provider(name: "Unbounce", suffixes: ["unbouncepages.com"]),
        Provider(name: "Atlassian", suffixes: ["stspg-customer.com", "atlassian.net"]),
        Provider(name: "Tumblr", suffixes: ["domains.tumblr.com"], takeover: .someCases),
        Provider(name: "Strikingly", suffixes: ["strikinglydns.com"], takeover: .reported),
        Provider(name: "Canny", suffixes: ["canny.io"], takeover: .reported),
        Provider(name: "Agile CRM", suffixes: ["agilecrm.com"], takeover: .reported),
        Provider(name: "Launchrock", suffixes: ["launchrock.com"], takeover: .reported),
        Provider(name: "ngrok", suffixes: ["ngrok.io", "ngrok.app"], takeover: .reported),
        Provider(name: "Uberflip", suffixes: ["uberflip.com"], takeover: .reported),
        Provider(name: "Worksites", suffixes: ["worksites.net"], takeover: .reported),
        Provider(name: "UserVoice", suffixes: ["uservoice.com"]),
        Provider(name: "Okta", suffixes: ["okta.com", "oktapreview.com", "okta-emea.com"]),
        Provider(name: "Auth0", suffixes: ["auth0.com"]),
        Provider(name: "Salesforce", suffixes: ["force.com", "salesforce.com", "salesforce-sites.com", "pardot.com"]),
        Provider(name: "Marketo", suffixes: ["mktoweb.com", "mktossl.com", "marketo.com"]),
        Provider(name: "SendGrid", suffixes: ["sendgrid.net"]),
        Provider(name: "Mailgun", suffixes: ["mailgun.org"]),
        Provider(name: "Amazon SES", suffixes: ["amazonses.com"]),
        Provider(name: "Mailchimp", suffixes: ["mcsv.net", "mailchimp.com", "mandrillapp.com"]),
        Provider(name: "Postmark", suffixes: ["mtasv.net"]),
    ]

    /// Addresses providers publish for customers to point a domain's apex at, each the provider's own.
    static let providerAddresses: [String: String] = [
        "185.199.108.153": "GitHub Pages", "185.199.109.153": "GitHub Pages", "185.199.110.153": "GitHub Pages", "185.199.111.153": "GitHub Pages",
        "2606:50c0:8000::153": "GitHub Pages", "2606:50c0:8001::153": "GitHub Pages", "2606:50c0:8002::153": "GitHub Pages", "2606:50c0:8003::153": "GitHub Pages",
        "75.2.60.5": "Netlify", "76.76.21.21": "Vercel", "23.227.38.65": "Shopify",
        "198.185.159.144": "Squarespace", "198.185.159.145": "Squarespace", "198.49.23.144": "Squarespace", "198.49.23.145": "Squarespace",
    ]

    /// Who hosts a name, by the longest end of it a provider names; S3's names hold the bucket's region in their middle.
    static func provider(of host: String) -> Provider? {
        let host = host.lowercased()
        let labels = host.split(separator: ".")
        if host.hasSuffix(".amazonaws.com"), labels.contains(where: { $0 == "s3" || $0.hasPrefix("s3-") }) || host.contains(".s3.") {
            return providers.first { $0.name == "AWS S3" }
        }
        var best: (Provider, Int)?
        for provider in providers {
            for suffix in provider.suffixes where host == suffix || host.hasSuffix("." + suffix) {
                if suffix.count > (best?.1 ?? 0) { best = (provider, suffix.count) }
            }
        }
        return best?.0
    }

    /// Name servers by who runs them, for a subdomain delegated away from the zone.
    static func nameServers(_ host: String) -> String {
        let host = host.lowercased()
        if host.contains("awsdns") { return "Amazon Route 53" }
        if host.contains("azure-dns") { return "Azure DNS" }
        if host.hasSuffix("googledomains.com") { return "Google Cloud DNS" }
        if host.hasSuffix("digitalocean.com") { return "DigitalOcean DNS" }
        if host.hasSuffix("ns.cloudflare.com") { return "Cloudflare" }
        if host.hasSuffix("nsone.net") { return "NS1" }
        if host.hasSuffix("dnsimple.com") { return "DNSimple" }
        return "other name servers"
    }

    /// Whether an address is private, loopback, link-local, shared or otherwise not reachable from the Internet.
    static func isInternal(_ address: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            switch (bytes[0], bytes[1]) {
            case (10, _), (127, _), (0, _): return true
            case (172, 16...31), (192, 168), (169, 254): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
        return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
    }

    /// One record that points outside its zone, or at a name in it no record answers, and what looking it up found.
    struct Exposure: Encodable, Sendable {
        let name: String, type: String, target: String, proxied: Bool, id: String
        let provider: String?, takeover: Provider.Takeover
        /// Whether the provider's deleted resources stop resolving, so that a target that resolves is likely still there.
        var stopsResolving = false
        /// resolves, doesn't resolve, couldn't tell, or not looked up; nil where there is nothing to look up.
        var lookup: String?
        /// Whether the resolver said plainly the target does not exist or has no address.
        var doesNotResolve = false
        var risk: String?

        var line: String {
            "\(type) \(name) → \(target)\(proxied ? " (proxied)" : "")" + (lookup.map { " [\($0)]" } ?? "") + (risk.map { " — \($0)" } ?? "") + " [\(id)]"
        }
    }

    /// The order targets are looked up and providers listed in: where takeovers were reported, then where they were in
    /// some cases, then other known providers, then hosts Pion does not recognise.
    static func rank(_ exposure: Exposure) -> Int {
        switch exposure.takeover {
        case .reported: 0
        case .someCases: 1
        case .none: exposure.provider == nil ? 3 : 2
        }
    }

    struct DNSExposure: ServiceOperation {
        struct Input: Decodable, Sendable { let zone: String, lookups: Int? }
        static let name = "dns-exposure"
        static let jobs: Set<ToolJob> = [.audit]
        static let summary = "A zone's DNS records that point outside it, grouped by the provider their target shows (such as Heroku, GitHub Pages, S3, Azure, Netlify, Vercel, Shopify or Zendesk), for the owner to confirm each is still in use; led by CNAMEs whose target doesn't resolve, marked possible takeover where the provider is one where others have claimed such names, CNAMEs to names in the zone no record answers, and private addresses published in public DNS. Looks the targets up through Cloudflare's DNS-over-HTTPS resolver, which already holds the zone's records, at most lookups of them, and says which it left out. It never visits a target, and never says a record can be taken over."
        static let input = JSONSchema.object([
            "zone": .string("The zone's domain, such as example.com."),
            "lookups": .integer("How many distinct targets to look up, at most, those at providers where others have claimed such names first. 40 when left out; 0 looks none up.",
                                minimum: 0, maximum: 100),
        ], required: ["zone"])

        func run(_ input: Input, on service: ServiceClient) async throws -> ServiceResult {
            let domain = try ServiceInput.domain(input.zone)
            let most = input.lookups ?? 40
            guard (0...100).contains(most) else { throw ServiceError.input("Ask for between 0 and 100 lookups.") }
            let id = try await Cloudflare.zone(domain, on: service)
            let listing = try await Cloudflare.read(Cloudflare.dnsNeed) {
                try await Cloudflare.list(service, ["zones", id, "dns_records"], query: [:], as: Item.self, size: 500, pages: 10)
            }
            func bare(_ name: String) -> String {
                var name = name.trimmingCharacters(in: .whitespaces).lowercased()
                while name.hasSuffix(".") { name.removeLast() }
                return name
            }
            let inZone = { (name: String) in name == domain || name.hasSuffix("." + domain) }
            let names = Set(listing.value.compactMap { $0.text("name").map(bare) })
            let wildcards = names.filter { $0.hasPrefix("*.") }.map { String($0.dropFirst(2)) }
            func answered(_ name: String) -> Bool { names.contains(name) || wildcards.contains { name.hasSuffix("." + $0) } }

            var outside: [Exposure] = [], dangling: [Exposure] = [], internalAddresses: [Exposure] = [], unknownAddresses: [Exposure] = []
            var delegations: [Exposure] = []
            for record in listing.value {
                guard let type = record.text("type")?.uppercased(), let name = record.text("name").map(bare), let content = record.text("content") else { continue }
                let proxied = record.flag("proxied") == true
                switch type {
                case "CNAME":
                    let target = bare(content)
                    if inZone(target) {
                        // A name in this zone is the zone's own; only one no record answers is worth saying, and only from a whole read.
                        if listing.complete, !answered(target) {
                            dangling.append(Exposure(name: name, type: type, target: target, proxied: proxied, id: record.id, provider: nil, takeover: .none,
                                                     risk: "no record in this zone answers \(target): remove it if no longer in use"))
                        }
                    } else {
                        let provider = Cloudflare.provider(of: target)
                        outside.append(Exposure(name: name, type: type, target: target, proxied: proxied, id: record.id, provider: provider?.name,
                                                takeover: provider?.takeover ?? .none, stopsResolving: provider?.stopsResolving ?? false))
                    }
                case "A", "AAAA":
                    let address = content.trimmingCharacters(in: .whitespaces).lowercased()
                    if Cloudflare.isInternal(address) {
                        internalAddresses.append(Exposure(name: name, type: type, target: address, proxied: proxied, id: record.id, provider: nil, takeover: .none,
                                                          risk: "a private or reserved address in public DNS shows how the inside network is laid out"))
                    } else if let provider = Cloudflare.providerAddresses[address] {
                        outside.append(Exposure(name: name, type: type, target: address, proxied: proxied, id: record.id, provider: provider,
                                                takeover: Cloudflare.providers.first { $0.name == provider }?.takeover ?? .none))
                    } else {
                        unknownAddresses.append(Exposure(name: name, type: type, target: address, proxied: proxied, id: record.id, provider: nil, takeover: .none))
                    }
                case "NS" where name != domain:
                    let target = bare(content)
                    if !inZone(target) {
                        delegations.append(Exposure(name: name, type: type, target: target, proxied: false, id: record.id, provider: Cloudflare.nameServers(target),
                                                    takeover: .none, risk: "delegated: check the zone still exists at \(Cloudflare.nameServers(target))"))
                    }
                default: break
                }
            }

            // The distinct CNAME targets, those at providers where others have claimed such names first, then other
            // known providers, then the rest; only well-formed names are looked up.
            let targets = NSOrderedSet(array: outside.filter { $0.type == "CNAME" }.sorted { a, b in
                (Cloudflare.rank(a), a.target) < (Cloudflare.rank(b), b.target)
            }.map(\.target)).compactMap { $0 as? String }.filter { (try? DNS.name($0)) != nil }
            let asked = Array(targets.prefix(most))
            var found: [String: Resolution] = [:]
            if !asked.isEmpty {
                found = await withTaskGroup(of: (String, Resolution).self) { group in
                    var pending = asked[...], answers: [String: Resolution] = [:]
                    // At most eight lookups at once, so a slow resolver holds only so many.
                    for _ in 0..<min(8, pending.count) {
                        let name = pending.removeFirst()
                        group.addTask { (name, await Cloudflare.lookUp(name)) }
                    }
                    while let (name, answer) = await group.next() {
                        answers[name] = answer
                        if let next = pending.popFirst() { group.addTask { (next, await Cloudflare.lookUp(next)) } }
                    }
                    return answers
                }
            }
            for index in outside.indices where outside[index].type == "CNAME" {
                let exposure = outside[index]
                let provider = exposure.provider.map { " at \($0)" } ?? ""
                func via(_ chain: [String]) -> String { chain.isEmpty ? "" : " via " + chain.prefix(5).joined(separator: " → ") }
                switch found[exposure.target] {
                case .resolves(let chain)?:
                    outside[index].lookup = "resolves" + via(chain)
                    outside[index].risk = "check whether still in use" + (exposure.takeover != .none && !exposure.stopsResolving
                        ? "; at \(exposure.provider ?? "this provider") a target still resolves after its resource is deleted, so confirm the resource there" : "")
                case .doesNotResolve(let why, let chain)?:
                    outside[index].lookup = "doesn't resolve: \(why)" + (chain.count > 1 ? via(chain) : "")
                    outside[index].doesNotResolve = true
                    outside[index].risk = exposure.takeover != .none ? "target doesn't resolve — possible takeover: confirm\(provider) that the resource still exists and is the organisation's, or remove the record"
                        : "target doesn't resolve: remove the record if no longer in use"
                case .unknown(let why)?:
                    outside[index].lookup = "couldn't tell: \(why)"
                    outside[index].risk = "check whether still in use"
                case nil:
                    outside[index].lookup = "not looked up"
                    outside[index].risk = "check whether still in use"
                }
            }
            for index in outside.indices where outside[index].type != "CNAME" { outside[index].risk = "check whether still in use" }

            let leads = outside.filter(\.doesNotResolve).sorted { (Cloudflare.rank($0), $0.name) < (Cloudflare.rank($1), $1.name) }
            let takeover = leads.filter { $0.takeover != .none }, notResolving = leads.filter { $0.takeover == .none }
            var groups: [(String, [Exposure])] = []
            for exposure in outside {
                let key = exposure.provider ?? "Other hosts outside the zone"
                if let index = groups.firstIndex(where: { $0.0 == key }) { groups[index].1.append(exposure) } else { groups.append((key, [exposure])) }
            }
            groups.sort { a, b in
                let (x, y) = (a.0 == "Other hosts outside the zone", b.0 == "Other hosts outside the zone")
                if x != y { return !x }
                let (x2, y2) = (a.1.first.map(Cloudflare.rank) ?? 2, b.1.first.map(Cloudflare.rank) ?? 2)
                if x2 != y2 { return x2 < y2 }
                return a.0 < b.0
            }

            let addresses = Set(unknownAddresses.map(\.target))
            let counted = { (count: Int, what: String) in "\(count) \(what)\(count == 1 ? "address" : "addresses")" }
            var lines = ["\(domain): \(Cloudflare.plural(listing.value.count, "DNS record")) read; \(Cloudflare.plural(outside.count, "record")) point outside the zone at "
                         + "\(Cloudflare.plural(groups.filter { $0.0 != "Other hosts outside the zone" }.count, "known provider"))"
                         + "\(groups.contains { $0.0 == "Other hosts outside the zone" } ? " and other hosts" : ""), \(counted(addresses.count, "other ")) "
                         + "Pion does not recognise, and \(Cloudflare.plural(delegations.count, "subdomain")) delegated elsewhere."]
            var shown = 0
            func add(_ heading: String, _ items: [Exposure]) {
                guard !items.isEmpty else { return }
                lines.append(heading)
                for item in items.prefix(max(0, 250 - shown)) { lines.append("  " + item.line); shown += 1 }
            }
            add("Target doesn't resolve — possible takeover (\(takeover.count)):", takeover)
            add("Target doesn't resolve — check whether still in use (\(notResolving.count)):", notResolving)
            add("Points at a name in this zone that no record answers (\(dangling.count)):", dangling)
            add("Private or reserved addresses published in public DNS (\(internalAddresses.count)):", internalAddresses)
            if !groups.isEmpty { lines.append("By provider — confirm each is still in use:") }
            for (provider, items) in groups {
                let said: String = switch items.first?.takeover {
                case .reported?: " (names left pointing at its deleted resources have been claimed by others)"
                case .someCases?: " (names left pointing at its deleted resources have been claimed by others in some cases)"
                default: ""
                }
                add("\(provider)\(said):", items)
            }
            add("Subdomains delegated to other name servers (\(delegations.count)):", delegations)
            if !unknownAddresses.isEmpty {
                lines.append("\(counted(addresses.count, "")) Pion does not recognise, in \(Cloudflare.plural(unknownAddresses.count, "record")): confirm each is still the "
                             + "organisation's; a cloud address given back can be handed to someone else.")
                for item in unknownAddresses.prefix(max(0, 250 - shown)) { lines.append("  " + item.line); shown += 1 }
            }
            let total = takeover.count + notResolving.count + dangling.count + internalAddresses.count + outside.count + delegations.count + unknownAddresses.count
            if shown < total, shown >= 250 { lines.append("Lines past the first 250 are in the structured result.") }
            if !targets.isEmpty, most == 0 {
                lines.append("No target was looked up, as lookups is 0: check them with the DNS tool, or raise lookups.")
            } else if !targets.isEmpty {
                let left = targets.count - asked.count
                lines.append("Looked up \(asked.count) of \(Cloudflare.plural(targets.count, "distinct target")) through Cloudflare's DNS-over-HTTPS resolver"
                             + (left > 0 ? "; \(left) were not, as at most \(most) are: raise lookups, or check them with the DNS tool." : "."))
            }
            if !outside.isEmpty {
                lines.append("Pion visits no target: one that resolves may still be unclaimed at its provider, and one that doesn't resolve is a lead to confirm, not proof.")
            }
            lines.append(String(Cloudflare.stopped(listing, "DNS records").dropFirst()))
            if !listing.complete { lines.append("Names in the zone that no record answers are not said, as not every record was read.") }
            struct Kept: Encodable {
                let zone: String; let possibleTakeover: [Exposure]; let notResolving: [Exposure]; let dangling: [Exposure]; let internalAddresses: [Exposure]
                let outside: [Exposure]; let delegations: [Exposure]; let unrecognisedAddresses: [Exposure]
                let lookedUp: Int; let targets: Int; let records: Int; let complete: Bool
            }
            return try ServiceResult(text: lines.filter { !$0.isEmpty }.joined(separator: "\n"),
                                     structured: Kept(zone: id, possibleTakeover: takeover, notResolving: notResolving, dangling: dangling, internalAddresses: internalAddresses,
                                                      outside: outside, delegations: delegations, unrecognisedAddresses: unknownAddresses,
                                                      lookedUp: asked.count, targets: targets.count,
                                                      records: listing.value.count, complete: listing.complete))
        }
    }
}
