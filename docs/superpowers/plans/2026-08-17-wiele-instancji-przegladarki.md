# Odporność na wiele instancji przeglądarki — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aplikacja znajduje Cel w każdej żywej instancji Chrome i Brave, zamiast
odpytywać tę jedną, którą wybierze system.

**Architecture:** Apple Events adresowane po identyfikatorze procesu przez
ScriptingBridge (`SBApplication(processIdentifier:)`) zamiast po nazwie aplikacji.
Logika wyboru instancji, okna i karty żyje w `TrikiMuteCore` za protokołami
`BrowserAccess`/`MeetBackend` i jest w całości testowalna atrapami; ScriptingBridge
pojawia się wyłącznie w cienkiej produkcyjnej implementacji w targecie aplikacji.
Dzisiejsza ścieżka AppleScript zostaje jako zapas przy awarii pierwszej.

**Tech Stack:** Swift 5 language mode, SwiftPM, ScriptingBridge, AppKit
(`NSWorkspace`), Swift Testing (`import Testing`, `@Test`, `#expect`).

**Spec:** `docs/superpowers/specs/2026-08-17-wiele-instancji-przegladarki-design.md`
**Decyzja:** `docs/adr/0003-scriptingbridge-zamiast-nazwy-aplikacji.md`

## Global Constraints

- Swift language mode v5 dla wszystkich targetów (`Package.swift` — nie zmieniaj).
- Platforma: macOS 14 (`.macOS(.v14)`).
- Testy: Swift Testing (`import Testing`, `@Test`, `#expect`, `Issue.record`).
  Nie XCTest.
- Kod, nazwy typów i komentarze po angielsku. Napisy interfejsu i komunikaty
  błędów widziane przez użytkownika — po polsku. Tak jest w całym repozytorium.
- Pojęcia domenowe zgodnie z `CONTEXT.md`: Cel (`target`), Instancja
  (`instance`), Akcja (`action`), Kapsel (`device`).
- Selektory DOM wolno pisać wyłącznie w `MeetScripts.swift` — tak stanowi
  komentarz nagłówkowy tego pliku i to się nie zmienia.
- `ProbeOutcome.failed` nigdy nie może udawać `.noTarget`. To najważniejsza
  reguła w tej bazie kodu; jeśli w trakcie zadania trzeba wybrać między nimi
  przy niepewności, wybierz `.failed`.
- Uruchamianie testów: `swift test`. Budowanie aplikacji: `./scripts/build-app.sh release`.
- Aplikację uruchamiaj wyłącznie przez `open build/TrikiMute.app`, nigdy wprost
  z terminala — inaczej dziedziczy zgody Automation terminala i wynik testu
  ręcznego jest bezwartościowy (patrz README).

---

## Struktura plików

**Tworzone (`TrikiMuteCore` — czysta logika, bez ScriptingBridge):**

- `Sources/TrikiMuteCore/BrowserInstance.swift` — `SupportedBrowser`,
  `BrowserInstance`, `BrowserOrdering.ordered(_:supported:)`
- `Sources/TrikiMuteCore/BrowserAccess.swift` — `BrowserTab`, `BrowserAccess`
- `Sources/TrikiMuteCore/MeetBackend.swift` — protokół `MeetBackend`
- `Sources/TrikiMuteCore/ScanningMeetBackend.swift` — ścieżka podstawowa
- `Sources/TrikiMuteCore/AppleScriptMeetBackend.swift` — ścieżka zapasowa

**Tworzone (`TrikiMute` — target aplikacji, tu mieszka ScriptingBridge):**

- `Sources/TrikiMute/ScriptingBridgeBrowsers.swift` — implementacja
  `BrowserAccess` plus deklaracje `@objc` i pułapka na błędy Apple Events
- `Sources/TrikiMute/RunningBrowsers.swift` — wykrywanie instancji przez
  `NSWorkspace`, zastępuje `BrowserOrder`

**Modyfikowane:**

- `Sources/TrikiMuteCore/MeetScripts.swift` — dochodzi stała `meetHost`
- `Sources/TrikiMuteCore/MeetController.swift` — staje się fasadą nad dwoma
  backendami; dzisiejsza logika AppleScript wyprowadza się do
  `AppleScriptMeetBackend`
- `Sources/TrikiMute/AppState.swift` — `browserOrder` ustępuje miejsca
  `browserInstances`
- `Sources/TrikiMute/BrowserOrder.swift` — kasowany w Task 5 (zastąpiony przez
  `RunningBrowsers`; żyje do tego czasu, bo opiera się na nim most przejściowy
  z Task 3, dzięki któremu każdy commit na gałęzi się buduje)

**Testy:**

- `Tests/TrikiMuteCoreTests/BrowserOrderingTests.swift` (nowy)
- `Tests/TrikiMuteCoreTests/ScanningMeetBackendTests.swift` (nowy)
- `Tests/TrikiMuteCoreTests/MeetControllerTests.swift` (przepisany)
- `Tests/TrikiMuteTests/RunningBrowsersTests.swift` (nowy)
- `Tests/TrikiMuteTests/AppStateTests.swift` (dostosowany)

---

### Task 1: Model Instancji i jej kolejność

Czysta logika, żadnego wejścia/wyjścia. Ustala jedyną listę obsługiwanych
przeglądarek i deterministyczną kolejność ich przeglądania.

**Files:**
- Create: `Sources/TrikiMuteCore/BrowserInstance.swift`
- Test: `Tests/TrikiMuteCoreTests/BrowserOrderingTests.swift`

**Interfaces:**
- Consumes: nic
- Produces: `SupportedBrowser(bundleID: String, name: String)`,
  `BrowserInstance(pid: pid_t, browser: SupportedBrowser, isActive: Bool)`,
  `BrowserOrdering.supported: [SupportedBrowser]`,
  `BrowserOrdering.ordered(_ instances: [BrowserInstance], supported: [SupportedBrowser]) -> [BrowserInstance]`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TrikiMuteCoreTests/BrowserOrderingTests.swift
import Foundation
import Testing
@testable import TrikiMuteCore

private let chrome = SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome")
private let brave = SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser")

@Test func activeInstanceWinsOverBrowserOrderAndPid() {
    // Brave is later in the list and has a higher pid, but it's the one the
    // user is looking at — "the browser you're looking at wins" is the rule
    // this whole ordering exists to preserve.
    let instances = [
        BrowserInstance(pid: 100, browser: chrome, isActive: false),
        BrowserInstance(pid: 900, browser: brave, isActive: true),
    ]
    let ordered = BrowserOrdering.ordered(instances, supported: [chrome, brave])
    #expect(ordered.map(\.pid) == [900, 100])
}

@Test func chromeBeatsBraveWhenNeitherIsActive() {
    let instances = [
        BrowserInstance(pid: 100, browser: brave, isActive: false),
        BrowserInstance(pid: 200, browser: chrome, isActive: false),
    ]
    let ordered = BrowserOrdering.ordered(instances, supported: [chrome, brave])
    #expect(ordered.map(\.browser.name) == ["Google Chrome", "Brave Browser"])
}

@Test func lowerPidWinsBetweenInstancesOfTheSameBrowser() {
    // The tool-launched instance starts later, so it gets the higher pid —
    // this key is what puts the user's own browser first.
    let instances = [
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ]
    let ordered = BrowserOrdering.ordered(instances, supported: [chrome, brave])
    #expect(ordered.map(\.pid) == [1450, 38259])
}

