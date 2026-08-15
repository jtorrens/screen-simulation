import Foundation

enum PhysicalSettingsExchange {
    static let schema = "ScreenSimulation.FrameSettings.v18"

    struct EnvironmentResource: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case procedural, image }
        let kind: Kind
        let fileName: String?
        let sha256: String?
        let inputTransformID: String?

        func validate() throws {
            switch kind {
            case .procedural:
                guard fileName == nil, sha256 == nil, inputTransformID == nil else {
                    throw ImportError.invalidEnvironmentResource
                }
            case .image:
                guard let fileName, !fileName.isEmpty,
                      let sha256, sha256.count == 64,
                      sha256.allSatisfy({ $0.isHexDigit }),
                      let inputTransformID, !inputTransformID.isEmpty
                else { throw ImportError.invalidEnvironmentResource }
            }
        }
    }

    struct FrameContext: Codable, Equatable, Sendable {
        let selection: TestAuthoringResolvedSelection
        let sourceInputTransformID: String
        let sourceAlphaMode: String
        let sourceColorModel: String
        let sourceYUVMatrix: String
        let sourceSignalRange: String
        let sourcePlacementID: String
        let previewOutputTransformID: String
        let previewPhaseID: String
        let environmentResource: EnvironmentResource
        let referenceResource: ReferenceResource
    }

    struct ReferenceResource: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case none, imageOrVideo }
        let kind: Kind
        let fileName: String?
        let sha256: String?
        let inputTransformID: String?
        let alphaMode: String?
        let signalColorModel: String?
        let signalMatrix: String?
        let signalRange: String?
        let placementID: String?
        let corners: [ReferenceCorner]

        func validate() throws {
            switch kind {
            case .none:
                guard fileName == nil, sha256 == nil, inputTransformID == nil,
                      alphaMode == nil, signalColorModel == nil, signalMatrix == nil,
                      signalRange == nil, placementID == nil,
                      corners.isEmpty
                else { throw ImportError.invalidReferenceResource }
            case .imageOrVideo:
                guard let fileName, !fileName.isEmpty,
                      let sha256, sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
                      let inputTransformID, !inputTransformID.isEmpty,
                      let alphaMode, !alphaMode.isEmpty,
                      let signalColorModel, !signalColorModel.isEmpty,
                      let signalMatrix, !signalMatrix.isEmpty,
                      let signalRange, !signalRange.isEmpty,
                      let placementID, !placementID.isEmpty,
                      corners.count == 4, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
                else { throw ImportError.invalidReferenceResource }
            }
        }
    }

    struct ReferenceCorner: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
    }

    struct Imported: Sendable {
        let device: DeviceDefinition
        let pipeline: PhysicalPipelineAuthoringState
        let model: PhysicalModelAuthoringState
        let context: FrameContext?
        let report: String
    }

    static func metadata(
        device: DeviceDefinition,
        pipeline: PhysicalPipelineAuthoringState,
        model: PhysicalModelAuthoringState,
        context: FrameContext
    ) -> [String: Any]? {
        guard let deviceObject = FrameCheckPNG.jsonObject(device),
              let pipelineObject = FrameCheckPNG.jsonObject(pipeline),
              let contextObject = FrameCheckPNG.jsonObject(context)
        else { return nil }
        let stages: [[String: Any]] = model.stages.map { stage in
            switch stage.control {
            case let .continuous(value):
                return [
                    "stageID": stage.stableID,
                    "kind": "continuous",
                    "storedAmount": value.storedAmount,
                    "bypassed": value.isBypassed,
                ]
            case let .discrete(enabled):
                return [
                    "stageID": stage.stableID,
                    "kind": "discrete",
                    "enabled": enabled,
                ]
            }
        }
        return [
            "schema": schema,
            "device": deviceObject,
            "pipeline": pipelineObject,
            "context": contextObject,
            "screen": [
                "storedAmount": model.screen.storedAmount,
                "bypassed": model.screen.isBypassed,
            ],
            "stages": stages,
        ]
    }

    @MainActor
    static func decode(from document: [String: Any]) throws -> Imported {
        guard let settings = document["settings"] as? [String: Any] else {
            throw ImportError.missingSettings
        }
        guard settings["schema"] as? String == schema else {
            throw ImportError.unsupportedSchema(settings["schema"] as? String)
        }
        let decoder = JSONDecoder()
        let device = try decoder.decode(
            DeviceDefinition.self,
            from: try JSONSerialization.data(withJSONObject: requiredObject("device", in: settings))
        )
        let pipeline = try decoder.decode(
            PhysicalPipelineAuthoringState.self,
            from: try JSONSerialization.data(withJSONObject: requiredObject("pipeline", in: settings))
        )
        _ = try device.resolved()
        _ = try pipeline.resolvedPipeline()
        let context = try decoder.decode(
            FrameContext.self,
            from: try JSONSerialization.data(withJSONObject: requiredObject("context", in: settings))
        )
        try context.environmentResource.validate()
        try context.referenceResource.validate()

        guard let screen = settings["screen"] as? [String: Any],
              let amount = number(screen["storedAmount"]),
              let bypassed = screen["bypassed"] as? Bool,
              let stageObjects = settings["stages"] as? [[String: Any]]
        else { throw ImportError.invalidModel }
        var stages: [PhysicalModelAuthoringState.Stage] = []
        for object in stageObjects {
            guard let idNumber = number(object["stageID"]),
                  let kind = object["kind"] as? String
            else { throw ImportError.invalidModel }
            let id = UInt32(idNumber)
            let control: PhysicalModelAuthoringState.StageControl
            if kind == "continuous",
               let storedAmount = number(object["storedAmount"]),
               let isBypassed = object["bypassed"] as? Bool {
                control = .continuous(.init(
                    storedAmount: storedAmount,
                    isBypassed: isBypassed
                ))
            } else if kind == "discrete", let enabled = object["enabled"] as? Bool {
                control = .discrete(enabled: enabled)
            } else {
                throw ImportError.invalidModel
            }
            stages.append(.init(stableID: id, control: control))
        }
        let model = PhysicalModelAuthoringState(
            screen: .init(storedAmount: amount, isBypassed: bypassed),
            stages: stages
        )
        let imported = try validated(model: model)
        return Imported(
            device: device,
            pipeline: pipeline,
            model: imported,
            context: context,
            report: report(device: device, pipeline: pipeline, model: imported, context: context)
        )
    }

    @MainActor
    private static func validated(
        model: PhysicalModelAuthoringState
    ) throws -> PhysicalModelAuthoringState {
        let controller = PhysicalModelController()
        try controller.restoreAuthoringState(model)
        return controller.authoringState
    }

    private static func requiredObject(
        _ key: String, in container: [String: Any]
    ) throws -> [String: Any] {
        guard let object = container[key] as? [String: Any] else {
            throw ImportError.missingField(key)
        }
        return object
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func report(
        device: DeviceDefinition,
        pipeline: PhysicalPipelineAuthoringState,
        model: PhysicalModelAuthoringState,
        context: FrameContext
    ) -> String {
        """
        SCREEN Simulation · importación física
        Esquema: \(schema)

        Aplicados
        • Device: \(device.name) · \(device.nativeWidth)×\(device.nativeHeight)
        • Panel: luminancia, EOTF, colorimetría, geometría subpíxel, uniformidad, temporal y light spread
        • Cristal y entorno
        • Pose cámara/pantalla y modelo de lente
        • Obturación, rolling shutter y muestreo temporal
        • Sensor, CFA, ruido, RAW y revelado
        • Cámara, raster de captura y objetivo
        • Raster de entrega, transform de grabación y codec
        • Interpretación de fuente, colocación, preview y fase visible
        • Recurso de entorno con identidad SHA-256 e interpretación radiométrica
        • Contribución maestra y \(model.stages.count) controles de etapa

        Conservados deliberadamente
        • Fuente y fotograma actual
        • Zoom, pan, transporte, render y DeckLink
        • Armado de animación/keyframes

        Incompatibles u omitidos
        • Fuente de imagen/vídeo (se conserva; el PNG guarda su interpretación, no sus píxeles)
        • Perfil ColorSync observado del monitor

        Importación atómica: una sola operación de Undo.
        """
    }

    enum ImportError: LocalizedError {
        case missingSettings
        case unsupportedSchema(String?)
        case missingField(String)
        case invalidModel
        case invalidEnvironmentResource
        case unavailableEnvironmentResource(String)
        case invalidReferenceResource
        case unavailableReferenceResource(String)

        var errorDescription: String? {
            switch self {
            case .missingSettings:
                "El PNG no contiene el bloque estructurado de ajustes físicos. Los PNG anteriores a esta versión solo permiten inspección manual."
            case let .unsupportedSchema(value):
                "Esquema de ajustes no compatible: \(value ?? "ausente")."
            case let .missingField(field):
                "Falta el campo físico obligatorio ‘\(field)’ en el PNG."
            case .invalidModel:
                "Los controles físicos del PNG no cumplen el contrato vigente."
            case .invalidEnvironmentResource:
                "La identidad del entorno HDR del PNG es incompleta o inválida."
            case let .unavailableEnvironmentResource(name):
                "El frame necesita el entorno HDR ‘\(name)’. Selecciona primero ese archivo con Browse; su SHA-256 debe coincidir y después repite la importación."
            case .invalidReferenceResource:
                "La identidad o los cuatro puntos de la referencia son inválidos."
            case let .unavailableReferenceResource(name):
                "El frame necesita la referencia ‘\(name)’, que no está en la biblioteca estable."
            }
        }
    }
}
