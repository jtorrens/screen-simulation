import Foundation
import simd

struct CameraNavigationPose: Equatable, Sendable {
    var position: SIMD3<Double>
    var orientation: simd_quatd
}

struct CameraNavigationGeometry: Equatable, Sendable {
    let center: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>
    let halfWidth: Double
    let halfHeight: Double

    var corners: [SIMD3<Double>] {
        [
            center - right * halfWidth + up * halfHeight,
            center + right * halfWidth + up * halfHeight,
            center + right * halfWidth - up * halfHeight,
            center - right * halfWidth - up * halfHeight,
        ]
    }
}

enum CameraNavigationOperation: Equatable, Sendable {
    case pan
    case orbit
    case dolly
}

enum CameraNavigationLockedAxis: Equatable, Sendable { case horizontal, vertical }

struct CameraNavigationGesture: Sendable {
    let operation: CameraNavigationOperation
    let startPose: CameraNavigationPose
    let geometry: CameraNavigationGeometry
    let viewportSize: CGSize
    let verticalFovRadians: Double
    let nearClipMeters: Double
    var lockedAxis: CameraNavigationLockedAxis?
}

enum CameraNavigationMath {
    static let orbitRadiansPerPixel = 0.2 * Double.pi / 180
    static let dollyExponentPerPixel = 0.008
    static let orbitLockThresholdPixels = 3.0

    static func pan(
        gesture: CameraNavigationGesture, delta: CGSize
    ) -> CameraNavigationPose {
        let forward = gesture.startPose.orientation.act(SIMD3<Double>(0, 0, -1))
        let right = gesture.startPose.orientation.act(SIMD3<Double>(1, 0, 0))
        let up = gesture.startPose.orientation.act(SIMD3<Double>(0, 1, 0))
        let opticalDepth = max(
            gesture.nearClipMeters * 2,
            simd_dot(gesture.geometry.center - gesture.startPose.position, forward)
        )
        let height = max(1, Double(gesture.viewportSize.height))
        let width = max(1, Double(gesture.viewportSize.width))
        let visibleHeight = 2 * opticalDepth * tan(gesture.verticalFovRadians * 0.5)
        let horizontalFov = 2 * atan(tan(gesture.verticalFovRadians * 0.5) * width / height)
        let visibleWidth = 2 * opticalDepth * tan(horizontalFov * 0.5)
        // Viewer navigation follows the projected Device under the cursor:
        // moving the camera itself uses the opposite world-space direction.
        let movement = right * (-Double(delta.width) * visibleWidth / width)
            + up * (-Double(delta.height) * visibleHeight / height)
        return .init(
            position: gesture.startPose.position + movement,
            orientation: gesture.startPose.orientation
        )
    }

    static func orbit(
        gesture: inout CameraNavigationGesture, delta: CGSize
    ) -> CameraNavigationPose {
        if gesture.lockedAxis == nil,
           hypot(delta.width, delta.height) >= orbitLockThresholdPixels {
            gesture.lockedAxis = abs(delta.width) >= abs(delta.height) ? .horizontal : .vertical
        }
        guard let axis = gesture.lockedAxis else { return gesture.startPose }
        let deviceAxis = axis == .horizontal ? gesture.geometry.up : gesture.geometry.right
        let pixels = axis == .horizontal ? Double(delta.width) : Double(delta.height)
        let angle = -pixels * orbitRadiansPerPixel
        let rotation = simd_quatd(angle: angle, axis: simd_normalize(deviceAxis))
        let offset = gesture.startPose.position - gesture.geometry.center
        return .init(
            position: gesture.geometry.center + rotation.act(offset),
            orientation: simd_normalize(rotation * gesture.startPose.orientation)
        )
    }

    static func dolly(
        gesture: CameraNavigationGesture, deltaPixels: Double
    ) -> CameraNavigationPose {
        let forward = gesture.startPose.orientation.act(SIMD3<Double>(0, 0, -1))
        let currentDepths = gesture.geometry.corners.map {
            simd_dot($0 - gesture.startPose.position, forward)
        }
        let currentNearest = currentDepths.min() ?? gesture.nearClipMeters * 2
        let centerDepth = simd_dot(
            gesture.geometry.center - gesture.startPose.position, forward
        )
        let desiredDepth = max(
            gesture.nearClipMeters * 2,
            centerDepth * exp(deltaPixels * dollyExponentPerPixel)
        )
        var movement = centerDepth - desiredDepth
        let maximumForward = currentNearest - gesture.nearClipMeters * 1.5
        movement = min(movement, maximumForward)
        return .init(
            position: gesture.startPose.position + forward * movement,
            orientation: gesture.startPose.orientation
        )
    }
}
