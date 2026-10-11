import NoodleCore
import XCTest

/// Wire-level tests for the three decision formats: what each format puts on the
/// wire for the same typed question, and how each response shape maps back.
final class RemoteDecisionsTests: XCTestCase {
    /// Serves canned bodies per path, recording the requests it saw.
    final class StubTransport: RemoteTransport, @unchecked Sendable {
        var requests: [(path: String, body: [String: Any])] = []
        private let responses: [String: (status: Int, body: String)]

        init(_ responses: [String: (status: Int, body: String)]) {
            self.responses = responses
        }

        func send(_ request: URLRequest) async throws -> RemoteHTTPResponse {
            let path = request.url!.path
            let body = request.httpBody.map { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? nil
            requests.append((path, body ?? [:]))
            let canned = responses[path] ?? (404, "{}")
            let lines = AsyncThrowingStream<String, Error> { $0.yield(canned.body); $0.finish() }
            return RemoteHTTPResponse(status: canned.status, headers: [:], lines: lines)
        }
    }

    private func model(images: Bool = false) -> DiscoveredDecisionModel {
        DiscoveredDecisionModel(id: "typesafe/jev-1.13", canonicalSlug: "typesafe/jev-1.13-20260917",
                                displayName: "Jev 1.13", supportsImages: images, contextLength: 32_000,
                                promptTokenPrice: 0.00000004, description: "")
    }

    private func questions() -> [String: DecisionQuestion] {
        [
            "settled": .noul(instructions: "The page finished rendering."),
            "queue": .choice(instructions: "Which team?", criteria: ["billing": "Payments.", "shipping": "Delivery."]),
            "urgency": .score(instructions: "How urgent?", criteria: ["low", "high"]),
        ]
    }

    private func client(_ format: DecisionWireFormat, transport: StubTransport) -> RemoteDecisionsClient {
        let path = format == .decisions ? "/api/alpha/decisions"
            : format == .systemOne ? "/v1/systemone" : "/v1/decisions"
        return RemoteDecisionsClient(model: model(), endpoint: URL(string: "https://example.test")!.appendingPathComponent(path),
                              format: format, apiKey: "key", transport: transport)
    }

