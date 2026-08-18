import Foundation

/// Abstraction over the two thread hops around running an AppleScript
/// script: work in the background (blocking, so off the main thread), then
/// return to the main thread with the result. `afterDelay` is the same
/// pattern for the Target refresh delayed after an Action.
///
/// Exists solely so that `AppState` can be tested deterministically — the
/// test double runs `background` immediately, and `main` only on the test's
/// request, so tests need no sleeping or real delays.
@MainActor
protocol ScriptQueue {
    func run<T>(background: @escaping () -> T, main: @escaping (T) -> Void)
    func afterDelay(_ delay: TimeInterval, execute: @escaping () -> Void)
}

/// Production implementation: `background` on a serial background queue,
/// `main` and delayed calls back on the main thread.
struct DefaultScriptQueue: ScriptQueue {
    let backgroundQueue: DispatchQueue

    func run<T>(background: @escaping () -> T, main: @escaping (T) -> Void) {
        backgroundQueue.async {
            let result = background()
            DispatchQueue.main.async { main(result) }
        }
    }

    func afterDelay(_ delay: TimeInterval, execute: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: execute)
    }
}
