import Foundation

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
        _ frame: PhysicalFrameSelection
    ) throws -> Self {
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
                position: PhysicalVector3(x: 0, y: 0, z: 1),
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
