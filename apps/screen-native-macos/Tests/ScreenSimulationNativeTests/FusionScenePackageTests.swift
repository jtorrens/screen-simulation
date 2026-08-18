import Foundation
import StudioColor
import StudioMedia
import Testing
import simd
@testable import ScreenSimulationNative

private func fusionConfiguration(
    dof: StudioFusionDOFMode = .fusion,
    resolution: StudioFusionResolutionMode = .maximumProjectedDensity,
    policy: StudioOverwritePolicy = .failIfExists,
    frames: ClosedRange<Int> = 1 ... 2
) -> StudioResolvedRenderConfiguration {
    StudioResolvedRenderConfiguration(
        outputType: .fusionScenePackage,
        jobName: "Shot010",
        overwritePolicy: policy,
        fusionScene: .init(
            dofMode: dof,
            resolutionMode: resolution,
            customActiveWidth: nil,
            customActiveHeight: nil,
            spillThresholdSceneLinear: 0.1,
            spillFadeWidthPixels: 1
        ),
        composition: .deviceOnly,
        motionBlurEnabled: false,
        motionSamples: 8,
        format: .openEXR,
        pipeline: .aces,
        target: .acescg,
        peakNits: 0,
        display: nil,
        view: nil,
        vfxInterchangeEncodingID: nil,
        pixelEncoding: .rgba16Float,
        signalRange: .full,
        alpha: .straight,
        includeAudio: false,
        frameRate: .fps24,
        firstFrame: frames.lowerBound,
        lastFrame: frames.upperBound
    )
}

private func standardSequenceConfiguration(
    policy: StudioOverwritePolicy = .failIfExists
) -> StudioResolvedRenderConfiguration {
    StudioResolvedRenderConfiguration(
        outputType: .standard,
        jobName: "Shot010",
        overwritePolicy: policy,
        fusionScene: nil,
        composition: .deviceOnly,
        motionBlurEnabled: false,
        motionSamples: 8,
        format: .openEXR,
        pipeline: .aces,
        target: .acescg,
        peakNits: 0,
        display: nil,
        view: nil,
        vfxInterchangeEncodingID: nil,
        pixelEncoding: .rgba16Float,
        signalRange: .full,
        alpha: .straight,
        includeAudio: false,
        frameRate: .fps24,
        firstFrame: 1,
        lastFrame: 2
    )
}

private func camera(frame: Int = 1, z: Double = 1) -> FusionCameraKeyframe {
    FusionCameraKeyframe(
        frame: frame,
        positionMeters: [0, 0, z],
        quaternionXYZW: [0, 0, 0, 1],
        focalLengthMillimeters: 50,
        horizontalFOVDegrees: 39.5978,
        sensorWidthMillimeters: 36,
        sensorHeightMillimeters: 24,
        lensShiftXY: [0, 0],
        focusDistanceMeters: z,
        fStop: 2.8,
        nearClipMeters: 0.01,
        farClipMeters: 100
    )
}

