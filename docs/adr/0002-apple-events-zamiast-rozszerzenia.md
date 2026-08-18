# Sterowanie Meet przez Apple Events, nie przez rozszerzenie przeglądarki

Akcja musi zadziałać, gdy focus ma zupełnie inna aplikacja, więc wysłanie skrótu
klawiszowego odpada — trafiłby do okna na wierzchu. Wybraliśmy `execute
javascript in tab` przez Apple Events, bo wykonuje kod w karcie Meet bez jej
aktywowania, zwraca wartość (czyli daje odczyt stanu wyciszenia) i nie wymaga
drugiego komponentu: cała aplikacja to jedna binarka.

## Rozważane opcje

- **Rozszerzenie przeglądarki + lokalny most** — najsolidniejsze i najczystsze
  uprawnieniowo, natywnie dwukierunkowe (push zamiast sondy). Odrzucone z powodu
  drugiego komponentu i instalacji jako unpacked extension w trybie
  deweloperskim. Pozostaje planem awaryjnym.
- **Chrome DevTools Protocol** — wymaga uruchamiania przeglądarki z
  `--remote-debugging-port`, pokazuje banner ostrzegawczy i otwiera lokalny port
  z pełną kontrolą nad przeglądarką.

## Konsekwencje

Użytkownik musi jednorazowo, osobno dla Chrome i Brave, włączyć
`View → Developer → Allow JavaScript from Apple Events` i przyznać zgodę na
Automation. Sterowanie opiera się na klikaniu przycisku w DOM Meet, więc jest
wrażliwe na przebudowę interfejsu przez Google — selektory żyją w jednym miejscu
i celują w `data-is-muted`, a nie w tłumaczony `aria-label`. `MeetController`
ukrywa ten mechanizm za własnym interfejsem, żeby podmiana na rozszerzenie nie
ruszała reszty aplikacji.

Otwarte: nie zweryfikowano, czy Brave w ogóle ma przełącznik „Allow JavaScript
from Apple Events". Jeśli nie ma, dla Brave zostaje wyłącznie plan awaryjny.
