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
