import Foundation
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@MainActor @Test func historicalRerenderAcceptsEveryTerminalQueueState() {
    typealias State = NativeOutputQueueController.RenderJob.State
    #expect(WorkspaceModel.isHistoricalRerenderEligible(State.completed))
    #expect(WorkspaceModel.isHistoricalRerenderEligible(State.failed))
    #expect(WorkspaceModel.isHistoricalRerenderEligible(State.cancelled))
    #expect(!WorkspaceModel.isHistoricalRerenderEligible(State.pending))
    #expect(!WorkspaceModel.isHistoricalRerenderEligible(State.rendering))
}

@MainActor @Test func savedSyntheticSceneUsesItsTrackingTimelineForRenderAll() throws {
    let camera = TrackingCamera(
        id: "Cam1", label: "Cam1",
        frameRateNumerator: 25, frameRateDenominator: 1,
        focalLengthMillimeters: 40,
        gateWidthMillimeters: 24, gateHeightMillimeters: 13.5,
        plateWidth: 1920, plateHeight: 1080,
        distortion: .pinhole,
        samples: (0 ..< 100).map { frame in
            .init(
                frame: frame,
                sourcePosition: .init(Double(frame), 0, 0),
                orientation: .init(0, 0, 0, 1)
            )
        }
    )
    let tracking = SavedTrackingScene(
        scene: .init(
            cameras: [camera],
            pointGroups: [.init(id: "cloud", label: "Cloud", points: [])],
            meshes: []
        ),
        cameraID: camera.id, pointGroupID: "cloud", visibleMeshIDs: [],
        pointsVisible: true, geometryVisible: true, cameraEnabled: true,
        calibration: .init(unitValue: 1, unit: "m", metersPerSourceUnit: 1)
    )
    let timeline = try WorkspaceModel.savedRenderTimeline(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [], missingMedia: nil
        ),
        tracking: tracking,
        fusionTrackerMotion: nil,
        trackingSceneMethod: .fusionComposition
    )
    let expectedRate = try StudioFrameRate(numerator: 25, denominator: 1)
    #expect(timeline.exactFrameRate == expectedRate)
    #expect(timeline.frameCount == 100)

    let motion = try FusionTrackerPoseTrack(
        target: .camera, anchorFrame: 0,
        frameRateNumerator: 24, frameRateDenominator: 1,
        samples: [
            .init(frame: 0, position: SIMD3(0, 0, 1), orientation: SIMD4(0, 0, 0, 1)),
            .init(frame: 199, position: SIMD3(1, 0, 1), orientation: SIMD4(0, 0, 0, 1)),
        ]
    )
    let fusionTimeline = try WorkspaceModel.savedRenderTimeline(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [], missingMedia: nil
        ),
        tracking: tracking,
        fusionTrackerMotion: motion,
        trackingSceneMethod: .fusionComposition
    )
    #expect(fusionTimeline.exactFrameRate == expectedRate)
    #expect(fusionTimeline.frameCount == 100)

    let trackerTimeline = try WorkspaceModel.savedRenderTimeline(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [], missingMedia: nil
        ),
        tracking: tracking,
        fusionTrackerMotion: motion,
        trackingSceneMethod: .fusionTrackerClipboard
    )
    #expect(trackerTimeline.exactFrameRate == .fps24)
    #expect(trackerTimeline.frameCount == 200)
}

@MainActor @Test func rerenderRestoresAuthoredDirectoryNameAndVersion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-rerender-output-identity-\(UUID().uuidString)")
    let configuration = try derivationConfiguration(format: .h264High)
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    let model = WorkspaceModel()

    model.renderOutputDirectoryPath = "/tmp/another-output"
    model.renderJobName = "Other"
    model.renderVersionSuffix = "_other"
    model.configureRerender(from: configuration, outputPlan: plan)

    #expect(model.renderOutputDirectoryPath == root.path)
    #expect(model.renderJobName == "Shot")
    #expect(model.renderVersionSuffix == "_v12")
}

