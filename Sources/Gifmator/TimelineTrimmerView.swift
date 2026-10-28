import AVFoundation
import AppKit
import Combine

/// Change notifications emitted while the user interacts with the trimmer.
/// Separate messages for in/out/scrub so the host can route each to the model
/// without re-interpreting intent.
protocol TimelineTrimmerDelegate: AnyObject {
    func trimmer(_ view: TimelineTrimmerView, didChangeInTime seconds: Double)
    func trimmer(_ view: TimelineTrimmerView, didChangeOutTime seconds: Double)
    func trimmer(_ view: TimelineTrimmerView, didScrubTo seconds: Double, precise: Bool)
}

/// The timeline strip itself: dark background placeholder + two draggable
/// handles + an independent playhead cursor + dim overlays outside the
/// selection. Hit-testing is done manually in mouseDown/Dragged/Up so the
/// handles have a generous grab region that extends vertically beyond the
/// strip.
///
/// Phase A: the playhead gets a red flag grip above the strip and a smaller
/// mirror below it. These flags live outside any handle rectangle so the user
/// can still grab-and-scrub even when the in/out handles overlap the shaft
/// (the original overlap-grab bug the user hit in testing).
final class TimelineTrimmerView: NSView {
    weak var delegate: TimelineTrimmerDelegate?

    // Driven by the host via `update(...)`.
    private var sourceDuration: Double = 0
    private var inSeconds: Double = 0
    private var outSeconds: Double = 0
    private var playheadSeconds: Double = 0
    private var minHandleGapSeconds: Double = 0.001

    private let stripHeight: CGFloat = 56
    private let handleWidth: CGFloat = 10
    private let handleHeight: CGFloat = 64
    private let handleGrabSlop: CGFloat = 6

    // Playhead flag grips. See drawTopFlag / drawBottomFlag for the overlap-
    // handle bug these fix. Flags live entirely in the padding regions above
    // and below the strip — they never share vertical space with handles.
    private let topFlagWidth: CGFloat = 16
    private let topFlagHeight: CGFloat = 12
    private let bottomFlagWidth: CGFloat = 12
    private let bottomFlagHeight: CGFloat = 10
    private let flagStripGap: CGFloat = 1          // visual gap between flag tip and strip edge
    private let flagGrabSlop: CGFloat = 4          // horizontal grab slop around flag (each side)
    private let flagInsideStripSlop: CGFloat = 1   // tiny inside-strip slop for grab (keeps hit easy at edge)
    private let flagOutsideStripSlop: CGFloat = 3  // slop beyond the flag away from strip

    // Padding above AND below the strip reserved for the flag grips. 14 pt
    // seats a 12 pt-tall top flag + 1 pt gap + 1 pt breathing room above.
    // Bumped from 12 pt after the flag-tip-in-strip bug.
    private let flagPadding: CGFloat = 14
    private var totalHeight: CGFloat { stripHeight + flagPadding * 2 }

