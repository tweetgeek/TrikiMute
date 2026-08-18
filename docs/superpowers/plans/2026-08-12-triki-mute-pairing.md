# Parowanie z wyborem urządzenia — plan implementacji

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gdy w zasięgu jest więcej niż jeden Kapsel, użytkownik wybiera właściwy z listy w pasku menu i potwierdza wybór, naciskając na nim przycisk losowo wskazaną liczbę razy.

**Architecture:** Logika liczenia naciśnięć trafia do `TrikiMuteCore` jako czysta maszyna stanów z testami. `TrikiConnection` zyskuje tryb rozpoznawania, w którym zbiera kandydatów zamiast łączyć się z pierwszym napotkanym. `AppState` kieruje zdarzenia przycisku do potwierdzania albo do Meet, zależnie od fazy.

**Tech Stack:** bez zmian — Swift 6.3, CoreBluetooth, SwiftUI `MenuBarExtra`, Swift Testing.

**Dlaczego:** dzisiejszy kod przy pierwszym parowaniu bierze **pierwsze** urządzenie, którego nazwa zawiera „triki". Reklamy BLE nie są zsynchronizowane, więc przy dwóch Kapslach wybór jest losowy. Dodatkowo `stopScan()` wykonuje się dopiero po skoku na główny wątek, więc kolejne wykrycia zdążą nadpisać zapisany identyfikator — można skończyć z zapisanym UUID jednego urządzenia, będąc połączonym z drugim.

## Global Constraints

- Zero zależności zewnętrznych. Wyłącznie API systemowe.
- Wszystkie cele używają `swiftLanguageMode(.v5)`.
- Testy w Swift Testing (`import Testing`, `@Test`, `#expect`).
- **Kod i komentarze po angielsku. Napisy widoczne w menu po polsku.** Terminologia pojęciowa według `CONTEXT.md`.
- Komunikaty commitów po angielsku, `type(scope): description`, zakres obowiązkowy.
- Tożsamość podpisu: `Apple Development: Sebastian Dawidziak`. Nigdy podpis ad-hoc.
- Zachowanie przy **jednym** Kapslu i przy zapisanym urządzeniu nie może się zmienić. To jest wymóg regresyjny: dzisiejsza ścieżka codzienna musi działać dokładnie tak samo.

**Ten plan celowo nie dyktuje ciał funkcji.** Określa interfejsy, zachowanie i przypadki testowe. Poprzedni plan podawał kompletny kod i w efekcie przeniósł do implementacji własne błędy, których wykonawcy nie mieli powodu kwestionować. Jeśli opisane tu zachowanie wydaje się błędne, zgłoś to zamiast wiernie odtwarzać.

---

### Task 1: PairingConfirmation

Czysta logika w `TrikiMuteCore`: zlicza naciśnięcia potwierdzające i rozstrzyga, czy wybór został potwierdzony, czy upłynął czas.

**Files:**
- Create: `Sources/TrikiMuteCore/PairingConfirmation.swift`
- Create: `Tests/TrikiMuteCoreTests/PairingConfirmationTests.swift`

**Interfaces:**
- Consumes: `ButtonEvent` z `Models.swift`.
- Produces:

```swift
public struct PairingConfirmation {
    public enum Outcome: Equatable, Sendable {
        case pending(remaining: Int)
        case confirmed
        case timedOut
    }

    public static let requiredRange: ClosedRange<Int>   // 2...5
    public static func randomRequirement() -> Int

    public init(required: Int, timeout: TimeInterval, startedAt: TimeInterval)
    public var required: Int { get }
    public mutating func consume(_ event: ButtonEvent, at timestamp: TimeInterval) -> Outcome
    public mutating func tick(at timestamp: TimeInterval) -> Outcome
}
```

Task 3 tworzy instancję po wybraniu urządzenia i karmi ją zdarzeniami.

**Zachowanie:**

