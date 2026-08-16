import Foundation

public struct TestChoiceOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct TestChoiceControl: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let options: [TestChoiceOption]
    public let selectedID: String
    public let resetID: String

    public init(
        id: String,
        label: String,
        options: [TestChoiceOption],
        selectedID: String,
        resetID: String
    ) {
        self.id = id
        self.label = label
        self.options = options
        self.selectedID = selectedID
        self.resetID = resetID
    }
}

public struct TestScalarControl: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: Double
    public let resetValue: Double
    public let minimum: Double
    public let maximum: Double
    public let step: Double
    public let sliderVisible: Bool
    public let unit: String

    public init(
        id: String,
        label: String,
        value: Double,
        resetValue: Double,
        minimum: Double,
        maximum: Double,
        step: Double,
        sliderVisible: Bool = true,
        unit: String
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.resetValue = resetValue
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.sliderVisible = sliderVisible
        self.unit = unit
    }
}

public struct TestActionControl: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct TestReadOnlyControl: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct TestToggleControl: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let value: Bool
    public let resetValue: Bool

    public init(id: String, label: String, value: Bool, resetValue: Bool) {
        self.id = id
        self.label = label
        self.value = value
        self.resetValue = resetValue
    }
}

public enum TestControlDescriptor: Equatable, Identifiable, Sendable {
    case choice(TestChoiceControl)
    case scalar(TestScalarControl)
    case toggle(TestToggleControl)
    case action(TestActionControl)
    case readOnly(TestReadOnlyControl)

    public var id: String {
        switch self {
        case let .choice(control): control.id
        case let .scalar(control): control.id
        case let .toggle(control): control.id
        case let .action(control): control.id
        case let .readOnly(control): control.id
        }
    }
}

public struct TestControlSection: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let controls: [TestControlDescriptor]

    public init(id: String, label: String, controls: [TestControlDescriptor]) {
        self.id = id
        self.label = label
        self.controls = controls
    }
}

public struct TestPhasePresentation: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let effectSummary: String
    public let headerControlID: String?
    public let inputArtifactID: String
    public let outputArtifactID: String
    public let calculationDomain: String
    public let previewRoute: String
    public let sections: [TestControlSection]

    public init(
        id: String,
        label: String,
        effectSummary: String,
        headerControlID: String? = nil,
        inputArtifactID: String,
        outputArtifactID: String,
        calculationDomain: String,
        previewRoute: String,
        sections: [TestControlSection]
    ) {
        self.id = id
        self.label = label
        self.effectSummary = effectSummary
        self.headerControlID = headerControlID
        self.inputArtifactID = inputArtifactID
        self.outputArtifactID = outputArtifactID
        self.calculationDomain = calculationDomain
        self.previewRoute = previewRoute
        self.sections = sections
    }
}

public struct TestPagePresentation: Equatable, Sendable {
    public let phases: [TestPhasePresentation]
    public let selectedPhaseID: String
    public let previewControls: [TestControlDescriptor]
    public let visiblePreviewChoiceIDs: [String]
    public let quickControlIDs: [String]
    public let featuredPhaseID: String

    public init(
        phases: [TestPhasePresentation],
        selectedPhaseID: String,
        previewControls: [TestControlDescriptor] = [],
        visiblePreviewChoiceIDs: [String] = [],
        quickControlIDs: [String] = [],
        featuredPhaseID: String = ""
    ) throws {
        self.phases = phases
        self.selectedPhaseID = selectedPhaseID
        self.previewControls = previewControls
        self.visiblePreviewChoiceIDs = visiblePreviewChoiceIDs
        self.quickControlIDs = quickControlIDs
        self.featuredPhaseID = featuredPhaseID
        try validate()
    }

