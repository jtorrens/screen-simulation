import CoreGraphics
import Foundation

@MainActor
final class ViewerNavigationController: ObservableObject {
    @Published private(set) var zoom = 1.0
    @Published private(set) var pan = CGSize.zero
    @Published private(set) var isFitted = true
    @Published private(set) var modelOneToOne = false

    var zoomPercentage: Double { zoom * 100 }

    func fit() {
        isFitted = true
        pan = .zero
    }

    func showOneToOne() {
        isFitted = false
        zoom = 1
        pan = .zero
    }

    func updateFittedZoom(_ value: Double) {
        guard isFitted, value.isFinite, value > 0,
              abs(zoom - value) > 0.000_001
        else { return }
        zoom = value
    }

    func setInteractiveZoom(_ value: Double) {
        guard value.isFinite else { return }
        isFitted = false
        zoom = min(16, max(0.01, value))
    }

    func setPan(_ value: CGSize) {
        guard value.width.isFinite, value.height.isFinite else { return }
        pan = value
    }

    func zoom(by factor: Double) {
        guard factor.isFinite, factor > 0 else { return }
        setInteractiveZoom(zoom * factor)
    }

    func setZoomPercentage(_ percentage: Double) {
        setInteractiveZoom(percentage / 100)
    }

    func fitModelPreview() {
        modelOneToOne = false
        fit()
    }

    func showModelPreviewOneToOne() {
        modelOneToOne = true
        fit()
    }

    func restore(zoom: Double, pan: CGSize, isFitted: Bool) {
        guard zoom.isFinite, zoom > 0,
              pan.width.isFinite, pan.height.isFinite
        else { return }
        self.zoom = min(16, max(0.01, zoom))
        self.pan = pan
        self.isFitted = isFitted
    }
}
