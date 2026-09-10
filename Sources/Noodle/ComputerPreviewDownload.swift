import AppKit

/// Shared missing-provider state for live terminal and display attachments.
/// Opening the release page is always an explicit user action.
@MainActor final class ComputerPreviewDownload: NSView {
    private let openDownload: () async throws -> Void
    private var task: Task<Void, Never>?
    private let message = NSTextField(wrappingLabelWithString: "Install Noodle Computer, then reopen this preview to connect.")
    private lazy var download = NSButton(title: "Get Noodle Computer…", target: self, action: #selector(getComputer))

    init(openDownload: @escaping () async throws -> Void) {
        self.openDownload = openDownload
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "Noodle Computer is not installed")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        let requirements = NSTextField(labelWithString: "Apple silicon · macOS 26 or later")
        requirements.font = .systemFont(ofSize: 11)
        requirements.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, message, download, requirements])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalTo: widthAnchor, constant: -48),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(in surface: NSView) {
        surface.addSubview(self)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: surface.leadingAnchor), trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            topAnchor.constraint(equalTo: surface.topAnchor), bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        isHidden = true
    }
    func showIfNeeded(_ needed: Bool) { isHidden = !needed }
    func stop() { task?.cancel(); task = nil }

    @objc private func getComputer() {
        guard task == nil else { return }
        download.isEnabled = false
        download.title = "Checking…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { download.isEnabled = true; download.title = "Get Noodle Computer…"; task = nil }
            do {
                try await openDownload()
                guard !Task.isCancelled else { return }
                message.stringValue = "Install Noodle Computer from the download page, then reopen this preview to connect."
            } catch {
                guard !Task.isCancelled else { return }
                message.stringValue = error.localizedDescription
            }
        }
    }
}