@MainActor @Test func editorialOutputSeedsEditableResolveFriendlySettings() {
    let model = WorkspaceModel()
    model.applyRenderPreset(StudioRenderPreset.builtIns.last!)
    #expect(model.renderMode == .final)
    #expect(model.renderComposition == .deviceAndSpillSeparate)
    #expect(model.renderSpillDeliveryMode == .editorialEncodedAdd)
    #expect(model.renderMotionBlurMode == .approximate2D)
    #expect(model.outputFormat == .proRes4444XQ)
    #expect(model.outputPixelEncoding == .rgb44412)
    #expect(model.outputSignalRange == .full)
    #expect(model.vfxInterchangeEncodingID
        == StudioVFXEditorialDeliveryContract.colorEncodingID)
    #expect(!model.includeAudio)
    #expect(model.renderWIPReviewPreset == nil)

    model.vfxInterchangeEncodingID = StudioVFXEditorialDeliveryContract.rec709ColorEncodingID
    #expect(model.effectiveRenderTarget == .sdr)

    model.applyRenderPreset(StudioRenderPreset.builtIns[0])
    #expect(model.renderMode == .final)
    #expect(model.renderPreset.target == .sdr)
    #expect(model.renderSpillDeliveryMode == .editorialEncodedAdd)
}

@MainActor @Test func rec709EditorialRerenderRestoresTheEditableODTChoice() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-editorial-rec709-rerender-\(UUID().uuidString)")
    let configuration = StudioResolvedRenderConfiguration(
        renderMode: .final, jobName: "Editorial", versionSuffix: "_rec709",
        overwritePolicy: .failIfExists, fusionScene: nil,
        composition: .deviceAndSpillSeparate,
        spillDeliveryMode: .editorialEncodedAdd,
        motionBlurMode: .approximate2D, motionSamples: 8,
        raster: .init(width: 1920, height: 1080, placementID: "fit"),
        format: .proRes4444XQ, pipeline: .aces, target: .sdr,
        peakNits: StudioVFXEditorialDeliveryContract.rec709PeakNits,
        display: StudioVFXEditorialDeliveryContract.rec709Display,
        view: StudioVFXEditorialDeliveryContract.rec709View,
        vfxInterchangeEncodingID: StudioVFXEditorialDeliveryContract.rec709ColorEncodingID,
        pixelEncoding: .rgb44412, signalRange: .full, alpha: .straight,
        includeAudio: false, frameRate: .fps24, firstFrame: 0, lastFrame: 0
    )
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    let model = WorkspaceModel()

    model.configureRerender(from: configuration, outputPlan: plan)
    model.ensureRenderOptionsCompatible()

    #expect(model.renderPreset.target == .sdr)
    #expect(model.vfxInterchangeEncodingID
        == StudioVFXEditorialDeliveryContract.rec709ColorEncodingID)
    #expect(model.effectiveRenderTarget == .sdr)
    #expect(model.renderSpillDeliveryMode == .editorialEncodedAdd)
}

@Test func authoredNameAndVersionProduceTheExactMovieAndSequenceManifests() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-authored-output-name-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let movie = try RenderOutputPlan.prepare(
        configuration: derivationConfiguration(format: .h264High),
        selectedDestination: root
    )
    #expect(movie.destination == root.appendingPathComponent("Shot_v12.mp4"))
    let sequence = try RenderOutputPlan.prepare(
        configuration: derivationConfiguration(format: .tiff16),
        selectedDestination: root
    )
    #expect(sequence.destination == root)
    #expect(sequence.generatedRelativePaths == [
        "Shot_v1200000001.tiff", "Shot_v1200000002.tiff",
    ])
}

