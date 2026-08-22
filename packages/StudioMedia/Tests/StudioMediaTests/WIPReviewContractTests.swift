import Foundation
import Testing
@testable import StudioMedia

@Test func wipReviewBuiltInsOwnSixTypedZonesAndFilenameIsLiteralized() throws {
    #expect(StudioWIPReviewPreset.builtIns.count == 4)
    for preset in StudioWIPReviewPreset.builtIns {
        try preset.validate()
        #expect(Set(preset.zones.map(\.position)) == Set(StudioWIPZonePosition.allCases))
    }
    let filename = try #require(
        StudioWIPReviewPreset.builtIns[0].zones.first { $0.calculatedField == .outputFilename }
    )
    #expect(filename.resolvedText(
        frame: 12, timecode: "00:00:00:12", date: "2026-08-22",
        outputFilename: "shot_v002.mov"
    ) == "shot_v002.mov")
}

@Test func wipReviewRejectsIncompleteCustomRasterAndDuplicateZones() {
    var preset = StudioWIPReviewPreset.builtIns[0]
    preset.reviewRaster = .custom
    #expect(throws: StudioWIPReviewContractError.self) { try preset.validate() }
    preset.customWidth = 1920
    preset.customHeight = 1080
    preset.zones[1].position = preset.zones[0].position
    #expect(throws: StudioWIPReviewContractError.self) { try preset.validate() }
}

@Test func wipReviewEnforcesTheExactPluginParameterRanges() {
    var preset = StudioWIPReviewPreset.builtIns[0]
    preset.graphicsWhiteNits = 0.99
    #expect(throws: StudioWIPReviewContractError.self) { try preset.validate() }
    preset.graphicsWhiteNits = 203
    preset.hlgPeakNits = 10_001
    #expect(throws: StudioWIPReviewContractError.self) { try preset.validate() }
    preset.hlgPeakNits = 1_000
    preset.frameRateOverride = 240.1
    #expect(throws: StudioWIPReviewContractError.self) { try preset.validate() }
    preset.frameRateOverride = 24
    preset.zones[0].offsetX = 1.01
    #expect(throws: StudioWIPReviewContractError.self) { try preset.validate() }
}
