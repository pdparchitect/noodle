import Foundation
import FoundationModels
import NoodleCore

public enum AppleModel {
    /// Packaging must retain newer features even when the build host runs an
    /// older OS and cannot report them through runtime model inspection.
    public static var compiledWithMacOS27Support: Bool {
        #if canImport(FoundationModels, _version: 2)
        true
        #else
        false
        #endif
    }

    public static func inspection(version: String, modelsDirectory: URL? = nil) -> AppleHarnessInspection {
        var name = "Apple on-device"
        var description = "Apple Intelligence’s on-device model."
        var localSupported = false
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) {
            localSupported = true
            let model = SystemLanguageModel.default
            if model.isAvailable {
                name = model.variant.displayName
                let context = model.contextSize
                var details = ["On device"]
                if context > 0 { details.append("\(context.formatted()) token context") }
                if model.capabilities.contains(.vision) { details.append("Images") }
                if model.capabilities.contains(.toolCalling) { details.append("Tools") }
                if model.capabilities.contains(.guidedGeneration) { details.append("Structured output") }
                if model.capabilities.contains(.reasoning) { details.append("Reasoning") }
                description = details.joined(separator: " · ")
            }
        }
        #endif
        var models = [HarnessModel(id: "default", displayName: name, description: description,
                                  supportedEfforts: [], defaultEffort: "", isDefault: true)]
        if localSupported, let modelsDirectory {
            models += ((try? AppleLocalModelStore(directory: modelsDirectory).models()) ?? []).map(\.harnessModel)
        }
        let reason = systemUnavailableReason
        if reason != nil, models.count > 1 { models.removeFirst() }
        return .init(models: models, unavailableReason: models.contains(where: { $0.id != "default" }) ? nil : reason,
                     version: version, localModelsSupported: localSupported)
    }

    static var systemUnavailableReason: String? {
        let reason: String?
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: reason = nil
            case .unavailable(.deviceNotEligible): reason = "Apple Intelligence is not supported on this Mac."
            case .unavailable(.appleIntelligenceNotEnabled): reason = "Enable Apple Intelligence in System Settings, then check again."
            case .unavailable(.modelNotReady): reason = "The Apple on-device model is not ready. Let its download finish in System Settings, then check again."
            case .unavailable: reason = "Apple Intelligence is currently unavailable. Check System Settings."
            }
        } else { reason = "The Apple harness requires macOS 26 or later and an Apple Intelligence capable Mac." }
        return reason
    }

    public static func respond(workspace: URL, modelIdentifier: String?, remote: AppleRemoteAccess? = nil, wake: String,
                               onEvent: @escaping @Sendable (AppleActivityEvent) async -> Void = { _ in },
                               onActivity: @escaping @Sendable () -> Void) async throws {
        guard #available(macOS 26, *) else { throw HarnessSetupError("The Apple harness requires macOS 26 or later.") }
        onActivity()
        await onEvent(.status("Preparing turn"))
        let backend = try await AppleModelBackend.prepare(identifier: modelIdentifier, workspace: workspace, remote: remote)
        try await run(workspace: workspace, backend: backend, wake: wake, onEvent: onEvent, onActivity: onActivity)
    }

    /// Like Codex and Claude, the model gets AGENTS.md, the workspace skills
    /// and the wake event. It reads and answers its messages with its tools.
    @available(macOS 26, *)
    static func run(workspace: URL, backend: AppleModelBackend, wake: String,
                    onEvent: @escaping @Sendable (AppleActivityEvent) async -> Void,
                    onActivity: @escaping @Sendable () -> Void) async throws {
        let context = try AppleToolContext(workspace: workspace, pageBytes: backend.pageBytes)
        let unfinished = workspace.appendingPathComponent(".noodle/apple/unfinished")
        let recovering = FileManager.default.fileExists(atPath: unfinished.path)
        try AtomicFile.write(Data("unfinished".utf8), to: unfinished)
        let instructions = try AppleWorkspaceInstructions.text(workspace: workspace)
        await onEvent(.status("Loaded AGENTS.md and skill catalogue"))
        var look: (@Sendable (URL) async throws -> String)?
        if backend.supportsImages { look = { url in try await backend.describe(image: url) } }
        let tools = workspaceTools(context: context, look: look, onEvent: onEvent, onActivity: onActivity)
        let file = AppleConversationSession.file(in: workspace)
        let saved = try AppleConversationSession.load(from: file)
        let entries = try await backend.recentEntries(saved, prompt: wake, instructions: instructions, tools: tools)
        let control = AppleTurnControl(resuming: recovering && saved?.transcript.isEmpty == false)
        let session = backend.session(tools: tools, instructions: instructions, entries: entries, control: control) { transcript in
            try AppleConversationSession(transcript: AppleConversationSession.persistable(transcript),
                modelIdentifier: backend.identifier).save(to: file)
        }
        var stored = false
        defer {
            // Private local diagnostics and a recovery aid, like other harness
            // transcripts. Never sent to the app's visible conversation stream.
            try? AtomicFile.write(JSONEncoder().encode(AppleConversationSession.persistable(session.transcript)),
                to: workspace.appendingPathComponent(".noodle/apple/last-transcript.json"))
            if !stored {
                try? AppleConversationSession(transcript: AppleConversationSession.persistable(session.transcript),
                    modelIdentifier: backend.identifier).save(to: file)
            }
        }
        onActivity()
        do {
            // The final text is private, as for other harnesses; replies go
            // through Messenger.
            _ = try await AppleResponseRecovery.respond(session: session, prompt: Prompt(wake),
                responseTokens: backend.responseTokens, control: control, allowsEmptyReply: true, onEvent: onEvent, onActivity: onActivity)
            try Task.checkCancellation()
            try AppleConversationSession(transcript: AppleConversationSession.persistable(session.transcript),
                modelIdentifier: backend.identifier).save(to: file)
            stored = true
            try FileManager.default.removeItem(at: unfinished)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            saveFailure(error, in: workspace)
            throw HarnessSetupError("The selected model could not finish this turn: \(failureDescription(error)). Unfinished work is preserved; retry to continue.")
        }
    }

    @available(macOS 26, *)
    static func workspaceTools(context: AppleToolContext, look: (@Sendable (URL) async throws -> String)? = nil,
                               onEvent: @escaping @Sendable (AppleActivityEvent) async -> Void = { _ in },
                               onActivity: @escaping @Sendable () -> Void) -> [any Tool] {
        [Bash(context: context, activity: onActivity, onEvent: onEvent),
         Read(context: context, look: look, activity: onActivity, onEvent: onEvent),
         Write(context: context, activity: onActivity, onEvent: onEvent),
         Edit(context: context, activity: onActivity, onEvent: onEvent)]
    }

    @available(macOS 26, *)
    private static func saveFailure(_ error: Error, in workspace: URL) {
        // Keep framework diagnostics local, alongside the private transcript.
        // The visible conversation receives the short actionable error above.
        let description = String(String(reflecting: error).prefix(8_192))
        try? AtomicFile.write(Data(description.utf8), to: workspace.appendingPathComponent(".noodle/apple/last-error.txt"))
    }

    @available(macOS 26, *)
    private static func failureDescription(_ error: Error) -> String {
        if error is AppleContextLimit { return error.localizedDescription }
        if AppleContextOverflow.matches(error) { return "the selected model’s context filled while processing the turn" }
        #if canImport(FoundationModels, _version: 2)
        if #available(macOS 27, *) {
            if let error = error as? LanguageModelError {
                switch error {
                case .contextSizeExceeded: return "the selected model’s context filled while processing the turn"
                case .rateLimited: return "the selected model is busy; try again shortly"
                case .guardrailViolation, .refusal: return "the selected model declined this request"
                case .unsupportedCapability: return "the selected model does not support this request’s capabilities"
                case .unsupportedTranscriptContent: return "the selected model cannot read this conversation’s content"
                case .unsupportedGenerationGuide: return "the selected model cannot use this tool or response schema"
                case .unsupportedLanguageOrLocale: return "the selected model does not support this language or locale"
                case .timeout: return "the selected model timed out"
                @unknown default: return error.localizedDescription
                }
            }
            if let error = error as? SystemLanguageModel.Error { return error.localizedDescription }
        }
        #endif
        if let error = error as? LanguageModelSession.ToolCallError { return "\(error.tool.name): \(error.underlyingError.localizedDescription)" }
        guard let error = error as? LanguageModelSession.GenerationError else { return error.localizedDescription }
        switch error {
        case .exceededContextWindowSize: return "the selected model’s context filled while processing the turn"
        case .assetsUnavailable: return "the on-device model assets are unavailable; check Apple Intelligence in System Settings"
        case .guardrailViolation, .refusal: return "the selected model declined this request"
        case .unsupportedGuide: return "the selected model could not use a response schema"
        case .unsupportedLanguageOrLocale: return "the selected model does not support this language or locale"
        case .decodingFailure: return "the selected model returned an invalid structured response"
        case .rateLimited, .concurrentRequests: return "the selected model is busy; try again shortly"
        @unknown default: return "the selected model is temporarily unavailable"
        }
    }
}

