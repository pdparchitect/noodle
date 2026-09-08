// Manual native UI fixture: no store, harness, persistence or message sending.
import AppKit
import SwiftUI
import NoodleCore

private func fixtureAvatarData() -> Data? {
    NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
        NSColor.systemOrange.setFill()
        rect.fill()
        return true
    }.tiffRepresentation
}

private struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, line: UInt = #line) throws {
    if !condition() { throw FixtureFailure(description: "Avatar/menu regression failed at line \(line)") }
}

private func pixelDifference(_ lhs: NSImage, _ rhs: NSImage) -> CGFloat {
    let a = NSBitmapImageRep(cgImage: lhs.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    let b = NSBitmapImageRep(cgImage: rhs.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
    var difference: CGFloat = 0
    for y in 0..<a.pixelsHigh {
        for x in 0..<a.pixelsWide {
            let c = a.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let d = b.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            difference += abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent)
                + abs(c.blueComponent - d.blueComponent) + abs(c.alphaComponent - d.alphaComponent)
        }
    }
    return difference / CGFloat(a.pixelsWide * a.pixelsHigh * 4)
}

@MainActor private func verifyNativeMenuPresentation() throws {
    let clipboard = NSPasteboard.withUniqueName()
    defer { clipboard.releaseGlobally() }
    try require(!ImageAttachmentPasteboard.canPasteImage(clipboard))
    clipboard.setString("Plain text", forType: .string)
    try require(!ImageAttachmentPasteboard.canPasteImage(clipboard))
    clipboard.clearContents()
    clipboard.setData(fixtureAvatarData(), forType: .tiff)
    try require(ImageAttachmentPasteboard.canPasteImage(clipboard))
    clipboard.clearContents()
    clipboard.writeObjects([URL(fileURLWithPath: "/tmp/noodle-menu-example.png") as NSURL,
                            URL(fileURLWithPath: "/tmp/noodle-menu-example.txt") as NSURL])
    try require(ImageAttachmentPasteboard.canPasteImage(clipboard))
    try require(ImageAttachmentPasteboard.imageFileURLs(clipboard).map(\.pathExtension) == ["png"])
    clipboard.clearContents()
    clipboard.writeObjects([URL(fileURLWithPath: "/tmp/noodle-menu-example.txt") as NSURL])
    try require(!ImageAttachmentPasteboard.canPasteImage(clipboard))
    let agent = AgentRecord(displayName: "Mara", publicDescription: "  Reviews\n ideas.  ", avatarImageData: fixtureAvatarData())
    let directProfile = AgentProfileSheet(agent: agent)
    try require(directProfile.reply == nil && directProfile.directMessage == nil)
    let groupProfile = AgentProfileSheet(agent: agent, canOpenDirectMessage: true, reply: {}, directMessage: {})
    try require(groupProfile.reply != nil && groupProfile.directMessage != nil)
    try require(ComposerNameCompletion.menuTitle(for: agent, showDescriptions: false) == "Mara")
    try require(ComposerNameCompletion.menuTitle(for: agent, showDescriptions: true) == "Mara  Reviews ideas.")
    try require(ComposerNameCompletion.menuTitle(for: AgentRecord(displayName: "Ruby"), showDescriptions: true) == "Ruby")
    let long = AgentRecord(displayName: "Long", publicDescription: String(repeating: "x", count: 200))
    try require(ComposerNameCompletion.menuTitle(for: long, showDescriptions: true) == "Long  " + String(repeating: "x", count: 72) + "…")
    let avatar = ComposerNameCompletion.menuAvatar(for: agent)!
    let bitmap = NSBitmapImageRep(cgImage: avatar.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    try require(bitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.1)
    try require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.alphaComponent > 0.9)
    try require(!avatar.isTemplate && avatar.size == NSSize(width: 16, height: 16))
    let generated = AgentRecord(displayName: "Generated", accentSeed: 0)
    let generatedImage = ComposerNameCompletion.menuAvatar(for: generated)!
    let generatedBitmap = NSBitmapImageRep(cgImage: generatedImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    try require(generatedBitmap.pixelsWide == 32 && generatedBitmap.pixelsHigh == 32)
    try require(generatedBitmap.colorAt(x: 0, y: 0)!.alphaComponent < 0.1)
    try require(generatedBitmap.colorAt(x: 8, y: 16)!.alphaComponent > 0.9)
    var customized = generated
    customized.avatarColorIndex = 2
    try require(pixelDifference(ComposerNameCompletion.menuAvatar(for: customized)!, generatedImage) > 0.01)
    customized = generated
    customized.avatarSymbolName = "heart.fill"
    try require(pixelDifference(ComposerNameCompletion.menuAvatar(for: customized)!, generatedImage) > 0.005)
    customized = generated
    customized.avatarImageData = Data([0, 1, 2])
    try require(pixelDifference(ComposerNameCompletion.menuAvatar(for: customized)!, generatedImage) < 0.002)
}

private struct FixtureView: View {
    @AppStorage(ComposerNameCompletion.descriptionsDefaultsKey) private var showDescriptions = true
    @StateObject private var completion = ComposerNameCompletion()
    @State private var draft = ""
    @State private var submissions = 0
    @State private var profile: AgentRecord?
    @State private var pendingReply: String?
    @State private var destination = "Group"
    @State private var directProfile = false
    @State private var attachmentMenu = false
    @State private var attachmentAction = "None"
    @FocusState private var focused: Bool
    private let agents = [
        AgentRecord(displayName: "Angy", publicDescription: "Designs friendly interfaces."),
        AgentRecord(displayName: "Mara", publicDescription: "Reviews ideas and asks useful questions.", avatarImageData: fixtureAvatarData()),
        AgentRecord(displayName: "Mary Jane"),
        AgentRecord(displayName: "Ruby"),
        AgentRecord(displayName: "Tony"),
        AgentRecord(displayName: "Zoe")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(destination) — submissions: \(submissions)").font(.headline)
            Button("Show Mara's profile") { directProfile = false; profile = agents[1] }
            Button("Show Mara's DM profile") { directProfile = true; profile = agents[1] }
            Toggle("Show descriptions in the @ name menu", isOn: $showDescriptions)
            Button("Attachments") { attachmentMenu = true }
                .background(ComposerAttachmentMenu(isPresented: $attachmentMenu,
                    attachFile: { attachmentAction = "File" },
                    choosePhoto: { attachmentAction = "Photo" },
                    pasteImage: { attachmentAction = "Paste" }))
            Text("Attachment action: \(attachmentAction)")
            Spacer()
            TextField("Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...6).focused($focused)
                .background(ChatComposerBridge(isActive: focused, draft: draft, agents: agents,
                                               preferredIDs: [agents[1].id], completion: completion))
                .onSubmit { submissions += 1 }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
        }
        .padding(24).frame(width: 540, height: 450)
        .sheet(item: $profile, onDismiss: {
            if let pendingReply { draft = pendingReply + ", " + draft; self.pendingReply = nil }
            DispatchQueue.main.async { focused = true }
        }) { agent in
            if directProfile {
                AgentProfileSheet(agent: agent).noodleSheetSizing()
            } else {
                AgentProfileSheet(agent: agent, canOpenDirectMessage: true, reply: {
                    pendingReply = agent.displayName
                    profile = nil
                }, directMessage: {
                    destination = "Direct: \(agent.displayName)"
                    profile = nil
                }).noodleSheetSizing()
            }
        }
        .onDisappear { completion.detach() }
    }
}

@main
struct ChatFeaturesTest: App {
    init() {
        if CommandLine.arguments.contains("--verify") {
            do {
                try verifyNativeMenuPresentation()
                print("Avatar/menu regression checks passed")
                exit(0)
            } catch {
                print(error)
                exit(1)
            }
        }
    }
    var body: some Scene {
        WindowGroup("Chat Feature Tests") { FixtureView().preferredColorScheme(.dark) }
    }
}
