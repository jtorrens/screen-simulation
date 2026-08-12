import CryptoKit
import Foundation
import Testing

struct VfxReferenceFixture {
    struct AcceptedOutput {
        let pixelRGBA8SHA256: String
        let pixelRGBA16SHA256: String
    }

    let id: String
    let description: String
    let status: String
    let settings: [String: String]
    let acceptedOutput: AcceptedOutput?
    let fixtureSHA256: String
    let document: [String: Any]
    let resolvedResources: [[String: String]]

    static func load(
        from fixtureURL: URL,
        repositoryRoot: URL,
        resourceRoot: URL
    ) throws -> Self {
        let data = try Data(contentsOf: fixtureURL)
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        try requireKeys(
            document,
            exactly: [
                "schema", "version", "id", "description", "status", "settings",
                "resources", "acceptedOutput",
            ],
            context: "fixture"
        )
        #expect(document["schema"] as? String == "ScreenSimulation.VfxReferenceFixture")
        #expect((document["version"] as? NSNumber)?.intValue == 1)
        let id = try #require(document["id"] as? String)
        let description = try #require(document["description"] as? String)
        let status = try #require(document["status"] as? String)
        #expect(["candidate", "canonical"].contains(status))
        let settings = try #require(document["settings"] as? [String: String])
        try requireSettingContract(settings)

        let resourceObjects = try #require(document["resources"] as? [[String: Any]])
        var resolvedResources: [[String: String]] = []
        var resolvedSettings = settings
        for resource in resourceObjects {
            try requireKeys(
                resource,
                exactly: ["setting", "root", "relativePath", "sha256"],
                context: "resource"
            )
            let rootID = try #require(resource["root"] as? String)
            let relativePath = try #require(resource["relativePath"] as? String)
            let expectedHash = try #require(resource["sha256"] as? String)
            let root: URL
            switch rootID {
            case "repository": root = repositoryRoot
            case "resource-root": root = resourceRoot
            default:
                Issue.record("Root de recurso desconocido: \(rootID)")
                throw FixtureError.invalidResourceRoot(rootID)
            }
            let url = root.appendingPathComponent(relativePath).standardizedFileURL
            let data = try Data(contentsOf: url)
            let actualHash = sha256(data)
            #expect(actualHash == expectedHash)
            if let setting = resource["setting"] as? String {
                #expect(resolvedSettings[setting] == nil)
                resolvedSettings[setting] = url.path
            } else {
                #expect(resource["setting"] is NSNull)
            }
            resolvedResources.append([
                "root": rootID,
                "relativePath": relativePath,
                "resolvedPath": url.path,
                "sha256": actualHash,
            ])
        }

        let acceptedOutput: AcceptedOutput?
        if document["acceptedOutput"] is NSNull {
            acceptedOutput = nil
            #expect(status == "candidate")
        } else {
            let output = try #require(document["acceptedOutput"] as? [String: Any])
            try requireKeys(
                output,
                exactly: ["pixelRGBA8SHA256", "pixelRGBA16SHA256"],
                context: "acceptedOutput"
            )
            acceptedOutput = AcceptedOutput(
                pixelRGBA8SHA256: try #require(output["pixelRGBA8SHA256"] as? String),
                pixelRGBA16SHA256: try #require(output["pixelRGBA16SHA256"] as? String)
            )
            #expect(status == "canonical")
        }

        return Self(
            id: id,
            description: description,
            status: status,
            settings: resolvedSettings,
            acceptedOutput: acceptedOutput,
            fixtureSHA256: sha256(data),
            document: document,
            resolvedResources: resolvedResources
        )
    }

    private static func requireKeys(
        _ object: [String: Any], exactly expected: Set<String>, context: String
    ) throws {
        let actual = Set(object.keys)
        guard actual == expected else {
            let message = "Contrato \(context) inválido. Faltan "
                + "\(expected.subtracting(actual)); sobran \(actual.subtracting(expected))"
            Issue.record(Comment(rawValue: message))
            throw FixtureError.invalidKeys(context)
        }
    }

