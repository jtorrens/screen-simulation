import Foundation

/// UI projection of the engine's canonical per-channel sensor gains.
/// 6500 K / tint 0 is the neutral calibration point for every camera matrix.
enum DevelopWhiteBalanceControls {
    static let temperatureRange = 2_000.0 ... 15_000.0
    static let tintRange = -100.0 ... 100.0

    static func gains(
        temperatureKelvin: Double,
        tint: Double,
        acescgToSensor: [Double]
    ) -> [Double] {
        let neutral = sensorResponse(temperatureKelvin: 6_500, matrix: acescgToSensor)
        let response = sensorResponse(
            temperatureKelvin: temperatureRange.clamped(temperatureKelvin),
            matrix: acescgToSensor
        )
        let magentaScale = pow(2, tintRange.clamped(tint) / 100)
        return (0 ..< 3).map { channel in
            let chromatic = neutral[channel] / max(response[channel], 1e-9)
            return chromatic * (channel == 1 ? 1 : magentaScale)
        }
    }

    static func controls(gains: [Double], acescgToSensor: [Double]) -> (
        temperatureKelvin: Double, tint: Double
    ) {
        guard gains.count == 3, gains.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return (6_500, 0)
        }
        var bestTemperature = 6_500.0
        var bestError = Double.greatestFiniteMagnitude
        for temperature in stride(from: 2_000.0, through: 15_000.0, by: 10) {
            let base = self.gains(
                temperatureKelvin: temperature, tint: 0,
                acescgToSensor: acescgToSensor
            )
            // Tint scales red and blue equally, so their ratio isolates CCT.
            let error = abs(log(max(gains[0] / gains[2], 1e-9))
                - log(max(base[0] / base[2], 1e-9)))
            if error < bestError {
                bestError = error
                bestTemperature = temperature
            }
        }
        let base = self.gains(
            temperatureKelvin: bestTemperature, tint: 0,
            acescgToSensor: acescgToSensor
        )
        let scale = sqrt(max(gains[0] / base[0], 1e-9) * max(gains[2] / base[2], 1e-9))
        let tint = tintRange.clamped(log2(scale) * 100)
        return (bestTemperature, tint)
    }

    private static func sensorResponse(
        temperatureKelvin: Double,
        matrix: [Double]
    ) -> [Double] {
        guard matrix.count == 9 else { return [1, 1, 1] }
        let xy = planckianChromaticity(temperatureKelvin)
        let xyz = [xy.x / xy.y, 1, (1 - xy.x - xy.y) / xy.y]
        let acescg = multiply([
            1.64102338, -0.32480329, -0.23642470,
            -0.66366286, 1.61533159, 0.01675635,
            0.01172189, -0.00828444, 0.98839486,
        ], xyz)
        return multiply(matrix, acescg).map { max($0, 1e-9) }
    }

    private static func planckianChromaticity(_ temperatureKelvin: Double) -> (x: Double, y: Double) {
        let t = temperatureRange.clamped(temperatureKelvin)
        let x: Double = if t <= 4_000 {
            -0.2661239e9 / pow(t, 3) - 0.2343580e6 / pow(t, 2) + 0.8776956e3 / t + 0.179910
        } else {
            -3.0258469e9 / pow(t, 3) + 2.1070379e6 / pow(t, 2) + 0.2226347e3 / t + 0.240390
        }
        let y: Double
        if t <= 2_222 {
            y = -1.1063814 * pow(x, 3) - 1.34811020 * pow(x, 2) + 2.18555832 * x - 0.20219683
        } else if t <= 4_000 {
            y = -0.9549476 * pow(x, 3) - 1.37418593 * pow(x, 2) + 2.09137015 * x - 0.16748867
        } else {
            y = 3.0817580 * pow(x, 3) - 5.87338670 * pow(x, 2) + 3.75112997 * x - 0.37001483
        }
        return (x, y)
    }

    private static func multiply(_ matrix: [Double], _ vector: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: 3)
        for row in 0 ..< 3 {
            let offset = row * 3
            let red = matrix[offset] * vector[0]
            let green = matrix[offset + 1] * vector[1]
            let blue = matrix[offset + 2] * vector[2]
            result[row] = red + green + blue
        }
        return result
    }
}

private extension ClosedRange where Bound == Double {
    func clamped(_ value: Double) -> Double {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
