import Testing
@testable import swift_mail

/// The pane is single-occupancy: the preference decides where compose opens,
/// but never at the cost of a message already being written there.
struct ComposePlacementTests {
    @Test("The preference off always means a window")
    func windowedByDefault() {
        #expect(ComposePreferences.placement(composesInline: false, paneIsBusy: false) == .window)
        #expect(ComposePreferences.placement(composesInline: false, paneIsBusy: true) == .window)
    }

    @Test("The preference on uses a free pane")
    func inlineWhenFree() {
        #expect(ComposePreferences.placement(composesInline: true, paneIsBusy: false) == .inline)
    }

    @Test("A busy pane falls back to a window rather than displacing a draft")
    func windowWhenPaneIsBusy() {
        #expect(ComposePreferences.placement(composesInline: true, paneIsBusy: true) == .window)
    }
}
