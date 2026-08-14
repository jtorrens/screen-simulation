import CoreGraphics
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func viewerNavigationOwnsFitZoomAndPanWithoutCameraState() {
    let controller = ViewerNavigationController()
    controller.updateFittedZoom(0.5)
    #expect(controller.isFitted)
    #expect(controller.zoom == 0.5)

    controller.setPan(CGSize(width: 42, height: -17))
    controller.zoom(by: 2)
    #expect(!controller.isFitted)
    #expect(controller.zoom == 1)
    #expect(controller.pan == CGSize(width: 42, height: -17))

    controller.fit()
    #expect(controller.isFitted)
    #expect(controller.pan == .zero)
}

@Test @MainActor func viewerNavigationRestoresOneStrictFiniteSnapshot() {
    let controller = ViewerNavigationController()
    controller.restore(
        zoom: 2.5,
        pan: CGSize(width: -21, height: 9),
        isFitted: false
    )
    #expect(controller.zoom == 2.5)
    #expect(controller.pan == CGSize(width: -21, height: 9))
    #expect(!controller.isFitted)

    controller.restore(zoom: .nan, pan: .zero, isFitted: true)
    #expect(controller.zoom == 2.5)
    #expect(!controller.isFitted)
}
