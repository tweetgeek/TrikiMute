import SwiftUI
import TrikiMuteCore

/// Identifier shared between the `Window` scene declared in `TrikiMuteApp`
/// and the places that open or dismiss it — `MenuBarView.pairingEntry` and
/// `PairingWindowView` itself. A `String` constant, not a magic literal
/// repeated at each call site.
enum PairingWindow {
    static let id = "parowanie"
}

/// Standalone window for the pairing flow, replacing its old home inside the
/// menu bar menu. A native `NSMenu` closes on every click — that made the
/// one piece of feedback that actually matters here, the live press
/// countdown, disappear behind a menu the user had to keep reopening to
/// watch. This window stays on screen and updates as `AppState.pairing`
/// changes, same as any other SwiftUI view bound to `@Observable` state.
///
/// Deliberately a thin re-presentation of `AppState.pairing`, not a new
/// source of truth: every case here mirrors what the menu's old inline
/// pairing section rendered, phase for phase, largely word for word.
/// Pairing logic itself — timers, timeouts, the confirmation count — is
/// untouched; see `AppState`.
///
/// **Two defects fixed here, presentation only, no change to `AppState` or
/// `PairingConfirmation`:**
///
/// 1. The window used to size itself from a single, unconstrained line of
///    text per phase — fine inside a narrow menu column, where every row is
///    already known to be one line, but a plain `Label` with no width bound
///    left the confirmation sentence ("Potwierdź „xxx”: naciśnij…") free to
///    render off the edge of the window instead of wrapping, cutting off the
///    one number this whole screen exists to convey. The root `.frame` below
///    now bounds the window's width, and every piece of text that can vary
///    in length (`wrappingLabel`, `remainingPressCount`'s caption, candidate
///    names) is explicitly allowed to grow vertically instead. The press
///    count itself no longer lives inside a sentence at all — see
///    `remainingPressCount(_:)`.
/// 2. Candidates used to render as `Label`s under `.buttonStyle(.borderless)`
///    — correct *inside* an `NSMenu`, where every row is already known to be
///    clickable, but read as inert text the moment pairing moved into an
///    ordinary window. `CandidateRow` below gives each one a hit-testable
///    background, a hover highlight, and a trailing chevron.
struct PairingWindowView: View {
    let state: AppState

    /// Used to close the window itself once a session concludes on its own
    /// — see the `onChange` below for exactly when.
    @Environment(\.dismissWindow) private var dismissWindow

    private static let pairingIcon = "dot.radiowaves.left.and.right"

