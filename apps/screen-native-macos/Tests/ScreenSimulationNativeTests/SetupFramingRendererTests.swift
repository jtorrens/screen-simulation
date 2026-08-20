import CoreGraphics
import ScreenPhysicalBridge
import simd
import StudioColor
import Testing
@testable import ScreenSimulationNative

private func setupPlan(
    authored: PhysicalPipelineAuthoringState,
    device: DeviceDefinition,
    deliveryWidth: Int,
    deliveryHeight: Int,
    placement: String,
    background: String = "black",
    previewWidth: Int? = nil,
    previewHeight: Int? = nil
) -> ScreenSetupDiagnosticPlanV1 {
    var plan = ScreenSetupDiagnosticPlanV1()
    plan.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
    plan.camera_rotation_xyzw = (
        Float(authored.cameraPose.quaternion[0]), Float(authored.cameraPose.quaternion[1]),
        Float(authored.cameraPose.quaternion[2]), Float(authored.cameraPose.quaternion[3])
    )
    plan.camera_position = (
        Float(authored.cameraPose.position[0]), Float(authored.cameraPose.position[1]),
        Float(authored.cameraPose.position[2])
    )
    plan.screen_rotation_xyzw = (
        Float(authored.screenPose.quaternion[0]), Float(authored.screenPose.quaternion[1]),
        Float(authored.screenPose.quaternion[2]), Float(authored.screenPose.quaternion[3])
    )
    plan.screen_position = (
        Float(authored.screenPose.position[0]), Float(authored.screenPose.position[1]),
        Float(authored.screenPose.position[2])
    )
    plan.active_sensor_width = authored.sensor.nativeWidth
    plan.active_sensor_height = authored.sensor.nativeHeight
    plan.device_native_width = UInt32(device.nativeWidth)
    plan.device_native_height = UInt32(device.nativeHeight)
    plan.device_active_width_meters = Float(device.activeWidthMeters)
    plan.device_active_height_meters = Float(device.activeHeightMeters)
    plan.device_corner_radius_meters = Float(device.cornerRadiusMeters)
    plan.focal_length_millimeters = Float(authored.sceneLens.focalLengthMillimeters)
    plan.sensor_width_millimeters = Float(authored.sceneLens.sensorWidthMillimeters)
    plan.sensor_height_millimeters = Float(authored.sceneLens.sensorHeightMillimeters)
    plan.lens_shift = (
        Float(authored.sceneLens.lensShift[0]), Float(authored.sceneLens.lensShift[1])
    )
    plan.focus_distance_meters = Float(authored.sceneLens.focusDistanceMeters)
    plan.f_stop = Float(authored.sceneLens.fStop)
    plan.lens_radial_distortion = (
        Float(authored.sceneLens.radialDistortion[0]),
        Float(authored.sceneLens.radialDistortion[1]),
        Float(authored.sceneLens.radialDistortion[2])
    )
    plan.lens_tangential_distortion = (
        Float(authored.sceneLens.tangentialDistortion[0]),
        Float(authored.sceneLens.tangentialDistortion[1])
    )
    plan.environment_rotation_radians = (
        Float(authored.environment.rotationXDegrees * .pi / 180),
        Float(authored.environment.rotationYDegrees * .pi / 180)
    )
    plan.environment_placement_anchor_direction_world = (
        Float(authored.environment.placementAnchorDirectionWorld[0]),
        Float(authored.environment.placementAnchorDirectionWorld[1]),
        Float(authored.environment.placementAnchorDirectionWorld[2])
    )
    plan.environment_placement_source_direction = (
        Float(authored.environment.placementSourceDirection[0]),
        Float(authored.environment.placementSourceDirection[1]),
        Float(authored.environment.placementSourceDirection[2])
    )
    plan.environment_placement_tangent_transform = (
        Float(authored.environment.placementTangentTransform[0]),
        Float(authored.environment.placementTangentTransform[1]),
        Float(authored.environment.placementTangentTransform[2]),
        Float(authored.environment.placementTangentTransform[3])
    )
    plan.environment_finite_sphere = authored.environment.projectionMode == 1
    plan.environment_sphere_center_meters = (
        Float(authored.environment.sphereCenterMeters[0]),
        Float(authored.environment.sphereCenterMeters[1]),
        Float(authored.environment.sphereCenterMeters[2])
    )
    plan.environment_sphere_radius_meters = Float(authored.environment.sphereRadiusMeters)
    plan.delivery_width = UInt32(deliveryWidth)
    plan.delivery_height = UInt32(deliveryHeight)
    plan.preview_width = UInt32(previewWidth ?? deliveryWidth)
    plan.preview_height = UInt32(previewHeight ?? deliveryHeight)
    plan.delivery_placement = switch placement {
    case "fit": 0
    case "one-to-one": 1
    default: 2
    }
    plan.delivery_background = background == "transparent" ? 0 : 1
    return plan
}

