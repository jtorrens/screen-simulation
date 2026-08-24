import Foundation
import Testing
@testable import StudioMedia

@Test func creditosOutputMatrixAndPresetIdentityRemainExact() {
    #expect(StudioOutputFormat.allCases.map(\.rawValue) == [
        "openEXR", "dpx10RGB", "tiff16", "proRes4444", "proRes4444XQ",
        "h264Low", "h264Medium", "h264High", "h265Low", "h265Medium", "h265High",
    ])
    #expect(StudioRenderPreset.builtIns.count == 10)
    #expect(StudioRenderPreset.builtIns[1].peakNits == 1_000)
    #expect(StudioRenderPreset.builtIns[0].pipeline == .aces)
    #expect(StudioRenderPreset.builtIns[2].pipeline == .davinciColorManaged)
    #expect(StudioRenderPreset.builtIns[2].view == "Video (colorimetric)")
    #expect(StudioOutputFormat.h264High.bitsPerPixelPerFrame == 0.16)
    #expect(StudioOutputFormat.h265High.bitsPerPixelPerFrame == 0.10)
    #expect(StudioRenderPreset.builtIns[7].target == .vfxLog)
    #expect(StudioRenderPreset.builtIns[7].format == .proRes4444)
    #expect(StudioRenderPreset.builtIns[8].target == .vfxLog)
    #expect(StudioRenderPreset.builtIns[8].format == .proRes4444XQ)
    let editorial = StudioRenderPreset.builtIns[9]
    #expect(editorial.id == StudioVFXEditorialDeliveryContract.presetID)
    #expect(editorial.fixedVFXInterchangeEncodingID == "acescct-ap1")
    #expect(editorial.format == .proRes4444XQ)
    #expect(editorial.pixelEncoding == .rgb44412)
    #expect(editorial.signalRange == .full)
    #expect(editorial.alpha == .straight)
    #expect(editorial.includeAudio == false)
    #expect(editorial.supportsFusionScenePackage == false)
    #expect(StudioOutputFormat.proRes4444.supports(target: .vfxLog))
    #expect(StudioOutputFormat.proRes4444XQ.supports(target: .vfxLog))
    #expect(!StudioOutputFormat.openEXR.supports(target: .vfxLog))
}

@Test func metadataProposalMatchesCreditsRulesAndAddsMatrix() {
    let explicit = StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2"
    )
    #expect(explicit?.id == "input-rec709")
    #expect(explicit?.provenance == .detected)
    #expect(StudioMediaMetadataDetector.proposedMatrix("ITU_R_2020") == .bt2020)
}

@Test func rec709WithoutTransferIsProposedNotDetected() {
    let incomplete = StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_709_2", transfer: nil, matrix: "ITU_R_709_2"
    )
    #expect(incomplete?.id == "input-rec709")
    #expect(incomplete?.provenance == .proposed)
}

@Test func pqRequiresCompleteExplicitMetadata() {
    let explicit = StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020"
    )
    #expect(explicit?.id == "display-rec2100-pq-dcm")
    #expect(explicit?.provenance == .detected)
    #expect(StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_2020", transfer: nil, matrix: "ITU_R_2020"
    ) == nil)
}

@Test func unlabeledVideoImportUsesVisibleEditableDefaults() {
    let resolution = StudioMediaImportResolution(
        detection: StudioMediaDetection(hasAlpha: true),
        isVideo: true
    )
    #expect(resolution.detection.proposedInputTransformID == "srgb-encoded-rec709")
    #expect(resolution.detection.inputTransformProvenance == .proposed)
    #expect(resolution.detection.colorModel == .ycbcr)
    #expect(resolution.detection.matrix == .bt709)
    #expect(resolution.detection.range == .video)
    #expect(resolution.detection.alpha == .premultiplied)
    #expect(resolution.nonMetadataFields == StudioImportInterpretationField.allCases)
}

