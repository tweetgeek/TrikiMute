# TrikiMute — specyfikacja projektowa

Data: 2026-08-12

Terminologia projektu: [CONTEXT.md](../../../CONTEXT.md).

## Cel

Natywna aplikacja macOS żyjąca w pasku menu, która przełącza mikrofon i kamerę
w rozmowie Google Meet na naciśnięcie Kapsla — niezależnie od tego, która
aplikacja ma w danym momencie focus.

Wiedza o protokole urządzenia pochodzi z projektu
[TrikiScope](../../../../TrikiScope) (reverse engineering, Python/TUI).

## Zakres

W zakresie:

- połączenie BLE z Kapslem, odczyt stanu przycisku, baterii i RSSI,
- Naciśnięcie przełącza mikrofon, Przytrzymanie przełącza kamerę,
- obsługa Google Chrome i Brave, z automatycznym wykryciem, w której jest Cel,
- ikona w pasku menu ze stanem Kapsla, Gotowości i wyciszenia,
- dźwiękowe potwierdzenie wyniku Akcji.

Poza zakresem:

- konfigurowalne mapowanie gestów na dowolne akcje lub skróty klawiszowe,
- obsługa aplikacji innych niż Google Meet,
- dekodowanie i wykorzystanie danych IMU (orientacja, gesty ruchowe),
- sterowanie diodą LED Kapsla.

## Stack

**Swift + SwiftUI**, wyłącznie API systemowe, zero zależności zewnętrznych:

- `CoreBluetooth` — komunikacja z Kapslem,
- `SwiftUI.MenuBarExtra` — pasek menu,
- `NSAppleScript` (Apple Events) — sterowanie przeglądarką,
- `AppKit.NSSound` — sygnały dźwiękowe,
- `ServiceManagement.SMAppService` — uruchamianie przy logowaniu.

Projekt jest **pakietem SPM** ze skryptem składającym `.app` (`Info.plist`,
ikona, podpis). Wszystko jest plikami tekstowymi — brak `.xcodeproj`, którego
nie da się utrzymywać poza GUI Xcode. Koszt: brak podglądów SwiftUI
i debuggera Xcode.

Aplikacja jest typu accessory (`LSUIElement`) — bez ikony w Docku.
Identyfikator: `pl.tweetgeek.trikimute`.

**Podpis stałą tożsamością** `Apple Development: Sebastian Dawidziak`. macOS
wiąże zgody TCC (Bluetooth, Automation) z podpisem aplikacji — bez stałego
podpisu każda przebudowa unieważnia zgody i wymusza ich ponowne przyznanie.

Uzasadnienie wyboru Swifta wobec istniejącego projektu MiniMute:
[ADR 0001](../../adr/0001-swift-zamiast-tauri.md).

## Środowisko

- macOS 26.6.1, Xcode 26.6 (zweryfikowane)
- Google Chrome i Brave Browser (oba zainstalowane i w użyciu)
- Kapsel dostępny do testów na stałe

## Protokół urządzenia

Ustalenia przejęte z TrikiScope:

- Nordic UART Service: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
  - RX (zapis, host → Kapsel): `6e400002-b5a3-f393-e0a9-e50e24dcca9e`
  - TX (notyfikacje, Kapsel → host): `6e400003-b5a3-f393-e0a9-e50e24dcca9e`
- komenda startowa strumienia zapisywana na RX: `20 10 00 D0 07 68 00 03`
- ramka IMU: 14 bajtów, nagłówek `22 00` (przycisk puszczony)
  lub `22 01` (przycisk wciśnięty), dalej 6 osi `int16` little-endian
- poziom baterii: standardowa charakterystyka SIG `0x2A19`, z notyfikacjami
- Kapsel zasypia; budzi go naciśnięcie przycisku

