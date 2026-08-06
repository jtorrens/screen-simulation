import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func previewPanUsesInitialDeltaAndClampsOnlyToVisibleContent() {
    let initial = CGSize(width: 40, height: -20)
    let start = CGPoint(x: 120, y: 80)
    let current = CGPoint(x: 175, y: 25)
    let proposed = CGSize(
        width: initial.width + current.x - start.x,
        height: initial.height - current.y + start.y
    )
    #expect(proposed == CGSize(width: 95, height: 35))
    #expect(PreviewNavigationMath.clampedPan(
        proposed,
        viewport: CGSize(width: 100, height: 80),
        scale: 2
    ) == CGSize(width: 50, height: 35))
}

@Test func previewZoomPreservesTheContentPointUnderItsAnchor() {
    let previous = CGSize(width: 20, height: -10)
    let anchor = CGPoint(x: 75, y: 30)
    let center = CGPoint(x: 50, y: 50)
    let result = PreviewNavigationMath.anchoredPan(
        previous: previous,
        anchor: anchor,
        viewportCenter: center,
        scaleRatio: 2
    )
    #expect(result == CGSize(width: 15, height: -40))
}
