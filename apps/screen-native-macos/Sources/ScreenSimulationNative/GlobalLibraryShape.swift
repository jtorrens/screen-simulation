import Foundation

/// Compare JSON keys with the owning Codable representation, recursively. Values and
/// required fields are validated by decoding and the domain's existing validators.
enum GlobalLibraryShape {
    static func validate(_ data: Data, document: GlobalLibraryDocument) throws {
        let input = try JSONSerialization.jsonObject(with: data)
        let encoded = try JSONEncoder().encode(document)
        let canonical = try JSONSerialization.jsonObject(with: encoded)
        try compare(input, canonical, path: "GlobalLibrary")
    }

    private static func compare(_ input: Any, _ canonical: Any, path: String) throws {
        if let object = input as? [String: Any], let expected = canonical as? [String: Any] {
            // Synthesized Codable omits nil optionals. Explicit JSON null has the
            // same domain meaning only for these declared optional properties.
            let optional: Set<String> = switch path {
            case "GlobalLibrary.cameras[].value": ["nativeVFXEncodingID"]
            case "GlobalLibrary.renderPresets[].value": ["display", "view"]
            case "GlobalLibrary.wipReviewPresets[].value":
                ["customWidth", "customHeight", "customBlankingAspect"]
            default: []
            }
            for key in object.keys.sorted() {
                if let value = expected[key] {
                    try compare(object[key]!, value, path: "\(path).\(key)")
                } else if !(optional.contains(key) && object[key] is NSNull) {
                    throw GlobalLibraryError.invalidEntity(
                        "Campo desconocido en la biblioteca global: \(path).\(key)."
                    )
                }
            }
        } else if let values = input as? [Any], let expected = canonical as? [Any] {
            guard values.count == expected.count else {
                throw GlobalLibraryError.invalidEntity("Colección inválida: \(path).")
            }
            for (value, encoded) in zip(values, expected) {
                try compare(value, encoded, path: "\(path)[]")
            }
        }
    }
}
