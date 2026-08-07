import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func physicalDoubleDraftAcceptsSignedAndLocalizedDecimalInput() {
    let range = -2.0 ... 2.0

    #expect(PhysicalNumericDraftParser.double(
        "-0,125",
        in: range,
        allowTrailingDecimalSeparator: false
    ) == -0.125)
    #expect(PhysicalNumericDraftParser.double(
        "+1.75",
        in: range,
        allowTrailingDecimalSeparator: false
    ) == 1.75)
}

@Test func physicalDoubleDraftKeepsIncompleteInputOutOfTheModelUntilFinalCommit() {
    let range = -2.0 ... 2.0

    for draft in ["", "-", "+", ".", ",", "-.", "-,", "1.", "1,"] {
        #expect(PhysicalNumericDraftParser.double(
            draft,
            in: range,
            allowTrailingDecimalSeparator: false
        ) == nil)
    }
    #expect(PhysicalNumericDraftParser.double(
        "1.",
        in: range,
        allowTrailingDecimalSeparator: true
    ) == 1)
    #expect(PhysicalNumericDraftParser.double(
        "1,",
        in: range,
        allowTrailingDecimalSeparator: true
    ) == 1)
}

@Test func physicalNumericDraftRejectsInvalidAndOutOfRangeValues() {
    #expect(PhysicalNumericDraftParser.double(
        "2.01",
        in: -2 ... 2,
        allowTrailingDecimalSeparator: true
    ) == nil)
    #expect(PhysicalNumericDraftParser.double(
        "nan",
        in: -2 ... 2,
        allowTrailingDecimalSeparator: true
    ) == nil)
    #expect(PhysicalNumericDraftParser.integer("-12", in: -20 ... 20) == -12)
    #expect(PhysicalNumericDraftParser.integer("-", in: -20 ... 20) == nil)
    #expect(PhysicalNumericDraftParser.integer("21", in: -20 ... 20) == nil)
}

@Test func physicalInspectorNumericFieldsUseOneDeferredTextEditingRoute() throws {
    #expect(PhysicalNumericDraftParser.debounceNanoseconds == 350_000_000)

    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let sources = tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ScreenSimulationNative")
    let controls = try String(
        contentsOf: sources.appendingPathComponent("PhysicalParameterControls.swift"),
        encoding: .utf8
    )
    let inspector = try String(
        contentsOf: sources.appendingPathComponent("ModelInspectorView.swift"),
        encoding: .utf8
    )

    let controlTextFields = controls.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.filter { $0.hasPrefix("TextField(") }
    let inspectorTextFields = inspector.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
    }.filter { $0.hasPrefix("TextField(") }
    #expect(controlTextFields == [
        "TextField(label, text: $draft)",
        "TextField(label, text: $draft)",
    ])
    #expect(inspectorTextFields.isEmpty)
    #expect(controls.contains("TextField(label, text: $draft)"))
    #expect(controls.contains(".onSubmit { commitFinalDraft() }"))
    #expect(controls.contains("if !focused { commitFinalDraft() }"))
    #expect(inspector.contains("limits.safeRange"))
}