@Test func orderingIsTotalSoTheSameInputAlwaysGivesTheSameTarget() {
    // NSWorkspace makes no promise about the order it returns processes in,
    // so the same set arriving shuffled must still order identically.
    let a = BrowserInstance(pid: 1450, browser: chrome, isActive: false)
    let b = BrowserInstance(pid: 38259, browser: chrome, isActive: false)
    let c = BrowserInstance(pid: 1445, browser: brave, isActive: false)
    let one = BrowserOrdering.ordered([a, b, c], supported: [chrome, brave])
    let two = BrowserOrdering.ordered([c, b, a], supported: [chrome, brave])
    #expect(one == two)
    #expect(one.map(\.pid) == [1450, 38259, 1445])
}

@Test func supportedListNamesBothBrowsers() {
    // One list, two uses: bundle identifiers find the processes, names are
    // what AppleScript and the menu call them.
    #expect(BrowserOrdering.supported.map(\.bundleID)
        == ["com.google.Chrome", "com.brave.Browser"])
    #expect(BrowserOrdering.supported.map(\.name)
        == ["Google Chrome", "Brave Browser"])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BrowserOrderingTests`
Expected: FAIL — kompilacja nie przechodzi, `cannot find 'SupportedBrowser' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/TrikiMuteCore/BrowserInstance.swift
import Foundation

/// A browser the app knows how to control.
///
/// One list, two uses: the bundle identifier is how running processes are
/// recognized, the name is what AppleScript addresses and what the menu shows.
/// Keeping both in one type is deliberate — a third browser must never mean
/// remembering to edit two separate lists.
public struct SupportedBrowser: Equatable, Sendable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// A single running browser process.
///
/// Not a profile: several profiles share one Instance, and only separate
/// processes are separate Instances (see `CONTEXT.md`). This distinction is the
/// whole reason this type exists — an Instance is what an Apple Event can be
/// addressed to, and what a browser name cannot distinguish.
public struct BrowserInstance: Equatable, Sendable {
    public let pid: pid_t
    public let browser: SupportedBrowser
    /// Whether this process is the frontmost application.
    public let isActive: Bool

    public init(pid: pid_t, browser: SupportedBrowser, isActive: Bool) {
        self.pid = pid
        self.browser = browser
        self.isActive = isActive
    }
}

/// The order in which Instances are searched for a Target.
public enum BrowserOrdering {
    /// Every browser the app can control, in preference order.
    public static let supported: [SupportedBrowser] = [
        SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome"),
        SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser"),
    ]

