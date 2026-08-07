import Testing
@testable import ScreenSimulationNative

@Test func neutralDevelopWhiteBalanceIsStableAcrossCameraMatrices() {
    let matrix = [0.72, 0.21, 0.07, 0.10, 0.82, 0.08, 0.03, 0.16, 0.81]
    let gains = DevelopWhiteBalanceControls.gains(
        temperatureKelvin: 6_500, tint: 0, acescgToSensor: matrix
    )
    for gain in gains { #expect(abs(gain - 1) < 1e-9) }
}

@Test func developWhiteBalanceRoundTripsTemperatureAndTint() {
    let matrix = [0.72, 0.21, 0.07, 0.10, 0.82, 0.08, 0.03, 0.16, 0.81]
    let gains = DevelopWhiteBalanceControls.gains(
        temperatureKelvin: 4_300, tint: 18, acescgToSensor: matrix
    )
    let controls = DevelopWhiteBalanceControls.controls(gains: gains, acescgToSensor: matrix)
    #expect(abs(controls.temperatureKelvin - 4_300) <= 10)
    #expect(abs(controls.tint - 18) < 0.01)
}
