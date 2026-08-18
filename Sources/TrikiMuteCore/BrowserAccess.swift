import Foundation

/// One tab in one Instance.
///
/// Deliberately minimal: an address to recognize the call by, and a way to run
/// JavaScript in it. Everything else a real tab can do is outside what this app
/// needs, and would only make the type harder to fake in tests.
public protocol BrowserTab {
    var url: String { get }
    func execute(_ javascript: String) throws -> String
}

/// Reads tabs out of a running Instance.
///
/// The production implementation talks to ScriptingBridge; the test one hands
/// back programmed tabs. Keeping the protocol here — in the pure target — is
/// what makes "the Target is in the second Instance" a case a unit test can
/// describe at all.
///
/// Throwing is meaningful: it means the Instance could not be read, which is a
/// failure, as opposed to an Instance that simply has no call in it.
public protocol BrowserAccess {
    func tabs(in instance: BrowserInstance) throws -> [any BrowserTab]
}
