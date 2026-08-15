import CoreGraphics
import simd
import StudioColor
import Testing
@testable import ScreenSimulationNative

@Test func referenceMatchInvertsEveryDeliveryRasterPlacement() throws {
    let cameraWidth: UInt32 = 4_032
    let cameraHeight: UInt32 = 3_024
    let referenceWidth = 1_920
    let referenceHeight = 1_080

    for placement in ["fit", "fill-crop", "one-to-one"] {
        let gateWidth = Double(cameraWidth)
        let gateHeight = Double(cameraHeight)
        let outputWidth = Double(referenceWidth)
        let outputHeight = Double(referenceHeight)
        let scale: Double = switch placement {
        case "fit": min(outputWidth / gateWidth, outputHeight / gateHeight)
        case "fill-crop": max(outputWidth / gateWidth, outputHeight / gateHeight)
        default: 1
        }
        let offsetX = (outputWidth - gateWidth * scale) * 0.5
        let offsetY = (outputHeight - gateHeight * scale) * 0.5
        let gateCorners = [
            CGPoint(x: 120, y: 240), CGPoint(x: 3_000, y: 240),
            CGPoint(x: 3_000, y: 2_400), CGPoint(x: 120, y: 2_400),
        ]
        let referenceCorners = gateCorners.map { point in
            CGPoint(
                x: (Double(point.x) + 0.5) * scale + offsetX - 0.5,
                y: (Double(point.y) + 0.5) * scale + offsetY - 0.5
            )
        }
        let recovered = try ReferenceMatchRasterMapping.cameraGateCorners(
            referenceCorners,
            referenceWidth: referenceWidth,
            referenceHeight: referenceHeight,
            cameraWidth: cameraWidth,
            cameraHeight: cameraHeight,
            deliveryPlacementID: placement
        )
        for index in gateCorners.indices {
            #expect(abs(recovered[index].x - gateCorners[index].x) < 0.000_001)
            #expect(abs(recovered[index].y - gateCorners[index].y) < 0.000_001)
        }
    }
}

@Test func referenceMovieIsTheTimelineAuthorityWhileItRemainsLoaded() throws {
    let source = NativeVideoTimelineInfo(exactFrameRate: .fps24, frameCount: 120)
    let reference = NativeVideoTimelineInfo(
        exactFrameRate: try ExactFrameRate(numerator: 25, denominator: 1),
        frameCount: 300
    )
    #expect(ReferenceTimelineAuthority.resolve(
        source: source, reference: reference, referenceVisible: true
    ) == reference)
    #expect(ReferenceTimelineAuthority.resolve(
        source: source, reference: reference, referenceVisible: false
    ) == source)
    #expect(ReferenceTimelineAuthority.resolve(
        source: source, reference: nil, referenceVisible: true
    ) == source)
}

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
        referencePlacement: .stretch,
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
    #expect(result.sensorGateBoundary.count == 4)
    #expect(result.corners.count == 4)
    #expect(result.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(sourceInterior.count > 1_000)
}

@Test @MainActor func setupSensorGateShowsFitFillCropAndOneToOneInsideTheDeliveryRaster() {
    let fit = SetupFramingRenderer.sensorGateBoundary(
        cameraWidth: 4_032, cameraHeight: 3_024,
        deliveryWidth: 3_840, deliveryHeight: 2_160,
        deliveryPlacement: 0, outputWidth: 3_840, outputHeight: 2_160
    )
    #expect(fit.count == 4)
    #expect(abs(fit[0].x - 479.5) < 0.001)
    #expect(abs(fit[0].y - (-0.5)) < 0.001)
    #expect(abs(fit[2].x - 3_359.5) < 0.001)
    #expect(abs(fit[2].y - 2_159.5) < 0.001)

    let fillCrop = SetupFramingRenderer.sensorGateBoundary(
        cameraWidth: 4_032, cameraHeight: 3_024,
        deliveryWidth: 3_840, deliveryHeight: 2_160,
        deliveryPlacement: 2, outputWidth: 3_840, outputHeight: 2_160
    )
    #expect(abs(fillCrop[0].x - (-0.5)) < 0.001)
    #expect(abs(fillCrop[0].y - (-360.5)) < 0.001)
    #expect(abs(fillCrop[2].x - 3_839.5) < 0.001)
    #expect(abs(fillCrop[2].y - 2_519.5) < 0.001)

    let oneToOne = SetupFramingRenderer.sensorGateBoundary(
        cameraWidth: 1_920, cameraHeight: 1_080,
        deliveryWidth: 3_840, deliveryHeight: 2_160,
        deliveryPlacement: 1, outputWidth: 3_840, outputHeight: 2_160
    )
    #expect(abs(oneToOne[0].x - 959.5) < 0.001)
    #expect(abs(oneToOne[0].y - 539.5) < 0.001)
    #expect(abs(oneToOne[2].x - 2_879.5) < 0.001)
    #expect(abs(oneToOne[2].y - 1_619.5) < 0.001)
}

