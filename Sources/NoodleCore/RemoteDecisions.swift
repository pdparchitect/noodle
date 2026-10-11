import Foundation

/// The three decision wire formats a server may speak. All carry the same typed
/// questions and answers; they differ in path, field names and model-id spelling,
/// which is why one typed layer serves all three.
public enum DecisionWireFormat: Sendable, Equatable {
    /// OpenRouter's plain-HTTP surface: full model id (`vendor/model`).
    case decisions
    /// The TypeSafe SDK surface: bare model id after the vendor prefix, so an
    /// existing SDK client switches to any host by changing its base URL.
    case systemOne
    /// The OpenAI Decisions surface: `input` plus a questions array, predicate
    /// instead of noul. OpenAI's API and OpenAI-compatible gateways speak it.
    case openAI

    var path: String {
        switch self {
        case .decisions: return "/api/alpha/decisions"
        case .systemOne: return "/v1/systemone"
        case .openAI: return "/v1/decisions"
        }
    }

    func requestModelID(_ model: DiscoveredDecisionModel) -> String {
        switch self {
        case .decisions, .openAI: return model.requestID
        case .systemOne: return model.requestID.split(separator: "/").last.map(String.init) ?? model.requestID
        }
    }
}

/// Serves decisions from any server the endpoint probe verified. The format and
/// the model came from discovery; nothing about either is baked in.
public struct RemoteDecisionsClient: DecisionModelServing {
    public let model: DiscoveredDecisionModel
    public let endpoint: URL
    public let format: DecisionWireFormat
    private let apiKey: String
    private let transport: any RemoteTransport

    public init(model: DiscoveredDecisionModel, endpoint: URL, format: DecisionWireFormat, apiKey: String,
                transport: any RemoteTransport = URLSessionRemoteTransport()) {
        self.model = model
        self.endpoint = endpoint
        self.format = format
        self.apiKey = apiKey
        self.transport = transport
    }

    public var isAvailable: Bool { !apiKey.isEmpty }
    public var supportsImages: Bool { model.supportsImages }

    public func decide(state: [String: any Sendable], questions: [String: DecisionQuestion]) async throws -> [String: DecisionAnswer] {
        try await DecisionWire.decide(
            endpoint: endpoint, format: format, apiKey: apiKey, modelID: format.requestModelID(model),
            state: DecisionWire.state(state), questions: questions, transport: transport)
    }
}

/// Asks any provider base URL which decision models it serves and where. A
/// provider that offers neither format yields no decision models, which leaves
/// the setting on the on-device backend — being unsupported is a state, not an error.
public struct RemoteDecisionsCatalog: DecisionModelCatalog {
    private let baseURL: URL
    private let apiKey: String
    private let transport: any RemoteTransport

    public init(baseURL: URL, apiKey: String, transport: any RemoteTransport = URLSessionRemoteTransport()) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    public init(account: RemoteModelAccount, key: String, transport: any RemoteTransport = URLSessionRemoteTransport()) {
        let base = account.baseURL ?? account.provider?.baseURL ?? Self.openRouterBase
        self.init(baseURL: base, apiKey: key, transport: transport)
    }

    /// OpenRouter's own base; also the default when an account names none.
    public static let openRouterBase = URL(string: "https://openrouter.ai")!

    public func decisionModels() async throws -> [DiscoveredDecisionModel] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "output_modalities", value: "decisions")]
        var request = URLRequest(url: components.url!)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 30
        let response = try await transport.send(request)
        guard response.status == 200 else { throw await DecisionWire.failure(response) }
        let decoded = try JSONDecoder().decode(CatalogResponse.self, from: try await DecisionWire.body(of: response))
        // A server that ignores the filter returns its whole catalog; the entry's own
        // output modalities decide, never the query string.
        return decoded.data.filter { $0.architecture?.output_modalities?.contains("decisions") ?? false }
            .map(DiscoveredDecisionModel.init)
    }

    /// Probes each format's path with a one-question request. Only 404/405 mean
    /// the path is not served; any other answer — including a 400 rejecting the
    /// probe's placeholder model id — proves a live endpoint speaking that format.
    public func detect() async throws -> (endpoint: URL, format: DecisionWireFormat) {
        for format in [DecisionWireFormat.decisions, .systemOne, .openAI] {
            let url = baseURL.appendingPathComponent(format.path)
            do {
                _ = try await DecisionWire.decide(
                    endpoint: url, format: format, apiKey: apiKey, modelID: "",
                    state: ["probe": true], questions: ["reachable": DecisionsProbe.question],
                    transport: transport)
                return (url, format)
            } catch DecisionWire.WireError.unsupportedPath {
                continue
            } catch {
                return (url, format)
            }
        }
        throw HarnessSetupError("No decisions endpoint answered at \(baseURL).")
    }

    /// The person's chosen model, served through the endpoint and format the probe verified.
    public func client(for model: DiscoveredDecisionModel) async throws -> RemoteDecisionsClient {
        let detected = try await detect()
        return RemoteDecisionsClient(model: model, endpoint: detected.endpoint, format: detected.format,
                                     apiKey: apiKey, transport: transport)
    }
}

