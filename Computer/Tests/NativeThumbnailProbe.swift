import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

@main struct NativeThumbnailProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: NativeThumbnailProbe reference.noodlecomputer output.png\n", stderr); exit(64)
        }
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        print("Resolved type: \(UTType(filenameExtension: file.pathExtension)?.identifier ?? "unknown")")
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 800, height: 520), scale: 1, representationTypes: .thumbnail)
        Task { try? await Task.sleep(for: .seconds(20)); fputs("Native thumbnail timed out\n", stderr); exit(2) }
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let bitmap = NSBitmapImageRep(cgImage: representation.cgImage)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(3) }
            try data.write(to: output)
            print("Rendered \(bitmap.pixelsWide)x\(bitmap.pixelsHigh), type \(representation.type.rawValue)")
            exit(0)
        } catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