private func lens(frame: Int = 1) -> FusionLensKeyframe {
    FusionLensKeyframe(
        frame: frame,
        radialK1K2K3: [0, 0, 0],
        tangentialP1P2: [0, 0],
        opticalCenterXY: [0, 0]
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fusion-package-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func frontalProjectionUsesCompleteUnclippedDevice() throws {
    let raster = try FusionProjectionResolver.maximumProjectedDensity(
        cameraSamples: [camera()],
        deviceWidthMeters: 0.36,
        deviceHeightMeters: 0.24,
        deliveryWidth: 1920,
        deliveryHeight: 1080
    )
    #expect((960 ... 961).contains(raster.activeWidth))
    #expect((640 ... 641).contains(raster.activeHeight))

    let projectedOutsideFrame = try FusionProjectionResolver.maximumProjectedDensity(
        cameraSamples: [camera(z: 0.1)],
        deviceWidthMeters: 0.36,
        deviceHeightMeters: 0.24,
        deliveryWidth: 1920,
        deliveryHeight: 1080
    )
    #expect((9_600 ... 9_601).contains(projectedOutsideFrame.activeWidth))
    #expect((6_400 ... 6_401).contains(projectedOutsideFrame.activeHeight))
}

@Test @MainActor func fusionEulerRoundTripsTheSynthEyesImporterConvention() {
    let authoredDegrees = SIMD3<Double>(-12.5, 23.25, 7.75)
    let qx = simd_quatd(angle: authoredDegrees.x * .pi / 180, axis: SIMD3(1, 0, 0))
    let qy = simd_quatd(angle: authoredDegrees.y * .pi / 180, axis: SIMD3(0, 1, 0))
    let qz = simd_quatd(angle: authoredDegrees.z * .pi / 180, axis: SIMD3(0, 0, 1))
    let canonical = simd_normalize(qz * qy * qx)
    let exported = FusionScenePackageWriter.fusionEulerDegrees([
        canonical.imag.x, canonical.imag.y, canonical.imag.z, canonical.real,
    ])
    let exportedQX = simd_quatd(angle: exported.x * .pi / 180, axis: SIMD3(1, 0, 0))
    let exportedQY = simd_quatd(angle: exported.y * .pi / 180, axis: SIMD3(0, 1, 0))
    let exportedQZ = simd_quatd(angle: exported.z * .pi / 180, axis: SIMD3(0, 0, 1))
    let roundTrip = simd_normalize(exportedQZ * exportedQY * exportedQX)
    #expect(abs(simd_dot(canonical.vector, roundTrip.vector)) > 1 - 1e-12)
}

@Test func spillPaddingPreservesRGBAtZeroAlphaAndIndependentMatte() throws {
    // Active Device is the middle 2x2. The left spill pixel is above threshold with A=0.
    let width = 6
    let height = 6
    var rgba = [Float](repeating: 0, count: width * height * 4)
    func set(_ x: Int, _ y: Int, rgb: Float, alpha: Float) {
        let offset = (y * width + x) * 4
        rgba[offset] = rgb
        rgba[offset + 1] = rgb
        rgba[offset + 2] = rgb
        rgba[offset + 3] = alpha
    }
    set(1, 2, rgb: 0.2, alpha: 0)
    set(2, 2, rgb: 0.8, alpha: 0)
    set(3, 2, rgb: 0.8, alpha: 0.5)
    set(2, 3, rgb: 0.8, alpha: 1)
    let prepared = try FusionSpillSupport.prepare(
        .init(
            width: width,
            height: height,
            activeRect: .init(x: 2, y: 2, width: 2, height: 2),
            rgba: rgba
        ),
        thresholdSceneLinear: 0.1,
        fadeWidthPixels: 1,
        fixedThresholdSupportPixels: 1
    )
    #expect(prepared.uniformPaddingPixels == 2)
    #expect(prepared.activeRect == .init(x: 2, y: 2, width: 2, height: 2))
    let leftSpill = (2 * prepared.width + 1) * 4
    #expect(prepared.rgba[leftSpill] > 0)
    #expect(prepared.rgba[leftSpill + 3] == 0)
    let alphaZero = (2 * prepared.width + 2) * 4
    let alphaHalf = (2 * prepared.width + 3) * 4
    let alphaOne = (3 * prepared.width + 2) * 4
    #expect(prepared.rgba[alphaZero] == 0.8)
    #expect(prepared.rgba[alphaZero + 3] == 0)
    #expect(prepared.rgba[alphaHalf] == 0.8)
    #expect(prepared.rgba[alphaHalf + 3] == 0.5)
    #expect(prepared.rgba[alphaOne] == 0.8)
    #expect(prepared.rgba[alphaOne + 3] == 1)
}

@Test func exteriorFadeBandDoesNotChangeTheSupportedSpill() throws {
    // One supported spill pixel remains untouched. The next, outer fade-band pixel is smoothly
    // attenuated; the Device and every sample nearer to it retain their physical RGB and matte.
    let width = 8
    let height = 8
    var rgba = [Float](repeating: 0, count: width * height * 4)
    func set(_ x: Int, _ y: Int, rgb: Float, alpha: Float = 0) {
        let offset = (y * width + x) * 4
        rgba[offset] = rgb
        rgba[offset + 1] = rgb
        rgba[offset + 2] = rgb
        rgba[offset + 3] = alpha
    }
    set(3, 3, rgb: 0.8, alpha: 1) // Active Device.
    set(2, 3, rgb: 0.4) // Declared support: untouched.
    set(1, 3, rgb: 0.2) // Exterior fade band: reaches zero at its outer edge.
    let prepared = try FusionSpillSupport.prepare(
        .init(
            width: width,
            height: height,
            activeRect: .init(x: 3, y: 3, width: 2, height: 2),
            rgba: rgba
        ),
        thresholdSceneLinear: 0.1,
        fadeWidthPixels: 1,
        fixedThresholdSupportPixels: 1
    )
    #expect(prepared.uniformPaddingPixels == 2)
    let activePixel = (2 * prepared.width + 2) * 4
    #expect(prepared.rgba[activePixel] == 0.8)
    #expect(prepared.rgba[activePixel + 3] == 1)
    let supportedSpill = (2 * prepared.width + 1) * 4
    #expect(prepared.rgba[supportedSpill] == 0.4)
    #expect(prepared.rgba[supportedSpill + 3] == 0)
    let outerFadeBand = (2 * prepared.width) * 4
    #expect(prepared.rgba[outerFadeBand] == 0)
    #expect(prepared.rgba[outerFadeBand + 3] == 0)
}

@Test func physicalOverscanRetainsCompleteGlowSupportAtEveryPositiveAmount() throws {
    let full = try FusionPhysicalSupportResolver.sourceOverscanPixels(
        panelTailRadiusMicrometers: 0,
        panelSpreadAmount: 0,
        glowRadiusMillimeters: 3.5,
        glowAmount: 1,
        dofSupportPixels: 0,
        fadeWidthPixels: 4,
        pixelsPerMeter: 1_000
    )
    let reducedEnergy = try FusionPhysicalSupportResolver.sourceOverscanPixels(
        panelTailRadiusMicrometers: 0,
        panelSpreadAmount: 0,
        glowRadiusMillimeters: 3.5,
        glowAmount: 0.01,
        dofSupportPixels: 0,
        fadeWidthPixels: 4,
        pixelsPerMeter: 1_000
    )
    let disabled = try FusionPhysicalSupportResolver.sourceOverscanPixels(
        panelTailRadiusMicrometers: 0,
        panelSpreadAmount: 0,
        glowRadiusMillimeters: 3.5,
        glowAmount: 0,
        dofSupportPixels: 0,
        fadeWidthPixels: 4,
        pixelsPerMeter: 1_000
    )
    #expect(full == 11)
    #expect(reducedEnergy == full)
    #expect(disabled == 4)
}

@Test func multiFilePlansOwnDirectoriesAndRequirePreflightPolicy() throws {
    let root = try temporaryDirectory()
    let standard = try RenderOutputPlan.prepare(
        configuration: standardSequenceConfiguration(), selectedDestination: root
    )
    #expect(standard.destination.deletingLastPathComponent().path == root.path)
    #expect(standard.destination.lastPathComponent == "Shot010")
    try standard.prepareDirectories()
    #expect(try standard.inspectCollision() == .none)
    let generated = standard.destination.appendingPathComponent("Shot010-00000001.exr")
    try Data([1]).write(to: generated)
    #expect(try standard.inspectCollision().requiresConfirmation)
    #expect(throws: RenderOutputPlanningError.self) {
        try standard.authorizeWrite(to: generated, policy: .failIfExists)
    }
    try standard.authorizeWrite(to: generated, policy: .replaceGeneratedFiles)

    let package = try RenderOutputPlan.prepare(
        configuration: fusionConfiguration(), selectedDestination: root
    )
    #expect(package.destination.deletingLastPathComponent().path == root.path)
    #expect(package.destination.lastPathComponent == "Shot010_FusionScene")
    #expect(package.generatedRelativePaths.contains("fusion/Shot010.comp"))
    #expect(package.generatedRelativePaths.allSatisfy { !$0.hasPrefix("/") })
    #expect(package.generatedRelativePaths.allSatisfy { !$0.contains("STMap") })
    try package.prepareDirectories()
    #expect(try package.inspectCollision() == .none)
    let unrelated = package.destination.appendingPathComponent("notes.txt")
    try Data([2]).write(to: unrelated)
    #expect(try package.inspectCollision() == .populatedDirectory(
        package.destination, matchingGeneratedFiles: 0, totalEntries: 1
    ))
}