    public func validate() throws {
        guard !phases.isEmpty,
              phases.allSatisfy({
                  !$0.id.isEmpty && !$0.label.isEmpty
                      && !$0.effectSummary.isEmpty
                      && !$0.calculationDomain.isEmpty && !$0.previewRoute.isEmpty
                      && !$0.inputArtifactID.isEmpty && !$0.outputArtifactID.isEmpty
              }),
              Set(phases.map(\.id)).count == phases.count,
              phases.contains(where: { $0.id == selectedPhaseID }),
              featuredPhaseID.isEmpty || phases.contains(where: { $0.id == featuredPhaseID })
        else { throw TestPresentationError.invalidPhases }

        let allControlIDs = Set(phases.flatMap { $0.sections.flatMap(\.controls).map(\.id) })
        guard Set(quickControlIDs).count == quickControlIDs.count,
              quickControlIDs.allSatisfy(allControlIDs.contains)
        else { throw TestPresentationError.invalidControls("quick-controls") }
        let previewOptionIDs = Set(previewControls.compactMap { descriptor -> [String]? in
            if case let .choice(control) = descriptor { return control.options.map(\.id) }
            return nil
        }.flatMap { $0 })
        guard Set(visiblePreviewChoiceIDs).count == visiblePreviewChoiceIDs.count,
              visiblePreviewChoiceIDs.allSatisfy(previewOptionIDs.contains)
        else { throw TestPresentationError.invalidControls("preview-choices") }

        for phase in phases {
            guard phase.sections.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty }),
                  Set(phase.sections.map(\.id)).count == phase.sections.count
            else { throw TestPresentationError.invalidSections(phase.id) }
            let controls = phase.sections.flatMap(\.controls)
            guard controls.allSatisfy({ !$0.id.isEmpty }),
                  Set(controls.map(\.id)).count == controls.count
            else { throw TestPresentationError.invalidControls(phase.id) }
            for control in controls {
                try control.validate()
            }
        }
        guard previewControls.allSatisfy({ !$0.id.isEmpty }),
              Set(previewControls.map(\.id)).count == previewControls.count
        else { throw TestPresentationError.invalidControls("preview") }
        for control in previewControls { try control.validate() }
    }
}

public enum TestControlIntent: Equatable, Sendable {
    case selectPhase(String)
    case setChoice(controlID: String, optionID: String)
    case setScalar(controlID: String, value: Double)
    case setToggle(controlID: String, value: Bool)
    case performAction(controlID: String)
}

public enum TestPresentationError: Error, Equatable {
    case invalidPhases
    case invalidSections(String)
    case invalidControls(String)
    case invalidChoice(String)
    case invalidScalar(String)
}

private extension TestControlDescriptor {
    func validate() throws {
        switch self {
        case let .choice(control):
            guard !control.label.isEmpty,
                  !control.options.isEmpty,
                  control.options.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty }),
                  Set(control.options.map(\.id)).count == control.options.count,
                  control.options.contains(where: { $0.id == control.selectedID }),
                  control.options.contains(where: { $0.id == control.resetID })
            else { throw TestPresentationError.invalidChoice(control.id) }
        case let .scalar(control):
            guard !control.label.isEmpty,
                  control.value.isFinite,
                  control.resetValue.isFinite,
                  control.minimum.isFinite,
                  control.maximum.isFinite,
                  control.step.isFinite,
                  control.minimum <= control.value,
                  control.value <= control.maximum,
                  control.minimum <= control.resetValue,
                  control.resetValue <= control.maximum,
                  control.minimum <= control.maximum,
                  control.step > 0,
                  !control.unit.isEmpty
            else { throw TestPresentationError.invalidScalar(control.id) }
        case let .toggle(control):
            guard !control.label.isEmpty else {
                throw TestPresentationError.invalidControls(control.id)
            }
        case let .action(control):
            guard !control.label.isEmpty else {
                throw TestPresentationError.invalidControls(control.id)
            }
        case let .readOnly(control):
            guard !control.label.isEmpty else {
                throw TestPresentationError.invalidControls(control.id)
            }
        }
    }
}
