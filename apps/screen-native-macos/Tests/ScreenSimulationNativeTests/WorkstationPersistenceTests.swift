import Foundation
import Testing
@testable import ScreenSimulationNative

@Suite struct WorkstationPersistenceTests {
    @Test func absentCurrentDocumentRejectsOtherVersionsWithoutReadingOrWritingThem() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-current-contract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for family in ["GlobalLibrary", "Scenes", "RenderQueue"] {
            for version in [1, 7, 16, 17, 23, 29, 30, 999] {
                let directory = root.appendingPathComponent("\(family)-\(version)")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let old = directory.appendingPathComponent("\(family).v\(version).json")
                // Not decodable: detecting another version must not open it.
                let bytes = Data("unreadable old contract".utf8)
                try bytes.write(to: old)
                switch family {
                case "GlobalLibrary":
                    if version == 17 { continue }
                    let store = try GlobalLibraryStore(documentURL: directory.appendingPathComponent("GlobalLibrary.v17.json"))
                    #expect(throws: (any Error).self) { try store.load() }
                    #expect(!FileManager.default.fileExists(atPath: store.documentURL.path))
                case "Scenes":
                    let store = try SceneLibraryStore(directoryURL: directory)
                    #expect(throws: (any Error).self) { try store.load() }
                    #expect(!FileManager.default.fileExists(atPath: store.documentURL.path))
                default:
                    let store = try RenderQueueStore(directoryURL: directory)
                    #expect(throws: (any Error).self) { try store.load() }
                    #expect(!FileManager.default.fileExists(atPath: store.documentURL.path))
                }
                #expect(try Data(contentsOf: old) == bytes)
                #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [old.lastPathComponent])
            }
        }
    }

    @Test func uninitializedCollectionsAreReadOnlyAndCurrentDocumentsIgnoreOldFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-initial-contract-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scenes = try SceneLibraryStore(directoryURL: root.appendingPathComponent("scenes"))
        let queue = try RenderQueueStore(directoryURL: root.appendingPathComponent("queue"))
        let global = try GlobalLibraryStore(documentURL: root.appendingPathComponent("GlobalLibrary.v17.json"))
        let initialScenes = try scenes.load()
        let initialQueue = try queue.load()
        let initialGlobal = try global.load()
        #expect(initialScenes.scenes.isEmpty)
        #expect(initialQueue.jobs.isEmpty)
        for url in [scenes.documentURL, queue.documentURL, global.documentURL] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        try scenes.save(initialScenes)
        try queue.save(initialQueue)
        try global.save(initialGlobal)
        for (url, family) in [(scenes.documentURL, "Scenes"), (queue.documentURL, "RenderQueue"), (global.documentURL, "GlobalLibrary")] {
            try Data([0]).write(to: url.deletingLastPathComponent().appendingPathComponent("\(family).v1.json"))
        }
        #expect(try scenes.load() == initialScenes)
        #expect(try queue.load().jobs.isEmpty)
        #expect(try queue.load().isPaused == initialQueue.isPaused)
        #expect(try global.load() == initialGlobal)
    }

    @Test func globalLibraryRejectsUnknownKeysAtEveryObjectBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-strict-global-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try GlobalLibraryStore(documentURL: root.appendingPathComponent("GlobalLibrary.v17.json"))
        var document = GlobalLibraryDocument()
        // Include a user-authored external-image record as well as every seeded family.
        document.testImages = [.init(value: .init(
            id: UUID(), name: "User image", bookmark: Data([1]), inputTransformID: "acescg",
            alpha: .straight, matrix: .bt709, range: .full
        ), isLocked: false)]
        let data = try JSONEncoder().encode(document)
        let json = try JSONSerialization.jsonObject(with: data)
        let paths = objectPaths(json)
        #expect(paths.count > 100)
        for path in paths {
            let invalid = addingUnknown(json, path: path)
            let bytes = try JSONSerialization.data(withJSONObject: invalid)
            try bytes.write(to: store.documentURL)
            #expect(throws: GlobalLibraryError.self) { try store.load() }
            #expect(try Data(contentsOf: store.documentURL) == bytes)
        }
        try store.save(document)
        #expect(try store.load() == document)
    }

    @Test func globalLibraryAcceptsOnlyDeclaredOptionalNulls() throws {
        let document = GlobalLibraryDocument()
        let data = try JSONEncoder().encode(document)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var cameras = try #require(json["cameras"] as? [[String: Any]])
        var camera = try #require(cameras[0]["value"] as? [String: Any])
        camera["nativeVFXEncodingID"] = NSNull()
        cameras[0]["value"] = camera
        json["cameras"] = cameras
        let bytes = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(GlobalLibraryDocument.self, from: bytes)
        try GlobalLibraryShape.validate(bytes, document: decoded)
        #expect(decoded.cameras[0].nativeVFXEncodingID == nil)
        json["unknownOptional"] = NSNull()
        #expect(throws: GlobalLibraryError.self) {
            try GlobalLibraryShape.validate(JSONSerialization.data(withJSONObject: json), document: decoded)
        }
    }
}

private enum JSONStep { case key(String), index(Int) }
private func objectPaths(_ value: Any, path: [JSONStep] = []) -> [[JSONStep]] {
    if let object = value as? [String: Any] {
        return [path] + object.keys.sorted().flatMap { objectPaths(object[$0]!, path: path + [.key($0)]) }
    }
    if let values = value as? [Any] {
        return values.indices.flatMap { objectPaths(values[$0], path: path + [.index($0)]) }
    }
    return []
}
private func addingUnknown(_ value: Any, path: [JSONStep]) -> Any {
    guard let head = path.first else {
        var object = value as! [String: Any]
        object["unknownAuditField"] = NSNull()
        return object
    }
    switch head {
    case let .key(key):
        var object = value as! [String: Any]
        object[key] = addingUnknown(object[key]!, path: Array(path.dropFirst()))
        return object
    case let .index(index):
        var values = value as! [Any]
        values[index] = addingUnknown(values[index], path: Array(path.dropFirst()))
        return values
    }
}