@Test func reflectionAuthoringKeepsDeliveryRasterGeometryAcrossPreviewResolution() {
    let delivery = CGSize(width: 3_840, height: 2_160)
    let preview = CGSize(width: 1_920, height: 1_080)
    let authored = [
        CGPoint(x: 960, y: 540),
        CGPoint(x: 1_440, y: 540),
    ]
    let presented = ReflectionEditorRasterMapping.presentationPoints(
        authored, deliverySize: delivery, previewSize: preview
    )
    #expect(presented == [CGPoint(x: 480, y: 270), CGPoint(x: 720, y: 270)])
    for index in presented.indices {
        let recovered = ReflectionEditorRasterMapping.deliveryPoint(
            presented[index], deliverySize: delivery, previewSize: preview
        )
        #expect(recovered == authored[index])
    }
}

@Test @MainActor func referenceMatchSetupKeepsTheReferenceBehindTheRigidDevice() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let sourcePixel: [Float] = [0.8, 0.1, 0.1, 1]
    let referencePixel: [Float] = [0.05, 0.2, 0.05, 1]
    let sourcePixels = Array(repeating: sourcePixel, count: 16 * 9).flatMap { $0 }
    let referencePixels = Array(repeating: referencePixel, count: 160 * 180).flatMap { $0 }
    let source = try display.makeACEScgFrame(
        width: 16, height: 9, encodedRGBA: sourcePixels, input: input, alpha: .straight
    )
    let reference = try display.makeACEScgFrame(
        width: 160, height: 180, encodedRGBA: referencePixels, input: input, alpha: .straight
    )
    let device = try #require(try RustDeviceCatalog.builtIns().first { $0.name.contains("ASUS ProArt") })
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
    authored.sceneLens.lensShift = [0.025, -0.015]
    authored.sceneLens.radialDistortion = [-0.12, 0.025, -0.003]
    authored.sceneLens.tangentialDistortion = [0.001, -0.0008]

    let renderer = try SetupFramingRenderer(device: source.texture.device)
    let result = try renderer.renderReferenceMatch(
        source: source, reference: reference, sourcePlacement: .stretch,
        referencePlacement: .fit,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180, deliveryPlacementID: "fit"
    )
    #expect(result.frame.width == 320)
    #expect(result.frame.height == 180)
    #expect(result.boundary.count == 256)
    #expect(result.corners.count == 4)
    #expect(result.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })

    let anchorTarget = result.corners[0]
    let movingTarget = CGPoint(x: result.corners[1].x - 18, y: result.corners[1].y + 9)
    let gate = try ReferenceMatchRasterMapping.cameraGateCorners(
        [anchorTarget, movingTarget],
        referenceWidth: 320, referenceHeight: 180,
        cameraWidth: authored.sensor.nativeWidth, cameraHeight: authored.sensor.nativeHeight,
        deliveryPlacementID: "fit"
    )
    let halfWidth = device.activeWidthMeters * 0.5
    let halfHeight = device.activeHeightMeters * 0.5
    let startPose = CameraNavigationPose(
        position: SIMD3(authored.cameraPose.position[0], authored.cameraPose.position[1],
                        authored.cameraPose.position[2]),
        orientation: simd_quatd(ix: authored.cameraPose.quaternion[0],
                                iy: authored.cameraPose.quaternion[1],
                                iz: authored.cameraPose.quaternion[2],
                                r: authored.cameraPose.quaternion[3])
    )
    let moved = try #require(ReferenceAnchorCameraMath.poseKeepingAnchor(
        startPose: startPose,
        anchorWorld: SIMD3(-halfWidth, halfHeight, 0),
        movingWorld: SIMD3(halfWidth, halfHeight, 0),
        anchorTargetPixel: gate[0], movingTargetPixel: gate[1],
        imageSize: CGSize(width: Int(authored.sensor.nativeWidth),
                          height: Int(authored.sensor.nativeHeight)),
        focalLengthMillimeters: authored.sceneLens.focalLengthMillimeters,
        sensorSizeMillimeters: CGSize(width: authored.sceneLens.sensorWidthMillimeters,
                                      height: authored.sceneLens.sensorHeightMillimeters),
        lensShift: SIMD2(authored.sceneLens.lensShift[0], authored.sceneLens.lensShift[1]),
        radialDistortion: SIMD3(authored.sceneLens.radialDistortion[0],
                                authored.sceneLens.radialDistortion[1],
                                authored.sceneLens.radialDistortion[2]),
        tangentialDistortion: SIMD2(authored.sceneLens.tangentialDistortion[0],
                                    authored.sceneLens.tangentialDistortion[1])
    ))
    authored.cameraPose.position = [moved.position.x, moved.position.y, moved.position.z]
    authored.cameraPose.quaternion = [moved.orientation.imag.x, moved.orientation.imag.y,
                                      moved.orientation.imag.z, moved.orientation.real]
    let movedResult = try renderer.renderReferenceMatch(
        source: source, reference: reference, sourcePlacement: .stretch,
        referencePlacement: .fit,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180, deliveryPlacementID: "fit"
    )
    #expect(hypot(movedResult.corners[0].x - anchorTarget.x,
                  movedResult.corners[0].y - anchorTarget.y) < 0.01)
    #expect(hypot(movedResult.corners[1].x - movingTarget.x,
                  movedResult.corners[1].y - movingTarget.y) < 0.01)

    let cameraResultPixels = Array(
        repeating: [Float(0.7), Float(0.05), Float(0.05), Float(1)], count: 320 * 180
    ).flatMap { $0 }
    let cameraResult = try display.makeACEScgFrame(
        width: 320, height: 180, encodedRGBA: cameraResultPixels,
        input: input, alpha: .straight
    )
    let composite = try renderer.renderReferenceComposite(
        cameraResult: cameraResult, reference: reference,
        referencePlacement: .fit,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180, deliveryPlacementID: "fit"
    )
    let compositeValues = try display.readLinearRGBA(composite.frame)
    let referenceValues = try display.readLinearRGBA(reference)
    let cameraValues = try display.readLinearRGBA(cameraResult)
    let compositePixels = stride(from: 0, to: compositeValues.count, by: 4).map {
        SIMD3(compositeValues[$0], compositeValues[$0 + 1], compositeValues[$0 + 2])
    }
    let referenceColor = SIMD3(referenceValues[0], referenceValues[1], referenceValues[2])
    let cameraColor = SIMD3(cameraValues[0], cameraValues[1], cameraValues[2])
    let cameraDelta = cameraColor - referenceColor
    let cameraDeltaSquared = simd_length_squared(cameraDelta)
    #expect(composite.frame.width == 320)
    #expect(composite.frame.height == 180)
    #expect(compositePixels.contains { simd_distance($0, referenceColor) < 0.001 })
    #expect(compositePixels.contains { simd_distance($0, cameraColor) < 0.001 })
    #expect(compositePixels.contains { simd_length($0) < 0.001 })
    #expect(compositePixels.contains { pixel in
        let amount = simd_dot(pixel - referenceColor, cameraDelta) / cameraDeltaSquared
        let reconstructed = referenceColor + cameraDelta * amount
        return amount > 0.01 && amount < 0.99
            && simd_distance(pixel, reconstructed) < 0.002
    })

    let alignedWidth = 200
    let alignedHeight = 100
    let alignedPixels = (0 ..< alignedHeight).flatMap { _ in
        (0 ..< alignedWidth).flatMap { x in
            [Float(x) / Float(alignedWidth - 1), Float(0.1), Float(0.2), Float(1)]
        }
    }
    let aligned = try display.makeACEScgFrame(
        width: alignedWidth, height: alignedHeight, encodedRGBA: alignedPixels,
        input: input, alpha: .straight
    )
    let alignedComposite = try renderer.renderReferenceComposite(
        cameraResult: aligned, reference: reference,
        referencePlacement: .fit,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180, deliveryPlacementID: "fit",
        deliveryAligned: true
    )
    let alignedSourceValues = try display.readLinearRGBA(aligned)
    let alignedValues = try display.readLinearRGBA(alignedComposite.frame)
    let fullyCovered = stride(from: 0, to: alignedValues.count, by: 4).first {
        abs(alignedValues[$0 + 1] - alignedSourceValues[1]) < 0.005
            && abs(alignedValues[$0 + 2] - alignedSourceValues[2]) < 0.005
    }
    let alignedOffset = try #require(fullyCovered)
    let alignedX = (alignedOffset / 4) % 320
    let sourceX = min(
        alignedWidth - 1,
        max(0, Int(((Float(alignedX) + 0.5) / 320 * Float(alignedWidth)).rounded(.down)))
    )
    let expectedRed = alignedSourceValues[sourceX * 4]
    #expect(abs(alignedValues[alignedOffset] - expectedRed) < 0.02)
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
        referencePlacement: .stretch,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 240,
        deliveryPlacementID: "fit", deliveryBackgroundID: "black"
    )
    let oneToOne = try renderer.render(
        source: source, sourcePlacement: .stretch,
        referencePlacement: .stretch,
        device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 240,
        deliveryPlacementID: "one-to-one", deliveryBackgroundID: "black"
    )
    let interactive = try renderer.render(
        source: source, sourcePlacement: .stretch,
        referencePlacement: .stretch,
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

@Test @MainActor func environmentSetupClipsToTheDeviceAndUsesItsLocalSphere() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let width = 32
    let height = 16
    var encoded: [Float] = []
    encoded.reserveCapacity(width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            encoded.append(Float(x) / Float(width - 1))
            encoded.append(Float(y) / Float(height - 1))
            encoded.append(0.25)
            encoded.append(1)
        }
    }
    let environment = try display.makeACEScgFrame(
        width: width, height: height, encodedRGBA: encoded, input: input, alpha: .straight
    )
    let device = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    authored.cameraPose.position = [0, 0, 2]
    authored.cameraPose.quaternion = [0, 0, 0, 1]
    authored.screenPose.position = [0, 0, 0]
    authored.screenPose.quaternion = PoseRotationProjection.quaternion(fromDegrees: [0, 18, 0])
    authored.sceneLens.sensorWidthMillimeters = 36
    authored.sceneLens.sensorHeightMillimeters = 20.25
    authored.sceneLens.focalLengthMillimeters = 45
    authored.sceneLens.lensShift = [0, 0]
    authored.environment.projectionMode = 1
    authored.environment.sphereRadiusMeters = 5

    let renderer = try SetupFramingRenderer(device: environment.texture.device)
    let base = try renderer.renderEnvironment(
        environment: environment, device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180,
        deliveryPlacementID: "fill-crop", deliveryBackgroundID: "black"
    )
    let basePixels = try display.readLinearRGBA(base.frame)
    let corner = 0
    let center = ((base.frame.height / 2) * base.frame.width + base.frame.width / 2) * 4
    #expect(basePixels[corner] == 0 && basePixels[corner + 1] == 0 && basePixels[corner + 2] == 0)
    #expect(basePixels[center] > 0 || basePixels[center + 1] > 0 || basePixels[center + 2] > 0)

    authored.cameraPose.position[0] += 0.4
    authored.screenPose.position[0] += 0.4
    let translated = try renderer.renderEnvironment(
        environment: environment, device: device, pipeline: authored,
        deliveryWidth: 320, deliveryHeight: 180,
        deliveryPlacementID: "fill-crop", deliveryBackgroundID: "black"
    )
    let translatedPixels = try display.readLinearRGBA(translated.frame)
    #expect(basePixels.count == translatedPixels.count)
    #expect(zip(basePixels, translatedPixels).allSatisfy { abs($0 - $1) < 0.000_01 })
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
