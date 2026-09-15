import Foundation
import FoundationModels
#if canImport(FoundationModels, _version: 2)
import CoreGraphics

/// Applied at the executor boundary, before *each* generation, including after
/// tool calls. Only the model's input is compacted; the session keeps the full
/// transcript and the framework never has to replay a completed tool call.
@available(macOS 27, *)
struct AppleContextModel<Base: LanguageModel>: LanguageModel {
    let base: Base
    let budget: AppleContextBudget
    let count: @Sendable (LanguageModelExecutorGenerationRequest) async throws -> Int

    var capabilities: LanguageModelCapabilities { base.capabilities }
    var executorConfiguration: Base.Executor.Configuration { base.executorConfiguration }

    struct Executor: LanguageModelExecutor {
        typealias Model = AppleContextModel<Base>
        let underlying: Base.Executor
        init(configuration: Base.Executor.Configuration) throws {
            underlying = try Base.Executor(configuration: configuration)
        }

        func respond(to request: LanguageModelExecutorGenerationRequest, model: Model,
                     streamingInto channel: LanguageModelExecutorGenerationChannel) async throws {
            let fitted = try await model.budget.fit(request, count: model.count)
            try Task.checkCancellation()
            try await underlying.respond(to: fitted, model: model.base, streamingInto: channel)
        }
    }
}

@available(macOS 27, *)
struct AppleContextBudget: Sendable {
    let contextSize: Int
    var responseTokens = 768
    var reserve = 512

    /// The macOS 27 token-counting service rejects image attachments (model
    /// service error 1001), even when inference accepts the same image. Count
    /// text/schemas natively and reserve a conservative image/tile allowance.
    /// The allowance falls with resolution so oversized requests can be fitted.
    static func systemTokenCount(_ request: LanguageModelExecutorGenerationRequest,
                                 model: SystemLanguageModel) async throws -> Int {
        let (entries, imageTokens) = textAndImageBudget(Array(request.transcript))
        var count = try await model.tokenCount(for: entries) + imageTokens
        if let schema = request.schema { count += try await model.tokenCount(for: schema) }
        return count
    }

    static func textAndImageBudget(_ entries: [Transcript.Entry]) -> ([Transcript.Entry], Int) {
        var imageTokens = 0
        let text = entries.map { entry -> Transcript.Entry in
            guard case .prompt(var prompt) = entry else { return entry }
            prompt.segments = prompt.segments.map { segment in
                guard case .attachment(let attachment) = segment, case .image(let image) = attachment.content else { return segment }
                let pixels = image.cgImage
                let tiles = max(1, (pixels.width + 511) / 512) * max(1, (pixels.height + 511) / 512)
                imageTokens += 256 + tiles * 128
                return .text(.init(id: attachment.id, content: "[Image: \(attachment.label ?? "image")]"))
            }
            return .prompt(prompt)
        }
        return (text, imageTokens)
    }

    func fit(_ original: LanguageModelExecutorGenerationRequest,
             count: (LanguageModelExecutorGenerationRequest) async throws -> Int) async throws -> LanguageModelExecutorGenerationRequest {
        var request = original
        var entries = Array(request.transcript)
        let wanted = max(1, min(request.generationOptions.maximumResponseTokens ?? responseTokens, responseTokens))
        let minimum = min(wanted, 128)
        while true {
            try Task.checkCancellation()
            request.transcript = Transcript(entries: entries)
            let used: Int
            do { used = try await count(request) }
            catch {
                // Some SDK builds reject an oversized transcript even when
                // counting it. The reported count still lets us compact it.
                guard let reported = AppleContextOverflow.tokenCount(in: error) else { throw error }
                used = reported
            }
            if used + wanted + reserve <= contextSize {
                request.generationOptions.maximumResponseTokens = wanted
                return request
            }
            // Preserve whole turns, including all call/output pairs. The most
            // recent prompt, instructions and tool schemas are never discarded.
            if Self.removeOldestTurn(&entries) { continue }
            if Self.shortenToolOutput(&entries) { continue }
            if Self.reduceImage(&entries) { continue }
            let available = contextSize - used - reserve
            if available >= minimum {
                request.generationOptions.maximumResponseTokens = min(wanted, available)
                return request
            }
            throw AppleContextLimit()
        }
    }

