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
    pipeline.environment.rotationXDegrees = -7.25
    pipeline.environment.rotationYDegrees = 23.5
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
        model: controller.authoringState,
        context: try canonicalFrameContext(deviceID: device.id)
    ))
    let imported = try PhysicalSettingsExchange.decode(from: ["settings": settings])
    let expectedContext = try canonicalFrameContext(deviceID: device.id)

    #expect(imported.device == device)
    #expect(imported.pipeline == pipeline)
    #expect(imported.model == controller.authoringState)
    #expect(imported.context == expectedContext)
    #expect(imported.report.contains("preview y fase visible"))
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
        model: controller.authoringState,
        context: try canonicalFrameContext(deviceID: device.id)
    ))
    settings["schema"] = "ScreenSimulation.PhysicalSettings.v6"

    #expect(throws: PhysicalSettingsExchange.ImportError.self) {
        try PhysicalSettingsExchange.decode(from: ["settings": settings])
    }
}

@Test @MainActor func physicalSettingsExchangeRejectsFrameSettingsVersionFifteen() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    let pipeline = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    let controller = PhysicalModelController()
    var settings = try #require(PhysicalSettingsExchange.metadata(
        device: device,
        pipeline: pipeline,
        model: controller.authoringState,
        context: try canonicalFrameContext(deviceID: device.id)
    ))
    settings["schema"] = "ScreenSimulation.FrameSettings.v15"

    #expect(throws: PhysicalSettingsExchange.ImportError.self) {
        try PhysicalSettingsExchange.decode(from: ["settings": settings])
    }
}

@Test func normalPNGImportRejectsRetiredContainers() throws {
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
    #expect(FrameCheckPNG.metadata(in: compressedPNG) == nil)
}

@Test func frameSettingsRejectMalformedImageEnvironmentIdentity() throws {
    let resource = PhysicalSettingsExchange.EnvironmentResource(
        kind: .image,
        fileName: "room.exr",
        sha256: "not-a-sha",
        inputTransformID: "linear-rec709"
    )
    #expect(throws: PhysicalSettingsExchange.ImportError.self) {
        try resource.validate()
    }
}

@Test func frameSettingsRejectReferenceWithoutCompleteInterpretation() throws {
    let resource = PhysicalSettingsExchange.ReferenceResource(
        kind: .imageOrVideo,
        fileName: "reference.mov",
        sha256: String(repeating: "a", count: 64),
        inputTransformID: "srgb-encoded-rec709",
        alphaMode: "Ignorar",
        signalColorModel: "RGB",
        signalMatrix: "BT.709",
        signalRange: "Completo",
        placementID: nil,
        corners: [
            .init(x: 10, y: 10), .init(x: 100, y: 10),
            .init(x: 100, y: 80), .init(x: 10, y: 80),
        ]
    )
    #expect(throws: PhysicalSettingsExchange.ImportError.self) {
        try resource.validate()
    }
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

@MainActor
private func canonicalFrameContext(
    deviceID: String
) throws -> PhysicalSettingsExchange.FrameContext {
    .init(
        selection: try RustTestAuthoringCoordinator.defaultSelection(
            inputTransformID: "srgb-encoded-rec709",
            deviceID: deviceID,
            frameRate: .fps24
        ),
        sourceInputTransformID: "srgb-encoded-rec709",
        sourceAlphaMode: "Ignorar",
        sourceColorModel: "RGB",
        sourceYUVMatrix: "BT.709",
        sourceSignalRange: "Completo",
        sourcePlacementID: "fit",
        previewOutputTransformID: "aces2-srgb-sdr-100",
        previewPhaseID: "recording-codec",
        environmentResource: .init(
            kind: .procedural, fileName: nil, sha256: nil, inputTransformID: nil
        ),
        referenceResource: .init(
            kind: .none, fileName: nil, sha256: nil, inputTransformID: nil,
            alphaMode: nil, signalColorModel: nil, signalMatrix: nil,
            signalRange: nil, placementID: nil,
            corners: []
        )
    )
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