- Liczy **wyłącznie** `ButtonEvent.press`. `hold` nie zbliża do potwierdzenia i go nie przerywa — użytkownik może przytrzymać przycisk przypadkiem, a karanie za to byłoby mylące.
- `consume` zwraca `.pending(remaining:)` z liczbą pozostałych naciśnięć, `.confirmed` gdy komplet się zebrał, `.timedOut` gdy czas minął.
- `tick` służy do wykrycia upływu czasu bez żadnego naciśnięcia. Zwraca to samo, co zwróciłoby `consume` w tej chwili, ale bez zliczania.
- Po `.confirmed` albo `.timedOut` stan jest końcowy: kolejne wywołania zwracają ten sam wynik i nie zmieniają licznika.
- Czas liczony jest od `startedAt`, monotonicznie — wywołujący podaje znacznik z tego samego źródła co reszta aplikacji (`ProcessInfo.processInfo.systemUptime`).
- `randomRequirement()` zwraca liczbę z `requiredRange`.

- [ ] **Step 1: Napisz testy**

Pokryj co najmniej te przypadki. Nazwy po angielsku, opisowe.

| Przypadek | Oczekiwanie |
|---|---|
| trzy naciśnięcia przy wymaganych trzech | kolejno `.pending(2)`, `.pending(1)`, `.confirmed` |
| przytrzymanie w trakcie | nie zmienia licznika, dalej `.pending` z tą samą wartością |
| naciśnięcie po upływie czasu | `.timedOut`, licznik bez znaczenia |
| `tick` przed upływem czasu bez naciśnięć | `.pending(required)` |
| `tick` po upływie czasu | `.timedOut` |
| wywołania po `.confirmed` | nadal `.confirmed`, licznik się nie cofa |
| wywołania po `.timedOut` | nadal `.timedOut`, nie da się „dobić" potwierdzenia |
| `randomRequirement()` wielokrotnie | zawsze w `requiredRange` |

- [ ] **Step 2: Uruchom testy i potwierdź, że nie przechodzą**

Run: `swift test --filter PairingConfirmationTests`
Expected: FAIL — typ nie istnieje. Zrzuć wyjście do pliku, nie przepisuj go ręcznie.

- [ ] **Step 3: Napisz implementację**

- [ ] **Step 4: Uruchom testy i potwierdź, że przechodzą**

Cały zestaw musi rosnąć o dokładnie tyle testów, ile dopisałeś. Zgłoś rzeczywistą liczbę.

- [ ] **Step 5: Commit**

```
feat(core): pairing confirmation by counted button presses
```

---

### Task 2: Tryb rozpoznawania w TrikiConnection

`TrikiConnection` przestaje łączyć się z pierwszym napotkanym urządzeniem. Zyskuje tryb, w którym zbiera kandydatów i oddaje ich decyzję wyżej.

**Files:**
- Modify: `Sources/TrikiMute/TrikiConnection.swift`
- Modify: `Sources/TrikiMute/DeviceConnection.swift` (protokół musi objąć nowe operacje)

**Interfaces:**
- Produces, jako uzupełnienie istniejącego `DeviceConnection`:

```swift
struct DeviceCandidate: Equatable, Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

var onCandidates: (([DeviceCandidate]) -> Void)? { get set }
func startPairing()
func choose(_ id: UUID)
func cancelPairing()
```

**Zachowanie:**

