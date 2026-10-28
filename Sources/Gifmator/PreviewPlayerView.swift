import AVFoundation
import AppKit
import Combine

/// A plain NSView that hosts an AVPlayerLayer. AVPlayerLayer doesn't track its
/// hosting view's bounds on its own; we resize it in `layout()` to prevent the
/// picture from drifting on window resize (same workaround the SwiftUI version
/// used inside its NSViewRepresentable).
final class PlayerContainerView: NSView {
    private let playerLayer = AVPlayerLayer()

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// Preview region: video surface on top, transport bar on bottom.
final class PreviewSectionView: NSView {
    let playerContainer = PlayerContainerView()
    let transportBar: TransportBarView

    private let model: PlayerModel
    private var cancellables = Set<AnyCancellable>()

    init(model: PlayerModel) {
        self.model = model
        self.transportBar = TransportBarView(model: model)
        super.init(frame: .zero)

        wantsLayer = true

        playerContainer.translatesAutoresizingMaskIntoConstraints = false
        transportBar.translatesAutoresizingMaskIntoConstraints = false

        addSubview(playerContainer)
        addSubview(transportBar)

        NSLayoutConstraint.activate([
            playerContainer.topAnchor.constraint(equalTo: topAnchor),
            playerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            transportBar.topAnchor.constraint(equalTo: playerContainer.bottomAnchor, constant: 8),
            transportBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            transportBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            transportBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            transportBar.heightAnchor.constraint(equalToConstant: 28),
        ])

        playerContainer.player = model.player
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}

/// Play/pause, loop toggle, and `playhead / selected` time readout.
final class TransportBarView: NSView {
    private let model: PlayerModel
    private let playPauseButton = NSButton()
    private let loopButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00.000 / 0:00.000")

    private var cancellables = Set<AnyCancellable>()

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)

        wantsLayer = true

        playPauseButton.bezelStyle = .texturedRounded
        playPauseButton.setButtonType(.momentaryPushIn)
        playPauseButton.title = "Play"
        playPauseButton.target = self
        playPauseButton.action = #selector(didTapPlayPause)
        playPauseButton.toolTip = "Play / Pause (Space)"

        loopButton.setButtonType(.switch)
        loopButton.title = "Loop"
        loopButton.target = self
        loopButton.action = #selector(didToggleLoop)
        loopButton.state = model.loopEnabled.value ? .on : .off
        loopButton.toolTip = "Loop the trimmed range (on by default)"

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .left

        let stack = NSStackView(views: [playPauseButton, loopButton, timeLabel])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        bindToModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func bindToModel() {
        model.isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                self?.playPauseButton.title = playing ? "Pause" : "Play"
            }
            .store(in: &cancellables)

        model.loopEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                self?.loopButton.state = on ? .on : .off
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(model.currentTime, model.inTime, model.outTime)
            .throttle(for: .milliseconds(50), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] current, inT, outT in
                guard let self else { return }
                let rel = CMTimeSubtract(current, inT)
                let shown = CMTimeCompare(rel, .zero) >= 0 ? rel : .zero
                let selectedRaw = CMTimeSubtract(outT, inT)
                let selected = CMTimeCompare(selectedRaw, .zero) > 0 ? selectedRaw : .zero
                self.timeLabel.stringValue = "\(formatTime(shown)) / \(formatTime(selected))"
            }
            .store(in: &cancellables)
    }

    @objc private func didTapPlayPause() {
        model.togglePlayPause()
    }

    @objc private func didToggleLoop() {
        model.setLoopEnabled(loopButton.state == .on)
    }
}
