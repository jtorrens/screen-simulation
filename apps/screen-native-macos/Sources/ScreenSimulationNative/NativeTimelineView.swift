import AppKit
import SwiftUI

struct NativeTimelineView: NSViewRepresentable {
    let frameCount: Int
    let frameRate: Double
    let currentFrame: Int
    let inFrame: Int
    let outFrame: Int
    let snapFrames: [Int]
    let onSeek: (Int) -> Void
    let onSetIn: (Int) -> Void
    let onSetOut: (Int) -> Void

    func makeNSView(context: Context) -> TimelineCanvas {
        let view = TimelineCanvas()
        view.onSeek = onSeek
        view.onSetIn = onSetIn
        view.onSetOut = onSetOut
        return view
    }

    func updateNSView(_ view: TimelineCanvas, context: Context) {
        view.frameCount = max(1, frameCount)
        view.frameRate = max(1, frameRate)
        view.currentFrame = currentFrame
        view.inFrame = inFrame
        view.outFrame = outFrame
        view.snapFrames = snapFrames
        view.onSeek = onSeek
        view.onSetIn = onSetIn
        view.onSetOut = onSetOut
        view.needsDisplay = true
    }
}

final class TimelineCanvas: NSView {
    enum DragTarget { case playhead, input, output }

    var frameCount = 1
    var frameRate = 24.0
    var currentFrame = 0
    var inFrame = 0
    var outFrame = 0
    var snapFrames: [Int] = []
    var onSeek: ((Int) -> Void)?
    var onSetIn: ((Int) -> Void)?
    var onSetOut: ((Int) -> Void)?
    private var dragTarget = DragTarget.playhead

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let rulerHeight: CGFloat = 24
        let track = NSRect(x: 0, y: rulerHeight, width: bounds.width, height: max(20, bounds.height - rulerHeight))
        NSColor.black.withAlphaComponent(0.28).setFill()
        track.fill()

        let inputX = x(for: inFrame)
        let outputX = x(for: outFrame)
        NativeTheme.nsAccent.withAlphaComponent(0.20).setFill()
        NSRect(x: inputX, y: track.minY, width: max(1, outputX - inputX), height: track.height).fill()

        drawRuler(height: rulerHeight)
        drawHandle(x: inputX, color: .systemBlue, pointsRight: true)
        drawHandle(x: outputX, color: .systemYellow, pointsRight: false)

        let playheadX = x(for: currentFrame)
        NSColor.white.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: playheadX, y: 0))
        path.line(to: NSPoint(x: playheadX, y: bounds.maxY))
        path.stroke()
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: playheadX - 4, y: 1, width: 8, height: 8),
            xRadius: 2, yRadius: 2
        ).fill()

        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
            focus.lineWidth = 2
            focus.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let inputDistance = abs(point.x - x(for: inFrame))
        let outputDistance = abs(point.x - x(for: outFrame))
        dragTarget = if inputDistance <= 9 { .input }
            else if outputDistance <= 9 { .output }
            else { .playhead }
        update(at: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        update(at: convert(event.locationInWindow, from: nil).x)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: onSeek?(max(0, currentFrame - 1))
        case 124: onSeek?(min(frameCount - 1, currentFrame + 1))
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { "Timeline" }
    override func accessibilityValue() -> Any? { timecode(currentFrame) }
    override func accessibilityMinValue() -> Any? { 0 }
    override func accessibilityMaxValue() -> Any? { frameCount - 1 }
    override func accessibilityPerformIncrement() -> Bool {
        onSeek?(min(frameCount - 1, currentFrame + 1)); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        onSeek?(max(0, currentFrame - 1)); return true
    }

    private func update(at x: CGFloat) {
        switch dragTarget {
        case .playhead:
            onSeek?(TimelineFrameGeometry.snappedFrame(
                at: x, width: bounds.width, frameCount: frameCount,
                snapFrames: snapFrames
            ))
        case .input:
            onSetIn?(min(TimelineFrameGeometry.frame(
                at: x, width: bounds.width, frameCount: frameCount
            ), outFrame))
        case .output:
            onSetOut?(max(TimelineFrameGeometry.frame(
                at: x, width: bounds.width, frameCount: frameCount
            ), inFrame))
        }
    }

    private func drawRuler(height: CGFloat) {
        let pixelsPerFrame = bounds.width / CGFloat(max(1, frameCount - 1))
        let candidates = [1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]
        let major = candidates.first { CGFloat($0) * pixelsPerFrame >= 72 } ?? candidates.last!
        let minor = max(1, major / 5)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for frame in stride(from: 0, to: frameCount, by: minor) {
            let position = x(for: frame)
            let isMajor = frame.isMultiple(of: major)
            NSColor.separatorColor.setStroke()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: position, y: height - (isMajor ? 10 : 5)))
            tick.line(to: NSPoint(x: position, y: height))
            tick.stroke()
            if isMajor {
                timecode(frame).draw(at: NSPoint(x: position + 3, y: 3), withAttributes: attributes)
            }
        }
    }

    private func drawHandle(x: CGFloat, color: NSColor, pointsRight: Bool) {
        color.setFill()
        let path = NSBezierPath()
        let direction: CGFloat = pointsRight ? 1 : -1
        path.move(to: NSPoint(x: x, y: 24))
        path.line(to: NSPoint(x: x + direction * 8, y: 24))
        path.line(to: NSPoint(x: x, y: 34))
        path.close()
        path.fill()
        NSRect(x: x - 1, y: 24, width: 2, height: bounds.height - 24).fill()
    }

    private func x(for frame: Int) -> CGFloat {
        TimelineFrameGeometry.x(for: frame, width: bounds.width, frameCount: frameCount)
    }

    private func timecode(_ frame: Int) -> String {
        let rate = max(1, Int(frameRate.rounded()))
        let value = max(0, frame)
        return String(
            format: "%02d:%02d:%02d:%02d",
            value / (rate * 3_600),
            (value / (rate * 60)) % 60,
            (value / rate) % 60,
            value % rate
        )
    }
}