- **Ścieżka codzienna bez zmian.** Gdy w `UserDefaults` jest zapisany identyfikator, `resumeSearch()` działa dokładnie jak dziś: pobiera urządzenie i zawiesza połączenie, bez skanowania. Tryb rozpoznawania nie uruchamia się sam.
- `startPairing()` przełącza w tryb rozpoznawania i rozpoczyna skanowanie. **Nie kasuje** zapisanego identyfikatora — dopiero potwierdzony wybór go nadpisuje. Przerwane parowanie musi zostawić dotychczasowe urządzenie nietknięte.
- W trybie rozpoznawania `didDiscover` **nie łączy się i nie zapisuje niczego**. Dopisuje kandydata do zbioru i zgłasza całą listę przez `onCandidates`. Powtórne wykrycia tego samego urządzenia aktualizują siłę sygnału zamiast tworzyć duplikat.
- Lista jest posortowana malejąco po sile sygnału — najbliższe urządzenie na górze.
- `choose(_:)` zatrzymuje skanowanie, łączy się z **tym** urządzeniem i przechodzi normalną ścieżkę odkrywania usług aż do stanu uzbrojonego. Zapisany identyfikator wciąż pozostaje niezmieniony.
- Zapis identyfikatora następuje **wyłącznie** po potwierdzeniu, przez nową metodę wywoływaną z `AppState` (dobierz nazwę i umieść w protokole).
- `cancelPairing()` przerywa: zatrzymuje skanowanie, rozłącza ewentualnie wybrane urządzenie i wraca do stanu sprzed parowania — czyli do zawieszonego połączenia z zapisanym urządzeniem, jeśli takie było.
- Usuń dotychczasowe automatyczne parowanie z `didDiscover`. Jeśli nie ma zapisanego urządzenia, aplikacja **nie łączy się sama** — czeka, aż użytkownik uruchomi parowanie.
- Zachowaj bramkę z ostatniej fali poprawek: rozłączenie urządzenia, które nie jest bieżącym, nie może wywołać ponownego łączenia.

**Uwaga na pułapkę, która już raz wystąpiła.** `stopScan()` wykonywane wewnątrz skoku na główny wątek nie zatrzymuje napływu wykryć natychmiast. W trybie rozpoznawania to nieszkodliwe, bo wykrycia jedynie aktualizują listę — ale przy `choose(_:)` upewnij się, że kolejne wykrycie nie nadpisze wybranego urządzenia.

- [ ] **Step 1: Rozszerz protokół i zaimplementuj**

Testów jednostkowych tu nie ma — to granica CoreBluetooth. Sprawdzeniem jest kompilacja, przejście dotychczasowych testów i test ręczny w Task 3.

- [ ] **Step 2: Zweryfikuj brak regresji**

Run: `swift test` — musi przejść tyle testów, ile było po Task 1, bez zmian.
Run: `./scripts/build-app.sh` — kompilacja i podpis czyste.

Zrzuć oba wyjścia do plików.

- [ ] **Step 3: Commit**

```
feat(ble): discovery mode with explicit device choice
```

---

### Task 3: Parowanie w pasku menu

`AppState` prowadzi użytkownika przez parowanie, a menu je pokazuje.

**Files:**
- Modify: `Sources/TrikiMute/AppState.swift`
- Modify: `Sources/TrikiMute/MenuBarView.swift`
- Modify: `Tests/TrikiMuteTests/AppStateTests.swift`
- Modify: `docs/superpowers/specs/2026-08-12-triki-mute-design.md` (sekcja o cyklu życia połączenia)
- Modify: `README.md` (opis parowania)

**Interfaces:**
- Produces w `AppState`:

```swift
enum PairingPhase: Equatable {
    case inactive
    case searching([DeviceCandidate])
    case confirming(candidate: DeviceCandidate, remaining: Int)
    case failed(String)
}

private(set) var pairing: PairingPhase { get }
func startPairing()
func choosePairingCandidate(_ id: UUID)
func cancelPairing()
```

**Zachowanie:**

