# Odporność na wiele instancji przeglądarki

Aplikacja przestaje pytać system „która to jest Chrome" i zaczyna pytać każdy
żywy proces Chrome i Brave z osobna, po jego identyfikatorze. Dzięki temu Cel
otwarty w drugiej instancji przeglądarki przestaje być niewidzialny.

## Problem

`MeetScripts.appleScript` adresuje przeglądarkę nazwą — `tell application
"Google Chrome"` — czyli w praktyce jej identyfikatorem pakietu. Gdy działa
więcej niż jeden proces o tym samym identyfikatorze, system wybiera jeden z nich
i nie ma sposobu, żeby wskazać inny. Aplikacja odpytuje wtedy instancję, której
użytkownik w ogóle nie ma na myśli.

Zdiagnozowane na żywo 2026-08-17. Chrome uruchomiony przez Playwright MCP
z własnym `--user-data-dir` przechwycił wszystkie Apple Events; rozmowa Meet
siedziała w normalnej przeglądarce użytkownika, a sonda widziała wyłącznie
jedną zakładkę `localhost` z instancji narzędziowej i uczciwie raportowała
brak Celu. Nic w kodzie nie było zepsute — zepsute było założenie, że nazwa
aplikacji identyfikuje proces.

Zjawisko nie jest egzotyczne: dowolne narzędzie automatyzujące przeglądarkę
(Playwright, Puppeteer, Selenium), drugi profil uruchomiony osobnym poleceniem
albo równolegle działający kanał wydawniczy dają ten sam efekt.

## Rozwiązanie

`SBApplication(processIdentifier:)` z ScriptingBridge adresuje **konkretny
proces**, a nie „aplikację o tym identyfikatorze pakietu". Aplikacja przechodzi
po wszystkich żywych procesach Chrome i Brave, w każdym szuka zakładki
z `meet.google.com` i działa na pierwszej, która ma komplet przycisków.

To nie jest zmiana decyzji z ADR-0002: nadal rozmawiamy z przeglądarką przez
Apple Events i nadal klikamy przycisk w DOM. Zmienia się wyłącznie API, którym
te zdarzenia wysyłamy — z `NSAppleScript` na ScriptingBridge — bo tylko ono
potrafi wskazać adresata po identyfikatorze procesu.

### Zweryfikowane przed napisaniem tego dokumentu

Spike na żywych przeglądarkach, nie lektura dokumentacji:

- `SBApplication(processIdentifier:)` zwraca obiekt związany z konkretnym
  procesem; Brave (pid 1445) i Chrome (pid 1450) dały rozdzielne listy zakładek.
- `executeJavascript` działa i zwraca wartość — w obu przeglądarkach.
- Przy okazji domknięte pytanie zostawione otwarte w ADR-0002: **Brave ma
  działający przełącznik „Allow JavaScript from Apple Events"**, więc plan
  awaryjny w postaci rozszerzenia nie jest dla Brave potrzebny.

Niezweryfikowane i świadomie zostawione planowi implementacji: zachowanie
uprawnień Automation dla podpisanej aplikacji (spike działał na uprawnieniach
terminala) oraz raportowanie błędów przez `SBApplicationDelegate`.

## Architektura

### Seam

W `TrikiMuteCore`, bez importu ScriptingBridge — czysty kod, testowalny bez
przeglądarki:

```swift
public struct BrowserInstance: Equatable, Sendable {
    public let pid: pid_t
    public let name: String       // "Google Chrome"
    public let isActive: Bool
}

public protocol BrowserTab {
    var url: String { get }
    func execute(_ javascript: String) throws -> String
}

public protocol BrowserAccess {
    func instances() -> [BrowserInstance]
    func tabs(in instance: BrowserInstance) throws -> [BrowserTab]
}
```

Produkcyjna implementacja `ScriptingBridgeBrowsers` mieszka w targecie aplikacji
i jest cienka: `NSWorkspace.runningApplications` → filtr po identyfikatorze
pakietu → `SBApplication(processIdentifier:)` → `unsafeBitCast` na deklaracje
`@objc`. Logika wyboru zostaje po czystej stronie granicy.

To jest wprost zysk na testowalności. Dzisiejsza atrapa `ScriptRunner` zwraca
napis udający odpowiedź AppleScriptu, więc testy sprawdzają parsowanie, a nie
wybór karty. Atrapa `BrowserAccess` opisuje układ instancji i zakładek, czyli
dokładnie to, co w tej usterce zawiodło.

### Dwa backendy

```swift
public protocol MeetBackend {
    func probe() -> ProbeOutcome
    func perform(_ action: MeetAction) -> ActionOutcome
}
```

`ScriptingBridgeBackend` jest pierwszy, `AppleScriptBackend` — dzisiejszy kod,
bez zmian w zachowaniu — jest zapasem na wypadek niespodzianki z uprawnieniami
albo z ScriptingBridge. `MeetController` staje się fasadą nad oboma.

