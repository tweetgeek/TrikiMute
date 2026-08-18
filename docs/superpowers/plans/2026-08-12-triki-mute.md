# TrikiMute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aplikacja macOS w pasku menu, która na naciśnięcie przycisku kontrolera BLE Triki przełącza mikrofon (krótkie naciśnięcie) albo kamerę (przytrzymanie) w rozmowie Google Meet, bez zabierania focusu bieżącej aplikacji.

**Architecture:** Jednokierunkowy łańcuch: CoreBluetooth → `FrameParser` → `ButtonRecognizer` → `MeetController` → przeglądarka. Cała logika bez efektów ubocznych żyje w bibliotece `TrikiMuteCore` i jest testowana bez sprzętu i bez przeglądarki; cel wykonawczy `TrikiMute` zawiera wyłącznie CoreBluetooth, SwiftUI i wykonawcę AppleScript. Sterowanie Meet idzie przez `execute javascript in tab`, które działa na karcie nieaktywnej.

**Tech Stack:** Swift 6.3 / SwiftUI (`MenuBarExtra`), CoreBluetooth, `NSAppleScript`, `NSSound`, `SMAppService`, Swift Testing, pakiet SPM bez `.xcodeproj`.

**Dokumenty źródłowe:** [specyfikacja](../specs/2026-08-12-triki-mute-design.md), [glosariusz](../../../CONTEXT.md), [ADR 0001](../../adr/0001-swift-zamiast-tauri.md), [ADR 0002](../../adr/0002-apple-events-zamiast-rozszerzenia.md).

## Global Constraints

- Terminologia z `CONTEXT.md` obowiązuje w nazwach typów i w komunikatach: Kapsel, Uzbrojenie, Cel, Gotowość, Naciśnięcie, Przytrzymanie, Akcja.
- Zero zależności zewnętrznych. Wyłącznie API systemowe.
- Minimalna wersja systemu: macOS 14.0 (`@Observable`). Środowisko deweloperskie: macOS 26.6.1, Swift 6.3.3.
- Identyfikator pakietu: `pl.tweetgeek.trikimute`. Nazwa: `TrikiMute`.
- Aplikacja typu accessory (`LSUIElement`) — bez ikony w Docku.
- Podpis stałą tożsamością `Apple Development: Sebastian Dawidziak` przy każdej przebudowie. Bez tego macOS unieważnia zgody na Bluetooth i Automation.
- Hardened runtime wymaga uprawnienia `com.apple.security.automation.apple-events`. Bez niego wszystkie wywołania AppleScript zwrócą błąd `-1743`.
- Oba cele używają trybu języka Swift 5 (`swiftLanguageMode(.v5)`). Ścisła współbieżność Swift 6 kłóci się z delegatami CoreBluetooth i nie wnosi tu wartości.
- Wszystkie stałe czasowe rozpoznawania przycisku żyją w jednym miejscu: `ButtonRecognizer.Tuning`.
- Selektory DOM żyją wyłącznie w `MeetScripts`. Nigdzie indziej nie wolno ich powtarzać.
- Commity po polsku, w konwencji `typ(zakres): opis`.

---

### Task 1: Spike — DOM Meet i Apple Events w obu przeglądarkach

Rozstrzyga trzy niewiadome ze specyfikacji, zanim powstanie kod, który od nich zależy. Nie produkuje kodu aplikacji — produkuje udokumentowane fakty i dwie stałe.

**Files:**
- Create: `docs/findings/2026-08-12-meet-dom.md`

**Interfaces:**
- Consumes: nic.
- Produces: potwierdzone wartości `MeetScripts.micIndex` i `MeetScripts.cameraIndex` (typ `Int`) oraz selektor `MeetScripts.buttonSelector` (typ `String`), użyte w Task 6. Potwierdzona lista nazw aplikacji dla AppleScript, użyta w Task 7.

- [ ] **Step 1: Włącz wykonywanie JavaScriptu z Apple Events w Chrome**

Otwórz Google Chrome, wejdź w `View → Developer` i zaznacz `Allow JavaScript from Apple Events`. Jeśli pozycji nie ma w menu, zanotuj to w dokumencie z ustaleniami — wtedy dla Chrome zostaje wyłącznie plan awaryjny z ADR 0002.

- [ ] **Step 2: Sprawdź, czy Brave ma ten sam przełącznik**

Otwórz Brave Browser i poszukaj `View → Developer → Allow JavaScript from Apple Events`. To główna niewiadoma tego kroku — Brave nie dokumentuje tej opcji. Zanotuj wynik.

- [ ] **Step 3: Otwórz rozmowę testową**

Wejdź na `https://meet.google.com/`, załóż nową rozmowę i dołącz do niej. Drugi uczestnik nie jest potrzebny — przyciski mikrofonu i kamery są aktywne w rozmowie jednoosobowej. Zostaw kartę otwartą i **przełącz się do innej aplikacji**, żeby test potwierdził działanie bez focusu.

- [ ] **Step 4: Zrzuć strukturę przycisków**

Uruchom w terminalu:

Cały JavaScript używa apostrofów, bo trafia do literału tekstowego AppleScript,
w którym podwójny cudzysłów rozerwałby skrypt. Z tego samego powodu łamanie
linii idzie przez `String.fromCharCode(10)` — `\n` byłoby zinterpretowane już
przez AppleScript i uszkodziło łańcuch JS.

```bash
BROWSER="Google Chrome"
cat > /tmp/triki-probe.scpt <<EOF
tell application "$BROWSER"
    if it is not running then return "PRZEGLADARKA NIE URUCHOMIONA"
    repeat with w in windows
        repeat with t in tabs of w
            if URL of t contains "meet.google.com" then
                return execute t javascript "Array.from(document.querySelectorAll('[data-is-muted]')).map(function(e,i){return i + ' muted=' + e.getAttribute('data-is-muted') + ' aria=' + (e.getAttribute('aria-label')||'-') + ' tip=' + (e.getAttribute('data-tooltip-id')||'-')}).join(String.fromCharCode(10))"
            end if
        end repeat
    end repeat
end tell
return "BRAK KARTY MEET"
EOF
osascript /tmp/triki-probe.scpt
```

Oczekiwany wynik: dwie linie, po jednej na przycisk, z indeksem, stanem i etykietą. Etykieta `aria-label` powie, który indeks to mikrofon, a który kamera.

- [ ] **Step 5: Zweryfikuj stabilność indeksów**

Wyłącz kamerę myszką, uruchom polecenie z kroku 4 ponownie i porównaj. Sprawdź, czy indeksy się nie przestawiły i czy `data-is-muted` faktycznie zmieniło wartość dla właściwego przycisku. Powtórz raz jeszcze po przeładowaniu karty (`Cmd+R` i ponowne dołączenie).

- [ ] **Step 6: Powtórz krok 4 dla Brave**

Otwórz tę samą rozmowę w Brave i uruchom ten sam blok z `BROWSER="Brave Browser"`. Jeśli krok 2 wykazał brak przełącznika, oczekuj błędu — zanotuj jego treść i numer.

- [ ] **Step 7: Zapisz ustalenia**

Utwórz `docs/findings/2026-08-12-meet-dom.md` zawierający: pełne wyjście z kroków 4–6, indeks mikrofonu, indeks kamery, wynik testu stabilności po przeładowaniu, oraz jednoznaczne stwierdzenie, czy Brave obsługuje Apple Events. Jeśli `data-is-muted` okazał się nieodpowiedni (na przykład indeksy się przestawiają), zapisz alternatywny selektor wraz z uzasadnieniem — Task 6 użyje tego, co tu zapiszesz.

- [ ] **Step 8: Commit**

```bash
git add docs/findings/2026-08-12-meet-dom.md
git commit -m "docs(spike): struktura przyciskow Meet i obsluga Apple Events w Chrome i Brave"
```

---

### Task 2: Spike — zachowanie Kapsla

Mierzy, jak długo Kapsel zostaje wybudzony i czy zasypia mimo połączenia. Używa gotowych narzędzi TrikiScope zamiast nowego kodu.

**Files:**
- Create: `docs/findings/2026-08-12-kapsel.md`

**Interfaces:**
- Consumes: nic.
- Produces: potwierdzenie, że flaga przycisku dociera w nagłówku `22 01`; zmierzone czasy, na których opiera się model Uzbrojenia w Task 8.

- [ ] **Step 1: Potwierdź, że środowisko TrikiScope działa na macOS**

```bash
~/_TweetGeek/_Projects/TrikiScope/.venv/bin/python -c "import bleak; print(bleak.__version__)"
```

Jeśli polecenie zawiedzie, utwórz środowisko od nowa:

