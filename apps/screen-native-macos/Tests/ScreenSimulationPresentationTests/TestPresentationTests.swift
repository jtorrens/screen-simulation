import Testing
@testable import ScreenSimulationPresentation

@Test func presentationRejectsDuplicatePhaseAndControlIdentities() throws {
    let duplicateControls = TestControlSection(
        id: "source",
        label: "Fuente",
        controls: [
            .readOnly(.init(id: "same", label: "A", value: "1")),
            .readOnly(.init(id: "same", label: "B", value: "2")),
        ]
    )
    #expect(throws: TestPresentationError.self) {
        try TestPagePresentation(
            phases: [
                .init(
                    id: "phase", label: "Phase", effectSummary: "Effect",
                    inputArtifactID: "input-v1", outputArtifactID: "output-v1",
                    sections: [duplicateControls]
                ),
            ],
            selectedPhaseID: "phase"
        )
    }
}

@Test func presentationRejectsInvalidScalarAndChoiceContracts() throws {
    let invalidScalar = TestScalarControl(
        id: "white",
        label: "White",
        value: 351,
        resetValue: 350,
        minimum: 100,
        maximum: 350,
        step: 1,
        unit: "cd/m²"
    )
    let invalidChoice = TestChoiceControl(
        id: "mode",
        label: "Mode",
        options: [.init(id: "srgb", label: "sRGB")],
        selectedID: "unknown",
        resetID: "srgb"
    )
    for control in [
        TestControlDescriptor.scalar(invalidScalar),
        TestControlDescriptor.choice(invalidChoice),
    ] {
        #expect(throws: TestPresentationError.self) {
            try TestPagePresentation(
                phases: [
                    .init(
                        id: "phase",
                        label: "Phase",
                        effectSummary: "Effect",
                        inputArtifactID: "input-v1",
                        outputArtifactID: "output-v1",
                        sections: [.init(id: "section", label: "Section", controls: [control])]
                    ),
                ],
                selectedPhaseID: "phase"
            )
        }
    }
}

@Test func presentationAcceptsADeviceCapabilityWithOneFixedScalarValue() throws {
    let fixedWhite = TestControlDescriptor.scalar(.init(
        id: "white",
        label: "White Luminance",
        value: 350,
        resetValue: 350,
        minimum: 350,
        maximum: 350,
        step: 1,
        unit: "cd/m²"
    ))
    _ = try TestPagePresentation(
        phases: [
            .init(
                id: "device", label: "Device", effectSummary: "Effect",
                inputArtifactID: "acescg-v1", outputArtifactID: "device-signal-v1",
                sections: [.init(id: "parameters", label: "Parameters", controls: [fixedWhite])]
            ),
        ],
        selectedPhaseID: "device"
    )
}
