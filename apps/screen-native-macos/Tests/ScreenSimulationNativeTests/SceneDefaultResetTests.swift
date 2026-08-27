import Foundation
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@MainActor
@Test func sceneDefaultResetPreservesOnlySourceAndReference() throws {
    let library = GlobalLibraryDocument()
    try library.validate()
    let device = try #require(library.devices.first?.value)
    let defaults = try RustTestAuthoringCoordinator.defaultSelection(
        profileContext: RustTestAuthoringProfileContext(library: library),
        inputTransformID: "srgb-encoded-rec709",
        deviceID: device.id,
        frameRate: try ExactFrameRate(numerator: 24_000, denominator: 1_001)
    )
    let source = SavedSceneSource(
        kind: .externalMedia,
        patternRawValue: nil,
        assets: [.init(absolutePath: "/Volumes/source/plate.mov")],
        missingMedia: .init(
            originalName: "plate.mov",
            width: 4_096,
            height: 2_160,
            frameRateNumerator: 24_000,
            frameRateDenominator: 1_001,
            frameCount: 240,
            durationNumerator: 10_010,
            durationDenominator: 1_000
        )
    )
    let reference = PhysicalSettingsExchange.ReferenceResource(
        kind: .imageOrVideo,
        fileName: "reference.exr",
        absolutePath: "/Volumes/reference/reference.exr",
        inputTransformID: "acescg",
        alphaMode: StudioAlphaMode.straight.rawValue,
        signalColorModel: StudioSignalColorModel.rgb.rawValue,
        signalMatrix: StudioSignalMatrix.bt709.rawValue,
        signalRange: StudioSignalRange.full.rawValue,
        placementID: "fill-crop",
        corners: [
            .init(x: 0.1, y: 0.2), .init(x: 0.9, y: 0.2),
            .init(x: 0.9, y: 0.8), .init(x: 0.1, y: 0.8),
        ]
    )
    let camera = TrackingCamera(
        id: "camera", label: "Camera",
        frameRateNumerator: 24_000, frameRateDenominator: 1_001,
        focalLengthMillimeters: 40,
        gateWidthMillimeters: 24, gateHeightMillimeters: 13.5,
        plateWidth: 1_920, plateHeight: 1_080,
        distortion: .pinhole,
        samples: [
            .init(frame: 0, sourcePosition: .zero, orientation: .init(0, 0, 0, 1)),
            .init(frame: 1, sourcePosition: .init(1, 0, 0), orientation: .init(0, 0, 0, 1)),
        ]
    )
    let pointGroup = TrackingPointGroup(
        id: "points", label: "Points",
        points: [.init(id: "point", label: "Point", sourcePosition: .zero)]
    )
    let tracking = SavedTrackingScene(
        scene: .init(cameras: [camera], pointGroups: [pointGroup], meshes: []),
        cameraID: camera.id,
        pointGroupID: pointGroup.id,
        visibleMeshIDs: [],
        pointsVisible: true,
        geometryVisible: true,
        cameraEnabled: true,
        calibration: .init(unitValue: 1, unit: "m", metersPerSourceUnit: 1)
    )
    let original = SavedSceneSnapshot(
        source: source,
        currentFrame: 87,
        viewerZoom: 2.5,
        viewerPanX: 31,
        viewerPanY: -12,
        viewerIsFitted: false,
        authoring: .init(
            profiles: .init(
                deviceID: defaults.deviceID,
                coverGlassID: defaults.coverGlassPresetID,
                captureID: defaults.capturePresetID,
                lensID: defaults.lensPresetID,
                environmentID: defaults.environmentSourceID,
                deliveryID: defaults.deliveryPresetID,
                recordingID: defaults.recordingProfileID
            ),
            overrides: [.scalar("camera-position-x-meters", 7)],
            modelOverrides: .init(screen: nil, stages: []),
            context: .init(
                sourceInputTransformID: "srgb-encoded-rec709",
                sourceAlphaMode: StudioAlphaMode.premultiplied.rawValue,
                sourceColorModel: StudioSignalColorModel.rgb.rawValue,
                sourceYUVMatrix: StudioSignalMatrix.bt709.rawValue,
                sourceSignalRange: StudioSignalRange.full.rawValue,
                sourcePlacementID: "one-to-one",
                previewOutputTransformID: "aces2-rec2100-pq-1000",
                previewPhaseID: "panel-emission",
                referencePlateID: "video-reference",
                environmentResource: .init(
                    kind: .image,
                    fileName: "environment.exr",
                    absolutePath: "/Volumes/environment/environment.exr",
                    inputTransformID: "acescg"
                ),
                referenceResource: reference
            ),
            environmentCalibration: nil
        ),
        generatedEnvironment: .init(
            fileName: "generated.exr",
            sha256: String(repeating: "a", count: 64)
        ),
        tracking: tracking
    )
    try original.validate()

    let reset = try WorkspaceModel.defaultSceneSnapshot(
        preserving: original,
        library: library
    )

    #expect(reset.source == source)
    #expect(reset.authoring.context.sourceInputTransformID == "srgb-encoded-rec709")
    #expect(reset.authoring.context.sourceAlphaMode == StudioAlphaMode.premultiplied.rawValue)
    #expect(reset.authoring.context.sourceColorModel == StudioSignalColorModel.rgb.rawValue)
    #expect(reset.authoring.context.sourceYUVMatrix == StudioSignalMatrix.bt709.rawValue)
    #expect(reset.authoring.context.sourceSignalRange == StudioSignalRange.full.rawValue)
    #expect(reset.authoring.context.sourcePlacementID == "one-to-one")
    #expect(reset.authoring.context.referencePlateID == "video-reference")
    #expect(reset.authoring.context.referenceResource == reference)

    #expect(reset.authoring.profiles.deviceID == defaults.deviceID)
    #expect(reset.authoring.profiles.coverGlassID == defaults.coverGlassPresetID)
    #expect(reset.authoring.profiles.captureID == defaults.capturePresetID)
    #expect(reset.authoring.profiles.lensID == defaults.lensPresetID)
    #expect(reset.authoring.profiles.environmentID == defaults.environmentSourceID)
    #expect(reset.authoring.profiles.deliveryID == defaults.deliveryPresetID)
    #expect(reset.authoring.profiles.recordingID == defaults.recordingProfileID)
    #expect(reset.authoring.overrides.isEmpty)
    #expect(reset.authoring.modelOverrides.screen == nil)
    #expect(reset.authoring.modelOverrides.stages.isEmpty)
    #expect(
        reset.authoring.context.environmentResource.kind
            == PhysicalSettingsExchange.EnvironmentResource.Kind.procedural
    )
    #expect(reset.authoring.environmentCalibration == nil)
    #expect(reset.generatedEnvironment == nil)
    #expect(reset.tracking == nil)
    #expect(reset.currentFrame == 0)
    #expect(reset.viewerZoom == 1)
    #expect(reset.viewerPanX == 0)
    #expect(reset.viewerPanY == 0)
    #expect(reset.viewerIsFitted)
}