**Fallback rusza wyłącznie przy `.failed`, nigdy przy `.noTarget`.** To nie jest
optymalizacja, tylko warunek sensowności zapasu: skoro pierwsza ścieżka
przeszukała wszystkie instancje i nie znalazła Celu, to druga przeszuka ich
podzbiór i tym bardziej go nie znajdzie. Wołanie jej przy `.noTarget`
kosztowałoby ruch Apple Events przy każdym takcie sondy — a stan „uzbrojony,
brak rozmowy" jest najczęstszy — nie zmieniając wyniku.

### Obsługa błędów

Największe ryzyko całej zmiany. `SBApplication` domyślnie **połyka** błędy
Apple Events: przy cofniętej zgodzie na Automatyzację zwraca `nil`, zamiast
dać znać o błędzie. Bez przeciwdziałania `-1743` zamieniłoby się w ciche „brak
Celu", czyli w awarię udającą poprawną odpowiedź — dokładnie to, przed czym
bronią się komentarze w `MeetController` i `AppleScriptRunner` i co ta baza kodu
konsekwentnie traktuje jako niedopuszczalne.

Wymagania:

- `SBApplicationDelegate` z `eventDidFail(_:withError:)` mapujący błąd na
  `.failed` z zachowaniem kodu, żeby komunikat o przyczynie (brak zgody na
  Automatyzację, wyłączony JavaScript z Apple Events) pozostał rozróżnialny.
- `timeout` ustawiony na odpowiednik dzisiejszych 5 sekund, żeby zawieszona
  przeglądarka nadal kończyła się `.failed`, a nie blokadą kolejki skryptów.
- Test pokrywający oba przypadki. Sama recenzja kodu tu nie wystarczy — historia
  tego projektu zawiera naprawę, która wyglądała poprawnie i przechodziła testy,
  a nie działała, bo opierała się na niezweryfikowanym założeniu.

### Kolejność

Zasada bez zmian — „ta, na którą patrzysz, wygrywa" — tylko schodzi poziom
niżej. Zamiast kolejności nazw przeglądarek nowa ścieżka sortuje instancje:
aktywna pierwsza, dalej kolejność systemowa; w ramach instancji zachowana
kolejność okien, czyli okno na wierzchu pierwsze.

`BrowserOrder` **zostaje**, bo obsługuje ją ścieżka zapasowa: AppleScript nadal
adresuje przeglądarki nazwami i bez tej listy nie ma czego odpytać. Wstrzykiwana
w `AppState` zależność `browserOrder: () -> [String]` również zostaje — obsługuje
fallback. Nowa ścieżka jej nie używa; zna wyłącznie identyfikatory pakietów,
bo tylko po nich rozpoznaje procesy w `NSWorkspace`.

Wynika stąd, że lista obsługiwanych przeglądarek żyje odtąd w dwóch postaciach:
nazwy dla AppleScriptu i identyfikatory pakietów dla ScriptingBridge. Plan
implementacji ma je związać w jednym miejscu, żeby dodanie trzeciej przeglądarki
nie wymagało pamiętania o dwóch listach.

## Testy

Atrapy `BrowserAccess` dają przypadki dziś nieosiągalne:

- Cel w drugiej instancji przy pierwszej bez Celu — regresja dla tej usterki.
- Błąd w pierwszej instancji, Cel w drugiej — awaria jednej instancji nie może
  zasłonić działającego Celu w innej.
- Brak Celu w żadnej instancji → `.noTarget`.
- Fallback rusza przy `.failed` i milczy przy `.noTarget`.
- Błąd zgody na Automatyzację → `.failed`, nie `.noTarget`.

## Poza zakresem

- Pokazywanie w menu, w której instancji siedzi Cel. Użytkownik ma jeden Cel
  i jedną intencję; informacja o procesie niczego mu nie ułatwia.
- „Dwie karty Meet naraz" z `follow-ups.md`. Kod będzie dotykał tego samego
  miejsca, ale to osobny problem — poczekalnia obok trwającej rozmowy — i nie
  rozwiązujemy go przy okazji.

## Ryzyko, które zostaje po wdrożeniu

`unsafeBitCast` na protokołach `@objc` jest kruchy: literówka w nazwie selektora
nie jest błędem kompilacji, tylko cichą awarią w czasie działania. Spike
potwierdził poprawność nazw dla obu przeglądarek na dzisiejszych wersjach, ale
zmiana słownika skryptowego przez Google albo Brave objawi się dopiero na
sprzęcie. Deklaracje trzymamy w jednym małym pliku, a zmianę zamyka test dymny
na żywej przeglądarce — zielona macierz testów jednostkowych tego nie wykryje.
