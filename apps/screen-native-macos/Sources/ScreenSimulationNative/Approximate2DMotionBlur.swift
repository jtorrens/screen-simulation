import CoreGraphics
import Foundation

enum Approximate2DMotionBlurError: Error {
    case invalidInput
}

/// Deterministic post-Delivery approximation. RGB and matte are filtered as four
/// independent linear channels; RGB is never associated with alpha.
enum Approximate2DMotionBlur {
    static func apply(
        to rgba: [Float],
        width: Int,
        height: Int,
        shutterStart: CGPoint,
        shutterEnd: CGPoint,
        samples: UInt16
    ) throws -> [Float] {
        guard width > 0, height > 0, rgba.count == width * height * 4,
              rgba.allSatisfy(\.isFinite), shutterStart.x.isFinite,
              shutterStart.y.isFinite, shutterEnd.x.isFinite,
              shutterEnd.y.isFinite, (2 ... 64).contains(samples)
        else { throw Approximate2DMotionBlurError.invalidInput }

        let dx = Float(shutterEnd.x - shutterStart.x)
        let dy = Float(shutterEnd.y - shutterStart.y)
        guard dx.isFinite, dy.isFinite else {
            throw Approximate2DMotionBlurError.invalidInput
        }
        if abs(dx) < 1e-6, abs(dy) < 1e-6 { return rgba }

        var output = [Float](repeating: 0, count: rgba.count)
        let count = Int(samples)
        let weight = 1 / Float(count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let outputOffset = (y * width + x) * 4
                for sample in 0 ..< count {
                    let phase = (Float(sample) + 0.5) / Float(count) - 0.5
                    let value = bilinear(
                        rgba, width: width, height: height,
                        x: Float(x) - dx * phase,
                        y: Float(y) - dy * phase
                    )
                    output[outputOffset] += value.x * weight
                    output[outputOffset + 1] += value.y * weight
                    output[outputOffset + 2] += value.z * weight
                    output[outputOffset + 3] += value.w * weight
                }
                output[outputOffset + 3] = min(1, max(0, output[outputOffset + 3]))
            }
        }
        guard output.allSatisfy(\.isFinite) else {
            throw Approximate2DMotionBlurError.invalidInput
        }
        return output
    }

    private static func bilinear(
        _ rgba: [Float], width: Int, height: Int, x: Float, y: Float
    ) -> SIMD4<Float> {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let tx = x - Float(x0)
        let ty = y - Float(y0)
        let a = sample(rgba, width: width, height: height, x: x0, y: y0)
        let b = sample(rgba, width: width, height: height, x: x0 + 1, y: y0)
        let c = sample(rgba, width: width, height: height, x: x0, y: y0 + 1)
        let d = sample(rgba, width: width, height: height, x: x0 + 1, y: y0 + 1)
        let top = a + (b - a) * tx
        let bottom = c + (d - c) * tx
        return top + (bottom - top) * ty
    }

    private static func sample(
        _ rgba: [Float], width: Int, height: Int, x: Int, y: Int
    ) -> SIMD4<Float> {
        guard x >= 0, x < width, y >= 0, y < height else { return .zero }
        let offset = (y * width + x) * 4
        return SIMD4(rgba[offset], rgba[offset + 1], rgba[offset + 2], rgba[offset + 3])
    }
}
