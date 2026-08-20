import SwiftUI

/// Presentation state for actions that remain active until the user turns them off.
/// Momentary commands and progress/status controls do not use this contract.
enum NativeActionState: Equatable, Sendable {
    case unavailable
    case inactive
    case active

    init(available: Bool = true, active: Bool) {
        self = available ? (active ? .active : .inactive) : .unavailable
    }

    var isEnabled: Bool { self != .unavailable }
    var isHighlighted: Bool { self == .active }
}

private struct NativeActionStateModifier: ViewModifier {
    let state: NativeActionState

    func body(content: Content) -> some View {
        content
            .foregroundStyle(state.isHighlighted ? NativeTheme.accent : Color.secondary)
            .opacity(state == .unavailable ? 0.35 : 1)
            .disabled(!state.isEnabled)
    }
}

extension View {
    func nativeActionState(_ state: NativeActionState) -> some View {
        modifier(NativeActionStateModifier(state: state))
    }
}