    private enum DragTarget {
        case none
        case inHandle
        case outHandle
        case scrub
    }
    private var dragTarget: DragTarget = .none

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: totalHeight)
    }

    /// Push a fresh snapshot of model state. The host throttles / coalesces as
    /// needed; the view just redraws.
    func update(sourceDuration: Double,
                inSeconds: Double,
                outSeconds: Double,
                playheadSeconds: Double,
                minHandleGapSeconds: Double) {
        self.sourceDuration = max(0, sourceDuration)
        self.inSeconds = max(0, min(self.sourceDuration, inSeconds))
        self.outSeconds = max(0, min(self.sourceDuration, outSeconds))
        self.playheadSeconds = max(0, min(self.sourceDuration, playheadSeconds))
        self.minHandleGapSeconds = max(minHandleGapSeconds, 0.001)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let strip = stripRect()
        drawFilmstripPlaceholder(in: ctx, rect: strip)

        guard sourceDuration > 0 else { return }

        let inX = xForSeconds(inSeconds)
        let outX = xForSeconds(outSeconds)
        let playX = xForSeconds(playheadSeconds)

        // Dim overlays outside the selected range.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        if inX > strip.minX {
            ctx.fill(CGRect(x: strip.minX, y: strip.minY,
                            width: inX - strip.minX, height: strip.height))
        }
        if outX < strip.maxX {
            ctx.fill(CGRect(x: outX, y: strip.minY,
                            width: strip.maxX - outX, height: strip.height))
        }

        // Selection stroke.
        if outX > inX {
            let selection = CGRect(x: inX, y: strip.minY,
                                   width: outX - inX, height: strip.height)
                .insetBy(dx: 1, dy: 1)
            let path = CGPath(roundedRect: selection, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.addPath(path)
            ctx.strokePath()
        }

        drawHandle(in: ctx, atX: inX)
        drawHandle(in: ctx, atX: outX)

        // Playhead shaft last (over handles) with a 1 pt white outline so it
        // still reads clearly when it crosses a handle's accent fill.
        drawPlayheadShaft(in: ctx, atX: playX, strip: strip)

        drawTopFlag(in: ctx, atX: playX, strip: strip)
        drawBottomFlag(in: ctx, atX: playX, strip: strip)
    }

    private func drawPlayheadShaft(in ctx: CGContext, atX x: CGFloat, strip: CGRect) {
        // Shaft deliberately terminates at the flag bases — the top flag caps
        // the upper end and the bottom flag caps the lower end, so no red stub
        // extends past either flag into the view's edge padding. The flags are
        // the visual terminators the user asked for.
        let shaftBottom = strip.minY - flagStripGap - bottomFlagHeight
        let shaftTop = strip.maxY + flagStripGap + topFlagHeight
        let shaftHeight = shaftTop - shaftBottom

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.fill(CGRect(x: x - 2, y: shaftBottom, width: 4, height: shaftHeight))
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(CGRect(x: x - 1, y: shaftBottom, width: 2, height: shaftHeight))
    }

    private func drawTopFlag(in ctx: CGContext, atX x: CGFloat, strip: CGRect) {
        // Dedicated playhead grab target. Lives ENTIRELY in the top padding
        // region above the strip — the flag's tip sits `flagStripGap` pt above
        // `strip.maxY` and the base extends further up into the padding. Trim
        // handles occupy the strip rect exclusively, so this flag's rectangle
        // is vertically disjoint from any handle for every playhead position.
        // Invariant: flag.minY (= tipY) > strip.maxY. Pre-fix the flag's tip
        // extended into the strip and visually collided with the handles,
        // defeating the very reason the flag exists.
        let tipY = strip.maxY + flagStripGap              // flag's lowest Y (visually just above strip top)
        let topY = tipY + topFlagHeight                    // flag's upper edge
        let shoulderY = tipY + (topFlagHeight * 0.5)       // widest point halfway up
        let halfW = topFlagWidth / 2

        let path = CGMutablePath()
        path.move(to: CGPoint(x: x - halfW, y: topY))
        path.addLine(to: CGPoint(x: x + halfW, y: topY))
        path.addLine(to: CGPoint(x: x + halfW, y: shoulderY))
        path.addLine(to: CGPoint(x: x, y: tipY))
        path.addLine(to: CGPoint(x: x - halfW, y: shoulderY))
        path.closeSubpath()

        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawBottomFlag(in ctx: CGContext, atX x: CGFloat, strip: CGRect) {
        // Mirror of the top flag. Also strictly outside the strip rect:
        // tip sits `flagStripGap` pt below `strip.minY`, base extends further
        // down into the padding. Vertically disjoint from the handles.
        let tipY = strip.minY - flagStripGap               // flag's highest Y (visually just below strip bottom)
        let bottomY = tipY - bottomFlagHeight              // flag's lower edge
        let shoulderY = tipY - (bottomFlagHeight * 0.5)
        let halfW = bottomFlagWidth / 2

        let path = CGMutablePath()
        path.move(to: CGPoint(x: x - halfW, y: bottomY))
        path.addLine(to: CGPoint(x: x + halfW, y: bottomY))
        path.addLine(to: CGPoint(x: x + halfW, y: shoulderY))
        path.addLine(to: CGPoint(x: x, y: tipY))
        path.addLine(to: CGPoint(x: x - halfW, y: shoulderY))
        path.closeSubpath()

        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    private func drawFilmstripPlaceholder(in ctx: CGContext, rect: CGRect) {
        // TODO v1.1: thumbnail strip via AVAssetImageGenerator
        // Replace the gradient + stripe pattern with a horizontal sequence of
        // frame thumbnails. The surrounding handle geometry won't change.
        let clip = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.saveGState()
        ctx.addPath(clip)
        ctx.clip()

        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            NSColor(white: 0.22, alpha: 1).cgColor,
            NSColor(white: 0.32, alpha: 1).cgColor
        ]
        if let gradient = CGGradient(colorsSpace: space,
                                     colors: colors as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: CGPoint(x: rect.minX, y: rect.maxY),
                                   options: [])
        }

        let stripeCount = 40
        let stripeWidth = rect.width / CGFloat(stripeCount)
        for i in 0..<stripeCount {
            let alpha: CGFloat = i.isMultiple(of: 2) ? 0.03 : 0.06
            ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
            ctx.fill(CGRect(x: rect.minX + CGFloat(i) * stripeWidth,
                            y: rect.minY,
                            width: stripeWidth,
                            height: rect.height))
        }
        ctx.restoreGState()
    }

    private func drawHandle(in ctx: CGContext, atX x: CGFloat) {
        let yCenter = bounds.midY
        let rect = CGRect(x: x - handleWidth / 2,
                          y: yCenter - handleHeight / 2,
                          width: handleWidth,
                          height: handleHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1),
                      blur: 2,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }

    // MARK: Geometry

    private func stripRect() -> CGRect {
        CGRect(x: 0,
               y: (bounds.height - stripHeight) / 2,
               width: bounds.width,
               height: stripHeight)
    }

    private func xForSeconds(_ seconds: Double) -> CGFloat {
        guard sourceDuration > 0 else { return 0 }
        let frac = min(max(seconds / sourceDuration, 0), 1)
        return CGFloat(frac) * bounds.width
    }

    private func secondsForX(_ x: CGFloat) -> Double {
        guard bounds.width > 0 else { return 0 }
        let frac = min(max(Double(x / bounds.width), 0), 1)
        return frac * sourceDuration
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        guard sourceDuration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let strip = stripRect()
        let playX = xForSeconds(playheadSeconds)

        // Phase A hit-test priority (fixes the overlap-grab bug):
        //   1. Top playhead flag (+ grab slop)
        //   2. Bottom playhead flag (+ grab slop)
        //   3. In/out handles (6 pt grab slop)
        //   4. Strip background (scrub)
        // Flag hits always win and become scrubs, even when a handle bbox would
        // also contain the point. That is intentional — a flag grab is the
        // user asking for the playhead specifically.
        if topFlagHitRect(atX: playX, strip: strip).contains(point)
            || bottomFlagHitRect(atX: playX, strip: strip).contains(point) {
            dragTarget = .scrub
            delegate?.trimmer(self, didScrubTo: secondsForX(point.x), precise: false)
            return
        }

        let inX = xForSeconds(inSeconds)
        let outX = xForSeconds(outSeconds)
        let grabHalf = handleWidth / 2 + handleGrabSlop

        // Prefer whichever handle is closer when both are within grab range,
        // so overlapping handles don't ambiguously steal each other's drags.
        let distIn = abs(point.x - inX)
        let distOut = abs(point.x - outX)
        if distIn <= grabHalf || distOut <= grabHalf {
            dragTarget = (distIn <= distOut) ? .inHandle : .outHandle
            return
        }

        // Clicks on the strip itself start a scrub.
        if strip.insetBy(dx: 0, dy: -8).contains(point) {
            dragTarget = .scrub
            delegate?.trimmer(self, didScrubTo: secondsForX(point.x), precise: false)
        } else {
            dragTarget = .none
        }
    }

    private func topFlagHitRect(atX x: CGFloat, strip: CGRect) -> CGRect {
        // Follows the flag visuals: entirely in the top padding region plus a
        // tiny `flagInsideStripSlop` of in-strip grab-slop for forgiveness at
        // the strip edge. Expands to the far side by `flagOutsideStripSlop`.
        let yLower = strip.maxY - flagInsideStripSlop
        let yUpper = strip.maxY + flagStripGap + topFlagHeight + flagOutsideStripSlop
        return CGRect(x: x - topFlagWidth / 2 - flagGrabSlop,
                      y: yLower,
                      width: topFlagWidth + flagGrabSlop * 2,
                      height: yUpper - yLower)
    }

    private func bottomFlagHitRect(atX x: CGFloat, strip: CGRect) -> CGRect {
        // Mirror of topFlagHitRect: same slop budget, strictly outside the
        // strip apart from the tiny `flagInsideStripSlop` edge forgiveness.
        let yUpper = strip.minY + flagInsideStripSlop
        let yLower = strip.minY - flagStripGap - bottomFlagHeight - flagOutsideStripSlop
        return CGRect(x: x - bottomFlagWidth / 2 - flagGrabSlop,
                      y: yLower,
                      width: bottomFlagWidth + flagGrabSlop * 2,
                      height: yUpper - yLower)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragTarget != .none, sourceDuration > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let x = max(0, min(bounds.width, point.x))
        let seconds = secondsForX(x)

        switch dragTarget {
        case .inHandle:
            let maxIn = max(0, outSeconds - minHandleGapSeconds)
            delegate?.trimmer(self, didChangeInTime: min(seconds, maxIn))
        case .outHandle:
            let minOut = min(sourceDuration, inSeconds + minHandleGapSeconds)
            delegate?.trimmer(self, didChangeOutTime: max(seconds, minOut))
        case .scrub:
            delegate?.trimmer(self, didScrubTo: seconds, precise: false)
        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragTarget == .scrub, sourceDuration > 0 {
            let point = convert(event.locationInWindow, from: nil)
            let x = max(0, min(bounds.width, point.x))
            delegate?.trimmer(self, didScrubTo: secondsForX(x), precise: true)
        }
        dragTarget = .none
    }
}

