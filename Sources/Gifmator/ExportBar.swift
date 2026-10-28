import AppKit
import Combine
import UniformTypeIdentifiers

/// Export preset table. Named presets have fixed (width, fps); `custom` reads
/// width/fps from `UserDefaults` so the user's last Custom tuning survives
/// relaunches.
enum ExportPreset: String, CaseIterable {
    case standard
    case high
    case max
    case ultra
    case custom

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .high:     return "High"
        case .max:      return "Max"
        case .ultra:    return "Ultra"
        case .custom:   return "Custom"
        }
    }

    /// Returns nil for `.custom` — resolve from UserDefaults.
    var dimensions: (width: Int, fps: Int)? {
        switch self {
        case .standard: return (960, 15)
        case .high:     return (1280, 20)
        case .max:      return (1920, 24)
        case .ultra:    return (2560, 30)
        case .custom:   return nil
        }
    }

    /// What the popup shows for this preset — includes the (w × fps) for the
    /// named presets so the user can read the contract without expanding the
    /// menu twice.
    var menuTitle: String {
        if let d = dimensions {
            return "\(displayName) · \(d.width) px · \(d.fps) fps"
        }
        return displayName
    }
}

private enum ExportDefaultsKey {
    static let preset = "GifmatorExportPreset"
    static let customWidth = "GifmatorCustomWidth"
    static let customFPS = "GifmatorCustomFPS"
}

private enum CustomRange {
    static let widthMin = 320
    static let widthMax = 3840
    static let widthStep = 160
    static let widthDefault = 1600

    static let fpsMin = 10
    static let fpsMax = 30
    static let fpsStep = 1
    static let fpsDefault = 20
}

/// Preset popup + Custom width/fps controls + live size estimate on the left;
/// `NSProgressIndicator` + Cancel + Reveal in Finder + Export button on the
/// right. All AppKit — no SwiftUI.
final class ExportBar: NSView {
    private let model: PlayerModel
    private let engine: ExportEngine

    // Preset + custom controls (Phase B).
    private let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customWidthLabel = NSTextField(labelWithString: "Width")
    private let customWidthField = NSTextField(labelWithString: "0")
    private let customWidthStepper = NSStepper()
    private let customFPSLabel = NSTextField(labelWithString: "FPS")
    private let customFPSField = NSTextField(labelWithString: "0")
    private let customFPSStepper = NSStepper()
    private let estimateLabel = NSTextField(labelWithString: "≈ est  —")

    // Status / progress / buttons.
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let progressPercent = NSTextField(labelWithString: "0%")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export GIF…", target: nil, action: nil)

    private var cancellables = Set<AnyCancellable>()
    private var lastSavedURL: URL?
    private var toastTimer: Timer?

    // Persisted settings.
    private var currentPreset: ExportPreset = .standard
    private var customWidth: Int = CustomRange.widthDefault
    private var customFPS: Int = CustomRange.fpsDefault

