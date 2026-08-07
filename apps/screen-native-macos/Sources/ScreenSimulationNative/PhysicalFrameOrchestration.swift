import Foundation
import ScreenPhysicalBridge

struct PhysicalVector3: Equatable, Sendable {
    let x: Float
    let y: Float
    let z: Float
}

struct PhysicalQuaternion: Equatable, Sendable {
    let x: Float
    let y: Float
    let z: Float
    let w: Float

    static let identity = Self(x: 0, y: 0, z: 0, w: 1)
}

struct PhysicalPoseSnapshot: Equatable, Sendable {
    let position: PhysicalVector3
    let rotation: PhysicalQuaternion
}

/// Host-owned temporal description. The current UI supplies one exact sample
/// and constant pose snapshots. A future timeline can expand this value to
/// ordered samples and pose knots without changing the physical ABI or engine.
struct PhysicalFrameOrchestration: Equatable, Sendable {
    let frame: PhysicalFrameSelection
    let shutter: PhysicalShutterInterval
    let cameraPose: PhysicalPoseSnapshot
    let screenPose: PhysicalPoseSnapshot
    let isStaticInput: Bool

    static func staticSelectedFrame(
        _ frame: PhysicalFrameSelection,
        cameraDistanceMeters: Float = 1
    ) throws -> Self {
        guard cameraDistanceMeters.isFinite, cameraDistanceMeters > 0 else {
            throw PhysicalContractError.invalidFrameTime
        }
        let (scaledTime, timeOverflow) = frame.timeNumerator
            .multipliedReportingOverflow(by: 96)
        let (denominator, denominatorOverflow) = frame.timeDenominator
            .multipliedReportingOverflow(by: 96)
        let open = scaledTime.subtractingReportingOverflow(
            Int64(frame.timeDenominator)
        )
        let close = scaledTime.addingReportingOverflow(
            Int64(frame.timeDenominator)
        )
        guard !timeOverflow, !denominatorOverflow, !open.overflow, !close.overflow else {
            throw PhysicalContractError.invalidFrameTime
        }
        return Self(
            frame: frame,
            shutter: PhysicalShutterInterval(
                open: try PhysicalRationalTime(
                    numerator: open.partialValue,
                    denominator: denominator
                ),
                close: try PhysicalRationalTime(
                    numerator: close.partialValue,
                    denominator: denominator
                )
            ),
            cameraPose: PhysicalPoseSnapshot(
                position: PhysicalVector3(x: 0, y: 0, z: cameraDistanceMeters),
                rotation: .identity
            ),
            screenPose: PhysicalPoseSnapshot(
                position: PhysicalVector3(x: 0, y: 0, z: 0),
                rotation: .identity
            ),
            isStaticInput: true
        )
    }
}

struct PhysicalStaticFraming: Equatable, Sendable {
    let cameraDistanceMeters: Float

    init(device: DeviceDefinition, scene: ScreenSceneGeometryLensParametersV2) throws {
        let focal = Double(scene.focal_length_millimeters)
        let sensorWidth = Double(scene.sensor_width_millimeters)
        let sensorHeight = Double(scene.sensor_height_millimeters)
        guard focal.isFinite, focal > 0,
              sensorWidth.isFinite, sensorWidth > 0,
              sensorHeight.isFinite, sensorHeight > 0,
              device.activeWidthMeters.isFinite, device.activeWidthMeters > 0,
              device.activeHeightMeters.isFinite, device.activeHeightMeters > 0
        else { throw DeviceDomainError.invalidPhysicalProfile("Encuadre físico no válido.") }
        let horizontal = device.activeWidthMeters * focal / sensorWidth
        let vertical = device.activeHeightMeters * focal / sensorHeight
        // Five percent of breathing room makes the device boundary observable
        // while deriving the pose solely from the resolved lens/sensor/device.
        cameraDistanceMeters = Float(max(horizontal, vertical) * 1.05)
    }
}
