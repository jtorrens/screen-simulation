import AppKit
import Foundation
import ScreenSimulationPresentation

enum SceneSettingsBlock: String, Codable, CaseIterable, Identifiable, Sendable {
    case general
    case reference
    case device
    case environment
    case camera
    case delivery
    case deviceTransform
    case cameraTransform

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .reference: "Referencia"
        case .device: "Device"
        case .environment: "Entorno"
        case .camera: "Cámara"
        case .delivery: "Raster de entrega"
        case .deviceTransform: "Transformación de Device"
        case .cameraTransform: "Transformación de Cámara"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .reference: "photo"
        case .device: "display"
        case .environment: "globe"
        case .camera: "camera"
        case .delivery: "rectangle.inset.filled"
        case .deviceTransform: "move.3d"
        case .cameraTransform: "camera.rotate"
        }
    }
}

struct SceneSettingsOwnership: Sendable {
    let controlBlocks: [String: SceneSettingsBlock]

    init(controlBlocks: [String: SceneSettingsBlock]) {
        self.controlBlocks = controlBlocks
    }

    init(presentation: TestPagePresentation) throws {
        try self.init(presentations: [presentation])
    }

    init(presentations: [TestPagePresentation]) throws {
        guard !presentations.isEmpty else {
            throw SceneLibraryError.invalidDocument(
                "Application no publicó tarjetas para el portapapeles."
            )
        }
        var ownership: [String: SceneSettingsBlock] = [:]
        for presentation in presentations {
            for group in presentation.inspectorGroups {
                for section in group.sections {
                    let block: SceneSettingsBlock? = switch (group.id, section.id) {
                    case ("device", "device.geometry"): .deviceTransform
                    case ("camera", "camera.geometry"): .cameraTransform
                    case ("device", _): .device
                    case ("environment", _): .environment
                    case ("camera", _): .camera
                    case ("delivery", _): .delivery
                    default: nil
                    }
                    guard let block else {
                        throw SceneLibraryError.invalidDocument(
                            "Application publicó una tarjeta sin contrato de portapapeles: \(group.id)/\(section.id)."
                        )
                    }
                    for control in section.controls {
                        if let existing = ownership[control.id], existing != block {
                            throw SceneLibraryError.invalidDocument(
                                "Application publicó dos propietarios para \(control.id)."
                            )
                        }
                        ownership[control.id] = block
                    }
                }
            }
            for control in presentation.previewControls {
                if let existing = ownership[control.id], existing != .general {
                    throw SceneLibraryError.invalidDocument(
                        "Application publicó dos propietarios para \(control.id)."
                    )
                }
                ownership[control.id] = .general
            }
        }
        controlBlocks = ownership
    }
}

