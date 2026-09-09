import Foundation

/// The catalogue describes tools, not a particular protocol. New kinds add a
/// configuration case and a setup handler; they do not inherit MCP fields.
public enum ToolKind: String, Equatable, Sendable {
    case mcp = "MCP"
}

public enum ToolConfiguration: Equatable, Sendable {
    case mcp(MCPToolConfiguration)

    public var kind: ToolKind {
        switch self { case .mcp: return .mcp }
    }
}

public struct MCPToolConfiguration: Equatable, Sendable {
    public let endpoint: URL
    public init(endpoint: URL) { self.endpoint = endpoint }

    /// Every addition is a separate account, including repeated presets.
    public func makeConnection(name: String, description: String = "", instructions: String = "") throws -> MCPConnectionRecord {
        try MCPConnectionRecord(name: name, endpoint: endpoint, description: description, instructions: instructions)
    }
}

public struct ToolDefinition: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let defaultInstructions: String
    public let iconName: String
    public let configuration: ToolConfiguration
    public var kind: ToolKind { configuration.kind }

    public init(id: String, name: String, summary: String, defaultInstructions: String, iconName: String, configuration: ToolConfiguration) {
        self.id = id; self.name = name; self.summary = summary
        self.defaultInstructions = defaultInstructions
        self.iconName = iconName; self.configuration = configuration
    }
}