    /// Bounds the window's width so long text (a device name, the failure
    /// message) wraps instead of either truncating or growing the window
    /// past a sane size. `maxWidth` in particular is what makes wrapping
    /// happen at all — without it, an unconstrained `Text` prefers a single
    /// wide line over wrapping, which is exactly how the original truncation
    /// defect arose once that single line ran past the window's actual
    /// on-screen edge. Height is deliberately left unbounded here — phases
    /// vary a lot in how tall they are (an empty search vs. five
    /// candidates), and `.windowResizability(.contentSize)` in
    /// `TrikiMuteApp` already resizes the window to match.
    private static let contentWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (380, 440, 480)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            content
        }
        .padding(20)
        .frame(
            minWidth: Self.contentWidth.min,
            idealWidth: Self.contentWidth.ideal,
            maxWidth: Self.contentWidth.max,
            minHeight: 96,
            alignment: .leading
        )
        .onChange(of: state.pairing) { oldPhase, newPhase in
            // The window closes itself only when a *live* session concludes
            // on its own — confirmed, or cancelled from any phase (both land
            // on `.inactive`). `.failed` deliberately does not close it: the
            // failure message is the one piece of information this window
            // exists to keep visible, and closing out from under it would
            // reintroduce exactly the problem the window was built to fix.
            // Guarded on `oldPhase != .inactive` so the window's very first
            // render — already non-`.inactive` by the time it appears, since
            // `MenuBarView.pairingEntry` starts pairing before opening the
            // window — never matches this and closes itself immediately.
            if newPhase == .inactive, oldPhase != .inactive {
                dismissWindow(id: PairingWindow.id)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.pairing {
        case .inactive:
            // Reachable only for the brief instant between a session
            // concluding and the `dismissWindow` call above actually taking
            // effect — the window is never opened while `pairing` already
            // reads `.inactive` (see `MenuBarView.pairingEntry`).
            Text("Parowanie zakończone.")

        case .searching(let candidates):
            // The Kapsel sleeps and doesn't advertise until its button is
            // pressed — the single most important fact for anyone staring at
            // an empty list.
            if candidates.isEmpty {
                wrappingLabel("Szukam Kapsli… naciśnij przycisk kapsla, żeby go obudzić.", systemImage: Self.pairingIcon)
            } else {
                Text("Wybierz Kapsel:")
                    .font(.headline)
                candidateList(candidates)
                wrappingLabel("Innego nie widać? Naciśnij jego przycisk, żeby go obudzić.", systemImage: Self.pairingIcon)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            cancelButton

        case .connecting(let candidate):
            // A spinner, not the static radiowaves icon `wrappingLabel`
            // otherwise uses — this is the one phase that is genuinely just
            // waiting on the network, distinct from the press countdown
            // below. Showing the same text for "still connecting" and
            // "counting presses" would leave the user unable to tell which
            // one had actually failed.
            HStack(alignment: .top, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
                Text("Łączę się z „\(candidate.name)”…")
                    .fixedSize(horizontal: false, vertical: true)
            }
            cancelButton

        case .confirming(let candidate, let remaining, let resetAfterDrop):
            confirmingSection(candidate: candidate, remaining: remaining, resetAfterDrop: resetAfterDrop)
            cancelButton

        case .failed(let message):
            // Same triangle the tray and the menu's pairing entry use for
            // "something is broken" — a failed pairing attempt is itself a
            // fault the user has to acknowledge, not a step still in
            // progress.
            wrappingLabel(message, systemImage: "exclamationmark.triangle.fill")
            Button {
                state.startPairing()
            } label: {
                Label("Wróć do listy", systemImage: "arrow.uturn.backward")
            }
            cancelButton
        }
    }

    /// Outline `xmark.circle`, not a filled variant — cancelling pairing is
    /// reversible and cheap, same posture the menu used for it.
    private var cancelButton: some View {
        Button {
            state.cancelPairing()
        } label: {
            Label("Anuluj parowanie", systemImage: "xmark.circle")
        }
    }

    /// `Label` with its text explicitly allowed to wrap onto multiple lines
    /// and stretched to the full width offered by the window, instead of
    /// `Label`'s own default of preferring one line as wide as the text
    /// needs. Every piece of variable-length, user-facing text in this view
    /// goes through this (or the equivalent treatment in `CandidateRow`) —
    /// see the type-level doc comment for why that default is what produced
    /// the original truncation defect.
    @ViewBuilder
    private func wrappingLabel(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Height budget for `candidateList` once it needs to scroll at all —
    /// a rough per-row estimate, good enough for a height *cap*, not
    /// something rows are held to (a wrapped long name is taller, and stays
    /// free to be).
    private static let candidateRowHeight: CGFloat = 44
    private static let maxVisibleCandidateRows = 5

    /// The candidate list, scrollable past `maxVisibleCandidateRows` so a
    /// noisy BLE environment with many capsules in range can't grow the
    /// window past a usable size — everything else about the window still
    /// resizes to fit its content (`.windowResizability(.contentSize)` in
    /// `TrikiMuteApp`), but an unbounded list is the one part of this screen
    /// whose length isn't under this app's control at all.
    ///
    /// The height cap only applies once there's actually something to
    /// scroll past: with `candidates.count` at or under
    /// `maxVisibleCandidateRows`, this renders as a plain, unscrolled
    /// `VStack` sized to its true content — capping *every* list at
    /// `maxVisibleCandidateRows * candidateRowHeight` regardless of count
    /// produced a spurious scrollbar for as few as three candidates
    /// whenever one had a long enough name to wrap onto a second line,
    /// since that row alone could already exceed the estimate the fixed
    /// height assumed for it.
    @ViewBuilder
    private func candidateList(_ candidates: [DeviceCandidate]) -> some View {
        if candidates.count > Self.maxVisibleCandidateRows {
            ScrollView {
                candidateRows(candidates)
            }
            .frame(height: CGFloat(Self.maxVisibleCandidateRows) * Self.candidateRowHeight)
        } else {
            candidateRows(candidates)
        }
    }

    private func candidateRows(_ candidates: [DeviceCandidate]) -> some View {
        VStack(spacing: 4) {
            ForEach(candidates) { candidate in
                CandidateRow(candidate: candidate) {
                    state.choosePairingCandidate(candidate.id)
                }
            }
        }
    }

    @ViewBuilder
    private func confirmingSection(candidate: DeviceCandidate, remaining: Int, resetAfterDrop: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = ConfirmingCopy.dropNotice(resetAfterDrop: resetAfterDrop) {
                wrappingLabel(notice, systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // A dedicated "press the button" icon rather than the generic
            // pairing one — this is the one phase where the user's next move
            // is a physical action on the Kapsel itself, not a choice in
            // this window.
            wrappingLabel(ConfirmingCopy.title(name: candidate.name), systemImage: "hand.tap.fill")
                .font(.headline)
            remainingPressCount(remaining)
        }
    }

    /// The one number this whole screen exists to show, given its own line
    /// and its own size instead of living inside a sentence that can
    /// truncate (see the type-level doc comment). Large and
    /// `monospacedDigit()` so it reads at a glance — this is the instruction
    /// the user acts on while looking away from the screen at the physical
    /// Kapsel — and it updates on every press for free: `remaining` is
    /// `PairingPhase.confirming`'s own field, not a copy this view keeps in
    /// sync itself, so there's no separate state that could drift from it.
    ///
    /// Wording split across the caption and the numeral is exactly the
    /// original single sentence ("Potwierdź „xxx”: naciśnij przycisk jeszcze
    /// N×"), just no longer concatenated into one truncatable line — see
    /// `ConfirmingCopy`.
    private func remainingPressCount(_ remaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Naciśnij przycisk jeszcze")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(remaining)×")
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.tint)
        }
    }
}