    /// Sorts Instances by three keys, in order: the active one first, then the
    /// order browsers appear in `supported`, then ascending pid.
    ///
    /// The third key isn't decoration. `NSWorkspace.runningApplications` makes
    /// no promise about ordering, so without it the same arrangement of windows
    /// could pick a different Target after a restart, with nothing having
    /// changed for the user. It also tends to put the instance a human started
    /// in the morning ahead of one a tool started later, which is exactly the
    /// failure this work exists to fix.
    public static func ordered(
        _ instances: [BrowserInstance],
        supported: [SupportedBrowser]
    ) -> [BrowserInstance] {
        let rank = Dictionary(
            uniqueKeysWithValues: supported.enumerated().map { ($1.bundleID, $0) }
        )
        return instances.sorted { left, right in
            if left.isActive != right.isActive { return left.isActive }
            let leftRank = rank[left.browser.bundleID] ?? Int.max
            let rightRank = rank[right.browser.bundleID] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            return left.pid < right.pid
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter BrowserOrderingTests`
Expected: PASS — 5 testów.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMuteCore/BrowserInstance.swift Tests/TrikiMuteCoreTests/BrowserOrderingTests.swift
git commit -m "feat(core): wprowadź model Instancji przeglądarki i jej kolejność"
```

---

### Task 2: Ścieżka podstawowa — szukanie Celu po Instancjach

Seam, za którym chowa się ScriptingBridge, plus cała logika wyboru karty.
Po tym zadaniu przypadek „Cel w drugiej instancji" jest pokryty testem,
mimo że nic jeszcze nie rozmawia z prawdziwą przeglądarką.

**Files:**
- Create: `Sources/TrikiMuteCore/BrowserAccess.swift`
- Create: `Sources/TrikiMuteCore/MeetBackend.swift`
- Create: `Sources/TrikiMuteCore/ScanningMeetBackend.swift`
- Modify: `Sources/TrikiMuteCore/MeetScripts.swift` (dochodzi `meetHost`)
- Test: `Tests/TrikiMuteCoreTests/ScanningMeetBackendTests.swift`

**Interfaces:**
- Consumes: `BrowserInstance`, `SupportedBrowser` (Task 1); `MeetScripts.probeJS()`,
  `MeetScripts.toggleJS(_:)`, `ProbeOutcome`, `ActionOutcome`, `ProbeResult`,
  `MeetAction` (istniejące)
- Produces: `BrowserTab` (`var url: String`, `func execute(_ javascript: String) throws -> String`),
  `BrowserAccess` (`func tabs(in instance: BrowserInstance) throws -> [any BrowserTab]`),
  `MeetBackend` (`func probe(instances: [BrowserInstance]) -> ProbeOutcome`,
  `func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome`),
  `ScanningMeetBackend(access:)`, `MeetScripts.meetHost`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/TrikiMuteCoreTests/ScanningMeetBackendTests.swift
import Foundation
import Testing
@testable import TrikiMuteCore

private let chrome = SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome")
private let brave = SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser")

private struct AccessError: Error {}

/// Fake tab: answers with a programmed response, or throws.
/// `nil` response means "this tab throws when executed".
private final class FakeTab: BrowserTab {
    let url: String
    private let response: String?
    private(set) var executed: [String] = []

    init(url: String, response: String?) {
        self.url = url
        self.response = response
    }

    func execute(_ javascript: String) throws -> String {
        executed.append(javascript)
        guard let response else { throw AccessError() }
        return response
    }
}

/// Fake access: hands out programmed tabs per pid, or throws for pids listed
/// as broken — the case where one Instance is unreachable while another
/// answers normally.
private final class FakeAccess: BrowserAccess {
    private let tabsByPid: [pid_t: [FakeTab]]
    private let brokenPids: Set<pid_t>
    private(set) var queriedPids: [pid_t] = []

    init(tabsByPid: [pid_t: [FakeTab]], brokenPids: Set<pid_t> = []) {
        self.tabsByPid = tabsByPid
        self.brokenPids = brokenPids
    }

    func tabs(in instance: BrowserInstance) throws -> [any BrowserTab] {
        queriedPids.append(instance.pid)
        if brokenPids.contains(instance.pid) { throw AccessError() }
        return tabsByPid[instance.pid] ?? []
    }
}

@Test func probeFindsTargetInTheSecondInstance() {
    // The regression for the whole piece of work: the first Instance is the
    // tool-launched one with no call in it, the Target lives in the second.
    let access = FakeAccess(tabsByPid: [
        38259: [FakeTab(url: "http://localhost:8011/panel", response: nil)],
        1450: [FakeTab(url: "https://meet.google.com/abc-defg-hij", response: "10")],
    ])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ])
    #expect(outcome == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func probeSkipsTabsThatArentMeetWithoutExecutingAnything() {
    let idle = FakeTab(url: "https://example.com", response: "10")
    let access = FakeAccess(tabsByPid: [1450: [idle]])
    let backend = ScanningMeetBackend(access: access)
    #expect(backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) == .noTarget)
    #expect(idle.executed.isEmpty)
}

@Test func probeSkipsMeetTabsWithoutAFullSetOfButtons() {
    // Today's behaviour, kept 1:1: a Meet tab answering NONE is passed over
    // and the search carries on to the next tab.
    let waiting = FakeTab(url: "https://meet.google.com/waiting", response: "NONE")
    let live = FakeTab(url: "https://meet.google.com/abc-defg-hij", response: "01")
    let access = FakeAccess(tabsByPid: [1450: [waiting, live]])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    #expect(outcome == .target(ProbeResult(browser: "Google Chrome", micMuted: false, cameraOff: true)))
}

@Test func probeReportsFailureWhenAnInstanceIsUnreachableAndNoTargetIsFound() {
    // A failure must never masquerade as "no call in progress" — the menu bar
    // would then claim everything is fine while, say, Automation access had
    // been revoked.
    let access = FakeAccess(tabsByPid: [:], brokenPids: [1450])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    if case .failed = outcome {} else { Issue.record("Oczekiwano .failed") }
}

@Test func probeReturnsTargetEvenIfAnEarlierInstanceFailed() {
    // One broken Instance must not hide a working Target in another.
    let access = FakeAccess(
        tabsByPid: [1445: [FakeTab(url: "https://meet.google.com/abc", response: "11")]],
        brokenPids: [1450]
    )
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.probe(instances: [
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
    ])
    #expect(outcome == .target(ProbeResult(browser: "Brave Browser", micMuted: true, cameraOff: true)))
}

@Test func probeStopsAtTheFirstInstanceWithATarget() {
    let access = FakeAccess(tabsByPid: [
        1450: [FakeTab(url: "https://meet.google.com/first", response: "00")],
        1445: [FakeTab(url: "https://meet.google.com/second", response: "11")],
    ])
    let backend = ScanningMeetBackend(access: access)
    _ = backend.probe(instances: [
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
    ])
    #expect(access.queriedPids == [1450])
}

@Test func probeRejectsAnswersThatArentTwoCharacters() {
    // Anything the injected JavaScript can't have produced is an anomaly, not
    // an answer — decoding it as "mic live, camera live" would be a failure
    // wearing the mask of a valid reading.
    let access = FakeAccess(tabsByPid: [
        1450: [FakeTab(url: "https://meet.google.com/abc", response: "nonsense")],
    ])
    let backend = ScanningMeetBackend(access: access)
    #expect(backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) == .noTarget)
}

@Test func performClicksInTheInstanceThatHasTheTarget() {
    let idle = FakeTab(url: "https://localhost/panel", response: nil)
    let live = FakeTab(url: "https://meet.google.com/abc", response: "OK")
    let access = FakeAccess(tabsByPid: [38259: [idle], 1450: [live]])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.perform(.microphone, instances: [
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
    ])
    #expect(outcome == .performed)
    #expect(live.executed.count == 1)
}

@Test func performReportsNoTargetWhenNothingAnswersOK() {
    let access = FakeAccess(tabsByPid: [
        1450: [FakeTab(url: "https://meet.google.com/waiting", response: "NONE")],
    ])
    let backend = ScanningMeetBackend(access: access)
    #expect(backend.perform(.camera, instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) == .noTarget)
}

@Test func performReportsFailureWhenAnInstanceIsUnreachable() {
    let access = FakeAccess(tabsByPid: [:], brokenPids: [1450])
    let backend = ScanningMeetBackend(access: access)
    let outcome = backend.perform(.microphone, instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    if case .failed = outcome {} else { Issue.record("Oczekiwano .failed") }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ScanningMeetBackendTests`
Expected: FAIL — `cannot find 'ScanningMeetBackend' in scope`.

- [ ] **Step 3: Write minimal implementation**

Najpierw stała hosta w `MeetScripts.swift`. Wstaw ją tuż pod `buttonSelector`:

```swift
    /// The address that marks a tab as a call. Lives here with the selectors,
    /// because it's the same kind of knowledge about Meet's surface.
    public static let meetHost = "meet.google.com"
```

```swift
// Sources/TrikiMuteCore/BrowserAccess.swift
import Foundation

/// One tab in one Instance.
///
/// Deliberately minimal: an address to recognize the call by, and a way to run
/// JavaScript in it. Everything else a real tab can do is outside what this app
/// needs, and would only make the type harder to fake in tests.
public protocol BrowserTab {
    var url: String { get }
    func execute(_ javascript: String) throws -> String
}

/// Reads tabs out of a running Instance.
///
/// The production implementation talks to ScriptingBridge; the test one hands
/// back programmed tabs. Keeping the protocol here — in the pure target — is
/// what makes "the Target is in the second Instance" a case a unit test can
/// describe at all.
///
/// Throwing is meaningful: it means the Instance could not be read, which is a
/// failure, as opposed to an Instance that simply has no call in it.
public protocol BrowserAccess {
    func tabs(in instance: BrowserInstance) throws -> [any BrowserTab]
}
```

```swift
// Sources/TrikiMuteCore/MeetBackend.swift
import Foundation

/// One way of reaching the Target.
///
/// Two implementations exist: `ScanningMeetBackend`, which addresses Instances
/// by process, and `AppleScriptMeetBackend`, which addresses browsers by name
/// and serves as the fallback. `MeetController` combines them.
public protocol MeetBackend {
    func probe(instances: [BrowserInstance]) -> ProbeOutcome
    func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome
}
```

```swift
// Sources/TrikiMuteCore/ScanningMeetBackend.swift
import Foundation

/// Searches every given Instance for the Target.
///
/// The order of `instances` is the order of the search, and the first tab with
/// a full set of buttons wins — the same rule as before this backend existed,
/// only applied across Instances instead of across browser names.
public struct ScanningMeetBackend: MeetBackend {
    private let access: any BrowserAccess

    public init(access: any BrowserAccess) {
        self.access = access
    }

    public func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        var lastError: String?
        for instance in instances {
            do {
                for tab in try access.tabs(in: instance) where tab.url.contains(MeetScripts.meetHost) {
                    let response = try tab.execute(MeetScripts.probeJS())
                    // "NONE" is four characters, so it's excluded here without
                    // needing to be named. Anything else of the wrong length is
                    // an anomaly and gets the same treatment: pass it over
                    // rather than decode it into a confident-looking reading.
                    guard response.count == 2 else { continue }
                    let chars = Array(response)
                    return .target(ProbeResult(
                        browser: instance.browser.name,
                        micMuted: chars[0] == "1",
                        cameraOff: chars[1] == "1"
                    ))
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }

    public func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        var lastError: String?
        for instance in instances {
            do {
                for tab in try access.tabs(in: instance) where tab.url.contains(MeetScripts.meetHost) {
                    if try tab.execute(MeetScripts.toggleJS(action)) == "OK" { return .performed }
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScanningMeetBackendTests`
Expected: PASS — 10 testów.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMuteCore/BrowserAccess.swift Sources/TrikiMuteCore/MeetBackend.swift Sources/TrikiMuteCore/ScanningMeetBackend.swift Sources/TrikiMuteCore/MeetScripts.swift Tests/TrikiMuteCoreTests/ScanningMeetBackendTests.swift
git commit -m "feat(core): szukaj Celu we wszystkich Instancjach przeglądarek"
```

---

### Task 3: Ścieżka zapasowa i fasada `MeetController`

Dzisiejsza logika AppleScript przeprowadza się bez zmiany zachowania do
własnego typu, a `MeetController` staje się fasadą, która pilnuje jedynej
reguły zapasu: wchodzi przy awarii, nigdy przy braku Celu.

**Files:**
- Create: `Sources/TrikiMuteCore/AppleScriptMeetBackend.swift`
- Modify: `Sources/TrikiMuteCore/MeetController.swift` (cała treść zastąpiona)
- Test: `Tests/TrikiMuteCoreTests/MeetControllerTests.swift` (przepisany)

**Interfaces:**
- Consumes: `MeetBackend`, `BrowserInstance` (Tasks 1-2); `ScriptRunner`,
  `MeetScripts.appleScript(browser:javascript:)` (istniejące)
- Produces: `AppleScriptMeetBackend(runner:)`,
  `MeetController(primary: any MeetBackend, fallback: (any MeetBackend)?)`
  z metodami `probe(instances:)` i `perform(_:instances:)`

- [ ] **Step 1: Write the failing test**

Zastąp całą treść `Tests/TrikiMuteCoreTests/MeetControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import TrikiMuteCore

private let chrome = SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome")
private let brave = SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser")

private let twoInstances = [
    BrowserInstance(pid: 1450, browser: chrome, isActive: true),
    BrowserInstance(pid: 1445, browser: brave, isActive: false),
]

private struct RunnerError: Error {}

/// Fake executor: hands back programmed responses in order and remembers the
/// scripts it ran. The value "THROW" means that call should throw.
private final class FakeRunner: ScriptRunner {
    var responses: [String]
    private(set) var executed: [String] = []

    init(_ responses: [String]) { self.responses = responses }

    func run(_ source: String) throws -> String {
        executed.append(source)
        let response = responses.isEmpty ? "NONE" : responses.removeFirst()
        if response == "THROW" { throw RunnerError() }
        return response
    }
}

/// Backend that answers with whatever it was told to, and counts its calls.
private final class StubBackend: MeetBackend {
    private let probeOutcome: ProbeOutcome
    private let actionOutcome: ActionOutcome
    private(set) var probeCalls = 0
    private(set) var performCalls = 0

    init(probe: ProbeOutcome, action: ActionOutcome = .noTarget) {
        probeOutcome = probe
        actionOutcome = action
    }

    func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        probeCalls += 1
        return probeOutcome
    }

    func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        performCalls += 1
        return actionOutcome
    }
}

// MARK: - AppleScriptMeetBackend

@Test func appleScriptBackendAsksEachBrowserNameOnceForTwoInstancesOfIt() {
    // AppleScript addresses browsers by name, so two Instances of Chrome are
    // one question to it, not two. Asking twice would be pure waste — the
    // answer cannot differ.
    let runner = FakeRunner(["NONE", "NONE"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let instances = [
        BrowserInstance(pid: 1450, browser: chrome, isActive: false),
        BrowserInstance(pid: 38259, browser: chrome, isActive: false),
        BrowserInstance(pid: 1445, browser: brave, isActive: false),
    ]
    #expect(backend.probe(instances: instances) == .noTarget)
    #expect(runner.executed.count == 2)
}

@Test func appleScriptBackendDecodesMicAndCameraState() {
    let runner = FakeRunner(["10"])
    let backend = AppleScriptMeetBackend(runner: runner)
    let result = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)])
    #expect(result == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
}

@Test func appleScriptBackendReportsErrorWhenRunnerThrows() {
    let runner = FakeRunner(["THROW"])
    let backend = AppleScriptMeetBackend(runner: runner)
    if case .failed = backend.probe(instances: [BrowserInstance(pid: 1450, browser: chrome, isActive: false)]) {
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func appleScriptBackendPerformsActionAndReportsSuccess() {
    let runner = FakeRunner(["OK"])
    let backend = AppleScriptMeetBackend(runner: runner)
    #expect(backend.perform(.microphone, instances: twoInstances) == .performed)
}

// MARK: - MeetController as a facade

@Test func controllerUsesFallbackOnlyWhenPrimaryFails() {
    let primary = StubBackend(probe: .failed("brak zgody"))
    let fallback = StubBackend(probe: .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
    let controller = MeetController(primary: primary, fallback: fallback)
    let outcome = controller.probe(instances: twoInstances)
    #expect(outcome == .target(ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false)))
    #expect(fallback.probeCalls == 1)
}

@Test func controllerNeverUsesFallbackWhenPrimarySaysNoTarget() {
    // The rule that makes the fallback sane: the primary has already searched
    // every Instance, so the fallback — which searches a subset of them — has
    // no way to find a Target it missed. Calling it would be one Apple Event
    // per browser, every 3 seconds, in the app's most common state.
    let primary = StubBackend(probe: .noTarget)
    let fallback = StubBackend(probe: .target(ProbeResult(browser: "Google Chrome", micMuted: false, cameraOff: false)))
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.probe(instances: twoInstances) == .noTarget)
    #expect(fallback.probeCalls == 0)
}

@Test func controllerNeverUsesFallbackWhenPrimaryFindsTheTarget() {
    let primary = StubBackend(probe: .target(ProbeResult(browser: "Brave Browser", micMuted: false, cameraOff: true)))
    let fallback = StubBackend(probe: .failed("nie powinno się wykonać"))
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.probe(instances: twoInstances) == .target(ProbeResult(browser: "Brave Browser", micMuted: false, cameraOff: true)))
    #expect(fallback.probeCalls == 0)
}

@Test func controllerFallsBackForActionsToo() {
    let primary = StubBackend(probe: .noTarget, action: .failed("ScriptingBridge padł"))
    let fallback = StubBackend(probe: .noTarget, action: .performed)
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.perform(.camera, instances: twoInstances) == .performed)
    #expect(fallback.performCalls == 1)
}

@Test func controllerNeverUsesFallbackForActionsWhenThereIsNoTarget() {
    let primary = StubBackend(probe: .noTarget, action: .noTarget)
    let fallback = StubBackend(probe: .noTarget, action: .performed)
    let controller = MeetController(primary: primary, fallback: fallback)
    #expect(controller.perform(.microphone, instances: twoInstances) == .noTarget)
    #expect(fallback.performCalls == 0)
}

@Test func controllerWithoutFallbackReturnsPrimaryFailureUnchanged() {
    let primary = StubBackend(probe: .failed("brak zgody"))
    let controller = MeetController(primary: primary, fallback: nil)
    if case .failed(let message) = controller.probe(instances: twoInstances) {
        #expect(message == "brak zgody")
    } else {
        Issue.record("Oczekiwano .failed")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MeetControllerTests`
Expected: FAIL — `cannot find 'AppleScriptMeetBackend' in scope` oraz brak
inicjalizatora `MeetController(primary:fallback:)`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/TrikiMuteCore/AppleScriptMeetBackend.swift
import Foundation

/// Reaches the Target the way the app did before Instances were understood:
/// by telling a browser, by name, to look through its own tabs.
///
/// Kept as the fallback path (ADR-0003), for the one failure the primary path
/// can have on its own — a change to the browser's scripting dictionary that
/// breaks the ScriptingBridge bindings. Its known weakness is exactly the
/// defect that motivated this work: a browser name cannot pick an Instance, so
/// when several are running, the system chooses for it.
public struct AppleScriptMeetBackend: MeetBackend {
    private let runner: any ScriptRunner

    public init(runner: any ScriptRunner) {
        self.runner = runner
    }

    public func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        var lastError: String?
        for browser in browserNames(instances) {
            let script = MeetScripts.appleScript(browser: browser, javascript: MeetScripts.probeJS())
            do {
                let response = try runner.run(script)
                guard response.count == 2 else { continue }
                let chars = Array(response)
                return .target(ProbeResult(
                    browser: browser,
                    micMuted: chars[0] == "1",
                    cameraOff: chars[1] == "1"
                ))
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }

    public func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        var lastError: String?
        for browser in browserNames(instances) {
            do {
                let response = try runner.run(
                    MeetScripts.appleScript(browser: browser, javascript: MeetScripts.toggleJS(action))
                )
                if response == "OK" { return .performed }
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }

    /// Browser names in the order their Instances appear, without repeats.
    /// Two Instances of one browser are a single question to AppleScript — it
    /// has no way to tell them apart, so asking twice would only cost time.
    private func browserNames(_ instances: [BrowserInstance]) -> [String] {
        var seen = Set<String>()
        return instances.compactMap { instance in
            seen.insert(instance.browser.name).inserted ? instance.browser.name : nil
        }
    }
}
```

Zastąp treść `Sources/TrikiMuteCore/MeetController.swift`, zachowując
w nim istniejące deklaracje `ScriptRunner`, `ProbeResult`, `ActionOutcome`
i `ProbeOutcome` bez żadnej zmiany — zmienia się wyłącznie sam
`MeetController` na końcu pliku:

```swift
/// Controls the microphone and camera in the Target.
///
/// A facade over two backends. The primary one addresses Instances by process
/// and is the reason this type stopped talking to AppleScript directly; the
/// fallback is the old name-addressed path, kept for a failure only the primary
/// can have (see ADR-0003).
public struct MeetController {
    private let primary: any MeetBackend
    private let fallback: (any MeetBackend)?

    public init(primary: any MeetBackend, fallback: (any MeetBackend)? = nil) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Looks for the Target across the given Instances.
    ///
    /// The fallback runs on `.failed` and on nothing else. `.noTarget` means the
    /// primary path already searched every Instance and found no call — the
    /// fallback searches a subset of the same browsers, so it cannot find
    /// anything the primary missed, and asking it would add an Apple Event per
    /// browser to every probe tick in the app's most common state.
    public func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        let outcome = primary.probe(instances: instances)
        guard case .failed = outcome, let fallback else { return outcome }
        return fallback.probe(instances: instances)
    }

    /// Performs an Action in the first Instance that has a Target. Falls back
    /// under the same rule as `probe(instances:)`, and with the same caveat —
    /// the fallback cannot choose an Instance, so if a call is running in more
    /// than one, it may click in the wrong one (see `docs/follow-ups.md`).
    public func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        let outcome = primary.perform(action, instances: instances)
        guard case .failed = outcome, let fallback else { return outcome }
        return fallback.perform(action, instances: instances)
    }
}
```

Dodaj też most przejściowy, żeby każdy commit na gałęzi się budował — bez
niego `AppState` i kilkanaście miejsc w `AppStateTests` przestają się
kompilować aż do Task 5. Task 5 kasuje go razem z resztą migracji:

```swift
extension MeetController {
    /// Temporary bridge for call sites still written against the old shape,
    /// removed in the task that migrates `AppState`. Exists so that every
    /// commit on this branch builds — a broken intermediate commit would
    /// make `git bisect` useless across exactly the range where the risky
    /// change lands.
    @available(*, deprecated, message: "Przejdź na MeetController(primary:fallback:)")
    public init(runner: any ScriptRunner) {
        self.init(primary: AppleScriptMeetBackend(runner: runner), fallback: nil)
    }
}
```

Stare wywołania w `AppState.swift` (`controller.probe(browsers:)` i
`controller.perform(_:browsers:)`) nadal nie mają dopasowanej sygnatury, więc
w tym samym kroku dopisz w `AppState.swift` przejściowe wyliczenie Instancji
z dzisiejszej listy nazw — jedna linia w każdym z dwóch miejsc wywołania:

```swift
        let instances = BrowserOrdering.ordered(
            BrowserOrder.ordered().compactMap { name in
                BrowserOrdering.supported.first { $0.name == name }
                    .map { BrowserInstance(pid: 0, browser: $0, isActive: false) }
            },
            supported: BrowserOrdering.supported
        )
```

i zamień `browsers: browsers` na `instances: instances` w obu wywołaniach
`controller`. `pid: 0` jest tu bez znaczenia — ścieżka zapasowa adresuje
przeglądarki nazwami, a ścieżka podstawowa dochodzi dopiero w Task 4.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS — cały pakiet, łącznie z niezmienionymi `AppStateTests`.
Gałąź buduje się w całości.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMuteCore/AppleScriptMeetBackend.swift Sources/TrikiMuteCore/MeetController.swift Tests/TrikiMuteCoreTests/MeetControllerTests.swift
git commit -m "refactor(core): rozbij MeetController na fasadę i dwa backendy"
```

---

### Task 4: ScriptingBridge — produkcyjny dostęp do Instancji

Jedyne miejsce w kodzie, które wie o ScriptingBridge. Cienkie z założenia:
im mniej tu logiki, tym mniej rzeczy, których nie da się przetestować bez
prawdziwej przeglądarki.

**Files:**
- Create: `Sources/TrikiMute/ScriptingBridgeBrowsers.swift`
- Create: `Sources/TrikiMute/RunningBrowsers.swift`

`BrowserOrder.swift` **zostaje nietknięty w tym zadaniu**, mimo że
`RunningBrowsers` przejmuje jego rolę: opiera się na nim jeszcze most
przejściowy z Task 3. Kasuje go Task 5, razem z resztą mostu.

**Interfaces:**
- Consumes: `BrowserAccess`, `BrowserTab`, `BrowserInstance`, `BrowserOrdering`
  (Tasks 1-2)
- Produces: `ScriptingBridgeBrowsers()` (implementuje `BrowserAccess`),
  `RunningBrowsers.instances() -> [BrowserInstance]`

**Uwagi zweryfikowane spike'em — nie zgaduj tutaj:**

1. `SBApplication` odpowiada na selektory dynamicznie, więc `as?` na protokół
   `@objc` zwróci `nil`. Trzeba `unsafeBitCast`.
2. `sendMode` ma typ `AESendMode` (czyli `Int32`) — `AESendMode(kAEWaitReply)`.
   Zapis z nawiasami klamrowymi (`[.waitForReply]`) **nie kompiluje się**.
3. `timeout` liczy się w tickach po 1/60 sekundy, więc 5 sekund to `5 * 60`.
4. **Delegat nie łapie wszystkich błędów.** Dla procesu, którego nie ma,
   `SBApplication` zwraca obiekt, `windows()` daje `nil`, a
   `eventDidFail(_:withError:)` **nie zostaje wywołany** — błąd trafia wyłącznie
   do logu systemowego. Dlatego `nil` z `windows()` też musi być traktowane jako
   awaria, inaczej powstaje dokładnie ta „awaria udająca brak Celu", której cała
   ta baza kodu unika.
5. `SBApplication.delegate` jest deklarowany jako `assign`, czyli **nie trzyma
   delegata przy życiu**. `ErrorTrap` musi więc mieć silnego właściciela na cały
   czas zadawania pytań — dlatego jest zmienną lokalną `tabs(in:)` i polem
   każdego zwróconego `ScriptingBridgeTab`. Zwolniony przedwcześnie, cichnie
   dokładnie w chwili, w której jest potrzebny.

- [ ] **Step 1: Write the failing test**

Ten typ rozmawia z systemem, więc test jednostkowy pokrywa tylko tę część,
która systemu nie dotyka: rozpoznawanie obsługiwanych przeglądarek wśród
działających aplikacji. Reszta jest sprawdzana na sprzęcie w Task 6.

```swift
// Tests/TrikiMuteTests/RunningBrowsersTests.swift
import Foundation
import Testing
import TrikiMuteCore
@testable import TrikiMute

// The tuple type has to be spelled with its labels — an array of unlabelled
// tuples is a different type in Swift and won't convert on its own.
private typealias RunningApp = (bundleID: String?, pid: pid_t, isActive: Bool)

@Test func recognizesSupportedBrowsersAmongRunningApplications() {
    // The mapping under test: bundle identifier in, SupportedBrowser out,
    // everything else ignored. No NSWorkspace involved.
    let running: [RunningApp] = [
        (bundleID: "com.apple.finder", pid: 500, isActive: false),
        (bundleID: "com.google.Chrome", pid: 1450, isActive: true),
        (bundleID: nil, pid: 700, isActive: false),
        (bundleID: "com.brave.Browser", pid: 1445, isActive: false),
        (bundleID: "com.google.Chrome", pid: 38259, isActive: false),
    ]
    let instances = RunningBrowsers.instances(from: running)
    #expect(instances.map(\.pid) == [1450, 1445, 38259])
    #expect(instances.first?.browser.name == "Google Chrome")
    #expect(instances.first?.isActive == true)
}

@Test func ordersRecognizedInstancesByTheSharedRule() {
    // Active first, then Chrome before Brave, then ascending pid — the same
    // ordering BrowserOrderingTests pins down, applied here end to end.
    let running: [RunningApp] = [
        (bundleID: "com.google.Chrome", pid: 38259, isActive: false),
        (bundleID: "com.brave.Browser", pid: 1445, isActive: true),
        (bundleID: "com.google.Chrome", pid: 1450, isActive: false),
    ]
    #expect(RunningBrowsers.instances(from: running).map(\.pid) == [1445, 1450, 38259])
}

@Test func ignoresApplicationsThatArentSupportedBrowsers() {
    let running: [RunningApp] = [(bundleID: "com.apple.Safari", pid: 800, isActive: true)]
    #expect(RunningBrowsers.instances(from: running).isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter RunningBrowsersTests`
Expected: FAIL — `cannot find 'RunningBrowsers' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/TrikiMute/RunningBrowsers.swift
import AppKit
import TrikiMuteCore

/// Finds the Instances of supported browsers that are running right now.
///
/// Replaces `BrowserOrder`: the app no longer asks "which browsers do we know
/// about, and which is frontmost", but "which processes are there, and in what
/// order should they be searched".
enum RunningBrowsers {
    /// Reads `NSWorkspace`. Call on the main thread — the same rule the old
    /// `BrowserOrder.ordered()` followed, and for the same reason: `AppState`
    /// resolves this before handing work to the background script queue.
    @MainActor
    static func instances() -> [BrowserInstance] {
        instances(from: NSWorkspace.shared.runningApplications.map {
            ($0.bundleIdentifier, $0.processIdentifier, $0.isActive)
        })
    }

    /// The pure half, split out so it can be tested without a real workspace.
    static func instances(
        from running: [(bundleID: String?, pid: pid_t, isActive: Bool)]
    ) -> [BrowserInstance] {
        let supported = BrowserOrdering.supported
        let recognized = running.compactMap { app -> BrowserInstance? in
            guard let bundleID = app.bundleID,
                  let browser = supported.first(where: { $0.bundleID == bundleID })
            else { return nil }
            return BrowserInstance(pid: app.pid, browser: browser, isActive: app.isActive)
        }
        return BrowserOrdering.ordered(recognized, supported: supported)
    }
}
```

```swift
// Sources/TrikiMute/ScriptingBridgeBrowsers.swift
import AppKit
import ScriptingBridge
import TrikiMuteCore

/// Minimal ScriptingBridge declarations for Chrome and Brave.
///
/// The names come from the browsers' scripting dictionaries (`sdef`): the
/// `execute` command with a `javascript` parameter generates the selector
/// `executeJavascript:` on the tab class. A typo here is not a compile error —
/// it's a silent runtime failure — which is why these declarations live in one
/// small file and why Task 6 tests them against a live browser.
@objc private protocol ScriptableTab {
    @objc optional var URL: String { get }
    @objc optional func executeJavascript(_ javascript: String) -> Any
}

@objc private protocol ScriptableWindow {
    @objc optional func tabs() -> SBElementArray
}

@objc private protocol ScriptableBrowser {
    @objc optional func windows() -> SBElementArray
}

/// Reads tabs out of a specific browser process.
///
/// This is the whole point of the exercise: `SBApplication(processIdentifier:)`
/// addresses one process, where `tell application "Google Chrome"` addresses
/// whichever process the system picks (ADR-0003).
final class ScriptingBridgeBrowsers: NSObject, BrowserAccess {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Apple Events time out after this many ticks of 1/60 s — 5 seconds, the
    /// same bound the AppleScript path used, so a hung browser still surfaces
    /// as a failure instead of blocking the script queue.
    private static let timeoutTicks = 5 * 60

    func tabs(in instance: BrowserInstance) throws -> [any BrowserTab] {
        guard let app = SBApplication(processIdentifier: instance.pid) else {
            throw Failure(message: "Nie udało się połączyć z \(instance.browser.name) (proces \(instance.pid))")
        }
        let trap = ErrorTrap()
        app.delegate = trap
        app.timeout = Self.timeoutTicks
        app.sendMode = AESendMode(kAEWaitReply)

        let browser = unsafeBitCast(app, to: ScriptableBrowser.self)
        // A nil answer is not "no windows" — it's "the question didn't get
        // through". Verified with a spike: for a process that no longer exists,
        // ScriptingBridge returns nil here and never calls the delegate, so
        // trusting nil would let a dead Instance read as an empty one.
        guard let windows = browser.windows?() else {
            throw trap.failure(browser: instance.browser.name)
                ?? Failure(message: "\(instance.browser.name) nie odpowiedział na pytanie o okna")
        }

        var result: [any BrowserTab] = []
        for window in windows {
            let scriptableWindow = unsafeBitCast(window as AnyObject, to: ScriptableWindow.self)
            guard let tabs = scriptableWindow.tabs?() else { continue }
            for tab in tabs {
                let scriptableTab = unsafeBitCast(tab as AnyObject, to: ScriptableTab.self)
                guard let url = scriptableTab.URL else { continue }
                result.append(ScriptingBridgeTab(tab: scriptableTab, url: url, trap: trap, browser: instance.browser.name))
            }
        }
        if let failure = trap.failure(browser: instance.browser.name) { throw failure }
        return result
    }
}

/// One tab, reached through ScriptingBridge.
private struct ScriptingBridgeTab: BrowserTab {
    fileprivate let tab: ScriptableTab
    let url: String
    fileprivate let trap: ErrorTrap
    let browser: String

    func execute(_ javascript: String) throws -> String {
        trap.reset()
        let answer = tab.executeJavascript?(javascript)
        if let failure = trap.failure(browser: browser) { throw failure }
        guard let text = answer as? String else {
            // The same posture the AppleScript runner takes: a missing string
            // is an anomaly, not an answer. Returning "NONE" here would let a
            // browser with JavaScript-from-Apple-Events disabled masquerade as
            // a browser with no call in it.
            throw ScriptingBridgeBrowsers.Failure(
                message: "\(browser) nie zwrócił wyniku JavaScriptu — sprawdź "
                    + "View → Developer → Allow JavaScript from Apple Events"
            )
        }
        return text
    }
}

/// Catches Apple Event failures, which ScriptingBridge otherwise swallows.
///
/// Without this, revoked Automation permission would surface as a nil answer,
/// i.e. as "no call in progress" — a failure wearing the mask of a correct
/// reading, which this codebase treats as the worst possible outcome.
private final class ErrorTrap: NSObject, SBApplicationDelegate {
    private var lastError: (any Error)?

    func reset() { lastError = nil }

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        lastError = error
        return nil
    }

    /// Translates the trapped error into the app's own failure type, naming the
    /// two causes worth telling apart by hand: `-1743` is refused Automation
    /// permission, `-600`/`-609` mean the process went away mid-question.
    func failure(browser: String) -> ScriptingBridgeBrowsers.Failure? {
        guard let lastError else { return nil }
        let code = (lastError as NSError).code
        switch code {
        case -1743:
            return .init(message: "Brak zgody na sterowanie \(browser) — włącz ją w Ustawieniach systemowych → Prywatność i ochrona → Automatyzacja")
        case -600, -609:
            return .init(message: "\(browser) przestał działać w trakcie sprawdzania")
        default:
            return .init(message: "\(browser): błąd Apple Events \(code)")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS — cały pakiet, w tym 3 nowe testy `RunningBrowsersTests`.
Gałąź nadal buduje się w całości: most przejściowy z Task 3 wciąż stoi i wciąż
korzysta z `BrowserOrder`, którego to zadanie nie rusza.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMute/ScriptingBridgeBrowsers.swift Sources/TrikiMute/RunningBrowsers.swift Tests/TrikiMuteTests/RunningBrowsersTests.swift
git commit -m "feat(app): adresuj przeglądarki po procesie przez ScriptingBridge"
```

---

### Task 5: Wpięcie w `AppState`

Najmniejsza możliwa zmiana w `AppState`: ta sama forma wstrzykiwania, ta sama
kolejność wątków, tylko lista nazw przeglądarek ustępuje liście Instancji.

**Files:**
- Modify: `Sources/TrikiMute/AppState.swift` (pola i inicjalizator ~linie 68-85
  i 270-284; wywołania w `perform(_:)` ~568-571 i `refreshTarget()` ~1025-1029)
- Modify: `Sources/TrikiMuteCore/MeetController.swift` (kasowany most przejściowy
  z Task 3 — `init(runner:)` wraz z jego `@available(*, deprecated)`)
- Modify: `Tests/TrikiMuteTests/AppStateTests.swift`

Most przejściowy z Task 3 znika w tym zadaniu w całości: skasuj rozszerzenie
`MeetController` z `init(runner:)` oraz przejściowe wyliczanie Instancji
z nazw, które Task 3 wstawił w `perform(_:)` i `refreshTarget()`. Po tym
zadaniu w kodzie nie może zostać żadne odwołanie do `BrowserOrder` — ten typ
został skasowany w Task 4.

**Interfaces:**
- Consumes: `MeetController(primary:fallback:)`, `ScanningMeetBackend(access:)`,
  `AppleScriptMeetBackend(runner:)`, `ScriptingBridgeBrowsers()`,
  `RunningBrowsers.instances()`, `BrowserInstance` (Tasks 1-4)
- Produces: `AppState(connection:controller:scriptQueue:now:browserInstances:)`

- [ ] **Step 1: Write the failing test**

W `Tests/TrikiMuteTests/AppStateTests.swift` zastąp stałą `testBrowserOrder`:

```swift
/// Fixed stand-in for `RunningBrowsers.instances()`, passed to every `AppState`
/// built in this file. Without it, `AppState` would fall back to its production
/// default and read the real `NSWorkspace` — whichever browsers happen to be
/// running while the suite runs would then reorder this list out from under the
/// tests, and any assertion that depends on which browser answered first (e.g.
/// `ProbeResult.browser`) would fail or pass for a reason that has nothing to do
/// with what it's testing. See `docs/follow-ups.md`.
private let testBrowserInstances = [
    BrowserInstance(
        pid: 1450,
        browser: SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome"),
        isActive: false
    ),
    BrowserInstance(
        pid: 1445,
        browser: SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave Browser"),
        isActive: false
    ),
]
```

Następnie trzy mechaniczne zamiany w całym pliku:

1. Każde `browserOrder: { testBrowserOrder }` → `browserInstances: { testBrowserInstances }`.
2. Każde `MeetController(runner: runner)` → `MeetController(primary: AppleScriptMeetBackend(runner: runner), fallback: nil)`,
   a każde `MeetController(runner: FakeRunner([]))` →
   `MeetController(primary: AppleScriptMeetBackend(runner: FakeRunner([])), fallback: nil)`.
   Zachowanie tych testów się nie zmienia: `AppleScriptMeetBackend` robi dokładnie
   to, co robił dotąd `MeetController`, więc zaprogramowane odpowiedzi
   `FakeRunner` (`"10"`, `"OK"`, `"THROW"`) znaczą to samo co przedtem.
3. W teście `probeHonorsInjectedBrowserOrderNotJustProductionDefault`
   (ok. linii 216) zamień odwróconą listę nazw na odwróconą listę Instancji,
   a asercję `#expect(reversedOrder != BrowserOrder.all)` — na porównanie
   z nową listą, bo `BrowserOrder` przestał istnieć:

```swift
    let reversedInstances = Array(testBrowserInstances.reversed())
    #expect(reversedInstances.map(\.browser) != BrowserOrdering.supported)
```

a wywołanie `AppState(...)` w tym teście — na `browserInstances: { reversedInstances }`.

Dodaj jeden nowy test pilnujący, że Instancje docierają do kontrolera.
Atrapa kolejki w tym pliku nazywa się `TestQueue` i ma metodę `flush()`:

```swift
@Test @MainActor func probePassesTheInjectedInstancesToTheController() {
    // The wiring under test: whatever RunningBrowsers would have produced is
    // what the controller gets, resolved on the main thread before the work
    // hops to the script queue.
    let connection = FakeDeviceConnection()
    let queue = TestQueue()
    let backend = RecordingBackend(probe: .noTarget)
    let state = AppState(
        connection: connection,
        controller: MeetController(primary: backend, fallback: nil),
        scriptQueue: queue,
        browserInstances: { testBrowserInstances }
    )
    connection.onState?(.armed)
    queue.flush()
    #expect(backend.seenInstances == [testBrowserInstances])
    // Silences the unused-variable warning; `state` has to stay alive for the
    // probe it kicked off to reach the queue at all.
    _ = state.targetDescription
}
```

wraz z atrapą backendu:

```swift
/// Backend that records the Instances it was handed.
private final class RecordingBackend: MeetBackend {
    private let probeOutcome: ProbeOutcome
    private(set) var seenInstances: [[BrowserInstance]] = []

    init(probe: ProbeOutcome) { probeOutcome = probe }

    func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        seenInstances.append(instances)
        return probeOutcome
    }

    func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        seenInstances.append(instances)
        return .noTarget
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AppStateTests`
Expected: FAIL — `AppState` nie ma parametru `browserInstances`.

- [ ] **Step 3: Write minimal implementation**

W `AppState.swift` zamień pole `browserOrder` wraz z jego komentarzem na:

```swift
    /// Source of the Instances to search, injected so tests can supply a fixed
    /// list instead of `RunningBrowsers.instances()` reading the real
    /// `NSWorkspace` — a test run with a browser frontmost would otherwise see
    /// the list reorder out from under it and fail for a reason that has
    /// nothing to do with what it's testing (see `docs/follow-ups.md`).
    /// Production default is `RunningBrowsers.instances()`, called
    /// synchronously at each call site, on the main thread, before dispatching
    /// to `scriptQueue`.
    private let browserInstances: () -> [BrowserInstance]
```

W inicjalizatorze zamień dwa parametry:

```swift
        controller: MeetController = MeetController(
            primary: ScanningMeetBackend(access: ScriptingBridgeBrowsers()),
            fallback: AppleScriptMeetBackend(runner: AppleScriptRunner())
        ),
```

```swift
        browserInstances: @escaping () -> [BrowserInstance] = { RunningBrowsers.instances() }
```

oraz przypisanie `self.browserOrder = browserOrder` na
`self.browserInstances = browserInstances`.

W `perform(_:)` zamień dwie linie:

```swift
        // NSWorkspace is still queried on the main thread here (in production;
        // see the `browserInstances` doc comment for the injected-default shape).
        let instances = browserInstances()
        let controller = self.controller
        scriptQueue.run(
            background: { controller.perform(action, instances: instances) },
```

W `refreshTarget()` analogicznie:

```swift
        let instances = browserInstances()
        let controller = self.controller
        connection.readRSSI()
        scriptQueue.run(
            background: { controller.probe(instances: instances) },
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS — cały pakiet, wszystkie testy obu celów.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMute/AppState.swift Tests/TrikiMuteTests/AppStateTests.swift
git commit -m "feat(app): przekazuj Instancje przeglądarek do kontrolera Meet"
```

---

### Task 6: Sprawdzenie na sprzęcie i domknięcie dokumentacji

Testy jednostkowe nie mogą wykryć literówki w nazwie selektora `@objc` ani
tego, czy zgody Automation działają dla podpisanej aplikacji. To zadanie jest
jedynym dowodem, że rzecz faktycznie działa — bez niego zmiana pozostaje
niezweryfikowana, dokładnie jak nieudana naprawa opisana w `follow-ups.md`.

**Files:**
- Modify: `docs/follow-ups.md` (sekcja „Potwierdzone na żywym sprzęcie")
- Modify: `README.md` (sekcja „Jak to działa")

- [ ] **Step 1: Zbuduj i uruchom aplikację**

```bash
./scripts/build-app.sh release
open build/TrikiMute.app
```

Nigdy nie uruchamiaj binarki wprost z terminala — odziedziczy zgody terminala
i wynik całego tego zadania będzie bezwartościowy (patrz README).

- [ ] **Step 2: Odtwórz usterkę, która to wszystko wywołała**

1. Otwórz rozmowę Meet w swojej zwykłej przeglądarce.
2. Uruchom drugą instancję Chrome z osobnym katalogiem danych:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir=/tmp/trikimute-druga-instancja about:blank &
```

3. Sprawdź w menu aplikacji, że Cel jest widoczny (wiersz rozmowy pokazuje stan
   mikrofonu, nie „Brak Celu").
4. Naciśnij przycisk Kapsla i potwierdź, że wycisza się **rozmowa**, a nie nic.

Kryterium: przed tą zmianą krok 3 pokazywał „Brak Celu". Jeśli nadal pokazuje,
zatrzymaj się — coś jest nie tak z wiązaniem ScriptingBridge, a nie z resztą.

- [ ] **Step 3: Sprawdź, że awaria nie udaje braku Celu**

1. Ustawienia systemowe → Prywatność i ochrona → Automatyzacja → wyłącz zgodę
   TrikiMute na sterowanie Chrome.
2. Zaczekaj jeden takt sondy (3 s) i otwórz menu.

Kryterium: menu mówi „Nie mogę sprawdzić Celu: …", a ikona w pasku to znak
zapytania — **nie** „Brak Celu". To jest test, dla którego istnieje `ErrorTrap`;
jeśli tu zobaczysz „Brak Celu", pułapka na błędy nie działa i nie wolno tego
zadania uznać za zrobione.

3. Włącz zgodę z powrotem i potwierdź, że Cel wraca.

- [ ] **Step 4: Posprzątaj po teście**

```bash
rm -rf /tmp/trikimute-druga-instancja
```

- [ ] **Step 5: Zapisz wynik w dokumentacji**

W `docs/follow-ups.md`, w sekcji „Potwierdzone na żywym sprzęcie", dopisz punkt:

```markdown
- Cel znajdowany w drugiej instancji Chrome (uruchomionej z osobnym
  `--user-data-dir`), z Akcją wykonaną we właściwej rozmowie. Odtworzona
  najpierw sama usterka, dla pewności, że test sprawdza to, co ma sprawdzać.
- Cofnięta zgoda na Automatyzację daje „Nie mogę sprawdzić Celu", nie „Brak
  Celu" — pułapka na błędy ScriptingBridge działa.
```

W `README.md`, w sekcji „Jak to działa", dopisz akapit:

```markdown
**Wiele instancji przeglądarki.** Aplikacja szuka rozmowy w każdym działającym
procesie Chrome i Brave z osobna, nie w „tej jednej", którą wybrałby system —
więc druga instancja uruchomiona przez narzędzie automatyzujące albo osobnym
poleceniem nie przesłania Ci rozmowy. Kolejność szukania: przeglądarka na
wierzchu, potem Chrome przed Brave, potem starszy proces.
```

- [ ] **Step 6: Commit**

```bash
git add docs/follow-ups.md README.md
git commit -m "docs: potwierdź na sprzęcie szukanie Celu we wszystkich instancjach"
```

---

## Kolejność i zależności

Zadania 1 → 2 → 3 → 4 → 5 → 6, sekwencyjnie. Zadania 2 i 3 dają się pisać
równolegle po Zadaniu 1 (dzielą tylko `MeetBackend` z Zadania 2), ale Zadanie 5
wymaga ukończenia 3 i 4, a Zadanie 6 — kompletu.

**Każdy commit na gałęzi musi się budować i mieć zielone testy.** Zadanie 3
stawia w tym celu most przejściowy (`MeetController.init(runner:)` plus
wyliczenie Instancji z nazw w `AppState`), Zadanie 4 zostawia go nietkniętym,
a Zadanie 5 kasuje go w całości razem z `BrowserOrder`. Nie kasuj mostu
wcześniej i nie zostawiaj go po Zadaniu 5.