    func testDecisionsFormatSendsFullModelIDAndKeyedQuestions() async throws {
        let transport = StubTransport(["/api/alpha/decisions": (200, #"{"answers":{"settled":{"type":"noul","noul":0.9}}}"#)])
        let answers = try await client(.decisions, transport: transport).decide(state: ["page": "done"], questions: ["settled": .noul(instructions: "The page finished rendering.")])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.path, "/api/alpha/decisions")
        XCTAssertEqual(request.body["model"] as? String, "typesafe/jev-1.13-20260917")
        XCTAssertEqual((request.body["questions"] as? [String: Any])?.keys.sorted(), ["settled"])
        XCTAssertEqual(answers["settled"]?.noul, 0.9)
    }

    func testSystemOneFormatStripsVendorPrefix() async throws {
        let transport = StubTransport(["/v1/systemone": (200, #"{"answers":{"settled":{"type":"noul","noul":0.2}}}"#)])
        _ = try await client(.systemOne, transport: transport).decide(state: ["page": "loading"], questions: ["settled": .noul(instructions: "The page finished rendering.")])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.path, "/v1/systemone")
        XCTAssertEqual(request.body["model"] as? String, "jev-1.13-20260917")
    }

    func testOpenAIEncodingAndAnswerMapping() async throws {
        let transport = StubTransport([
            "/v1/decisions": (200, """
            {"answers":[
              {"type":"predicate","name":"settled","probability":0.95},
              {"type":"choice","name":"queue","choice":"shipping","confidence":0.8,
               "probabilities":[{"value":"billing","probability":0.2},{"value":"shipping","probability":0.8}]},
              {"type":"score","name":"urgency","score":1.3,
               "probabilities":[{"value":0,"label":"low","probability":0.3},{"value":1,"label":"high","probability":0.7}]}
            ]}
            """)
        ])
        let answers = try await client(.openAI, transport: transport).decide(state: ["page": "done"], questions: questions())
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.path, "/v1/decisions")
        XCTAssertEqual(request.body["model"] as? String, "typesafe/jev-1.13-20260917")
        XCTAssertNotNil(request.body["input"])
        let sent = try XCTUnwrap(request.body["questions"] as? [[String: Any]])
        XCTAssertEqual(sent.map { $0["name"] as? String }, ["queue", "settled", "urgency"])
        XCTAssertEqual(sent[0]["type"] as? String, "choice")
        XCTAssertEqual((sent[0]["choices"] as? [[String: Any]])?.map { $0["value"] as? String }, ["billing", "shipping"])
        XCTAssertEqual((sent[2]["levels"] as? [[String: Any]])?.map { $0["label"] as? String }, ["low", "high"])
        XCTAssertEqual(answers["settled"]?.noul, 0.95)
        XCTAssertEqual(answers["queue"]?.choice, "shipping")
        XCTAssertEqual(answers["queue"]?.probabilities?["shipping"], 0.8)
        XCTAssertEqual(answers["urgency"]?.score, 1.3)
        XCTAssertEqual(answers["urgency"]?.probabilities?["1"], 0.7)
    }

    func testImagesTravelAsDataURIs() async throws {
        let transport = StubTransport(["/api/alpha/decisions": (200, #"{"answers":{}}"#)])
        let image = DecisionImage(data: Data([0x89, 0x50]), label: "screenshot")
        _ = try await client(.decisions, transport: transport).decide(state: ["shot": image], questions: questions())
        let request = try XCTUnwrap(transport.requests.first)
        let state = try XCTUnwrap(request.body["state"] as? [String: Any])
        let wrapped = try XCTUnwrap(state["shot"] as? [String: Any])
        XCTAssertTrue((wrapped["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    func testCatalogFiltersOnEntryOutputModalities() async throws {
        let entry = #"{"data":[{"id":"a","architecture":{"input_modalities":["text","image"],"output_modalities":["decisions"]}},{"id":"b","architecture":{"input_modalities":["text"],"output_modalities":["text"]}}]}"#
        let transport = StubTransport(["/api/v1/models": (200, entry)])
        let catalog = RemoteDecisionsCatalog(baseURL: URL(string: "https://example.test")!, apiKey: "key", transport: transport)
        // A server that ignored the filter would still leave only the decision model.
        let models = try await catalog.decisionModels()
        XCTAssertEqual(models.map(\.id), ["a"])
        XCTAssertEqual(models.first?.requestID, "a")
        XCTAssertTrue(models.first?.supportsImages ?? false)
    }

    /// Live end-to-end through OpenRouter with the real discovery path. Opt-in:
    /// NOODLE_LIVE_DECISIONS_KEY must hold an OpenRouter API key.
    func testLiveDiscoveryDetectDecide() async throws {
        let key = ProcessInfo.processInfo.environment["NOODLE_LIVE_DECISIONS_KEY"]
        try XCTSkipIf(key == nil || key!.isEmpty, "Set NOODLE_LIVE_DECISIONS_KEY to run the live smoke.")

        let catalog = RemoteDecisionsCatalog(baseURL: RemoteDecisionsCatalog.openRouterBase, apiKey: key!)
        let models = try await catalog.decisionModels()
        XCTAssertGreaterThan(models.count, 1, "The decision catalog should list several models.")
        let pinned = try XCTUnwrap(models.first { $0.canonicalSlug != nil }, "At least one model carries a canonical slug.")

        let detected = try await catalog.detect()
        XCTAssertEqual(detected.format, .decisions, "OpenRouter answers the alpha decisions path first.")

        let client = try await catalog.client(for: pinned)
        let answers = try await client.decide(
            state: ["page": ["title": "Loading", "text": "Loading your workspace…"]],
            questions: ["settled": .noul(instructions: "The page finished rendering its primary content.")])
        let settled = try XCTUnwrap(answers["settled"])
        XCTAssertLessThan(settled.noul ?? 1, 0.5, "A loading page should not read as settled.")
    }

    func testUnsupportedModelIsNotImagesCapableByDefault() {
        XCTAssertFalse(model().supportsImages)
        XCTAssertTrue(model(images: true).supportsImages)
    }
}
