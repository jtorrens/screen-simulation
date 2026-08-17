import Foundation
import StudioColor
import StudioMedia
import Testing
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
        format: .openEXR,
        pipeline: .aces,
        target: .acescg,
        peakNits: 0,
        display: nil,
        view: nil,
        pixelEncoding: .rgba16Float,
        signalRange: .full,
        alpha: .straight,
        includeAudio: false,
        frameRate: 24,
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
        format: .openEXR,
        pipeline: .aces,
        target: .acescg,
        peakNits: 0,
        display: nil,
        view: nil,
        pixelEncoding: .rgba16Float,
        signalRange: .full,
        alpha: .straight,
        includeAudio: false,
        frameRate: 24,
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
}

@Test @MainActor func compDelegatesLensMotionAndOptionalDOFWithoutConventionalOver() throws {
    let root = try temporaryDirectory()
    for dof in [StudioFusionDOFMode.baked, .fusion] {
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
            deliveryWidth: 1920,
            deliveryHeight: 1080,
            camera: [camera(frame: 1), camera(frame: 2, z: 1.1)],
            lens: [lens(frame: 1), lens(frame: 2)],
            motionBlur: .init(
                bakedInEXR: false,
                enabledInFusion: true,
                shutterAngleDegrees: 180,
                shutterPhaseDegrees: -90
            )
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
        #expect(comp.contains("Comp:/../media/Shot010.%08d.exr"))
        #expect(comp.contains("DeviceLensDistortion = LensDistort"))
        #expect(comp.contains("Model = Input { Value = FuID { \"FusionRadial\" } }"))
        #expect(comp.contains("[\"FusionRadial.LowOrderDistortion\"]"))
        #expect(comp.contains("[\"FusionRadial.HighOrderDistortion\"]"))
        #expect(comp.contains("[\"FusionRadial.FishEyeDistortion\"]"))
        #expect(comp.contains("[\"FusionRadial.TangentialDistortion.X\"]"))
        #expect(comp.contains("SourceOp = \"LensP2\""))
        #expect(comp.contains("[\"FusionRadial.TangentialDistortion.Y\"]"))
        #expect(comp.contains("SourceOp = \"LensP1\""))
        #expect(!comp.contains("STMap"))
        #expect(!comp.contains("LensDistortionExact = Texture"))
        #expect(comp.contains("MotionBlur = Input { Value = 1 }"))
        #expect(comp.contains("r1*(1-a2)"))
        #expect(comp.contains("r1+r2"))
        #expect(!comp.contains("PhysicalComposite = Merge"))
        #expect(comp.contains("EnableDepthOfField = Input { Value = \(dof == .fusion ? 1 : 0) }"))
        #expect(comp.contains("CameraFocal = BezierSpline"))
        #expect(comp.contains("CameraFStop = BezierSpline"))
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
        deliveryWidth: 8,
        deliveryHeight: 8,
        camera: [camera(frame: 1), camera(frame: 2)],
        lens: [lens(frame: 1), lens(frame: 2)],
        motionBlur: .init(
            bakedInEXR: false,
            enabledInFusion: true,
            shutterAngleDegrees: 180,
            shutterPhaseDegrees: 0
        )
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
    #expect(calls == 4)
    #expect(FileManager.default.fileExists(
        atPath: plan.destination.appendingPathComponent("media/Shot010.00000001.exr").path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: plan.destination.appendingPathComponent("media/Shot010_STMap.00000002.exr").path
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
    #expect(metadata.lensReconstruction.fusionModel == "FusionRadial")
    let comp = try String(contentsOf: plan.destination.appendingPathComponent(
        "fusion/Shot010.comp"
    ))
    #expect(comp.contains("Comp:/../media/Shot010.%08d.exr"))
    #expect(comp.contains("DeviceLensDistortion = LensDistort"))
    #expect(!comp.contains("STMap"))
}