@Test @MainActor func compDelegatesLensMotionAndOptionalDOFWithoutConventionalOver() throws {
    let root = try temporaryDirectory()
    for dof in [StudioFusionDOFMode.disabled, .baked, .fusion] {
        let configuration = fusionConfiguration(dof: dof)
        let plan = try RenderOutputPlan.prepare(
            configuration: configuration, selectedDestination: root
        )
        let request = FusionScenePackageRequest(
            configuration: configuration,
            outputPlan: plan,
            deviceWidthMeters: 0.36,
            deviceHeightMeters: 0.24,
            activeRaster: .init(activeWidth: 8, activeHeight: 4, pixelsPerMeter: 25),
            sourceOverscanPixels: 2,
            deliveryWidth: 1920,
            deliveryHeight: 1080,
            camera: [camera(frame: 1), camera(frame: 2, z: 1.1)],
            lens: [lens(frame: 1), lens(frame: 2)],
            motionBlur: .init(
                bakedInEXR: false,
                enabledInFusion: true,
                shutterAngleDegrees: 180,
                shutterPhaseDegrees: -90
            ),
            referencePlate: nil
        )
        let comp = FusionScenePackageWriter.fusionComp(
            request: request,
            prepared: .init(
                width: 12,
                height: 8,
                activeRect: .init(x: 2, y: 2, width: 8, height: 4),
                uniformPaddingPixels: 2,
                thresholdSupportPixels: 1,
                rgba: [Float](repeating: 0, count: 12 * 8 * 4)
            )
        )
        #expect(comp.contains("Comp:/../media/Shot010.00000001.exr"))
        #expect(comp.hasPrefix("Composition {"))
        #expect(comp.contains("FrameFormat = {"))
        #expect(comp.contains("Width = 1920"))
        #expect(comp.contains("Height = 1080"))
        #expect(comp.contains("AovType = Input { Value = 1 }"))
        #expect(comp.contains("AoV = Input { SourceOp = \"CameraHorizontalFOV\", Source = \"Value\" }"))
        #expect(comp.contains("CameraHorizontalFOV = BezierSpline"))
        #expect(comp.contains("[\"Transform3DOp.ScaleLock\"] = Input { Value = 0 }"))
        // The 12x8 texture represents a 0.54x0.48 m padded canvas. ImagePlane3D's
        // built-in 12:8 texture aspect means Y scale is 0.48 / (8 / 12) = 0.72.
        #expect(comp.contains("[\"Transform3DOp.Scale.X\"] = Input { Value = 0.54 }"))
        #expect(comp.contains("[\"Transform3DOp.Scale.Y\"] = Input { Value = 0.72 }"))
        #expect(!comp.contains("[\"Transform3DOp.Scale.X\"] = Input { Value = 0.27 }"))
        #expect(comp.contains("DeviceLensDistortion = LensDistort"))
        #expect(comp.contains("Model = Input { Value = FuID { \"DE4RadialStandardDegree4\" } }"))
        #expect(comp.contains("[\"DE4RadialStandardDegree4.DistortionDegree2\"]"))
        #expect(comp.contains("[\"DE4RadialStandardDegree4.QuarticDistortionDegree4\"]"))
        #expect(!comp.contains("FusionRadial"))
        #expect(!comp.contains("STMap"))
        #expect(!comp.contains("LensDistortionExact = Texture"))
        #expect(comp.contains("MotionBlur = Input { Value = 1 }"))
        #expect(comp.contains("CenterBias = Input { Value = -1.0 }"))
        #expect(comp.contains("RendererType = Input { Value = FuID { \"RendererOpenGL\" } }"))
        #expect(comp.contains("[\"RendererOpenGL.EnableAccumDepthOfField\"] = Input { Value = \(dof == .fusion ? 1 : 0) }"))
        #expect(comp.contains("CameraApertureRadius = BezierSpline"))
        #expect(comp.contains("DeviceRGBOpaque = Custom"))
        #expect(comp.contains("DeviceMatteOpaque = Custom"))
        #expect(comp.contains("RecombineDeviceRGBA = Custom"))
        #expect(comp.contains("AlphaExpression = Input { Value = \"r2\" }"))
        #expect(comp.contains("PremultiplicationForbidden = true"))
        #expect(!comp.contains("PlateOccluded"))
        #expect(comp.contains("r1+r2*(1-a1)"))
        #expect(comp.contains("Equation = \"resultRGB = deviceRGB + plateRGB * (1 - A)\""))
        #expect(!comp.contains("PhysicalComposite = Merge"))
        #expect(comp.contains("DeviceRGBA = Loader {"))
        #expect(comp.contains("ViewInfo = OperatorInfo { Pos = { 110, 214.5 } }"))
        #expect(comp.contains("PhysicalComposite = Custom {"))
        #expect(comp.contains("ViewInfo = OperatorInfo { Pos = { 1265, 214.5 } }"))
        #expect(!comp.contains("MayaCam"))
        #expect(!comp.contains("EnableDepthOfField"))
        #expect(!comp.contains("ShutterPhase = Input"))
        #expect(comp.contains("CameraFocal = BezierSpline"))
        #expect(comp.contains("CameraFStop = BezierSpline"))
    }
}

