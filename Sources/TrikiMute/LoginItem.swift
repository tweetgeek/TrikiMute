import ServiceManagement

/// Launch-at-login registration. `SMAppService.mainApp` only works for a
/// signed .app bundle — a binary launched directly will report an error.
enum LoginItem {
    /// Registration status, in a form fit to display in the menu.
    enum Status: Equatable {
        case disabled
        case enabled
        /// Registered, but waiting for approval in System Settings. Without
        /// this state it would look identical to disabled, so clicking it
        /// would lead to re-registering instead of pointing the user to
        /// where the matter is actually pending.
        case requiresApproval
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    static var isEnabled: Bool { status == .enabled }

    /// Returns an error description if the operation failed.
    ///
    /// Registration can be blocked by device management policy or by
    /// `SMAppService` restrictions. Reporting this via `print` would be
    /// useless: an app launched by LaunchServices has nowhere to print to,
    /// and the user is looking right at the menu at this moment.
    static func toggle() -> String? {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
