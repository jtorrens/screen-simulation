import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func previewPanUsesInitialDeltaAndClampsOnlyToVisibleContent() {
    let initial = CGSize(width: 40, height: -20)
    let start = CGPoint(x: 120, y: 80)
    let current = CGPoint(x: 175, y: 25)
    let proposed = CGSize(
        width: initial.width + current.x - start.x,
        height: initial.height + current.y - start.y
    )
    #expect(proposed == CGSize(width: 95, height: -75))
    #expect(PreviewNavigationMath.clampedPan(
        proposed,
        viewport: CGSize(width: 100, height: 80),
        fittedContent: CGSize(width: 100, height: 50),
        scale: 2
    ) == CGSize(width: 50, height: -10))
}

@Test func previewFitAndOneToOneUseTheActualImageRect() {
    let fitted = PreviewNavigationMath.fittedContentSize(
        texture: CGSize(width: 200, height: 100),
        viewport: CGSize(width: 100, height: 100)
    )
    #expect(fitted == CGSize(width: 100, height: 50))
    #expect(PreviewNavigationMath.oneToOneScale(
        texture: CGSize(width: 200, height: 100), fittedContent: fitted
    ) == 2)
    #expect(PreviewNavigationMath.clampedPan(
        CGSize(width: 200, height: -200),
        viewport: CGSize(width: 100, height: 100),
        fittedContent: fitted,
        scale: 2
    ) == CGSize(width: 50, height: 0))
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
    #expect(result == CGSize(width: 15, height: 0))
}

@Test func previewPanReachesEveryEdgeAndCentersContentThatIsSmallerThanViewport() {
    let viewport = CGSize(width: 100, height: 80)
    let fitted = CGSize(width: 100, height: 50)
    #expect(PreviewNavigationMath.clampedPan(
        CGSize(width: 10_000, height: 10_000), viewport: viewport,
        fittedContent: fitted, scale: 3
    ) == CGSize(width: 100, height: 35))
    #expect(PreviewNavigationMath.clampedPan(
        CGSize(width: -10_000, height: -10_000), viewport: viewport,
        fittedContent: fitted, scale: 3
    ) == CGSize(width: -100, height: -35))
    #expect(PreviewNavigationMath.clampedPan(
        CGSize(width: 50, height: -50), viewport: viewport,
        fittedContent: fitted, scale: 1
    ) == .zero)
}