**Konsekwencja projektowa.** Stan przycisku jest zaszyty w nagłówku ramek IMU,
a strumień rusza dopiero po komendzie startowej. Nie istnieje znany sposób
odczytu samego przycisku — aby wykryć naciśnięcie, Kapsel musi nadawać pełny
strumień ~104 ramek na sekundę. Stąd model Uzbrojenia (niżej).

## Architektura

Jednokierunkowy łańcuch, każdy komponent z jedną odpowiedzialnością:

```
CoreBluetooth → FrameParser → ButtonRecognizer → MeetController → przeglądarka
                     ↓              ↓                  ↓
                  AppState  ←───────┴──────────────────┘
                     ↓
           MenuBarExtra + Feedback (dźwięk)
```

Warstwy nie znają się „w górę": `TrikiConnection` nic nie wie o Meet,
`MeetController` nic nie wie o Bluetooth.

### TrikiConnection

Opakowuje `CBCentralManager`. Emituje na zewnątrz wyłącznie: surowe `Data`
z timestampem, stan połączenia, procent baterii, RSSI.

### FrameParser

Bufor bajtów z resynchronizacją po nagłówku. Szuka `22 00` lub `22 01`, odcina
14 bajtów, zwraca stan przycisku (`Bool`) z timestampem. Dane IMU są odrzucane.

Odporność: ramka o złej długości lub z nieznanym nagłówkiem jest odrzucana,
a parser szuka kolejnego znacznika — nie blokuje się na uszkodzonym strumieniu.
Musi obsłużyć ramki sklejone w jednej notyfikacji (Kapsel nadaje burstami)
oraz ramki ucięte na granicy notyfikacji.

### ButtonRecognizer

Flaga przycisku przychodzi jako *poziom* w każdej ramce, nie jako zdarzenie.
Komponent wykrywa zbocza: `0→1` = wciśnięcie, `1→0` = puszczenie.

- puszczenie przed progiem → Naciśnięcie
- przekroczenie progu w trakcie trzymania → Przytrzymanie, emitowane
  **natychmiast**, bez czekania na puszczenie; ustawiana jest flaga tłumiąca
  Naciśnięcie przy następującym puszczeniu

Stałe trzymane w jednym miejscu: próg Przytrzymania **0,4 s**, debounce zboczy
30 ms, cooldown po zdarzeniu 300 ms. Próg wynika z pomiaru na żywym Kapslu
(`docs/findings/2026-08-12-kapsel.md`), nie z założenia.

### MeetController

Publiczne API: `toggle(.microphone)` / `toggle(.camera)` oraz `probe()`.

Wewnątrz `NSAppleScript` z poleceniem `execute javascript in tab`. Karta **nie
musi być aktywna ani na wierzchu** — to jedyny mechanizm spełniający wymóg
działania bez zabierania focusu. Uzasadnienie wobec alternatywy w postaci
rozszerzenia przeglądarki: [ADR 0002](../../adr/0002-apple-events-zamiast-rozszerzenia.md).

Wstrzykiwany JavaScript klika realny przycisk w DOM. Meet nie ma API,
a syntetyczny `Cmd+D` przez `dispatchEvent` nie zadziała, bo obsługa skrótów
reaguje wyłącznie na zaufane zdarzenia. Przycisk wybieramy po atrybucie
`data-is-muted`, nie po `aria-label` — etykieta jest tłumaczona i rozjechałaby
się przy zmianie języka interfejsu.

**Wybór Celu.** Odpytywane są obie przeglądarki. Kolejność: aktywna karta
przeglądarki na wierzchu, potem pozostałe karty. Wygrywa pierwsza, w której
znaleziono przycisk mikrofonu. W danej chwili istnieje najwyżej jeden Cel.

**Sonda.** `probe()` jest wywoływana co 3 sekundy, wyłącznie gdy Kapsel jest
uzbrojony, i zwraca jednocześnie: czy Cel istnieje oraz stan wyciszenia
mikrofonu. To jedno zapytanie odpowiada więc na pytania „gdzie działać",
„czy da się teraz zadziałać" i „jaki jest stan" — stan wyciszenia nie kosztuje
nic ponad to, co i tak musimy odpytywać, by wykryć koniec rozmowy.

