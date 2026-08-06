import AppKit
import ColorSync
import MetalKit

public struct StudioColorSystemDisplayInfo: Equatable, Sendable {
    public let displayID: CGDirectDisplayID?
    public let displayName: String
    public let profileName: String
    public let systemColorSpaceName: String

    public init(
        displayID: CGDirectDisplayID?,
        displayName: String,
        profileName: String,
        systemColorSpaceName: String
    ) {
        self.displayID = displayID
        self.displayName = displayName
        self.profileName = profileName
        self.systemColorSpaceName = systemColorSpaceName
    }

    public static let unavailable = Self(
        displayID: nil,
        displayName: "Pantalla no identificada",
        profileName: "Perfil no disponible",
        systemColorSpaceName: "Espacio no disponible"
    )

    @MainActor
    public static func current(screen: NSScreen?) -> Self {
        guard let screen = screen ?? NSScreen.main else { return .unavailable }
        let systemColorSpaceName = screen.colorSpace?.localizedName
            ?? screen.colorSpace?.cgColorSpace?.name as String?
            ?? "Espacio no identificado"
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return Self(
                displayID: nil,
                displayName: screen.localizedName,
                profileName: systemColorSpaceName,
                systemColorSpaceName: systemColorSpaceName
            )
        }
        let displayID = number.uint32Value
        guard let unmanagedProfile = ColorSyncProfileCreateWithDisplayID(displayID) else {
            return Self(
                displayID: displayID,
                displayName: screen.localizedName,
                profileName: systemColorSpaceName,
                systemColorSpaceName: systemColorSpaceName
            )
        }
        let profile = unmanagedProfile.takeRetainedValue()
        let description = ColorSyncProfileCopyDescriptionString(profile)?
            .takeRetainedValue() as String?
        return Self(
            displayID: displayID,
            displayName: screen.localizedName,
            profileName: description ?? systemColorSpaceName,
            systemColorSpaceName: systemColorSpaceName
        )
    }
}

/// Shared CREDITOS-HDR screen/profile observation boundary. The ODT remains
/// standard-referred; CAMetalLayer declares that signal and ColorSync owns the
/// final conversion into the active physical display profile.
@MainActor
public final class StudioColorScreenAwareMetalView: MTKView {
    public var screenDidChange: ((StudioColorSystemDisplayInfo) -> Void)?

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reportScreenChange),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reportScreenChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reportScreenChange),
            name: Notification.Name("com.apple.ColorSync.DisplayProfileNotification"),
            object: nil
        )
        reportScreenChange()
    }

    @objc private func reportScreenChange() {
        screenDidChange?(.current(screen: window?.screen ?? NSScreen.main))
        setNeedsDisplay(bounds)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
