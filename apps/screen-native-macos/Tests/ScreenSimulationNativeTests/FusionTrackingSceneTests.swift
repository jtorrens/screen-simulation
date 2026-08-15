import Foundation
import simd
import Testing
@testable import ScreenSimulationNative

@Test func actualSynthEyesFusionCompositionImportsAtomicSolve() throws {
    guard let path = ProcessInfo.processInfo.environment["SCREEN_SYNTH_EYES_FUSION_COMP"] else { return }
    let scene = try FusionTrackingImporter().load(URL(fileURLWithPath: path))
    let camera = try #require(scene.cameras.first)
    #expect(camera.samples.count == 100)
    #expect(camera.frameRateNumerator == 25)
    #expect(camera.frameRateDenominator == 1)
    #expect(camera.plateWidth == 1920)
    #expect(camera.plateHeight == 1080)
    #expect(abs(camera.focalLengthMillimeters - 39.548260) < 0.000_001)
    if case let .de4RadialStandardDegree4(degree2, degree4) = camera.distortion {
        #expect(abs(degree2 - -0.005811815106) < 1e-12)
        #expect(degree4 == 0)
    } else { Issue.record("La calibración DE4 no se importó.") }
    #expect(scene.pointGroups.contains { $0.points.count == 15 })
    let plane = try #require(scene.meshes.first { $0.label == "Plane01" })
    #expect(plane.faceVertexCounts == [4])
    #expect(plane.faceVertexIndices == [0, 1, 2, 3])
    #expect(plane.triangleIndices.count == 6)
}

@Test func fusionTrackingRejectsUnknownOrContradictoryLensModels() throws {
    guard let path = ProcessInfo.processInfo.environment["SCREEN_SYNTH_EYES_FUSION_COMP"] else { return }
    let source = try String(contentsOfFile: path, encoding: .utf8)
    let unknown = source.replacingOccurrences(of: "DE4RadialStandardDegree4", with: "UnknownLensModel")
    #expect(throws: FusionTrackingError.self) {
        try FusionTrackingImporter().parse(unknown, sourceFileName: "unknown.comp")
    }
    let quartic = "QuarticDistortionDegree4\"] = Input { Value = 0, }"
    let secondNode = try #require(source.range(of: "Cam1ReDis"))
    let quarticRange = try #require(source.range(of: quartic, range: secondNode.lowerBound..<source.endIndex))
    var contradictory = source
    contradictory.replaceSubrange(
        quarticRange,
        with: "QuarticDistortionDegree4\"] = Input { Value = 0.01, }"
    )
    #expect(throws: FusionTrackingError.self) {
        try FusionTrackingImporter().parse(contradictory, sourceFileName: "contradictory.comp")
    }
}

@Test func trackingCameraStartsAtSceneFrameZeroAndInterpolatesByTimelineTime() throws {
    let camera = TrackingCamera(
        id: "camera", label: "Camera", frameRateNumerator: 25, frameRateDenominator: 1,
        focalLengthMillimeters: 40, gateWidthMillimeters: 24, gateHeightMillimeters: 13.5,
        plateWidth: 1920, plateHeight: 1080, distortion: .pinhole,
        samples: [
            .init(frame: 0, sourcePosition: .zero, orientation: .init(0, 0, 0, 1)),
            .init(frame: 1, sourcePosition: .init(1, 0, 0), orientation: .init(0, 0, 0, 1)),
        ]
    )
    #expect(camera.sample(atTimelineFrame: 0, timelineFrameRate: 50)?.sourcePosition.x == 0)
    #expect(camera.sample(atTimelineFrame: 1, timelineFrameRate: 50)?.sourcePosition.x == 0.5)
}

@Test func quadTrackingGeometryProvidesStableCenterWithoutOverlayDiagonal() throws {
    let plane = TrackingMesh(
        id: "Plane", label: "Plane",
        sourceVertices: [.init(-2, -1, 0), .init(2, -1, 0), .init(2, 1, 0), .init(-2, 1, 0)],
        faceVertexCounts: [4], faceVertexIndices: [0, 1, 2, 3]
    )
    let placement = try #require(plane.planePlacement(toward: .init(0, 0, 5)))
    #expect(simd_length(placement.center) < 1e-12)
    #expect(plane.triangleIndices == [0, 1, 2, 0, 2, 3])
}
