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
        let session = try makeSession(
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            frameRate: frameRate, firstFrame: frame, lastFrame: frame,
            preset: preset
        )
        do {
            let result = try await session.render(
                encodedRGBA: encodedRGBA,
                frame: frame,
                outputFilename: outputFilename
            )
            try await session.finish()
            return result
        } catch {
            session.terminate()
            throw error
        }
    }

    func makeSession(
        sourceWidth: Int,
        sourceHeight: Int,
        frameRate: Double,
        firstFrame: Int,
        lastFrame: Int,
        preset: StudioWIPReviewPreset
    ) throws -> Session {
        try preset.validate()
        guard sourceWidth > 0, sourceHeight > 0,
              frameRate.isFinite, frameRate > 0, firstFrame <= lastFrame else {
            throw WIPReviewOFXError.invalidPayload
        }
        let raster = try Self.raster(
            for: preset, sourceWidth: sourceWidth, sourceHeight: sourceHeight
        )
        return try Session(
            hostExecutableURL: hostExecutableURL,
            pluginBundleURL: pluginBundleURL,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            raster: raster, frameRate: frameRate,
            firstFrame: firstFrame, lastFrame: lastFrame,
            preset: preset
        )
    }

    final class Session: @unchecked Sendable {
        private static let requestMagic: UInt32 = 0x3150_4957
        private static let responseMagic: UInt32 = 0x3152_4f57

        let raster: Raster
        private let sourceWidth: Int
        private let sourceHeight: Int
        private let preset: StudioWIPReviewPreset
        private let process: Process
        private let input: FileHandle
        private let output: FileHandle
        private let diagnostic: FileHandle
        private let stateLock = NSLock()
        private var isFinished = false

        var processIdentifier: Int32 { process.processIdentifier }
        var isRunning: Bool { process.isRunning }

        fileprivate init(
            hostExecutableURL: URL, pluginBundleURL: URL,
            sourceWidth: Int, sourceHeight: Int, raster: Raster,
            frameRate: Double, firstFrame: Int, lastFrame: Int,
            preset: StudioWIPReviewPreset
        ) throws {
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
            self.raster = raster
            self.preset = preset
            let standardInput = Pipe()
            let standardOutput = Pipe()
            let standardError = Pipe()
            process = Process()
            process.executableURL = hostExecutableURL
            process.arguments = [
                pluginBundleURL.path,
                String(sourceWidth), String(sourceHeight),
                String(raster.width), String(raster.height),
                String(frameRate), String(firstFrame), String(lastFrame),
            ]
            process.standardInput = standardInput
            process.standardOutput = standardOutput
            process.standardError = standardError
            input = standardInput.fileHandleForWriting
            output = standardOutput.fileHandleForReading
            diagnostic = standardError.fileHandleForReading
            try process.run()
        }

        deinit {
            if process.isRunning { process.terminate() }
        }

        func render(
            encodedRGBA: [Float], frame: Int, outputFilename: String
        ) async throws -> (rgba: [Float], raster: Raster) {
            try await withTaskCancellationHandler {
                try await Task.detached { [self] in
                    try renderSynchronously(
                        encodedRGBA: encodedRGBA, frame: frame,
                        outputFilename: outputFilename
                    )
                }.value
            } onCancel: { [self] in
                terminate()
            }
        }

        func finish() async throws {
            try await Task.detached { [self] in try finishSynchronously() }.value
        }

        func terminate() {
            stateLock.lock()
            let shouldTerminate = !isFinished
            isFinished = true
            stateLock.unlock()
            if shouldTerminate, process.isRunning { process.terminate() }
        }

        private func renderSynchronously(
            encodedRGBA: [Float], frame: Int, outputFilename: String
        ) throws -> (rgba: [Float], raster: Raster) {
            guard sessionIsOpen(),
                  encodedRGBA.count == sourceWidth * sourceHeight * 4,
                  encodedRGBA.allSatisfy(\.isFinite),
                  stride(from: 3, to: encodedRGBA.count, by: 4)
                    .allSatisfy({ encodedRGBA[$0] == 1 })
            else { throw WIPReviewOFXError.invalidPayload }

            let parameters = WIPReviewOFXAdapter.parameters(
                for: preset, outputFilename: outputFilename
            )
            guard parameters.count.isMultiple(of: 3) else {
                throw WIPReviewOFXError.invalidPayload
            }
            var header = Data()
            append(Self.requestMagic, to: &header)
            append(Double(frame), to: &header)
            append(UInt32(parameters.count / 3), to: &header)
            for index in stride(from: 0, to: parameters.count, by: 3) {
                try append(parameters[index], to: &header)
                try append(parameters[index + 1], to: &header)
                try append(parameters[index + 2], to: &header)
            }
            append(UInt64(encodedRGBA.count), to: &header)
            try input.write(contentsOf: header)
            try encodedRGBA.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else {
                    throw WIPReviewOFXError.invalidPayload
                }
                try input.write(contentsOf: Data(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: address),
                    count: bytes.count, deallocator: .none
                ))
            }

            let magic: UInt32 = try readValue()
            let status: UInt32 = try readValue()
            let messageLength: UInt32 = try readValue()
            let floatCount: UInt64 = try readValue()
            guard magic == Self.responseMagic, messageLength <= 1_048_576 else {
                throw WIPReviewOFXError.invalidPayload
            }
            let messageData = try readExactly(Int(messageLength))
            let message = String(data: messageData, encoding: .utf8) ?? ""
            guard status == 0 else {
                throw WIPReviewOFXError.hostFailed(message.isEmpty ? "session render failed" : message)
            }
            let expectedCount = raster.width * raster.height * 4
            guard floatCount == UInt64(expectedCount) else {
                throw WIPReviewOFXError.invalidPayload
            }
            var rgba = [Float](repeating: 0, count: expectedCount)
            try rgba.withUnsafeMutableBytes { destination in
                var offset = 0
                while offset < destination.count {
                    let count = min(1_048_576, destination.count - offset)
                    let chunk = try readExactly(count)
                    chunk.copyBytes(to: UnsafeMutableRawBufferPointer(
                        rebasing: destination[offset ..< offset + count]
                    ))
                    offset += count
                }
            }
            guard rgba.allSatisfy(\.isFinite),
                  stride(from: 3, to: rgba.count, by: 4)
                    .allSatisfy({ rgba[$0] == 1 })
            else { throw WIPReviewOFXError.invalidPayload }
            return (rgba, raster)
        }

        private func finishSynchronously() throws {
            stateLock.lock()
            let shouldFinish = !isFinished
            isFinished = true
            stateLock.unlock()
            guard shouldFinish else { return }
            try input.close()
            process.waitUntilExit()
            let message = String(
                data: diagnostic.readDataToEndOfFile(), encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0 else {
                throw WIPReviewOFXError.hostFailed(
                    message.isEmpty ? "status \(process.terminationStatus)" : message
                )
            }
        }

        private func readExactly(_ count: Int) throws -> Data {
            var result = Data()
            result.reserveCapacity(count)
            while result.count < count {
                guard let chunk = try output.read(
                    upToCount: count - result.count
                ), !chunk.isEmpty else {
                    throw WIPReviewOFXError.invalidPayload
                }
                result.append(chunk)
            }
            return result
        }

        private func sessionIsOpen() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return !isFinished
        }

        private func readValue<T>() throws -> T {
            let data = try readExactly(MemoryLayout<T>.size)
            return data.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        }

        private func append<T>(_ value: T, to data: inout Data) {
            var value = value
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }

        private func append(_ value: String, to data: inout Data) throws {
            let bytes = Data(value.utf8)
            guard bytes.count <= 1_048_576 else {
                throw WIPReviewOFXError.invalidPayload
            }
            append(UInt32(bytes.count), to: &data)
            data.append(bytes)
        }
    }

    fileprivate static func parameters(
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
