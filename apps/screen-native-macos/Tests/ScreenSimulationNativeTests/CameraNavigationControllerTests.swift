import Foundation
import simd
import Testing
@testable import ScreenSimulationNative

@Test func referenceAnchorTranslationIsExactAndPreservesOpticalDepth() throws {
    let orientation = simd_quatd(angle: 0.14, axis: simd_normalize(SIMD3(0.2, 1, 0.1)))
    let start = CameraNavigationPose(position: SIMD3(0.1, -0.04, 1.2), orientation: orientation)
    let anchor = SIMD3<Double>(-0.35, 0.2, 0)
    let target = CGPoint(x: 3_100.25, y: 920.75)
    let image = CGSize(width: 4_032, height: 3_024)
    let sensor = CGSize(width: 36, height: 24)
    let shift = SIMD2<Double>(0.03, -0.02)
    let radial = SIMD3<Double>(-0.08, 0.015, -0.002)
    let tangential = SIMD2<Double>(0.001, -0.0007)
    let pose = try #require(ReferenceAnchorCameraMath.translatedPose(
        startPose: start, anchorWorld: anchor, targetPixel: target,
        imageSize: image, focalLengthMillimeters: 50,
        sensorSizeMillimeters: sensor, lensShift: shift,
        radialDistortion: radial, tangentialDistortion: tangential
    ))
    let projected = try #require(ReferenceAnchorCameraMath.project(
        pose: pose, point: anchor, imageSize: image,
        focalLengthMillimeters: 50, sensorSizeMillimeters: sensor,
        lensShift: shift, radialDistortion: radial,
        tangentialDistortion: tangential
    ))
    let forward = start.orientation.act(SIMD3<Double>(0, 0, -1))
    #expect(abs(projected.x - target.x) < 0.000_001)
    #expect(abs(projected.y - target.y) < 0.000_001)
    #expect(abs(simd_dot(anchor - start.position, forward)
        - simd_dot(anchor - pose.position, forward)) < 0.000_000_001)
    #expect(pose.orientation == start.orientation)
}

@Test func secondReferenceCornerRotatesCameraWhileKeepingAnchorExact() throws {
    let start = CameraNavigationPose(
        position: SIMD3<Double>(0.05, -0.02, 1.4),
        orientation: simd_quatd(angle: 0.08, axis: SIMD3(0, 1, 0))
    )
    let anchor = SIMD3<Double>(-0.35, 0.2, 0)
    let moving = SIMD3<Double>(0.35, 0.2, 0)
    let image = CGSize(width: 4_032, height: 3_024)
    let sensor = CGSize(width: 36, height: 24)
    let shift = SIMD2<Double>(0.01, -0.015)
    let radial = SIMD3<Double>(-0.04, 0.006, 0)
    let tangential = SIMD2<Double>(0.0004, -0.0002)
    let anchorTarget = CGPoint(x: 1_020.25, y: 910.5)
    let movingTarget = CGPoint(x: 3_120.75, y: 1_040.25)
    let pose = try #require(ReferenceAnchorCameraMath.poseKeepingAnchor(
        startPose: start, anchorWorld: anchor, movingWorld: moving,
        anchorTargetPixel: anchorTarget, movingTargetPixel: movingTarget,
        imageSize: image, focalLengthMillimeters: 50,
        sensorSizeMillimeters: sensor, lensShift: shift,
        radialDistortion: radial, tangentialDistortion: tangential
    ))
    let projectedAnchor = try #require(ReferenceAnchorCameraMath.project(
        pose: pose, point: anchor, imageSize: image, focalLengthMillimeters: 50,
        sensorSizeMillimeters: sensor, lensShift: shift,
        radialDistortion: radial, tangentialDistortion: tangential
    ))
    let projectedMoving = try #require(ReferenceAnchorCameraMath.project(
        pose: pose, point: moving, imageSize: image, focalLengthMillimeters: 50,
        sensorSizeMillimeters: sensor, lensShift: shift,
        radialDistortion: radial, tangentialDistortion: tangential
    ))
    #expect(hypot(projectedAnchor.x - anchorTarget.x,
                  projectedAnchor.y - anchorTarget.y) < 0.000_001)
    #expect(hypot(projectedMoving.x - movingTarget.x,
                  projectedMoving.y - movingTarget.y) < 0.000_001)
    #expect(pose.orientation != start.orientation)
}

@Test func distortedReferenceTargetConvertsToTheEquivalentPinholePixel() throws {
    let image = CGSize(width: 4_032, height: 3_024)
    let sensor = CGSize(width: 36, height: 24)
    let shift = SIMD2<Double>(0.03, -0.02)
    let radial = SIMD3<Double>(-0.08, 0.015, -0.002)
    let tangential = SIMD2<Double>(0.001, -0.0007)
    let pose = CameraNavigationPose(
        position: SIMD3<Double>(0, 0, 1),
        orientation: simd_quatd(real: 1, imag: .zero)
    )
    let point = SIMD3<Double>(0.31, -0.17, 0)
    let distorted = try #require(ReferenceAnchorCameraMath.project(
        pose: pose, point: point, imageSize: image,
        focalLengthMillimeters: 50, sensorSizeMillimeters: sensor,
        lensShift: shift, radialDistortion: radial, tangentialDistortion: tangential
    ))
    let converted = try #require(ReferenceAnchorCameraMath.undistortedPinholePixel(
        distorted, imageSize: image, lensShift: shift,
        radialDistortion: radial, tangentialDistortion: tangential
    ))
    let pinhole = try #require(ReferenceAnchorCameraMath.project(
        pose: pose, point: point, imageSize: image,
        focalLengthMillimeters: 50, sensorSizeMillimeters: sensor,
        lensShift: shift, radialDistortion: .zero, tangentialDistortion: .zero
    ))
    #expect(hypot(converted.x - pinhole.x, converted.y - pinhole.y) < 0.000_001)
}

