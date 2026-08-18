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

**Rozłączenie z bezczynności.** Wcześniejsza wersja tej sekcji zakładała, że
aplikacja po uzbrojeniu zostaje połączona bez końca. Pomiar na żywym
urządzeniu obalił to założenie: 98%→90% baterii w ciągu jednej nocy, czyli
około dwunastu dni czuwania zamiast tygodni, jakich należałoby oczekiwać po
sprzęcie w spoczynku. Przyczyna jest znana i udokumentowana wyżej — stan
przycisku jest zaszyty w nagłówku ramek IMU, a strumień rusza dopiero po
komendzie startowej, więc uzbrojony Kapsel musi nadawać ~106 ramek/s bez
przerwy, żeby aplikacja miała jak zauważyć naciśnięcie. Nie istnieje znany
sposób usypiania Kapsla na żądanie — TrikiScope dokumentuje wyłącznie komendę
startową, a szukanie komendy usypiającej byłoby reverse engineeringiem
o niepewnym wyniku, którego świadomie nie podjęto.

Rozłączenie jest niezawodnym zamiennikiem nieznanej komendy usypiającej: bez
połączenia Kapsel przestaje nadawać i zasypia sam, dokładnie tak jak wtedy,
gdy aplikacja nie działa. Polityka: aplikacja rozłącza się, gdy Kapsel jest
uzbrojony i przez 10 minut nie istnieje żaden Cel. Zegar bezczynności liczy się
od nowa przy każdym pojawieniu się Celu (sonda odpytuje co 3 s, więc trwa to
przez całą rozmowę) i przy każdym zdarzeniu przycisku — długie spotkanie bez
ani jednego naciśnięcia nie rozłączy Kapsla, dopóki trwa. Rozłączenie zostawia
zapamiętany identyfikator nietknięty — w odróżnieniu od „Zapomnij Kapsel".