enum TimelineFrameGeometry {
    static let snapDistance: CGFloat = 9

    static func x(for frame: Int, width: CGFloat, frameCount: Int) -> CGFloat {
        CGFloat(min(max(0, frame), max(0, frameCount - 1)))
            / CGFloat(max(1, frameCount - 1)) * max(0, width)
    }

    static func frame(at x: CGFloat, width: CGFloat, frameCount: Int) -> Int {
        Int((min(max(0, x), max(0, width)) / max(1, width)
            * CGFloat(max(1, frameCount - 1))).rounded())
    }

    static func snappedFrame(
        at x: CGFloat,
        width: CGFloat,
        frameCount: Int,
        snapFrames: [Int]
    ) -> Int {
        let raw = frame(at: x, width: width, frameCount: frameCount)
        var candidateFrame: Int?
        var candidateDistance = CGFloat.greatestFiniteMagnitude
        for snapFrame in snapFrames where (0 ..< frameCount).contains(snapFrame) {
            let snapX = self.x(for: snapFrame, width: width, frameCount: frameCount)
            let distance = abs(x - snapX)
            guard distance <= snapDistance else { continue }
            if distance < candidateDistance
                || (distance == candidateDistance && snapFrame < (candidateFrame ?? Int.max))
            {
                candidateFrame = snapFrame
                candidateDistance = distance
            }
        }
        return candidateFrame ?? raw
    }

    static func previousKeyframe(before frame: Int, keyframes: [Int]) -> Int? {
        keyframes.filter { $0 < frame }.max()
    }

    static func nextKeyframe(after frame: Int, keyframes: [Int]) -> Int? {
        keyframes.filter { $0 > frame }.min()
    }
}

struct SimulationOpacityTrackView: NSViewRepresentable {
    let frameCount: Int
    let currentFrame: Int
    let keyframes: [SceneScalarKeyframePresentation]
    let interpolationOptions: [(SceneAnimationInterpolation, String)]
    let onSeek: (Int) -> Void
    let onMove: (UUID, Int) -> Void
    let onSetInterpolation: (UUID, SceneAnimationInterpolation) -> Void

    func makeNSView(context: Context) -> SimulationOpacityTrackCanvas {
        let view = SimulationOpacityTrackCanvas()
        update(view)
        return view
    }

    func updateNSView(_ view: SimulationOpacityTrackCanvas, context: Context) {
        update(view)
    }

    private func update(_ view: SimulationOpacityTrackCanvas) {
        view.frameCount = max(1, frameCount)
        view.currentFrame = currentFrame
        view.keyframes = keyframes
        view.interpolationOptions = interpolationOptions
        view.onSeek = onSeek
        view.onMove = onMove
        view.onSetInterpolation = onSetInterpolation
        view.needsDisplay = true
    }
}