struct SceneSettingsClipboardDocument: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SceneSettingsClipboard.v1"
    static let pasteboardType = NSPasteboard.PasteboardType(
        "com.jtorrens.screen-simulation.scene-settings.v1"
    )

    let schema: String
    let sourceSceneID: UUID
    let sourceSceneName: String
    let includedBlocks: [SceneSettingsBlock]
    let snapshot: SavedSceneSnapshot
    let generatedEnvironmentEXR: Data?

    init(
        source: SavedScene,
        includedBlocks: Set<SceneSettingsBlock>,
        generatedEnvironmentEXR: Data?
    ) throws {
        schema = Self.schema
        sourceSceneID = source.id
        sourceSceneName = source.name
        self.includedBlocks = SceneSettingsBlock.allCases.filter(includedBlocks.contains)
        snapshot = source.snapshot
        self.generatedEnvironmentEXR = generatedEnvironmentEXR
        try validate()
    }

    func validate() throws {
        guard schema == Self.schema,
              !sourceSceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !includedBlocks.isEmpty,
              Set(includedBlocks).count == includedBlocks.count,
              includedBlocks == SceneSettingsBlock.allCases.filter(Set(includedBlocks).contains)
        else {
            throw SceneLibraryError.invalidDocument("El portapapeles de settings no es válido.")
        }
        try snapshot.validate()
        guard (snapshot.generatedEnvironment != nil) == (generatedEnvironmentEXR != nil)
                || !includedBlocks.contains(.environment)
        else {
            throw SceneLibraryError.invalidDocument(
                "El bloque Entorno no contiene su recurso generado completo."
            )
        }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == [
                "schema", "sourceSceneID", "sourceSceneName", "includedBlocks", "snapshot",
              ] || Set(root.keys) == [
                "schema", "sourceSceneID", "sourceSceneName", "includedBlocks",
                "snapshot", "generatedEnvironmentEXR",
              ]
        else {
            throw SceneLibraryError.invalidDocument(
                "El portapapeles contiene campos desconocidos."
            )
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        let canonicalObject = try JSONSerialization.jsonObject(with: value.encoded())
        let normalizedInput = try JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys]
        )
        let normalizedCanonical = try JSONSerialization.data(
            withJSONObject: canonicalObject, options: [.sortedKeys]
        )
        guard normalizedInput == normalizedCanonical else {
            throw SceneLibraryError.invalidDocument(
                "El portapapeles contiene campos desconocidos o una representación obsoleta."
            )
        }
        return value
    }

    static func read(from pasteboard: NSPasteboard = .general) -> Self? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return try? decode(data)
    }

    func write(to pasteboard: NSPasteboard = .general) throws {
        pasteboard.clearContents()
        guard pasteboard.setData(try encoded(), forType: Self.pasteboardType) else {
            throw SceneLibraryError.inaccessible("No se han podido copiar los settings.")
        }
    }

    var containsAnimation: Bool {
        (includedBlocks.contains(.cameraTransform) && (
            snapshot.tracking != nil || snapshot.fusionTrackerMotion?.target == .camera
        )) || (includedBlocks.contains(.deviceTransform)
            && snapshot.fusionTrackerMotion?.target == .device)
    }
}