@Test @MainActor func referencePlateUsesNativeOCIOAndCenteredDeliveryPlacement() throws {
    let configuration = fusionConfiguration()
    let root = try temporaryDirectory()
    let request = FusionScenePackageRequest(
        configuration: configuration,
        outputPlan: try RenderOutputPlan.prepare(configuration: configuration, selectedDestination: root),
        deviceWidthMeters: 0.36, deviceHeightMeters: 0.24,
        activeRaster: .init(activeWidth: 8, activeHeight: 4, pixelsPerMeter: 25),
        sourceOverscanPixels: 2, deliveryWidth: 1920, deliveryHeight: 1080,
        camera: [camera(frame: 1), camera(frame: 2)], lens: [lens(frame: 1), lens(frame: 2)],
        motionBlur: .init(bakedInEXR: false, enabledInFusion: true, shutterAngleDegrees: 180, shutterPhaseDegrees: 0),
        referencePlate: .init(
            sourceURL: URL(fileURLWithPath: "/reference.mov"),
            inputTransformID: "arri-logc4", ocioSourceColorSpace: "ARRI LogC4",
            placementID: "fill-crop", width: 2048, height: 858
        )
    )
    let comp = FusionScenePackageWriter.fusionComp(
        request: request,
        prepared: .init(width: 12, height: 8, activeRect: .init(x: 2, y: 2, width: 8, height: 4), uniformPaddingPixels: 2, thresholdSupportPixels: 1, rgba: [])
    )
    #expect(comp.contains("ReferenceToACEScg = OCIOColorSpace"))
    #expect(comp.contains("Filename = \"/reference.mov\""))
    #expect(!comp.contains("Comp:/../reference/"))
    #expect(comp.contains("studio-fusion-ocio-v2.4.ocio"))
    #expect(!comp.contains(StudioColorEngine.configurationFileName))
    #expect(comp.contains("SourceSpace = Input { Value = FuID { \"ARRI LogC4\" } }"))
    #expect(comp.contains("OutputSpace = Input { Value = FuID { \"ACEScg\" } }"))
    #expect(comp.contains("ReferenceResize = BetterResize"))
    #expect(comp.contains("PlateInput = Merge"))
    #expect(comp.contains("Placement = \"fill-crop\""))
}