- Menu zyskuje pozycję uruchamiającą parowanie. Gdy nie ma zapisanego urządzenia, jest to naturalny pierwszy krok; gdy jest — służy do zmiany urządzenia i zastępuje dotychczasowe „Zapomnij Kapsel".
- W fazie `searching` menu wypisuje kandydatów: nazwę i siłę sygnału. Kliknięcie wybiera.
- Po wyborze aplikacja losuje wymaganą liczbę naciśnięć i pokazuje polecenie z **konkretną liczbą** oraz z liczbą pozostałych po każdym naciśnięciu. Bez tego użytkownik nie wie, czy aplikacja go słyszy.
- **W fazie potwierdzania zdarzenia przycisku nie trafiają do Meet.** Naciśnięcia potwierdzają wybór; nie wolno, żeby przy okazji wyciszały rozmowę.
- Po potwierdzeniu: zapis identyfikatora, faza wraca do `inactive`, aplikacja działa jak dotąd.
- Po upływie czasu: faza `failed` z czytelnym komunikatem po polsku, powrót do listy kandydatów.
- Parowanie musi dać się przerwać na każdym etapie, a przerwanie zostawia dotychczasowe urządzenie nietknięte.
- Sonda Meet nie ma sensu w trakcie parowania — nie odpytuj przeglądarek w tym czasie.

**Kandydat widmo — wykryte przy recenzji Task 2.** Kapsel, który przestanie się
reklamować w trakcie skanowania, zostaje na liście. Wybranie go **zawiesza
aplikację**: `connect()` w CoreBluetooth nie ma limitu czasu, nie mamy podpiętej
obsługi nieudanego połączenia, więc stan zostaje na „szukam" bez komunikatu,
a jedynym wyjściem jest przerwanie parowania.

To zadanie musi to zamknąć. Wybierz jedno z dwóch, uzasadniając wybór:
- ograniczenie czasu na połączenie z kandydatem, po którym parowanie zgłasza
  niepowodzenie i wraca do listy,
- albo usuwanie z listy kandydatów, którzy nie odezwali się od pewnego czasu,
  plus i tak jakieś ograniczenie czasu, bo urządzenie może zniknąć między
  wyświetleniem listy a kliknięciem.

Ograniczenie czasu jest konieczne w obu wariantach — samo usuwanie nieaktualnych
wpisów nie wyklucza wyścigu między wyświetleniem a kliknięciem.

**Testy** (dopisz do istniejącego zestawu, korzystając z wstrzykiwanych atrap):

| Przypadek | Oczekiwanie |
|---|---|
| naciśnięcie w fazie potwierdzania | nie wywołuje Akcji w Meet |
| komplet naciśnięć | identyfikator zapisany, faza wraca do `inactive` |
| upływ czasu | faza `failed`, identyfikator **nie** zapisany |
| przerwanie w trakcie | faza `inactive`, zapisany identyfikator bez zmian |
| naciśnięcie poza parowaniem | wywołuje Akcję jak dotąd (test regresyjny) |
| kandydat nie łączy się w zadanym czasie | faza `failed`, powrót do listy, brak zawieszenia |

- [ ] **Step 1: Napisz testy**

- [ ] **Step 2: Uruchom i potwierdź, że nie przechodzą**

- [ ] **Step 3: Zaimplementuj**

- [ ] **Step 4: Uruchom cały zestaw**

Zrzuć wyjście do pliku, zgłoś rzeczywistą liczbę.

- [ ] **Step 5: Zaktualizuj specyfikację i README**

Specyfikacja opisuje dziś parowanie jako automatyczne — popraw sekcję o cyklu życia połączenia. README zyskuje krótki opis: parowanie uruchamiasz z menu, wybierasz urządzenie z listy i potwierdzasz naciśnięciami.

- [ ] **Step 6: Test ręczny (człowiek)**

Do przeprowadzenia przez użytkownika, nie przez wykonawcę:

1. „Zapomnij"/parowanie przy jednym Kapslu — lista pokazuje jedno urządzenie, potwierdzenie działa, po nim przycisk przełącza mikrofon.
2. Wybranie urządzenia i **nienaciśnięcie** przycisku — po upływie czasu wraca komunikat i lista.
3. Przerwanie parowania w trakcie — dotychczasowe urządzenie nadal działa.
4. Jeśli dostępne są dwa Kapsle: wybranie tego dalszego i potwierdzenie naciśnięciami na nim; sprawdzenie, że aplikacja słucha właśnie jego.

- [ ] **Step 7: Commit**

```
feat(app): device pairing with list selection and press confirmation
```
