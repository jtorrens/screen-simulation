import Testing
@testable import ScreenSimulationNative

@Test func rustDeviceCatalogIsTheSinglePresetAuthority() throws {
    let devices = try RustDeviceCatalog.builtIns()
    #expect(devices.count == 9)
    #expect(Set(devices.map(\.id)).count == devices.count)
    let macBook = try #require(
        devices.first { $0.id == "lcd-macbook-pro-retina-14" }
    )
    #expect(macBook.nativeWidth == 3_024)
    #expect(macBook.nativeHeight == 1_964)
    #expect(abs(macBook.activeWidthMeters - 0.3024) < 0.000_001)
    #expect(abs(macBook.pixelsPerInch - 254) < 0.2)
    #expect(macBook.panelTechnology == .ipsLCD)
    #expect(macBook.defaultCoverGlassPresetID == "cover-glossy-strong-ar")
    #expect(macBook.panelLightSpread.coreRadiusMicrometers.count == 3)
    _ = try macBook.resolved()
}

@Test func invalidDeviceIsRejectedByTheRustPhysicalContract() throws {
    var device = try #require(try RustDeviceCatalog.builtIns().first)
    device.whiteLevelNits = device.blackLevelNits
    #expect(throws: DeviceDomainError.self) {
        try device.resolved()
    }
}

@Test func resolvedDeviceIsAnImmutableSnapshot() throws {
    var definition = try #require(try RustDeviceCatalog.builtIns().first)
    let resolved = try definition.resolved()
    definition.name = "Editado después"
    #expect(resolved.definition.name != definition.name)
}