@Test @MainActor func interactiveBackgroundsAreExplicitAndQueueCompositionRemainsIndependent() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let width = 64
    let height = 64
    let transparent = try display.makeACEScgFrame(
        width: width, height: height,
        encodedRGBA: Array(repeating: 0, count: width * height * 4),
        input: input, alpha: .straight
    )
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(
        device: device, coverGlass: cover
    )
    authored.cameraPose.position = [0, 0, 1]
    authored.cameraPose.quaternion = [0, 0, 0, 1]
    authored.screenPose.position = [0, 0, 0]
    authored.screenPose.quaternion = [0, 0, 0, 1]
    authored.sceneLens.sensorWidthMillimeters = 36
    authored.sceneLens.sensorHeightMillimeters = 36
    authored.sceneLens.focalLengthMillimeters = 45
    let plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: width, deliveryHeight: height, placement: "fit"
    )
    let renderer = try SetupFramingRenderer(device: transparent.texture.device)

    func values(_ background: InteractivePreviewBackground) throws -> [Float] {
        let result = try renderer.renderCameraComposite(
            cameraResult: transparent,
            reference: nil,
            referencePlacement: .fit,
            plan: plan,
            deliveryAligned: true,
            interactiveBackground: background
        )
        return try display.readLinearRGBA(result.frame)
    }

    let black = try values(.black)
    let white = try values(.white)
    let gray = try values(.middleGray)
    let checker = try values(.vfxChecker)
    let missingReference = try values(.reference)
    #expect(abs(black[0]) < 0.0001)
    #expect(abs(white[0] - 1) < 0.0001)
    #expect(abs(gray[0] - 0.18) < 0.0001)
    #expect(abs(checker[0] - 1) < 0.0001)
    #expect(abs(checker[40 * 4] - 0.18) < 0.0001)
    #expect(abs(missingReference[0]) < 0.0001)

    let center = ((height / 2) * width + width / 2) * 4
    // Native camera output substitutes the same plate even while applying its
    // camera-to-delivery placement.
    let nativeWhite = try renderer.renderCameraComposite(
        cameraResult: transparent,
        reference: nil,
        referencePlacement: .fit,
        plan: plan,
        deliveryAligned: false,
        interactiveBackground: .white
    )
    let nativeWhiteValues = try display.readLinearRGBA(nativeWhite.frame)
    #expect(abs(nativeWhiteValues[center] - 1) < 0.0001)
    #expect(abs(nativeWhiteValues[center + 1] - 1) < 0.0001)
    #expect(abs(nativeWhiteValues[center + 2] - 1) < 0.0001)

    let setup = try renderer.render(
        source: transparent,
        sourcePlacement: .stretch,
        referencePlacement: .fit,
        plan: plan,
        interactiveBackground: .white
    )
    let setupValues = try display.readLinearRGBA(setup.frame)
    #expect(setup.boundary.count >= 4)
    #expect(abs(setupValues[center] - 1) < 0.0001)
    #expect(abs(setupValues[center + 1] - 1) < 0.0001)
    #expect(abs(setupValues[center + 2] - 1) < 0.0001)

    // No interactive choice is passed by Render Queue. Its explicit plan remains
    // the sole owner of that output composition.
    let queueResult = try renderer.renderCameraComposite(
        cameraResult: transparent,
        reference: nil,
        referencePlacement: .fit,
        plan: plan,
        deliveryAligned: true
    )
    let queueValues = try display.readLinearRGBA(queueResult.frame)
    #expect(abs(queueValues[0]) < 0.0001)
}

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

