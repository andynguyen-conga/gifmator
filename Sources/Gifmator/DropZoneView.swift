import AppKit

/// Dashed-border drop zone shown in the empty state. Accepts `.mov` / `.mp4` /
/// `.m4v` via drag-and-drop, and forwards clicks to an "Open Video…" handler.
final class DropZoneView: NSView {
    var onOpenRequested: (() -> Void)?
    var onFileDropped: ((URL) -> Void)?

    static let supportedExtensions: Set<String> = ["mov", "mp4", "m4v"]

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Drop a video here, or click to open")
    private let subtitleLabel = NSTextField(labelWithString: ".mp4   .mov   .m4v   (H.264 / HEVC / ProRes)")
    private let openButton = NSButton(title: "Open Video…", target: nil, action: nil)
    private let border = CAShapeLayer()

    private var isTargeted: Bool = false {
        didSet { updateBorderStyle() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        border.fillColor = NSColor.clear.cgColor
        border.lineWidth = 1
        border.lineDashPattern = [8, 6]
        border.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor
        layer?.addSublayer(border)

        if let symbol = NSImage(systemSymbolName: "arrow.down.doc",
                                 accessibilityDescription: "Drop video here") {
            iconView.image = symbol
            iconView.symbolConfiguration = .init(pointSize: 48, weight: .light)
        }
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(didTapOpen)

        let stack = NSStackView(views: [iconView, titleLabel, subtitleLabel, openButton])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
        ])

        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        let path = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        border.path = path
    }

    private func updateBorderStyle() {
        if isTargeted {
            border.strokeColor = NSColor.controlAccentColor.cgColor
            border.lineWidth = 2
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        } else {
            border.strokeColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5).cgColor
            border.lineWidth = 1
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        onOpenRequested?()
    }

    @objc private func didTapOpen() {
        onOpenRequested?()
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = draggedURL(from: sender),
              Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return []
        }
        isTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isTargeted = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = draggedURL(from: sender),
              Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isTargeted = false
        guard let url = draggedURL(from: sender),
              Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            return false
        }
        onFileDropped?(url)
        return true
    }

    private func draggedURL(from info: NSDraggingInfo) -> URL? {
        let pb = info.draggingPasteboard
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first
    }
}
