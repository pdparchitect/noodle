import AppKit
import Containerization
import ComputerCore
import Foundation
import SwiftTerm
import SwiftUI

/// Only transports bytes to a guest PTY. Never launches a shell on the Mac.
final class GuestTerminalIO: ReaderStream, Writer, @unchecked Sendable {
    private let input = AsyncStream<Data>.makeStream()
    private let output = AsyncStream<Data>.makeStream()
    func stream() -> AsyncStream<Data> { input.stream }
    var received: AsyncStream<Data> { output.stream }
    func send(_ data: Data) { input.continuation.yield(data) }
    func write(_ data: Data) throws { output.continuation.yield(data) }
    func close() throws { output.continuation.finish() }
    func finish() { input.continuation.finish(); output.continuation.finish() }
}

@MainActor final class GuestTerminal: NSObject, ObservableObject, @preconcurrency TerminalViewDelegate {
    private(set) var io = GuestTerminalIO()
    let view = ComputerNativeTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    var resize: ((Int, Int) -> Void)?
    var retryConnection: (() -> Void)?
    private var outputTask: Task<Void, Never>?

    override init() {
        super.init()
        view.terminalDelegate = self
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.setAccessibilityLabel("Computer terminal")
        receiveOutput()
    }
    private func receiveOutput() {
        let stream = io.received
        outputTask = Task { [weak self] in
            for await data in stream {
                guard !Task.isCancelled else { break }
                self?.view.feed(byteArray: Array(data)[...])
            }
        }
    }
    func reconnect() {
        retryConnection = nil
        outputTask?.cancel()
        io.finish()
        io = GuestTerminalIO()
        view.feed(text: "\u{1b}[?1049l\u{1b}[0m\u{1b}[?25h\r\n[Shell exited. Opening a new shell…]\r\n")
        receiveOutput()
    }
    deinit { outputTask?.cancel(); io.finish() }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let retryConnection {
            if data.contains(13) || data.contains(10) { retryConnection() }
            return
        }
        io.send(Data(data))
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { resize?(newCols, newRows) }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    // Guest escape sequences cannot open host files/apps or read/write its clipboard.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
}

final class ComputerNativeTerminalView: TerminalView {
    override func viewWillDraw() {
        super.viewWillDraw()
        // SwiftTerm's standalone NSScroller otherwise paints a full-height
        // disabled thumb. Preserve its reserved width to avoid reflow jumps.
        for scroller in subviews.compactMap({ $0 as? NSScroller }) {
            let opacity: CGFloat = canScroll ? 1 : 0
            if scroller.alphaValue != opacity { scroller.alphaValue = opacity }
        }
    }
}

struct ComputerTerminalView: NSViewRepresentable {
    let terminal: GuestTerminal
    var appearance = ComputerAppearance()
    func makeNSView(context: Context) -> ComputerTerminalSurface {
        let surface = ComputerTerminalSurface(terminal: terminal.view)
        apply(to: surface)
        return surface
    }
    func updateNSView(_ surface: ComputerTerminalSurface, context: Context) { apply(to: surface) }
    private func apply(to surface: ComputerTerminalSurface) {
        let view = surface.terminal
        view.nativeForegroundColor = computerColour(appearance.terminalForeground)
        let background = computerColour(appearance.terminalBackground)
        // One layer paints the entire panel, including its inset. SwiftTerm
        // paints only text, cursor and explicit ANSI backgrounds over it.
        view.nativeBackgroundColor = background.withAlphaComponent(0)
        view.backgroundOpacity = 0
        surface.layer?.backgroundColor = background.withAlphaComponent(appearance.terminalOpacity).cgColor
    }
}

/// One uniform background avoids stale/double-painted strips during resizing.
final class ComputerTerminalSurface: NSView {
    static let inset: CGFloat = 12
    let terminal: TerminalView

    init(terminal: TerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { false }
}
