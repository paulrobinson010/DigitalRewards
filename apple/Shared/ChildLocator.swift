import CloudKit
import Foundation

/// Finds the signed-in child's zones. Used by the iPhone app in Child mode and by the Watch.
enum ChildLocator {
    private static let preferredKey = "dr.child.familyZone"

    /// The child's own Activity zone (private database).
    static var activityZone: ZoneRef { .privateZone(AppConfig.activityZoneName) }

    /// The family zone the child last joined, if remembered on this device.
    static var preferredFamilyZone: ZoneRef? {
        get {
            guard let data = UserDefaults.standard.data(forKey: preferredKey) else { return nil }
            return try? JSONDecoder().decode(ZoneRef.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: preferredKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preferredKey)
            }
        }
    }

    /// The `Family-*` zone shared to this child, from the shared-database mirror
    /// (call `SyncEngine.sync(.sharedDB)` first for an up-to-date answer). Prefers
    /// the one remembered from the last join (a child can see an old zone after a
    /// parent "takes over").
    static func findFamilyZone() async -> ZoneRef? {
        let zones = await SyncEngine.shared.knownZones(.sharedDB)
            .filter { $0.zoneName.hasPrefix(AppConfig.familyZonePrefix) }
        if let preferred = preferredFamilyZone,
           zones.contains(where: { $0.zoneName == preferred.zoneName && $0.ownerName == preferred.ownerName }) {
            return preferred
        }
        return zones.first
    }
}
