import Testing
@testable import TrikiMute

/// Pins `ConfirmingCopy` — the only piece of the pairing window's rewritten
/// presentation that has any actual branching logic (see
/// `PairingWindowView.swift`). Everything else in that rewrite (wrapping
/// instead of truncating, the candidate row's hover/chevron affordance, the
/// press count's size and placement) is layout, not logic, and is verified
/// visually instead — see `/tmp/pairui-report.md` for how.
@Suite("ConfirmingCopy")
struct ConfirmingCopyTests {
    @Test func titleQuotesTheCandidateName() {
        #expect(ConfirmingCopy.title(name: "Kapsel-A") == "Potwierdź „Kapsel-A”")
    }

    @Test func dropNoticeIsNilWithoutADrop() {
        #expect(ConfirmingCopy.dropNotice(resetAfterDrop: false) == nil)
    }

    @Test func dropNoticeNamesTheResetAfterADrop() {
        #expect(ConfirmingCopy.dropNotice(resetAfterDrop: true) == "Połączenie się zerwało — licz od nowa.")
    }
}
