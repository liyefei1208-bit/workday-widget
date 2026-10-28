import Foundation
import ServiceManagement

/// Login-item registration.
///
/// Work-time recording only works while the app is running — macOS gives no
/// access to lock history, so a lock that happens with the app closed is simply
/// never seen. This makes "keep it running" something the user can opt into
/// rather than a hidden requirement.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the app and reports the outcome the system
    /// gives, which can be a refusal (for example when the bundle is not in a
    /// stable location).
    static func set(_ enabled: Bool) -> Result<Void, Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }
}
