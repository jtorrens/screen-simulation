import Foundation
import StudioColor
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func wipReviewLibrarySeedsAreLockedAndDuplicateIsEditable() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-wip-library-\(UUID().uuidString)")
    let controller = GlobalLibraryController(store: try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("GlobalLibrary.v15.json")
    ))
    #expect(controller.document.wipReviewPresets.count == 4)
    #expect(controller.document.wipReviewPresets.allSatisfy { $0.isLocked })
    controller.selectedWIPReviewPresetID = controller.document.wipReviewPresets[0].id
    controller.duplicateSelectedWIPReviewPreset()
    #expect(controller.document.wipReviewPresets.count == 5)
    #expect(controller.selectedWIPReviewPresetItem?.isLocked == false)
    controller.updateSelectedWIPReviewPreset { $0.name = "Editorial cliente" }
    #expect(controller.selectedWIPReviewPresetItem?.name == "Editorial cliente")
}

@Test func directOFXHostProcessesTheExactBundleWithoutRendererSource() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let host = repository.appendingPathComponent(
        "target/wip-ofx-host-build/screen-wip-ofx-host"
    )
    let bundle = URL(fileURLWithPath: "/Library/OFX/Plugins/WIPReviewProbe.ofx.bundle")
    #expect(FileManager.default.isExecutableFile(atPath: host.path))
    #expect(FileManager.default.fileExists(atPath: bundle.path))
    var preset = StudioWIPReviewPreset.builtIns[0]
    for index in preset.zones.indices { preset.zones[index].enabled = false }
    let input = [Float](repeating: 0.18, count: 4 * 4 * 4).enumerated().map {
        $0.offset % 4 == 3 ? 1 : $0.element
    }
    let result = try await WIPReviewOFXAdapter(
        hostExecutableURL: host, pluginBundleURL: bundle
    ).render(
        encodedRGBA: input, sourceWidth: 4, sourceHeight: 4,
        frame: 1001, frameRate: 24, outputFilename: "shot_v002.mov",
        preset: preset
    )
    #expect(result.raster == .init(width: 4, height: 4))
    #expect(zip(result.rgba, input).map { abs($0 - $1) }.max() ?? 1 < 0.000_001)
}

@Test func directOFXMetalHostPreservesOpaqueRGB() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    var preset = StudioWIPReviewPreset.builtIns[0]
    preset.placement = .identity
    for index in preset.zones.indices { preset.zones[index].enabled = false }
    let input: [Float] = [
        0.8, 0.4, 0.2, 1,
        0.7, 0.3, 0.1, 1,
        0.6, 0.2, 0.9, 1,
        0.2, 0.6, 0.9, 1,
    ]
    let result = try await WIPReviewOFXAdapter(
        hostExecutableURL: repository.appendingPathComponent(
            "target/wip-ofx-host-build/screen-wip-ofx-host"
        ),
        pluginBundleURL: URL(
            fileURLWithPath: "/Library/OFX/Plugins/WIPReviewProbe.ofx.bundle"
        )
    ).render(
        encodedRGBA: input, sourceWidth: 4, sourceHeight: 1,
        frame: 1_001, frameRate: 24, outputFilename: "alpha.mov",
        preset: preset
    )
    #expect(zip(result.rgba, input).map { abs($0 - $1) }.max() ?? 1 < 0.000_001)
}

@Test @MainActor func wipOpaqueBoundaryPreservesRGBWithoutPremultiplying() throws {
    let source: [Float] = [
        0.8, 0.4, 0.2, 0,
        0.8, 0.4, 0.2, 0.5,
        0.8, 0.4, 0.2, 1,
    ]
    let opaque = try NativeOutputRenderer.opaqueWIPRGBA(source)
    #expect(opaque == [
        0.8, 0.4, 0.2, 1,
        0.8, 0.4, 0.2, 1,
        0.8, 0.4, 0.2, 1,
    ])
}

@Test func wipOFXAdapterRejectsNonOpaqueInputBeforePublication() async throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    var preset = StudioWIPReviewPreset.builtIns[0]
    for index in preset.zones.indices { preset.zones[index].enabled = false }
    await #expect(throws: WIPReviewOFXError.self) {
        try await WIPReviewOFXAdapter(
            hostExecutableURL: repository.appendingPathComponent(
                "target/wip-ofx-host-build/screen-wip-ofx-host"
            ),
            pluginBundleURL: URL(
                fileURLWithPath: "/Library/OFX/Plugins/WIPReviewProbe.ofx.bundle"
            )
        ).render(
            encodedRGBA: [0.8, 0.4, 0.2, 0.5],
            sourceWidth: 1, sourceHeight: 1,
            frame: 1_001, frameRate: 24, outputFilename: "alpha.mov",
            preset: preset
        )
    }
}

