import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FrameCheckPNG {
    static let metadataKeyword = "ScreenSimulation.PhysicalFrame.v1"

    static func jsonObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func finalizedMetadata(
        _ base: [String: Any], rgba8: [UInt8]
    ) throws -> Data {
        var document = base
        let configuration = try JSONSerialization.data(
            withJSONObject: document, options: [.sortedKeys]
        )
        document["hashes"] = [
            "configurationSHA256": sha256(configuration),
            "pixelRGBA8SHA256": sha256(Data(rgba8)),
        ]
        return try JSONSerialization.data(
            withJSONObject: document, options: [.sortedKeys]
        )
    }

    static func encode(
        rgba8: [UInt8], width: Int, height: Int,
        colorSpace: CGColorSpace?, metadata: Data
    ) throws -> Data {
        guard rgba8.count == width * height * 4,
              let provider = CGDataProvider(data: Data(rgba8) as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { throw NativeOutputError.invalidFrame }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil
        ) else { throw NativeOutputError.invalidFrame }
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGDescription: "SCREEN Simulation physical-frame check",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFSoftware: "SCREEN Simulation",
                kCGImagePropertyTIFFDateTime: ISO8601DateFormatter().string(from: Date()),
            ],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw NativeOutputError.invalidFrame
        }
        return try insertingITXt(metadata, into: encoded as Data)
    }

    static func metadata(in png: Data) -> Data? {
        for chunk in chunks(in: png) where chunk.type == "iTXt" {
            var prefix = Data(metadataKeyword.utf8)
            prefix.append(contentsOf: [0, 0, 0, 0, 0])
            guard chunk.payload.starts(with: prefix) else { continue }
            return Data(chunk.payload.dropFirst(prefix.count))
        }
        return nil
    }

    private struct Chunk {
        let type: String
        let start: Int
        let end: Int
        let payload: Data
    }

    private static func chunks(in png: Data) -> [Chunk] {
        guard png.count >= 8, png.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else {
            return []
        }
        var result: [Chunk] = []
        var cursor = 8
        while cursor + 12 <= png.count {
            let length = Int(readUInt32(png, at: cursor))
            let end = cursor + 12 + length
            guard end <= png.count else { return [] }
            let typeData = png[(cursor + 4)..<(cursor + 8)]
            result.append(Chunk(
                type: String(decoding: typeData, as: UTF8.self),
                start: cursor, end: end,
                payload: Data(png[(cursor + 8)..<(cursor + 8 + length)])
            ))
            cursor = end
        }
        return result
    }

    private static func insertingITXt(_ metadata: Data, into png: Data) throws -> Data {
        guard let iend = chunks(in: png).first(where: { $0.type == "IEND" }) else {
            throw NativeOutputError.invalidFrame
        }
        var payload = Data(metadataKeyword.utf8)
        payload.append(contentsOf: [0, 0, 0, 0, 0])
        payload.append(metadata)
        let type = Data("iTXt".utf8)
        var chunk = Data()
        appendUInt32(UInt32(payload.count), to: &chunk)
        chunk.append(type)
        chunk.append(payload)
        appendUInt32(crc32(type + payload), to: &chunk)
        var result = Data(png[..<iend.start])
        result.append(chunk)
        result.append(png[iend.start...])
        return result
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(contentsOf: [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0)
            }
        }
        return crc ^ UInt32.max
    }
}