/// Wire encoding shared by the client, the endpoint probe and the catalog reads.
/// State values must be JSON-serializable or `DecisionImage`; images travel as
/// data URIs, which vision models read straight from state.
enum DecisionWire {
    static func decide(endpoint: URL, format: DecisionWireFormat, apiKey: String, modelID: String,
                       state: [String: Any], questions: [String: DecisionQuestion],
                       transport: any RemoteTransport) async throws -> [String: DecisionAnswer] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 60
        let payload: [String: Any]
        switch format {
        case .decisions, .systemOne:
            payload = [
                "model": modelID, "state": state,
                "questions": questions.reduce(into: [String: Any]()) { $0[$1.key] = $1.value.wire },
            ]
        case .openAI:
            // The OpenAI surface takes `input` and a positional array; `name`
            // carries the caller's question id back in the answers. Dictionary
            // iteration is unordered, so the array is sorted by id to make the
            // request deterministic.
            payload = [
                "model": modelID, "input": state,
                "questions": questions.sorted { $0.key < $1.key }.map { id, question in
                    var wire = question.openAIWire
                    wire["name"] = id
                    return wire
                },
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let response = try await transport.send(request)
        guard response.status == 200 else {
            // A path the server does not serve answers 404/405; the probe walks on.
            if response.status == 404 || response.status == 405 { throw WireError.unsupportedPath }
            throw await failure(response)
        }
        let data = try await body(of: response)
        if format == .openAI,
            let array = try? JSONDecoder().decode(OpenAIDecisionsResponse.self, from: data)
        {
            return array.answers.reduce(into: [String: DecisionAnswer]()) { result, answer in
                result[answer.name] = DecisionAnswer(answer: answer)
            }
        }
        let decoded = try JSONDecoder().decode(DecisionsResponse.self, from: data)
        return decoded.answers.mapValues(DecisionAnswer.init)
    }

    static func state(_ state: [String: any Sendable]) -> [String: Any] {
        state.mapValues { value in
            guard let image = value as? DecisionImage else { return value }
            return ["image_url": "data:image/png;base64," + image.data.base64EncodedString()]
        }
    }

    static func body(of response: RemoteHTTPResponse) async throws -> Data {
        var lines = [String]()
        for try await line in response.lines where lines.count < 1_000 { lines.append(line) }
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func failure(_ response: RemoteHTTPResponse) async -> Swift.Error {
        let detail = String(decoding: (try? await body(of: response))?.prefix(300) ?? Data(), as: UTF8.self)
        return HarnessSetupError("The decision model rejected the request (HTTP \(response.status)): \(detail)")
    }

    enum WireError: Swift.Error { case unsupportedPath }
}

struct CatalogResponse: Decodable {
    struct Entry: Decodable {
        struct Architecture: Decodable {
            let input_modalities: [String]?
            let output_modalities: [String]?
        }
        struct Pricing: Decodable {
            let prompt: String?
        }
        let id: String
        let canonical_slug: String?
        let name: String?
        let context_length: Int?
        let architecture: Architecture?
        let pricing: Pricing?
        let description: String?
    }

    let data: [Entry]
}

extension DiscoveredDecisionModel {
    init(entry: CatalogResponse.Entry) {
        self.init(
            id: entry.id,
            canonicalSlug: entry.canonical_slug,
            displayName: entry.name ?? entry.id,
            supportsImages: entry.architecture?.input_modalities?.contains("image") ?? false,
            contextLength: entry.context_length ?? 0,
            promptTokenPrice: entry.pricing?.prompt.flatMap(Double.init),
            description: entry.description ?? "")
    }
}

struct DecisionsResponse: Decodable {
    struct Answer: Decodable {
        let noul: Double?
        let choice: String?
        let probabilities: [String: Double]?
        let score: Double?
        let confidence: Double?
    }

    let answers: [String: Answer]
}

extension DecisionAnswer {
    init(answer: DecisionsResponse.Answer) {
        self.init(
            noul: answer.noul.map(Float.init),
            choice: answer.choice,
            probabilities: answer.probabilities.map { $0.mapValues(Float.init) },
            score: answer.score.map(Float.init),
            confidence: answer.confidence.map(Float.init),
            calibrated: true)
    }
}

extension DecisionQuestion {
    /// The OpenAI surface's names: predicate for noul, `choices` and `levels`
    /// arrays for the option sets.
    var openAIWire: [String: Any] {
        switch self {
        case .noul(let instructions, _):
            return ["type": "predicate", "instructions": instructions]
        case .choice(let instructions, let criteria):
            return [
                "type": "choice", "instructions": instructions,
                "choices": criteria.keys.sorted().map { ["value": $0, "description": criteria[$0] ?? ""] },
            ]
        case .score(let instructions, let criteria):
            return [
                "type": "score", "instructions": instructions,
                "levels": criteria.map { ["label": $0] },
            ]
        }
    }
}

struct OpenAIDecisionsResponse: Decodable {
    struct Answer: Decodable {
        struct Probability: Decodable {
            let value: StringOrNumber
            let probability: Double
        }

        enum StringOrNumber: Decodable {
            case string(String), number(Double)

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let string = try? container.decode(String.self) { self = .string(string) } else {
                    self = .number(try container.decode(Double.self))
                }
            }

            var key: String {
                switch self {
                case .string(let string): return string
                case .number(let number): return String(Int(number))
                }
            }
        }

        let name: String
        let probability: Double?
        let choice: String?
        let score: Double?
        let confidence: Double?
        let probabilities: [Probability]?
    }

    let answers: [Answer]
}

extension DecisionAnswer {
    init(answer: OpenAIDecisionsResponse.Answer) {
        self.init(
            noul: answer.probability.map(Float.init),
            choice: answer.choice,
            probabilities: answer.probabilities.map { probabilities in
                probabilities.reduce(into: [String: Float]()) { $0[$1.value.key] = Float($1.probability) }
            },
            score: answer.score.map(Float.init),
            confidence: answer.confidence.map(Float.init),
            calibrated: true)
    }
}