@Test func wipContractRequiresOpaqueOutputAlpha() throws {
    let preset = StudioWIPReviewPreset.builtIns[0]
    let straight = StudioResolvedRenderConfiguration(
        outputType: .standard, jobName: "WIP", overwritePolicy: .failIfExists,
        fusionScene: nil, composition: .deviceAndSpillTogether,
        motionBlurEnabled: false, motionSamples: 2, format: .tiff16,
        pipeline: .aces, target: .sdr, peakNits: 100,
        display: "Rec.1886 Rec.709 - Display",
        view: "ACES 2.0 - SDR 100 nits (Rec.709)",
        vfxInterchangeEncodingID: nil, pixelEncoding: .rgb16,
        signalRange: .full, alpha: .straight, includeAudio: false,
        frameRate: try StudioFrameRate(numerator: 24, denominator: 1),
        firstFrame: 1_001, lastFrame: 1_001, wipReview: preset
    )
    #expect(throws: StudioOutputContractError.wipReviewDeliveryInvalid) {
        try straight.validate()
    }
}

@Test @MainActor func selectingWIPMakesTheEditableOutputContractOpaque() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-wip-workspace-\(UUID().uuidString)")
    let model = WorkspaceModel(globalLibraryStore: try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("GlobalLibrary.v15.json")
    ))
    model.changeOutputFormat(.tiff16)
    model.outputAlphaMode = .straight
    model.changeWIPReviewPreset(StudioWIPReviewPreset.builtIns[0])
    #expect(model.outputAlphaMode == .ignore)
    model.outputAlphaMode = .premultiplied
    model.ensureRenderOptionsCompatible()
    #expect(model.outputAlphaMode == .ignore)
}

@Test @MainActor func hlgWIPUsesHLGTransformAndRejectsPQSignaling() throws {
    let preset = StudioWIPReviewPreset.builtIns[3]
    let valid = StudioResolvedRenderConfiguration(
        outputType: .standard, jobName: "HLG", overwritePolicy: .failIfExists,
        fusionScene: nil, composition: .fullComposite,
        motionBlurEnabled: false, motionSamples: 2, format: .h265High,
        pipeline: .aces, target: .hdr, peakNits: preset.hlgPeakNits,
        display: "Rec.2100-HLG - Display",
        view: "ACES 2.0 - HDR 1000 nits (P3 D65)",
        vfxInterchangeEncodingID: nil, pixelEncoding: .yuv42010,
        signalRange: .video, alpha: .ignore, includeAudio: false,
        frameRate: try StudioFrameRate(numerator: 24, denominator: 1),
        firstFrame: 1_001, lastFrame: 1_001, wipReview: preset
    )
    try valid.validate()
    #expect(try NativeOutputRenderer.outputTransform(for: valid)?.encoding == .rec2100HLG)
    let mismatched = StudioResolvedRenderConfiguration(
        outputType: .standard, jobName: "HLG", overwritePolicy: .failIfExists,
        fusionScene: nil, composition: .fullComposite,
        motionBlurEnabled: false, motionSamples: 2, format: .h265High,
        pipeline: .aces, target: .hdr, peakNits: preset.hlgPeakNits,
        display: "Rec.2100-PQ - Display",
        view: "ACES 2.0 - HDR 1000 nits (Rec.2020)",
        vfxInterchangeEncodingID: nil, pixelEncoding: .yuv42010,
        signalRange: .video, alpha: .ignore, includeAudio: false,
        frameRate: try StudioFrameRate(numerator: 24, denominator: 1),
        firstFrame: 1_001, lastFrame: 1_001, wipReview: preset
    )
    #expect(throws: StudioOutputContractError.wipReviewDeliveryInvalid) {
        try mismatched.validate()
    }
}

@Test func wipCustomRasterIsResolvedExplicitly() throws {
    var preset = StudioWIPReviewPreset.builtIns[0]
    preset.reviewRaster = .custom
    preset.customWidth = 2_048
    preset.customHeight = 858
    try preset.validate()
    #expect(try WIPReviewOFXAdapter.raster(
        for: preset, sourceWidth: 1_920, sourceHeight: 1_080
    ) == .init(width: 2_048, height: 858))
}
