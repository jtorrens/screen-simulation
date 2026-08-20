import Foundation

/// Workstation-only plate owned by Reference composition when inspecting the
/// resolved Device contribution. It is never Saved Scene authoring or a Render
/// Queue request, even though both the Reference card and Preview toolbar bind it.
enum InteractivePreviewBackground: String, CaseIterable, Identifiable {
    case reference
    case vfxChecker
    case black
    case white
    case middleGray

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reference: "Referencia"
        case .vfxChecker: "Damero VFX"
        case .black: "Negro"
        case .white: "Blanco"
        case .middleGray: "Gris medio"
        }
    }

    /// Stable renderer code. Zero remains reserved for non-interactive callers
    /// such as Render Queue, which retain their own explicit composition contract.
    var rendererCode: UInt32 {
        switch self {
        case .reference: 1
        case .vfxChecker: 2
        case .black: 3
        case .white: 4
        case .middleGray: 5
        }
    }
}