public enum ToolCatalog {
    /// Public metadata checked 2026-09-09. No API keys, embedded OAuth clients,
    /// account-specific URLs or legacy SSE presets. See docs/tool-catalogue.md.
    public static let entries: [ToolDefinition] = [
        .init(id: "apollo", name: "Apollo", summary: "Sales research, contacts and outreach.",
              defaultInstructions: "Use Apollo for company and contact research and sales workflows. Avoid duplicate records and distinguish verified facts from inferred details; confirm before sending outreach. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "apollo",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.apollo.io/mcp")!))),
        .init(id: "attio", name: "Attio", summary: "Customer records and relationship workflows.",
              defaultInstructions: "Use Attio to find and maintain customer records and lists. Search for existing records first and keep updates factual; confirm before bulk changes or outreach. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "attio",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.attio.com/mcp")!))),
        .init(id: "buildkite", name: "Buildkite", summary: "Builds and delivery pipelines.",
              defaultInstructions: "Use Buildkite to inspect pipelines, builds and job failures. Report the failing step and evidence; confirm before triggering deployments or changing pipelines. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "buildkite",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.buildkite.com/mcp")!))),
        .init(id: "canva", name: "Canva", summary: "Designs, templates and visual content.",
              defaultInstructions: "Use Canva to find and work with designs and assets. Preserve existing brand and layout choices unless asked to change them; confirm before publishing or sharing. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "canva",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.canva.com/mcp")!))),
        .init(id: "clay", name: "Clay", summary: "Company research and data enrichment.",
              defaultInstructions: "Use Clay for company research and data enrichment. Avoid duplicate records, minimize unnecessary personal data and confirm before bulk enrichment or outreach. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "clay",
              configuration: .mcp(.init(endpoint: URL(string: "https://api.clay.com/v3/mcp")!))),
        .init(id: "clickup", name: "ClickUp", summary: "Tasks, projects and team workflows.",
              defaultInstructions: "Use ClickUp to find and maintain tasks, documents and projects. Verify the workspace, list and assignee; search before creating duplicate work. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "clickup",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.clickup.com/mcp")!))),
        .init(id: "cloudflare", name: "Cloudflare", summary: "Cloud services and developer infrastructure.",
              defaultInstructions: "Use Cloudflare to inspect infrastructure and developer services. Verify the account, zone and environment; obtain approval before configuration, deployment or security changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "cloudflare",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.cloudflare.com/mcp")!))),
        .init(id: "crmkit", name: "crmkit", summary: "Contacts, companies and customer relationships.",
              defaultInstructions: "Use crmkit to find and maintain contacts, companies, deals and activities. Search for matching records before creating new ones, and record concise factual notes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "crmkit",
              configuration: .mcp(.init(endpoint: URL(string: "https://api.crmkit.ai/mcp")!))),
        .init(id: "exa", name: "Exa", summary: "Web search and content discovery.",
              defaultInstructions: "Use Exa to search public web sources and retrieve relevant content. Cite sources, check dates and distinguish evidence from inference. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "exa",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.exa.ai/mcp")!))),
        .init(id: "fireflies", name: "Fireflies", summary: "Meeting transcripts and notes.",
              defaultInstructions: "Use Fireflies to find meeting transcripts and summarize decisions and follow-ups. Reference the relevant meeting and preserve uncertainty about speakers or commitments. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "fireflies",
              configuration: .mcp(.init(endpoint: URL(string: "https://api.fireflies.ai/mcp")!))),
        .init(id: "granola", name: "Granola", summary: "Meeting notes and knowledge.",
              defaultInstructions: "Use Granola to find meeting notes and summarize decisions and follow-ups. Reference the relevant meeting and avoid attributing commitments not supported by the notes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "granola",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.granola.ai/mcp")!))),
        .init(id: "higgsfield", name: "Higgsfield", summary: "Image and video creation.",
              defaultInstructions: "Use Higgsfield for requested image and video workflows. Follow the user's creative brief, check generation costs when available and avoid duplicate submissions. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "higgsfield",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.higgsfield.ai/mcp")!))),
        .init(id: "jam", name: "Jam", summary: "Bug reports and debugging context.",
              defaultInstructions: "Use Jam to inspect bug reports and debugging context. Summarize reproduction steps and observed evidence, and distinguish a confirmed cause from a hypothesis. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "jam",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.jam.dev/mcp")!))),
        .init(id: "jotform", name: "Jotform", summary: "Forms and submissions.",
              defaultInstructions: "Use Jotform to find forms and inspect submissions. Minimize exposure of personal data; confirm before publishing forms or changing live collection workflows. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "jotform",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.jotform.com")!))),
        .init(id: "linear", name: "Linear", summary: "Issues, projects and team planning.",
              defaultInstructions: "Use Linear to find and maintain issues, projects and comments. Check the target team and existing issue before making changes; include useful context in updates. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "linear",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.linear.app/mcp")!))),
        .init(id: "mapbox", name: "Mapbox", summary: "Maps and location services.",
              defaultInstructions: "Use Mapbox for mapping and location tasks. Verify coordinate order, units and the intended region; avoid exposing private location data unnecessarily. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "mapbox",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.mapbox.com/mcp")!))),
        .init(id: "morningstar", name: "Morningstar", summary: "Investment research and financial data.",
              defaultInstructions: "Use Morningstar to research financial and investment information. Report the source date, relevant currency and limitations; do not present historical data as a guaranteed outcome. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "morningstar",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.morningstar.com/mcp")!))),
        .init(id: "neon", name: "Neon", summary: "Postgres databases and projects.",
              defaultInstructions: "Use Neon to inspect Postgres projects, branches and schemas. Verify the target branch and environment; obtain approval before changing production data or schema. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "neon",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.neon.tech/mcp")!))),
        .init(id: "netlify", name: "Netlify", summary: "Web projects and deployments.",
              defaultInstructions: "Use Netlify to inspect sites and deploys. Verify the site and environment; obtain approval before production deployment or configuration changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "netlify",
              configuration: .mcp(.init(endpoint: URL(string: "https://netlify-mcp.netlify.app/mcp")!))),
        .init(id: "notion", name: "Notion", summary: "Pages, databases and workspace knowledge.",
              defaultInstructions: "Use Notion to find workspace knowledge and maintain pages and databases. Search for existing content before creating a new page; preserve existing structure when editing. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "notion",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.notion.com/mcp")!))),
        .init(id: "parallelai-search", name: "Parallel Search", summary: "Web search and research.",
              defaultInstructions: "Use Parallel Search to research public web information. Choose focused queries, link to supporting sources and distinguish source evidence from inference. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "parallelai-search",
              configuration: .mcp(.init(endpoint: URL(string: "https://search-mcp.parallel.ai/mcp")!))),
        .init(id: "parallelai-task", name: "Parallel Tasks", summary: "Longer research and data-processing tasks.",
              defaultInstructions: "Use Parallel Tasks for longer research and structured data tasks. Define a focused question and expected output, report source evidence and avoid duplicate task submissions. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "parallelai-task",
              configuration: .mcp(.init(endpoint: URL(string: "https://task-mcp.parallel.ai/mcp")!))),
        .init(id: "paypal", name: "PayPal", summary: "Payments, invoices and transactions.",
              defaultInstructions: "Use PayPal to inspect payments, transactions and invoices. Verify amounts, currencies and recipients; obtain explicit user approval before moving money or changing billing. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "paypal",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.paypal.com/mcp")!))),
        .init(id: "pipedream", name: "Pipedream", summary: "Connected apps and cross-service workflows.",
              defaultInstructions: "Use Pipedream to discover and use the apps connected to the user's Pipedream MCP account. Inspect the available tools and their schemas rather than assuming an app or account is available. Verify the target service and account before acting; ask if the intended account is unclear. When a tool returns an account-connection link, present it to the user to complete in their browser; never request or handle their credentials. Confirm before sending messages, publishing, deleting data or making financial changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "pipedream",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.pipedream.net/v2")!))),
        .init(id: "polar", name: "Polar", summary: "Billing, products and subscriptions.",
              defaultInstructions: "Use Polar to inspect products, subscriptions and billing. Verify environment, amounts and currency; obtain explicit approval before financial or customer-access changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "polar",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.polar.sh/mcp/polar-mcp")!))),
        .init(id: "prisma", name: "Prisma", summary: "Database projects and workflows.",
              defaultInstructions: "Use Prisma to inspect database projects and schemas. Verify the project and environment; obtain approval before applying migrations or destructive data changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "prisma",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.prisma.io/mcp")!))),
        .init(id: "pulumi", name: "Pulumi", summary: "Cloud infrastructure and deployments.",
              defaultInstructions: "Use Pulumi to inspect cloud infrastructure and deployment state. Prefer read-only inspection first; obtain approval before deployment, deletion or other infrastructure changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "pulumi",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.ai.pulumi.com/mcp")!))),
        .init(id: "ramp", name: "Ramp", summary: "Business spending and finance workflows.",
              defaultInstructions: "Use Ramp to inspect business spending and financial records. Verify the entity, amount, currency and period; obtain explicit approval before financial or policy changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "ramp",
              configuration: .mcp(.init(endpoint: URL(string: "https://ramp-mcp-remote.ramp.com/mcp")!))),
        .init(id: "revenuecat", name: "RevenueCat", summary: "Subscriptions and app revenue.",
              defaultInstructions: "Use RevenueCat to inspect app subscriptions and revenue. Verify the app, environment, period and currency; obtain approval before changing products or customer entitlements. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "revenuecat",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.revenuecat.ai/mcp")!))),
        .init(id: "runway", name: "Runway", summary: "Video and creative media.",
              defaultInstructions: "Use Runway for requested media generation and editing. Follow the user's brief, preserve source assets and avoid duplicate paid generation requests. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "runway",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.runwayml.com/mcp")!))),
        .init(id: "sanity", name: "Sanity", summary: "Structured content and publishing.",
              defaultInstructions: "Use Sanity to find and edit structured content. Preserve schema and document references; confirm before publishing or deleting content. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "sanity",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.sanity.io")!))),
        .init(id: "sentry", name: "Sentry", summary: "Errors, performance and debugging.",
              defaultInstructions: "Use Sentry to investigate errors, releases and performance. Start with the relevant project and time range; distinguish observed evidence from suspected causes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "sentry",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.sentry.dev/mcp")!))),
        .init(id: "stripe", name: "Stripe", summary: "Payments, customers and billing.",
              defaultInstructions: "Use Stripe to inspect customers, payments, subscriptions and invoices. Verify live versus test mode, amounts and currency; obtain explicit user approval for financial changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "stripe",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.stripe.com")!))),
        .init(id: "todoist", name: "Todoist", summary: "Tasks, projects and reminders.",
              defaultInstructions: "Use Todoist to find and maintain tasks and projects. Preserve due dates, priorities and project placement unless asked to change them; check for duplicates before adding tasks. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "todoist",
              configuration: .mcp(.init(endpoint: URL(string: "https://ai.todoist.net/mcp")!))),
        .init(id: "webflow", name: "Webflow", summary: "Website content and publishing.",
              defaultInstructions: "Use Webflow to inspect and edit website content. Preserve existing structure and styling unless asked; confirm before publishing or deleting content. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "webflow",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.webflow.com/mcp")!))),
        .init(id: "wix", name: "Wix", summary: "Websites and business content.",
              defaultInstructions: "Use Wix to inspect and maintain website content. Preserve existing design and business settings unless instructed otherwise; confirm before publishing changes. Use only tools actually offered by this connection and only within the user's request and granted permissions.", iconName: "wix",
              configuration: .mcp(.init(endpoint: URL(string: "https://mcp.wix.com/mcp")!))),
    ]

    public static func matching(_ query: String) -> [ToolDefinition] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return entries.filter { entry in
            let text = entry.name + " " + entry.summary + " " + entry.kind.rawValue
            return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
    }

    public static func availableName(for tool: ToolDefinition, existingNames: [String]) -> String {
        var name = tool.name
        var suffix = 2
        while existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(tool.name) \(suffix)"
            suffix += 1
        }
        return name
    }

    public static func definition(forMCPEndpoint endpoint: URL) -> ToolDefinition? {
        entries.first {
            switch $0.configuration {
            case .mcp(let configuration): return configuration.endpoint == endpoint
            }
        }
    }
}
