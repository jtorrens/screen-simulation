import Metal
import StudioColor
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func unifiedPhysicalABIAmountZeroPreservesSourceTexture() async throws {
    let fixture = try makePhysicalFixture()
    let job = try submit(
        fixture: fixture,
        screenAmount: 0,
        contributions: try contributions(active: false),
        intermediate: .sourceACEScg,
        identity: 1
    )
    let result = try await terminalSnapshot(job)
    #expect(result.state == .complete)
    #expect(result.returnedIntermediate == .sourceACEScg)
    let output = try #require(result.frame?.texture)
    #expect(readRGBA32(output) == readRGBA32(fixture.source.texture))
}

@Test @MainActor func unifiedPhysicalABIReturnsEverySupportedIntermediate() async throws {
    let fixture = try makePhysicalFixture()
    for (offset, intermediate) in PhysicalIntermediate.supportedDiagnostics.enumerated() {
        let job = try submit(
            fixture: fixture,
            screenAmount: 1,
            contributions: try contributions(),
            intermediate: intermediate,
            identity: UInt64(10 + offset)
        )
        let result = try await terminalSnapshot(job)
        #expect(result.state == .complete)
        #expect(result.returnedIntermediate == intermediate)
        #expect(result.frame != nil)
        #expect(result.diagnostics.map(\.stage) == PhysicalStageID.ordered)
    }
}

@Test @MainActor func unifiedPhysicalABIReportsStaticInputForCompletePipeline() async throws {
    let fixture = try makePhysicalFixture()
    let job = try submit(
        fixture: fixture,
        screenAmount: 1,
        contributions: try contributions(),
        intermediate: .developedACEScg,
        identity: 30
    )
    let result = try await terminalSnapshot(job)
    #expect(result.state == .complete)
    #expect(result.diagnostics.count == 12)
    #expect(result.diagnostics[8].message.contains("STATIC_INPUT"))
    #expect(result.diagnostics.prefix(9).allSatisfy {
        $0.elapsedNanoseconds == result.diagnostics[0].elapsedNanoseconds
    })
    #expect(result.diagnostics.suffix(3).allSatisfy {
        $0.elapsedNanoseconds == result.diagnostics[9].elapsedNanoseconds
    })
}

@Test @MainActor func unifiedPhysicalABIPublishesDevelopedFrameWithEnergyAndOpaqueAlpha() async throws {
    let fixture = try makePhysicalFixture(width: 64, height: 36)
    let job = try submit(
        fixture: fixture,
        screenAmount: 1,
        contributions: try contributions(),
        intermediate: .developedACEScg,
        identity: 31
    )
    let result = try await terminalSnapshot(job)
    let texture = try #require(result.frame?.texture)
    let values = readRGBA32(texture)
    let rgb = values.enumerated().compactMap { index, value in
        index % 4 == 3 ? nil : value
    }
    let alpha = values.enumerated().compactMap { index, value in
        index % 4 == 3 ? value : nil
    }
    #expect(rgb.allSatisfy { $0.isFinite })
    // This is a publication smoke test, not a display-referred brightness
    // assertion. Radiometric exposure is validated against calibrated goldens
    // in the Rust/Metal contract tests, so only require non-zero finite energy
    // at this boundary.
    #expect(rgb.reduce(0) { $0 + max(0, $1) } / Float(rgb.count) > 0)
    #expect(alpha.allSatisfy { $0 == 1 })
}

@Test @MainActor func authoredSnapshotRoundTripsThroughUnifiedEngineAndRestore() async throws {
    let base = try makePhysicalFixture(width: 32, height: 18)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == base.device.definition.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(
        device: base.device.definition,
        coverGlass: cover
    )
    authored.sceneLens.focalLengthMillimeters = 62
    authored.sensor.nativeWidth = 32
    authored.sensor.nativeHeight = 18
    authored.develop.exposureEV = 0.5
    let restored = try JSONDecoder().decode(
        PhysicalPipelineAuthoringState.self,
        from: JSONEncoder().encode(authored)
    )
    let fixture = PhysicalFixture(
        source: base.source,
        deviceSignal: base.deviceSignal,
        device: base.device,
        pipeline: try restored.resolvedPipeline()
    )
    let result = try await terminalSnapshot(submit(
        fixture: fixture,
        screenAmount: 1,
        contributions: try contributions(),
        intermediate: .developedACEScg,
        identity: 32
    ))
    #expect(result.state == .complete)
    #expect(result.frame?.width == 32)
    #expect(result.frame?.height == 18)
}

