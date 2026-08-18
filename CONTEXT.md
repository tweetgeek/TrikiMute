# TrikiMute

Sterowanie mikrofonem i kamerą w rozmowie Google Meet za pomocą fizycznego
kontrolera BLE Żabka Triki, niezależnie od tego, która aplikacja ma focus.

## Język

### Urządzenie

**Kapsel**:
Fizyczny kontroler BLE Żabka Triki w kształcie kapsla, z przyciskiem i czujnikiem
inercyjnym.
_Unikaj_: urządzenie, Triki, pilot, guzik

**Uzbrojenie**:
Doprowadzenie kapsla do stanu, w którym reaguje na naciśnięcia — obejmuje jego
wybudzenie i zestawienie połączenia. Naciśnięcie, które uzbraja, nie wywołuje
żadnej akcji.
_Unikaj_: parowanie, inicjalizacja, obudzenie

**Naciśnięcie**:
Krótkie wciśnięcie i puszczenie przycisku kapsla. Odpowiada mikrofonowi.
_Unikaj_: klik, tap, press

**Przytrzymanie**:
Wciśnięcie przycisku kapsla utrzymane ponad próg czasowy. Odpowiada kamerze.
Rozpoznawane jest w chwili przekroczenia progu, nie przy puszczeniu.
_Unikaj_: długie naciśnięcie, long press, hold

### Rozmowa

**Cel**:
Karta przeglądarki, w której aplikacja wykonuje akcje — ta, w której znaleziono
przycisk mikrofonu. W danej chwili istnieje najwyżej jeden Cel.
_Unikaj_: karta Meet, zakładka, target

**Gotowość**:
Stan, w którym istnieje jednocześnie uzbrojony Kapsel i Cel. Tylko wtedy
naciśnięcie przycisku cokolwiek zmienia.
_Unikaj_: połączony, aktywny, ready

**Akcja**:
Zmiana stanu mikrofonu albo kamery w Celu, wywołana przez Kapsel.
_Unikaj_: komenda, toggle, przełączenie
