import Compression
import Foundation
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

@Test @MainActor func physicalSettingsExchangeRejectsVersionSixWithoutAReader() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    let pipeline = try PhysicalPipelineAuthoringState.seeded(
        device: device,
        coverGlass: cover
    )
    let controller = PhysicalModelController()
    var settings = try #require(PhysicalSettingsExchange.metadata(
        device: device,
        pipeline: pipeline,
        model: controller.authoringState
    ))
    settings["schema"] = "ScreenSimulation.PhysicalSettings.v6"

    #expect(throws: PhysicalSettingsExchange.ImportError.self) {
        try PhysicalSettingsExchange.decode(from: ["settings": settings])
    }
}

@Test @MainActor func selectedImportMigratesTheRetiredSchemaWithExplicitCalibration() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var pipeline = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    let calibration = PhysicalPipelineAuthoringState.RadiometricCalibration(
        baseExposureIndex: 800,
        referenceLambertianReflectance: 0.18,
        referenceIlluminanceLux: 1_000,
        referenceTStop: 2.8,
        referenceShutterSeconds: 1.0 / 48.0,
        effectiveSensorExposureScale: 0.75
    )
    pipeline.radiometricCalibration = calibration
    let controller = PhysicalModelController()
    var settings = try #require(PhysicalSettingsExchange.metadata(
        device: device,
        pipeline: pipeline,
        model: controller.authoringState
    ))
    settings["schema"] = "ScreenSimulation.PhysicalSettings.v1"
    var oldPipeline = try #require(settings["pipeline"] as? [String: Any])
    oldPipeline.removeValue(forKey: "radiometricCalibration")
    settings["pipeline"] = oldPipeline

    #expect(throws: PhysicalSettingsExchange.ImportError.self) {
        try PhysicalSettingsExchange.decode(from: ["settings": settings])
    }
    let imported = try PhysicalSettingsExchange.decodeSelectedImport(
        from: ["settings": settings],
        retainedCalibration: calibration,
        retainedCaptureName: "Cámara elegida"
    )

    #expect(imported.pipeline.radiometricCalibration == calibration)
    #expect(imported.report.contains("Migración seleccionada"))
    #expect(imported.report.contains("Cámara elegida"))
}

@Test func selectedPNGImportReadsRawAndCompressedRetiredContainers() throws {
    let metadata = Data("{\"settings\":{\"schema\":\"ScreenSimulation.PhysicalSettings.v1\"}}".utf8)
    let rawPNG = try pngWithInternationalText(
        keyword: "ScreenSimulation.PhysicalFrame.v1",
        text: metadata,
        compressed: false
    )
    let compressedPNG = try pngWithInternationalText(
        keyword: "ScreenSimulation.PhysicalFrame.v1",
        text: metadata,
        compressed: true
    )

    #expect(FrameCheckPNG.metadata(in: rawPNG) == nil)
    #expect(FrameCheckPNG.metadataForSelectedImport(in: rawPNG) == metadata)
    #expect(FrameCheckPNG.metadataForSelectedImport(in: compressedPNG) == metadata)
}

private func pngWithInternationalText(
    keyword: String, text: Data, compressed: Bool
) throws -> Data {
    var payload = Data(keyword.utf8)
    payload.append(0)
    payload.append(compressed ? 1 : 0)
    payload.append(contentsOf: [0, 0, 0])
    if compressed {
        payload.append(try #require(zlibCompressed(text)))
    } else {
        payload.append(text)
    }
    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    appendPNGChunk(type: "iTXt", payload: payload, to: &png)
    appendPNGChunk(type: "IEND", payload: Data(), to: &png)
    return png
}

private func zlibCompressed(_ source: Data) -> Data? {
    let capacity = max(source.count * 2 + 64, 1_024)
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
    guard count > 0 else { return nil }
    destination.count = count
    return destination
}

private func appendPNGChunk(type: String, payload: Data, to data: inout Data) {
    let length = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
    data.append(Data(type.utf8))
    data.append(payload)
    data.append(contentsOf: [0, 0, 0, 0])
}
