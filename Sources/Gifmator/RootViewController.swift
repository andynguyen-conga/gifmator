import AVFoundation
import AppKit
import Combine
import UniformTypeIdentifiers

/// Root view controller. Drives the empty-state <-> working-layout swap, hosts
/// the preview section, and owns the single `PlayerModel` instance.
final class RootViewController: NSViewController {
    let model = PlayerModel()
    let exportEngine = ExportEngine()

    private let headerView = HeaderView()
    private let contentContainer = NSView()
    private var dropZone: DropZoneView?
    private var workingLayout: NSStackView?
    private var previewSection: PreviewSectionView?
    private var cancellables = Set<AnyCancellable>()

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1120, height: 760))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.onOpenRequested = { [weak self] in self?.openVideoPanel() }

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(headerView)
        view.addSubview(divider)
        view.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            divider.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            contentContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        headerView.bind(model: model)

        model.loadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.applyLoadState(state) }
            .store(in: &cancellables)

        // Prime initial layout.
        applyLoadState(model.loadState.value)
    }

    func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType.movie,
            UTType.quickTimeMovie,
            UTType.mpeg4Movie
        ]
        panel.title = "Open Video"
        panel.message = "Select a .mp4, .mov, or .m4v file."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.loadVideo(url: url)
        }
    }

    /// Returns `true` if the key event was consumed.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard model.isLoaded, let chars = event.charactersIgnoringModifiers else {
            return false
        }
        switch chars {
        case " ":
            model.togglePlayPause()
            return true
        case "i", "I":
            model.setInToPlayhead()
            return true
        case "o":
            // Cmd+O is Open; let it pass through to the menu.
            if event.modifierFlags.contains(.command) { return false }
            model.setOutToPlayhead()
            return true
        case "O":
            model.setOutToPlayhead()
            return true
        case "[":
            model.nudgeIn(frames: -1)
            return true
        case "{":
            // Shift+[ pushes the in-point one frame later.
            model.nudgeIn(frames: 1)
            return true
        case "]":
            model.nudgeOut(frames: 1)
            return true
        case "}":
            // Shift+] pulls the out-point one frame earlier.
            model.nudgeOut(frames: -1)
            return true
        default:
            return false
        }
    }

    // MARK: Layout swap

    private func applyLoadState(_ state: PlayerModel.LoadState) {
        let loaded: Bool
        switch state {
        case .loaded: loaded = true
        default: loaded = false
        }
        if loaded {
            showWorkingLayout()
        } else {
            showEmptyState()
        }
    }

    private func showEmptyState() {
        workingLayout?.removeFromSuperview()
        workingLayout = nil
        previewSection = nil

        if dropZone != nil { return }

        let zone = DropZoneView()
        zone.translatesAutoresizingMaskIntoConstraints = false
        zone.onOpenRequested = { [weak self] in self?.openVideoPanel() }
        zone.onFileDropped = { [weak self] url in self?.model.loadVideo(url: url) }

        contentContainer.addSubview(zone)
        NSLayoutConstraint.activate([
            zone.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 32),
            zone.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -32),
            zone.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 32),
            zone.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -32),
        ])
        dropZone = zone
    }

    private func showWorkingLayout() {
        dropZone?.removeFromSuperview()
        dropZone = nil

        if workingLayout != nil { return }

        let preview = PreviewSectionView(model: model)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        self.previewSection = preview

        let trimmerSection = TimelineSectionView(model: model)
        trimmerSection.translatesAutoresizingMaskIntoConstraints = false
        trimmerSection.setContentHuggingPriority(.required, for: .vertical)
        trimmerSection.setContentCompressionResistancePriority(.required, for: .vertical)

        let exportBar = ExportBar(model: model, engine: exportEngine)
        exportBar.translatesAutoresizingMaskIntoConstraints = false
        exportBar.setContentHuggingPriority(.required, for: .vertical)
        exportBar.setContentCompressionResistancePriority(.required, for: .vertical)

        let topDivider = NSBox(); topDivider.boxType = .separator
        let bottomDivider = NSBox(); bottomDivider.boxType = .separator

        let stack = NSStackView(views: [
            preview,
            topDivider,
            trimmerSection,
            bottomDivider,
            exportBar
        ])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor, constant: -16),

            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 320),

            topDivider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomDivider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            trimmerSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            exportBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        workingLayout = stack
    }
}

/// Window header: app title, source-video metadata badge, Open button.
final class HeaderView: NSView {
    var onOpenRequested: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Gifmator")
    private let detailLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open Video…", target: nil, action: nil)

    private var cancellables = Set<AnyCancellable>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        detailLabel.cell?.truncatesLastVisibleLine = true

        openButton.bezelStyle = .texturedRounded
        openButton.target = self
        openButton.action = #selector(didTapOpen)
        openButton.setContentHuggingPriority(.required, for: .horizontal)

        let leftStack = NSStackView(views: [titleLabel, detailLabel])
        leftStack.orientation = .horizontal
        leftStack.spacing = 10
        leftStack.alignment = .centerY
        leftStack.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [leftStack, openButton])
        outer.orientation = .horizontal
        outer.alignment = .centerY
        outer.distribution = .equalSpacing
        outer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func bind(model: PlayerModel) {
        model.loadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.update(state: state) }
            .store(in: &cancellables)
    }

    private func update(state: PlayerModel.LoadState) {
        detailLabel.textColor = .secondaryLabelColor
        switch state {
        case .empty:
            detailLabel.stringValue = ""
            openButton.title = "Open Video…"
        case .loading:
            detailLabel.stringValue = "— Loading…"
            openButton.title = "Open another video…"
        case let .loaded(_, name, size, duration, fps):
            detailLabel.stringValue = "— \(name)  •  \(Int(size.width))×\(Int(size.height))  •  \(Int(fps)) fps  •  \(formatTime(duration))"
            openButton.title = "Open another video…"
        case let .failed(message):
            detailLabel.stringValue = "— \(message)"
            detailLabel.textColor = .systemRed
            openButton.title = "Open Video…"
        }
    }

    @objc private func didTapOpen() {
        onOpenRequested?()
    }
}
