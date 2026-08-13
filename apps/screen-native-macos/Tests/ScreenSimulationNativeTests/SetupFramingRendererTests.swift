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
    let result = try renderer.render(
        source: source, sourcePlacement: WorkspaceModel.SourcePlacement.stretch,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180,
        deliveryPlacementID: "fill-crop", deliveryBackgroundID: "black"
    )
    let frame = result.frame
    let values = try display.readLinearRGBA(frame)
    let pixels = stride(from: 0, to: values.count, by: 4).map {
        (values[$0], values[$0 + 1], values[$0 + 2])
    }
    let sourceInterior = pixels.filter { abs($0.0 - $0.1) < 0.01 && $0.0 > 0.01 }

    #expect(frame.width == 320)
    #expect(frame.height == 180)
    #expect(result.boundary.count == 4)
    #expect(result.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(sourceInterior.count > 1_000)
}

@Test @MainActor func setupFramingRecomputesDeliveryPlacementWithoutLosingTheBoundary() throws {
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
    let fit = try renderer.render(
        source: source, sourcePlacement: .stretch,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 240,
        deliveryPlacementID: "fit", deliveryBackgroundID: "black"
    )
    let oneToOne = try renderer.render(
        source: source, sourcePlacement: .stretch,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 240,
        deliveryPlacementID: "one-to-one", deliveryBackgroundID: "black"
    )
    let interactive = try renderer.render(
        source: source, sourcePlacement: .stretch,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 240,
        deliveryPlacementID: "fit", deliveryBackgroundID: "black",
        previewWidth: 160, previewHeight: 120
    )

    #expect(fit.boundary.count == 4)
    #expect(oneToOne.boundary.count == 4)
    #expect(fit.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(oneToOne.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(fit.boundary != oneToOne.boundary)
    #expect(try display.readLinearRGBA(fit.frame) != display.readLinearRGBA(oneToOne.frame))
    #expect(interactive.frame.width == 160)
    #expect(interactive.frame.height == 120)
    for index in fit.boundary.indices {
        #expect(abs(interactive.boundary[index].x - (fit.boundary[index].x + 0.5) * 0.5 + 0.5) < 0.001)
        #expect(abs(interactive.boundary[index].y - (fit.boundary[index].y + 0.5) * 0.5 + 0.5) < 0.001)
    }
}

@Test @MainActor func focusSetupClipsItsChartAndDistortedBoundaryToTheDevice() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let encoded = Array(repeating: Float(0.18), count: 16 * 9 * 4)
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
    authored.screenPose.quaternion = PoseRotationProjection.quaternion(fromDegrees: [0, 20, 0])
    authored.sceneLens.sensorWidthMillimeters = 36
    authored.sceneLens.sensorHeightMillimeters = 20.25
    authored.sceneLens.focalLengthMillimeters = 45
    authored.sceneLens.focusDistanceMeters = 1
    authored.sceneLens.fStop = 2.8
    authored.sceneLens.radialDistortion = [0.18, -0.04, 0.01]
    authored.sceneLens.tangentialDistortion = [0.01, -0.005]

    let renderer = try SetupFramingRenderer(device: source.texture.device)
    let result = try renderer.renderFocus(
        source: source, device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180,
        deliveryPlacementID: "fill-crop", deliveryBackgroundID: "black"
    )
    let values = try display.readLinearRGBA(result.frame)
    let luminance = stride(from: 0, to: values.count, by: 4).map { values[$0] }
    #expect(result.boundary.count == 256)
    #expect(result.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(luminance.contains { $0 == 0 })
    #expect(luminance.contains { $0 > 0.95 })
    #expect(luminance.contains { index in index > 0 && index < 0.95 })
}
