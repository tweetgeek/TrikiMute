# Sprawy odroczone

Znaleziska z recenzji, które świadomie odłożono. Każde zostało rozważone
i uznane za niewymagające naprawy przed pierwszym wydaniem. Lista istnieje po
to, żeby decyzje nie przepadły — nie jako lista życzeń.

Kolejność mniej więcej według wartości naprawy.

## Warte zrobienia przy następnym dotknięciu kodu

**Jeden Apple Event na kartę zamiast jednego na przeglądarkę.** Stara ścieżka
wysyłała **jedno** zdarzenie na przeglądarkę i cały obchód okien i kart
odbywał się wewnątrz Chrome. Nowa pyta osobno o okna, potem o karty każdego
okna, a potem o adres każdej karty — ScriptingBridge nie grupuje odczytów
właściwości, więc przy dwóch oknach i trzydziestu kartach wychodzi około
trzydziestu trzech synchronicznych zapytań na Instancję, co 3 sekundy, przez
cały czas uzbrojenia. To budzi główny wątek przeglądarki jakieś 600 razy na
minutę w imieniu narzędzia z paska menu — i zazębia się z wpisem o takcie
sondy powyżej.

Naprawa jest znana: `tabs.arrayByApplyingSelector(#selector(getter:
ScriptableTab.URL))` pobiera adresy hurtowo, jedno zdarzenie na okno, po czym
`ScriptingBridgeTab` powstaje wyłącznie dla kart, które trafiły w Meet — ścina
ruch o jakieś 95%. Świadomie odłożone: dokłada nietestowanego kodu
ScriptingBridge w pliku, którego jeszcze nie uruchomiono na prawdziwej
przeglądarce, więc rozsądnie zrobić to razem z testem sprzętowym opisanym
w sekcji „Niezweryfikowane na żywo", a nie przed nim.

**Zrobione: zużycie baterii Kapsla przy stałym połączeniu.** Zmierzone na
żywym urządzeniu: 98%→90% w ciągu jednej nocy, czyli około dwunastu dni
czuwania zamiast tygodni, jakich należałoby oczekiwać po sprzęcie
w spoczynku — gorzej, niż wcześniejsze „niezweryfikowane" założenie
sugerowało. Przyczyna była znana i udokumentowana od początku: stan
przycisku jest zaszyty w nagłówku ramek IMU, a strumień rusza dopiero po
komendzie startowej, więc uzbrojony Kapsel musiał nadawać ~106 ramek/s bez
przerwy, żeby aplikacja miała jak zauważyć naciśnięcie — a aplikacja po
uzbrojeniu nigdy się nie rozłączała, więc strumień szedł całą noc bez
żadnej rozmowy w tle. Nie istnieje znany sposób usypiania Kapsla na
żądanie — TrikiScope dokumentuje wyłącznie komendę startową — a szukanie
komendy usypiającej byłoby reverse engineeringiem o niepewnym wyniku,
świadomie nieodbytym. Naprawione rozłączeniem: bez połączenia Kapsel
przestaje nadawać i zasypia sam, dokładnie jak wtedy, gdy aplikacja nie
działa, a model Uzbrojenia i tak trzyma zawieszone `connect()`, które
podnosi połączenie z powrotem, gdy tylko naciśnięcie przycisku obudzi
Kapsla. Polityka: rozłączenie po 10 minutach bez Celu, z zegarem liczonym
od nowa przy każdym pojawieniu się Celu i przy każdym zdarzeniu przycisku,
żeby długie spotkanie bez naciśnięć nie rozłączyło Kapsla w trakcie.
Zapamiętany identyfikator przeżywa rozłączenie — to nie jest „Zapomnij
Kapsel" — a pasek menu wraca do tego samego „Szukam Kapsla — naciśnij
przycisk, żeby go obudzić", co po zwykłym starcie aplikacji.

