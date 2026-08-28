import Foundation
import Testing
@testable import ScreenSimulationNative

private func opacityTrack(
    _ interpolation: SceneAnimationInterpolation
) -> SceneScalarAnimationTrack {
    .init(
        propertyID: SceneScalarAnimationTrack.simulationOpacityID,
        keyframes: [
            .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                timeNumerator: 0, timeDenominator: 24,
                value: 0, interpolation: interpolation
            ),
            .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                timeNumerator: 24, timeDenominator: 24,
                value: 1, interpolation: .hold
            ),
        ]
    )
}

@Test func simulationOpacityUsesTheRustExactTimeEvaluator() throws {
    let descriptor = SimulationOpacityResolver.presentation
    #expect(descriptor.propertyID == "simulation-opacity")
    #expect(descriptor.displayName == "Opacidad")
    #expect(descriptor.minimum == 0)
    #expect(descriptor.maximum == 1)
    #expect(descriptor.defaultValue == 1)
    #expect(descriptor.defaultInterpolation == .smooth)
    #expect(descriptor.supportedInterpolations == [.hold, .linear, .smooth])
    #expect(try SimulationOpacityResolver.resolve(
        track: opacityTrack(.hold), timeNumerator: 6, timeDenominator: 24
    ) == 0)
    #expect(try SimulationOpacityResolver.resolve(
        track: opacityTrack(.linear), timeNumerator: 6, timeDenominator: 24
    ) == 0.25)
    #expect(try SimulationOpacityResolver.resolve(
        track: opacityTrack(.smooth), timeNumerator: 6, timeDenominator: 24
    ) == 0.15625)
}

@Test func sceneAnimationRoundTripsOnlyItsCurrentStrictContract() throws {
    let document = SceneAnimationDocument(scalarTracks: [opacityTrack(.linear)])
    try document.validate()
    let data = try JSONEncoder().encode(document)
    let decoded = try JSONDecoder().decode(SceneAnimationDocument.self, from: data)
    try decoded.validate()
    #expect(decoded == document)
    let object = try JSONSerialization.jsonObject(with: data)
    #expect(SceneAnimationDocument.hasStrictShape(object))

    var unknown = try #require(object as? [String: Any])
    unknown["legacyOpacity"] = 1
    #expect(!SceneAnimationDocument.hasStrictShape(unknown))
}

@Test func animationRejectsDuplicateKeysUnorderedTimesAndOutOfRangeValues() {
    let duplicatedID = UUID()
    let duplicate = SceneAnimationDocument(scalarTracks: [.init(
        propertyID: SceneScalarAnimationTrack.simulationOpacityID,
        keyframes: [
            .init(id: duplicatedID, timeNumerator: 0, timeDenominator: 1,
                  value: 0, interpolation: .linear),
            .init(id: duplicatedID, timeNumerator: 1, timeDenominator: 1,
                  value: 1, interpolation: .hold),
        ]
    )])
    #expect(throws: (any Error).self) { try duplicate.validate() }

    let unordered = SceneAnimationDocument(scalarTracks: [.init(
        propertyID: SceneScalarAnimationTrack.simulationOpacityID,
        keyframes: [
            .init(timeNumerator: 1, timeDenominator: 1, value: 0, interpolation: .linear),
            .init(timeNumerator: 0, timeDenominator: 1, value: 1, interpolation: .hold),
        ]
    )])
    #expect(throws: (any Error).self) { try unordered.validate() }

    let outOfRange = SceneAnimationDocument(scalarTracks: [.init(
        propertyID: SceneScalarAnimationTrack.simulationOpacityID,
        keyframes: [.init(
            timeNumerator: 0, timeDenominator: 1, value: 1.01, interpolation: .hold
        )]
    )])
    #expect(throws: (any Error).self) { try outOfRange.validate() }
}

@Test func zeroShortcutIsExactAndFractionalOpacityScalesRGBAndMatteTogether() throws {
    #expect(!SimulationOpacityResolver.requiresPhysicalEvaluation(0))
    #expect(SimulationOpacityResolver.requiresPhysicalEvaluation(Double.leastNonzeroMagnitude))
    var rgba: [Float] = [-0.5, 2, 0.25, 0.75]
    try SimulationOpacityResolver.apply(0.5, to: &rgba)
    #expect(rgba == [-0.25, 1, 0.125, 0.375])

    let sparse = FusionRawPhysicalFrame(
        width: 2, height: 2,
        activeRect: .init(x: 0, y: 0, width: 2, height: 2),
        deviceRGBA: [], simulationOpacity: 0
    )
    try sparse.validate()
    #expect(throws: (any Error).self) {
        try FusionRawPhysicalFrame(
            width: 2, height: 2,
            activeRect: .init(x: 0, y: 0, width: 2, height: 2),
            deviceRGBA: [], simulationOpacity: Double.leastNonzeroMagnitude
        ).validate()
    }
}