    static func removeOldestTurn(_ entries: inout [Transcript.Entry]) -> Bool {
        let prompts = entries.indices.filter { if case .prompt = entries[$0] { return true }; return false }
        guard prompts.count > 1 else { return false }
        entries.removeSubrange(prompts[0]..<prompts[1])
        return true
    }

    private static func shortenToolOutput(_ entries: inout [Transcript.Entry]) -> Bool {
        // Retain the call, its arguments, and the start/end of its result. In
        // particular, keep exit status and the saved-output path/page offset.
        let candidates = entries.indices.compactMap { index -> (Int, Int, Int)? in
            guard case .toolOutput(let output) = entries[index] else { return nil }
            guard let segment = output.segments.indices.max(by: {
                output.segments[$0].description.utf8.count < output.segments[$1].description.utf8.count
            }), case .text(let text) = output.segments[segment], text.content.utf8.count > 768 else { return nil }
            return (index, segment, text.content.utf8.count)
        }
        for (index, segment, _) in candidates.sorted(by: { $0.2 > $1.2 }) {
            guard case .toolOutput(var output) = entries[index], case .text(var text) = output.segments[segment] else { continue }
            // Keep Noodle's retrieval footer intact, including long workspace
            // paths. An excerpt must not cut off how to read the full result.
            let footerStart = ["\n[Full result saved at ", "\n[bytes "].compactMap {
                text.content.range(of: $0, options: .backwards)?.lowerBound
            }.max() ?? text.content.endIndex
            let footer = text.content[footerStart...]
            let scalars = text.content[..<footerStart].unicodeScalars
            let keep = max(16, scalars.count / 4)
            let excerpt = String(scalars.prefix(keep))
                + "\n[Output excerpt; this tool call already completed.]\n"
                + String(scalars.suffix(keep)) + footer
            guard excerpt.utf8.count < text.content.utf8.count else { continue }
            text.content = excerpt
            output.segments[segment] = .text(text)
            entries[index] = .toolOutput(output)
            return true
        }
        return false
    }

    private static func reduceImage(_ entries: inout [Transcript.Entry]) -> Bool {
        for index in entries.indices {
            guard case .prompt(var prompt) = entries[index] else { continue }
            for segment in prompt.segments.indices {
                guard case .attachment(var attachment) = prompt.segments[segment],
                      case .image(let image) = attachment.content else { continue }
                let original = image.cgImage
                let edge = max(original.width, original.height)
                guard edge > 512 else { continue }
                let scale = Double(max(512, edge / 2)) / Double(edge)
                guard let context = CGContext(data: nil, width: max(1, Int(Double(original.width) * scale)),
                    height: max(1, Int(Double(original.height) * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.interpolationQuality = .high
                context.draw(original, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                guard let resized = context.makeImage() else { continue }
                attachment.content = .image(.init(resized, orientation: image.orientation))
                prompt.segments[segment] = .attachment(attachment)
                entries[index] = .prompt(prompt)
                return true
            }
        }
        return false
    }
}
#endif

struct AppleContextLimit: Error, LocalizedError {
    var errorDescription: String? {
        "This request and its images or tool results are too large for the selected model. Send a smaller request or fewer images, or choose a model with a larger context window."
    }
}

enum AppleContextOverflow {
    @available(macOS 26, *)
    static func tokenCount(in error: Error) -> Int? {
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *), let modelError = error as? LanguageModelError {
            if case .contextSizeExceeded(let details) = modelError { return details.tokenCount }
            return nil
        }
        #endif
        // The macOS 27 inference service can surface this lower-level error
        // instead of LanguageModelError. Recognize only its specific domain
        // and token-limit wording, never arbitrary service failures.
        let description = String(reflecting: error)
        guard description.contains("TokenGenerationInference.DecoderModelError"),
              let regex = try? NSRegularExpression(pattern: #"Provided ([\d,]+) tokens, but the maximum allowed is ([\d,]+)"#),
              let match = regex.firstMatch(in: description, range: NSRange(description.startIndex..., in: description)),
              let range = Range(match.range(at: 1), in: description) else { return nil }
        return Int(description[range].replacingOccurrences(of: ",", with: ""))
    }
}
