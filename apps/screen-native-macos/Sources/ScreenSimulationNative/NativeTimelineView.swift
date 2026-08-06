import AppKit
import SwiftUI

struct NativeTimelineView: NSViewRepresentable {
    let frameCount: Int
    let frameRate: Double
    let currentFrame: Int
    let inFrame: Int
    let outFrame: Int
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
        let frame = frame(at: x)
        switch dragTarget {
        case .playhead: onSeek?(frame)
        case .input: onSetIn?(min(frame, outFrame))
        case .output: onSetOut?(max(frame, inFrame))
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
        CGFloat(min(max(0, frame), frameCount - 1)) / CGFloat(max(1, frameCount - 1)) * bounds.width
    }

    private func frame(at x: CGFloat) -> Int {
        Int((min(max(0, x), bounds.width) / max(1, bounds.width) * CGFloat(max(1, frameCount - 1))).rounded())
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
