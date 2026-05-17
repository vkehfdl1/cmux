import Foundation

enum WorkspaceMemorySettings {
    static let aggressiveCleanupOnTeardownKey = "workspaceAggressiveCleanupOnTeardown"
    static let aggressiveCleanupOnTeardownDefault = true

    static var aggressiveCleanupOnTeardown: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: aggressiveCleanupOnTeardownKey) == nil {
            return aggressiveCleanupOnTeardownDefault
        }
        return defaults.bool(forKey: aggressiveCleanupOnTeardownKey)
    }
}
