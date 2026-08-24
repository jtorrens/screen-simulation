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

@MainActor @Test func editorialOutputSeedsEditableResolveFriendlySettings() {
    let model = WorkspaceModel()
    model.changeRenderOutputType(.editorial)
    #expect(model.renderOutputType == .editorial)
    #expect(model.renderComposition == .deviceAndSpillSeparate)
    #expect(model.renderSpillDeliveryMode == .editorialACEScctAdd)
    #expect(model.renderMotionBlurMode == .approximate2D)
    #expect(model.outputFormat == .proRes4444XQ)
    #expect(model.outputPixelEncoding == .rgb44412)
    #expect(model.outputSignalRange == .full)
    #expect(model.vfxInterchangeEncodingID
        == StudioVFXEditorialDeliveryContract.colorEncodingID)
    #expect(!model.includeAudio)
    #expect(model.renderWIPReviewPreset == nil)

    model.applyRenderPreset(StudioRenderPreset.builtIns[0])
    #expect(model.renderOutputType == .editorial)
    #expect(model.renderPreset.target == .sdr)
    #expect(model.renderSpillDeliveryMode == .physicalLinear)
}

@Test func wholeDeliverableVersioningStartsAtV002AndSkipsCollisions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-versioning-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configuration = try derivationConfiguration(format: .tiff16)
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    let v2 = try plan.nextAvailableVersion(configuration: configuration)
    #expect(v2.configuration.jobName == "Shot_v002")
    #expect(v2.plan.destination.lastPathComponent == "Shot_v002")
    #expect(v2.plan.generatedRelativePaths.allSatisfy { $0.contains("Shot_v002") })
    try FileManager.default.createDirectory(
        at: v2.plan.destination, withIntermediateDirectories: true
    )
    try Data([1]).write(to: v2.plan.destination.appendingPathComponent(
        v2.plan.generatedRelativePaths[0]
    ))
    let v3 = try plan.nextAvailableVersion(configuration: configuration)
    #expect(v3.configuration.jobName == "Shot_v003")
    let nextFromV2 = try v2.plan.nextAvailableVersion(
        configuration: v2.configuration
    )
    #expect(nextFromV2.configuration.jobName == "Shot_v003")
    #expect(!nextFromV2.plan.destination.lastPathComponent.contains("v002_v"))
}

@Test func movieVersioningUpdatesDestinationAndCalculatedFilenameTogether() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-movie-versioning-\(UUID().uuidString)")
    let configuration = try derivationConfiguration(format: .h264High)
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration,
        selectedDestination: root.appendingPathComponent("Editorial.mov")
    )
    let versioned = try plan.nextAvailableVersion(configuration: configuration)
    #expect(versioned.plan.destination.lastPathComponent == "Editorial_v002.mp4")
    #expect(versioned.configuration.jobName == "Shot_v002")
}

@Test func versioningIsAtomicForSeparatedDeviceSpillAndFusionPackages() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-package-versioning-\(UUID().uuidString)")
    let rate = try StudioFrameRate(numerator: 24, denominator: 1)
    let separated = StudioResolvedRenderConfiguration(
        outputType: .standard, jobName: "Shot", overwritePolicy: .failIfExists,
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
    let separatedV2 = try separatedPlan.nextAvailableVersion(configuration: separated)
    #expect(separatedV2.plan.destination.lastPathComponent == "Shot_v002_DeviceSpill")
    #expect(separatedV2.plan.generatedRelativePaths.count == 4)
    #expect(separatedV2.plan.generatedRelativePaths.allSatisfy { $0.contains("Shot_v002_") })

    let fusion = StudioResolvedRenderConfiguration(
        outputType: .fusionScenePackage, jobName: "Shot", overwritePolicy: .failIfExists,
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
    let fusionV2 = try fusionPlan.nextAvailableVersion(configuration: fusion)
    #expect(fusionV2.plan.destination.lastPathComponent == "Shot_v002_FusionScene")
    #expect(fusionV2.plan.generatedRelativePaths.allSatisfy { $0.contains("Shot_v002") })
}

private func derivationConfiguration(
    format: StudioOutputFormat
) throws -> StudioResolvedRenderConfiguration {
    StudioResolvedRenderConfiguration(
        outputType: .standard, jobName: "Shot", overwritePolicy: .failIfExists,
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
