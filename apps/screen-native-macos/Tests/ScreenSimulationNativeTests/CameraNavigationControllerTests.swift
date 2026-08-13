import Foundation
import simd
import Testing
@testable import ScreenSimulationNative

private func navigationGesture(
    distance: Double,
    operation: CameraNavigationOperation = .pan,
    center: SIMD3<Double> = .zero
) -> CameraNavigationGesture {
    .init(
        operation: operation,
        startPose: .init(
            position: [0, 0, distance],
            orientation: simd_quatd(real: 1, imag: .zero)
        ),
        geometry: .init(
            center: center, right: [1, 0, 0], up: [0, 1, 0],
            halfWidth: 0.35, halfHeight: 0.2
        ),
        viewportSize: CGSize(width: 1_920, height: 1_080),
        verticalFovRadians: 45 * .pi / 180,
        nearClipMeters: 0.01,
        lockedAxis: nil
    )
}

@Test func panScalesInWorldWhileRemainingConstantInProjection() {
    let near = navigationGesture(distance: 1)
    let far = navigationGesture(distance: 10)
    let drag = CGSize(width: 100, height: 0)
    let nearPose = CameraNavigationMath.pan(gesture: near, delta: drag)
    let farPose = CameraNavigationMath.pan(gesture: far, delta: drag)
    let nearDelta = nearPose.position.x - near.startPose.position.x
    let farDelta = farPose.position.x - far.startPose.position.x
    #expect(abs(farDelta / nearDelta - 10) < 1e-10)
    #expect(abs(nearDelta / 1 - farDelta / 10) < 1e-10)
}

@Test func dollyIsProportionalAndNeverCrossesTheDevicePlane() {
    let near = navigationGesture(distance: 1, operation: .dolly)
    let far = navigationGesture(distance: 10, operation: .dolly)
    let nearPose = CameraNavigationMath.dolly(gesture: near, deltaPixels: -50)
    let farPose = CameraNavigationMath.dolly(gesture: far, deltaPixels: -50)
    #expect(abs(farPose.position.z / nearPose.position.z - 10) < 1e-9)
    let extreme = CameraNavigationMath.dolly(gesture: near, deltaPixels: -100_000)
    #expect(extreme.position.z > near.nearClipMeters)
}

@Test func orbitLocksOneDeviceAxisAndPreservesDistance() {
    var horizontal = navigationGesture(distance: 2, operation: .orbit)
    let horizontalPose = CameraNavigationMath.orbit(
        gesture: &horizontal, delta: CGSize(width: 100, height: 20)
    )
    #expect(horizontal.lockedAxis == .horizontal)
    #expect(abs(simd_length(horizontalPose.position) - 2) < 1e-10)
    #expect(abs(horizontalPose.position.y) < 1e-10)

    var vertical = navigationGesture(distance: 2, operation: .orbit)
    let verticalPose = CameraNavigationMath.orbit(
        gesture: &vertical, delta: CGSize(width: 20, height: 100)
    )
    #expect(vertical.lockedAxis == .vertical)
    #expect(abs(simd_length(verticalPose.position) - 2) < 1e-10)
    #expect(abs(verticalPose.position.x) < 1e-10)
}

@Test func deviceGeometryExposesRigidWorldCornersWithoutMutation() {
    let geometry = CameraNavigationGeometry(
        center: [3, 2, 1], right: [0, 0, -1], up: [0, 1, 0],
        halfWidth: 2, halfHeight: 1
    )
    let before = geometry
    #expect(geometry.corners == [
        [3, 3, 3], [3, 3, -1], [3, 1, -1], [3, 1, 3],
    ])
    _ = CameraNavigationMath.pan(
        gesture: navigationGesture(distance: 5, center: geometry.center),
        delta: CGSize(width: 50, height: 20)
    )
    #expect(geometry == before)
}

@Test func cameraPoseAcceptsAnExternalProgrammaticPose() {
    let pose = CameraNavigationPose(
        position: [1, 2, 3],
        orientation: simd_quatd(angle: 0.4, axis: simd_normalize([1, 2, 3]))
    )
    #expect(pose.position == [1, 2, 3])
    #expect(abs(pose.orientation.length - 1) < 1e-12)
}
