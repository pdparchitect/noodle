import AppKit
import AVFoundation
import CoreImage
import SwiftUI

/// The Mac's camera, live, handing each frame to `frame` on a background queue until it returns false.
public struct CameraView: NSViewRepresentable {
    let frame: @Sendable (CVPixelBuffer) -> Bool
    let failed: @MainActor (String) -> Void

    public init(frame: @escaping @Sendable (CVPixelBuffer) -> Bool, failed: @escaping @MainActor (String) -> Void) {
        self.frame = frame
        self.failed = failed
    }

    public func makeCoordinator() -> Coordinator { Coordinator(frame: frame, failed: failed) }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        context.coordinator.start(in: view)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.stop() }

    public final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let session = AVCaptureSession()
        private let frame: @Sendable (CVPixelBuffer) -> Bool
        private let failed: @MainActor (String) -> Void
        private let frames = DispatchQueue(label: "com.pdparchitect.noodle.camera")
        private var stopped = false

        init(frame: @escaping @Sendable (CVPixelBuffer) -> Bool, failed: @escaping @MainActor (String) -> Void) {
            self.frame = frame
            self.failed = failed
        }

        @MainActor func start(in view: NSView) {
            Task { @MainActor in
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    failed("Allow Noodle to use the camera in System Settings > Privacy & Security > Camera.")
                    return
                }
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                    failed("No camera is available.")
                    return
                }
                session.addInput(input)
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(output) else {
                    failed("The camera cannot be read.")
                    return
                }
                session.addOutput(output)
                output.setSampleBufferDelegate(self, queue: frames)
                let preview = AVCaptureVideoPreviewLayer(session: session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = view.bounds
                preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                view.layer?.addSublayer(preview)
                let session = session
                DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
            }
        }

        func stop() {
            let session = session
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        }

        public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard !stopped, let buffer = sampleBuffer.imageBuffer else { return }
            if !frame(buffer) {
                stopped = true
                stop()
            }
        }
    }
}

/// Takes one photo with the Mac's camera for a picture, square as it will show.
public struct CameraPhotoSheet: View {
    let taken: (CGImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var latest = LatestFrame()
    @State private var problem: String?

    public init(taken: @escaping (CGImage) -> Void) {
        self.taken = taken
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.foregroundStyle(.blue)
                Spacer(); Text("Camera").font(.headline); Spacer()
                Button("Take Photo") {
                    guard let image = latest.image() else { return }
                    taken(image)
                    dismiss()
                }
                .foregroundStyle(.blue)
                .disabled(problem != nil)
                .keyboardShortcut(.defaultAction)
            }.buttonStyle(.plain).padding(16)
            Divider()
            ZStack {
                let latest = latest
                CameraView { frame in
                    latest.keep(frame)
                    return true
                } failed: { problem = $0 }
                if let problem {
                    Text(problem).foregroundStyle(.white).multilineTextAlignment(.center).padding()
                }
            }
            .frame(width: 320, height: 320)
            .clipShape(Circle())
            .padding(20)
        }
    }

    /// The newest frame, kept from the camera's queue for the main one to take.
    final class LatestFrame: @unchecked Sendable {
        private let lock = NSLock()
        private var frame: CVPixelBuffer?
        private let context = CIContext()

        func keep(_ frame: CVPixelBuffer) { lock.withLock { self.frame = frame } }

        func image() -> CGImage? {
            guard let frame = lock.withLock({ self.frame }) else { return nil }
            // Mirrored, as the preview shows the person.
            let image = CIImage(cvPixelBuffer: frame).oriented(.upMirrored)
            return context.createCGImage(image, from: image.extent)
        }
    }
}
