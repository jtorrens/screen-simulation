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

    /// Keeps the tracked camera/world fixed while reproducing on the Device
    /// the same relative transform that a camera-navigation gesture requested.
    static func equivalentDevicePose(
        startCamera: CameraNavigationPose,
        movedCamera: CameraNavigationPose,
        startDevice: CameraNavigationPose
    ) -> CameraNavigationPose {
        let worldRotation = simd_normalize(
            startCamera.orientation * movedCamera.orientation.inverse
        )
        return CameraNavigationPose(
            position: startCamera.position + worldRotation.act(
                startDevice.position - movedCamera.position
            ),
            orientation: simd_normalize(worldRotation * startDevice.orientation)
        )
    }
}

enum EnvironmentNavigationMath {
    static func translatedCenter(
        start: SIMD3<Double>,
        radius: Double,
        cameraRight: SIMD3<Double>,
        cameraUp: SIMD3<Double>,
        viewportSize: CGSize,
        verticalFovRadians: Double,
        delta: CGSize
    ) -> SIMD3<Double> {
        let height = max(1, Double(viewportSize.height))
        let width = max(1, Double(viewportSize.width))
        let visibleHeight = 2 * radius * tan(verticalFovRadians * 0.5)
        let horizontalFov = 2 * atan(tan(verticalFovRadians * 0.5) * width / height)
        let visibleWidth = 2 * radius * tan(horizontalFov * 0.5)
        return start
            + cameraRight * (Double(delta.width) * visibleWidth / width)
            + cameraUp * (-Double(delta.height) * visibleHeight / height)
    }

    static func rotations(
        startX: Double,
        startY: Double,
        lockedAxis: inout CameraNavigationLockedAxis?,
        delta: CGSize
    ) -> (x: Double, y: Double) {
        if lockedAxis == nil,
           hypot(delta.width, delta.height) >= CameraNavigationMath.orbitLockThresholdPixels {
            lockedAxis = abs(delta.width) >= abs(delta.height) ? .horizontal : .vertical
        }
        switch lockedAxis {
        case .horizontal:
            return (startX, min(180, max(-180, startY - Double(delta.width) * 0.2)))
        case .vertical:
            return (min(90, max(-90, startX + Double(delta.height) * 0.2)), startY)
        case nil:
            return (startX, startY)
        }
    }

    static func scaledRadius(start: Double, deltaPixels: Double) -> Double {
        start * exp(deltaPixels * CameraNavigationMath.dollyExponentPerPixel)
    }
}