@Test func trackingOverlayProjectionUsesTheSameDeliveryAndPreviewMappingAsTheDevice() throws {
    let gateCenter = CGPoint(x: 2_015.5, y: 1_511.5)
    for placement in ["fit", "fill-crop", "one-to-one"] {
        let preview = try ReferenceMatchRasterMapping.previewPoints(
            [gateCenter],
            deliveryWidth: 3_840,
            deliveryHeight: 2_160,
            previewWidth: 1_280,
            previewHeight: 720,
            cameraWidth: 4_032,
            cameraHeight: 3_024,
            deliveryPlacementID: placement
        )
        let point = try #require(preview.first)
        #expect(abs(point.x - 639.5) < 0.000_001)
        #expect(abs(point.y - 359.5) < 0.000_001)
    }

    let shifted = try ReferenceMatchRasterMapping.previewPoints(
        [CGPoint(x: 3_023.5, y: 1_511.5)],
        deliveryWidth: 3_840,
        deliveryHeight: 2_160,
        previewWidth: 960,
        previewHeight: 540,
        cameraWidth: 4_032,
        cameraHeight: 3_024,
        deliveryPlacementID: "fit"
    )
    let shiftedPoint = try #require(shifted.first)
    #expect(abs(shiftedPoint.x - 659.5) < 0.000_001)
    #expect(abs(shiftedPoint.y - 269.5) < 0.000_001)
}

@Test func trackingPlateScalesFromHDToUHDWithoutChangingCameraGeometry() throws {
    let platePoints = [
        CGPoint(x: -0.5, y: -0.5),
        CGPoint(x: 959.5, y: 539.5),
        CGPoint(x: 1_919.5, y: 1_079.5),
    ]
    let output = try ReferenceMatchRasterMapping.previewPoints(
        platePoints,
        deliveryWidth: 3_840,
        deliveryHeight: 2_160,
        previewWidth: 3_840,
        previewHeight: 2_160,
        cameraWidth: 1_920,
        cameraHeight: 1_080,
        deliveryPlacementID: "fill-crop"
    )
    #expect(output == [
        CGPoint(x: -0.5, y: -0.5),
        CGPoint(x: 1_919.5, y: 1_079.5),
        CGPoint(x: 3_839.5, y: 2_159.5),
    ])
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