@available(macOS 26, *)
private struct Read: Tool {
    let context: AppleToolContext
    let look: (@Sendable (URL) async throws -> String)?
    let activity: @Sendable () -> Void
    let onEvent: @Sendable (AppleActivityEvent) async -> Void
    let name = "read"
    var description: String {
        "Read a text file one page at a time, or list a directory." + (look == nil ? "" : " For an image file, returns what it shows.")
    }
    @Generable struct Arguments {
        @Guide(description: "File or directory path, absolute or relative to the working directory.")
        var path: String
        @Guide(description: "Byte offset to start from. Omit for the start; use the offset the previous page gives.")
        var offset: Int?
    }
    func call(arguments: Arguments) async throws -> String {
        activity()
        let offset = arguments.offset ?? 0
        return try await AppleToolActivity.perform(name: "Read file", input: ["path": arguments.path, "offset": String(offset)], onEvent: onEvent) {
            if let look, let image = try await context.image(path: arguments.path) {
                return AppleToolResult(text: "Image \(image.path) shows:\n" + (try await look(image)))
            }
            return AppleToolResult(text: try await context.read(path: arguments.path, offset: offset))
        }
    }
}

@available(macOS 26, *)
private struct Write: Tool {
    let context: AppleToolContext
    let activity: @Sendable () -> Void
    let onEvent: @Sendable (AppleActivityEvent) async -> Void
    let name = "write"
    let description = "Create or replace a UTF-8 file, or append to it. Parent directories must exist."
    @Generable struct Arguments {
        @Guide(description: "File path, absolute or relative to the working directory.")
        var path: String
        @Guide(description: "The text to write.")
        var content: String
        @Guide(description: "True to add the text to the end of the file, for writing a long file in parts.")
        var append: Bool?
    }
    func call(arguments: Arguments) async throws -> String {
        activity()
        let append = arguments.append ?? false
        return try await AppleToolActivity.perform(name: "Write file", input: ["path": arguments.path, "bytes": String(arguments.content.utf8.count)]
            .merging(append ? ["append": "true"] : [:]) { $1 }, onEvent: onEvent) {
            AppleToolResult(text: try await context.write(path: arguments.path, content: arguments.content, append: append))
        }
    }
}