@Test func importResolutionPreservesDetectedFieldsAndFillsOnlyMissingOnes() {
    let resolution = StudioMediaImportResolution(
        detection: StudioMediaDetection(
            proposedInputTransformID: "input-rec709",
            inputTransformProvenance: .detected,
            matrix: .bt2020,
            matrixProvenance: .detected,
            range: .full,
            rangeProvenance: .detected,
            colorModel: .ycbcr,
            colorModelProvenance: .detected,
            hasAlpha: true
        ),
        isVideo: true
    )
    #expect(resolution.detection.proposedInputTransformID == "input-rec709")
    #expect(resolution.detection.matrix == .bt2020)
    #expect(resolution.detection.range == .full)
    #expect(resolution.detection.alpha == .premultiplied)
    #expect(resolution.nonMetadataFields == [.alpha])
}

@Test func unlabeledStillUsesRgbFullRangeAndOpaqueWhenNoAlphaExists() {
    let resolution = StudioMediaImportResolution(
        detection: StudioMediaDetection(hasAlpha: false),
        isVideo: false
    )
    #expect(resolution.detection.colorModel == .rgb)
    #expect(resolution.detection.range == .full)
    #expect(resolution.detection.alpha == .ignore)
}

@Test func renderJobConfigurationIsAnEffectiveImmutableSnapshot() throws {
    var preset = StudioRenderPreset.builtIns[0]
    let exactFrameRate = try StudioFrameRate(numerator: 24_000, denominator: 1_001)
    let configuration = StudioResolvedRenderConfiguration(
        outputType: .standard,
        jobName: "standard-snapshot",
        versionSuffix: "_v03",
        overwritePolicy: .failIfExists,
        fusionScene: nil,
        composition: .deviceAndSpillTogether,
        spillDeliveryMode: .physicalLinear,
        motionBlurMode: .physical,
        motionSamples: 8, raster: .init(width: 1920, height: 1080, placementID: "fit"),
        format: .proRes4444,
        pipeline: preset.pipeline,
        target: preset.target,
        peakNits: 120,
        display: preset.display,
        view: preset.view,
        vfxInterchangeEncodingID: nil,
        pixelEncoding: .yuv44412,
        signalRange: .video,
        alpha: .straight,
        includeAudio: true,
        frameRate: exactFrameRate,
        firstFrame: 12,
        lastFrame: 47
    )
    preset.peakNits = 4_000
    preset.view = "otra ODT"
    #expect(configuration.peakNits == 120)
    #expect(configuration.view == "ACES 2.0 - SDR 100 nits (Rec.709)")
    #expect(configuration.frameRange == 12 ... 47)
    #expect(configuration.frameRate.numerator == 24_000)
    #expect(configuration.frameRate.denominator == 1_001)
    let roundtrip = try JSONDecoder().decode(
        StudioResolvedRenderConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )
    #expect(roundtrip == configuration)
    #expect(configuration.physicalTemporalSamples == 8)
}

@Test func renderJobRequiresKnownExplicitMotionBlurMode() throws {
    let configuration = StudioResolvedRenderConfiguration(
        outputType: .standard, jobName: "motion-mode", versionSuffix: "",
        overwritePolicy: .failIfExists, fusionScene: nil,
        composition: .deviceAndSpillTogether, spillDeliveryMode: .physicalLinear,
        motionBlurMode: .approximate2D,
        motionSamples: 8, raster: .init(width: 1920, height: 1080, placementID: "fit"), format: .openEXR, pipeline: .aces, target: .acescg,
        peakNits: 0, display: nil, view: nil, vfxInterchangeEncodingID: nil,
        pixelEncoding: .rgba16Float, signalRange: .full, alpha: .straight,
        includeAudio: false, frameRate: .fps24, firstFrame: 0, lastFrame: 0
    )
    let encoded = try JSONEncoder().encode(configuration)
    #expect(configuration.physicalTemporalSamples == 1)
    let object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var missing = object
    missing.removeValue(forKey: "motionBlurMode")
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            StudioResolvedRenderConfiguration.self,
            from: JSONSerialization.data(withJSONObject: missing)
        )
    }
    var unknown = object
    unknown["motionBlurMode"] = "temporal-magic"
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            StudioResolvedRenderConfiguration.self,
            from: JSONSerialization.data(withJSONObject: unknown)
        )
    }
}

