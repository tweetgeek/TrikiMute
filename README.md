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
uruchamiasz parowanie z paska menu, wybierasz właściwy Kapsel z listy
kandydatów (nazwa i siła sygnału — przydaje się, gdy w zasięgu jest więcej niż
jeden) i potwierdzasz wybór, naciskając na nim przycisk tyle razy, ile pokaże
menu. Dopiero komplet naciśnięć zapamiętuje urządzenie na stałe; naciśnięcia
w trakcie potwierdzania nie wyciszają niczego w Meet. Parowanie da się przerwać
w każdej chwili — dotychczasowe urządzenie zostaje wtedy nietknięte. Kapsel nie
reklamuje się, dopóki nie naciśniesz jego przycisku — lista przypomina o tym,
jeśli jest pusta — a samo szukanie ma limit czasu, więc porzucone menu nie
zostawia aplikacji skanującej bez końca. W trakcie parowania ikona w pasku
menu pokazuje osobny symbol, bo nie ma wtedy jak sprawdzić stanu mikrofonu.

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
