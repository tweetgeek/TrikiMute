import Foundation

/// One way of reaching the Target.
///
/// Two implementations exist: `ScanningMeetBackend`, which addresses Instances
/// by process, and `AppleScriptMeetBackend`, which addresses browsers by name
/// and serves as the fallback. `MeetController` combines them.
public protocol MeetBackend {
    func probe(instances: [BrowserInstance]) -> ProbeOutcome
    func perform(_ action: MeetAction, instances: [BrowserInstance]) -> ActionOutcome
}
