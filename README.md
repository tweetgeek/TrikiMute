# TrikiMute

Aplikacja macOS w pasku menu, która przełącza mikrofon i kamerę w rozmowie
Google Meet na naciśnięcie przycisku kontrolera BLE **Żabka Triki** — bez
zabierania focusu bieżącej aplikacji.

- **Naciśnięcie** przycisku Kapsla przełącza mikrofon.
- **Przytrzymanie** dłuższe niż 0,4 s przełącza kamerę.

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

macOS wiąże zgody Automation z procesem, który faktycznie uruchomił aplikację,
nie z samym plikiem binarnym — dlatego TrikiMute trzeba zawsze uruchamiać przez
`open` albo Findera (jak w sekcji Budowanie), a nie wprost z terminala: binarka
odpalona bezpośrednio z powłoki dziedziczy zgodę terminala, działa pozornie
poprawnie i nigdy nie pojawia się we własnej pozycji w Ustawieniach systemowych.

## Jak to działa

**Parowanie.** Przy pierwszym uruchomieniu (albo żeby zmienić urządzenie)
klikasz pozycję parowania w pasku menu — otwiera się osobne, małe okno, które
zostaje na ekranie przez cały przebieg (menu samo w sobie znika po każdym
kliknięciu, co uniemożliwiało śledzenie licznika naciśnięć na bieżąco). W tym
oknie wybierasz właściwy Kapsel z listy kandydatów (nazwa i siła sygnału —
przydaje się, gdy w zasięgu jest więcej niż jeden) i potwierdzasz wybór,
naciskając na nim przycisk tyle razy, ile pokaże okno, obserwując licznik na
żywo. Dopiero komplet naciśnięć zapamiętuje urządzenie na stałe; naciśnięcia
w trakcie potwierdzania nie wyciszają niczego w Meet. Parowanie da się przerwać
w każdej chwili — dotychczasowe urządzenie zostaje wtedy nietknięte. Kapsel nie
reklamuje się, dopóki nie naciśniesz jego przycisku — lista przypomina o tym,
jeśli jest pusta — a samo szukanie ma limit czasu, więc porzucone okno (albo
zamknięte ręcznie, albo po prostu zignorowane) nie zostawia aplikacji
skanującej bez końca — sesja po prostu działa dalej w tle, a ponowne otwarcie
okna pokazuje jej bieżący stan. Okno zamyka się samo po potwierdzeniu albo po
przerwaniu; po niepowodzeniu zostaje otwarte, żeby komunikat o błędzie
faktycznie było widać, z przyciskiem powrotu do listy kandydatów. W trakcie
parowania ikona w pasku menu pokazuje osobny symbol, bo nie ma wtedy jak
sprawdzić stanu mikrofonu.

Kapsel zasypia i budzi go dopiero naciśnięcie przycisku, więc **pierwsze
naciśnięcie po przerwie tylko go uzbraja** — budzi urządzenie i zestawia
połączenie, nie wywołując Akcji. Pasek menu pokazuje, kiedy Kapsel jest gotowy.

Uzbrojony Kapsel można też uśpić ręcznie z paska menu („Uśpij Kapsel"), zamiast
czekać na automatyczne rozłączenie z bezczynności (po 10 minutach bez
rozmowy) — oszczędza to baterię, bo bez połączenia Kapsel przestaje nadawać
i zasypia sam. Po rozłączeniu Kapsel jeszcze przez chwilę się reklamuje, więc
pasek menu na krótko pokazuje „Kapsel zasypia", zanim wróci do zwykłego
„Szukam Kapsla". Kliknięcie „Uśpij Kapsel" przez pomyłkę da się cofnąć od
razu — w tym samym miejscu w menu pojawia się wtedy „Anuluj usypianie".

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
