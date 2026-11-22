import NoodleWallpaperCore
import QuickLook
import SwiftUI
#if os(macOS)
import Quartz

/// Quick Look's preview of a Metal shader file, on the Mac: the shader playing, or why it can't.
@MainActor @objc(ShaderPreviewController)
final class ShaderPreviewController: NSViewController, @preconcurrency QLPreviewingController {
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500)) }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        preferredContentSize = NSSize(width: 800, height: 500)
        view.subviews.forEach { $0.removeFromSuperview() }
        let host = NSHostingView(rootView: ShaderPreview(url: url))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
        handler(nil)
    }
}
#else
import UIKit

/// Quick Look's preview of a Metal shader file, on iPhone and iPad: the shader playing, or why it can't.
@MainActor @objc(ShaderPreviewController)
final class ShaderPreviewController: UIViewController, @preconcurrency QLPreviewingController {
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        children.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        let host = UIHostingController(rootView: ShaderPreview(url: url).ignoresSafeArea())
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        handler(nil)
    }
}
#endif