**Oczekiwanie na faktyczne zaśnięcie.** Wcześniejsza wersja tej sekcji
zakładała, że zawieszone `connect()` można wznowić w tej samej chwili, w
której aplikacja się rozłączy — że rozłączenie z bezczynności nie różni się
dla użytkownika od zwykłej utraty zasięgu. Usterka znaleziona ręcznie: kapsel
usypiał widowiskowo w pasku menu, po czym natychmiast wracał do uzbrojenia,
bo Kapsel po rozłączeniu jeszcze przez chwilę się reklamuje — a zawieszone
`connect()` łapało go z powrotem w ułamku sekundy, wznawiając strumień
i unieważniając cały sens rozłączenia. Niewiadoma, którą ten dokument
i `docs/findings/2026-08-12-kapsel.md` zostawiały otwartą („czas do zaśnięcia
bez połączenia nie został zmierzony"), okazała się mieć znaczenie
praktyczne, nie tylko teoretyczne. Zmierzone: **Kapsel reklamuje się jeszcze
przez około 180 sekund po rozłączeniu**, zanim faktycznie zaśnie i zniknie
z eteru (`docs/findings/2026-08-12-kapsel.md`, dopisek 2026-08-13).

Naprawa: po rozłączeniu na żądanie aplikacja nie wznawia zawieszonego
`connect()` od razu, tylko wchodzi w osobny stan — `DeviceState.fallingAsleep`
— i skanuje krótkimi seriami w poszukiwaniu tego konkretnego, zapisanego
identyfikatora (inny kapsel reklamujący się w pobliżu nic nie mówi o tym
naszym). Seria trwa 4 s, nowa zaczyna się co 20 s (20% czasu skanowania,
80% przerwy) — Kapsel potrzebuje ok. trzech minut, więc sprawdzanie co 20 s
zauważa zniknięcie w niewielkim ułamku tego okna, bez skanowania niemal bez
przerwy. Całość ma nadrzędny limit **270 s (4,5 minuty)** — z rozsądnym
zapasem (~50%) ponad zmierzone 180 s — na wypadek, gdyby urządzenie nigdy nie
zniknęło z reklam; po jego upływie aplikacja wznawia zawieszone `connect()`
mimo wszystko, tak samo jak przy zniknięciu. Ten limit ma przy okazji miły
efekt uboczny: naciśnięcie przycisku w trakcie usypiania podtrzymuje
reklamowanie Kapsla w nieskończoność, więc urządzenie nigdy nie znika z
eteru — to właśnie limit, nie zniknięcie, kończy wtedy oczekiwanie
i uzbraja Kapsla, dokładnie tak, jak użytkownik by tego chciał, naciskając
przycisk w tym oknie. Logika decyzyjna (czy zakończyć oczekiwanie, i dlaczego)
żyje w osobnym, czysto testowalnym typie, `SleepWait`, bez śladu
CoreBluetooth. Naciśnięcie przycisku w trakcie `.fallingAsleep` nic nie robi
— nie ma jeszcze połączenia, do którego mogłoby dotrzeć — dlatego pasek menu
dostał dla tego stanu osobny, uczciwy tekst („Kapsel zasypia — naciśnięcie
na razie nic nie zrobi"), zamiast dzielić go z tekstem stanu „szukam"
(„Szukam Kapsla — naciśnij przycisk, żeby go obudzić"), gdzie naciśnięcie
faktycznie budzi urządzenie. Ikona paska menu współdzieli jednak symbol
księżyca z „rozłączony"/„szukam" — rozróżnienie ma znaczenie dopiero po
otwarciu menu, nie na pierwszy rzut oka. Stan `.fallingAsleep` da się opuścić
tylko przez zakończenie oczekiwania (zniknięcie albo limit), rozpoczęcie
nowego parowania, albo „Zapomnij Kapsel" — każde z nich jawnie anuluje
oczekiwanie zamiast zostawiać je działające w tle.

Po zakończeniu oczekiwania (zniknięciem albo limitem) aplikacja wznawia
zawieszone `connect()` i pasek menu wraca do tekstu „Szukam Kapsla — naciśnij
przycisk, żeby go obudzić", bo to dokładnie ten sam stan, w jakim aplikacja
czeka na pierwsze uzbrojenie po starcie.

**Rozłączenie na żądanie.** To samo rozłączenie da się wywołać ręcznie
z paska menu — pozycja „Uśpij Kapsel", widoczna wyłącznie gdy Kapsel jest
uzbrojony (nieuzbrojony już śpi albo nigdy nie był sparowany, więc nie ma
czego usypiać). To nie jest osobna ścieżka: `AppState.sleepDevice()` woła
dokładnie ten sam `TrikiConnection.disconnectIdle()`, którego używa
rozłączenie z bezczynności — różni się wyłącznie wyzwalacz (kliknięcie
w menu zamiast upływu `idleTimeout`), nie skutek — i przechodzi przez to samo
oczekiwanie na faktyczne zaśnięcie opisane wyżej. Aplikacja rozłącza się,
a Kapsel zasypia w konsekwencji tego rozłączenia — to wciąż nie jest
wysłanie żadnej komendy usypiającej, bo taka nie istnieje (patrz wyżej).
Identyfikator przeżywa nietknięty, dokładnie jak przy rozłączeniu
z bezczynności, więc kolejne naciśnięcie ponownie uzbraja Kapsla przez ten
sam zawieszony `connect()`, gdy tylko oczekiwanie się zakończy.

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
   nowego urządzenia jest nadzbiorem zapominania starego). Etykieta przycisku
   („Paruj Kapsla" / „Zmień Kapsla") zależy od tego, czy identyfikator jest
   zapisany — nie od bieżącego stanu połączenia, który może akurat pokazywać
   błąd (np. wyłączony Bluetooth) mimo zapisanego urządzenia. Jeśli Bluetooth
   nie jest gotowe, uruchomienie parowania odmawia startu i pokazuje
   konkretną przyczynę zamiast fałszywie zgłaszać trwające skanowanie.
2. `TrikiConnection` przełącza się w tryb rozpoznawania: skanuje i zgłasza
   pełną listę kandydatów (nazwa, RSSI) do `AppState`, zamiast łączyć się
   z pierwszym napotkanym. Dotychczasowe zapisane urządzenie, jeśli istnieje,
   działa nietknięte przez cały czas przeglądania listy. Kapsel zasypia i nie
   reklamuje się, dopóki ktoś nie naciśnie jego przycisku — lista przypomina
   o tym wprost, żeby pusta lista nie wyglądała na awarię. Skanowanie ma
   własny limit czasu (2 minuty): porzucone menu nie zostawia aplikacji
   skanującej bez końca z wyłączoną sondą Meet. Zmiana stanu Bluetootha
   w trakcie parowania (np. wyłączenie i włączenie) restartuje skanowanie
   zamiast wznawiać zawieszone połączenie z zapisanym urządzeniem — inaczej
   mogłoby przejąć sesję parowania i podmienić urządzenie, z którym aplikacja
   faktycznie się łączy.
3. Wybranie kandydata z listy łączy się z nim. Zanim faktycznie się uzbroi,
   aplikacja pokazuje osobną fazę „łączę się" — z jednym ograniczeniem czasu
   (dziś: 10 s) na dotarcie do Gotowości. `connect()` w CoreBluetooth nie ma
   własnego limitu, a kandydat, który przestał się reklamować między
   wyświetleniem listy a kliknięciem, i tak może już nie istnieć — bez tej
   granicy parowanie zawiesiłoby się na „łączę się" bez wyjścia poza jego
   przerwaniem. Wymagana liczba naciśnięć (2–5) jest losowana raz, w chwili
   wyboru — nie zmienia się już do końca próby parowania tego kandydata.
4. Po osiągnięciu Gotowości aplikacja pokazuje polecenie z konkretną liczbą
   naciśnięć i przechodzi do osobnej fazy potwierdzania, z **własnym**
   ograniczeniem czasu (dziś: 15 s) liczonym od chwili uzbrojenia, nie od
   wyboru kandydata — więc czas spędzony na łączeniu nigdy nie ujmuje czasu
   na naciśnięcia. Naciśnięcia w tej fazie potwierdzają wybór i **nie
   trafiają do Meet** — inaczej sama próba sparowania właściwego Kapsla
   wyciszałaby przypadkowo mikrofon na dotychczasowym urządzeniu. Rozłączenie
   w trakcie potwierdzania cofa fazę do „łączę się" (z tym samym, raz
   wylosowanym wymogiem, ale wyzerowanym postępem naciśnięć — rozłączone
   połączenie niczego nie potwierdziło) zamiast zostawiać na ekranie
   nieaktualny licznik przeciw urządzeniu, którego już nie ma. Wyzerowanie
   jest widoczne w komunikacie, nie tylko w danych — bez tego użytkownik,
   który nacisnął już dwa z trzech razy, naciskałby tylko raz więcej i nie
   rozumiałby, dlaczego mimo to upłynął czas.
5. Osobne liczniki „łączę się" i „potwierdzanie" naprawiły wcześniejszy
   problem (zbyt mało czasu na naciśnięcia po wolnym połączeniu), ale same
   z siebie otworzyły inny: urządzenie migoczące na granicy zasięgu może
   cyklicznie łączyć się i rozłączać szybciej, niż upływa którykolwiek z tych
   dwóch, osobnych limitów — każde rozłączenie odświeża licznik łączenia od
   zera, więc żaden z nich nigdy nie dobiega końca. Jednoprzebiegowy model
   sprzed podziału był na to odporny, bo miał jeden licznik, który nigdy się
   nie odświeżał. Zamyka to trzeci, nadrzędny limit (dziś: 60 s) na całą
   próbę parowania danego kandydata, liczony raz od jego wybrania i nigdy nie
   odświeżany przez restarty liczników cząstkowych — niezależnie od tego, ile
   razy urządzenie zdąży się połączyć i rozłączyć, cała próba i tak kończy
   się porażką w ograniczonym czasie, z komunikatem nazywającym prawdziwą
   przyczynę: powtarzające się rozłączenia, nie pojedynczy wolny krok.
6. Komplet naciśnięć na wybranym urządzeniu zapisuje jego identyfikator jako
   Kapsel na stałe; od tej pory łączenie wraca do modelu Uzbrojenia opisanego
   wyżej. Zapisywany jest identyfikator kandydata wybranego w kroku 3, nie
   identyfikator urządzenia aktualnie połączonego — te dwa mogą się chwilowo
   rozjechać w trakcie ponownego łączenia po rozłączeniu, a jedynym, który
   faktycznie odpowiada na pytanie „które urządzenie użytkownik wybrał", jest
   ten pierwszy.
7. Trzy osobne ograniczenia czasu dają trzy osobne, trafne komunikaty
   o niepowodzeniu: „Kapsel nie odpowiedział" dla fazy łączenia, „nie
   potwierdzono wyboru" dla fazy naciśnięć, „Kapsel wielokrotnie się
   rozłączał" dla całej próby — użytkownik nigdy nie czyta komunikatu, który
   nie pasuje do tego, co faktycznie się stało. Po upływie któregokolwiek
   faza wraca do listy kandydatów.
8. Parowanie da się przerwać na każdym etapie; przerwanie zawsze zostawia
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
oraz — gdy istnieje Cel — czy mikrofon jest wyciszony. W trakcie parowania
pokazuje osobny symbol niezależnie od tego wszystkiego: sonda Meet stoi przez
cały czas parowania, więc ikona oparta na stanie mikrofonu twierdziłaby coś,
czego aplikacja akurat nie ma jak wiedzieć — w tym w skrajnym przypadku, gdy
dotychczasowe, zapisane urządzenie zostaje w tle Uzbrojone, a użytkownik
dopiero przegląda listę kandydatów do zmiany.

Rozwijane menu:

- stan Kapsla i Gotowości
- poziom baterii (procent) i RSSI
- wykryty Cel (przeglądarka i stan) albo jego brak
- ostatnia Akcja
- parowanie: pozycja startowa poza sesją; w trakcie — lista kandydatów
  z siłą sygnału, albo „łączę się" z wybranym, albo polecenie naciśnięć
  z licznikiem pozostałych (z zaznaczeniem, gdy licznik właśnie wystartował
  od nowa po rozłączeniu), albo komunikat o niepowodzeniu (osobny dla
  łączenia, dla naciśnięć i dla całej próby); zawsze z opcją przerwania
- „Uśpij Kapsel" — rozłącza uzbrojony Kapsel na żądanie zamiast czekać na
  rozłączenie z bezczynności; widoczne wyłącznie, gdy Kapsel jest uzbrojony
- „Zapomnij Kapsel" — czyści zapamiętany identyfikator; widoczne wyłącznie,
  gdy jakiś jest zapisany
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
- `AppState` w trakcie parowania (przez wstrzykiwane atrapy i wstrzykiwany
  zegar, bez sprzętu): naciśnięcie w fazie potwierdzania nie trafia do Meet,
  komplet naciśnięć zapisuje identyfikator i kończy parowanie, upływ czasu
  naciśnięć kończy się porażką z komunikatem właściwym tej fazie i bez
  zapisu, przerwanie zostawia dotychczasowe urządzenie nietknięte,
  naciśnięcie poza parowaniem działa jak dotąd, kandydat, który nigdy się nie
  uzbraja, kończy się porażką z komunikatem właściwym łączeniu (odrębnym od
  powyższego) zamiast zawieszeniem, kandydat uzbrojony tuż przed upływem
  czasu łączenia dostaje mimo to pełne okno na naciśnięcia, rozłączenie
  w trakcie potwierdzania wraca do fazy łączenia z tym samym, raz wylosowanym
  wymogiem, ale realnie wyzerowanym postępem naciśnięć — i menu jest o tym
  poinformowane — a urządzenie migoczące szybciej niż którykolwiek z dwóch
  liczników cząstkowych mimo to kończy próbę porażką w ograniczonym czasie
  dzięki trzeciemu, nadrzędnemu limitowi, który restarty tamtych dwóch nie
  odświeżają; dodatkowo (końcowa recenzja): odmowa uruchomienia parowania
  nazywa przyczynę zamiast zgłaszać skanowanie, którego nie ma, odmowa
  potwierdzenia trafia do użytkownika zamiast ciszy, przerwanie w fazie
  potwierdzania nie zostawia żywego licznika po sobie, przerwanie z fazy
  niepowodzenia wraca do stanu nieaktywnego i nie dziedziczy flagi
  „rozłączono" do następnej próby, upływ czasu samego skanowania kończy się
  porażką zamiast wiecznym „szukam", a ikona w trakcie parowania jest inna
  niż w spoczynku
- `AppState` — rozłączenie z bezczynności (przez ten sam wstrzykiwany zegar):
  upływ 10 minut bez Celu rozłącza, obecność Celu i nadchodzące zdarzenia
  przycisku odświeżają zegar i nie dopuszczają do rozłączenia, zapamiętany
  identyfikator przeżywa rozłączenie, a aplikacja przechodzi przez
  `.fallingAsleep` i dopiero po zakończeniu oczekiwania wraca do „szukam" —
  nie do rozłączenia bez zapisanego urządzenia
- `AppState.sleepDevice()` — to samo rozłączenie wywołane ręcznie: rozłącza
  i zostawia zapamiętany identyfikator nietknięty (jak wyżej, ten sam
  dowód), jest bez efektu, gdy Kapsel nie jest uzbrojony (nie ma czego
  usypiać), i jest bez efektu w trakcie parowania (wcześniej zapisany Kapsel
  może zostać w tle Uzbrojony, podczas gdy użytkownik przegląda kandydatów
  do zmiany — nie jest to ten Kapsel, którego dotyczy przycisk w menu);
  osobny test przypina samą równoważność — obie ścieżki (zegar i ręczna
  akcja) dają identyczną sekwencję `.fallingAsleep` → `.searching`, nie dwie
  niezależnie zachowujące się kopie
- `SleepWait` — czysta logika oczekiwania na faktyczne zaśnięcie, bez
  CoreBluetooth i bez `@MainActor`: widzenie obserwowanego identyfikatora
  w trakcie serii nie kończy oczekiwania, koniec serii bez widzenia kończy
  je jako „zniknął", widzenie innego identyfikatora nic nie znaczy, upływ
  nadrzędnego limitu kończy oczekiwanie nawet w trakcie trwającej serii
  (i nawet gdy urządzenie jest akurat widziane — to właśnie ta ścieżka
  odpowiada za „naciśnięcie w trakcie usypiania mimo to uzbraja"), a
  pierwsze rozstrzygnięcie jest ostateczne — nic nie cofa go później
- `TrikiConnection`: `CentralManaging` — wąski protokół nad pięcioma
  wywołaniami `CBCentralManager`, którego faktycznie używa ten plik —
  pozwala przypiąć testami jednostkowymi część inwariantów, które wcześniej
  sprawdzał wyłącznie test ręczny: odmowę uruchomienia parowania bez
  gotowego Bluetootha, odmowę potwierdzenia bez aktywnej sesji albo bez
  wybranego kandydata, i to, że zmiana stanu Bluetootha w trakcie parowania
  restartuje skanowanie zamiast wznawiać zapisane urządzenie (a bez sesji
  w toku wznawia je dokładnie jak dotąd). Ta sama warstwa pozwala przypiąć
  orkiestrację oczekiwania na zaśnięcie wprost, bez prawdziwego
  `CBPeripheral`: zawieszone `connect()` nie jest wznawiane, dopóki
  urządzenie wciąż się reklamuje, jest wznawiane, gdy zniknie, nadrzędny
  limit wznawia je mimo wszystko, rozpoczęcie parowania w trakcie
  oczekiwania je anuluje, „Zapomnij Kapsel" w trakcie oczekiwania też, a cykl
  zasilania Bluetootha w trakcie oczekiwania wznawia przerwaną serię zamiast
  zawieszonego połączenia — dowód pośredni przez `retrievePeripherals`
  (niewywołany, dopóki oczekiwanie trwa; wywołany raz, gdy się kończy), tym
  samym sposobem, jakim testy tego pliku już radzą sobie z brakiem
  prawdziwego `CBPeripheral`. Nie obejmuje `CBPeripheral` — nie da się go
  stworzyć poza CoreBluetooth — więc ścieżka przechowująca faktyczną
  tożsamość wybranego kandydata (oraz samo okablowanie
  `didDisconnectPeripheral` → `startSleepWait()`) zostaje testem ręcznym.

Test ręczny: warstwa CoreBluetooth na Kapslu (w tym część inwariantów, których
`CentralManaging` nie obejmuje — patrz wyżej), Akcje w prawdziwym Meet oraz
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