@Test func trackingTimelineDrivesAStaticSourceAndStartsAtFrameZero() throws {
    let still = NativeVideoTimelineInfo(exactFrameRate: .fps24, frameCount: 1)
    let tracking = NativeVideoTimelineInfo(
        exactFrameRate: try ExactFrameRate(numerator: 25, denominator: 1),
        frameCount: 100
    )
    #expect(ReferenceTimelineAuthority.resolve(
        source: still, reference: nil, referenceVisible: false, tracking: tracking
    ) == tracking)
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
    let plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let result = try renderer.render(
        source: source, sourcePlacement: WorkspaceModel.SourcePlacement.stretch,
        referencePlacement: .stretch,
        plan: plan
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

@Test @MainActor func focusTargetProjectionAndInverseUseTheSameDistortedCameraContract() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    authored.cameraPose.position = [0.08, 0.03, 0.62]
    authored.cameraPose.quaternion = [0, 0, 0, 1]
    authored.screenPose.position = [0, 0, 0]
    authored.screenPose.quaternion = [0, 0.12, 0, sqrt(1 - 0.12 * 0.12)]
    authored.sceneLens.sensorWidthMillimeters = 36
    authored.sceneLens.sensorHeightMillimeters = 20.25
    authored.sceneLens.focalLengthMillimeters = 50
    authored.sceneLens.lensShift = [0.03, -0.02]
    authored.sceneLens.radialDistortion = [-0.08, 0.015, -0.001]
    authored.sceneLens.tangentialDistortion = [0.002, -0.001]
    let plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 3_840, deliveryHeight: 2_160,
        placement: "fill-crop", previewWidth: 1_280, previewHeight: 720
    )

    let expected = SIMD2<Double>(0.23, 0.71)
    let projected = try #require(SetupFramingRenderer.projectedDevicePoint(
        u: Float(expected.x), v: Float(expected.y),
        plan: plan,
        applyLensDistortion: true
    ))
    let recovered = try #require(SetupFramingRenderer.deviceUV(
        at: projected, plan: plan
    ))
    #expect(abs(recovered.x - expected.x) < 0.000_1)
    #expect(abs(recovered.y - expected.y) < 0.000_1)
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
    var plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fit"
    )
    let result = try renderer.renderReferenceMatch(
        source: source, reference: reference, sourcePlacement: .stretch,
        referencePlacement: .fit,
        plan: plan
    )
    #expect(result.frame.width == 320)
    #expect(result.frame.height == 180)
    #expect(result.boundary.count == 256)
    #expect(result.corners.count == 4)
    #expect(result.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    let resultValues = try display.readLinearRGBA(result.frame)
    let expectedReference = SIMD3<Float>(
        resultValues[0], resultValues[1], resultValues[2]
    )
    let decodedSource = try display.readLinearRGBA(source)
    #expect(simd_length(expectedReference) < 0.001)
    #expect(simd_distance(
        expectedReference,
        SIMD3(decodedSource[0], decodedSource[1], decodedSource[2])
    ) > 0.05)

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
    plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fit"
    )
    let movedResult = try renderer.renderReferenceMatch(
        source: source, reference: reference, sourcePlacement: .stretch,
        referencePlacement: .fit,
        plan: plan
    )
    #expect(hypot(movedResult.corners[0].x - anchorTarget.x,
                  movedResult.corners[0].y - anchorTarget.y) < 0.01)
    #expect(hypot(movedResult.corners[1].x - movingTarget.x,
                  movedResult.corners[1].y - movingTarget.y) < 0.01)

    let projectedMinimumX = movedResult.corners.map(\.x).min() ?? 0
    let projectedMaximumX = movedResult.corners.map(\.x).max() ?? 0
    let projectedMinimumY = movedResult.corners.map(\.y).min() ?? 0
    let projectedMaximumY = movedResult.corners.map(\.y).max() ?? 0
    var cameraResultPixels: [Float] = []
    cameraResultPixels.reserveCapacity(320 * 180 * 4)
    for y in 0 ..< 180 {
        for x in 0 ..< 320 {
            let pixelX = CGFloat(x)
            let pixelY = CGFloat(y)
            let insideHorizontal = pixelX >= projectedMinimumX && pixelX <= projectedMaximumX
            let insideVertical = pixelY >= projectedMinimumY && pixelY <= projectedMaximumY
            let insideProjectedBounds = insideHorizontal && insideVertical
            cameraResultPixels.append(contentsOf: insideProjectedBounds
                ? [0.7, 0.05, 0.05, 1]
                // Physical RGB outside the Device is the panel/cover glow.
                // Device VFX Transparency publishes the independent occlusion
                // matte in alpha; glow remains an additive RGB contribution.
                : [0.015, 0.01, 0.005, 0])
        }
    }
    let cameraResult = try display.makeACEScgFrame(
        width: 320, height: 180, encodedRGBA: cameraResultPixels,
        input: input, alpha: .straight
    )
    let composite = try renderer.renderReferenceComposite(
        cameraResult: cameraResult, reference: reference,
        referencePlacement: .fit,
        plan: plan
    )
    let compositeValues = try display.readLinearRGBA(composite.frame)
    let referenceValues = try display.readLinearRGBA(reference)
    let cameraValues = try display.readLinearRGBA(cameraResult)
    let compositePixels = stride(from: 0, to: compositeValues.count, by: 4).map {
        SIMD3(compositeValues[$0], compositeValues[$0 + 1], compositeValues[$0 + 2])
    }
    let referenceColor = SIMD3(referenceValues[0], referenceValues[1], referenceValues[2])
    var cameraColor = SIMD3<Float>.zero
    for offset in stride(from: 0, to: cameraValues.count, by: 4) {
        let candidate = SIMD3(
            cameraValues[offset], cameraValues[offset + 1], cameraValues[offset + 2]
        )
        if candidate.x > cameraColor.x { cameraColor = candidate }
    }
    #expect(composite.frame.width == 320)
    #expect(composite.frame.height == 180)
    #expect(compositePixels.contains { simd_distance($0, cameraColor) < 0.001 })
    let outsideOffset = try #require(stride(from: 0, to: cameraValues.count, by: 4).first {
        cameraValues[$0] < cameraColor.x * 0.5
    })
    let glowColor = SIMD3(
        cameraValues[outsideOffset], cameraValues[outsideOffset + 1], cameraValues[outsideOffset + 2]
    )
    #expect(compositePixels.contains {
        simd_distance($0, referenceColor + glowColor) < 0.002
    })
    #expect(compositePixels.contains { simd_distance($0, glowColor) < 0.002 })

    let deviceOnly = try renderer.renderCameraComposite(
        cameraResult: cameraResult, reference: nil,
        referencePlacement: .fit,
        plan: plan
    )
    let deviceOnlyValues = try display.readLinearRGBA(deviceOnly.frame)
    let deviceOnlyPixels = stride(from: 0, to: deviceOnlyValues.count, by: 4).map {
        SIMD3(deviceOnlyValues[$0], deviceOnlyValues[$0 + 1], deviceOnlyValues[$0 + 2])
    }
    #expect(deviceOnly.frame.width == 320)
    #expect(deviceOnly.frame.height == 180)
    #expect(deviceOnlyPixels.contains { simd_distance($0, glowColor) < 0.002 })
    #expect(deviceOnlyPixels.contains { simd_distance($0, cameraColor) < 0.001 })

    let alignedWidth = 200
    let alignedHeight = 100
    let alignedPixels = (0 ..< alignedHeight).flatMap { _ in
        (0 ..< alignedWidth).flatMap { x in
            let alpha = Float(x) / Float(alignedWidth - 1)
            // RGB is already the premultiplied additive Device contribution.
            return [0.6 * alpha, 0.1 * alpha, 0.2 * alpha, alpha]
        }
    }
    let aligned = try display.makeACEScgFrame(
        width: alignedWidth, height: alignedHeight, encodedRGBA: alignedPixels,
        input: input, alpha: .straight
    )
    let alignedComposite = try renderer.renderReferenceComposite(
        cameraResult: aligned, reference: reference,
        referencePlacement: .fit,
        plan: plan,
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

    // A fractional matte must be consumed directly, independently of the
    // projected Device polygon. This canonical gradient proves that Swift
    // neither reconstructs coverage nor multiplies Device RGB a second time.
    let gradientX = 160
    let gradientY = 90
    let gradientOffset = (gradientY * 320 + gradientX) * 4
    let gradientSourceX = min(
        alignedWidth - 1,
        max(0, Int(((Float(gradientX) + 0.5) / 320 * Float(alignedWidth)).rounded(.down)))
    )
    let gradientSourceOffset = gradientSourceX * 4
    let gradientAlpha = alignedSourceValues[gradientSourceOffset + 3]
    for channel in 0 ..< 3 {
        let expected = alignedSourceValues[gradientSourceOffset + channel]
            + referenceValues[channel] * (1 - gradientAlpha)
        #expect(abs(alignedValues[gradientOffset + channel] - expected) < 0.02)
    }
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
    let fitPlan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 240, placement: "fit"
    )
    let oneToOnePlan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 240, placement: "one-to-one"
    )
    let interactivePlan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 240, placement: "fit",
        previewWidth: 160, previewHeight: 120
    )
    let fit = try renderer.render(
        source: source, sourcePlacement: .stretch,
        referencePlacement: .stretch,
        plan: fitPlan
    )
    let oneToOne = try renderer.render(
        source: source, sourcePlacement: .stretch,
        referencePlacement: .stretch,
        plan: oneToOnePlan
    )
    let interactive = try renderer.render(
        source: source, sourcePlacement: .stretch,
        referencePlacement: .stretch,
        plan: interactivePlan
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

@Test @MainActor func environmentSetupUsesTheAuthoredFiniteSphereCenter() throws {
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
    var plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let base = try renderer.renderEnvironment(
        environment: environment, plan: plan
    )
    let basePixels = try display.readLinearRGBA(base.frame)
    let corner = 0
    let center = ((base.frame.height / 2) * base.frame.width + base.frame.width / 2) * 4
    #expect(basePixels[corner + 2] > 0)
    #expect(basePixels[center] > 0 || basePixels[center + 1] > 0 || basePixels[center + 2] > 0)

    authored.cameraPose.position[0] += 0.4
    authored.screenPose.position[0] += 0.4
    plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let translated = try renderer.renderEnvironment(
        environment: environment, plan: plan
    )
    let translatedPixels = try display.readLinearRGBA(translated.frame)
    #expect(basePixels.count == translatedPixels.count)
    #expect(zip(basePixels, translatedPixels).contains { abs($0 - $1) > 0.000_01 })
    #expect(translatedPixels[corner + 2] > 0)

    authored.environment.sphereCenterMeters = [0.4, 0, 0]
    plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let coTranslated = try renderer.renderEnvironment(
        environment: environment, plan: plan
    )
    let coTranslatedPixels = try display.readLinearRGBA(coTranslated.frame)
    #expect(zip(basePixels, coTranslatedPixels).allSatisfy { abs($0 - $1) < 0.000_1 })
}

@Test @MainActor func environmentSetupDimsOnlyTheSphereOutsideTheProjectedDevice() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let pixel: [Float] = [0.5, 0.5, 0.5, 1]
    let encoded = Array(repeating: pixel, count: 16 * 8).flatMap { $0 }
    let environment = try display.makeACEScgFrame(
        width: 16, height: 8, encodedRGBA: encoded, input: input, alpha: .straight
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
    authored.screenPose.quaternion = [0, 0, 0, 1]
    authored.sceneLens.sensorWidthMillimeters = 36
    authored.sceneLens.sensorHeightMillimeters = 20.25
    authored.sceneLens.focalLengthMillimeters = 45
    authored.sceneLens.lensShift = [0, 0]
    authored.environment.projectionMode = 0

    let renderer = try SetupFramingRenderer(device: environment.texture.device)
    let plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let result = try renderer.renderEnvironment(
        environment: environment, plan: plan
    )
    let values = try display.readLinearRGBA(result.frame)
    let outside = 0
    let inside = ((result.frame.height / 2) * result.frame.width + result.frame.width / 2) * 4
    for channel in 0 ..< 3 {
        #expect(values[inside + channel] > 0)
        #expect(abs(values[outside + channel] / values[inside + channel] - 0.20) < 0.005)
    }
    #expect(values[outside + 3] == 1)
    #expect(values[inside + 3] == 1)
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
    let plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let result = try renderer.renderFocus(
        source: source, plan: plan
    )
    let values = try display.readLinearRGBA(result.frame)
    let luminance = stride(from: 0, to: values.count, by: 4).map { values[$0] }
    #expect(result.boundary.count == 256)
    #expect(result.boundary.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(luminance.contains { $0 == 0 })
    #expect(luminance.contains { $0 > 0.95 })
    #expect(luminance.contains { index in index > 0 && index < 0.95 })
}

@Test @MainActor func sphericalEnvironmentPlacementMatchesPlanarAidAtCalibrationAnchor() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first { $0.id == "acescg" })
    let width = 64
    let height = 32
    var encoded: [Float] = []
    for y in 0 ..< height {
        for x in 0 ..< width {
            encoded += [Float(x) / 63, Float(y) / 31, 0.25, 1]
        }
    }
    let environment = try display.makeACEScgFrame(
        width: width, height: height, encodedRGBA: encoded, input: input, alpha: .straight
    )
    let device = try #require(try RustDeviceCatalog.builtIns().first {
        $0.category == .phone
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
    authored.environment.projectionMode = 0
    let framing = EnvironmentReflectionFraming(
        centerX: 0.68, centerY: 0.31, zoom: 2.4, rollDegrees: 17
    )
    let setup = try SetupFramingRenderer(device: environment.texture.device)
    var plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let planar = try setup.renderEnvironment(
        environment: environment, plan: plan,
        planarFraming: framing.shaderValue
    )
    let longitude = (framing.centerX - 0.5) * 2 * Double.pi
    let latitude = (0.5 - framing.centerY) * Double.pi
    authored.environment.placementAnchorDirectionWorld = [0, 0, 1]
    authored.environment.placementSourceDirection = [
        sin(longitude) * cos(latitude), sin(latitude), cos(longitude) * cos(latitude),
    ]
    let roll = -framing.rollDegrees * .pi / 180
    authored.environment.placementTangentTransform = [
        cos(roll) / framing.zoom, sin(roll) / framing.zoom, 0, 0,
    ]
    plan = setupPlan(
        authored: authored, device: device,
        deliveryWidth: 320, deliveryHeight: 180, placement: "fill-crop"
    )
    let reflected = try setup.renderEnvironment(
        environment: environment, plan: plan
    )
    let a = try display.readLinearRGBA(planar.frame)
    let b = try display.readLinearRGBA(reflected.frame)
    let center = ((planar.frame.height / 2) * planar.frame.width + planar.frame.width / 2) * 4
    for channel in 0 ..< 3 {
        #expect(abs(a[center + channel] - b[center + channel]) < 0.04)
    }
    let planarBounds = planar.boundary.reduce(
        (minX: Double.greatestFiniteMagnitude, minY: Double.greatestFiniteMagnitude,
         maxX: -Double.greatestFiniteMagnitude, maxY: -Double.greatestFiniteMagnitude)
    ) { bounds, point in
        (min(bounds.minX, point.x), min(bounds.minY, point.y),
         max(bounds.maxX, point.x), max(bounds.maxY, point.y))
    }
    let navigationY = Int((planarBounds.minY + planarBounds.maxY) * 0.5)
    let navigationOutsideX = max(0, Int(planarBounds.minX) - 2)
    let navigationInsideX = min(planar.frame.width - 1, Int(planarBounds.minX) + 2)
    let navigationOutside = (navigationY * planar.frame.width + navigationOutsideX) * 4
    let navigationInside = (navigationY * planar.frame.width + navigationInsideX) * 4
    #expect(a[navigationOutside] > 0)
    #expect(a[navigationInside] > 0)
    #expect(a[navigationOutside] < a[navigationInside] * 0.35)
    let fittedPlanar = try setup.renderEnvironment(
        environment: environment, plan: plan,
        planarFraming: EnvironmentReflectionFraming().shaderValue
    )
    let fittedValues = try display.readLinearRGBA(fittedPlanar.frame)
    let bounds = fittedPlanar.boundary.reduce(
        (minX: Double.greatestFiniteMagnitude, minY: Double.greatestFiniteMagnitude,
         maxX: -Double.greatestFiniteMagnitude, maxY: -Double.greatestFiniteMagnitude)
    ) { bounds, point in
        (min(bounds.minX, point.x), min(bounds.minY, point.y),
         max(bounds.maxX, point.x), max(bounds.maxY, point.y))
    }
    let outsideSourceX = Int((bounds.minX + bounds.maxX) * 0.5)
    let outsideSourceY = Int(bounds.minY + (bounds.maxY - bounds.minY) * 0.15)
    let outsideSource = (outsideSourceY * fittedPlanar.frame.width + outsideSourceX) * 4
    #expect(fittedValues[outsideSource] == 0)
    #expect(fittedValues[outsideSource + 1] == 0)
    #expect(fittedValues[outsideSource + 2] == 0)
}
