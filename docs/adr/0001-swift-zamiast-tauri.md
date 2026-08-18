# Swift + SPM zamiast Tauri, mimo istniejącego MiniMute

Siostrzany projekt [MiniMute](../../../MiniMute) zawiera działającą aplikację
BLE w pasku menu napisaną w Tauri/Rust (btleplug), z rozwiązanym rejestrem
urządzeń, trwałością znanych urządzeń i powłoką tray — a jego protokół definiuje
`ButtonCode { Short, Long, Double }`, czyli dokładnie semantykę przycisku, jakiej
potrzebuje TrikiMute. Mimo to piszemy nową aplikację w Swift, bo sprzęt MiniMute
został porzucony, a ciągnięcie jego protokołu i firmware'u byłoby balastem.

## Rozważane opcje

- **Rozszerzenie MiniMute o Triki jako drugie urządzenie** — reużycie ~700 linii
  przetestowanego Rusta i jedna aplikacja dla obu urządzeń. Odrzucone, bo sprzęt
  MiniMute nie wszedł do użycia, a `Device` jest zabity gwoździami do jego
  protokołu, więc i tak wymagałby refaktoru na polimorfizm po typie urządzenia.
- **Nowy projekt Tauri kopiujący wzorce MiniMute** — znajomy stack, ale
  `btleplug` to kolejna warstwa nad CoreBluetooth, a webowe UI nie daje nic przy
  menu bez okna konfiguracyjnego.
- **Python (bleak + rumps)** — warstwa BLE z TrikiScope przeniosłaby się niemal
  1:1, ale `.app` przez PyInstaller waży ~50 MB, wolno startuje, a zgody TCC
  na Bluetooth przypinają się do binarki, więc uruchomienie z terminala przyznaje
  dostęp Pythonowi, nie aplikacji.

## Konsekwencje

Projekt jest pakietem SPM ze skryptem składającym `.app`, bez `.xcodeproj` —
wszystko jest tekstem i daje się utrzymywać poza GUI Xcode, kosztem podglądów
SwiftUI i debuggera. Nie ma reużycia kodu MiniMute; jest natomiast reużycie
jego wniosków (rozpoznane pułapki: wyścig przy starcie, dwuklik w ikonie tray).