enum ReferenceAnchorCameraMath {
    /// Converts a pixel from the rendered, distorted camera gate into the
    /// equivalent pinhole pixel consumed by the planar pose solver.
    static func undistortedPinholePixel(
        _ pixel: CGPoint,
        imageSize: CGSize,
        lensShift: SIMD2<Double>,
        radialDistortion: SIMD3<Double>,
        tangentialDistortion: SIMD2<Double>
    ) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let observed = SIMD2<Double>(
            2 * (Double(pixel.x) + 0.5) / imageSize.width - 1,
            2 * (Double(pixel.y) + 0.5) / imageSize.height - 1
        )
        guard let ideal = inverseDistortion(
            SIMD2(observed.x + 2 * lensShift.x, -observed.y - 2 * lensShift.y),
            radial: radialDistortion, tangential: tangentialDistortion
        ) else { return nil }
        let pinholeObserved = SIMD2(
            ideal.x - 2 * lensShift.x,
            -ideal.y - 2 * lensShift.y
        )
        return CGPoint(
            x: (pinholeObserved.x + 1) * 0.5 * imageSize.width - 0.5,
            y: (pinholeObserved.y + 1) * 0.5 * imageSize.height - 0.5
        )
    }

    static func poseKeepingAnchor(
        startPose: CameraNavigationPose,
        anchorWorld: SIMD3<Double>,
        movingWorld: SIMD3<Double>,
        anchorTargetPixel: CGPoint,
        movingTargetPixel: CGPoint,
        imageSize: CGSize,
        focalLengthMillimeters: Double,
        sensorSizeMillimeters: CGSize,
        lensShift: SIMD2<Double>,
        radialDistortion: SIMD3<Double>,
        tangentialDistortion: SIMD2<Double>
    ) -> CameraNavigationPose? {
        guard let anchorRay = cameraRay(
            pixel: anchorTargetPixel, imageSize: imageSize,
            focalLengthMillimeters: focalLengthMillimeters,
            sensorSizeMillimeters: sensorSizeMillimeters, lensShift: lensShift,
            radialDistortion: radialDistortion, tangentialDistortion: tangentialDistortion
        ), let movingRay = cameraRay(
            pixel: movingTargetPixel, imageSize: imageSize,
            focalLengthMillimeters: focalLengthMillimeters,
            sensorSizeMillimeters: sensorSizeMillimeters, lensShift: lensShift,
            radialDistortion: radialDistortion, tangentialDistortion: tangentialDistortion
        ) else { return nil }
        let forward = startPose.orientation.act(SIMD3<Double>(0, 0, -1))
        let anchorDepth = simd_dot(anchorWorld - startPose.position, forward)
        let movingDepth = simd_dot(movingWorld - startPose.position, forward)
        guard anchorDepth > 0, movingDepth > 0 else { return nil }

        // |d₂ r₂ - d₁ r₁| must equal the invariant 3D corner separation.
        // The positive root nearest the current depth selects the continuous solution.
        let separation = movingWorld - anchorWorld
        let a = simd_dot(movingRay, movingRay)
        let b = -2 * anchorDepth * simd_dot(movingRay, anchorRay)
        let c = anchorDepth * anchorDepth * simd_dot(anchorRay, anchorRay)
            - simd_dot(separation, separation)
        let discriminant = b * b - 4 * a * c
        guard a > 0, discriminant >= 0 else { return nil }
        let root = sqrt(discriminant)
        let candidates = [(-b - root) / (2 * a), (-b + root) / (2 * a)]
            .filter { $0 > 0 && $0.isFinite }
        guard let selectedDepth = candidates.min(by: {
            abs($0 - movingDepth) < abs($1 - movingDepth)
        }) else { return nil }
        let localSeparation = movingRay * selectedDepth - anchorRay * anchorDepth
        guard simd_length_squared(localSeparation) > 1e-18,
              simd_length_squared(separation) > 1e-18
        else { return nil }
        let currentWorldSeparation = startPose.orientation.act(localSeparation)
        let correction = simd_quatd(
            from: simd_normalize(currentWorldSeparation),
            to: simd_normalize(separation)
        )
        let orientation = simd_normalize(correction * startPose.orientation)
        let position = anchorWorld - orientation.act(anchorRay * anchorDepth)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
        return CameraNavigationPose(position: position, orientation: orientation)
    }

    static func translatedPose(
        startPose: CameraNavigationPose,
        anchorWorld: SIMD3<Double>,
        targetPixel: CGPoint,
        imageSize: CGSize,
        focalLengthMillimeters: Double,
        sensorSizeMillimeters: CGSize,
        lensShift: SIMD2<Double>,
        radialDistortion: SIMD3<Double>,
        tangentialDistortion: SIMD2<Double>
    ) -> CameraNavigationPose? {
        guard imageSize.width > 0, imageSize.height > 0,
              focalLengthMillimeters > 0,
              sensorSizeMillimeters.width > 0, sensorSizeMillimeters.height > 0
        else { return nil }
        let right = startPose.orientation.act(SIMD3<Double>(1, 0, 0))
        let up = startPose.orientation.act(SIMD3<Double>(0, 1, 0))
        let forward = startPose.orientation.act(SIMD3<Double>(0, 0, -1))
        let depth = simd_dot(anchorWorld - startPose.position, forward)
        guard depth > 0, depth.isFinite else { return nil }

        let observed = SIMD2<Double>(
            2 * (Double(targetPixel.x) + 0.5) / imageSize.width - 1,
            2 * (Double(targetPixel.y) + 0.5) / imageSize.height - 1
        )
        let distorted = SIMD2<Double>(
            observed.x + 2 * lensShift.x,
            -observed.y - 2 * lensShift.y
        )
        guard let ideal = inverseDistortion(
            distorted, radial: radialDistortion, tangential: tangentialDistortion
        ) else { return nil }
        let relative = forward * depth
            + right * (depth * ideal.x * sensorSizeMillimeters.width
                / (2 * focalLengthMillimeters))
            + up * (depth * ideal.y * sensorSizeMillimeters.height
                / (2 * focalLengthMillimeters))
        let position = anchorWorld - relative
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
        return CameraNavigationPose(position: position, orientation: startPose.orientation)
    }

    static func project(
        pose: CameraNavigationPose,
        point: SIMD3<Double>,
        imageSize: CGSize,
        focalLengthMillimeters: Double,
        sensorSizeMillimeters: CGSize,
        lensShift: SIMD2<Double>,
        radialDistortion: SIMD3<Double>,
        tangentialDistortion: SIMD2<Double>
    ) -> CGPoint? {
        let right = pose.orientation.act(SIMD3<Double>(1, 0, 0))
        let up = pose.orientation.act(SIMD3<Double>(0, 1, 0))
        let forward = pose.orientation.act(SIMD3<Double>(0, 0, -1))
        let relative = point - pose.position
        let depth = simd_dot(relative, forward)
        guard depth > 0 else { return nil }
        let ideal = SIMD2<Double>(
            simd_dot(relative, right) / depth * 2 * focalLengthMillimeters
                / sensorSizeMillimeters.width,
            simd_dot(relative, up) / depth * 2 * focalLengthMillimeters
                / sensorSizeMillimeters.height
        )
        let distorted = distort(
            ideal, radial: radialDistortion, tangential: tangentialDistortion
        )
        let observed = SIMD2<Double>(
            distorted.x - 2 * lensShift.x,
            -distorted.y - 2 * lensShift.y
        )
        return CGPoint(
            x: (observed.x + 1) * 0.5 * imageSize.width - 0.5,
            y: (observed.y + 1) * 0.5 * imageSize.height - 0.5
        )
    }

    private static func distort(
        _ point: SIMD2<Double>,
        radial: SIMD3<Double>,
        tangential: SIMD2<Double>
    ) -> SIMD2<Double> {
        let r2 = simd_dot(point, point)
        let scale = 1 + radial.x * r2 + radial.y * r2 * r2 + radial.z * r2 * r2 * r2
        return point * scale + SIMD2(
            2 * tangential.x * point.x * point.y
                + tangential.y * (r2 + 2 * point.x * point.x),
            tangential.x * (r2 + 2 * point.y * point.y)
                + 2 * tangential.y * point.x * point.y
        )
    }

    private static func inverseDistortion(
        _ observed: SIMD2<Double>,
        radial: SIMD3<Double>,
        tangential: SIMD2<Double>
    ) -> SIMD2<Double>? {
        var ideal = observed
        for _ in 0..<12 {
            let residual = distort(ideal, radial: radial, tangential: tangential) - observed
            if max(abs(residual.x), abs(residual.y)) < 1e-10 { break }
            let epsilon = 1e-5
            let dx = (distort(
                ideal + SIMD2(epsilon, 0), radial: radial, tangential: tangential
            ) - distort(
                ideal - SIMD2(epsilon, 0), radial: radial, tangential: tangential
            )) / (2 * epsilon)
            let dy = (distort(
                ideal + SIMD2(0, epsilon), radial: radial, tangential: tangential
            ) - distort(
                ideal - SIMD2(0, epsilon), radial: radial, tangential: tangential
            )) / (2 * epsilon)
            let determinant = dx.x * dy.y - dy.x * dx.y
            guard abs(determinant) > 1e-14 else { return nil }
            ideal -= SIMD2(
                (dy.y * residual.x - dy.x * residual.y) / determinant,
                (-dx.y * residual.x + dx.x * residual.y) / determinant
            )
        }
        let residual = distort(ideal, radial: radial, tangential: tangential) - observed
        guard ideal.x.isFinite, ideal.y.isFinite,
              max(abs(residual.x), abs(residual.y)) < 2e-7
        else { return nil }
        return ideal
    }

    private static func cameraRay(
        pixel: CGPoint,
        imageSize: CGSize,
        focalLengthMillimeters: Double,
        sensorSizeMillimeters: CGSize,
        lensShift: SIMD2<Double>,
        radialDistortion: SIMD3<Double>,
        tangentialDistortion: SIMD2<Double>
    ) -> SIMD3<Double>? {
        guard imageSize.width > 0, imageSize.height > 0,
              focalLengthMillimeters > 0,
              sensorSizeMillimeters.width > 0, sensorSizeMillimeters.height > 0
        else { return nil }
        let observed = SIMD2<Double>(
            2 * (Double(pixel.x) + 0.5) / imageSize.width - 1,
            2 * (Double(pixel.y) + 0.5) / imageSize.height - 1
        )
        guard let ideal = inverseDistortion(
            SIMD2(observed.x + 2 * lensShift.x, -observed.y - 2 * lensShift.y),
            radial: radialDistortion, tangential: tangentialDistortion
        ) else { return nil }
        return SIMD3(
            ideal.x * sensorSizeMillimeters.width / (2 * focalLengthMillimeters),
            ideal.y * sensorSizeMillimeters.height / (2 * focalLengthMillimeters),
            -1
        )
    }
}
