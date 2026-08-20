import Foundation

/// Workstation-only background used to inspect the resolved Device contribution.
/// It is never part of Saved Scene authoring or a Render Queue request.
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
