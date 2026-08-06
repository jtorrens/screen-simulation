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
    #expect(explicit?.id == "display-rec709-aces2-sdr")
    #expect(explicit?.provenance == .detected)
    #expect(StudioMediaMetadataDetector.proposedMatrix("ITU_R_2020") == .bt2020)
}

@Test func rec709WithoutTransferIsProposedNotDetected() {
    let incomplete = StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_709_2", transfer: nil, matrix: "ITU_R_709_2"
    )
    #expect(incomplete?.id == "display-rec709-aces2-sdr")
    #expect(incomplete?.provenance == .proposed)
}

@Test func pqRequiresCompleteExplicitMetadata() {
    let explicit = StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_2020", transfer: "SMPTE_ST_2084_PQ", matrix: "ITU_R_2020"
    )
    #expect(explicit?.id == "display-rec2100-pq-aces2-hdr-1000")
    #expect(explicit?.provenance == .detected)
    #expect(StudioMediaMetadataDetector.inputTransformProposal(
        primaries: "ITU_R_2020", transfer: nil, matrix: "ITU_R_2020"
    ) == nil)
}
