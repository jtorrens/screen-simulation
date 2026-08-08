import Foundation
import Testing
@testable import StudioMedia

@Test func creditosOutputMatrixAndPresetIdentityRemainExact() {
    #expect(StudioOutputFormat.allCases.map(\.rawValue) == [
        "openEXR", "dpx10RGB", "tiff16", "proRes4444", "proRes4444XQ",
        "h264Low", "h264Medium", "h264High", "h265Low", "h265Medium", "h265High",
    ])
    #expect(StudioRenderPreset.builtIns.count == 7)
    #expect(StudioRenderPreset.builtIns[1].peakNits == 1_000)
    #expect(StudioRenderPreset.builtIns[0].pipeline == .aces)
    #expect(StudioRenderPreset.builtIns[2].pipeline == .davinciColorManaged)
    #expect(StudioRenderPreset.builtIns[2].view == "Video (colorimetric)")
    #expect(StudioOutputFormat.h264High.bitsPerPixelPerFrame == 0.16)
    #expect(StudioOutputFormat.h265High.bitsPerPixelPerFrame == 0.10)
}

@Test func metadataProposalMatchesCreditsRulesAndAddsMatrix() {
    let explicit = StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2"
    )
    #expect(explicit?.id == "display-rec709-gamma24-dcm")
    #expect(explicit?.provenance == .detected)
    #expect(StudioMediaMetadataDetector.proposedMatrix("ITU_R_2020") == .bt2020)
}

@Test func rec709WithoutTransferIsProposedNotDetected() {
    let incomplete = StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_709_2", transfer: nil, matrix: "ITU_R_709_2"
    )
    #expect(incomplete?.id == "display-rec709-gamma24-dcm")
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

@Test func renderJobConfigurationIsAnEffectiveImmutableSnapshot() throws {
    var preset = StudioRenderPreset.builtIns[0]
    let configuration = StudioResolvedRenderConfiguration(
        format: .proRes4444,
        pipeline: preset.pipeline,
        target: preset.target,
        peakNits: 120,
        display: preset.display,
        view: preset.view,
        pixelEncoding: .yuv44412,
        signalRange: .video,
        alpha: .straight,
        includeAudio: true,
        frameRate: 24,
        firstFrame: 12,
        lastFrame: 47
    )
    preset.peakNits = 4_000
    preset.view = "otra ODT"
    #expect(configuration.peakNits == 120)
    #expect(configuration.view == "ACES 2.0 - SDR 100 nits (Rec.709)")
    #expect(configuration.frameRange == 12 ... 47)
    let roundtrip = try JSONDecoder().decode(
        StudioResolvedRenderConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )
    #expect(roundtrip == configuration)
}

@Test func outputRangeSupportIsExplicitPerWriter() {
    #expect(StudioOutputFormat.h264High.supportedPixelEncodings == [.yuv4208])
    #expect(StudioOutputFormat.h264High.supportedSignalRanges(for: .yuv4208) == [.video, .full])
    #expect(StudioOutputFormat.proRes4444.supportedPixelEncodings == [.yuv44412])
    #expect(StudioOutputFormat.proRes4444.supportedSignalRanges(for: .yuv44412) == [.video])
    #expect(StudioOutputFormat.openEXR.supportedPixelEncodings == [.rgba16Float])
    #expect(StudioOutputFormat.openEXR.supportedSignalRanges(for: .rgba16Float) == [.full])
}
