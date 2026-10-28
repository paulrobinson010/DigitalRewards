import Foundation

/// This parent's identity. CloudKit can't tell an app the user's own email, so
/// the parent enters it once; other family members' devices use it to add
/// this parent to shares.
struct ParentProfile: Codable, Hashable {
    var displayName: String
    var email: String?
    var phone: String?
    var userRecordName: String

    var parentInfo: ParentInfo {
        ParentInfo(recordName: ParentInfo.recordName(userRecordName: userRecordName),
                   displayName: displayName, lookupEmail: email, lookupPhone: phone)
    }

    private static let key = "dr.parentProfile"

    static var saved: ParentProfile? {
        get {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(ParentProfile.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
