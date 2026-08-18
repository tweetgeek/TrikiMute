# Apple Events adresowane po procesie, przez ScriptingBridge

`tell application "Google Chrome"` adresuje identyfikator pakietu, a nie proces —
gdy działa kilka instancji przeglądarki, system sam wybiera adresata i nie ma jak
wskazać innego. Rozmowa otwarta w instancji, której system nie wybrał, jest wtedy
dla aplikacji niewidzialna. Przechodzimy na ScriptingBridge, bo
`SBApplication(processIdentifier:)` adresuje konkretny proces, więc aplikacja może
przejść po wszystkich żywych instancjach Chrome i Brave i znaleźć Cel w każdej
z nich.

To nie jest zmiana decyzji z ADR-0002: nadal rozmawiamy z przeglądarką przez
Apple Events i nadal klikamy przycisk w DOM. Zmienia się wyłącznie API, którym te
zdarzenia wysyłamy.

## Rozważane opcje

- **Zostawić AppleScript i wykrywać konflikt** — tanie, ale kończy się
  komunikatem „Cel może być w innej instancji", czyli aplikacja nadal nie robi
  tego, po co istnieje.
- **Chrome DevTools Protocol** — odrzucony już w ADR-0002 i nadal odrzucony
  z tych samych powodów.

## Konsekwencje

AppleScript zostaje jako ścieżka zapasowa, uruchamiana wyłącznie przy awarii
pierwszej — nigdy przy braku Celu, bo przeszukuje podzbiór tego, co pierwsza już
sprawdziła. Zapas nie potrafi wskazać instancji, więc przy awarii ScriptingBridge
i rozmowie w dwóch instancjach naraz może kliknąć w niewłaściwej; ryzyko przyjęte
świadomie i opisane w `follow-ups.md`.

ScriptingBridge domyślnie połyka błędy Apple Events — bez `SBApplicationDelegate`
cofnięta zgoda na Automatyzację zamieniłaby się w ciche „brak Celu", czyli
w awarię udającą poprawną odpowiedź. Obsługa błędów jest tu warunkiem poprawności,
nie dodatkiem.

Wiązanie z API odbywa się przez `unsafeBitCast` na protokołach `@objc`, bo
`SBApplication` odpowiada na selektory dynamicznie i zwykłe rzutowanie zwróciłoby
`nil`. Literówka w nazwie selektora nie jest wtedy błędem kompilacji, tylko cichą
awarią w czasie działania — deklaracje trzymamy w jednym pliku, a zmiany zamyka
test na żywej przeglądarce.
