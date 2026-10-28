import Foundation

/// A stable per-install device id, used in `Device`/`Spend`/`Session` record names.
enum DeviceIdentity {
    private static let key = "dr.deviceId"

    static var id: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key) { return existing }
        let new = UUID().uuidString.lowercased()
        defaults.set(new, forKey: key)
        return new
    }
}