    init(model: PlayerModel, engine: ExportEngine) {
        self.model = model
        self.engine = engine
        super.init(frame: .zero)
        wantsLayer = true

        loadPersistedSettings()
        configurePresetPopup()
        configureCustomControls()
        configureEstimateLabel()
        configureRightSideControls()
        layoutViews()
        bind()
        refreshCustomControlVisibility()
        refreshEstimate()
        refreshExportEnabled()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    deinit {
        toastTimer?.invalidate()
    }

    // MARK: Configuration

    private func loadPersistedSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: ExportDefaultsKey.preset),
           let preset = ExportPreset(rawValue: raw) {
            currentPreset = preset
        }
        if let w = defaults.object(forKey: ExportDefaultsKey.customWidth) as? Int {
            customWidth = clampWidth(w)
        }
        if let f = defaults.object(forKey: ExportDefaultsKey.customFPS) as? Int {
            customFPS = clampFPS(f)
        }
    }

    private func configurePresetPopup() {
        presetPopup.removeAllItems()
        for preset in ExportPreset.allCases {
            presetPopup.addItem(withTitle: preset.menuTitle)
        }
        presetPopup.target = self
        presetPopup.action = #selector(didChangePreset)
        if let idx = ExportPreset.allCases.firstIndex(of: currentPreset) {
            presetPopup.selectItem(at: idx)
        }
    }

    private func configureCustomControls() {
        for label in [customWidthLabel, customFPSLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }

        for field in [customWidthField, customFPSField] {
            field.isBordered = true
            field.isEditable = false
            field.isSelectable = true
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.alignment = .right
            field.drawsBackground = true
            field.backgroundColor = .textBackgroundColor
            field.setContentHuggingPriority(.required, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        customWidthField.stringValue = "\(customWidth)"
        customFPSField.stringValue = "\(customFPS)"

        customWidthStepper.minValue = Double(CustomRange.widthMin)
        customWidthStepper.maxValue = Double(CustomRange.widthMax)
        customWidthStepper.increment = Double(CustomRange.widthStep)
        customWidthStepper.integerValue = customWidth
        customWidthStepper.valueWraps = false
        customWidthStepper.target = self
        customWidthStepper.action = #selector(didChangeCustomWidth)

        customFPSStepper.minValue = Double(CustomRange.fpsMin)
        customFPSStepper.maxValue = Double(CustomRange.fpsMax)
        customFPSStepper.increment = Double(CustomRange.fpsStep)
        customFPSStepper.integerValue = customFPS
        customFPSStepper.valueWraps = false
        customFPSStepper.target = self
        customFPSStepper.action = #selector(didChangeCustomFPS)
    }

    private func configureEstimateLabel() {
        estimateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        estimateLabel.textColor = .secondaryLabelColor
        estimateLabel.lineBreakMode = .byTruncatingTail
        estimateLabel.maximumNumberOfLines = 1
        estimateLabel.toolTip = "Rough estimate using 0.15 bytes/pixel-frame — real GIF size varies with content."
    }

    private func configureRightSideControls() {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        progressPercent.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressPercent.textColor = .secondaryLabelColor
        progressPercent.isHidden = true

        cancelButton.bezelStyle = .texturedRounded
        cancelButton.target = self
        cancelButton.action = #selector(didTapCancel)
        cancelButton.isHidden = true

        revealButton.bezelStyle = .texturedRounded
        revealButton.target = self
        revealButton.action = #selector(didTapReveal)
        revealButton.isHidden = true

        exportButton.bezelStyle = .rounded
        exportButton.keyEquivalent = "\r"
        exportButton.target = self
        exportButton.action = #selector(didTapExport)
        exportButton.isEnabled = false
        exportButton.toolTip = "Export the trimmed range as a GIF"
    }

    private func layoutViews() {
        let widthGroup = NSStackView(views: [customWidthLabel, customWidthField, customWidthStepper])
        widthGroup.orientation = .horizontal
        widthGroup.spacing = 4
        widthGroup.alignment = .centerY

        let fpsGroup = NSStackView(views: [customFPSLabel, customFPSField, customFPSStepper])
        fpsGroup.orientation = .horizontal
        fpsGroup.spacing = 4
        fpsGroup.alignment = .centerY

        let presetRow = NSStackView(views: [presetPopup, widthGroup, fpsGroup, estimateLabel])
        presetRow.orientation = .horizontal
        presetRow.spacing = 12
        presetRow.alignment = .centerY

        let progressStack = NSStackView(views: [progressBar, progressPercent, cancelButton])
        progressStack.orientation = .horizontal
        progressStack.spacing = 8
        progressStack.alignment = .centerY

        let leftStack = NSStackView(views: [presetRow, statusLabel, progressStack])
        leftStack.orientation = .horizontal
        leftStack.spacing = 14
        leftStack.alignment = .centerY

        let outer = NSStackView(views: [leftStack, NSView(), revealButton, exportButton])
        outer.orientation = .horizontal
        outer.alignment = .centerY
        outer.distribution = .fill
        outer.spacing = 10
        outer.translatesAutoresizingMaskIntoConstraints = false

        leftStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        revealButton.setContentHuggingPriority(.required, for: .horizontal)
        exportButton.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressBar.widthAnchor.constraint(equalToConstant: 180),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
    }

    private func bind() {
        // Export-enable + size-estimate inputs. loadState changes affect both the
        // enabled state and the aspect ratio used in the estimate; trim changes
        // only affect the estimate (via selectedDuration).
        model.loadState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshExportEnabled()
                self?.refreshEstimate()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(model.inTime, model.outTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshEstimate() }
            .store(in: &cancellables)

        engine.isExporting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] exporting in
                guard let self else { return }
                self.progressBar.isHidden = !exporting
                self.progressPercent.isHidden = !exporting
                self.cancelButton.isHidden = !exporting
                if exporting {
                    self.statusLabel.stringValue = ""
                    self.revealButton.isHidden = true
                    self.toastTimer?.invalidate()
                }
                self.refreshExportEnabled()
            }
            .store(in: &cancellables)

        engine.progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                self.progressBar.doubleValue = value
                self.progressPercent.stringValue = "\(Int((value * 100).rounded()))%"
            }
            .store(in: &cancellables)
    }

    // MARK: Preset / custom actions

    @objc private func didChangePreset() {
        let idx = presetPopup.indexOfSelectedItem
        guard idx >= 0 && idx < ExportPreset.allCases.count else { return }
        currentPreset = ExportPreset.allCases[idx]
        UserDefaults.standard.set(currentPreset.rawValue, forKey: ExportDefaultsKey.preset)
        refreshCustomControlVisibility()
        refreshEstimate()
    }

    @objc private func didChangeCustomWidth() {
        customWidth = clampWidth(customWidthStepper.integerValue)
        customWidthField.stringValue = "\(customWidth)"
        UserDefaults.standard.set(customWidth, forKey: ExportDefaultsKey.customWidth)
        refreshEstimate()
    }

    @objc private func didChangeCustomFPS() {
        customFPS = clampFPS(customFPSStepper.integerValue)
        customFPSField.stringValue = "\(customFPS)"
        UserDefaults.standard.set(customFPS, forKey: ExportDefaultsKey.customFPS)
        refreshEstimate()
    }

    private func refreshCustomControlVisibility() {
        let isCustom = (currentPreset == .custom)
        for v in [customWidthLabel, customWidthField, customWidthStepper,
                  customFPSLabel, customFPSField, customFPSStepper] {
            v.isHidden = !isCustom
        }
    }

    // MARK: Estimate

    private func refreshEstimate() {
        let dims = resolvedDimensions()
        let aspectHeight = Double(dims.width) * aspectRatioHeightOverWidth()
        let heightEven = (aspectHeight / 2).rounded() * 2
        let duration = max(0.05, model.selectedDuration.seconds)
        // Plan heuristic: ~0.15 bytes per pixel-frame for a palettized GIF.
        let bytes = Double(dims.width) * heightEven * Double(dims.fps) * duration * 0.15
        let mb = bytes / 1_048_576.0

        let sizeText: String
        if mb >= 100 {
            sizeText = String(format: "%.0f MB", mb)
        } else if mb >= 10 {
            sizeText = String(format: "%.0f MB", mb)
        } else {
            sizeText = String(format: "%.1f MB", mb)
        }

        if mb > 200 {
            estimateLabel.textColor = .systemRed
            estimateLabel.stringValue = "⚠︎  ≈ est  \(sizeText)"
        } else if mb > 50 {
            estimateLabel.textColor = .systemOrange
            estimateLabel.stringValue = "⚠︎  ≈ est  \(sizeText)"
        } else {
            estimateLabel.textColor = .secondaryLabelColor
            estimateLabel.stringValue = "≈ est  \(sizeText)"
        }
    }

    private func aspectRatioHeightOverWidth() -> Double {
        if case let .loaded(_, _, size, _, _) = model.loadState.value,
           size.width > 0, size.height > 0 {
            return Double(size.height) / Double(size.width)
        }
        // No video loaded yet — assume 16:9 for the estimate (matches most
        // screen recordings the user is likely to drop in).
        return 9.0 / 16.0
    }

    private func resolvedDimensions() -> (width: Int, fps: Int) {
        if let d = currentPreset.dimensions { return d }
        return (customWidth, customFPS)
    }

    // MARK: Clamps

    private func clampWidth(_ v: Int) -> Int {
        min(max(v, CustomRange.widthMin), CustomRange.widthMax)
    }

    private func clampFPS(_ v: Int) -> Int {
        min(max(v, CustomRange.fpsMin), CustomRange.fpsMax)
    }

    private func refreshExportEnabled() {
        exportButton.isEnabled = model.isLoaded && !engine.isExporting.value
    }

    // MARK: Export action + alerts

    @objc private func didTapExport() {
        Task { @MainActor in await runExport() }
    }

    @objc private func didTapCancel() {
        engine.cancel()
    }

    @objc private func didTapReveal() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    private func runExport() async {
        guard let sourceURL = model.videoURL else { return }

        guard let ffmpegPath = FFmpegLocator().locate() else {
            presentFFmpegMissingAlert()
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.gif]
        panel.nameFieldStringValue = defaultOutputName(for: sourceURL)
        panel.canCreateDirectories = true
        panel.title = "Export GIF"
        panel.message = "Choose a destination for the exported GIF."
        panel.isExtensionHidden = false

        let response = await panel.beginAsync()
        guard response == .OK, let destination = panel.url else { return }

        let dims = resolvedDimensions()
        let options = ExportEngine.Options(
            inputURL: sourceURL,
            outputURL: destination,
            start: model.inTime.value.seconds,
            end: model.outTime.value.seconds,
            width: dims.width,
            fps: dims.fps,
            ffmpegPath: ffmpegPath
        )

        do {
            try await engine.export(options: options)
            lastSavedURL = destination
            showSavedToast(url: destination)
        } catch is CancellationError {
            // User-initiated cancel; stay quiet.
        } catch let err as ExportEngine.ExportError {
            presentFailureAlert(message: err.userMessage)
        } catch {
            presentFailureAlert(message: error.localizedDescription)
        }
    }

    private func showSavedToast(url: URL) {
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = "✓  GIF saved — \(url.lastPathComponent)"
        revealButton.isHidden = false
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: 7, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.statusLabel.stringValue = ""
            self.statusLabel.textColor = .secondaryLabelColor
            self.revealButton.isHidden = true
        }
    }

    private func presentFFmpegMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "ffmpeg not found"
        alert.informativeText = """
        Gifmator could not find `ffmpeg` on your PATH. Install it with Homebrew and try again:

            brew install ffmpeg

        Checked: /opt/homebrew/bin/ffmpeg, /usr/local/bin/ffmpeg, /usr/bin/ffmpeg, /opt/local/bin/ffmpeg.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Copy install command")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
        }
    }

    private func presentFailureAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Export failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func defaultOutputName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        return "\(base).gif"
    }
}

extension NSSavePanel {
    func beginAsync() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            self.begin { response in
                continuation.resume(returning: response)
            }
        }
    }
}
