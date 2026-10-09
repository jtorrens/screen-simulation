import AppKit
import Testing
@testable import ScreenSimulationMacUI

@MainActor
@Test func sceneTreeDragScrollEdgesRespectDirectionAndViewport() {
    let rect = NSRect(x: 0, y: 200, width: 300, height: 200)
    #expect(SceneTreeDragScroll.step(point: NSPoint(x: 100, y: 201), viewport: rect, flipped: true) < 0)
    #expect(SceneTreeDragScroll.step(point: NSPoint(x: 100, y: 399), viewport: rect, flipped: true) > 0)
    #expect(SceneTreeDragScroll.step(point: NSPoint(x: 100, y: 399), viewport: rect, flipped: false) > 0)
    #expect(SceneTreeDragScroll.step(point: NSPoint(x: 100, y: 201), viewport: rect, flipped: false) < 0)
    for point in [NSPoint(x: 100, y: 300), NSPoint(x: -1, y: 201), NSPoint(x: 100, y: 401)] {
        #expect(SceneTreeDragScroll.step(point: point, viewport: rect, flipped: true) == 0)
    }
}

@MainActor
@Test func sceneTreeDragScrollContinuesAtStationaryPointerAndStopsOnRelease() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 1600))
    let anchor = NSView(frame: document.bounds)
    document.addSubview(anchor)
    scroll.documentView = document
    window.contentView = scroll
    let controller = SceneTreeDragScroll()
    controller.anchor = anchor
    defer { controller.stop() }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 500))
    func mouse(_ y: CGFloat) -> NSPoint {
        let clip = scroll.contentView
        return window.convertPoint(toScreen: clip.convert(
            NSPoint(x: clip.bounds.minX + 100, y: clip.bounds.minY + y), to: nil
        ))
    }
    controller.begin()
    let upperEdge = mouse(199)
    let initial = scroll.contentView.bounds.minY
    controller.tick(mouse: upperEdge, pressed: true)
    let first = scroll.contentView.bounds.minY
    controller.tick(mouse: upperEdge, pressed: true)
    #expect(first > initial)
    #expect(scroll.contentView.bounds.minY > first)
    let beforeDown = scroll.contentView.bounds.minY
    controller.tick(mouse: mouse(1), pressed: true)
    #expect(scroll.contentView.bounds.minY < beforeDown)
    for _ in 0..<300 { controller.tick(mouse: upperEdge, pressed: true) }
    #expect(scroll.contentView.bounds.maxY <= document.bounds.maxY)
    for _ in 0..<300 { controller.tick(mouse: mouse(1), pressed: true) }
    #expect(scroll.contentView.bounds.minY >= document.bounds.minY)
    let final = scroll.contentView.bounds
    controller.tick(mouse: upperEdge, pressed: false)
    #expect(!controller.isDragging)
    controller.tick(mouse: upperEdge, pressed: true)
    #expect(scroll.contentView.bounds == final)
    controller.begin()
    controller.stop()
    #expect(!controller.isDragging)
}