@Test @MainActor func unifiedPhysicalABICoversTopologyPlacementAndSpreadMatrix() async throws {
    for stripe in [DeviceStripeLayout.rgb, .bgr] {
        let fixture = try makePhysicalFixture(stripe: stripe, blackMatrix: 0.18)
        for placement in PhysicalRasterPlacement.allCases {
            for spread in [0.0, 1.0, 2.5] {
                let identity = UInt64(
                    100 + Int(stripe == .bgr ? 50 : 0)
                        + Int(placement.rawValue) * 10 + Int(spread * 2)
                )
                let job = try submit(
                    fixture: fixture,
                    screenAmount: 1,
                    contributions: try contributions(spreadAmount: spread),
                    intermediate: .developedACEScg,
                    identity: identity,
                    placement: placement
                )
                let result = try await terminalSnapshot(job)
                #expect(result.state == .complete)
                #expect(result.frame != nil)
                #expect(result.progress == 1)
                #expect(result.diagnostics.count == 12)
            }
        }
    }
}

@Test @MainActor func unifiedPhysicalABIExecutesEveryAuthoredAmountAndEnable() async throws {
    let fixture = try makePhysicalFixture()
    let continuous = PhysicalStageID.ordered.filter {
        $0 != .capture(.sensorCFA) && $0 != .capture(.developDemosaic)
    }
    var identity: UInt64 = 400
    for stage in continuous {
        let limits = stage.contributionLimits
        for amount in [0.0, 1.0, min(2.5, limits.safeRange.upperBound)] {
            var values = try contributions()
            let index = try #require(values.firstIndex { $0.stage == stage })
            values[index] = try PhysicalStageContribution(
                stage: stage,
                control: .continuous(amount: amount, limits: limits),
                exactIdentityAtZero: true
            )
            identity &+= 1
            let result = try await terminalSnapshot(submit(
                fixture: fixture,
                screenAmount: 1,
                contributions: values,
                intermediate: .developedACEScg,
                identity: identity
            ))
            #expect(result.state == .complete)
        }
    }
    for enabled in [false, true] {
        var cfa = try contributions()
        let cfaIndex = try #require(cfa.firstIndex { $0.stage == .capture(.sensorCFA) })
        cfa[cfaIndex] = try PhysicalStageContribution(
            stage: .capture(.sensorCFA),
            control: .discrete(enabled: enabled),
            exactIdentityAtZero: false
        )
        if !enabled {
            let noiseIndex = try #require(cfa.firstIndex { $0.stage == .capture(.noise) })
            cfa[noiseIndex] = try PhysicalStageContribution(
                stage: .capture(.noise),
                control: .continuous(amount: 0, limits: .standard),
                exactIdentityAtZero: true
            )
            let developIndex = try #require(cfa.firstIndex {
                $0.stage == .capture(.developDemosaic)
            })
            cfa[developIndex] = try PhysicalStageContribution(
                stage: .capture(.developDemosaic),
                control: .discrete(enabled: false),
                exactIdentityAtZero: false
            )
        }
        identity &+= 1
        let cfaResult = try await terminalSnapshot(submit(
            fixture: fixture,
            screenAmount: 1,
            contributions: cfa,
            intermediate: enabled ? .rawMosaic : .shutterMotion,
            identity: identity
        ))
        #expect(cfaResult.state == .complete)

        var develop = try contributions()
        let developIndex = try #require(develop.firstIndex {
            $0.stage == .capture(.developDemosaic)
        })
        develop[developIndex] = try PhysicalStageContribution(
            stage: .capture(.developDemosaic),
            control: .discrete(enabled: enabled),
            exactIdentityAtZero: false
        )
        identity &+= 1
        let developResult = try await terminalSnapshot(submit(
            fixture: fixture,
            screenAmount: 1,
            contributions: develop,
            intermediate: enabled ? .developedACEScg : .rawMosaic,
            identity: identity
        ))
        #expect(developResult.state == .complete)
    }
}

@Test @MainActor func unifiedPhysicalABICancelsNativeWithMatchingIdentity() async throws {
    let fixture = try makePhysicalFixture(useNativeDeviceRaster: true)
    let job = try submit(
        fixture: fixture,
        screenAmount: 1,
        contributions: try contributions(),
        intermediate: .developedACEScg,
        identity: 220,
        quality: .native,
        dimensions: try PhysicalDimensions(
            width: fixture.device.definition.nativeWidth,
            height: fixture.device.definition.nativeHeight
        )
    )
    #expect(job.cancel())
    let result = try await terminalSnapshot(job)
    #expect(result.state == .cancelled)
}

private struct PhysicalFixture {
    let source: StudioColorMetalFrame
    let deviceSignal: StudioColorMetalFrame
    let device: ResolvedDevice
    let pipeline: PhysicalPipelineResolvedState
}

