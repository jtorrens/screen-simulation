import Foundation
import Testing
@testable import ScreenSimulationNative

private func clipboardContext(
    preview: String = "preview-a",
    reference: String = "black"
) -> SceneAuthoringContext {
    .init(
        sourceInputTransformID: "source-transform",
        sourceAlphaMode: "ignore",
        sourceColorModel: "rgb",
        sourceYUVMatrix: "bt709",
        sourceSignalRange: "full",
        sourcePlacementID: "fit",
        previewOutputTransformID: preview,
        previewPhaseID: "recording-codec",
        referencePlateID: reference,
        environmentResource: .init(
            kind: .procedural, fileName: nil, absolutePath: nil, inputTransformID: nil
        ),
        referenceResource: .init(
            kind: .none, fileName: nil, absolutePath: nil, inputTransformID: nil,
            alphaMode: nil, signalColorModel: nil, signalMatrix: nil,
            signalRange: nil, placementID: nil, corners: []
        )
    )
}

private func clipboardSnapshot(
    device: String,
    camera: String,
    overrides: [SceneControlOverride],
    preview: String
) -> SavedSceneSnapshot {
    .init(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [],
            missingMedia: nil
        ),
        currentFrame: 12,
        viewerZoom: 2,
        viewerPanX: 3,
        viewerPanY: 4,
        viewerIsFitted: false,
        authoring: .init(
            profiles: .init(
                deviceID: device,
                coverGlassID: "cover-\(device)",
                captureID: camera,
                lensID: "lens-\(camera)",
                environmentID: "environment",
                deliveryID: "delivery",
                recordingID: "recording-\(camera)"
            ),
            overrides: overrides,
            modelOverrides: .init(screen: nil, stages: []),
            context: clipboardContext(preview: preview),
            environmentCalibration: nil
        )
    )
}

private func clipboardScene(name: String, snapshot: SavedSceneSnapshot) -> SavedScene {
    let id = UUID()
    return SavedScene(
        id: id,
        name: name,
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: snapshot
    )
}

@Test func sceneSettingsClipboardRejectsUnknownFieldsAndDuplicateBlocks() throws {
    let scene = clipboardScene(
        name: "Origen",
        snapshot: clipboardSnapshot(
            device: "device-a", camera: "camera-a", overrides: [], preview: "preview-a"
        )
    )
    let clipboard = try SceneSettingsClipboardDocument(
        source: scene,
        includedBlocks: [.device, .cameraTransform],
        generatedEnvironmentEXR: nil
    )
    #expect(try SceneSettingsClipboardDocument.decode(clipboard.encoded()) == clipboard)

    var object = try #require(
        JSONSerialization.jsonObject(with: clipboard.encoded()) as? [String: Any]
    )
    object["legacy"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: SceneLibraryError.self) {
        try SceneSettingsClipboardDocument.decode(unknown)
    }

    object.removeValue(forKey: "legacy")
    object["includedBlocks"] = ["device", "device"]
    let duplicate = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: SceneLibraryError.self) {
        try SceneSettingsClipboardDocument.decode(duplicate)
    }
}

@Test func sceneSettingsPasteChangesOnlySelectedCardsAndPreservesViewerState() throws {
    let source = clipboardSnapshot(
        device: "device-source",
        camera: "camera-source",
        overrides: [
            .scalar("device-control", 8),
            .scalar("camera-control", 9),
            .scalar("camera-transform-control", 10),
        ],
        preview: "preview-source"
    )
    let target = clipboardSnapshot(
        device: "device-target",
        camera: "camera-target",
        overrides: [
            .scalar("device-control", 1),
            .scalar("camera-control", 2),
            .scalar("camera-transform-control", 3),
        ],
        preview: "preview-target"
    )
    let ownership = SceneSettingsOwnership(controlBlocks: [
        "device-control": .device,
        "camera-control": .camera,
        "camera-transform-control": .cameraTransform,
    ])

    let merged = try target.applyingSettings(
        from: source,
        blocks: [.device, .cameraTransform],
        ownership: ownership
    )
    #expect(merged.authoring.profiles.deviceID == "device-source")
    #expect(merged.authoring.profiles.captureID == "camera-target")
    #expect(merged.authoring.context.previewOutputTransformID == "preview-target")
    #expect(merged.viewerZoom == target.viewerZoom)
    #expect(merged.viewerPanX == target.viewerPanX)
    let values = Dictionary(uniqueKeysWithValues: merged.authoring.overrides.map {
        ($0.controlID, $0.scalar)
    })
    #expect(values["device-control"] == 8)
    #expect(values["camera-control"] == 2)
    #expect(values["camera-transform-control"] == 10)
}
