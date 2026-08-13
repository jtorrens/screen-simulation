import Foundation
import StudioColor

enum DeviceSignalCheckpointError: Error, LocalizedError {
    case invalidMetadata(String)
    case destinationExists(String)
    case invalidRaster

    var errorDescription: String? {
        switch self {
        case let .invalidMetadata(message): message
        case let .destinationExists(path): "El checkpoint ya existe: \(path)"
        case .invalidRaster: "El raster del checkpoint no coincide con sus metadatos."
        }
    }
}

struct DeviceSignalCheckpointMetadata: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.FeederSignalCheckpoint.v3"

    let schema: String
    let width: Int
    let height: Int
    let pixelEncoding: String
    let inputTransformID: String
    let inputReferenceDomain: String
    let outputSignalID: String
    let feederOutputTransformID: String
    let alphaInterpretation: String
    let sourceAdjustment: SceneAdjustmentParameters

    init(
        width: Int,
        height: Int,
        inputTransform: StudioColorInputTransform,
        outputSignal: StudioColorMode,
        feederOutput: StudioColorOutputTransform,
        alphaInterpretation: String,
        sourceAdjustment: SceneAdjustmentParameters
    ) {
        schema = Self.schema
        self.width = width
        self.height = height
        pixelEncoding = "rgba16Float-little-endian"
        inputTransformID = inputTransform.id
        inputReferenceDomain = inputTransform.referenceDomain.rawValue
        outputSignalID = outputSignal.id
        feederOutputTransformID = feederOutput.id
        self.alphaInterpretation = alphaInterpretation
        self.sourceAdjustment = sourceAdjustment
    }

    func validate() throws {
        guard schema == Self.schema else {
            throw DeviceSignalCheckpointError.invalidMetadata("Schema desconocido: \(schema)")
        }
        guard width > 0, height > 0, pixelEncoding == "rgba16Float-little-endian" else {
            throw DeviceSignalCheckpointError.invalidMetadata("Raster o codificación inválidos.")
        }
        guard let inputTransform = StudioColorInputTransform.catalog.first(where: {
            $0.id == inputTransformID && $0.referenceDomain.rawValue == inputReferenceDomain
        }) else {
            throw DeviceSignalCheckpointError.invalidMetadata("Input Transform desconocido.")
        }
        guard let outputSignal = StudioColorMode.catalog.first(where: {
            $0.id == outputSignalID
        }) else {
            throw DeviceSignalCheckpointError.invalidMetadata("Output Signal desconocida.")
        }
        guard outputSignal.resolvedOutput(for: inputTransform).id == feederOutputTransformID else {
            throw DeviceSignalCheckpointError.invalidMetadata(
                "El feeder no corresponde al Input Transform y Output Signal declarados."
            )
        }
        guard sourceAdjustment.exposureEV.isFinite,
              (-8 ... 8).contains(sourceAdjustment.exposureEV),
              sourceAdjustment.contrast.isFinite,
              (0.25 ... 4).contains(sourceAdjustment.contrast),
              sourceAdjustment.saturation.isFinite,
              (0 ... 4).contains(sourceAdjustment.saturation),
              sourceAdjustment.temperatureKelvin.isFinite,
              (2000 ... 12_000).contains(sourceAdjustment.temperatureKelvin),
              sourceAdjustment.tint.isFinite,
              (-1 ... 1).contains(sourceAdjustment.tint)
        else {
            throw DeviceSignalCheckpointError.invalidMetadata(
                "El ajuste de fuente no pertenece al contrato vigente."
            )
        }
    }
}

struct DeviceSignalCheckpoint: @unchecked Sendable {
    let sourceACEScg: StudioColorMetalFrame
    let deviceSignal: StudioColorMetalFrame
    let metadata: DeviceSignalCheckpointMetadata

