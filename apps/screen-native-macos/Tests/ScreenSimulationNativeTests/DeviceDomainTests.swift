import Testing
import StudioColor
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
    #expect(macBook.colorModeID == "srgb")
    #expect(macBook.colorModeIDs == ["srgb"])
    #expect(macBook.minimumWhiteLuminance == 100)
    #expect(macBook.maximumWhiteLuminance == 500)
    #expect(macBook.whiteLuminanceStep == 1)
    #expect(macBook.defaultCoverGlassPresetID == "cover-glossy-strong-ar")
    #expect(macBook.panelLightSpread.coreRadiusMicrometers.count == 3)
    _ = try macBook.resolved()
}

@Test func asusPresetPublishesItsColorModesAndExplicitLuminanceCapability() throws {
    let asus = try #require(
        try RustDeviceCatalog.builtIns().first { $0.id == "lcd-asus-proart-pa329cv" }
    )
    #expect(asus.colorModeIDs == ["srgb", "rec709-gamma24"])
    #expect(asus.colorModeIDs.contains(asus.colorModeID))
    #expect(asus.minimumWhiteLuminance == 100)
    #expect(asus.maximumWhiteLuminance == 350)
    #expect(asus.whiteLuminanceStep == 1)
}

@Test func deviceRejectsAnUnknownColorMode() throws {
    var device = try #require(try RustDeviceCatalog.builtIns().first)
    device.colorModeID = "unknown-mode"
    #expect(throws: DeviceDomainError.self) {
        try device.resolved()
    }
    #expect(StudioColorMode.catalog.contains { $0.id == "srgb" })
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
