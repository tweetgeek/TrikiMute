# TrikiMute

Sterowanie mikrofonem i kamerą w rozmowie Google Meet za pomocą fizycznego
kontrolera BLE Żabka Triki, niezależnie od tego, która aplikacja ma focus.

## Język

Konwencja: pojęcia domenowe i interfejs użytkownika pozostają po polsku —
to one są tu ustalonym słownictwem. Kod (typy, właściwości, funkcje,
komentarze) jest po angielsku, zgodnie z resztą ekosystemu Swift. Każdy
poniższy termin ma więc dwie postaci: polską nazwę pojęciową (tu, w
CONTEXT.md, w specyfikacji, w napisach interfejsu) i angielski identyfikator,
pod którym występuje w kodzie.

### Urządzenie

**Kapsel**:
Fizyczny kontroler BLE Żabka Triki w kształcie kapsla, z przyciskiem i czujnikiem
inercyjnym.
_Unikaj_: urządzenie, Triki, pilot, guzik
_W kodzie_: `device`/`peripheral` (np. `DeviceState`, `DeviceConnection`,
`TrikiConnection.peripheral`)

**Uzbrojenie**:
Doprowadzenie kapsla do stanu, w którym reaguje na naciśnięcia — obejmuje jego
wybudzenie i zestawienie połączenia. Naciśnięcie, które uzbraja, nie wywołuje
żadnej akcji.
_Unikaj_: parowanie, inicjalizacja, obudzenie
_W kodzie_: `arming`/`armed` (np. `DeviceState.armed`)

**Naciśnięcie**:
Krótkie wciśnięcie i puszczenie przycisku kapsla. Odpowiada mikrofonowi.
_Unikaj_: klik, tap, press
_W kodzie_: `press` (np. `ButtonEvent.press`)

**Przytrzymanie**:
Wciśnięcie przycisku kapsla utrzymane ponad próg czasowy. Odpowiada kamerze.
Rozpoznawane jest w chwili przekroczenia progu, nie przy puszczeniu.
_Unikaj_: długie naciśnięcie, long press, hold
_W kodzie_: `hold` (np. `ButtonEvent.hold`)

### Rozmowa

**Cel**:
Karta przeglądarki, w której aplikacja wykonuje akcje — ta, w której znaleziono
przycisk mikrofonu. W danej chwili istnieje najwyżej jeden Cel.
_Unikaj_: karta Meet, zakładka, target
_W kodzie_: `target` (np. `AppState.target`, `ProbeResult`)

**Gotowość**:
Stan, w którym istnieje jednocześnie uzbrojony Kapsel i Cel. Tylko wtedy
naciśnięcie przycisku cokolwiek zmienia.
_Unikaj_: połączony, aktywny, ready
_W kodzie_: `readiness` (pojęcie opisowe — nie ma osobnego typu; wynika ze
złożenia `DeviceState.armed` i obecności `AppState.target`)

**Akcja**:
Zmiana stanu mikrofonu albo kamery w Celu, wywołana przez Kapsel.
_Unikaj_: komenda, toggle, przełączenie
_W kodzie_: `action` (np. `MeetAction`, `AppState.perform(_:)`, `ActionOutcome`)
