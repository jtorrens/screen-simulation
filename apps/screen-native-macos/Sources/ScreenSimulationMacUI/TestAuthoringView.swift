import ScreenSimulationPresentation
import SwiftUI

public struct TestAuthoringView: View {
    private let state: TestPagePresentation
    private let onIntent: (TestControlIntent) -> Void

    public init(
        state: TestPagePresentation,
        onIntent: @escaping (TestControlIntent) -> Void
    ) {
        self.state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        VStack(spacing: 12) {
            ForEach(state.phases.filter { phase in
                phase.sections.contains { !$0.controls.isEmpty }
            }) { phase in
                TestPhaseCard(
                    label: phase.label,
                    characterScaleNote: phase.characterScaleNote
                ) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(phase.sections) { section in
                            if !section.label.isEmpty {
                                Text(section.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                ForEach(section.controls) { control in
                                    controlView(control)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func controlView(_ descriptor: TestControlDescriptor) -> some View {
        switch descriptor {
        case let .choice(control):
            GridRow {
                controlLabel(control.label)
                Color.clear.frame(width: 150, height: 1)
                Picker(control.label, selection: Binding(
                    get: { control.selectedID },
                    set: {
                        onIntent(.setChoice(controlID: control.id, optionID: $0))
                    }
                )) {
                    ForEach(control.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(width: 108)
                Text("").frame(width: 52)
                resetButton(disabled: control.selectedID == control.resetID) {
                    onIntent(.setChoice(controlID: control.id, optionID: control.resetID))
                }
            }
        case let .scalar(control):
            GridRow {
                controlLabel(control.label)
                if control.minimum < control.maximum {
                    Slider(
                        value: Binding(
                            get: { control.value },
                            set: {
                                onIntent(.setScalar(controlID: control.id, value: $0))
                            }
                        ),
                        in: control.minimum...control.maximum,
                        step: control.step
                    )
                    .frame(width: 150)
                } else {
                    Color.clear.frame(width: 150, height: 1)
                }
                DebouncedTestScalarField(control: control) { value in
                    onIntent(.setScalar(controlID: control.id, value: value))
                }
                .frame(width: 108)
                Text(control.unit)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                resetButton(disabled: control.value == control.resetValue) {
                    onIntent(.setScalar(controlID: control.id, value: control.resetValue))
                }
            }
        case let .action(control):
            GridRow {
                controlLabel("")
                Color.clear.frame(width: 150, height: 1)
                Button(control.label) {
                    onIntent(.performAction(controlID: control.id))
                }
                Text("").frame(width: 52)
                Color.clear.frame(width: 18, height: 1)
            }
        case let .readOnly(control):
            GridRow {
                controlLabel(control.label)
                Color.clear.frame(width: 150, height: 1)
                Text(control.value).frame(width: 108, alignment: .leading)
                Text("").frame(width: 52)
                Color.clear.frame(width: 18, height: 1)
            }
        }
    }

    private func controlLabel(_ label: String) -> some View {
        Text(label)
            .frame(width: 122, alignment: .leading)
    }

    private func resetButton(
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help("Restaurar valor predeterminado")
        .frame(width: 18)
    }
}

private struct DebouncedTestScalarField: View {
    let control: TestScalarControl
    let onCommit: (Double) -> Void

    @State private var draft: String
    @State private var pendingCommit: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(control: TestScalarControl, onCommit: @escaping (Double) -> Void) {
        self.control = control
        self.onCommit = onCommit
        _draft = State(initialValue: Self.format(control.value))
    }

    var body: some View {
        TextField(control.unit, text: $draft)
            .focused($focused)
            .frame(maxWidth: .infinity)
            .onSubmit { commitOrRestore() }
            .onChange(of: draft) { _, _ in
                guard focused else { return }
                scheduleCommit()
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commitOrRestore() }
            }
            .onChange(of: control.value) { _, value in
                guard !focused else { return }
                draft = Self.format(value)
            }
            .onDisappear { pendingCommit?.cancel() }
    }

    private func scheduleCommit() {
        pendingCommit?.cancel()
        pendingCommit = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            commitIfValid()
        }
    }

    private func commitOrRestore() {
        pendingCommit?.cancel()
        if !commitIfValid() {
            draft = Self.format(control.value)
        }
    }

    @discardableResult
    private func commitIfValid() -> Bool {
        guard let value = Self.parse(draft),
              value.isFinite,
              control.minimum...control.maximum ~= value
        else { return false }
        if value != control.value { onCommit(value) }
        return true
    }

    private static func parse(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        return formatter.number(from: text)?.doubleValue
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }
}

public struct TestPhasePicker: View {
    private let state: TestPagePresentation
    private let onIntent: (TestControlIntent) -> Void

    public init(
        state: TestPagePresentation,
        onIntent: @escaping (TestControlIntent) -> Void
    ) {
        self.state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        Picker("Ver hasta", selection: Binding(
            get: { state.selectedPhaseID },
            set: { onIntent(.selectPhase($0)) }
        )) {
            ForEach(state.phases) { phase in
                Text(phase.label).tag(phase.id)
            }
        }
    }
}

public struct TestPreviewControls: View {
    private let state: TestPagePresentation
    private let onIntent: (TestControlIntent) -> Void

    public init(
        state: TestPagePresentation,
        onIntent: @escaping (TestControlIntent) -> Void
    ) {
        self.state = state
        self.onIntent = onIntent
    }

    public var body: some View {
        ForEach(state.previewControls) { descriptor in
            if case let .choice(control) = descriptor {
                Picker(control.label, selection: Binding(
                    get: { control.selectedID },
                    set: {
                        onIntent(.setChoice(controlID: control.id, optionID: $0))
                    }
                )) {
                    ForEach(control.options) { option in
                        Text(option.label).tag(option.id)
                    }
                }
            }
        }
    }
}

public struct TestPhaseCard<Content: View>: View {
    private let label: String
    private let characterScaleNote: String?
    private let content: Content
    @State private var expanded: Bool

    public init(
        label: String,
        characterScaleNote: String? = nil,
        initiallyExpanded: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.characterScaleNote = characterScaleNote
        self.content = content()
        _expanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) {
                content
                    .padding(.top, 10)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.headline)
                    if let characterScaleNote {
                        Text(characterScaleNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