Selektory DOM żyją w jednym miejscu w kodzie, żeby poprawka po przebudowie
interfejsu przez Google była jednolinijkowa.

Konfiguracja jednorazowa po stronie użytkownika, osobno dla każdej przeglądarki:

1. `View → Developer → Allow JavaScript from Apple Events`
2. systemowa zgoda na Automation (macOS pyta sam przy pierwszym użyciu);
   wymaga `NSAppleEventsUsageDescription` w `Info.plist`

### AppState

`@Observable`, jedyne źródło prawdy dla UI: stan Kapsla, Gotowość, poziom
baterii, RSSI, stan wyciszenia, ostatnia Akcja, stan błędu.

## Cykl życia połączenia

**Model Uzbrojenia.** Śpiący Kapsel nie reklamuje się w eterze, więc aplikacja
nie ma jak się z nim połączyć z własnej inicjatywy. Pierwsze naciśnięcie budzi
Kapsel i zestawia połączenie — i z definicji **nie wywołuje Akcji**, bo
w chwili naciśnięcia aplikacja jeszcze nie słuchała. Pasek menu pokazuje
osiągnięcie Gotowości. Reszta rozmowy działa normalnie.

Rozwiązanie odrzucone: stałe połączenie od logowania. Dawałoby natychmiastową
gotowość kosztem ciągłego strumienia 104 Hz przez cały dzień roboczy.

**Zestawianie połączenia.** Po potwierdzonym parowaniu (niżej) identyfikator
Kapsla jest zapamiętywany, a aplikacja utrzymuje zawieszone `connect()` na
pobranym `CBPeripheral` — CoreBluetooth podniesie połączenie samo, gdy tylko
Kapsel się odezwie, bez ciągłego skanowania po stronie aplikacji. Skanowanie
jest potrzebne wyłącznie w trakcie samego parowania.

Rozłączenie w trakcie rozmowy jest natychmiast widoczne w pasku menu.

**Parowanie — z wyboru, nie automatyczne.** Wcześniejsza wersja tej sekcji
opisywała parowanie jako w pełni automatyczne: aplikacja łączyła się z
pierwszym urządzeniem, którego nazwa zawierała „triki". To założenie nie
przetrwało dwóch Kapsli naraz — reklamy BLE nie są zsynchronizowane, więc
wybór pierwszego napotkanego był losowy, a nazwa reklamowana przez urządzenie
(zawierająca jego numer seryjny) i tak nic nie mówi trzymającemu go
człowiekowi. Model dziś:

1. Użytkownik uruchamia parowanie z paska menu — jest to naturalny pierwszy
   krok bez zapisanego urządzenia, a przy już zapisanym służy do jego zmiany
   (zastępuje dawny osobny „Zapomnij Kapsel" — wybranie i potwierdzenie
   nowego urządzenia jest nadzbiorem zapominania starego).
2. `TrikiConnection` przełącza się w tryb rozpoznawania: skanuje i zgłasza
   pełną listę kandydatów (nazwa, RSSI) do `AppState`, zamiast łączyć się
   z pierwszym napotkanym. Dotychczasowe zapisane urządzenie, jeśli istnieje,
   działa nietknięte przez cały czas przeglądania listy.
3. Wybranie kandydata z listy łączy się z nim i uzbraja go normalną ścieżką,
   ale **nie zapisuje** jeszcze identyfikatora. Zamiast tego aplikacja losuje
   liczbę naciśnięć z zakresu 2–5 i pokazuje polecenie z tą konkretną liczbą.
   Naciśnięcia w tej fazie potwierdzają wybór i **nie trafiają do Meet** —
   inaczej sama próba sparowania właściwego Kapsla wyciszałaby przypadkowo
   mikrofon na dotychczasowym urządzeniu.