@Test func authoredNameAndVersionKeepDeviceAndSpillRoleSuffixes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-authored-role-name-\(UUID().uuidString)")
    let rate = try StudioFrameRate(numerator: 24, denominator: 1)
    let separated = StudioResolvedRenderConfiguration(
        renderMode: .final, jobName: "Shot", versionSuffix: "_v12", overwritePolicy: .failIfExists,
        fusionScene: nil, composition: .deviceAndSpillSeparate,
        spillDeliveryMode: .physicalLinear,
        motionBlurMode: .disabled, motionSamples: 2, raster: .init(width: 1920, height: 1080, placementID: "fit"), format: .tiff16,
        pipeline: .aces, target: .sdr, peakNits: 100,
        display: "Rec.1886 Rec.709 - Display",
        view: "ACES 2.0 - SDR 100 nits (Rec.709)",
        vfxInterchangeEncodingID: nil, pixelEncoding: .rgb16,
        signalRange: .full, alpha: .straight, includeAudio: false,
        frameRate: rate, firstFrame: 1, lastFrame: 2
    )
    let separatedPlan = try RenderOutputPlan.prepare(
        configuration: separated, selectedDestination: root
    )
    #expect(separatedPlan.destination == root)
    #expect(separatedPlan.generatedRelativePaths == [
        "Shot_v12_Device00000001.tiff", "Shot_v12_Spill00000001.tiff",
        "Shot_v12_Device00000002.tiff", "Shot_v12_Spill00000002.tiff",
    ])

    let fusion = StudioResolvedRenderConfiguration(
        renderMode: .final, jobName: "Shot", versionSuffix: "_v12", overwritePolicy: .failIfExists,
        fusionScene: .init(
            dofMode: .disabled, resolutionMode: .nativeDevice,
            customActiveWidth: nil, customActiveHeight: nil,
            spillThresholdSceneLinear: 0.001, spillFadeWidthPixels: 0
        ), composition: .deviceAndSpillTogether,
        spillDeliveryMode: .physicalLinear,
        motionBlurMode: .disabled, motionSamples: 2, raster: .init(width: 1920, height: 1080, placementID: "fit"), format: .tiff16,
        pipeline: .aces, target: .sdr, peakNits: 100,
        display: "Rec.1886 Rec.709 - Display",
        view: "ACES 2.0 - SDR 100 nits (Rec.709)",
        vfxInterchangeEncodingID: nil, pixelEncoding: .rgb16,
        signalRange: .full, alpha: .straight, includeAudio: false,
        frameRate: rate, firstFrame: 1, lastFrame: 2
    )
    let fusionPlan = try RenderOutputPlan.prepare(
        configuration: fusion, selectedDestination: root
    )
    #expect(fusionPlan.destination.lastPathComponent == "Shot_v12_FusionScene")
    #expect(fusionPlan.generatedRelativePaths.allSatisfy { $0.contains("Shot_v12") })
    #expect(fusionPlan.generatedRelativePaths.filter { $0.hasPrefix("media/") } == [
        "media/Shot_v12_Device00000001.tiff",
        "media/Shot_v12_Device00000002.tiff",
    ])
    #expect(!fusionPlan.generatedRelativePaths.contains { $0.contains("_Spill") })
}

private func derivationConfiguration(
    format: StudioOutputFormat
) throws -> StudioResolvedRenderConfiguration {
    StudioResolvedRenderConfiguration(
        renderMode: .preview, jobName: "Shot", versionSuffix: "_v12", overwritePolicy: .failIfExists,
        fusionScene: nil, composition: .fullComposite,
        spillDeliveryMode: .physicalLinear,
        motionBlurMode: .disabled, motionSamples: 2, raster: .init(width: 1920, height: 1080, placementID: "fit"), format: format,
        pipeline: .aces, target: .sdr, peakNits: 100,
        display: "Rec.1886 Rec.709 - Display",
        view: "ACES 2.0 - SDR 100 nits (Rec.709)",
        vfxInterchangeEncodingID: nil,
        pixelEncoding: format == .tiff16 ? .rgb16 : .yuv4208,
        signalRange: format == .tiff16 ? .full : .video,
        alpha: .ignore,
        includeAudio: false,
        frameRate: try StudioFrameRate(numerator: 24, denominator: 1),
        firstFrame: 1, lastFrame: 2,
        wipReview: StudioWIPReviewPreset.builtIns[0]
    )
}
