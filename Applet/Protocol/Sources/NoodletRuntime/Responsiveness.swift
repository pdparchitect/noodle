import Foundation
import Observation
import Surface
import WebKit

/// What the app showing a page tells the person about it: whether it has drawn yet, and the
/// notice to show over it while it is starting or not responding.
@MainActor @Observable public final class NoodletActivity {
    public internal(set) var drawn = false
    public internal(set) var notice: SurfaceNotice?
    /// Told whenever the notice changes, for what shows it somewhere else, such as a live view.
    @ObservationIgnored public var noticeChanged: ((SurfaceNotice?) -> Void)?
}

/// When a page counts as starting or not responding.
struct NoodletResponsiveness {
    var startingAfter = Duration.seconds(1)
    var unansweredFor = Duration.seconds(2)
    /// When the page began loading.
    var began: ContinuousClock.Instant?
    var drawn = false
    /// When the page was asked the question it has not answered yet.
    var asked: ContinuousClock.Instant?

    func notice(at now: ContinuousClock.Instant) -> SurfaceNotice? {
        guard let began else { return nil }
        if !drawn { return now - began >= startingAfter ? .starting : nil }
        guard let asked, now - asked >= unansweredFor else { return nil }
        return .notResponding
    }
}

/// Hears that the page drew, from a script world of the app's own that the page cannot reach.
@MainActor final class NoodletDrawnHandler: NSObject, WKScriptMessageHandler {
    static let name = "noodleDrawn"
    /// Two frames after the document is parsed, so the first frame with the page's content is on screen.
    static let script = """
        (() => {
          const drawn = () => requestAnimationFrame(() => requestAnimationFrame(() =>
            webkit.messageHandlers.\(name).postMessage(0)));
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', drawn, { once: true });
          else drawn();
        })();
        """
    weak var page: NoodletPage?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        page?.drew()
    }
}

extension Duration {
    /// As the logs give it, such as "2.4 s".
    var spoken: String {
        let (seconds, attoseconds) = components
        return String(format: "%.1f s", Double(seconds) + Double(attoseconds) / 1e18)
    }
}