    private static func requireSettingContract(_ settings: [String: String]) throws {
        let expected: Set<String> = [
            "SCREEN_MOIRE_DEVICE_ID", "SCREEN_MOIRE_DEVICE_WIDTH",
            "SCREEN_MOIRE_DEVICE_HEIGHT", "SCREEN_MOIRE_COLOR_MODE_ID",
            "SCREEN_MOIRE_WHITE_NITS", "SCREEN_MOIRE_BLACK_MATRIX_FRACTION",
            "SCREEN_MOIRE_COVER_ID", "SCREEN_MOIRE_COVER_CHARACTER_STRENGTH",
            "SCREEN_MOIRE_COVER_THICKNESS_MILLIMETERS",
            "SCREEN_MOIRE_COVER_REFRACTIVE_INDEX",
            "SCREEN_MOIRE_COVER_ANTI_REFLECTIVE_EFFICIENCY",
            "SCREEN_MOIRE_COVER_ABSORPTION_R", "SCREEN_MOIRE_COVER_ABSORPTION_G",
            "SCREEN_MOIRE_COVER_ABSORPTION_B", "SCREEN_MOIRE_COVER_ROUGHNESS",
            "SCREEN_MOIRE_COVER_HAZE", "SCREEN_MOIRE_COVER_GLOW_PROFILE_STRENGTH",
            "SCREEN_MOIRE_COVER_GLOW_SCATTER_FRACTION",
            "SCREEN_MOIRE_COVER_GLOW_CORE_RADIUS_MILLIMETERS",
            "SCREEN_MOIRE_COVER_GLOW_TAIL_RADIUS_MILLIMETERS",
            "SCREEN_MOIRE_COVER_GLOW_TAIL_FRACTION", "SCREEN_MOIRE_CAPTURE_ID",
            "SCREEN_MOIRE_LENS_ID", "SCREEN_MOIRE_CAPTURE_WIDTH",
            "SCREEN_MOIRE_CAPTURE_HEIGHT", "SCREEN_MOIRE_PATTERN_ID",
            "SCREEN_MOIRE_SOURCE_INPUT_TRANSFORM_ID", "SCREEN_MOIRE_OUTPUT_TRANSFORM_ID",
            "SCREEN_MOIRE_ENVIRONMENT_INPUT_TRANSFORM_ID",
            "SCREEN_MOIRE_ENVIRONMENT_UNIT_RADIANCE_CDM2",
            "SCREEN_MOIRE_ENVIRONMENT_EXPOSURE_STOPS",
            "SCREEN_MOIRE_ENVIRONMENT_ROTATION_DEGREES", "SCREEN_MOIRE_DISTANCE_METERS",
            "SCREEN_MOIRE_ORBIT_X_DEGREES", "SCREEN_MOIRE_ORBIT_Y_DEGREES",
            "SCREEN_MOIRE_LOOK_AT_TARGET_WORLD_X_METERS",
            "SCREEN_MOIRE_LOOK_AT_TARGET_WORLD_Y_METERS", "SCREEN_MOIRE_CA_MODE",
            "SCREEN_MOIRE_LENS_EVALUATION_MODEL", "SCREEN_MOIRE_FOCUS_DISTANCE_METERS",
            "SCREEN_MOIRE_F_STOP", "SCREEN_MOIRE_ND_STOPS",
            "SCREEN_MOIRE_SHUTTER_SECONDS", "SCREEN_MOIRE_EXPOSURE_INDEX",
            "SCREEN_MOIRE_DEVELOP_EXPOSURE_EV",
            "SCREEN_MOIRE_COMPUTATIONAL_EXPOSURE_COUNT",
            "SCREEN_MOIRE_COMPUTATIONAL_BRACKET_SPACING_STOPS",
            "SCREEN_MOIRE_GLOBAL_SHUTTER", "SCREEN_MOIRE_COVER_GLOW_AMOUNT",
            "SCREEN_MOIRE_PANEL_SPREAD_AMOUNT", "SCREEN_MOIRE_PANEL_UNIFORMITY_AMOUNT",
            "SCREEN_MOIRE_PANEL_STRUCTURE_AMOUNT", "SCREEN_MOIRE_SENSOR_NOISE_AMOUNT",
            "SCREEN_MOIRE_LENS_AMOUNT", "SCREEN_MOIRE_COMPUTATIONAL_CHARACTER_STRENGTH",
            "SCREEN_MOIRE_BASELINE_INTERMEDIATE", "SCREEN_MOIRE_BASELINE_ONLY",
            "SCREEN_MOIRE_SKIP_REPEAT",
        ]
        let actual = Set(settings.keys)
        guard actual == expected else {
            let message = "Ajustes VFX incompletos. Faltan "
                + "\(expected.subtracting(actual)); sobran \(actual.subtracting(expected))"
            Issue.record(Comment(rawValue: message))
            throw FixtureError.invalidSettings
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum FixtureError: Error {
        case invalidKeys(String)
        case invalidSettings
        case invalidResourceRoot(String)
    }
}

@MainActor enum VfxReferenceFixtureRuntime {
    static var current: VfxReferenceFixture?

    static func setting(_ key: String) -> String? {
        current?.settings[key]
    }
}