final class SimulationOpacityTrackCanvas: NSView {
    var frameCount = 1
    var currentFrame = 0
    var keyframes: [SceneScalarKeyframePresentation] = []
    var interpolationOptions: [(SceneAnimationInterpolation, String)] = []
    var onSeek: ((Int) -> Void)?
    var onMove: ((UUID, Int) -> Void)?
    var onSetInterpolation: ((UUID, SceneAnimationInterpolation) -> Void)?

    private var draggedKeyframeID: UUID?
    private var draggedOriginalFrame: Int?
    private var draggedPreviewFrame: Int?
    private var contextKeyframeID: UUID?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
        let center = NSBezierPath()
        center.move(to: NSPoint(x: 0, y: bounds.midY))
        center.line(to: NSPoint(x: bounds.maxX, y: bounds.midY))
        center.stroke()

        for keyframe in keyframes {
            let frame = keyframe.id == draggedKeyframeID
                ? draggedPreviewFrame ?? keyframe.frame : keyframe.frame
            drawKeyframe(keyframe, at: x(for: frame), selected: frame == currentFrame)
        }

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let playhead = NSBezierPath()
        let playheadX = x(for: currentFrame)
        playhead.move(to: NSPoint(x: playheadX, y: 0))
        playhead.line(to: NSPoint(x: playheadX, y: bounds.maxY))
        playhead.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let keyframe = keyframe(at: point) {
            draggedKeyframeID = keyframe.id
            draggedOriginalFrame = keyframe.frame
            draggedPreviewFrame = keyframe.frame
            onSeek?(keyframe.frame)
        } else {
            onSeek?(TimelineFrameGeometry.snappedFrame(
                at: point.x, width: bounds.width, frameCount: frameCount,
                snapFrames: keyframes.map(\.frame)
            ))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard draggedKeyframeID != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = TimelineFrameGeometry.frame(
            at: point.x, width: bounds.width, frameCount: frameCount
        )
        draggedPreviewFrame = frame
        onSeek?(frame)
        needsDisplay = true
    }

    override func mouseUp(with _: NSEvent) {
        defer {
            draggedKeyframeID = nil
            draggedOriginalFrame = nil
            draggedPreviewFrame = nil
            needsDisplay = true
        }
        guard let id = draggedKeyframeID,
              let destination = draggedPreviewFrame,
              destination != draggedOriginalFrame else { return }
        onMove?(id, destination)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let keyframe = keyframe(at: point) else { return nil }
        contextKeyframeID = keyframe.id
        onSeek?(keyframe.frame)
        let menu = NSMenu(title: "Interpolación")
        for (interpolation, label) in interpolationOptions {
            let item = NSMenuItem(
                title: label,
                action: #selector(selectInterpolation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(interpolation.bridgeValue)
            item.state = interpolation == keyframe.interpolation ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectInterpolation(_ sender: NSMenuItem) {
        guard let id = contextKeyframeID,
              let interpolation = SceneAnimationInterpolation.allCases.first(where: {
                  Int($0.bridgeValue) == sender.tag
              }) else { return }
        onSetInterpolation?(id, interpolation)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func keyframe(at point: NSPoint) -> SceneScalarKeyframePresentation? {
        keyframes
            .map { ($0, abs(point.x - x(for: $0.frame))) }
            .filter { $0.1 <= 8 && abs(point.y - bounds.midY) <= 10 }
            .min { $0.1 < $1.1 }?.0
    }

    private func x(for frame: Int) -> CGFloat {
        TimelineFrameGeometry.x(for: frame, width: bounds.width, frameCount: frameCount)
    }

    private func drawKeyframe(
        _ keyframe: SceneScalarKeyframePresentation,
        at x: CGFloat,
        selected: Bool
    ) {
        let center = NSPoint(x: x, y: bounds.midY)
        let radius: CGFloat = selected ? 5.5 : 4.5
        NativeTheme.nsAccent.setFill()
        let path: NSBezierPath
        switch SceneAnimationKeyframeShape(interpolation: keyframe.interpolation) {
        case .square:
            path = NSBezierPath(rect: NSRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
        case .diamond:
            path = NSBezierPath()
            path.move(to: NSPoint(x: center.x, y: center.y - radius - 1))
            path.line(to: NSPoint(x: center.x + radius + 1, y: center.y))
            path.line(to: NSPoint(x: center.x, y: center.y + radius + 1))
            path.line(to: NSPoint(x: center.x - radius - 1, y: center.y))
            path.close()
        case .circle:
            path = NSBezierPath(ovalIn: NSRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
        path.fill()
        if selected {
            NSColor.white.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }
}