@Test func editorialRenderFreezesExplicitAdditiveSpillContract() throws {
    let configuration = StudioResolvedRenderConfiguration(
        outputType: .editorial, jobName: "editorial", versionSuffix: "_v01",
        overwritePolicy: .failIfExists, fusionScene: nil,
        composition: .deviceAndSpillSeparate,
        spillDeliveryMode: .editorialEncodedAdd,
        motionBlurMode: .approximate2D, motionSamples: 8, raster: .init(width: 1920, height: 1080, placementID: "fit"),
        format: .proRes4444XQ, pipeline: .aces, target: .vfxLog,
        peakNits: 0, display: nil, view: nil,
        vfxInterchangeEncodingID: StudioVFXEditorialDeliveryContract.colorEncodingID,
        pixelEncoding: .rgb44412, signalRange: .full, alpha: .straight,
        includeAudio: false, frameRate: .fps24, firstFrame: 0, lastFrame: 10
    )
    try configuration.validate()
    #expect(StudioVFXEditorialDeliveryContract.supportedColorEncodingIDs
        == ["acescct-ap1", "rec709-gamma24"])
    #expect(StudioVFXEditorialDeliveryContract.spillAlpha == 0.125)
    let rec709 = StudioResolvedRenderConfiguration(
        outputType: .editorial, jobName: "editorial-rec709", versionSuffix: "",
        overwritePolicy: .failIfExists, fusionScene: nil,
        composition: .deviceAndSpillSeparate,
        spillDeliveryMode: .editorialEncodedAdd,
        motionBlurMode: .approximate2D, motionSamples: 8,
        raster: .init(width: 3840, height: 2160, placementID: "fill-crop"),
        format: .proRes4444XQ, pipeline: .aces, target: .sdr,
        peakNits: StudioVFXEditorialDeliveryContract.rec709PeakNits,
        display: StudioVFXEditorialDeliveryContract.rec709Display,
        view: StudioVFXEditorialDeliveryContract.rec709View,
        vfxInterchangeEncodingID: StudioVFXEditorialDeliveryContract.rec709ColorEncodingID,
        pixelEncoding: .rgb44412, signalRange: .full, alpha: .straight,
        includeAudio: false, frameRate: .fps24, firstFrame: 0, lastFrame: 10
    )
    try rec709.validate()
    var rec709WithoutODT = try #require(
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(rec709))
            as? [String: Any]
    )
    rec709WithoutODT["target"] = "vfxLog"
    rec709WithoutODT["peakNits"] = 0
    rec709WithoutODT.removeValue(forKey: "display")
    rec709WithoutODT.removeValue(forKey: "view")
    let invalidRec709 = try JSONDecoder().decode(
        StudioResolvedRenderConfiguration.self,
        from: JSONSerialization.data(withJSONObject: rec709WithoutODT)
    )
    #expect(throws: StudioOutputContractError.self) {
        try invalidRec709.validate()
    }
    let encoded = try JSONEncoder().encode(configuration)
    #expect(try JSONDecoder().decode(
        StudioResolvedRenderConfiguration.self, from: encoded
    ) == configuration)

    var object = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "spillDeliveryMode")
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            StudioResolvedRenderConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
    let incompatible = StudioResolvedRenderConfiguration(
        outputType: .editorial, jobName: "invalid", versionSuffix: "",
        overwritePolicy: .failIfExists, fusionScene: nil,
        composition: .deviceAndSpillSeparate,
        spillDeliveryMode: .editorialEncodedAdd,
        motionBlurMode: .approximate2D, motionSamples: 8, raster: .init(width: 1920, height: 1080, placementID: "fit"),
        format: .proRes4444XQ, pipeline: .aces, target: .vfxLog,
        peakNits: 0, display: nil, view: nil,
        vfxInterchangeEncodingID: StudioVFXEditorialDeliveryContract.colorEncodingID,
        pixelEncoding: .rgb44412, signalRange: .video, alpha: .straight,
        includeAudio: false, frameRate: .fps24, firstFrame: 0, lastFrame: 10
    )
    #expect(throws: StudioOutputContractError.editorialSpillDeliveryInvalid) {
        try incompatible.validate()
    }
}

