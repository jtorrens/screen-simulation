import AppKit
import SwiftUI

/// Presentation-only scrolling; the existing row drop targets still own the move.
@MainActor
public final class SceneTreeDragScroll: ObservableObject {
    weak var anchor: NSView?
    private var timer: Timer?
    private var escapeMonitor: Any?
    var isDragging: Bool { timer != nil }

    public init() {}

    public func begin() {
        stop()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick(mouse: NSEvent.mouseLocation, pressed: NSEvent.pressedMouseButtons & 1 != 0)
            }
        }
        self.timer = timer
        // Drag tracking runs outside the default run-loop mode, including while stationary.
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.stop() }
            return event
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    func tick(mouse: NSPoint, pressed: Bool) {
        guard isDragging else { return }
        guard pressed, let anchor, let window = anchor.window,
              let scroll = anchor.enclosingScrollView, !anchor.isHiddenOrHasHiddenAncestor else {
            stop()
            return
        }
        let clip = scroll.contentView
        let point = clip.convert(window.convertPoint(fromScreen: mouse), from: nil)
        let delta = Self.step(point: point, viewport: clip.bounds, flipped: clip.isFlipped)
        guard delta != 0 else { return }
        var bounds = clip.bounds
        bounds.origin.y += delta
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    static func step(point: NSPoint, viewport: NSRect, flipped: Bool) -> CGFloat {
        guard viewport.contains(point), viewport.height > 0 else { return 0 }
        let band = min(CGFloat(40), viewport.height / 2)
        let fromTop = flipped ? point.y - viewport.minY : viewport.maxY - point.y
        let fromBottom = viewport.height - fromTop
        let direction: CGFloat = flipped ? 1 : -1
        if fromTop < band { return -direction * 10 * (1 - fromTop / band) }
        if fromBottom < band { return direction * 10 * (1 - fromBottom / band) }
        return 0
    }
}

public struct SceneTreeDragScrollAnchor: NSViewRepresentable {
    let controller: SceneTreeDragScroll

    public init(controller: SceneTreeDragScroll) { self.controller = controller }

    public func makeCoordinator() -> SceneTreeDragScroll { controller }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.anchor = view
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        controller.anchor = view
    }

    public static func dismantleNSView(_ view: NSView, coordinator: SceneTreeDragScroll) {
        coordinator.stop()
    }
}
