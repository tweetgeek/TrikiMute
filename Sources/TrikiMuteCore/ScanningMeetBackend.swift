import Foundation

/// Searches every given Instance for the Target.
///
/// The order of `instances` is the order of the search, and the first tab with
/// a full set of buttons wins — the same rule as before this backend existed,
/// only applied across Instances instead of across browser names.
public struct ScanningMeetBackend: MeetBackend {
    private let access: any BrowserAccess

    public init(access: any BrowserAccess) {
        self.access = access
    }

    public func probe(instances: [BrowserInstance]) -> ProbeOutcome {
        var lastError: String?
        for instance in instances {
            do {
                for tab in try access.tabs(in: instance) where tab.url.contains(MeetScripts.meetHost) {
                    let response = try tab.execute(MeetScripts.probeJS())
                    // "NONE" is four characters, so it's excluded here without
                    // needing to be named. Anything else of the wrong length is
                    // an anomaly and gets the same treatment: pass it over
                    // rather than decode it into a confident-looking reading.
                    guard response.count == 2 else { continue }
                    let chars = Array(response)
                    return .target(ProbeResult(
                        browser: instance.browser.name,
                        micMuted: chars[0] == "1",
                        cameraOff: chars[1] == "1"
                    ))
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }

    public func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome {
        var lastError: String?
        for instance in instances {
            do {
                for tab in try access.tabs(in: instance) where tab.url.contains(MeetScripts.meetHost) {
                    if try tab.execute(MeetScripts.toggleJS(action)) == "OK" { return .performed }
                }
            } catch {
                lastError = String(describing: error)
            }
        }
        if let lastError { return .failed(lastError) }
        return .noTarget
    }
}
