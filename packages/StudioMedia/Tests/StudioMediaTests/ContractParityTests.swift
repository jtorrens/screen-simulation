import Testing
@testable import StudioMedia

@Test func creditosOutputMatrixAndPresetIdentityRemainExact() {
    #expect(StudioOutputFormat.allCases.map(\.rawValue) == [
        "openEXR", "dpx10RGB", "tiff16", "proRes4444", "proRes4444XQ",
        "h264Low", "h264Medium", "h264High", "h265Low", "h265Medium", "h265High",
    ])
    #expect(StudioRenderPreset.builtIns.count == 7)
    #expect(StudioRenderPreset.builtIns[1].peakNits == 1_000)
    #expect(StudioOutputFormat.h264High.bitsPerPixelPerFrame == 0.16)
    #expect(StudioOutputFormat.h265High.bitsPerPixelPerFrame == 0.10)
}

@Test func metadataProposalMatchesCreditsRulesAndAddsMatrix() {
    #expect(StudioMediaMetadataDetector.proposedInputColorSpace(
        primaries: "ITU_R_709_2", transfer: "ITU_R_709_2", matrix: "ITU_R_709_2"
    ) == "Input - Rec.709")
    #expect(StudioMediaMetadataDetector.proposedMatrix("ITU_R_2020") == .bt2020)
}
