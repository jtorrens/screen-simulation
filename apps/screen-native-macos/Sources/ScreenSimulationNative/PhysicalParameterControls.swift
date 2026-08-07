import SwiftUI

enum PhysicalNumericDraftParser {
    static let debounceNanoseconds: UInt64 = 350_000_000

    static func double(
        _ text: String,
        in range: ClosedRange<Double>,
        allowTrailingDecimalSeparator: Bool
    ) -> Double? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        if !allowTrailingDecimalSeparator,
           candidate.last == "." || candidate.last == ","
        {
            return nil
        }
        let normalized = candidate.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, range.contains(value) else {
            return nil
        }
        return value
    }

    static func integer(_ text: String, in range: ClosedRange<Int>) -> Int? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(candidate), range.contains(value) else { return nil }
        return value
    }
}

struct DeferredDoubleTextField: View {
    let label: String
    let range: ClosedRange<Double>
    let fractionDigits: ClosedRange<Int>
    @Binding var value: Double

    @State private var draft: String
    @State private var pendingCommit: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    init(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        fractionDigits: ClosedRange<Int> = 0 ... 6
    ) {
        self.label = label
        _value = value
        self.range = range
        self.fractionDigits = fractionDigits
        _draft = State(initialValue: Self.formatted(
            value.wrappedValue,
            fractionDigits: fractionDigits
        ))
    }

    var body: some View {
        TextField(label, text: $draft)
            .focused($isFocused)
            .onChange(of: draft) { _, _ in scheduleDebouncedCommit() }
            .onChange(of: value) { _, newValue in
                guard !isFocused else { return }
                draft = Self.formatted(newValue, fractionDigits: fractionDigits)
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commitFinalDraft() }
            }
            .onSubmit { commitFinalDraft() }
            .onDisappear { pendingCommit?.cancel() }
    }

    private func scheduleDebouncedCommit() {
        pendingCommit?.cancel()
        let candidate = draft
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: PhysicalNumericDraftParser.debounceNanoseconds
            )
            guard !Task.isCancelled,
                  let parsed = PhysicalNumericDraftParser.double(
                    candidate,
                    in: range,
                    allowTrailingDecimalSeparator: false
                  ), parsed != value
            else { return }
            value = parsed
        }
    }

    private func commitFinalDraft() {
        pendingCommit?.cancel()
        if let parsed = PhysicalNumericDraftParser.double(
            draft,
            in: range,
            allowTrailingDecimalSeparator: true
        ) {
            if parsed != value { value = parsed }
            draft = Self.formatted(parsed, fractionDigits: fractionDigits)
        } else {
            draft = Self.formatted(value, fractionDigits: fractionDigits)
        }
    }

    private static func formatted(
        _ value: Double,
        fractionDigits: ClosedRange<Int>
    ) -> String {
        value.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(fractionDigits))
        )
    }
}

struct DeferredIntegerTextField: View {
    let label: String
    let range: ClosedRange<Int>
    @Binding var value: Int

    @State private var draft: String
    @State private var pendingCommit: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>) {
        self.label = label
        _value = value
        self.range = range
        _draft = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        TextField(label, text: $draft)
            .focused($isFocused)
            .onChange(of: draft) { _, _ in scheduleDebouncedCommit() }
            .onChange(of: value) { _, newValue in
                guard !isFocused else { return }
                draft = String(newValue)
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commitFinalDraft() }
            }
            .onSubmit { commitFinalDraft() }
            .onDisappear { pendingCommit?.cancel() }
    }

    private func scheduleDebouncedCommit() {
        pendingCommit?.cancel()
        let candidate = draft
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: PhysicalNumericDraftParser.debounceNanoseconds
            )
            guard !Task.isCancelled,
                  let parsed = PhysicalNumericDraftParser.integer(candidate, in: range),
                  parsed != value
            else { return }
            value = parsed
        }
    }

    private func commitFinalDraft() {
        pendingCommit?.cancel()
        if let parsed = PhysicalNumericDraftParser.integer(draft, in: range) {
            if parsed != value { value = parsed }
            draft = String(parsed)
        } else {
            draft = String(value)
        }
    }
}

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
                DeferredDoubleTextField(
                    label,
                    value: $value,
                    in: range
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
                DeferredIntegerTextField(label, value: $value, in: range)
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
