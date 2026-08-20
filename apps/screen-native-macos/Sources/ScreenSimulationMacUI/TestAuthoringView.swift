import ScreenSimulationPresentation
import SwiftUI

public struct TestAuthoringView: View {
    private let state: TestPagePresentation
    private let onIntent: (TestControlIntent) -> Void
    private let onScalarEditingChanged: (String, Bool) -> Void
    private let excludedControlIDs: Set<String>
    private let showsGeneral: Bool
    private let showsInspectorGroups: Bool
    private let supplementarySectionContent: [String: AnyView]

    public init(
        state: TestPagePresentation,
        excludedControlIDs: Set<String> = [],
        showsGeneral: Bool = true,
        showsInspectorGroups: Bool = true,
        supplementarySectionContent: [String: AnyView] = [:],
        onScalarEditingChanged: @escaping (String, Bool) -> Void = { _, _ in },
        onIntent: @escaping (TestControlIntent) -> Void
    ) {
        self.state = state
        self.excludedControlIDs = excludedControlIDs
        self.showsGeneral = showsGeneral
        self.showsInspectorGroups = showsInspectorGroups
        self.supplementarySectionContent = supplementarySectionContent
        self.onScalarEditingChanged = onScalarEditingChanged
        self.onIntent = onIntent
    }

    public var body: some View {
        VStack(spacing: 12) {
            if showsGeneral, !quickControls.isEmpty {
                TestPhaseCard(label: "General") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        ForEach(quickControls) { control in
                            controlView(control)
                        }
                    }
                }
            }
            if showsInspectorGroups {
                ForEach(state.inspectorGroups) { group in
                    inspectorGroup(group)
                }
            }
        }
    }

    private var allControls: [TestControlDescriptor] {
        state.phases
            .flatMap { $0.sections.flatMap(\.controls) }
            .filter { !excludedControlIDs.contains($0.id) }
    }

    private var quickControls: [TestControlDescriptor] {
        state.quickControlIDs.compactMap { id in allControls.first { $0.id == id } }
    }

    private func inspectorGroup(_ group: TestInspectorGroupPresentation) -> some View {
        TestPhaseCard(label: group.label) {
            VStack(spacing: 8) {
                ForEach(group.sections) { section in
                    let controls = section.controls.filter {
                        !excludedControlIDs.contains($0.id)
                    }
                    let supplement = supplementarySectionContent[section.id]
                    if !controls.isEmpty || supplement != nil {
                        TestInspectorSubcard(label: section.label) {
                            VStack(alignment: .leading, spacing: 10) {
                                if let supplement { supplement }
                                if !controls.isEmpty {
                                    Grid(
                                        alignment: .leading,
                                        horizontalSpacing: 12,
                                        verticalSpacing: 8
                                    ) {
                                        ForEach(controls) { controlView($0) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func headerControlView(_ descriptor: TestControlDescriptor) -> some View {
        if case let .scalar(control) = descriptor {
            HStack(spacing: 6) {
                Text("Carácter").font(.caption)
                Slider(
                    value: Binding(
                        get: { control.value },
                        set: {
                            onIntent(.setScalar(
                                controlID: control.id,
                                value: snapped($0, for: control)
                            ))
                        }
                    ),
                    in: control.minimum...control.maximum,
                    onEditingChanged: {
                        onScalarEditingChanged(control.id, $0)
                    }
                )
                .frame(width: 92)
                DebouncedTestScalarField(control: control) { value in
                    onIntent(.setScalar(controlID: control.id, value: value))
                }
                .frame(width: 58)
                resetButton(disabled: control.value == control.resetValue) {
                    onIntent(.reset(controlID: control.id))
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
                    onIntent(.reset(controlID: control.id))
                }
            }
        case let .scalar(control):
            GridRow {
                controlLabel(control.label)
                if control.sliderVisible, control.minimum < control.maximum {
                    Slider(
                        value: Binding(
                            get: { control.value },
                            set: { onIntent(.setScalar(
                                controlID: control.id,
                                value: snapped($0, for: control)
                            )) }
                        ),
                        in: control.minimum...control.maximum,
                        onEditingChanged: {
                            onScalarEditingChanged(control.id, $0)
                        }
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
                    onIntent(.reset(controlID: control.id))
                }
            }
        case let .toggle(control):
            GridRow {
                controlLabel(control.label)
                Color.clear.frame(width: 150, height: 1)
                Toggle("", isOn: Binding(
                    get: { control.value },
                    set: { onIntent(.setToggle(controlID: control.id, value: $0)) }
                ))
                .labelsHidden()
                .frame(width: 108, alignment: .leading)
                Text("").frame(width: 52)
                resetButton(disabled: control.value == control.resetValue) {
                    onIntent(.reset(controlID: control.id))
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

    private func snapped(_ value: Double, for control: TestScalarControl) -> Double {
        let steps = ((value - control.minimum) / control.step).rounded()
        return min(control.maximum, max(control.minimum, control.minimum + steps * control.step))
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
                HStack {
                    Text(phase.label)
                    Spacer()
                    Text(phase.calculationDomain)
                        .foregroundStyle(.secondary)
                }
                .tag(phase.id)
            }
        }
        if let phase = state.phases.first(where: { $0.id == state.selectedPhaseID }) {
            Text("Vista: \(phase.previewRoute)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    ForEach(control.options.filter { option in
                        state.visiblePreviewChoiceIDs.isEmpty
                            || state.visiblePreviewChoiceIDs.contains(option.id)
                    }) { option in
                        Text(option.label).tag(option.id)
                    }
                }
                .labelsHidden()
            }
        }
    }
}

public struct TestPhaseCard<Content: View>: View {
    private let label: String
    private let effectSummary: String
    private let headerControl: AnyView?
    private let content: Content
    @State private var expanded: Bool

    public init(
        label: String,
        effectSummary: String = "",
        headerControl: AnyView? = nil,
        initiallyExpanded: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.effectSummary = effectSummary
        self.headerControl = headerControl
        self.content = content()
        _expanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(label).font(.headline)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                                .foregroundStyle(.secondary)
                        }
                        if !effectSummary.isEmpty {
                            Text(effectSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expandido" : "Contraído")
                if expanded {
                    if let headerControl {
                        headerControl.padding(.top, 10)
                    }
                    content
                        .padding(.top, 10)
                }
            }
        }
    }
}

private struct TestInspectorSubcard<Content: View>: View {
    let label: String
    let content: Content
    @State private var expanded = true

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack {
                    Text(label).font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                content.padding(.top, 8)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }
}
