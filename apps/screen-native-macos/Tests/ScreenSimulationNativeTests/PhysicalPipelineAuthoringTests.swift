import Foundation
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func physicalAuthoringRoundTripsEverySnapshotDomainAndNativeUndo() async throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(
        device: device,
        coverGlass: cover
    )
    authored.environment.rotationDegrees = 37.5
    authored.sceneLens.focalLengthMillimeters = 85
    authored.shutterMotion.temporalSamples = 8
    authored.sensor.nativeWidth = 1_920
    authored.sensor.nativeHeight = 1_080
    authored.sensor.readNoiseElectronsRMS = 3.5
    authored.develop.whiteBalance = [1.1, 1, 0.9]
    authored.cameraPose.position = [0.1, -0.2, 1.5]

    let data = try JSONEncoder().encode(authored)
    let restored = try JSONDecoder().decode(
        PhysicalPipelineAuthoringState.self,
        from: data
    )
    #expect(restored == authored)
    let snapshot = try restored.resolvedPipeline().parameters
    #expect(snapshot.environment.rotation_degrees == 37.5)
    #expect(snapshot.scene_geometry_lens.focal_length_millimeters == 85)
    #expect(snapshot.shutter_motion.temporal_samples == 8)
    #expect(snapshot.sensor_noise.native_width == 1_920)
    #expect(snapshot.sensor_noise.read_noise_electrons_rms == 3.5)
    #expect(snapshot.raw_develop.white_balance.0 == 1.1)

    let workspace = WorkspaceModel()
    workspace.selectModelDevice(device, coverGlass: cover)
    let undo = UndoManager()
    workspace.updatePhysicalAuthoring(undoManager: undo) {
        $0.sceneLens.focalLengthMillimeters = 85
    }
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 85)
    undo.undo()
    await Task.yield()
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 50)
}