@available(macOS 26, *)
private struct Edit: Tool {
    let context: AppleToolContext
    let activity: @Sendable () -> Void
    let onEvent: @Sendable (AppleActivityEvent) async -> Void
    let name = "edit"
    let description = "Replace one exact piece of text in a UTF-8 file, without rewriting the whole file."
    @Generable struct Arguments {
        @Guide(description: "File path, absolute or relative to the working directory.")
        var path: String
        @Guide(description: "The exact text to replace. It must appear exactly once in the file.")
        var old: String
        @Guide(description: "The replacement text.")
        var new: String
    }
    func call(arguments: Arguments) async throws -> String {
        activity()
        return try await AppleToolActivity.perform(name: "Edit file", input: ["path": arguments.path], onEvent: onEvent) {
            AppleToolResult(text: try await context.edit(path: arguments.path, old: arguments.old, new: arguments.new))
        }
    }
}

@available(macOS 26, *)
private struct Bash: Tool {
    let context: AppleToolContext
    let activity: @Sendable () -> Void
    let onEvent: @Sendable (AppleActivityEvent) async -> Void
    let name = "bash"
    let description = "Run a Bash command in the working directory. Quote paths and arguments."
    @Generable struct Arguments {
        @Guide(description: "The command line to run with bash -c.")
        var command: String
    }
    func call(arguments: Arguments) async throws -> String {
        activity()
        return try await AppleToolActivity.perform(name: "Bash", input: ["command": arguments.command], onEvent: onEvent) {
            try await context.executeResult(command: arguments.command)
        }
    }
}