```bash
cd ~/_TweetGeek/_Projects/TrikiScope
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

- [ ] **Step 2: Potwierdź flagę przycisku**

Naciśnij przycisk na Kapslu, żeby go wybudzić, i od razu uruchom:

```bash
cd ~/_TweetGeek/_Projects/TrikiScope && .venv/bin/python tools/probe_button.py
```

Naciskaj przycisk krótko i długo. Zanotuj, czy narzędzie wykrywa nagłówek `22 01` i czy stan trzyma się przez cały czas wciśnięcia. To weryfikuje fundament, na którym stoją Task 4 i Task 5.

- [ ] **Step 3: Zmierz czas do zaśnięcia bez połączenia**

Naciśnij przycisk, żeby wybudzić Kapsel, i uruchom skan bez łączenia:

```bash
cd ~/_TweetGeek/_Projects/TrikiScope && .venv/bin/python -m trikiscope --scan
```

Powtarzaj skan co 15 sekund i zanotuj, po jakim czasie Kapsel znika z listy. To jest okno, w którym aplikacja może zestawić połączenie po Uzbrojeniu.

- [ ] **Step 4: Zmierz zachowanie przy aktywnym połączeniu**

```bash
cd ~/_TweetGeek/_Projects/TrikiScope && .venv/bin/python -m trikiscope --auto-connect
```

Zostaw na 30 minut bez dotykania Kapsla. Zanotuj: czy połączenie przetrwało, czy strumień IMU płynął nieprzerwanie, oraz poziom baterii na starcie i na końcu (zakładka Overview). Różnica poziomów daje szacunek zużycia na godzinę ciągłego strumienia.

- [ ] **Step 5: Zapisz ustalenia**

Utwórz `docs/findings/2026-08-12-kapsel.md` z: potwierdzeniem flagi przycisku, czasem do zaśnięcia bez połączenia, wynikiem 30-minutowego testu, spadkiem baterii i wnioskiem, czy model Uzbrojenia wymaga korekty.

- [ ] **Step 6: Commit**

```bash
git add docs/findings/2026-08-12-kapsel.md
git commit -m "docs(spike): zmierzone zachowanie Kapsla - sen, wybudzanie, bateria"
```

---

### Task 3: Szkielet pakietu, skrypt budujący i ikona w pasku menu

Buduje najkrótszą ścieżkę do podpisanej, uruchamialnej aplikacji. Rozbraja infrastrukturę macOS (pakiet, `Info.plist`, uprawnienia, podpis), zanim dołoży się do niej jakakolwiek logika.

**Files:**
- Create: `Package.swift`
- Create: `Sources/TrikiMuteCore/TrikiMuteCore.swift`
- Create: `Sources/TrikiMute/TrikiMuteApp.swift`
- Create: `Sources/TrikiMute/Info.plist`
- Create: `Sources/TrikiMute/TrikiMute.entitlements`
- Create: `scripts/build-app.sh`

**Interfaces:**
- Consumes: nic.
- Produces: cele `TrikiMuteCore` (biblioteka) i `TrikiMute` (wykonywalny), używane przez wszystkie dalsze zadania. Skrypt `scripts/build-app.sh` produkujący `build/TrikiMute.app`.

To zadanie nie ma testów jednostkowych — nie ma jeszcze logiki, którą dałoby się sensownie testować, a test sprawdzający, że stała równa się samej sobie, nie weryfikuje niczego. Weryfikacją jest ręczny test w kroku 7: ikona pojawia się w pasku menu, a `codesign --verify` przechodzi. Cel testowy dochodzi do `Package.swift` w Task 4, razem z pierwszymi prawdziwymi testami.

- [ ] **Step 1: Napisz manifest pakietu**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrikiMute",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TrikiMuteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "TrikiMute",
            dependencies: ["TrikiMuteCore"],
            exclude: ["Info.plist", "TrikiMute.entitlements"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

Cel testowy celowo jeszcze nie istnieje — SPM zgłasza błąd, gdy zadeklarowany cel wskazuje na nieistniejący katalog. Dochodzi w Task 4.

- [ ] **Step 2: Dodaj minimalną zawartość biblioteki**

SPM wymaga, żeby cel miał przynajmniej jeden plik źródłowy.

`Sources/TrikiMuteCore/TrikiMuteCore.swift`:

```swift
/// Przestrzeń nazw biblioteki. Wersja protokołu Kapsla, na którym opiera się
/// `FrameParser` — podbij ją, jeśli format ramek się zmieni.
public enum TrikiMuteCore {
    public static let wersjaProtokolu = 1
}
```

- [ ] **Step 3: Napisz aplikację w pasku menu**

`Sources/TrikiMute/TrikiMuteApp.swift`:

```swift
import SwiftUI

