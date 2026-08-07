import SwiftUI

struct PhysicalDoubleParameterRow: View {
    let label: String
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double
    let defaultValue: Double
    let onRestore: () -> Void
    var animationArmed: Binding<Bool>? = nil

    var body: some View {
        GridRow(alignment: .center) {
            PhysicalAnimationArmButton(label: label, armed: animationArmed)
            Text(label).frame(minWidth: 116, alignment: .leading)
            CleanSteppedSlider(
                value: $value,
                range: range,
                step: step,
                identityDetent: nil,
                accessibilityLabel: label
            )
            .frame(minWidth: 110, maxWidth: .infinity)
            HStack(spacing: 4) {
                TextField(
                    label,
                    value: $value,
                    format: .number.precision(.fractionLength(0 ... 6))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(label)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary).frame(minWidth: 30, alignment: .leading)
                }
            }
            PhysicalParameterRestoreButton(
                label: label,
                isModified: value != defaultValue,
                action: onRestore
            )
        }
    }
}

struct PhysicalIntegerParameterRow: View {
    let label: String
    let unit: String
    let range: ClosedRange<Int>
    @Binding var value: Int
    let defaultValue: Int
    let onRestore: () -> Void
    var animationArmed: Binding<Bool>? = nil

    var body: some View {
        GridRow(alignment: .center) {
            PhysicalAnimationArmButton(label: label, armed: animationArmed)
            Text(label).frame(minWidth: 116, alignment: .leading)
            Stepper(value: $value, in: range) { EmptyView() }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 4) {
                TextField(label, value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 76)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(label)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary).frame(minWidth: 30, alignment: .leading)
                }
            }
            PhysicalParameterRestoreButton(
                label: label,
                isModified: value != defaultValue,
                action: onRestore
            )
        }
    }
}

struct PhysicalParameterRestoreButton: View {
    let label: String
    let isModified: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .frame(width: 22)
        .disabled(!isModified)
        .opacity(isModified ? 1 : 0)
        .help("Restaurar \(label) al valor del preset")
        .accessibilityLabel("Restaurar \(label) al valor del preset")
        .accessibilityHidden(!isModified)
    }
}

struct PhysicalDerivedRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Color.clear.frame(width: 16, height: 1)
            Text(label)
            Spacer()
            HStack(spacing: 5) {
                Text(value)
                Text("Derivado").font(.caption2).foregroundStyle(.secondary)
            }
            Color.clear.frame(width: 22, height: 1)
        }
    }
}

struct PhysicalAnimationArmButton: View {
    let label: String
    let armed: Binding<Bool>?

    var body: some View {
        if let armed {
            Button {
                armed.wrappedValue.toggle()
            } label: {
                Image(systemName: armed.wrappedValue ? "circle.inset.filled" : "circle")
                    .foregroundStyle(armed.wrappedValue ? NativeTheme.accent : .secondary)
            }
            .buttonStyle(.borderless)
            .frame(width: 16)
            .help(armed.wrappedValue
                ? "Preparado para Animación: \(label)"
                : "Preparar para Animación: \(label)")
            .accessibilityLabel(armed.wrappedValue
                ? "Quitar \(label) de Animación"
                : "Preparar \(label) para Animación")
        } else {
            Color.clear.frame(width: 16, height: 1)
        }
    }
}
