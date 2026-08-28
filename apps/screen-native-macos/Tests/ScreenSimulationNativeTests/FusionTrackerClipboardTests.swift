import CoreGraphics
import Foundation
import Testing
@testable import ScreenSimulationNative

private func trackerFixture(secondPointFrames: String? = nil) -> String {
    let second = secondPointFrames ?? """
        [0] = { 0, },
        [1] = { 0.5, },
        [2] = { 1, },
    """
    return """
    {
      Tools = ordered() {
        Tracker1 = Tracker {
          Trackers = {
            { ID = 0, },
            { ID = 1, }
          },
          Inputs = {
            Name1 = Input { Value = "Punto A", },
            TrackedCenter1 = Input { SourceOp = "PathA", Source = "Position", },
            Name2 = Input { Value = "Punto B", },
            TrackedCenter2 = Input { SourceOp = "PathB", Source = "Position", },
          },
        },
        PathA = PolyPath {
          Inputs = {
            Displacement = Input { SourceOp = "DisplacementA", Source = "Value", },
            PolyLine = Input { Value = Polyline { Points = {
              { Linear = true, X = -0.25, Y = -0.25 },
              { Linear = true, X = -0.20, Y = -0.20 },
              { Linear = true, X = -0.15, Y = -0.15 },
            } } },
          },
        },
        DisplacementA = BezierSpline { KeyFrames = {
          [0] = { 0, }, [1] = { 0.5, }, [2] = { 1, },
        } },
        PathB = PolyPath {
          Inputs = {
            Displacement = Input { SourceOp = "DisplacementB", Source = "Value", },
            PolyLine = Input { Value = Polyline { Points = {
              { Linear = true, X = 0.25, Y = -0.25 },
              { Linear = true, X = 0.30, Y = -0.20 },
              { Linear = true, X = 0.35, Y = -0.15 },
            } } },
          },
        },
        DisplacementB = BezierSpline { KeyFrames = {
          \(second)
        } },
      }
    }
    """
}

@Test func fusionTrackerClipboardParsesLinkedPolyPathsAndExactFrames() throws {
    let tracker = try FusionTrackerClipboardImporter().parse(trackerFixture())
    #expect(tracker.points.count == 2)
    #expect(tracker.frameRange == 0...2)
    #expect(tracker.points[0].label == "Punto A")
    #expect(tracker.points[0].samples[0].position == SIMD2(0.25, 0.25))
    #expect(tracker.points[1].samples[2].position == SIMD2(0.85, 0.35))
}

@Test func fusionTrackerClipboardRejectsMismatchedPointFrameSets() {
    #expect(throws: FusionTrackerClipboardError.self) {
        try FusionTrackerClipboardImporter().parse(trackerFixture(secondPointFrames: """
            [0] = { 0, }, [2] = { 1, },
        """))
    }
}

@Test func savitzkyGolayPreservesQuadraticCurvesExactly() throws {
    let samples = (0..<9).map { frame in
        FusionTrackerSample(
            frame: frame,
            position: SIMD2(Double(frame * frame), Double(2 * frame + 3))
        )
    }
    let tracker = try FusionTrackerClipboard(points: [
        .init(id: "p", label: "P", samples: samples),
    ])
    let smoothed = try tracker.smoothed(window: 5, degree: 2)
    for index in samples.indices {
        #expect(abs(smoothed.points[0].samples[index].position.x - samples[index].position.x) < 1e-9)
        #expect(abs(smoothed.points[0].samples[index].position.y - samples[index].position.y) < 1e-9)
    }
}

@Test func fusionTrackerComponentsKeepXAndYIndependent() throws {
    let base = [
        CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
        CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
    ]
    let anchor = [CGPoint(x: 2, y: 2)]
    let current = [CGPoint(x: 7, y: 9)]
    let xOnly = try FusionTrackerMotionMath.transformedCorners(
        base: base, anchorPoints: anchor, currentPoints: current,
        components: .init(x: true, y: false, scale: false, rotation: false, cornerPin: false)
    )
    #expect(xOnly[0] == CGPoint(x: 5, y: 0))
    let yOnly = try FusionTrackerMotionMath.transformedCorners(
        base: base, anchorPoints: anchor, currentPoints: current,
        components: .init(x: false, y: true, scale: false, rotation: false, cornerPin: false)
    )
    #expect(yOnly[0] == CGPoint(x: 0, y: 7))
}

