import Foundation

/// UI-only projection of the canonical XYZW quaternion. Rotations are applied
/// X, then Y, then Z. Persistence and physical evaluation remain quaternion based.
enum PoseRotationProjection {
    static func degrees(from quaternion: [Double]) -> [Double] {
        precondition(quaternion.count == 4)
        let length = sqrt(quaternion.reduce(0) { $0 + $1 * $1 })
        guard length > 0 else { return [0, 0, 0] }
        let x = quaternion[0] / length
        let y = quaternion[1] / length
        let z = quaternion[2] / length
        let w = quaternion[3] / length
        let rotationX = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        let sinY = min(1, max(-1, 2 * (w * y - z * x)))
        let rotationY = asin(sinY)
        let rotationZ = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        return [rotationX, rotationY, rotationZ].map { $0 * 180 / .pi }
    }

    static func quaternion(fromDegrees degrees: [Double]) -> [Double] {
        precondition(degrees.count == 3)
        let halfX = degrees[0] * .pi / 360
        let halfY = degrees[1] * .pi / 360
        let halfZ = degrees[2] * .pi / 360
        let sx = sin(halfX), cx = cos(halfX)
        let sy = sin(halfY), cy = cos(halfY)
        let sz = sin(halfZ), cz = cos(halfZ)
        return [
            sx * cy * cz - cx * sy * sz,
            cx * sy * cz + sx * cy * sz,
            cx * cy * sz - sx * sy * cz,
            cx * cy * cz + sx * sy * sz,
        ]
    }
}