@Test func fusionOCIOConfigurationIsExplicitOCIO24Subset() throws {
    let configuration = try String(
        contentsOf: StudioColorEngine.bundledFusionConfigurationURL(), encoding: .utf8
    )
    #expect(configuration.contains("ocio_profile_version: 2"))
    #expect(configuration.contains("name: Gamma 2.4 Encoded Rec.709"))
    #expect(configuration.contains("name: ARRI LogC4"))
    #expect(configuration.contains("name: ACEScg"))
    #expect(!configuration.contains("ACES-OUTPUT"))
    #expect(!configuration.contains("interop_id:"))
    #expect(!configuration.contains("amf_transform_ids:"))
}

@Test func fusionPackageRejectsAnUnrepresentedReferenceIDT() throws {
    let configuration = fusionConfiguration()
    let root = try temporaryDirectory()
    let request = FusionScenePackageRequest(
        configuration: configuration,
        outputPlan: try RenderOutputPlan.prepare(configuration: configuration, selectedDestination: root),
        deviceWidthMeters: 0.36, deviceHeightMeters: 0.24,
        activeRaster: .init(activeWidth: 8, activeHeight: 4, pixelsPerMeter: 25),
        sourceOverscanPixels: 2, deliveryWidth: 1920, deliveryHeight: 1080,
        camera: [camera(frame: 1), camera(frame: 2)], lens: [lens(frame: 1), lens(frame: 2)],
        motionBlur: .init(bakedInEXR: false, enabledInFusion: true, shutterAngleDegrees: 180, shutterPhaseDegrees: 0),
        referencePlate: .init(
            sourceURL: URL(fileURLWithPath: "/reference.mov"),
            inputTransformID: "canon-log3", ocioSourceColorSpace: "CanonLog3 CinemaGamut D55",
            placementID: "fit", width: 1920, height: 1080
        )
    )
    #expect(throws: FusionScenePackageError.unsupportedReferenceInputTransform) {
        try request.validate()
    }
}

