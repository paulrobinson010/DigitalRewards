import Foundation

/// Change the container here (and in the entitlements files) if you use your own bundle prefix.
enum AppConfig {
    static let containerIdentifier = "iCloud.com.digitalrewards.app"

    /// Zone names (docs/CONTRACT.md §5).
    static let familyZonePrefix = "Family-"
    static let activityZoneName = "Activity"
    static let prefsZoneName = "Prefs"

    static func familyZoneName(childId: String) -> String { familyZonePrefix + childId }

    static let inviteLifetime: TimeInterval = 7 * 24 * 3600
    static let samplesPerMinute = 12
    static let sampleInterval: TimeInterval = 5
}
