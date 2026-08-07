import Foundation

enum PhysicalSettingsExchange {
    static let schema = "ScreenSimulation.PhysicalSettings.v1"

    struct Imported: Sendable {
        let device: DeviceDefinition
        let pipeline: PhysicalPipelineAuthoringState
        let model: PhysicalModelAuthoringState
        let report: String
    }

    static func metadata(
        device: DeviceDefinition,
        pipeline: PhysicalPipelineAuthoringState,
        model: PhysicalModelAuthoringState
    ) -> [String: Any]? {
        guard let deviceObject = FrameCheckPNG.jsonObject(device),
              let pipelineObject = FrameCheckPNG.jsonObject(pipeline)
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
            report: report(device: device, pipeline: pipeline, model: imported)
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
        model: PhysicalModelAuthoringState
    ) -> String {
        """
        SCREEN Simulation · importación física
        Esquema: \(schema)

        Aplicados
        • Device: \(device.name) · \(device.nativeWidth)×\(device.nativeHeight)
        • Panel: luminancia, EOTF, colorimetría, geometría subpíxel, temporal y light spread
        • Cristal y entorno
        • Pose cámara/pantalla y modelo de lente
        • Obturación, rolling shutter y muestreo temporal
        • Sensor, CFA, ruido, RAW y revelado
        • Contribución maestra y \(model.stages.count) controles de etapa

        Conservados deliberadamente
        • Fuente y fotograma actual
        • ODT de preview y perfil ColorSync
        • Calidad Draft/Media/Alta/Nativa
        • Zoom, pan, transporte, render y DeckLink
        • Armado de animación/keyframes

        Incompatibles u omitidos
        • Ninguno en este archivo (\(schema))

        Importación atómica: una sola operación de Undo.
        """
    }

    enum ImportError: LocalizedError {
        case missingSettings
        case unsupportedSchema(String?)
        case missingField(String)
        case invalidModel

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
            }
        }
    }
}
