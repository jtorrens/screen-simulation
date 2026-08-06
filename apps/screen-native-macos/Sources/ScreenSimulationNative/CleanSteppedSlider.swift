import AppKit
import SwiftUI

struct CleanSteppedSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let identityDetent: Double
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: range.lowerBound,
            maxValue: range.upperBound,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.altIncrementValue = step
        slider.controlSize = .small
        slider.setAccessibilityLabel(accessibilityLabel)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.altIncrementValue = step
        slider.doubleValue = value
        slider.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: CleanSteppedSlider

        init(parent: CleanSteppedSlider) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSSlider) {
            let clamped = min(
                parent.range.upperBound,
                max(parent.range.lowerBound, sender.doubleValue)
            )
            let stepped = (clamped / parent.step).rounded() * parent.step
            let detentRadius = parent.step * 0.55
            let resolved = abs(clamped - parent.identityDetent) <= detentRadius
                ? parent.identityDetent
                : stepped
            sender.doubleValue = resolved
            parent.value = resolved
        }
    }
}