extension SavedSceneSnapshot {
    func applyingSettings(
        from source: SavedSceneSnapshot,
        blocks: Set<SceneSettingsBlock>,
        ownership: SceneSettingsOwnership
    ) throws -> SavedSceneSnapshot {
        guard !blocks.isEmpty else {
            throw SceneLibraryError.invalidDocument("Selecciona al menos una tarjeta de settings.")
        }

        func block(for override: SceneControlOverride) throws -> SceneSettingsBlock {
            guard let block = ownership.controlBlocks[override.controlID] else {
                throw SceneLibraryError.invalidDocument(
                    "Application no publicó el propietario de \(override.controlID)."
                )
            }
            return block
        }

        var mergedOverrides = try authoring.overrides.filter { !blocks.contains(try block(for: $0)) }
        mergedOverrides += try source.authoring.overrides.filter { blocks.contains(try block(for: $0)) }
        mergedOverrides.sort { $0.controlID < $1.controlID }

        func mergedStageOverrides() throws -> [PhysicalModelAuthoringState.Stage] {
            func owner(_ stage: PhysicalModelAuthoringState.Stage) throws -> SceneSettingsBlock {
                guard let physicalStage = PhysicalStageID(rawValue: stage.stableID) else {
                    throw SceneLibraryError.invalidDocument("El stage \(stage.stableID) no existe.")
                }
                return physicalStage.domain == .screen ? .device : .camera
            }
            var values = try authoring.modelOverrides.stages.filter {
                !blocks.contains(try owner($0))
            }
            values += try source.authoring.modelOverrides.stages.filter {
                blocks.contains(try owner($0))
            }
            return values.sorted { $0.stableID < $1.stableID }
        }

        let targetProfiles = authoring.profiles
        let sourceProfiles = source.authoring.profiles
        let profiles = SceneProfileSelection(
            deviceID: blocks.contains(.device) ? sourceProfiles.deviceID : targetProfiles.deviceID,
            coverGlassID: blocks.contains(.device) ? sourceProfiles.coverGlassID : targetProfiles.coverGlassID,
            captureID: blocks.contains(.camera) ? sourceProfiles.captureID : targetProfiles.captureID,
            lensID: blocks.contains(.camera) ? sourceProfiles.lensID : targetProfiles.lensID,
            environmentID: blocks.contains(.environment) ? sourceProfiles.environmentID : targetProfiles.environmentID,
            deliveryID: blocks.contains(.delivery) ? sourceProfiles.deliveryID : targetProfiles.deliveryID,
            recordingID: blocks.contains(.camera) ? sourceProfiles.recordingID : targetProfiles.recordingID
        )

        let targetContext = authoring.context
        let sourceContext = source.authoring.context
        let context = SceneAuthoringContext(
            sourceInputTransformID: blocks.contains(.general)
                ? sourceContext.sourceInputTransformID : targetContext.sourceInputTransformID,
            sourceAlphaMode: blocks.contains(.general)
                ? sourceContext.sourceAlphaMode : targetContext.sourceAlphaMode,
            sourceColorModel: blocks.contains(.general)
                ? sourceContext.sourceColorModel : targetContext.sourceColorModel,
            sourceYUVMatrix: blocks.contains(.general)
                ? sourceContext.sourceYUVMatrix : targetContext.sourceYUVMatrix,
            sourceSignalRange: blocks.contains(.general)
                ? sourceContext.sourceSignalRange : targetContext.sourceSignalRange,
            sourcePlacementID: blocks.contains(.general)
                ? sourceContext.sourcePlacementID : targetContext.sourcePlacementID,
            previewOutputTransformID: blocks.contains(.general)
                ? sourceContext.previewOutputTransformID : targetContext.previewOutputTransformID,
            previewPhaseID: blocks.contains(.general)
                ? sourceContext.previewPhaseID : targetContext.previewPhaseID,
            referencePlateID: blocks.contains(.reference)
                ? sourceContext.referencePlateID : targetContext.referencePlateID,
            environmentResource: blocks.contains(.environment)
                ? sourceContext.environmentResource : targetContext.environmentResource,
            referenceResource: blocks.contains(.reference)
                ? sourceContext.referenceResource : targetContext.referenceResource
        )
        let modelOverrides = SceneModelOverrides(
            screen: blocks.contains(.device)
                ? source.authoring.modelOverrides.screen : authoring.modelOverrides.screen,
            stages: try mergedStageOverrides()
        )
        let mergedAuthoring = SceneAuthoringDocument(
            profiles: profiles,
            overrides: mergedOverrides,
            modelOverrides: modelOverrides,
            context: context,
            environmentCalibration: blocks.contains(.environment)
                ? source.authoring.environmentCalibration : authoring.environmentCalibration
        )
        var mergedFusionTrackerMotion = fusionTrackerMotion
        for (block, target) in [
            (SceneSettingsBlock.cameraTransform, FusionTrackerTarget.camera),
            (.deviceTransform, .device),
        ] where blocks.contains(block) {
            if mergedFusionTrackerMotion?.target == target { mergedFusionTrackerMotion = nil }
            if source.fusionTrackerMotion?.target == target {
                mergedFusionTrackerMotion = source.fusionTrackerMotion
            }
        }
        let result = SavedSceneSnapshot(
            source: self.source,
            currentFrame: currentFrame,
            viewerZoom: viewerZoom,
            viewerPanX: viewerPanX,
            viewerPanY: viewerPanY,
            viewerIsFitted: viewerIsFitted,
            authoring: mergedAuthoring,
            generatedEnvironment: blocks.contains(.environment)
                ? source.generatedEnvironment : generatedEnvironment,
            tracking: blocks.contains(.cameraTransform) ? source.tracking : tracking,
            fusionTrackerMotion: mergedFusionTrackerMotion
        )
        try result.validate()
        return result
    }
}
