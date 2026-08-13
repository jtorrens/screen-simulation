import StudioColor
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func setupFramingUsesTheAuthoredCameraAndMarksTheDeviceBoundary() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let pixel: [Float] = [0.18, 0.18, 0.18, 1]
    let encoded: [Float] = Array(repeating: pixel, count: 16 * 9).flatMap { $0 }
    let source = try display.makeACEScgFrame(
        width: 16, height: 9, encodedRGBA: encoded, input: input, alpha: .straight
    )
    let device = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    authored.cameraPose.position = [0, 0, 1]
    authored.cameraPose.quaternion = [0, 0, 0, 1]
    authored.screenPose.position = [0, 0, 0]
    authored.screenPose.quaternion = [0, 0, 0, 1]
    authored.sceneLens.sensorWidthMillimeters = 36
    authored.sceneLens.sensorHeightMillimeters = 20.25
    authored.sceneLens.focalLengthMillimeters = 45
    authored.sceneLens.lensShift = [0, 0]

    let renderer = try SetupFramingRenderer(device: source.texture.device)
    let frame = try renderer.render(
        source: source, sourcePlacement: WorkspaceModel.SourcePlacement.stretch,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180,
        deliveryPlacementID: "fill-crop", deliveryBackgroundID: "black"
    )
    let values = try display.readLinearRGBA(frame)
    let pixels = stride(from: 0, to: values.count, by: 4).map {
        (values[$0], values[$0 + 1], values[$0 + 2])
    }
    let redBoundary = pixels.filter { $0.0 > 0.9 && $0.1 < 0.01 && $0.2 < 0.01 }
    let sourceInterior = pixels.filter { abs($0.0 - $0.1) < 0.01 && $0.0 > 0.01 }

    #expect(frame.width == 320)
    #expect(frame.height == 180)
    #expect(redBoundary.count > 100)
    #expect(redBoundary.count < 2_000)
    #expect(sourceInterior.count > 1_000)
}
