# Sprawy odroczone

Znaleziska z recenzji, które świadomie odłożono. Każde zostało rozważone
i uznane za niewymagające naprawy przed pierwszym wydaniem. Lista istnieje po
to, żeby decyzje nie przepadły — nie jako lista życzeń.

Kolejność mniej więcej według wartości naprawy.

## Warte zrobienia przy następnym dotknięciu kodu

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


**Testy `AppState` czytają prawdziwy `NSWorkspace`.** Przez
`BrowserOrder.uporzadkowane()` sięgają po aplikację na wierzchu. Gdyby przy
uruchamianiu testów była nią przeglądarka, kolejność listy by się przestawiła
i test padłby bez powodu. Uruchamiane z terminala są bezpieczne, bo na wierzchu
jest terminal. Naprawa: wstrzyknąć listę przeglądarek zamiast czytać system.

**Sonda odpytuje dwie przeglądarki co 3 sekundy bez końca.** Gdy Celu nie ma,
ikona i tak nie ma czego pokazywać, więc rzadszy takt nic nie kosztuje. 3 s przy
istniejącym Celu, 15 s bez niego, ścięłoby ruch Apple Events o cztery piąte
w najczęstszym stanie „uzbrojony, ale nie w rozmowie". To ten sam mechanizm,
który stoi za niezmierzonym dotąd zużyciem baterii Kapsla.

**Timer sondy zatrzymuje się, gdy menu jest otwarte.** `Timer.scheduledTimer`
rejestruje się w trybie `.default`, a `MenuBarExtra` śledzi zdarzenia w trybie
`.eventTracking` — więc odświeżanie stoi dokładnie wtedy, gdy patrzysz na stan,
który ma odświeżać. Naprawa: `RunLoop.main.add(timer, forMode: .common)`.

**Dwuznakowa odpowiedź sondy nie jest walidowana.** Znaki inne niż `0`/`1`
dekodują się cicho jako „mikrofon włączony, kamera włączona" zamiast zostać
odrzucone. Dziś nieosiągalne, bo wstrzykiwany JavaScript emituje wyłącznie te
dwa znaki, ale to najtańsze pozostałe utwardzenie z rodziny „awaria nie może
udawać poprawnej odpowiedzi".

**Ikona nie odróżnia „brak rozmowy" od „rozmowa, mikrofon włączony".** Przy
uzbrojonym Kapslu i braku Celu pokazuje ten sam symbol co przy aktywnej
rozmowie. Trzeci symbol uczyniłby ją uczciwą na pierwszy rzut oka.

**Kanał raportujący awarie sam może zawieść po cichu.** `NSSound(named:)?.play()`
nic nie robi, gdy dźwięku brakuje, a instancja nie jest przetrzymywana na czas
odtwarzania. Działa, ale akurat ten kanał nie powinien móc zawieść bezgłośnie.

## Znane ograniczenia, nie usterki

**Dwie karty Meet naraz.** Skrypt wybiera **pierwszą** kartę z adresem
`meet.google.com` i nie próbuje kolejnych w tej samej przeglądarce. Przy karcie
poczekalni otwartej obok trwającej rozmowy może więc trafić w poczekalnię, bo
ta też ma przyciski `data-is-muted`. Kolejność kart (najpierw okno na wierzchu)
sprawia, że zwykle trafia dobrze. Niezawodne rozpoznanie „czy ta karta jest
w rozmowie" nie jest oczywiste, stąd decyzja o udokumentowaniu zamiast naprawy.

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

## Niezweryfikowane na żywo

- Zużycie baterii Kapsla przy długiej sesji ciągłego strumienia.
- Utrata i odzyskanie zasięgu — połączenie nie zerwało się ani razu w trakcie
  testów, więc ścieżka ponownego łączenia została prześledzona w kodzie, ale nie
  uruchomiona.