@Test func fourAssignedCornersProduceProjectiveObservationWithoutPersistingHomography() throws {
    let source = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]
    let destination = [
        CGPoint(x: 2, y: 3), CGPoint(x: 6, y: 2),
        CGPoint(x: 7, y: 8), CGPoint(x: 1, y: 7),
    ]
    let transformed = try FusionTrackerMotionMath.transformedCorners(
        base: source, anchorPoints: source, currentPoints: destination,
        components: .init(x: true, y: true, scale: true, rotation: true, cornerPin: true)
    )
    for index in destination.indices {
        #expect(hypot(
            transformed[index].x - destination[index].x,
            transformed[index].y - destination[index].y
        ) < 1e-9)
    }
    let track = try FusionTrackerPoseTrack(
        target: .camera, anchorFrame: 0,
        frameRateNumerator: 24, frameRateDenominator: 1,
        samples: [.init(frame: 0, position: .zero, orientation: SIMD4(0, 0, 0, 1))]
    )
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any]
    #expect(encoded?["homography"] == nil)
}

@Test func rustResolverAppliesFusionPoseToExactlyTheSelectedRigidBody() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    let base = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    let resolvedPipeline = try base.resolvedPipeline()
    let resolvedDevice = try device.resolved()
    let rate = try ExactFrameRate(numerator: 24, denominator: 1)
    let frame = try PhysicalFrameSelection(
        frameIndex: 1,
        timeNumerator: 1,
        timeDenominator: 24,
        frameRateNumerator: 24,
        frameRateDenominator: 1
    )
    let cameraDestination = SIMD3(
        base.cameraPose.position[0] + 0.1,
        base.cameraPose.position[1] + 0.2,
        base.cameraPose.position[2] + 0.3
    )
    let deviceDestination = SIMD3(
        base.screenPose.position[0] - 0.1,
        base.screenPose.position[1] - 0.2,
        base.screenPose.position[2] - 0.3
    )
    func track(_ target: FusionTrackerTarget, _ destination: SIMD3<Double>) throws
        -> FusionTrackerPoseTrack
    {
        let origin = target == .camera ? base.cameraPose.position : base.screenPose.position
        return try FusionTrackerPoseTrack(
            target: target,
            anchorFrame: 0,
            frameRateNumerator: 24,
            frameRateDenominator: 1,
            samples: [
                .init(
                    frame: 0,
                    position: SIMD3(origin[0], origin[1], origin[2]),
                    orientation: SIMD4(0, 0, 0, 1)
                ),
                .init(frame: 1, position: destination, orientation: SIMD4(0, 0, 0, 1)),
            ]
        )
    }
    let cameraResolver = try RustSceneFrameResolver(
        revision: 1, frameRate: rate, base: base,
        resolvedDevice: resolvedDevice, resolvedPipeline: resolvedPipeline,
        trackingCamera: nil, trackingMetersPerSourceUnit: nil,
        fusionTrackerMotion: try track(.camera, cameraDestination)
    )
    let cameraFrame = try cameraResolver.resolve(frame)
    #expect(abs(Double(cameraFrame.camera_position.0) - cameraDestination.x) < 1e-5)
    #expect(abs(Double(cameraFrame.camera_position.1) - cameraDestination.y) < 1e-5)
    #expect(abs(Double(cameraFrame.camera_position.2) - cameraDestination.z) < 1e-5)
    #expect(abs(Double(cameraFrame.screen_position.0) - base.screenPose.position[0]) < 1e-5)

    let deviceResolver = try RustSceneFrameResolver(
        revision: 2, frameRate: rate, base: base,
        resolvedDevice: resolvedDevice, resolvedPipeline: resolvedPipeline,
        trackingCamera: nil, trackingMetersPerSourceUnit: nil,
        fusionTrackerMotion: try track(.device, deviceDestination)
    )
    let deviceFrame = try deviceResolver.resolve(frame)
    #expect(abs(Double(deviceFrame.screen_position.0) - deviceDestination.x) < 1e-5)
    #expect(abs(Double(deviceFrame.screen_position.1) - deviceDestination.y) < 1e-5)
    #expect(abs(Double(deviceFrame.screen_position.2) - deviceDestination.z) < 1e-5)
    #expect(abs(Double(deviceFrame.camera_position.0) - base.cameraPose.position[0]) < 1e-5)
}