@main
struct TrikiMuteApp: App {
    var body: some Scene {
        MenuBarExtra("TrikiMute", systemImage: "mic.slash.circle") {
            Text("TrikiMute")
            Divider()
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 4: Napisz Info.plist**

`Sources/TrikiMute/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TrikiMute</string>
    <key>CFBundleDisplayName</key>
    <string>TrikiMute</string>
    <key>CFBundleIdentifier</key>
    <string>pl.tweetgeek.trikimute</string>
    <key>CFBundleExecutable</key>
    <string>TrikiMute</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>TrikiMute łączy się z Kapslem Triki, żeby odbierać naciśnięcia przycisku.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>TrikiMute steruje mikrofonem i kamerą w rozmowie Google Meet w Twojej przeglądarce.</string>
</dict>
</plist>
```

- [ ] **Step 5: Napisz plik uprawnień**

`Sources/TrikiMute/TrikiMute.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 6: Napisz skrypt budujący**

`scripts/build-app.sh`:

```bash
#!/usr/bin/env bash
# Składa podpisany pakiet .app z produktu SPM.
# Podpis stałą tożsamością jest wymagany: macOS wiąże z nim zgody na Bluetooth
# i Automation, a podpis ad-hoc unieważnia je przy każdej przebudowie.
set -euo pipefail

CONFIG="${1:-debug}"
IDENTITY="Apple Development: Sebastian Dawidziak"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/TrikiMute.app"

cd "$ROOT"
swift build -c "$CONFIG" --product TrikiMute

BIN="$(swift build -c "$CONFIG" --product TrikiMute --show-bin-path)/TrikiMute"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TrikiMute"
cp "$ROOT/Sources/TrikiMute/Info.plist" "$APP/Contents/Info.plist"

codesign --force \
    --sign "$IDENTITY" \
    --identifier pl.tweetgeek.trikimute \
    --entitlements "$ROOT/Sources/TrikiMute/TrikiMute.entitlements" \
    --options runtime \
    "$APP"

codesign --verify --verbose=2 "$APP"
echo "Zbudowano: $APP"
```

- [ ] **Step 7: Zbuduj i uruchom**

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open build/TrikiMute.app
```

Expected: w prawym górnym rogu ekranu pojawia się ikona przekreślonego mikrofonu. Kliknięcie pokazuje menu z pozycją „Zakończ". W Docku **nie ma** ikony aplikacji. `codesign --verify` kończy się bez błędu.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources scripts
git commit -m "feat: szkielet pakietu SPM, skrypt budujacy i ikona w pasku menu"
```

---

### Task 4: FrameParser

Zamienia surowy strumień bajtów z Kapsla na stan przycisku. Czysta logika, testowana bez sprzętu.

**Files:**
- Modify: `Package.swift` (dochodzi cel testowy)
- Create: `Sources/TrikiMuteCore/Models.swift`
- Create: `Sources/TrikiMuteCore/FrameParser.swift`
- Create: `Tests/TrikiMuteCoreTests/FrameParserTests.swift`

**Interfaces:**
- Consumes: nic.
- Produces: `public struct ButtonSample: Equatable, Sendable { public let pressed: Bool; public let timestamp: TimeInterval }` oraz `public struct FrameParser { public init(); public mutating func consume(_ bytes: [UInt8], at timestamp: TimeInterval) -> [ButtonSample] }`. Task 5 konsumuje `ButtonSample`, Task 8 wywołuje `consume`.

- [ ] **Step 1: Dodaj cel testowy do Package.swift**

W tablicy `targets`, za `.executableTarget`, dopisz:

```swift
        .testTarget(
            name: "TrikiMuteCoreTests",
            dependencies: ["TrikiMuteCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
```

- [ ] **Step 2: Napisz testy**

`Tests/TrikiMuteCoreTests/FrameParserTests.swift`:

```swift
import Foundation
import Testing
@testable import TrikiMuteCore

/// Buduje jedną 14-bajtową ramkę IMU o zadanym stanie przycisku.
private func ramka(pressed: Bool) -> [UInt8] {
    [0x22, pressed ? 0x01 : 0x00] + Array(repeating: 0x00, count: 12)
}

@Test func pojedynczaRamkaDajeJedenStan() {
    var parser = FrameParser()
    let out = parser.consume(ramka(pressed: false), at: 1.0)
    #expect(out == [ButtonSample(pressed: false, timestamp: 1.0)])
}

@Test func wcisnietyPrzyciskJestRozpoznawany() {
    var parser = FrameParser()
    let out = parser.consume(ramka(pressed: true), at: 2.5)
    #expect(out == [ButtonSample(pressed: true, timestamp: 2.5)])
}

@Test func dwieSklejoneRamkiWJednymPowiadomieniu() {
    var parser = FrameParser()
    let out = parser.consume(ramka(pressed: false) + ramka(pressed: true), at: 3.0)
    #expect(out.count == 2)
    #expect(out[0].pressed == false)
    #expect(out[1].pressed == true)
}

@Test func ramkaUcietaNaGranicyPowiadomienia() {
    var parser = FrameParser()
    let pelna = ramka(pressed: true)
    let pierwsza = parser.consume(Array(pelna[0..<6]), at: 4.0)
    #expect(pierwsza.isEmpty)
    let druga = parser.consume(Array(pelna[6...]), at: 4.1)
    #expect(druga == [ButtonSample(pressed: true, timestamp: 4.1)])
}

@Test func smieciPrzedNaglowkiemSaOdrzucane() {
    var parser = FrameParser()
    let out = parser.consume([0xFF, 0xAB, 0x09] + ramka(pressed: true), at: 5.0)
    #expect(out == [ButtonSample(pressed: true, timestamp: 5.0)])
}

@Test func nieznanyNaglowekNieBlokujeStrumienia() {
    var parser = FrameParser()
    let smiec: [UInt8] = Array(repeating: 0x99, count: 40)
    _ = parser.consume(smiec, at: 6.0)
    let out = parser.consume(ramka(pressed: false), at: 6.1)
    #expect(out == [ButtonSample(pressed: false, timestamp: 6.1)])
}

@Test func buforNieRosnieWNieskonczonosc() {
    var parser = FrameParser()
    for i in 0..<200 {
        _ = parser.consume(Array(repeating: 0x99, count: 14), at: Double(i))
    }
    #expect(parser.rozmiarBufora < 64)
}
```

- [ ] **Step 3: Uruchom testy i potwierdź, że nie przechodzą**

Run: `swift test --filter FrameParserTests`
Expected: FAIL — kompilacja nie znajduje typów `FrameParser` i `ButtonSample`.

- [ ] **Step 4: Napisz model danych**

`Sources/TrikiMuteCore/Models.swift`:

```swift
import Foundation

/// Stan przycisku Kapsla odczytany z jednej ramki IMU.
public struct ButtonSample: Equatable, Sendable {
    public let pressed: Bool
    public let timestamp: TimeInterval

    public init(pressed: Bool, timestamp: TimeInterval) {
        self.pressed = pressed
        self.timestamp = timestamp
    }
}

/// Zdarzenie rozpoznane z sekwencji stanów przycisku.
public enum ButtonEvent: Equatable, Sendable {
    /// Naciśnięcie — krótkie wciśnięcie i puszczenie. Odpowiada mikrofonowi.
    case press
    /// Przytrzymanie — wciśnięcie ponad próg czasowy. Odpowiada kamerze.
    case hold
}

/// Akcja wykonywana w Celu.
public enum MeetAction: Equatable, Sendable {
    case microphone
    case camera
}
```

- [ ] **Step 5: Napisz parser**

`Sources/TrikiMuteCore/FrameParser.swift`:

```swift
import Foundation

/// Składa 14-bajtowe ramki IMU ze strumienia powiadomień BLE i wyciąga z nich
/// stan przycisku. Dane inercyjne są odrzucane — TrikiMute ich nie używa.
///
/// Kapsel nadaje burstami, więc jedno powiadomienie może zawierać wiele ramek
/// albo urwać się w połowie ramki. Parser resynchronizuje się po nagłówku.
public struct FrameParser {
    /// Długość pełnej ramki IMU w bajtach.
    private static let dlugoscRamki = 14
    /// Pierwszy bajt nagłówka. Drugi to flaga przycisku: 0x00 lub 0x01.
    private static let znacznik: UInt8 = 0x22

    private var bufor: [UInt8] = []

    public init() {}

    /// Rozmiar wewnętrznego bufora. Wyłącznie do testów odporności.
    var rozmiarBufora: Int { bufor.count }

    /// Dokłada bajty z jednego powiadomienia i zwraca stany przycisku ze
    /// wszystkich ramek, które udało się z nich złożyć.
    public mutating func consume(_ bytes: [UInt8], at timestamp: TimeInterval) -> [ButtonSample] {
        bufor.append(contentsOf: bytes)
        var wynik: [ButtonSample] = []

        while true {
            guard let start = indeksNaglowka() else {
                // Nic, co mogłoby być początkiem ramki — zachowaj tylko ogon,
                // który jeszcze może się okazać początkiem znacznika.
                if bufor.count > Self.dlugoscRamki {
                    bufor.removeFirst(bufor.count - 1)
                }
                break
            }
            if start > 0 { bufor.removeFirst(start) }
            guard bufor.count >= Self.dlugoscRamki else { break }

            wynik.append(ButtonSample(pressed: bufor[1] == 0x01, timestamp: timestamp))
            bufor.removeFirst(Self.dlugoscRamki)
        }

        return wynik
    }

    /// Indeks pierwszego bajtu, od którego może zaczynać się poprawna ramka.
    private func indeksNaglowka() -> Int? {
        for i in 0..<bufor.count where bufor[i] == Self.znacznik {
            // Drugi bajt musi być flagą przycisku. Jeśli go jeszcze nie ma,
            // czekamy na kolejne powiadomienie zamiast odrzucać znacznik.
            if i + 1 >= bufor.count { return i }
            if bufor[i + 1] == 0x00 || bufor[i + 1] == 0x01 { return i }
        }
        return nil
    }
}
```

- [ ] **Step 6: Uruchom testy i potwierdź, że przechodzą**

Run: `swift test --filter FrameParserTests`
Expected: PASS, 7 testów.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/TrikiMuteCore/Models.swift Sources/TrikiMuteCore/FrameParser.swift Tests/TrikiMuteCoreTests/FrameParserTests.swift
git commit -m "feat(core): parser ramek IMU wyciagajacy stan przycisku Kapsla"
```

---

### Task 5: ButtonRecognizer

Zamienia ciąg stanów przycisku na Naciśnięcia i Przytrzymania. Czysta logika, testowana bez sprzętu.

**Files:**
- Create: `Sources/TrikiMuteCore/ButtonRecognizer.swift`
- Create: `Tests/TrikiMuteCoreTests/ButtonRecognizerTests.swift`

**Interfaces:**
- Consumes: `ButtonSample` i `ButtonEvent` z Task 4.
- Produces: `public struct ButtonRecognizer { public struct Tuning { public let hold: TimeInterval; public let debounce: TimeInterval; public let cooldown: TimeInterval; public static let domyslne: Tuning }; public init(tuning: Tuning = .domyslne); public mutating func consume(_ sample: ButtonSample) -> ButtonEvent? }`. Task 8 wywołuje `consume` dla każdej próbki z `FrameParser`.

- [ ] **Step 1: Napisz testy**

`Tests/TrikiMuteCoreTests/ButtonRecognizerTests.swift`:

```swift
import Foundation
import Testing
@testable import TrikiMuteCore

/// Podaje rozpoznawaczowi ciąg próbek co 10 ms i zwraca wszystkie zdarzenia.
private func odtworz(
    _ recognizer: inout ButtonRecognizer,
    wcisniety: Bool,
    przez czas: TimeInterval,
    od start: TimeInterval
) -> [ButtonEvent] {
    var zdarzenia: [ButtonEvent] = []
    var t = start
    while t < start + czas {
        if let e = recognizer.consume(ButtonSample(pressed: wcisniety, timestamp: t)) {
            zdarzenia.append(e)
        }
        t += 0.01
    }
    return zdarzenia
}

@Test func krotkieWcisniecieDajeNacisniecie() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    _ = odtworz(&r, wcisniety: true, przez: 0.3, od: 0.2)
    let po = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.5)
    #expect(po == [.press])
}

@Test func przytrzymanieDajeHoldWMomenciePrzekroczeniaProgu() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    let wtrakcie = odtworz(&r, wcisniety: true, przez: 1.5, od: 0.2)
    #expect(wtrakcie == [.hold])
}

@Test func poPrzytrzymaniuPuszczenieNieDajeNacisniecia() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    _ = odtworz(&r, wcisniety: true, przez: 1.5, od: 0.2)
    let po = odtworz(&r, wcisniety: false, przez: 0.5, od: 1.7)
    #expect(po.isEmpty)
}

@Test func tuzPonizejProguToNacisniecie() {
    var r = ButtonRecognizer(tuning: .init(hold: 1.0, debounce: 0.03, cooldown: 0.0))
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    let wtrakcie = odtworz(&r, wcisniety: true, przez: 0.95, od: 0.2)
    #expect(wtrakcie.isEmpty)
    let po = odtworz(&r, wcisniety: false, przez: 0.2, od: 1.15)
    #expect(po == [.press])
}

@Test func drganieStykuJestTlumione() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    // Trzy zbocza w ciągu 20 ms — poniżej progu debounce.
    var zdarzenia: [ButtonEvent] = []
    for (i, stan) in [true, false, true].enumerated() {
        if let e = r.consume(ButtonSample(pressed: stan, timestamp: 0.2 + Double(i) * 0.005)) {
            zdarzenia.append(e)
        }
    }
    #expect(zdarzenia.isEmpty)
}

@Test func cooldownTlumiDrugieNacisniecie() {
    var r = ButtonRecognizer()
    _ = odtworz(&r, wcisniety: false, przez: 0.2, od: 0.0)
    _ = odtworz(&r, wcisniety: true, przez: 0.2, od: 0.2)
    let pierwsze = odtworz(&r, wcisniety: false, przez: 0.1, od: 0.4)
    #expect(pierwsze == [.press])
    _ = odtworz(&r, wcisniety: true, przez: 0.1, od: 0.5)
    let drugie = odtworz(&r, wcisniety: false, przez: 0.1, od: 0.6)
    #expect(drugie.isEmpty)
}

@Test func ciaglyStanPuszczonyNieDajeZdarzen() {
    var r = ButtonRecognizer()
    let zdarzenia = odtworz(&r, wcisniety: false, przez: 5.0, od: 0.0)
    #expect(zdarzenia.isEmpty)
}
```

- [ ] **Step 2: Uruchom testy i potwierdź, że nie przechodzą**

Run: `swift test --filter ButtonRecognizerTests`
Expected: FAIL — kompilacja nie znajduje typu `ButtonRecognizer`.

- [ ] **Step 3: Napisz rozpoznawacz**

`Sources/TrikiMuteCore/ButtonRecognizer.swift`:

```swift
import Foundation

/// Rozpoznaje Naciśnięcia i Przytrzymania z ciągu stanów przycisku.
///
/// Kapsel nadaje *poziom* przycisku w każdej ramce (~104 Hz), a nie zdarzenia,
/// więc rozpoznawanie polega na wykrywaniu zboczy. Przytrzymanie jest zgłaszane
/// w chwili przekroczenia progu, a nie przy puszczeniu — dzięki temu sprzężenie
/// zwrotne przychodzi od razu, bez czekania, aż zdejmiesz palec.
public struct ButtonRecognizer {
    /// Stałe czasowe rozpoznawania. Wszystkie w sekundach.
    public struct Tuning: Sendable {
        public let hold: TimeInterval
        public let debounce: TimeInterval
        public let cooldown: TimeInterval

        public init(hold: TimeInterval, debounce: TimeInterval, cooldown: TimeInterval) {
            self.hold = hold
            self.debounce = debounce
            self.cooldown = cooldown
        }

        public static let domyslne = Tuning(hold: 1.0, debounce: 0.03, cooldown: 0.3)
    }

    private let tuning: Tuning
    private var wcisniety = false
    private var poczatekWcisniecia: TimeInterval = 0
    private var holdZgloszony = false
    private var ostatnieZbocze: TimeInterval = -.greatestFiniteMagnitude
    private var ostatnieZdarzenie: TimeInterval = -.greatestFiniteMagnitude

    public init(tuning: Tuning = .domyslne) {
        self.tuning = tuning
    }

    /// Zwraca zdarzenie, jeśli ta próbka je domyka.
    public mutating func consume(_ sample: ButtonSample) -> ButtonEvent? {
        if sample.pressed != wcisniety {
            guard sample.timestamp - ostatnieZbocze >= tuning.debounce else {
                return nil  // drganie styku
            }
            ostatnieZbocze = sample.timestamp
            wcisniety = sample.pressed

            if wcisniety {
                poczatekWcisniecia = sample.timestamp
                holdZgloszony = false
                return nil
            }
            // Puszczenie. Przytrzymanie już zgłoszone — nie dubluj zdarzenia.
            guard !holdZgloszony else { return nil }
            guard sample.timestamp - poczatekWcisniecia < tuning.hold else { return nil }
            return wyemituj(.press, at: sample.timestamp)
        }

        guard wcisniety, !holdZgloszony else { return nil }
        guard sample.timestamp - poczatekWcisniecia >= tuning.hold else { return nil }
        holdZgloszony = true
        return wyemituj(.hold, at: sample.timestamp)
    }

    private mutating func wyemituj(_ event: ButtonEvent, at timestamp: TimeInterval) -> ButtonEvent? {
        guard timestamp - ostatnieZdarzenie >= tuning.cooldown else { return nil }
        ostatnieZdarzenie = timestamp
        return event
    }
}
```

- [ ] **Step 4: Uruchom testy i potwierdź, że przechodzą**

Run: `swift test --filter ButtonRecognizerTests`
Expected: PASS, 7 testów.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMuteCore/ButtonRecognizer.swift Tests/TrikiMuteCoreTests/ButtonRecognizerTests.swift
git commit -m "feat(core): rozpoznawanie Nacisniecia i Przytrzymania ze zbocz przycisku"
```

---

### Task 6: MeetScripts i MeetController

Generuje skrypty sterujące i interpretuje odpowiedzi. Testowane przez podstawionego wykonawcę, bez uruchamiania przeglądarki.

**Files:**
- Create: `Sources/TrikiMuteCore/MeetScripts.swift`
- Create: `Sources/TrikiMuteCore/MeetController.swift`
- Create: `Tests/TrikiMuteCoreTests/MeetControllerTests.swift`

**Interfaces:**
- Consumes: `MeetAction` z Task 4.
- Produces:
  - `public protocol ScriptRunner { func run(_ source: String) throws -> String }`
  - `public struct ProbeResult: Equatable, Sendable { public let browser: String; public let micMuted: Bool; public let cameraOff: Bool }`
  - `public enum ActionOutcome: Equatable, Sendable { case performed; case noTarget; case failed(String) }`
  - `public struct MeetController { public init(runner: ScriptRunner); public func probe(browsers: [String]) -> ProbeResult?; public func perform(_ action: MeetAction, browsers: [String]) -> ActionOutcome }`
  - `public enum MeetScripts { public static let buttonSelector: String; public static let micIndex: Int; public static let cameraIndex: Int; public static func probeJS() -> String; public static func toggleJS(_ action: MeetAction) -> String; public static func appleScript(browser: String, javascript: String) -> String }`

  Task 7 dostarcza produkcyjną implementację `ScriptRunner`, Task 9 konsumuje `ProbeResult` i `ActionOutcome`.

- [ ] **Step 1: Napisz testy**

`Tests/TrikiMuteCoreTests/MeetControllerTests.swift`:

```swift
import Foundation
import Testing
@testable import TrikiMuteCore

/// Wykonawca-atrapa: zwraca zaprogramowane odpowiedzi i zapamiętuje skrypty.
private final class FakeRunner: ScriptRunner {
    var odpowiedzi: [String]
    private(set) var wykonane: [String] = []

    init(_ odpowiedzi: [String]) { self.odpowiedzi = odpowiedzi }

    func run(_ source: String) throws -> String {
        wykonane.append(source)
        return odpowiedzi.isEmpty ? "NONE" : odpowiedzi.removeFirst()
    }
}

private struct RunnerError: Error {}

private final class ThrowingRunner: ScriptRunner {
    func run(_ source: String) throws -> String { throw RunnerError() }
}

@Test func sondaZwracaBrakCeluGdyZadnaPrzegladarkaNieMaMeet() {
    let runner = FakeRunner(["NONE", "NONE"])
    let c = MeetController(runner: runner)
    #expect(c.probe(browsers: ["Google Chrome", "Brave Browser"]) == nil)
    #expect(runner.wykonane.count == 2)
}

@Test func sondaDekodujeStanMikrofonuIKamery() {
    // Format odpowiedzi: dwa znaki, kolejno mikrofon i kamera, 1 = wyłączone.
    let runner = FakeRunner(["10"])
    let c = MeetController(runner: runner)
    let wynik = c.probe(browsers: ["Google Chrome"])
    #expect(wynik == ProbeResult(browser: "Google Chrome", micMuted: true, cameraOff: false))
}

@Test func sondaZatrzymujeSieNaPierwszejPrzegladarceZCelem() {
    let runner = FakeRunner(["01", "11"])
    let c = MeetController(runner: runner)
    let wynik = c.probe(browsers: ["Brave Browser", "Google Chrome"])
    #expect(wynik?.browser == "Brave Browser")
    #expect(wynik?.micMuted == false)
    #expect(wynik?.cameraOff == true)
    #expect(runner.wykonane.count == 1)
}

@Test func sondaPomijaPrzegladarkeKtoraRzucilaBlad() {
    let c = MeetController(runner: ThrowingRunner())
    #expect(c.probe(browsers: ["Google Chrome"]) == nil)
}

@Test func akcjaZglaszaBrakCelu() {
    let runner = FakeRunner(["NONE"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Google Chrome"]) == .noTarget)
}

@Test func akcjaZglaszaSukces() {
    let runner = FakeRunner(["OK"])
    let c = MeetController(runner: runner)
    #expect(c.perform(.microphone, browsers: ["Google Chrome"]) == .performed)
}

@Test func akcjaZglaszaBladWykonawcy() {
    let c = MeetController(runner: ThrowingRunner())
    if case .failed = c.perform(.camera, browsers: ["Google Chrome"]) {
        // oczekiwane
    } else {
        Issue.record("Oczekiwano .failed")
    }
}

@Test func skryptMikrofonuIKameryCelujaWRozneIndeksy() {
    let mic = MeetScripts.toggleJS(.microphone)
    let cam = MeetScripts.toggleJS(.camera)
    #expect(mic != cam)
    #expect(mic.contains("[\(MeetScripts.micIndex)]"))
    #expect(cam.contains("[\(MeetScripts.cameraIndex)]"))
}

@Test func javascriptNieZawieraCudzyslowowLamiacychAppleScript() {
    // JS jest wklejany do literału tekstowego AppleScript, więc podwójne
    // cudzysłowy rozerwałyby skrypt. Cały JS musi używać apostrofów.
    #expect(!MeetScripts.probeJS().contains("\""))
    #expect(!MeetScripts.toggleJS(.microphone).contains("\""))
    #expect(!MeetScripts.toggleJS(.camera).contains("\""))
}

@Test func appleScriptZawieraNazwePrzegladarkiIStrazneWarunki() {
    let s = MeetScripts.appleScript(browser: "Brave Browser", javascript: "1")
    #expect(s.contains("tell application \"Brave Browser\""))
    #expect(s.contains("if it is not running"))
    #expect(s.contains("meet.google.com"))
}
```

- [ ] **Step 2: Uruchom testy i potwierdź, że nie przechodzą**

Run: `swift test --filter MeetControllerTests`
Expected: FAIL — kompilacja nie znajduje `MeetController`, `MeetScripts`, `ScriptRunner`.

- [ ] **Step 3: Napisz generator skryptów**

`Sources/TrikiMuteCore/MeetScripts.swift`:

```swift
import Foundation

/// Skrypty sterujące rozmową Google Meet.
///
/// Meet nie ma API, a syntetyczny skrót klawiszowy nie zadziała, bo obsługa
/// skrótów reaguje wyłącznie na zaufane zdarzenia — dlatego klikamy realny
/// przycisk w DOM. To jedyne miejsce w kodzie, w którym wolno wymieniać
/// selektory DOM.
public enum MeetScripts {
    /// Atrybut, po którym rozpoznajemy przyciski mikrofonu i kamery.
    /// Świadomie nie `aria-label` — etykieta jest tłumaczona i rozjechałaby się
    /// przy zmianie języka interfejsu.
    public static let buttonSelector = "[data-is-muted]"

    /// Pozycje przycisków w wyniku `querySelectorAll`. Wartości potwierdzone
    /// spikiem z Task 1 (`docs/findings/2026-08-12-meet-dom.md`).
    public static let micIndex = 0
    public static let cameraIndex = 1

    /// Fragment JS wspólny dla sondy i akcji. Zwraca `NONE`, gdy w karcie nie
    /// ma kompletu przycisków — to jest sygnał „brak Celu".
    private static let preambula = """
    var b=document.querySelectorAll('\(buttonSelector)');if(b.length<2)return 'NONE';
    """

    /// Zwraca dwa znaki: stan mikrofonu i kamery, gdzie 1 oznacza wyłączone.
    public static func probeJS() -> String {
        """
        (function(){\(preambula)\
        var f=function(e){return e.getAttribute('data-is-muted')==='true'?'1':'0'};\
        return f(b[\(micIndex)])+f(b[\(cameraIndex)])})()
        """
    }

    /// Klika przycisk odpowiadający akcji. Zwraca `OK` albo `NONE`.
    public static func toggleJS(_ action: MeetAction) -> String {
        let index = action == .microphone ? micIndex : cameraIndex
        return """
        (function(){\(preambula)\
        b[\(index)].click();return 'OK'})()
        """
    }

    /// Opakowuje JS w skrypt szukający Celu wśród kart danej przeglądarki.
    /// Karta nie musi być aktywna ani na wierzchu — to jest cały sens Apple
    /// Events zamiast skrótu klawiszowego.
    public static func appleScript(browser: String, javascript: String) -> String {
        """
        tell application "\(browser)"
            if it is not running then return "NONE"
            repeat with w in windows
                repeat with t in tabs of w
                    if URL of t contains "meet.google.com" then
                        set wynik to execute t javascript "\(javascript)"
                        if wynik is not "NONE" then return wynik
                    end if
                end repeat
            end repeat
        end tell
        return "NONE"
        """
    }
}
```

- [ ] **Step 4: Napisz kontroler**

`Sources/TrikiMuteCore/MeetController.swift`:

```swift
import Foundation

/// Wykonawca skryptów. Produkcyjna implementacja opakowuje `NSAppleScript`,
/// testowa zwraca zaprogramowane odpowiedzi.
public protocol ScriptRunner {
    func run(_ source: String) throws -> String
}

/// Wynik sondy: gdzie jest Cel i w jakim jest stanie.
public struct ProbeResult: Equatable, Sendable {
    public let browser: String
    public let micMuted: Bool
    public let cameraOff: Bool

    public init(browser: String, micMuted: Bool, cameraOff: Bool) {
        self.browser = browser
        self.micMuted = micMuted
        self.cameraOff = cameraOff
    }
}

/// Wynik Akcji. Rozróżnienie `noTarget` od `failed` jest celowe: pierwsze
/// znaczy „nie ma czego wyciszyć", drugie „miałem co zrobić i nie wyszło".
public enum ActionOutcome: Equatable, Sendable {
    case performed
    case noTarget
    case failed(String)
}

/// Steruje mikrofonem i kamerą w Celu.
public struct MeetController {
    private let runner: ScriptRunner

    public init(runner: ScriptRunner) {
        self.runner = runner
    }

    /// Szuka Celu w podanych przeglądarkach, w kolejności. Zwraca stan
    /// pierwszej karty, w której jest komplet przycisków, albo `nil`.
    public func probe(browsers: [String]) -> ProbeResult? {
        for browser in browsers {
            guard let odpowiedz = wykonaj(MeetScripts.probeJS(), in: browser),
                  odpowiedz.count == 2 else { continue }
            let znaki = Array(odpowiedz)
            return ProbeResult(
                browser: browser,
                micMuted: znaki[0] == "1",
                cameraOff: znaki[1] == "1"
            )
        }
        return nil
    }

    /// Wykonuje Akcję w pierwszej przeglądarce, w której jest Cel.
    public func perform(_ action: MeetAction, browsers: [String]) -> ActionOutcome {
        var ostatniBlad: String?
        for browser in browsers {
            do {
                let odpowiedz = try runner.run(
                    MeetScripts.appleScript(browser: browser, javascript: MeetScripts.toggleJS(action))
                )
                if odpowiedz == "OK" { return .performed }
            } catch {
                ostatniBlad = String(describing: error)
            }
        }
        if let ostatniBlad { return .failed(ostatniBlad) }
        return .noTarget
    }

    private func wykonaj(_ javascript: String, in browser: String) -> String? {
        let skrypt = MeetScripts.appleScript(browser: browser, javascript: javascript)
        guard let odpowiedz = try? runner.run(skrypt), odpowiedz != "NONE" else { return nil }
        return odpowiedz
    }
}
```

- [ ] **Step 5: Uruchom testy i potwierdź, że przechodzą**

Run: `swift test --filter MeetControllerTests`
Expected: PASS, 10 testów.

- [ ] **Step 6: Uruchom cały zestaw testów**

Run: `swift test`
Expected: PASS, 24 testy (7 + 7 + 10).

- [ ] **Step 7: Commit**

```bash
git add Sources/TrikiMuteCore/MeetScripts.swift Sources/TrikiMuteCore/MeetController.swift Tests/TrikiMuteCoreTests/MeetControllerTests.swift
git commit -m "feat(core): skrypty sterujace Meet i kontroler z wykonawca wymiennym"
```

---

### Task 7: Wykonawca AppleScript i kolejność przeglądarek

Podłącza kontroler do prawdziwych przeglądarek. Pierwszy moment, w którym aplikacja realnie coś wycisza.

**Files:**
- Create: `Sources/TrikiMute/AppleScriptRunner.swift`
- Create: `Sources/TrikiMute/BrowserOrder.swift`
- Modify: `Sources/TrikiMute/TrikiMuteApp.swift`

**Interfaces:**
- Consumes: `ScriptRunner`, `MeetController`, `MeetAction` z Task 6.
- Produces: `final class AppleScriptRunner: ScriptRunner` oraz `enum BrowserOrder { static let wszystkie: [String]; static func uporzadkowane() -> [String] }`. Task 9 wstrzykuje oba do `AppState`.

- [ ] **Step 1: Napisz wykonawcę**

`Sources/TrikiMute/AppleScriptRunner.swift`:

```swift
import Foundation
import TrikiMuteCore

/// Wykonuje AppleScript przez `NSAppleScript`.
///
/// Najczęstsze błędy, które tu wypływają:
/// `-1743` — brak zgody na Automation w Ustawieniach systemowych,
/// `-2700` / komunikat o JavaScript — wyłączone „Allow JavaScript from Apple
/// Events" w menu `View → Developer` przeglądarki.
final class AppleScriptRunner: ScriptRunner {
    struct Blad: LocalizedError {
        let kod: Int
        let opis: String
        var errorDescription: String? { "AppleScript \(kod): \(opis)" }
    }

    func run(_ source: String) throws -> String {
        guard let skrypt = NSAppleScript(source: source) else {
            throw Blad(kod: 0, opis: "Nie udało się zbudować skryptu")
        }
        var info: NSDictionary?
        let wynik = skrypt.executeAndReturnError(&info)
        if let info {
            throw Blad(
                kod: info[NSAppleScript.errorNumber] as? Int ?? 0,
                opis: info[NSAppleScript.errorMessage] as? String ?? "nieznany błąd"
            )
        }
        return wynik.stringValue ?? "NONE"
    }
}
```

- [ ] **Step 2: Napisz kolejność przeglądarek**

`Sources/TrikiMute/BrowserOrder.swift`:

```swift
import AppKit

/// Kolejność odpytywania przeglądarek. Ta na wierzchu idzie pierwsza — jeśli
/// masz otwarte dwie rozmowy, wygrywa ta, na którą właśnie patrzysz.
enum BrowserOrder {
    static let wszystkie = ["Google Chrome", "Brave Browser"]

    /// Nazwy aplikacji dla AppleScript, z aktywną przeglądarką na początku.
    static func uporzadkowane() -> [String] {
        guard let aktywna = NSWorkspace.shared.frontmostApplication?.localizedName,
              wszystkie.contains(aktywna) else {
            return wszystkie
        }
        return [aktywna] + wszystkie.filter { $0 != aktywna }
    }
}
```

- [ ] **Step 3: Podłącz ręczny test do menu**

Zastąp treść `Sources/TrikiMute/TrikiMuteApp.swift`:

```swift
import SwiftUI
import TrikiMuteCore

@main
struct TrikiMuteApp: App {
    private let controller = MeetController(runner: AppleScriptRunner())

    var body: some Scene {
        MenuBarExtra("TrikiMute", systemImage: "mic.slash.circle") {
            Button("Sonda — wypisz stan Celu") {
                let wynik = controller.probe(browsers: BrowserOrder.uporzadkowane())
                print("Sonda: \(String(describing: wynik))")
            }
            Button("Przełącz mikrofon") {
                print("Mikrofon: \(controller.perform(.microphone, browsers: BrowserOrder.uporzadkowane()))")
            }
            Button("Przełącz kamerę") {
                print("Kamera: \(controller.perform(.camera, browsers: BrowserOrder.uporzadkowane()))")
            }
            Divider()
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 4: Zbuduj i przetestuj ręcznie na prawdziwej rozmowie**

```bash
./scripts/build-app.sh && open build/TrikiMute.app
```

Otwórz rozmowę Meet, przełącz się do innej aplikacji, po czym z paska menu wywołaj kolejno wszystkie trzy pozycje. Oczekiwane:

- przy pierwszym uruchomieniu macOS pyta o zgodę na sterowanie przeglądarką — zgódź się,
- „Sonda" wypisuje `ProbeResult` z nazwą przeglądarki i stanami,
- „Przełącz mikrofon" wycisza rozmowę **bez przenoszenia focusu** na przeglądarkę,
- „Przełącz kamerę" wyłącza kamerę,
- po zamknięciu karty Meet sonda zwraca `nil`, a akcje `noTarget`.

Logi zobaczysz przez `log stream --predicate 'process == "TrikiMute"'` albo uruchamiając binarkę wprost: `build/TrikiMute.app/Contents/MacOS/TrikiMute`.

- [ ] **Step 5: Zweryfikuj zachowanie przy braku zgody**

W Ustawieniach systemowych, `Prywatność i ochrona → Automatyzacja`, odbierz TrikiMute zgodę na przeglądarkę i wywołaj akcję ponownie. Oczekiwane: wynik `failed` z kodem `-1743` w treści, a nie cisza ani `noTarget`. Przywróć zgodę.

- [ ] **Step 6: Commit**

```bash
git add Sources/TrikiMute
git commit -m "feat: wykonawca AppleScript, kolejnosc przegladarek i reczny test sterowania Meet"
```

---

### Task 8: TrikiConnection i model Uzbrojenia

Podłącza Kapsel. Pierwszy moment, w którym fizyczny przycisk cokolwiek robi.

**Files:**
- Create: `Sources/TrikiMute/TrikiConnection.swift`
- Modify: `Sources/TrikiMute/TrikiMuteApp.swift`

**Interfaces:**
- Consumes: `FrameParser`, `ButtonRecognizer`, `ButtonEvent` z Task 4 i 5.
- Produces:
  - `enum PolaczenieKapsla: Equatable { case rozlaczony, szukam, uzbrojony, blad(String) }`
  - `@MainActor final class TrikiConnection: NSObject` z `var onEvent: ((ButtonEvent) -> Void)?`, `var onState: ((PolaczenieKapsla) -> Void)?`, `var onBattery: ((Int) -> Void)?`, `var onRSSI: ((Int) -> Void)?`, `func start()`, `func forget()`, `func odczytajRSSI()`.

  Task 9 podpina się pod wszystkie cztery domknięcia i woła `odczytajRSSI()` z timera sondy.

- [ ] **Step 1: Napisz warstwę BLE**

`Sources/TrikiMute/TrikiConnection.swift`:

```swift
import CoreBluetooth
import Foundation
import TrikiMuteCore

/// Stan Kapsla widziany przez aplikację.
enum PolaczenieKapsla: Equatable {
    case rozlaczony
    case szukam
    case uzbrojony
    case blad(String)
}

/// Utrzymuje połączenie z Kapslem i zamienia jego strumień na zdarzenia przycisku.
///
/// Model Uzbrojenia: śpiący Kapsel nie reklamuje się w eterze, więc aplikacja
/// nie ma jak się z nim połączyć z własnej inicjatywy. Pierwsze naciśnięcie budzi
/// Kapsel i zestawia połączenie — i z definicji nie wywołuje Akcji, bo w chwili
/// naciśnięcia aplikacja jeszcze nie słuchała. Zamiast ciągłego skanowania
/// zapamiętujemy identyfikator i zawieszamy `connect()`; CoreBluetooth podniesie
/// połączenie samo, gdy tylko Kapsel się odezwie.
@MainActor
final class TrikiConnection: NSObject {
    private enum UUIDy {
        static let nus = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
        static let rx = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        static let tx = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        static let bateria = CBUUID(string: "180F")
        static let poziomBaterii = CBUUID(string: "2A19")
    }

    /// Komenda uruchamiająca strumień IMU. Bez niej Kapsel milczy, a stan
    /// przycisku jest zaszyty w nagłówku ramek IMU — nie da się go czytać osobno.
    private static let komendaStartowa = Data([0x20, 0x10, 0x00, 0xD0, 0x07, 0x68, 0x00, 0x03])
    private static let kluczZnanegoKapsla = "znanyKapselUUID"
    private static let fragmentNazwy = "triki"

    var onEvent: ((ButtonEvent) -> Void)?
    var onState: ((PolaczenieKapsla) -> Void)?
    var onBattery: ((Int) -> Void)?
    var onRSSI: ((Int) -> Void)?

    private var central: CBCentralManager!
    private var kapsel: CBPeripheral?
    private var rx: CBCharacteristic?
    private var parser = FrameParser()
    private var recognizer = ButtonRecognizer()

    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Prosi o pomiar siły sygnału. Odpowiedź przychodzi asynchronicznie
    /// w `peripheral(_:didReadRSSI:error:)`.
    func odczytajRSSI() {
        kapsel?.readRSSI()
    }

    /// Zapomina Kapsel i wraca do skanowania. Do użycia, gdy trzeba sparować inny.
    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.kluczZnanegoKapsla)
        if let kapsel { central.cancelPeripheralConnection(kapsel) }
        kapsel = nil
        onState?(.rozlaczony)
        wznowPoszukiwania()
    }

    /// Znany Kapsel: zawieszony `connect()`. Nieznany: skan po nazwie.
    private func wznowPoszukiwania() {
        guard central?.state == .poweredOn else { return }
        onState?(.szukam)

        if let zapisany = UserDefaults.standard.string(forKey: Self.kluczZnanegoKapsla),
           let uuid = UUID(uuidString: zapisany),
           let znany = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            kapsel = znany
            znany.delegate = self
            central.connect(znany, options: nil)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func zresetujRozpoznawanie() {
        parser = FrameParser()
        recognizer = ButtonRecognizer()
    }
}

extension TrikiConnection: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: wznowPoszukiwania()
            case .poweredOff: onState?(.blad("Bluetooth jest wyłączony"))
            case .unauthorized: onState?(.blad("Brak zgody na Bluetooth"))
            case .unsupported: onState?(.blad("Ten Mac nie obsługuje Bluetooth LE"))
            default: onState?(.rozlaczony)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let nazwa = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard nazwa.lowercased().contains(Self.fragmentNazwy) else { return }
        Task { @MainActor in
            central.stopScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.kluczZnanegoKapsla)
            kapsel = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            zresetujRozpoznawanie()
            peripheral.discoverServices([UUIDy.nus, UUIDy.bateria])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            rx = nil
            onState?(.rozlaczony)
            // Zawieszony connect() podniesie połączenie, gdy Kapsel wróci.
            central.connect(peripheral, options: nil)
            onState?(.szukam)
        }
    }
}

extension TrikiConnection: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for usluga in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: usluga)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            for ch in service.characteristics ?? [] {
                switch ch.uuid {
                case UUIDy.tx:
                    peripheral.setNotifyValue(true, for: ch)
                case UUIDy.rx:
                    rx = ch
                    peripheral.writeValue(Self.komendaStartowa, for: ch, type: .withoutResponse)
                    onState?(.uzbrojony)
                case UUIDy.poziomBaterii:
                    peripheral.readValue(for: ch)
                    peripheral.setNotifyValue(true, for: ch)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let wartosc = RSSI.intValue
        Task { @MainActor in onRSSI?(wartosc) }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let dane = characteristic.value else { return }
        let uuid = characteristic.uuid
        let bajty = [UInt8](dane)
        let teraz = Date().timeIntervalSince1970

        Task { @MainActor in
            switch uuid {
            case UUIDy.poziomBaterii:
                if let poziom = bajty.first { onBattery?(Int(poziom)) }
            case UUIDy.tx:
                for probka in parser.consume(bajty, at: teraz) {
                    if let zdarzenie = recognizer.consume(probka) {
                        onEvent?(zdarzenie)
                    }
                }
            default:
                break
            }
        }
    }
}
```

- [ ] **Step 2: Podłącz Kapsel do menu**

Zastąp treść `Sources/TrikiMute/TrikiMuteApp.swift`:

```swift
import SwiftUI
import TrikiMuteCore

@main
struct TrikiMuteApp: App {
    @State private var most = MostTestowy()

    var body: some Scene {
        MenuBarExtra("TrikiMute", systemImage: "mic.slash.circle") {
            Text(most.opis)
            Divider()
            Button("Zakończ") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Tymczasowe spięcie Kapsla z Meet. Zastąpione przez AppState w Task 9.
@MainActor
@Observable
final class MostTestowy {
    private(set) var opis = "Start…"
    private let polaczenie = TrikiConnection()
    private let controller = MeetController(runner: AppleScriptRunner())

    init() {
        polaczenie.onState = { [weak self] stan in
            self?.opis = "Kapsel: \(stan)"
            print("Stan: \(stan)")
        }
        polaczenie.onBattery = { print("Bateria: \($0)%") }
        polaczenie.onEvent = { [weak self] zdarzenie in
            guard let self else { return }
            let akcja: MeetAction = zdarzenie == .press ? .microphone : .camera
            let wynik = controller.perform(akcja, browsers: BrowserOrder.uporzadkowane())
            print("Zdarzenie \(zdarzenie) → \(akcja) → \(wynik)")
        }
        polaczenie.start()
    }
}
```

- [ ] **Step 3: Zbuduj i przetestuj Uzbrojenie**

```bash
./scripts/build-app.sh && build/TrikiMute.app/Contents/MacOS/TrikiMute
```

Uruchom binarkę wprost, żeby widzieć logi. Przy pierwszym starcie macOS zapyta o zgodę na Bluetooth. Kolejność testu:

1. Kapsel śpi — w logu widać `szukam`.
2. Naciśnij przycisk na Kapslu. Oczekiwane: pojawia się `uzbrojony`, a **to naciśnięcie nie wywołuje Akcji** — to jest sedno modelu Uzbrojenia.
3. Otwórz rozmowę Meet, przełącz się do innej aplikacji.
4. Naciśnij krótko. Oczekiwane: `Zdarzenie press → microphone → performed`, mikrofon się przełącza.
5. Przytrzymaj ponad sekundę. Oczekiwane: `Zdarzenie hold → camera → performed` **w chwili przekroczenia progu**, jeszcze zanim puścisz przycisk, i tylko raz.
6. Odejdź z Kapslem poza zasięg i wróć. Oczekiwane: `rozlaczony`, potem `szukam`, potem `uzbrojony` bez restartu aplikacji.

- [ ] **Step 4: Zweryfikuj brak fałszywych zdarzeń**

Zostaw Kapsel nieruchomo na biurku na 5 minut przy otwartej rozmowie. Oczekiwane: zero zdarzeń w logu. Strumień IMU płynie cały czas, więc każde fałszywe zdarzenie ujawni się właśnie tutaj.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMute
git commit -m "feat: polaczenie z Kapslem, model Uzbrojenia i spiecie przycisku z Meet"
```

---

### Task 9: AppState i pełne menu

Zbiera stan w jedno źródło prawdy i pokazuje go w pasku menu.

**Files:**
- Create: `Sources/TrikiMute/AppState.swift`
- Create: `Sources/TrikiMute/MenuBarView.swift`
- Modify: `Sources/TrikiMute/TrikiMuteApp.swift`

**Interfaces:**
- Consumes: `TrikiConnection`, `PolaczenieKapsla` z Task 8; `MeetController`, `ProbeResult`, `ActionOutcome` z Task 6; `BrowserOrder` z Task 7.
- Produces: `@MainActor @Observable final class AppState` z polami `stanKapsla`, `bateria`, `rssi`, `cel`, `ostatniaAkcja`, `nazwaIkony` i metodami `func wykonaj(_ action: MeetAction)`, `func zapomnijKapsel()`. Task 10 podpina się pod `wykonaj`.

- [ ] **Step 1: Napisz stan aplikacji**

`Sources/TrikiMute/AppState.swift`:

```swift
import Foundation
import Observation
import TrikiMuteCore

/// Jedyne źródło prawdy dla interfejsu.
@MainActor
@Observable
final class AppState {
    private(set) var stanKapsla: PolaczenieKapsla = .rozlaczony
    private(set) var bateria: Int?
    private(set) var rssi: Int?
    private(set) var cel: ProbeResult?
    private(set) var ostatniaAkcja: String = "—"

    private let polaczenie = TrikiConnection()
    private let controller = MeetController(runner: AppleScriptRunner())
    private var sonda: Timer?

    /// Odstęp sondy. Sonda chodzi wyłącznie przy uzbrojonym Kapslu — poza
    /// rozmową nie ma czego odpytywać.
    private static let odstepSondy: TimeInterval = 3.0

    init() {
        polaczenie.onState = { [weak self] stan in
            guard let self else { return }
            stanKapsla = stan
            stan == .uzbrojony ? uruchomSonde() : zatrzymajSonde()
        }
        polaczenie.onBattery = { [weak self] in self?.bateria = $0 }
        polaczenie.onRSSI = { [weak self] in self?.rssi = $0 }
        polaczenie.onEvent = { [weak self] zdarzenie in
            self?.wykonaj(zdarzenie == .press ? .microphone : .camera)
        }
        polaczenie.start()
    }

    /// Nazwa symbolu SF dla ikony w pasku menu.
    var nazwaIkony: String {
        switch stanKapsla {
        case .blad: return "exclamationmark.triangle"
        case .rozlaczony, .szukam: return "circle.dotted"
        case .uzbrojony: return cel?.micMuted == true ? "mic.slash.fill" : "mic.fill"
        }
    }

    var opisKapsla: String {
        switch stanKapsla {
        case .rozlaczony: return "Kapsel rozłączony"
        case .szukam: return "Szukam Kapsla — naciśnij przycisk, żeby go obudzić"
        case .uzbrojony: return "Kapsel uzbrojony"
        case .blad(let opis): return opis
        }
    }

    var opisCelu: String {
        guard let cel else { return "Brak Celu — nie ma czego wyciszyć" }
        return "\(cel.browser): mikrofon \(cel.micMuted ? "wyciszony" : "aktywny"), "
            + "kamera \(cel.cameraOff ? "wyłączona" : "włączona")"
    }

    func wykonaj(_ action: MeetAction) {
        let wynik = controller.perform(action, browsers: BrowserOrder.uporzadkowane())
        ostatniaAkcja = opis(action, wynik)
        // Meet aktualizuje DOM asynchronicznie po kliknięciu — odczyt musi
        // poczekać, inaczej zobaczymy stan sprzed Akcji.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.odswiezCel()
        }
    }

    func zapomnijKapsel() {
        polaczenie.forget()
    }

    private func opis(_ action: MeetAction, _ wynik: ActionOutcome) -> String {
        let co = action == .microphone ? "Mikrofon" : "Kamera"
        switch wynik {
        case .performed: return "\(co): przełączono"
        case .noTarget: return "\(co): brak Celu"
        case .failed(let blad): return "\(co): błąd — \(blad)"
        }
    }

    private func uruchomSonde() {
        guard sonda == nil else { return }
        odswiezCel()
        sonda = Timer.scheduledTimer(withTimeInterval: Self.odstepSondy, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.odswiezCel() }
        }
    }

    private func zatrzymajSonde() {
        sonda?.invalidate()
        sonda = nil
        cel = nil
        rssi = nil
    }

    /// Jeden przebieg sondy: gdzie jest Cel, w jakim jest stanie i jak mocny
    /// jest sygnał Kapsla. Siła sygnału przychodzi asynchronicznie przez onRSSI.
    private func odswiezCel() {
        cel = controller.probe(browsers: BrowserOrder.uporzadkowane())
        polaczenie.odczytajRSSI()
    }
}
```

- [ ] **Step 2: Napisz widok menu**

`Sources/TrikiMute/MenuBarView.swift`:

```swift
import SwiftUI
import TrikiMuteCore

struct MenuBarView: View {
    let state: AppState

    var body: some View {
        Text(state.opisKapsla)
        if let bateria = state.bateria {
            Text("Bateria: \(bateria)%")
        }
        if let rssi = state.rssi {
            Text("Sygnał: \(rssi) dBm")
        }
        Text(state.opisCelu)
        Text("Ostatnia akcja: \(state.ostatniaAkcja)")

        Divider()

        Button("Przełącz mikrofon") { state.wykonaj(.microphone) }
        Button("Przełącz kamerę") { state.wykonaj(.camera) }

        Divider()

        Button("Zapomnij Kapsel") { state.zapomnijKapsel() }
        Button("Zakończ") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
```

- [ ] **Step 3: Zepnij całość**

Zastąp treść `Sources/TrikiMute/TrikiMuteApp.swift`:

```swift
import SwiftUI

@main
struct TrikiMuteApp: App {
    @State private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            Image(systemName: state.nazwaIkony)
        }
        .menuBarExtraStyle(.menu)
    }
}
```

- [ ] **Step 4: Zbuduj i przetestuj interfejs**

```bash
./scripts/build-app.sh && open build/TrikiMute.app
```

Oczekiwane:

- bez Kapsla ikona jest wykropkowanym kółkiem, a menu mówi „naciśnij przycisk, żeby go obudzić",
- po Uzbrojeniu ikona zmienia się w mikrofon, a menu pokazuje poziom baterii; siła sygnału pojawia się dopiero po pierwszym przebiegu sondy, czyli razem z Celem,
- po otwarciu rozmowy menu pokazuje przeglądarkę i oba stany, a ikona przekreśla się przy wyciszeniu — **także wtedy, gdy wyciszysz się myszką w Meet** (potwierdza, że sonda odczytuje rzeczywistość, a nie własne założenia),
- po zamknięciu karty menu wraca do „Brak Celu" w ciągu ~3 sekund,
- „Zapomnij Kapsel" wraca do stanu szukania.

- [ ] **Step 5: Commit**

```bash
git add Sources/TrikiMute
git commit -m "feat: AppState jako jedyne zrodlo prawdy i pelne menu w pasku"
```

---

### Task 10: Sprzężenie zwrotne dźwiękiem

Trzy rozróżnialne sygnały. Jedyny kanał, który działa, gdy nie patrzysz na ekran.

**Files:**
- Create: `Sources/TrikiMute/Feedback.swift`
- Modify: `Sources/TrikiMute/AppState.swift`

**Interfaces:**
- Consumes: `ActionOutcome` z Task 6.
- Produces: `enum Feedback { static func zagraj(_ wynik: ActionOutcome) }`.

- [ ] **Step 1: Napisz sygnały**

`Sources/TrikiMute/Feedback.swift`:

```swift
import AppKit
import TrikiMuteCore

/// Sygnały dźwiękowe potwierdzające wynik Akcji.
///
/// Pasek menu jest złym kanałem na komunikat o niepowodzeniu, bo cała wartość
/// Kapsla polega na tym, że nie patrzysz na ekran. Dźwięk trafia do słuchawek,
/// czyli tam, gdzie faktycznie jesteś podczas rozmowy.
///
/// Nieuzbrojony Kapsel nie wywoła żadnego dźwięku — aplikacja nie wie o jego
/// naciśnięciu. Cisza w tej sytuacji jest nieunikniona i oznacza brak Gotowości.
enum Feedback {
    private static let sukces = "Tink"
    private static let brakCelu = "Pop"
    private static let blad = "Basso"

    static func zagraj(_ wynik: ActionOutcome) {
        let nazwa: String
        switch wynik {
        case .performed: nazwa = sukces
        case .noTarget: nazwa = brakCelu
        case .failed: nazwa = blad
        }
        NSSound(named: nazwa)?.play()
    }
}
```

- [ ] **Step 2: Podłącz sygnały do wykonania Akcji**

W `Sources/TrikiMute/AppState.swift` zastąp metodę `wykonaj`:

```swift
    func wykonaj(_ action: MeetAction) {
        let wynik = controller.perform(action, browsers: BrowserOrder.uporzadkowane())
        Feedback.zagraj(wynik)
        ostatniaAkcja = opis(action, wynik)
        // Meet aktualizuje DOM asynchronicznie po kliknięciu — odczyt musi
        // poczekać, inaczej zobaczymy stan sprzed Akcji.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.odswiezCel()
        }
    }
```

- [ ] **Step 3: Zbuduj i przetestuj wszystkie trzy sygnały**

```bash
./scripts/build-app.sh && open build/TrikiMute.app
```

Wywołaj po kolei trzy sytuacje i potwierdź, że każda brzmi inaczej:

1. **Sukces** — otwarta rozmowa, naciśnięcie przycisku na Kapslu. Oczekiwane: `Tink`.
2. **Brak Celu** — zamknij kartę Meet, poczekaj, aż menu pokaże „Brak Celu", naciśnij przycisk. Oczekiwane: `Pop`.
3. **Błąd** — odbierz zgodę na Automation w Ustawieniach systemowych i naciśnij przycisk przy otwartej rozmowie. Oczekiwane: `Basso`. Przywróć zgodę.

- [ ] **Step 4: Commit**

```bash
git add Sources/TrikiMute
git commit -m "feat: trzy rozroznialne sygnaly dzwiekowe potwierdzajace wynik Akcji"
```

---

### Task 11: Uruchamianie przy logowaniu i dokumentacja

Domyka aplikację do stanu używalnego na co dzień.

**Files:**
- Create: `Sources/TrikiMute/LoginItem.swift`
- Create: `README.md`
- Modify: `Sources/TrikiMute/MenuBarView.swift`

**Interfaces:**
- Consumes: `AppState` z Task 9.
- Produces: `enum LoginItem { static var wlaczone: Bool { get }; static func przelacz() }`.

- [ ] **Step 1: Napisz obsługę autostartu**

`Sources/TrikiMute/LoginItem.swift`:

```swift
import ServiceManagement

/// Uruchamianie przy logowaniu. `SMAppService.mainApp` działa tylko dla
/// podpisanego pakietu .app — uruchomiona wprost binarka zgłosi błąd.
enum LoginItem {
    static var wlaczone: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func przelacz() {
        do {
            if wlaczone {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Autostart: \(error)")
        }
    }
}
```

- [ ] **Step 2: Dodaj przełącznik do menu**

W `Sources/TrikiMute/MenuBarView.swift` wstaw przed pozycją „Zapomnij Kapsel":

```swift
        Button(LoginItem.wlaczone ? "✓ Uruchamiaj przy logowaniu" : "Uruchamiaj przy logowaniu") {
            LoginItem.przelacz()
        }
```

- [ ] **Step 3: Napisz README**

`README.md`:

```markdown
# TrikiMute

Aplikacja macOS w pasku menu, która przełącza mikrofon i kamerę w rozmowie
Google Meet na naciśnięcie przycisku kontrolera BLE **Żabka Triki** — bez
zabierania focusu bieżącej aplikacji.

- **Naciśnięcie** przycisku Kapsla przełącza mikrofon.
- **Przytrzymanie** ponad sekundę przełącza kamerę.

Wiedza o protokole urządzenia pochodzi z siostrzanego projektu
[TrikiScope](https://github.com/Maku-hub/TrikiScope).

## Wymagania

- macOS 14 lub nowszy
- Google Chrome albo Brave Browser
- kontroler Żabka Triki

## Budowanie

```bash
./scripts/build-app.sh release
open build/TrikiMute.app
```

Skrypt podpisuje aplikację stałą tożsamością — macOS wiąże z podpisem zgody na
Bluetooth i Automation, a podpis ad-hoc unieważniałby je przy każdej przebudowie.

## Konfiguracja jednorazowa

1. W każdej używanej przeglądarce włącz `View → Developer → Allow JavaScript from Apple Events`.
2. Przy pierwszym uruchomieniu zgódź się na dostęp do Bluetooth i na sterowanie przeglądarką.

## Jak to działa

Kapsel zasypia i budzi go dopiero naciśnięcie przycisku, więc **pierwsze
naciśnięcie po przerwie tylko go uzbraja** — budzi urządzenie i zestawia
połączenie, nie wywołując Akcji. Pasek menu pokazuje, kiedy Kapsel jest gotowy.

Sterowanie Meet idzie przez Apple Events (`execute javascript in tab`), które
działa na karcie nieaktywnej — dlatego akcja nie przenosi focusu. Wynik każdej
Akcji potwierdza dźwięk: `Tink` gdy się udało, `Pop` gdy nie ma czego wyciszyć,
`Basso` przy błędzie.

## Testy

```bash
swift test
```

Cała logika bez efektów ubocznych żyje w `TrikiMuteCore` i jest testowana bez
sprzętu i bez przeglądarki. Warstwa CoreBluetooth i klikanie w DOM Meet
wymagają testu ręcznego.

## Dokumentacja

- [Specyfikacja](docs/superpowers/specs/2026-08-12-triki-mute-design.md)
- [Glosariusz](CONTEXT.md)
- [Decyzje architektoniczne](docs/adr/)
```

- [ ] **Step 4: Zainstaluj i przetestuj autostart**

```bash
./scripts/build-app.sh release
cp -R build/TrikiMute.app /Applications/
open /Applications/TrikiMute.app
```

Włącz „Uruchamiaj przy logowaniu", sprawdź w Ustawieniach systemowych w sekcji
`Ogólne → Elementy logowania`, że TrikiMute jest na liście. Wyloguj się i zaloguj
ponownie; oczekiwane: ikona pojawia się w pasku menu sama, a Kapsel uzbraja się po
naciśnięciu przycisku bez żadnej ingerencji.

- [ ] **Step 5: Uruchom pełny zestaw testów**

Run: `swift test`
Expected: PASS, 24 testy.

- [ ] **Step 6: Commit**

```bash
git add Sources/TrikiMute README.md
git commit -m "feat: uruchamianie przy logowaniu i dokumentacja projektu"
```

---

## Kolejność i zależności

Task 1 i Task 2 są niezależne od siebie i od reszty — można je wykonać w dowolnej
kolejności, ale **oba muszą poprzedzać** zadania, które od nich zależą: Task 1
ustala stałe w Task 6, Task 2 potwierdza założenia Task 8. Task 3 nie zależy od
spike'ów i może iść równolegle.

Task 4 → Task 5 → Task 8 to łańcuch danych z Kapsla. Task 6 → Task 7 → Task 9 to
łańcuch sterowania Meet. Zbiegają się w Task 8, gdzie przycisk pierwszy raz
wywołuje Akcję.

## Jeśli spike z Task 1 wypadnie negatywnie

Gdyby okazało się, że `data-is-muted` nie odróżnia mikrofonu od kamery albo że
indeksy się przestawiają, zmienia się wyłącznie zawartość `MeetScripts` — reszta
planu stoi bez zmian, bo cała reszta kodu komunikuje się z Meet przez
`MeetController`. Gdyby Brave nie miał przełącznika Apple Events, usuń go
z `BrowserOrder.wszystkie`; plan awaryjny w postaci rozszerzenia przeglądarki
opisuje [ADR 0002](../../adr/0002-apple-events-zamiast-rozszerzenia.md).