@MainActor
private func makePhysicalFixture(
    stripe: DeviceStripeLayout = .rgb,
    blackMatrix: Double = 0.12,
    useNativeDeviceRaster: Bool = false,
    width: Int = 4,
    height: Int = 4
) throws -> PhysicalFixture {
    let display = try StudioColorMetalDisplay()
    let pixelCount = width * height
    let sourcePixels = (0..<pixelCount).flatMap { index -> [Float] in
            let value = Float(index) / Float(max(1, pixelCount - 1))
            return [value, 1 - value, value * 1.25 - 0.1, value]
        }
    let metal = try #require(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float,
        width: width,
        height: height,
        mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead, .shaderWrite]
    let sourceTexture = try #require(metal.makeTexture(descriptor: descriptor))
    sourcePixels.withUnsafeBytes { bytes in
        sourceTexture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size
        )
    }
    let source = StudioColorMetalFrame(texture: sourceTexture)
    let output = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    }!
    let signal = try display.transformToMetalFrame(source, output: output)
    var device = try #require(try RustDeviceCatalog.builtIns().first)
    if !useNativeDeviceRaster {
        device.nativeWidth = width
        device.nativeHeight = height
    }
    device.stripeLayout = stripe
    device.blackMatrixFraction = blackMatrix
    let cover = try #require(
        try RustCoverGlassCatalog.builtIns().first {
            $0.id == device.defaultCoverGlassPresetID
        }
    )
    let defaultPipeline = try PhysicalPipelineResolvedState.resolvedDefaults(
        coverGlass: cover
    )
    var pipelineParameters = defaultPipeline.parameters
    pipelineParameters.sensor_noise.native_width = UInt32(width)
    pipelineParameters.sensor_noise.native_height = UInt32(height)
    let pipeline = PhysicalPipelineResolvedState(
        parameters: pipelineParameters,
        coverGlassID: defaultPipeline.coverGlassID
    )
    return PhysicalFixture(
        source: source,
        deviceSignal: signal,
        device: try device.resolved(),
        pipeline: pipeline
    )
}

private func readRGBA32(_ texture: MTLTexture) -> [Float] {
    precondition(texture.pixelFormat == .rgba32Float)
    var values = [Float](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &values,
        bytesPerRow: texture.width * 4 * MemoryLayout<Float>.size,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return values
}

private func contributions(
    spreadAmount: Double = 1,
    active: Bool = true
) throws -> [PhysicalStageContribution] {
    try PhysicalStageID.ordered.map { stage in
        let discrete = stage == .capture(.sensorCFA)
            || stage == .capture(.developDemosaic)
        let amount = stage == .screen(.panelLightSpread) && active
            ? spreadAmount : active ? 1 : 0
        return try PhysicalStageContribution(
            stage: stage,
            control: discrete
                ? .discrete(enabled: active)
                : .continuous(amount: amount, limits: stage.contributionLimits),
            exactIdentityAtZero: !discrete
        )
    }
}

@MainActor
private func submit(
    fixture: PhysicalFixture,
    screenAmount: Double,
    contributions: [PhysicalStageContribution],
    intermediate: PhysicalIntermediate,
    identity: UInt64,
    placement: PhysicalRasterPlacement = .fit,
    quality: PhysicalQuality = .draft,
    dimensions: PhysicalDimensions? = nil
) throws -> PhysicalMetalFrameJob {
    let spreadAmount = try #require(contributions.first {
        $0.stage == .screen(.panelLightSpread)
    }?.amount)
    var effectiveDefinition = fixture.device.definition
    effectiveDefinition.panelLightSpread.characterStrength = spreadAmount
    let frame = try PhysicalFrameSelection(
        frameIndex: 0,
        timeNumerator: 0,
        timeDenominator: 24
    )
    let framing = try PhysicalStaticFraming(
        device: effectiveDefinition,
        scene: fixture.pipeline.parameters.scene_geometry_lens
    )
    return try PhysicalMetalFrameEngine().submit(
        sourceACEScg: fixture.source,
        deviceSignal: fixture.deviceSignal,
        orchestration: try .staticSelectedFrame(
            frame,
            cameraDistanceMeters: framing.cameraDistanceMeters
        ),
        resolvedDevice: try effectiveDefinition.resolved(),
        resolvedPipeline: try fixture.pipeline.resolving(
            contributions: contributions,
            focusDistanceMeters: framing.cameraDistanceMeters
        ),
        quality: quality,
        screenAmount: screenAmount,
        contributions: contributions,
        requestedDimensions: try dimensions
            ?? PhysicalDimensions(width: 4, height: 4),
        cancellationIdentity: .init(high: identity, low: identity),
        progressIdentity: .init(high: identity, low: identity),
        parameterRevision: identity,
        parameterHash: try PhysicalParameterHash(
            bytes: [UInt8](repeating: UInt8(truncatingIfNeeded: identity), count: 32)
        ),
        rasterPlacement: placement,
        requestedIntermediate: intermediate
    )
}

@MainActor
private func terminalSnapshot(
    _ job: PhysicalMetalFrameJob
) async throws -> PhysicalMetalFrameSnapshot {
    for _ in 0..<2_000 {
        let result = try job.snapshot()
        if [.complete, .failed, .cancelled].contains(result.state) {
            return result
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("El job físico no alcanzó un estado terminal.")
    return try job.snapshot()
}
