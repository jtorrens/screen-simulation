import SwiftUI

struct CleanSteppedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let identityDetent: Double?
    let accessibilityLabel: String

    var body: some View {
        Slider(
            value: Binding(
                get: { value },
                set: { candidate in
                    value = resolved(candidate)
                }
            ),
            in: range
        )
        .controlSize(.small)
        .tint(NativeTheme.accent)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value.formatted(.number.precision(.fractionLength(2))))
    }

    private func resolved(_ candidate: Double) -> Double {
            let clamped = min(
                range.upperBound,
                max(range.lowerBound, candidate)
            )
            let stepped = (clamped / step).rounded() * step
            let detentRadius = step * 0.55
            if let identityDetent,
               abs(clamped - identityDetent) <= detentRadius
            {
                return identityDetent
            }
            return stepped
    }
}
