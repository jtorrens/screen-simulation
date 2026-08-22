import Foundation
import StudioMedia

enum WIPReviewOFXError: Error, LocalizedError {
    case missingPackagedHost(URL)
    case missingPackagedBundle(URL)
    case invalidRaster
    case invalidPayload
    case hostFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingPackagedHost(url):
            "Falta el host OFX WIP Review empaquetado: \(url.path)"
        case let .missingPackagedBundle(url):
            "Falta el bundle com.jtorrens.WIPReviewProbe empaquetado: \(url.path)"
        case .invalidRaster: "El raster WIP Review resuelto no es válido."
        case .invalidPayload: "El host OFX WIP Review devolvió un raster RGBA32F no válido."
        case let .hostFailed(message): "WIP Review OFX falló: \(message)"
        }
    }
}

struct WIPReviewOFXAdapter: Sendable {
    struct Raster: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    let hostExecutableURL: URL
    let pluginBundleURL: URL

    init() throws {
        guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        else { throw WIPReviewOFXError.invalidPayload }
        let host = executableDirectory.appendingPathComponent("screen-wip-ofx-host")
        let bundle = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/WIPReviewProbe.ofx.bundle")
        guard FileManager.default.isExecutableFile(atPath: host.path) else {
            throw WIPReviewOFXError.missingPackagedHost(host)
        }
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw WIPReviewOFXError.missingPackagedBundle(bundle)
        }
        hostExecutableURL = host
        pluginBundleURL = bundle
    }

    init(hostExecutableURL: URL, pluginBundleURL: URL) {
        self.hostExecutableURL = hostExecutableURL
        self.pluginBundleURL = pluginBundleURL
    }

    static func raster(
        for preset: StudioWIPReviewPreset,
        sourceWidth: Int,
        sourceHeight: Int
    ) throws -> Raster {
        let raster = switch preset.reviewRaster {
        case .output: Raster(width: sourceWidth, height: sourceHeight)
        case .hd1920x1080: Raster(width: 1_920, height: 1_080)
        case .uhd3840x2160: Raster(width: 3_840, height: 2_160)
        case .dci2K2048x1080: Raster(width: 2_048, height: 1_080)
        case .dci4K4096x2160: Raster(width: 4_096, height: 2_160)
        case .custom:
            Raster(width: preset.customWidth ?? 0, height: preset.customHeight ?? 0)
        }
        guard raster.width > 0, raster.height > 0 else {
            throw WIPReviewOFXError.invalidRaster
        }
        return raster
    }

    func render(
        encodedRGBA: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        frame: Int,
        frameRate: Double,
        outputFilename: String,
        preset: StudioWIPReviewPreset
    ) async throws -> (rgba: [Float], raster: Raster) {
        try await Task.detached {
            try renderSynchronously(
                encodedRGBA: encodedRGBA,
                sourceWidth: sourceWidth,
                sourceHeight: sourceHeight,
                frame: frame,
                frameRate: frameRate,
                outputFilename: outputFilename,
                preset: preset
            )
        }.value
    }

    private func renderSynchronously(
        encodedRGBA: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        frame: Int,
        frameRate: Double,
        outputFilename: String,
        preset: StudioWIPReviewPreset
    ) throws -> (rgba: [Float], raster: Raster) {
        try preset.validate()
        guard encodedRGBA.count == sourceWidth * sourceHeight * 4,
              encodedRGBA.allSatisfy(\.isFinite), frameRate.isFinite, frameRate > 0 else {
            throw WIPReviewOFXError.invalidPayload
        }
        let raster = try Self.raster(
            for: preset, sourceWidth: sourceWidth, sourceHeight: sourceHeight
        )
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-wip-ofx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("input.rgba32f")
        let output = temporary.appendingPathComponent("output.rgba32f")
        let inputData = encodedRGBA.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        try inputData.write(to: input, options: .atomic)

        let process = Process()
        process.executableURL = hostExecutableURL
        process.arguments = [
            pluginBundleURL.path, input.path, output.path,
            String(sourceWidth), String(sourceHeight),
            String(raster.width), String(raster.height),
            String(frame), String(frameRate),
        ] + parameters(for: preset, outputFilename: outputFilename)
        let diagnostic = Pipe()
        process.standardOutput = diagnostic
        process.standardError = diagnostic
        try process.run()
        process.waitUntilExit()
        let message = String(
            data: diagnostic.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw WIPReviewOFXError.hostFailed(message.isEmpty ? "status \(process.terminationStatus)" : message)
        }
        let data = try Data(contentsOf: output, options: .mappedIfSafe)
        let count = raster.width * raster.height * 4
        guard data.count == count * MemoryLayout<Float>.size else {
            throw WIPReviewOFXError.invalidPayload
        }
        var rgba = [Float](repeating: 0, count: count)
        _ = rgba.withUnsafeMutableBytes { destination in data.copyBytes(to: destination) }
        guard rgba.allSatisfy(\.isFinite) else { throw WIPReviewOFXError.invalidPayload }
        return (rgba, raster)
    }

    private func parameters(
        for preset: StudioWIPReviewPreset,
        outputFilename: String
    ) -> [String] {
        var result: [String] = []
        func integer(_ name: String, _ value: Int) { result += ["i", name, String(value)] }
        func double(_ name: String, _ value: Double) { result += ["d", name, String(value)] }
        func string(_ name: String, _ value: String) { result += ["s", name, value] }
        func color(_ name: String, _ value: StudioReviewColor) {
            result += ["c", name, "\(value.red),\(value.green),\(value.blue),\(value.alpha)"]
        }
        integer("canvasMode", 0) // Host Raster; this host never impersonates Fusion.
        let placement = switch preset.placement {
        case .identity: 0; case .fit: 1; case .fill: 2; case .stretch: 3; case .center: 4
        }
        integer("placementMode", placement)
        let filter = switch preset.resampleFilter {
        case .bilinear: 0; case .bicubic: 1; case .lanczos: 2
        }
        integer("resampleFilter", filter)
        color("canvasColour", preset.canvasColor)
        integer("blankingEnabled", preset.blankingEnabled ? 1 : 0)
        let blankingAspect = switch preset.blankingAspect {
        case .ratio178: 0; case .ratio185: 1; case .ratio200: 2; case .ratio239: 3; case .custom: 4
        }
        integer("blankingAspectPreset", blankingAspect)
        double("blankingAspectCustom", preset.customBlankingAspect ?? 2)
        color("blankingColor", preset.blankingColor)
        double("blankingOpacity", preset.blankingOpacity)
        string("fontFamily", preset.fontFamily)
        let fontStyle = switch preset.fontStyle {
        case .regular: 0; case .bold: 1; case .italic: 2; case .boldItalic: 3
        }
        integer("fontStyle", fontStyle)
        double("fontSize", preset.fontSize)
        color("textColor", preset.textColor)
        double("textOpacity", preset.textOpacity)
        integer("graphicsWhiteMode", preset.graphicsWhiteMode == .automatic ? 0 : 1)
        double("graphicsWhiteNits", preset.graphicsWhiteNits)
        double("hlgPeakNits", preset.hlgPeakNits)
        integer("colorSpaceMode", 1)
        let manualColorSpace = switch preset.outputColorSpace {
        case .rec709Gamma24: 0; case .rec2100PQ: 1; case .rec2100HLG: 2
        }
        integer("manualColorSpace", manualColorSpace)
        integer("outlineEnabled", preset.outlineEnabled ? 1 : 0)
        double("outlineWidth", preset.outlineWidth)
        color("outlineColor", preset.outlineColor)
        double("outlineOpacity", preset.outlineOpacity)
        integer("shadowEnabled", preset.shadowEnabled ? 1 : 0)
        double("shadowOffsetX", preset.shadowOffsetX)
        double("shadowOffsetY", preset.shadowOffsetY)
        double("shadowSoftness", preset.shadowSoftness)
        color("shadowColor", preset.shadowColor)
        double("shadowOpacity", preset.shadowOpacity)
        double("paddingLeft", preset.paddingLeft)
        double("paddingRight", preset.paddingRight)
        double("paddingTop", preset.paddingTop)
        double("paddingBottom", preset.paddingBottom)
        integer("frameRelativeBase", preset.frameRelativeBase)
        integer("frameStart", preset.frameStart)
        integer("fpsMode", preset.frameRateMode == .render ? 0 : 1)
        double("fpsOverride", preset.frameRateOverride)
        string("timecodeStart", preset.timecodeStart)
        if !preset.reviewDate.isEmpty { string("reviewDate", preset.reviewDate) }
        let zonePrefixes: [StudioWIPZonePosition: String] = [
            .topLeft: "tl", .topCenter: "tc", .topRight: "tr",
            .bottomLeft: "bl", .bottomCenter: "bc", .bottomRight: "br",
        ]
        for zone in preset.zones {
            guard let prefix = zonePrefixes[zone.position] else { continue }
            integer("\(prefix)Enabled", zone.enabled ? 1 : 0)
            let literal: String
            let calculated: Int
            switch zone.calculatedField {
            case .none: literal = zone.prefix; calculated = 0
            case .frameRelative: literal = zone.prefix; calculated = 1
            case .frame: literal = zone.prefix; calculated = 2
            case .timecode: literal = zone.prefix; calculated = 3
            case .date: literal = zone.prefix; calculated = 4
            case .outputFilename:
                literal = zone.prefix + outputFilename
                calculated = 0
            }
            string("\(prefix)Prefix", literal)
            integer("\(prefix)CalculatedField", calculated)
            double("\(prefix)OffsetX", zone.offsetX)
            double("\(prefix)OffsetY", zone.offsetY)
            integer("\(prefix)UseSizeOverride", zone.fontSize.enabled ? 1 : 0)
            double("\(prefix)Size", zone.fontSize.value)
            integer("\(prefix)UseColorOverride", zone.color.enabled ? 1 : 0)
            color("\(prefix)Color", zone.color.value)
            integer("\(prefix)UseOpacityOverride", zone.opacity.enabled ? 1 : 0)
            double("\(prefix)Opacity", zone.opacity.value)
        }
        return result
    }
}