4. Komplet naciśnięć na wybranym urządzeniu zapisuje jego identyfikator jako
   Kapsel na stałe; od tej pory łączenie wraca do modelu Uzbrojenia opisanego
   wyżej.
5. Cały krok wyboru i potwierdzenia jest ograniczony jednym wspólnym czasem
   (dziś: 20 s), liczonym od wybrania kandydata. To ograniczenie zamyka dwa
   różne tryby awarii jednym mechanizmem: użytkownika, który naciska za
   wolno lub za mało razy, **oraz** kandydata, który przestał się reklamować
   między wyświetleniem listy a kliknięciem — `connect()` w CoreBluetooth nie
   ma własnego limitu czasu i bez tej granicy zawiesiłby parowanie na
   „szukam" bez wyjścia poza jego przerwaniem. Ponieważ w obu przypadkach
   żadne naciśnięcie nie nadejdzie przed upływem czasu, jeden odliczany
   termin — bez osobnej fazy „łączę się" i bez usuwania nieaktualnych
   kandydatów z listy — wystarcza, by żaden z nich nie zawiesił aplikacji.
   Po upływie czasu faza wraca do listy kandydatów z czytelnym komunikatem.
6. Parowanie da się przerwać na każdym etapie; przerwanie zawsze zostawia
   dotychczasowe urządzenie dokładnie w takim stanie, w jakim było przed
   `startPairing()`.

Sonda Meet (niżej) nie działa w trakcie parowania — nie ma czego odpytywać,
a odpytywanie przeglądarek konkurowałoby o tę samą kolejkę skryptów.

## Sprzężenie zwrotne

Cała wartość Kapsla polega na tym, że nie patrzysz na ekran — więc pasek menu
jest złym kanałem na komunikat o niepowodzeniu. Kanałem podstawowym jest dźwięk
w słuchawkach, w trzech rozróżnialnych wariantach:

| Sytuacja | Sygnał |
|---|---|
| Akcja wykonana | krótki sygnał potwierdzenia |
| brak Celu (Kapsel uzbrojony, naciśnięcie dotarło) | łagodny sygnał neutralny |
| Cel istnieje, ale Akcja nie przeszła | sygnał błędu |

Nieuzbrojony Kapsel nie wywoła żadnego dźwięku — aplikacja nie wie o jego
naciśnięciu. Cisza w tej sytuacji jest nieunikniona i oznacza brak Gotowości.

Rozróżnienie „brak Celu" od „błąd" istnieje dlatego, że skoro sukces jest
słyszalny, cisza byłaby nieodróżnialna od awarii aplikacji.

## Interfejs

Ikona w pasku menu pokazuje jednym rzutem oka: Kapsel rozłączony, uzbrojony,
oraz — gdy istnieje Cel — czy mikrofon jest wyciszony.

Rozwijane menu:

- stan Kapsla i Gotowości
- poziom baterii (procent) i RSSI
- wykryty Cel (przeglądarka i stan) albo jego brak
- ostatnia Akcja
- parowanie: pozycja startowa poza sesją; w trakcie — lista kandydatów
  z siłą sygnału, albo polecenie naciśnięć z licznikiem pozostałych, albo
  komunikat o niepowodzeniu; zawsze z opcją przerwania
- przełącznik „uruchamiaj przy logowaniu" (`SMAppService`)
- akcja testowa (przełącz mikrofon bez Kapsla)
- wyjście

Bez osobnego okna preferencji — całość mieści się w menu.

## Obsługa błędów

Zasada: nigdy nie milcz. Każdy tryb awarii ma odrębny stan w pasku menu, wraz
z instrukcją naprawy i — gdzie to możliwe — przyciskiem otwierającym właściwy
panel Ustawień systemowych:

| Sytuacja | Wykrycie |
|---|---|
| Bluetooth wyłączony w systemie | stan `CBCentralManager` |
| brak zgody na Bluetooth | stan autoryzacji `CBManager` |
| Kapsel śpi lub jest poza zasięgiem | brak połączenia |
| brak zgody na Automation | kod błędu z `NSAppleScript` |
| wyłączone „Allow JavaScript from Apple Events" | charakterystyczny błąd przeglądarki |
| brak Celu | pusty wynik sondy |
| przycisk nieodnaleziony w DOM | wartość zwrócona przez sondę |

Dwa ostatnie są najbardziej podstępne, bo wszystko wygląda na sprawne —
dlatego Akcja, która nie trafiła w przycisk, jawnie zgłasza porażkę zamiast
udawać sukces.

## Testy

Testy jednostkowe, bez sprzętu i bez przeglądarki:

- `FrameParser`: strumień pocięty w losowych miejscach, dwie ramki sklejone
  w jednej notyfikacji, śmieci przed nagłówkiem, ramka ucięta na granicy
  notyfikacji, oba warianty nagłówka
- `ButtonRecognizer`: przycisk trzymany przez wiele ramek, Przytrzymanie tuż
  poniżej i tuż powyżej progu, tłumienie Naciśnięcia po Przytrzymaniu,
  debounce, cooldown
- `MeetController`: przez podstawiony wykonawca skryptów — weryfikujemy
  wygenerowany JavaScript i AppleScript oraz interpretację odpowiedzi,
  bez uruchamiania przeglądarki
- wybór Celu: reguła pierwszeństwa przy wielu kandydatach
- `PairingConfirmation`: zliczanie naciśnięć, tłumienie Przytrzymania, upływ
  czasu, stan końcowy po potwierdzeniu i po upływie czasu
- `AppState` w trakcie parowania (przez wstrzykiwane atrapy, bez sprzętu):
  naciśnięcie w fazie potwierdzania nie trafia do Meet, komplet naciśnięć
  zapisuje identyfikator i kończy parowanie, upływ czasu kończy się porażką
  bez zapisu, przerwanie zostawia dotychczasowe urządzenie nietknięte,
  naciśnięcie poza parowaniem działa jak dotąd, a kandydat, który nie
  odpowiada w wyznaczonym czasie, kończy się porażką zamiast zawieszeniem

Test ręczny: warstwa CoreBluetooth na Kapslu, Akcje w prawdziwym Meet oraz
pełny przebieg parowania (jeden i, jeśli dostępne, dwa Kapsle naraz).

## Niewiadome do rozstrzygnięcia pomiarem

Wszystkie są rozstrzygane przed napisaniem zależnego od nich kodu:

1. Czy `data-is-muted` odróżnia mikrofon od kamery samym porządkiem w DOM.
2. Czy Brave ma przełącznik „Allow JavaScript from Apple Events". Jeśli nie,
   dla Brave całe podejście Apple Events odpada i zostaje samo Chrome.
3. Ile Kapsel wytrzymuje na ciągłym strumieniu. Zmierzone zostanie na gotowej
   aplikacji podczas prawdziwej rozmowy, a nie na skrypcie testowym.

## Kolejność budowy

1. **Spike DOM** — struktura przycisków mikrofonu i kamery w prawdziwej
   rozmowie; weryfikacja przełącznika Apple Events w Chrome i Brave.
   Blokuje `MeetController`.
2. **Spike sprzętowy** — zachowanie Kapsla: sen, wybudzanie, bateria przy
   ciągłym strumieniu. Blokuje strojenie cyklu życia połączenia.
3. `FrameParser` + `ButtonRecognizer` z testami (czysta logika, bez sprzętu).
4. `TrikiConnection` — połączenie, strumień, model Uzbrojenia.
5. `MeetController` — sonda i Akcje.
6. `MenuBarExtra` + `AppState` + sygnały dźwiękowe.
7. Skrypt budujący `.app` z podpisem, `SMAppService`.