@Test @MainActor func fusionOutputCannotFallThroughTheStandardSourceFrameRenderer() async throws {
    let root = try temporaryDirectory()
    let configuration = fusionConfiguration(frames: 1 ... 1)
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    let display = try StudioColorMetalDisplay()
    var sourceFrameRequested = false
    await #expect(throws: NativeOutputError.self) {
        _ = try await NativeOutputRenderer.render(
            configuration: configuration,
            outputPlan: plan,
            audioSource: nil,
            display: display,
            frameProvider: { _ in
                sourceFrameRequested = true
                throw FusionScenePackageError.invalidRaster
            },
            progress: { _, _ in }
        )
    }
    #expect(sourceFrameRequested == false)
}

@Test @MainActor func packageWriterUsesSequenceWidePaddingAndPortableRelativeFiles() async throws {
    let root = try temporaryDirectory()
    let configuration = fusionConfiguration(frames: 1 ... 2)
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    let request = FusionScenePackageRequest(
        configuration: configuration,
        outputPlan: plan,
        deviceWidthMeters: 0.2,
        deviceHeightMeters: 0.2,
        activeRaster: .init(activeWidth: 2, activeHeight: 2, pixelsPerMeter: 10),
        sourceOverscanPixels: 3,
        deliveryWidth: 8,
        deliveryHeight: 8,
        camera: [camera(frame: 1), camera(frame: 2)],
        lens: [lens(frame: 1), lens(frame: 2)],
        motionBlur: .init(
            bakedInEXR: false,
            enabledInFusion: true,
            shutterAngleDegrees: 180,
            shutterPhaseDegrees: 0
        ),
        referencePlate: nil
    )
    var calls = 0
    let result = try await FusionScenePackageWriter.render(
        request: request,
        frameProvider: { frame in
            calls += 1
            var rgba = [Float](repeating: 0, count: 8 * 8 * 4)
            let active = FusionRasterRect(x: 3, y: 3, width: 2, height: 2)
            for y in active.y ..< active.y + active.height {
                for x in active.x ..< active.x + active.width {
                    let offset = (y * 8 + x) * 4
                    rgba[offset] = 1
                    rgba[offset + 1] = 0.5
                    rgba[offset + 2] = 0.25
                    rgba[offset + 3] = 1
                }
            }
            let spillX = frame == 1 ? 2 : 1
            let spill = (3 * 8 + spillX) * 4
            rgba[spill] = 0.2
            rgba[spill + 1] = 0.2
            rgba[spill + 2] = 0.2
            return FusionRawPhysicalFrame(
                width: 8, height: 8, activeRect: active, rgba: rgba
            )
        },
        progress: { _, _ in }
    )
    #expect(result == plan.destination)
    #expect(calls == 2)
    #expect(FileManager.default.fileExists(
        atPath: plan.destination.appendingPathComponent("media/Shot010.00000001.exr").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: plan.destination.appendingPathComponent("media/Shot010_STMap.00000002.exr").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: plan.destination.appendingPathComponent(
            "metadata/\(StudioColorEngine.fusionConfigurationFileName).ocio"
        ).path
    ))
    let metadataURL = plan.destination.appendingPathComponent(
        "metadata/Shot010_FusionScene.json"
    )
    let metadata = try JSONDecoder().decode(
        FusionSceneMetadata.self, from: Data(contentsOf: metadataURL)
    )
    #expect(metadata.raster.width == 8)
    #expect(metadata.raster.height == 8)
    #expect(metadata.raster.uniformPaddingPixels == 3)
    #expect(metadata.spill.thresholdSupportPixels == 2)
    #expect(metadata.lensReconstruction.fusionTool == "LensDistort")
    #expect(metadata.lensReconstruction.fusionModel == "DE4RadialStandardDegree4")
    let comp = try String(contentsOf: plan.destination.appendingPathComponent(
        "fusion/Shot010.comp"
    ))
    #expect(comp.contains("Comp:/../media/Shot010.00000001.exr"))
    #expect(comp.contains("DeviceLensDistortion = LensDistort"))
    #expect(!comp.contains("STMap"))
}

