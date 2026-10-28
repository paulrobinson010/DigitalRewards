import CloudKit
import Foundation

/// Child-side CloudKit setup: joining with an invite code, creating the
/// Activity zone and keeping its share in step with the family's parents.
enum ChildSetup {
    private static let sharedKeysKey = "dr.child.activityShareKeys"

    /// Lookup keys this device has added to the Activity share (participants
    /// don't always report their lookup info back once they've accepted).
    private static var addedKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: sharedKeysKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: sharedKeysKey) }
    }

    static func fetchInvite(code: String, kind: InviteKind, store: CloudStore = .shared) async throws -> InviteInfo {
        let clean = code.filter(\.isNumber)
        let id = CKRecord.ID(recordName: InviteInfo.recordName(code: clean))
        guard let record = try await store.fetch(id, scope: .publicDB),
              let invite = InviteInfo(record: record) else { throw CloudStoreError.inviteNotFound }
        guard invite.expiresAt > Date() else { throw CloudStoreError.inviteExpired }
        guard invite.kind == kind else { throw CloudStoreError.inviteWrongKind }
        return invite
    }

    /// Accepts the family share from an invite code and sets up the Activity zone.
    static func join(code: String, store: CloudStore = .shared) async throws {
        let invite = try await fetchInvite(code: code, kind: .child, store: store)
        let shares = try await store.acceptShares(invite.shareURLs)
        guard let zoneID = shares.first?.recordID.zoneID else { throw CloudStoreError.inviteNotFound }
        let family = ZoneRef(zoneID: zoneID, scope: .sharedDB)
        ChildLocator.preferredFamilyZone = family
        try await setUpActivity(family: family, store: store)
    }

    /// Creates the Activity zone, its Link record and its share, and publishes the
    /// share URL so parents' apps can accept it. Safe to call repeatedly.
    static func setUpActivity(family zone: ZoneRef, store: CloudStore = .shared) async throws {
        guard let family = try await SnapshotLoader.family(zone) else {
            throw CloudStoreError.inviteNotFound
        }
        let activity = try await store.ensurePrivateZone(AppConfig.activityZoneName)
        let link = LinkInfo(childId: family.childId, familyZoneName: zone.zoneName, familyZoneOwner: zone.ownerName)
        try await store.upsert([link.makeRecord(zoneID: activity.zoneID)], scope: .privateDB)
        let share = try await reconcileActivityShare(parents: family.parents, childName: family.child.name,
                                                     force: true, store: store)
        guard let url = share?.url else { throw CloudStoreError.shareURLMissing }
        try await store.upsert([ShareLinkRecord.make(childId: family.childId, url: url)], scope: .publicDB)
    }

    /// Adds parents missing from the Activity share (read-only) and removes ones
    /// no longer in the family. Returns the saved share, or nil if nothing changed.
    @discardableResult
    static func reconcileActivityShare(parents: [ParentInfo], childName: String, force: Bool = false,
                                       store: CloudStore = .shared) async throws -> CKShare? {
        let zone = ChildLocator.activityZone
        let share = try await store.zoneShareOrNew(for: zone, title: "\(childName) – activity")
        var changed = force || share.recordChangeTag == nil

        // Primary key per parent: email if known, else phone.
        var wanted: [String: CKUserIdentity.LookupInfo] = [:]
        var allWantedKeys = Set<String>()
        for parent in parents {
            allWantedKeys.formUnion(parent.lookupKeys)
            if let info = CloudStore.lookupInfo(email: parent.lookupEmail, phone: parent.lookupPhone),
               let key = CloudStore.key(for: info) {
                wanted[key] = info
            }
        }

        let others = share.participants.filter { $0.role != .owner }
        let present = Set(others.compactMap { CloudStore.key(for: $0) }).union(addedKeys)

        let missing = wanted.filter { !present.contains($0.key) }
        if !missing.isEmpty {
            let found = try await store.participants(for: Array(missing.values))
            for (key, participant) in found {
                participant.permission = .readOnly
                share.addParticipant(participant)
                addedKeys.insert(key)
                changed = true
            }
        }

        for participant in others {
            guard let key = CloudStore.key(for: participant), !allWantedKeys.contains(key) else { continue }
            share.removeParticipant(participant)
            addedKeys.remove(key)
            changed = true
        }

        guard changed else { return nil }
        return try await store.saveShare(share, scope: .privateDB)
    }
}