/// Pure text formatting for `.confirming`, factored out of the view body so
/// it's testable without rendering SwiftUI — the one piece of conditional
/// wording left on this screen. The press count itself is *not* text
/// formatting at all anymore; see
/// `PairingWindowView.remainingPressCount(_:)`.
enum ConfirmingCopy: Equatable {
    /// Unchanged from the original combined sentence, minus the press count
    /// — see the type-level doc comment on `PairingWindowView` for why the
    /// count moved out into its own presentation.
    static func title(name: String) -> String {
        "Potwierdź „\(name)”"
    }

    /// `nil` unless this attempt has already lost press progress to a
    /// mid-confirmation drop — see `PairingPhase.confirming`'s
    /// `resetAfterDrop` field. Unchanged wording from the original.
    static func dropNotice(resetAfterDrop: Bool) -> String? {
        resetAfterDrop ? "Połączenie się zerwało — licz od nowa." : nil
    }
}

/// One candidate in the pairing list, styled to read as a button rather than
/// a plain row of text: the whole row is hit-testable, hovering it tints the
/// background, and a trailing chevron says "this leads somewhere" — none of
/// which the previous `Label` under `.buttonStyle(.borderless)` conveyed.
/// That borderless style was exactly right *inside* an `NSMenu`, where every
/// row is already known to be clickable; it stopped being enough the moment
/// pairing moved into an ordinary window — see the type-level doc comment on
/// `PairingWindowView`.
private struct CandidateRow: View {
    let candidate: DeviceCandidate
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                // No line limit: a device name is hardware-supplied and can
                // be long — it wraps onto a second line rather than
                // truncating, same policy as the rest of this window.
                Text(candidate.name)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // Signal strength stays exactly as legible as it was
                // before (a plain dBm reading) — only its position and
                // weight changed, to a secondary trailing caption that
                // doesn't compete with the name for attention.
                Text("\(candidate.rssi) dBm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)
            )
            // Makes the padded background itself part of the hit area, not
            // just the icon/text glyphs inside it — without this, clicking
            // the row's empty space (most of its area) would miss the
            // button entirely.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
