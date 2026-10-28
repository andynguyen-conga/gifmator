import AVFoundation
import Combine
import Foundation

/// Observable AVPlayer wrapper. Uses Combine subjects (no `@Published`, no
/// `ObservableObject`) so this file compiles on the Command Line Tools without
/// the `SwiftUIMacros` plugin that only ships with Xcode.app.
final class PlayerModel: NSObject {
    enum LoadState {
        case empty
        case loading
        case loaded(url: URL,
                    name: String,
                    size: CGSize,
                    duration: CMTime,
                    fps: Double)
        case failed(message: String)
    }

    // Observable state (plain Combine). Views subscribe via `receive(on:)`.
    let currentTime = CurrentValueSubject<CMTime, Never>(.zero)
    let isPlaying = CurrentValueSubject<Bool, Never>(false)
    let inTime = CurrentValueSubject<CMTime, Never>(.zero)
    let outTime = CurrentValueSubject<CMTime, Never>(.zero)
    let loopEnabled = CurrentValueSubject<Bool, Never>(true)
    let loadState = CurrentValueSubject<LoadState, Never>(.empty)

    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        installTimeObserver()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleReachedEnd()
        }

        // Mirror outTime -> player.currentItem.forwardPlaybackEndTime, throttled
        // so live handle dragging doesn't thrash the player; final value lands
        // on drop. Preserves the core preview-matches-export behaviour.
        outTime
            .removeDuplicates(by: { CMTimeCompare($0, $1) == 0 })
            .throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] out in
                self?.player.currentItem?.forwardPlaybackEndTime = out
            }
            .store(in: &cancellables)

        // If the in-handle crosses the playhead, snap preview to the new in
        // point (zero tolerance) so the picture matches what the export will
        // produce.
        inTime
            .removeDuplicates(by: { CMTimeCompare($0, $1) == 0 })
            .throttle(for: .milliseconds(33), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] inPoint in
                guard let self else { return }
                if CMTimeCompare(self.currentTime.value, inPoint) < 0 {
                    self.player.seek(to: inPoint,
                                     toleranceBefore: .zero,
                                     toleranceAfter: .zero)
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    // MARK: Derived state

    var isLoaded: Bool {
        if case .loaded = loadState.value { return true }
        return false
    }

    var sourceDuration: CMTime {
        if case let .loaded(_, _, _, duration, _) = loadState.value { return duration }
        return .zero
    }

    var sourceFPS: Double {
        if case let .loaded(_, _, _, _, fps) = loadState.value { return fps }
        return 30
    }

    var sourceSize: CGSize {
        if case let .loaded(_, _, size, _, _) = loadState.value { return size }
        return .zero
    }

    var videoURL: URL? {
        if case let .loaded(url, _, _, _, _) = loadState.value { return url }
        return nil
    }

    var selectedDuration: CMTime {
        let d = CMTimeSubtract(outTime.value, inTime.value)
        return CMTimeCompare(d, .zero) > 0 ? d : .zero
    }

    var frameDuration: CMTime {
        let fps = max(sourceFPS, 1)
        return CMTime(seconds: 1.0 / fps, preferredTimescale: 600)
    }

    // MARK: Loading

    func loadVideo(url: URL) {
        loadState.send(.loading)

        Task { @MainActor in
            let asset = AVURLAsset(url: url)
            do {
                let (duration, tracks) = try await asset.load(.duration, .tracks)
                guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
                    self.loadState.send(.failed(message: "No video track found in \(url.lastPathComponent)."))
                    return
                }

                let (naturalSize, nominalFR, preferredTransform) = try await videoTrack.load(
                    .naturalSize, .nominalFrameRate, .preferredTransform
                )
                let transformed = naturalSize.applying(preferredTransform)
                let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                let fps = nominalFR > 0 ? Double(nominalFR) : 30

                let item = AVPlayerItem(asset: asset)
                item.forwardPlaybackEndTime = duration
                self.player.replaceCurrentItem(with: item)

                self.inTime.send(.zero)
                self.outTime.send(duration)
                self.currentTime.send(.zero)
                // Inside @MainActor Task, overload resolution picks the async
                // AVPlayer.seek; mark await explicitly.
                await self.player.seek(to: .zero,
                                       toleranceBefore: .zero,
                                       toleranceAfter: .zero)

                self.loadState.send(.loaded(url: url,
                                            name: url.lastPathComponent,
                                            size: size,
                                            duration: duration,
                                            fps: fps))
                self.play()
            } catch {
                self.loadState.send(.failed(message: "Could not load video: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: Transport

    func togglePlayPause() {
        if isPlaying.value { pause() } else { play() }
    }

    func play() {
        guard isLoaded else { return }
        if CMTimeCompare(currentTime.value, outTime.value) >= 0
            || CMTimeCompare(currentTime.value, inTime.value) < 0 {
            player.seek(to: inTime.value,
                        toleranceBefore: .zero,
                        toleranceAfter: .zero)
        }
        player.play()
        isPlaying.send(true)
    }

    func pause() {
        player.pause()
        isPlaying.send(false)
    }

    func toggleLoop() {
        loopEnabled.send(!loopEnabled.value)
    }

    func setLoopEnabled(_ enabled: Bool) {
        loopEnabled.send(enabled)
    }

    func seek(to time: CMTime, precise: Bool) {
        guard isLoaded else { return }
        let clamped = clamp(time: time, min: .zero, max: sourceDuration)
        if precise {
            player.seek(to: clamped, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            player.seek(to: clamped)
        }
    }

    // MARK: Trim (used by Phase 2 trimmer)

    func setInToPlayhead() {
        guard isLoaded else { return }
        let maxIn = CMTimeSubtract(outTime.value, frameDuration)
        inTime.send(clamp(time: currentTime.value, min: .zero, max: maxIn))
    }

    func setOutToPlayhead() {
        guard isLoaded else { return }
        let minOut = CMTimeAdd(inTime.value, frameDuration)
        outTime.send(clamp(time: currentTime.value, min: minOut, max: sourceDuration))
    }

    func nudgeIn(frames: Int) {
        guard isLoaded else { return }
        let delta = CMTimeMultiply(frameDuration, multiplier: Int32(frames))
        let maxIn = CMTimeSubtract(outTime.value, frameDuration)
        inTime.send(clamp(time: CMTimeAdd(inTime.value, delta), min: .zero, max: maxIn))
    }

    func nudgeOut(frames: Int) {
        guard isLoaded else { return }
        let delta = CMTimeMultiply(frameDuration, multiplier: Int32(frames))
        let minOut = CMTimeAdd(inTime.value, frameDuration)
        outTime.send(clamp(time: CMTimeAdd(outTime.value, delta), min: minOut, max: sourceDuration))
    }

    func resetTrim() {
        guard isLoaded else { return }
        inTime.send(.zero)
        outTime.send(sourceDuration)
    }

    // MARK: Private

    private func installTimeObserver() {
        let interval = CMTime(value: 1, timescale: 60)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            self?.currentTime.send(time)
        }
    }

    private func handleReachedEnd() {
        guard loopEnabled.value, isLoaded else {
            isPlaying.send(false)
            return
        }
        // Zero-tolerance seek back to the in-point so each loop iteration starts
        // exactly where the exported GIF will.
        player.seek(to: inTime.value,
                    toleranceBefore: .zero,
                    toleranceAfter: .zero) { [weak self] _ in
            self?.player.play()
        }
    }

    private func clamp(time: CMTime, min minT: CMTime, max maxT: CMTime) -> CMTime {
        if CMTimeCompare(time, minT) < 0 { return minT }
        if CMTimeCompare(time, maxT) > 0 { return maxT }
        return time
    }
}