@Test func referenceAndCameraGateMappingsAreExactInverses() throws {
    let points = [
        CGPoint(x: 100.25, y: 200.75), CGPoint(x: 1_500.5, y: 800.125),
    ]
    for placement in ["fit", "fill-crop", "one-to-one"] {
        let gate = try ReferenceMatchRasterMapping.cameraGateCorners(
            points, referenceWidth: 1_920, referenceHeight: 1_080,
            cameraWidth: 4_032, cameraHeight: 3_024,
            deliveryPlacementID: placement
        )
        let recovered = try ReferenceMatchRasterMapping.referenceCorners(
            gate, referenceWidth: 1_920, referenceHeight: 1_080,
            cameraWidth: 4_032, cameraHeight: 3_024,
            deliveryPlacementID: placement
        )
        for (actual, expected) in zip(recovered, points) {
            #expect(abs(actual.x - expected.x) < 0.000_001)
            #expect(abs(actual.y - expected.y) < 0.000_001)
        }
    }
}

@Test @MainActor func initialReferenceTargetsAlwaysRemainInsideTheVisibleRaster() {
    for size in [(32, 18), (1_920, 1_080), (5_712, 4_284)] {
        let targets = WorkspaceModel.initialReferenceMatchTargets(
            width: size.0, height: size.1
        )
        #expect(targets.count == 4)
        #expect(targets.allSatisfy {
            $0.x >= -0.5 && $0.x < CGFloat(size.0) - 0.5
                && $0.y >= -0.5 && $0.y < CGFloat(size.1) - 0.5
        })
    }
}

@Test @MainActor func workspaceNavigationPublishesSetupWithoutPresentationFailure() throws {
    let workspace = WorkspaceModel()
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    workspace.selectModelDevice(device, coverGlass: cover)

    workspace.beginCameraNavigation(.pan, viewportSize: CGSize(width: 1_200, height: 800))
    workspace.updateCameraNavigation(delta: CGSize(width: 180, height: -70))
    workspace.endCameraNavigation(undoManager: nil)

    #expect(workspace.errorMessage == nil)
    #expect(workspace.physicalModel.quality == .setup)
}

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
    #expect(nearDelta < 0)
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
    #expect(horizontalPose.position.x < 0)

    var vertical = navigationGesture(distance: 2, operation: .orbit)
    let verticalPose = CameraNavigationMath.orbit(
        gesture: &vertical, delta: CGSize(width: 20, height: 100)
    )
    #expect(vertical.lockedAxis == .vertical)
    #expect(abs(simd_length(verticalPose.position) - 2) < 1e-10)
    #expect(abs(verticalPose.position.x) < 1e-10)
    #expect(verticalPose.position.y > 0)
}

@Test func environmentNavigationFollowsCameraConventionsAndLocksOrbitAxis() {
    let center = EnvironmentNavigationMath.translatedCenter(
        start: .zero,
        radius: 5,
        cameraRight: [1, 0, 0],
        cameraUp: [0, 1, 0],
        viewportSize: CGSize(width: 1_920, height: 1_080),
        verticalFovRadians: 45 * .pi / 180,
        delta: CGSize(width: 100, height: -50)
    )
    #expect(center.x > 0)
    #expect(center.y > 0)

    var axis: CameraNavigationLockedAxis?
    let horizontal = EnvironmentNavigationMath.rotations(
        startX: 4, startY: 8, lockedAxis: &axis,
        delta: CGSize(width: 100, height: 20)
    )
    #expect(axis == .horizontal)
    #expect(horizontal.x == 4)
    #expect(horizontal.y < 8)
    let stillHorizontal = EnvironmentNavigationMath.rotations(
        startX: 4, startY: 8, lockedAxis: &axis,
        delta: CGSize(width: 20, height: 100)
    )
    #expect(stillHorizontal.x == 4)
    #expect(EnvironmentNavigationMath.scaledRadius(start: 5, deltaPixels: 100) > 5)
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
@Test func trackedCameraNavigationMovesOnlyTheDeviceRelativeToTheFixedWorld() {
    let camera = CameraNavigationPose(
        position: SIMD3(1, 2, 5),
        orientation: simd_quatd(angle: 0.2, axis: simd_normalize(SIMD3(0, 1, 0)))
    )
    let movedCamera = CameraNavigationPose(
        position: SIMD3(1.4, 1.8, 4.2),
        orientation: simd_quatd(angle: -0.15, axis: simd_normalize(SIMD3(0, 1, 0))) * camera.orientation
    )
    let device = CameraNavigationPose(
        position: SIMD3(0.2, -0.1, 0),
        orientation: simd_quatd(angle: 0.1, axis: simd_normalize(SIMD3(1, 0, 0)))
    )
    let movedDevice = CameraNavigationMath.equivalentDevicePose(
        startCamera: camera, movedCamera: movedCamera, startDevice: device
    )
    let devicePoint = SIMD3(0.3, 0.2, 0.0)
    let originalWorld = device.position + device.orientation.act(devicePoint)
    let movedWorld = movedDevice.position + movedDevice.orientation.act(devicePoint)
    let viewedByMovedCamera = movedCamera.orientation.inverse.act(originalWorld - movedCamera.position)
    let viewedByFixedCamera = camera.orientation.inverse.act(movedWorld - camera.position)
    #expect(simd_length(viewedByMovedCamera - viewedByFixedCamera) < 1e-12)
}
