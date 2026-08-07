import Foundation

/// UI-only projection of the canonical XYZW quaternion. Rotations are applied
/// X, then Y, then Z. Persistence and physical evaluation remain quaternion based.
enum PoseRotationProjection {
    static func quaternionLooking(from: [Double], to: [Double]) -> [Double] {
        let d = zip(to, from).map { $0 - $1 }.normalized3
        guard d.length3 > 1e-12 else { return [0, 0, 0, 1] }
        let dot = -d[2]
        if dot < -0.999_999 { return [0, 1, 0, 0] }
        return [d[1], -d[0], 0, 1 + dot].normalized4
    }

    static func forwardDirection(from quaternion: [Double]) -> [Double] {
        let q = quaternion.normalized4
        let x = q[0], y = q[1], z = q[2], w = q[3]
        return [
            -2 * (x * z + w * y),
            -2 * (y * z - w * x),
            -(1 - 2 * (x * x + y * y)),
        ]
    }

    static func target(from position: [Double], quaternion: [Double], distance: Double) -> [Double] {
        zip(position, forwardDirection(from: quaternion)).map { $0 + $1 * max(distance, 0.001) }
    }
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

    static func distance(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).prefix(3).reduce(0) { partial, pair in
            let delta = pair.0 - pair.1
            return partial + delta * delta
        }.squareRoot()
    }
}

private extension Array where Element == Double {
    var length3: Double { sqrt(prefix(3).reduce(0) { $0 + $1 * $1 }) }
    var normalized3: [Double] { let l = length3; return l > 0 ? prefix(3).map { $0 / l } : [0, 0, -1] }
    var normalized4: [Double] { let l = sqrt(reduce(0) { $0 + $1 * $1 }); return l > 0 ? map { $0 / l } : [0, 0, 0, 1] }
}
