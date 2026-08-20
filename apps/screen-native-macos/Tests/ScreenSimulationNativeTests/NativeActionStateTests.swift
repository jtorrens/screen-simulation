import Testing
@testable import ScreenSimulationNative

@Test func persistentActionStateHasOneConsistentPresentationContract() {
    let unavailable = NativeActionState(available: false, active: true)
    let inactive = NativeActionState(available: true, active: false)
    let active = NativeActionState(available: true, active: true)

    #expect(!unavailable.isEnabled)
    #expect(!unavailable.isHighlighted)
    #expect(inactive.isEnabled)
    #expect(!inactive.isHighlighted)
    #expect(active.isEnabled)
    #expect(active.isHighlighted)
}