/// Composite view that owns the trimmer strip and the readouts + Reset button.
/// This is what the RootViewController embeds in its vertical stack.
final class TimelineSectionView: NSView {
    private let model: PlayerModel
    private let trimmer = TimelineTrimmerView()

    private let inLabel = TimelineSectionView.makeReadoutLabel()
    private let outLabel = TimelineSectionView.makeReadoutLabel()
    private let selectedLabel = TimelineSectionView.makeReadoutLabel()
    private let sourceLabel = TimelineSectionView.makeReadoutLabel()
    private let resetButton = NSButton(title: "Reset trim", target: nil, action: nil)

    private var cancellables = Set<AnyCancellable>()

    init(model: PlayerModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true

        trimmer.translatesAutoresizingMaskIntoConstraints = false
        trimmer.delegate = self

        resetButton.bezelStyle = .texturedRounded
        resetButton.target = self
        resetButton.action = #selector(didTapReset)

        let readouts = NSStackView(views: [inLabel, outLabel, selectedLabel, sourceLabel])
        readouts.orientation = .horizontal
        readouts.spacing = 20
        readouts.alignment = .centerY

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let readoutsRow = NSStackView(views: [readouts, spacer, resetButton])
        readoutsRow.orientation = .horizontal
        readoutsRow.alignment = .centerY
        readoutsRow.distribution = .fill
        readoutsRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(trimmer)
        addSubview(readoutsRow)

        NSLayoutConstraint.activate([
            trimmer.topAnchor.constraint(equalTo: topAnchor),
            trimmer.leadingAnchor.constraint(equalTo: leadingAnchor),
            trimmer.trailingAnchor.constraint(equalTo: trailingAnchor),
            // stripHeight (56) + flagPadding * 2 (14 * 2) — padding grown to 14
            // after the flag-tip-in-strip fix so a 12 pt flag + 1 pt gap + 1 pt
            // breathing room fits strictly in the padding regions.
            trimmer.heightAnchor.constraint(equalToConstant: 84),

            readoutsRow.topAnchor.constraint(equalTo: trimmer.bottomAnchor, constant: 10),
            readoutsRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            readoutsRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            readoutsRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        bindToModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func bindToModel() {
        Publishers.CombineLatest4(
            model.loadState,
            model.inTime,
            model.outTime,
            model.currentTime
        )
        .throttle(for: .milliseconds(16), scheduler: DispatchQueue.main, latest: true)
        .sink { [weak self] state, inT, outT, cur in
            guard let self else { return }
            let source: Double
            if case let .loaded(_, _, _, duration, _) = state {
                source = duration.seconds
            } else {
                source = 0
            }
            let gap = self.model.frameDuration.seconds
            self.trimmer.update(sourceDuration: source,
                                inSeconds: inT.seconds,
                                outSeconds: outT.seconds,
                                playheadSeconds: cur.seconds,
                                minHandleGapSeconds: gap)

            self.inLabel.stringValue = "In  \(formatTime(inT))"
            self.outLabel.stringValue = "Out  \(formatTime(outT))"
            self.selectedLabel.stringValue = "Selected  \(formatTime(self.model.selectedDuration))"
            self.sourceLabel.stringValue = "Source  \(formatTime(self.model.sourceDuration))"
            self.resetButton.isEnabled = self.model.isLoaded
        }
        .store(in: &cancellables)
    }

    @objc private func didTapReset() {
        model.resetTrim()
    }

    private static func makeReadoutLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }
}

extension TimelineSectionView: TimelineTrimmerDelegate {
    func trimmer(_ view: TimelineTrimmerView, didChangeInTime seconds: Double) {
        let frame = model.frameDuration.seconds
        let maxIn = max(0, model.outTime.value.seconds - frame)
        let clamped = min(max(0, seconds), maxIn)
        model.inTime.send(CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func trimmer(_ view: TimelineTrimmerView, didChangeOutTime seconds: Double) {
        let frame = model.frameDuration.seconds
        let minOut = min(model.sourceDuration.seconds, model.inTime.value.seconds + frame)
        let clamped = max(min(model.sourceDuration.seconds, seconds), minOut)
        model.outTime.send(CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func trimmer(_ view: TimelineTrimmerView, didScrubTo seconds: Double, precise: Bool) {
        model.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), precise: precise)
    }
}