**Zrobione: rozłączenie z bezczynności i „Uśpij Kapsel" nie usypiały
faktycznie Kapsla.** Usterka znaleziona ręcznie, dzień po wpisie powyżej:
obie ścieżki rozłączały się, po czym w tej samej chwili wznawiały zawieszone
`connect()` — a Kapsel po rozłączeniu jeszcze przez chwilę się reklamuje, więc
CoreBluetooth łączył się z powrotem w ułamku sekundy, strumień ruszał od nowa,
a pasek menu pokazywał tylko mignięcie ikony snu. Przyczyna: niewiadoma, którą
`docs/findings/2026-08-12-kapsel.md` wprost zostawiał otwartą — „czas do
zaśnięcia bez połączenia nie został zmierzony" — a projekt milcząco założył,
że rozłączenie samo w sobie wystarcza. Zmierzone dopiero teraz: **Kapsel
reklamuje się jeszcze przez około 180 sekund po rozłączeniu**, zanim faktycznie
zaśnie (dopisek w tym samym pliku findings). Naprawione typem `SleepWait`
(czysta logika, bez CoreBluetooth) plus sekcją „Sleep wait" w
`TrikiConnection`: po rozłączeniu na żądanie aplikacja skanuje krótkimi seriami
(4 s co 20 s) w poszukiwaniu tego konkretnego, zapisanego identyfikatora i
wznawia zawieszone `connect()` dopiero, gdy urządzenie faktycznie zniknie z
reklam — albo gdy upłynie nadrzędny limit 270 s (4,5 min), na wypadek gdyby
nigdy nie zniknęło. Ten limit ma przy okazji miły efekt uboczny: naciśnięcie
przycisku w trakcie usypiania podtrzymuje reklamowanie Kapsla w
nieskończoność, więc to właśnie limit — nie zniknięcie z eteru — kończy
oczekiwanie i uzbraja urządzenie, dokładnie tak, jak użytkownik by tego chciał.
Nowy stan `DeviceState.fallingAsleep` dostał własny wiersz w menu („Kapsel
zasypia — naciśnięcie na razie nic nie zrobi"), żeby nie mylić go ze
„Szukam Kapsla" — tam naciśnięcie faktycznie budzi urządzenie, tu jeszcze nie.
Ikona paska menu współdzieli symbol księżyca z „rozłączony"/„szukam" —
rozróżnienie ma znaczenie dopiero po otwarciu menu.

**Zapis wybranego identyfikatora nie jest pilnowany testem.** To jedyna
obietnica, dla której parowanie z wyboru w ogóle powstało: potwierdzenie ma
zapisać urządzenie, które wskazałeś, a nie to, z którym aplikacja akurat jest
połączona. Testy pokrywają wyłącznie odmowy — brak sesji i brak wybranego
kandydata. Sam zapis opiera się na przeglądzie kodu i na teście ręcznym.

Końcowa recenzja wskazała wyjście, i nie jest nim walka z `CBPeripheral`.
Sesja parowania trzyma wybrane urządzenie jako obiekt, choć zapis potrzebuje
z niego wyłącznie identyfikatora; obiekt jest niezbędny tylko do wywołań
CoreBluetooth przy przerwaniu. Gdyby źródłem prawdy o wyborze był identyfikator,
a obiekt wyszukiwany dopiero w miejscu faktycznego wywołania, decyzja o tym, co
zapisać, sprowadzałaby się do porównania dwóch identyfikatorów — testowalnego
bez żadnego prawdziwego urządzenia. Nietestowalność jest tu więc częściowo
wyborem projektowym, nie ograniczeniem platformy.

**Dwa z trzech testów kolejności sprzątania niczego nie odróżniają.** Przy
usterce, w której faza była przypisywana po wywołaniu warstwy połączenia,
tylko `cancelDuringConfirmingLeavesNoLiveTimerBehind` pada przed poprawką.
Pozostałe dwa to sensowne pokrycie, ale przeszłyby również bez niej — cała waga
weryfikacji tej usterki spoczywa na jednym teście.


**Zrobione: testy `AppState` czytały prawdziwy `NSWorkspace`.** Przez
`BrowserOrder.ordered()` sięgały po aplikację na wierzchu. Gdy przy
uruchamianiu testów była nią przeglądarka, kolejność listy się przestawiała
i `secondProbeQueuesAsPendingNotParallel` padał bez powodu — dokładnie tak,
jak ten wpis przewidywał. Uzasadnienie odłożenia było błędne: „uruchamiane
z terminala są bezpieczne, bo na wierzchu jest terminal" to założenie o
układzie okien akurat tego dewelopera, a nie własność kodu — nic w kodzie
nie gwarantowało, że terminal będzie na wierzchu. Naprawione przez wstrzyknięcie
kolejności przeglądarek tym samym wzorcem co pozostali współpracownicy
`AppState` (`connection`, `controller`, `scriptQueue`, `now`), więc produkcyjne
miejsce wywołania (`AppState()` w `TrikiMuteApp.swift`) się nie zmieniło, a każdy
`AppState` w `AppStateTests.swift` dostaje stałą listę. Przy przejściu na
adresowanie po procesie (ADR-0003) wstrzykiwana zależność zmieniła kształt
z listy nazw na `browserInstances: @MainActor () -> [BrowserInstance]`,
domyślnie `{ RunningBrowsers.instances() }` — sama zasada została ta sama,
a adnotacja `@MainActor` na typie domknięcia oddaje kompilatorowi pilnowanie
reguły, która wcześniej żyła wyłącznie w komentarzu.

**Sonda odpytuje dwie przeglądarki co 3 sekundy bez końca.** Gdy Celu nie ma,
ikona i tak nie ma czego pokazywać, więc rzadszy takt nic nie kosztuje. 3 s przy
istniejącym Celu, 15 s bez niego, ścięłoby ruch Apple Events o cztery piąte
w najczęstszym stanie „uzbrojony, ale nie w rozmowie". To ten sam założeniowy
błąd, który stał za zmierzonym już zużyciem baterii Kapsla (patrz wyżej):
traktowanie „uzbrojony" jednakowo niezależnie od tego, czy Cel istnieje.
Rozłączenie z bezczynności naprawiło stronę Kapsla; ten wpis zostaje, bo
osobno kosztuje też ruch Apple Events po stronie Maca.

**Timer sondy zatrzymuje się, gdy menu jest otwarte.** `Timer.scheduledTimer`
rejestruje się w trybie `.default`, a `MenuBarExtra` śledzi zdarzenia w trybie
`.eventTracking` — więc odświeżanie stoi dokładnie wtedy, gdy patrzysz na stan,
który ma odświeżać. Naprawa: `RunLoop.main.add(timer, forMode: .common)`.

**Dwuznakowa odpowiedź sondy nie jest walidowana.** Znaki inne niż `0`/`1`
dekodują się cicho jako „mikrofon włączony, kamera włączona" zamiast zostać
odrzucone. Dziś nieosiągalne, bo wstrzykiwany JavaScript emituje wyłącznie te
dwa znaki, ale to najtańsze pozostałe utwardzenie z rodziny „awaria nie może
udawać poprawnej odpowiedzi".

**Zrobione: ikona nie odróżniała „brak rozmowy" od „rozmowa, mikrofon
włączony".** Przy uzbrojonym Kapslu i braku Celu pokazywała ten sam symbol co
przy aktywnej rozmowie — `iconName` twierdziło, że mikrofon jest aktywny,
mimo że aplikacja w ogóle nie wiedziała, czy trwa jakakolwiek rozmowa.
Naprawione rozbiciem na siedem stanów: kontur `mic` dla „gotowy, brak
rozmowy" odróżnia się teraz od wypełnionych `mic.fill`/`mic.slash.fill` dla
rozmowy, `moon.zzz.fill` dla uśpienia, `dot.radiowaves.left.and.right` dla
parowania, `questionmark.circle.fill` dla „nie mogę sprawdzić Celu" i
`exclamationmark.triangle.fill` dla awarii urządzenia — ta ostatnia
sprawdzana jako pierwsza, przed parowaniem, żeby awaria Bluetootha w trakcie
parowania nie chowała się za ikoną wyboru urządzenia. Menu dostało tę samą
ikonografię: każdy wiersz (informacyjny i akcja) ma teraz symbol, w tym
bateria dobierana z poziomu naładowania. Pełne uzasadnienie kolejności
i mapowania — w opisie zadania i historii commitów.

**Kanał raportujący awarie sam może zawieść po cichu.** `NSSound(named:)?.play()`
nic nie robi, gdy dźwięku brakuje, a instancja nie jest przetrzymywana na czas
odtwarzania. Działa, ale akurat ten kanał nie powinien móc zawieść bezgłośnie.

## Znane ograniczenia, nie usterki

**Adres karty dopasowywany przez `contains`, bez zakotwiczenia.** Zarówno nowa
ścieżka, jak i zapasowa uznają kartę za rozmowę, jeśli `meet.google.com`
pojawia się gdziekolwiek w adresie — więc `evil.com/?x=meet.google.com` też
pasuje. Zachowanie identyczne jak przed przejściem na adresowanie po procesie,
więc nie regresja, a konsekwencją jest tylko jedno dodatkowe wykonanie
JavaScriptu, które zwróci `NONE`. Rozpoznanie odnotowane w recenzji końcowej.

**Przy kilku awariach naraz zapamiętywana jest ostatnia, nie pierwsza.**
`ScanningMeetBackend` nadpisuje `lastError` przy każdej nieudanej Instancji,
więc komunikat w menu opisuje przyczynę z **ostatniej** przeszukanej
przeglądarki. Kolejność szukania stawia na początku tę, na którą użytkownik
patrzy, więc pierwsza awaria jest zwykle tą istotną — zapamiętywanie pierwszej
zamiast ostatniej byłoby trafniejsze i kosztuje jedną linijkę. Nabrało wagi
dopiero wtedy, gdy komunikaty zaczęły faktycznie docierać do użytkownika
(patrz commit poprawiający `localizedDescription`).

**`meetHost` wstawiany do AppleScriptu bez escapowania.** Sąsiednie
interpolacje w `MeetScripts.appleScript` przechodzą przez `escaped(...)`, ta
jedna nie. Bezczynne, dopóki stała nie zawiera cudzysłowa ani odwrotnego
ukośnika — a zawiera sam adres hosta — ale łamie konwencję własnego pliku.

**Dwie karty Meet naraz.** Skrypt wybiera **pierwszą kartę z kompletem
przycisków** i na niej poprzestaje. Wcześniejsza wersja tego wpisu twierdziła, że
wybiera pierwszą kartę z adresem `meet.google.com` i nie próbuje kolejnych — to
nieprawda: karta, która zwróci `NONE`, jest pomijana i szukanie idzie dalej.
Wniosek zostaje ten sam, bo poczekalnia też ma przyciski `data-is-muted`, więc
otwarta obok trwającej rozmowy wygrywa, jeśli trafi się wcześniej. Kolejność kart
(najpierw okno na wierzchu) sprawia, że zwykle trafia dobrze. Niezawodne
rozpoznanie „czy ta karta jest w rozmowie" nie jest oczywiste, stąd decyzja
o udokumentowaniu zamiast naprawy.

Zasięg tego ograniczenia rośnie wraz z przejściem na adresowanie po procesie
(ADR-0003): kandydatów szukamy odtąd we wszystkich instancjach przeglądarek,
a nie tylko w tych, które wybrał system, więc szansa natknięcia się na cudzą
poczekalnię przed własną rozmową jest większa niż była.

**Ścieżka zapasowa może kliknąć w niewłaściwej instancji.** Po przejściu na
adresowanie po procesie (ADR-0003) AppleScript zostaje jako zapas przy awarii
ScriptingBridge — a z definicji nie potrafi wskazać instancji. Gdy rozmowa toczy
się w dwóch instancjach naraz, zapas kliknie w tej, którą wybrał system:
użytkownik usłyszy dźwięk sukcesu i uzna się za wyciszonego, nie będąc nim. To
jedyne miejsce w aplikacji, gdzie Akcja może zameldować sukces, wykonawszy się
nie tam, gdzie trzeba.

Rozważana była wersja ostrożniejsza — zapas czynny wyłącznie przy dokładnie
jednej instancji danej przeglądarki, bo wtedy nie ma jak trafić źle. Odrzucona
świadomie na rzecz prostoty kodu i testów. Warunek jest wąski (awaria pierwszej
ścieżki, wiele instancji, rozmowa w więcej niż jednej), ale skutek jest cichy,
więc wpis zostaje jako pierwszy kandydat do przemyślenia, gdyby ScriptingBridge
kiedykolwiek faktycznie zawiódł.

**Zapisany identyfikator, który się rozwiązuje, ale jest nieosiągalny.** Kapsel
po resecie fabrycznym albo sparowany z innym komputerem daje wieczne „szukam"
bez samoczynnego powrotu do skanowania. Menu daje dwie drogi wyjścia, dla dwóch
różnych potrzeb: „Zmień Kapsla" uruchamia nowe parowanie niezależnie od stanu
bieżącego (zawieszonego) połączenia, a wybór i potwierdzenie nowego urządzenia
nadpisuje zapisany identyfikator — dla sytuacji, gdy jest czym zastąpić. „Zapomnij
Kapsel" (widoczne w menu tylko gdy `hasSavedDevice` jest prawdziwe) po prostu
czyści zapisany identyfikator i wraca do bezczynności, bez szukania zastępstwa —
dla sytuacji, gdy zastępstwa jeszcze nie ma (zgubiony albo oddany kapsel).
Wcześniejsza wersja tego wpisu twierdziła, że „Zapomnij Kapsel" nie istnieje
i że „Zmień Kapsla" jest jej nadzbiorem — to nigdy nie było prawdą co do
możliwości: zmiana zastępuje, nie usuwa. Wersja `DeviceConnection.forget()`
została skasowana jako rzekomo martwy kod (wywoływana tylko przez testową
atrapę), a ten wpis przy tej samej okazji błędnie przestawiony na nazywanie
„Zmień Kapsla" jedyną ścieżką odzysku. Obie pomyłki naprawione: `forget()`
przywrócone wraz z jego usztywnieniem (zatrzymuje trwające skanowanie
parowania i czyści sesję przed zerwaniem połączenia), a pozycja menu — obok
przycisku parowania.

**Kliknięcie przy stanie „wymaga zatwierdzenia".** Wywołuje ponowną rejestrację
zamiast otworzyć Ustawienia systemowe na panelu elementów logowania.
`SMAppService.register()` jest w tym stanie bezczynne, więc klik nic nie psuje —
ale otwarcie Ustawień byłoby właściwszym zachowaniem.

**Fałszywa synchronizacja parsera.** Ładunek IMU może zawierać bajty `22 00`
i udawać nagłówek. Wymaga to jednak zgubienia bajtów w trakcie połączenia,
a warstwa łącza BLE retransmituje; trwała utrata kończy się rozłączeniem, które
zeruje parser. Mechanizm w dużej mierze leczy się sam.

**Powiadomienia wyłączone bez zgłoszenia błędu.** `didUpdateNotificationStateFor`
z `error == nil` i `isNotifying == false` jest ignorowane. CoreBluetooth nie
produkuje takiego stanu poza rozłączeniem, które obsługujemy osobno.

## Drobiazgi kosmetyczne

- `Blad.errorDescription` jest martwe — konsumenci używają `String(describing:)`.
  Przejście na `localizedDescription` poprawiłoby tekst widziany w menu.
- `kod: 0` jako znacznik „nie zbudowano skryptu" koliduje z konwencją `noErr`.
  Nic nie rozgałęzia się po tej wartości.
- `build-app.sh` nie waliduje argumentu konfiguracji.
- Opóźnienie 0,3 s na ustabilizowanie DOM to jedyna stała czasowa bez nazwy.
- Formatowanie tekstów interfejsu żyje w `AppState`; `MenuBarView` niczego nie
  formatuje. Świadome, ale łączy dwie role w jednym pliku.
- Duplikaty `didDiscover` mogą zlecić po jednym połączeniu każdy. Nieszkodliwe
  przy jednym Kapslu w zasięgu.
- Urządzenie pasujące nazwą, ale bez usługi NUS, daje ciszę zamiast błędu.

## Świadomie odrzucone

**Tryb języka Swift 6.** Cele są przypięte do Swift 5. Końcowa recenzja
argumentowała za przejściem: kod jest już napisany dokładnie w kształcie, jakiego
Swift 6 oczekuje, dzielą go od tego trzy mechaniczne poprawki, a historia usterek
tej gałęzi to głównie ręcznie znalezione wyścigi w tym właśnie kodzie —
kompilator pilnowałby dyscypliny, którą dziś trzymają wyłącznie recenzje.
Odłożone jako osobna praca, żeby nie zmieniać założenia planu w ostatniej fali.

## Potwierdzone na żywym sprzęcie

Testy ręczne przeprowadzone przez użytkownika, nie przez automat:

- Sterowanie Meet bez zabierania focusu; efekt weryfikowany niezależnym
  odczytem stanu rozmowy, nie komunikatem aplikacji o samej sobie.
- Model Uzbrojenia: pierwsze naciśnięcie budzi i nie wywołuje Akcji; kolejne
  przełącza mikrofon; przytrzymanie wyzwala kamerę w chwili przekroczenia progu,
  jeszcze przed puszczeniem przycisku; minuta bezruchu bez zdarzeń widmo.
- Trzy sygnały dźwiękowe rozróżnialne, w tym komunikat o przyczynie przy
  cofniętej zgodzie na Automatyzację.
- Autostart po ponownym zalogowaniu, z pakietem zainstalowanym w `/Applications`.
- Ikony w pasku menu i przy pozycjach menu.
- Rozłączanie i parowanie z wyborem urządzenia.
- Anulowanie zasypiania — powrót do gotowości bez czekania i bez naciskania.
- Okno parowania: otwiera się na wierzchu z aplikacji bez ikony w Docku, lista
  i odliczanie aktualizują się na żywo, liczba naciśnięć czytelna, wiersze
  czytelnie klikalne, nic nie urywa się przy zmniejszaniu okna.

## Niezweryfikowane na żywo

- **Cała ścieżka ScriptingBridge — nie uruchomiona ani razu na prawdziwej
  przeglądarce.** To jedyna warstwa tej zmiany bez pokrycia testami: wiązanie
  z API opiera się na `unsafeBitCast` na protokołach `@objc`, więc literówka
  w nazwie selektora nie jest błędem kompilacji, tylko cichą awarią w czasie
  działania. 169 zielonych testów nie mówi o niej nic. Test odłożony świadomie,
  decyzją użytkownika, przy pełnej świadomości ryzyka.

  Co trzeba sprawdzić, gdy przyjdzie na to pora:

  1. Rozmowa Meet w zwykłej przeglądarce plus druga instancja uruchomiona przez
     `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir=/tmp/druga about:blank`.
     Menu ma pokazywać stan mikrofonu, nie „Brak Celu" — a przed tą zmianą
     pokazywało „Brak Celu", więc warto odtworzyć najpierw samą usterkę, żeby
     mieć pewność, że test sprawdza to, co ma sprawdzać.
  2. Naciśnięcie Kapsla wycisza **tę** rozmowę, nie inną.
  3. Cofnięta zgoda na Automatyzację (Ustawienia systemowe → Prywatność
     i ochrona → Automatyzacja) daje „Nie mogę sprawdzić Celu" i znak zapytania
     w pasku menu — **nie** „Brak Celu". To jest sprawdzian dla `ErrorTrap`:
     ScriptingBridge domyślnie połyka błędy Apple Events, a spike pokazał, że
     przy nieistniejącym procesie delegat nie dostaje nawet wywołania.
  4. Czy którekolwiek okno Chrome zwraca `nil` na pytanie o karty (okno
     DevTools, panel). Od tego zależy, czy warunkowy `throw` przy wymiecionej
     instancji nie daje fałszywych awarii — patrz niżej.

- **Skrajność w warunkowym `throw` przy czytaniu kart.** Gdyby jedno okno
  odpowiedziało zerem kart, a inne nie odpowiedziało wcale, `tabs(in:)` rzuci
  wyjątek, choć jedno okno technicznie odpowiedziało. Wedle semantyki Chrome
  nieosiągalne — okno przeglądarki ma zawsze co najmniej jedną kartę, a okna
  nieczytelne dla ScriptingBridge odpowiadają `nil`, nie pustą listą — ale to
  wniosek z lektury, nie z pomiaru.

- **Zużycie baterii Kapsla przez noc po zmianach usypiających.** To jedyny
  sprawdzian, który rozstrzyga, czy problem zgłoszony przez użytkownika (98% →
  90% przez dobę) faktycznie zniknął. Pierwsza próba naprawy wyglądała poprawnie
  w kodzie i przechodziła testy, a nie działała, bo opierała się na błędnym
  założeniu o zachowaniu firmware'u — dopiero pomiar na sprzęcie to ujawnił.
- Zapis identyfikatora **wybranego** urządzenia przy dwóch Kapslach naraz.
  Parowanie przetestowano, ale nie wiadomo, czy z dwoma urządzeniami w zasięgu —
  a to jedyna ścieżka, dla której ta funkcja powstała, i żaden test jej nie
  pokrywa (patrz wpis wyżej o `CBPeripheral`).
- Utrata i odzyskanie zasięgu — połączenie nie zerwało się ani razu w trakcie
  testów, więc ścieżka ponownego łączenia została prześledzona w kodzie, ale nie
  uruchomiona.
