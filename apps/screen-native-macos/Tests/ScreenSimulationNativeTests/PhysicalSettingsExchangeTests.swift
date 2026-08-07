import Foundation
import Compression
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func physicalSettingsExchangeRoundTripsTheCanonicalModelOnly() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var pipeline = try PhysicalPipelineAuthoringState.seeded(
        device: device,
        coverGlass: cover
    )
    pipeline.environment.rotationDegrees = 23.5
    pipeline.cameraPose.position = [-0.1, 0.2, 0.75]
    pipeline.sceneLens.focalLengthMillimeters = 65
    pipeline.develop.exposureEV = -1.25

    let controller = PhysicalModelController()
    try controller.setDomainAmount(1.2, domain: .screen)
    try controller.setContinuousAmount(1.4, stage: .screen(.panelLightSpread))
    try controller.setContinuousBypassed(true, stage: .screen(.temporal))
    try controller.setDiscreteEnabled(false, stage: .capture(.developDemosaic))

    let settings = try #require(PhysicalSettingsExchange.metadata(
        device: device,
        pipeline: pipeline,
        model: controller.authoringState
    ))
    let imported = try PhysicalSettingsExchange.decode(from: ["settings": settings])

    #expect(imported.device == device)
    #expect(imported.pipeline == pipeline)
    #expect(imported.model == controller.authoringState)
    #expect(imported.report.contains("ODT de preview"))
    #expect(imported.report.contains("Incompatibles u omitidos"))
}

@Test @MainActor func physicalSettingsExchangeRejectsLegacyDebugOnlyMetadata() throws {
    #expect(throws: PhysicalSettingsExchange.ImportError.self) {
        try PhysicalSettingsExchange.decode(from: ["physical": ["snapshotDebug": "legacy"]])
    }
}

@Test func frameCheckPNGReadsCompressedInternationalText() throws {
    let metadata = Data("{\"schema\":\"ScreenSimulation.PhysicalSettings.v1\"}".utf8)
    let compressed = try #require(zlibCompressed(metadata))
    var payload = Data(FrameCheckPNG.metadataKeyword.utf8)
    // iTXt: keyword NUL, compression flag/method, language NUL, translated NUL.
    payload.append(contentsOf: [0, 1, 0, 0, 0])
    payload.append(compressed)

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    appendPNGChunk(type: "iTXt", payload: payload, to: &png)
    appendPNGChunk(type: "IEND", payload: Data(), to: &png)

    #expect(FrameCheckPNG.metadata(in: png) == metadata)
}

private func zlibCompressed(_ source: Data) -> Data? {
    var capacity = max(source.count * 2 + 64, 1_024)
    while capacity <= 1_024 * 1_024 {
        var destination = Data(count: capacity)
        let count = destination.withUnsafeMutableBytes { destinationBytes in
            source.withUnsafeBytes { sourceBytes in
                compression_encode_buffer(
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress!,
                    capacity,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        if count > 0 {
            destination.count = count
            return destination
        }
        capacity *= 2
    }
    return nil
}

private func appendPNGChunk(type: String, payload: Data, to data: inout Data) {
    let length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
    data.append(Data(type.utf8))
    data.append(payload)
    // The production metadata reader intentionally does not need CRC validation.
    data.append(contentsOf: [0, 0, 0, 0])
}