@Test @MainActor func savedAnimatedCameraSceneRendersACompleteFusionPackageWhenRequested() async throws {
    guard ProcessInfo.processInfo.environment["SCREEN_RUN_SAVED_SCENE_FUSION_PACKAGE"] == "1"
    else { return }
    let document = try SceneLibraryStore().load()
    let scene = try #require(document.scenes.first { $0.snapshot.tracking != nil })
    let executor = WorkspaceModel()
    await executor.openSavedScene(scene, undoManager: nil)
    #expect(executor.errorMessage == nil)
    let trackedCamera = try #require(executor.trackingScene?.cameras.first)
    let lastFrame = try #require(trackedCamera.samples.last?.frame)

    let root: URL
    if let outputRoot = ProcessInfo.processInfo.environment["SCREEN_FUSION_PACKAGE_OUTPUT_ROOT"] {
        root = URL(fileURLWithPath: outputRoot, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    } else {
        root = try temporaryDirectory()
    }
    let configuration = StudioResolvedRenderConfiguration(
        outputType: .fusionScenePackage,
        jobName: "AnimatedCameraIntegration",
        overwritePolicy: .failIfExists,
        fusionScene: .init(
            dofMode: .fusion,
            resolutionMode: .custom,
            customActiveWidth: 64,
            customActiveHeight: 128,
            spillThresholdSceneLinear: 0.000_1,
            spillFadeWidthPixels: 4
        ),
        composition: .deviceOnly,
        motionBlurEnabled: false,
        motionSamples: 8,
        format: .openEXR,
        pipeline: .aces,
        target: .acescg,
        peakNits: 0,
        display: nil,
        view: nil,
        vfxInterchangeEncodingID: nil,
        pixelEncoding: .rgba16Float,
        signalRange: .full,
        alpha: .straight,
        includeAudio: false,
        frameRate: try StudioFrameRate(numerator: 25, denominator: 1),
        firstFrame: 0,
        lastFrame: lastFrame
    )
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    let queueRoot = try temporaryDirectory()
    let queue = try NativeOutputQueueController(
        store: RenderQueueStore(directoryURL: queueRoot)
    )
    queue.enqueue(
        scene: scene, generatedEnvironmentEXR: nil,
        outputPlan: plan, configuration: configuration
    )
    let job = try #require(queue.jobs.first)
    let package = try executor.makeFusionPackageRequest(job: job)
    #expect(package.request.camera.count == trackedCamera.samples.count)
    #expect(package.request.camera.first?.positionMeters != package.request.camera.last?.positionMeters)
    let destination = try await FusionScenePackageWriter.render(
        request: package.request,
        frameProvider: { frame in
            try await executor.renderFusionPhysicalFrame(
                frame, request: package.request, sourceOverscan: package.sourceOverscan
            )
        },
        progress: { _, _ in }
    )
    let comp = try String(
        contentsOf: destination.appendingPathComponent(
            "fusion/AnimatedCameraIntegration.comp"
        ),
        encoding: .utf8
    )
    #expect(comp.contains("DE4RadialStandardDegree4"))
    #expect(!comp.contains("STMap"))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent(
        "media/AnimatedCameraIntegration.00000000.exr"
    ).path))
    let metadataURL = destination.appendingPathComponent(
        "metadata/AnimatedCameraIntegration_FusionScene.json"
    )
    let metadata = try JSONDecoder().decode(
        FusionSceneMetadata.self, from: Data(contentsOf: metadataURL)
    )
    #expect(metadata.camera.count == trackedCamera.samples.count)
    #expect(metadata.motionBlur.bakedInEXR == false)
    #expect(metadata.dofMode == .fusion)
}