@Test func vfxRenderJobFreezesCodecAndLogGamutIndependentlyOfCamera() throws {
    let configuration = StudioResolvedRenderConfiguration(
        outputType: .standard,
        jobName: "vfx-master",
        versionSuffix: "_client-final",
        overwritePolicy: .failIfExists,
        fusionScene: nil,
        composition: .fullComposite,
        spillDeliveryMode: .physicalLinear,
        motionBlurMode: .disabled,
        motionSamples: 8, raster: .init(width: 1920, height: 1080, placementID: "fit"),
        format: .proRes4444XQ,
        pipeline: .aces,
        target: .vfxLog,
        peakNits: 0,
        display: nil,
        view: nil,
        vfxInterchangeEncodingID: "davinci-intermediate-wide-gamut",
        pixelEncoding: .yuv44412,
        signalRange: .video,
        alpha: .straight,
        includeAudio: true,
        frameRate: .fps24,
        firstFrame: 0,
        lastFrame: 23
    )
    let roundtrip = try JSONDecoder().decode(
        StudioResolvedRenderConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )
    #expect(roundtrip.format == .proRes4444XQ)
    #expect(roundtrip.vfxInterchangeEncodingID == "davinci-intermediate-wide-gamut")
    #expect(roundtrip == configuration)
}

@Test func frameRateRejectsValuesThatCannotBecomeExactMediaTimes() {
    #expect(throws: StudioMediaContractError.self) {
        try StudioFrameRate(numerator: 0, denominator: 1)
    }
    #expect(throws: StudioMediaContractError.self) {
        try StudioFrameRate(numerator: 24_000, denominator: 0)
    }
    #expect(throws: StudioMediaContractError.self) {
        try StudioFrameRate(numerator: UInt32(Int32.max) + 1, denominator: 1)
    }
}

@Test func outputRangeSupportIsExplicitPerWriter() {
    #expect(StudioOutputFormat.h264High.supportedPixelEncodings == [.yuv4208])
    #expect(StudioOutputFormat.h264High.supportedSignalRanges(for: .yuv4208) == [.video, .full])
    #expect(StudioOutputFormat.proRes4444.supportedPixelEncodings == [.yuv44412, .rgb44412])
    #expect(StudioOutputFormat.proRes4444.supportedSignalRanges(for: .yuv44412) == [.video, .full])
    #expect(StudioOutputFormat.openEXR.supportedPixelEncodings == [.rgba16Float])
    #expect(StudioOutputFormat.openEXR.supportedSignalRanges(for: .rgba16Float) == [.full])
}

@Test func outputFormatsDeclareTheirRenderTargetCompatibility() {
    #expect(StudioOutputFormat.h264High.supports(target: .sdr))
    #expect(!StudioOutputFormat.h264High.supports(target: .hdr))
    #expect(StudioOutputFormat.h265High.supports(target: .hdr))
    #expect(!StudioOutputFormat.h265High.supports(target: .sdr))
    #expect(StudioOutputFormat.openEXR.supports(target: .acescg))
    #expect(StudioOutputFormat.openEXR.supports(target: .aces2065))
    #expect(!StudioOutputFormat.openEXR.supports(target: .sdr))
    #expect(StudioOutputFormat.proRes4444.supports(target: .sdr))
    #expect(StudioOutputFormat.proRes4444.supports(target: .hdr))
}