    @MainActor
    static func prepare(
        sourceACEScg: StudioColorMetalFrame,
        inputTransform: StudioColorInputTransform,
        outputSignal: StudioColorMode,
        alphaInterpretation: String,
        sourceAdjustment: SceneAdjustmentParameters,
        display: StudioColorMetalDisplay
    ) throws -> Self {
        let feederOutput = outputSignal.resolvedOutput(for: inputTransform)
        let encodedSignal = try display.transformToMetalFrame(
            sourceACEScg,
            output: feederOutput
        )
        let deviceSignal = try display.materializeSharedRGBA16F(encodedSignal)
        return Self(
            sourceACEScg: sourceACEScg,
            deviceSignal: deviceSignal,
            metadata: .init(
                width: deviceSignal.width,
                height: deviceSignal.height,
                inputTransform: inputTransform,
                outputSignal: outputSignal,
                feederOutput: feederOutput,
                alphaInterpretation: alphaInterpretation,
                sourceAdjustment: sourceAdjustment
            )
        )
    }

    @MainActor
    func write(to packageURL: URL, display: StudioColorMetalDisplay) throws {
        try metadata.validate()
        guard !FileManager.default.fileExists(atPath: packageURL.path) else {
            throw DeviceSignalCheckpointError.destinationExists(packageURL.path)
        }
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: false)
        do {
            let metadataData = try JSONEncoder.checkpoint.encode(metadata)
            try metadataData.write(
                to: packageURL.appendingPathComponent("checkpoint.json"),
                options: .atomic
            )
            let values = try display.readLinearRGBA(deviceSignal)
            guard values.count == metadata.width * metadata.height * 4 else {
                throw DeviceSignalCheckpointError.invalidRaster
            }
            var words = values.map { Float16($0).bitPattern.littleEndian }
            let bytes = words.withUnsafeMutableBytes { Data($0) }
            try bytes.write(
                to: packageURL.appendingPathComponent("rgba16f.bin"),
                options: .atomic
            )
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }
}

struct DeviceSignalCheckpointPayload: Sendable {
    let metadata: DeviceSignalCheckpointMetadata
    let rgba: [Float]

    static func read(from packageURL: URL) throws -> Self {
        let entries = try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        guard entries == ["checkpoint.json", "rgba16f.bin"] else {
            throw DeviceSignalCheckpointError.invalidMetadata(
                "El paquete contiene archivos desconocidos o incompletos."
            )
        }
        let metadataData = try Data(
            contentsOf: packageURL.appendingPathComponent("checkpoint.json")
        )
        let object = try JSONSerialization.jsonObject(with: metadataData)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == DeviceSignalCheckpointMetadata.codingKeys else {
            throw DeviceSignalCheckpointError.invalidMetadata(
                "Los campos del checkpoint no coinciden con el contrato actual."
            )
        }
        let metadata = try JSONDecoder().decode(
            DeviceSignalCheckpointMetadata.self,
            from: metadataData
        )
        try metadata.validate()
        let bytes = try Data(contentsOf: packageURL.appendingPathComponent("rgba16f.bin"))
        let expectedCount = metadata.width * metadata.height * 4 * MemoryLayout<UInt16>.size
        guard bytes.count == expectedCount else {
            throw DeviceSignalCheckpointError.invalidRaster
        }
        let rgba = bytes.withUnsafeBytes { storage -> [Float] in
            let octets = storage.bindMemory(to: UInt8.self)
            return stride(from: 0, to: octets.count, by: 2).map { index in
                let word = UInt16(octets[index]) | UInt16(octets[index + 1]) << 8
                return Float(Float16(bitPattern: word))
            }
        }
        return Self(metadata: metadata, rgba: rgba)
    }
}

private extension DeviceSignalCheckpointMetadata {
    static let codingKeys: Set<String> = [
        "schema",
        "width",
        "height",
        "pixelEncoding",
        "inputTransformID",
        "inputReferenceDomain",
        "outputSignalID",
        "feederOutputTransformID",
        "alphaInterpretation",
        "sourceAdjustment",
    ]
}

private extension JSONEncoder {
    static var checkpoint: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
