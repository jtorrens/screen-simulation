import Foundation

enum ShutterPresentation {
    private static let denominator: UInt32 = 1_000_000_000

    static func exposureSeconds(_ shutter: PhysicalPipelineAuthoringState.ShutterMotion) -> Double {
        seconds(shutter.closeOffsetNumerator, shutter.closeOffsetDenominator)
            - seconds(shutter.openOffsetNumerator, shutter.openOffsetDenominator)
    }

    static func angle(_ shutter: PhysicalPipelineAuthoringState.ShutterMotion, fps: Double) -> Double {
        exposureSeconds(shutter) * max(fps, 0.001) * 360
    }

    static func setAngle(_ degrees: Double, fps: Double, in shutter: inout PhysicalPipelineAuthoringState.ShutterMotion) {
        setExposureSeconds(degrees / (360 * max(fps, 0.001)), in: &shutter)
    }

    static func setExposureSeconds(_ duration: Double, in shutter: inout PhysicalPipelineAuthoringState.ShutterMotion) {
        let open = seconds(shutter.openOffsetNumerator, shutter.openOffsetDenominator)
        let close = seconds(shutter.closeOffsetNumerator, shutter.closeOffsetDenominator)
        let midpoint = (open + close) / 2
        shutter.openOffsetNumerator = ticks(midpoint - duration / 2)
        shutter.openOffsetDenominator = denominator
        shutter.closeOffsetNumerator = ticks(midpoint + duration / 2)
        shutter.closeOffsetDenominator = denominator
    }

    static func readoutMilliseconds(_ shutter: PhysicalPipelineAuthoringState.ShutterMotion) -> Double {
        seconds(shutter.readoutDurationNumerator, shutter.readoutDurationDenominator) * 1_000
    }

    static func setReadoutMilliseconds(_ milliseconds: Double, in shutter: inout PhysicalPipelineAuthoringState.ShutterMotion) {
        shutter.readoutDurationNumerator = ticks(milliseconds / 1_000)
        shutter.readoutDurationDenominator = denominator
    }

    private static func seconds(_ numerator: Int64, _ denominator: UInt32) -> Double {
        Double(numerator) / Double(max(denominator, 1))
    }

    private static func ticks(_ seconds: Double) -> Int64 {
        Int64((seconds * Double(denominator)).rounded())
    }
}
