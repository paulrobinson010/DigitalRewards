import CloudKit
import Foundation
import RewardsCore

enum FamilyServiceError: LocalizedError {
    case noteRequired
    case noLookup
    case nothingToShare
    case notShared

    var errorDescription: String? {
        switch self {
        case .noteRequired: return "Add a note. Your child will see it."
        case .noLookup: return "Enter an Apple ID email address or phone number."
        case .nothingToShare: return "None of your children could be shared. Ask the parent who added them to invite instead."
        case .notShared: return "This child already lives in your iCloud."
        }
    }
}

/// Another parent saved the rules first.
struct RulesConflict: Error, @unchecked Sendable {
    let serverRecord: CKRecord
    let theirRules: Rules
    let updatedBy: String
}

/// Parent-side writes. Every function writes to the family zone through the
/// database it lives in: private if this parent owns it, shared otherwise.
enum FamilyService {
    // MARK: Invites

    static func createInvite(kind: InviteKind, urls: [URL], store: CloudStore = .shared) async throws -> String {
        for _ in 0..<8 {
            let code = String(format: "%06d", Int.random(in: 0...999_999))
            let id = CKRecord.ID(recordName: InviteInfo.recordName(code: code))
            if try await store.fetch(id, scope: .publicDB) != nil { continue }
            let invite = InviteInfo(code: code, kind: kind, shareURLs: urls,
                                    expiresAt: Date().addingTimeInterval(AppConfig.inviteLifetime))
            try await store.upsert([invite.makeRecord()], scope: .publicDB)
            return code
        }
        throw CloudStoreError.inviteNotFound
    }

    static func fetchInvite(code: String, kind: InviteKind, store: CloudStore = .shared) async throws -> InviteInfo {
        let id = CKRecord.ID(recordName: InviteInfo.recordName(code: code.filter(\.isNumber)))
        guard let record = try await store.fetch(id, scope: .publicDB),
              let invite = InviteInfo(record: record) else { throw CloudStoreError.inviteNotFound }
        guard invite.expiresAt > Date() else { throw CloudStoreError.inviteExpired }
        guard invite.kind == kind else { throw CloudStoreError.inviteWrongKind }
        return invite
    }

    // MARK: Children

    /// Creates the child's `Family` and `Activity` zones in this parent's iCloud, shares
    /// both (other parents read-write; the child read-only on Family, read-write on
    /// Activity) and returns a 6-digit invite code for the child.
    static func addChild(name: String, birthYear: Int, timeZone: String,
                         childEmail: String?, childPhone: String?,
                         me: ParentProfile, otherParents: [ParentInfo],
                         store: CloudStore = .shared) async throws -> String {
        guard let childLookup = CloudStore.lookupInfo(email: childEmail?.trimmed, phone: childPhone?.trimmed) else {
            throw FamilyServiceError.noLookup
        }
        let childId = UUID().uuidString.lowercased()
        let zone = try await store.ensurePrivateZone(AppConfig.familyZoneName(childId: childId))
        let activity = try await store.ensurePrivateZone(AppConfig.activityZoneName(childId: childId))
        let child = ChildInfo(childId: childId, name: name, birthYear: birthYear, timeZone: timeZone)
        let others = otherParents.filter { $0.recordName != me.parentInfo.recordName }
        var records = [child.makeRecord(zoneID: zone.zoneID),
                       RulesRecord.makeRecord(.defaults, zoneID: zone.zoneID, updatedBy: me.displayName),
                       me.parentInfo.makeRecord(zoneID: zone.zoneID)]
        records += others.map { $0.makeRecord(zoneID: zone.zoneID) }
        try await store.upsert(records, scope: .privateDB)

        let urls = try await shareChildZones(family: zone, activity: activity, childName: name,
                                             childLookup: childLookup, parents: others, store: store)
        // Mirror the new zones now rather than waiting for them to show up in the
        // private database's change feed.
        try? await SyncEngine.shared.syncZone(zone)
        try? await SyncEngine.shared.syncZone(activity)
        return try await createInvite(kind: .child, urls: urls, store: store)
    }

    /// A fresh code for a child who hasn't joined yet (codes expire after 7 days). For a
    /// child added before activity moved to the parent's iCloud, this also creates their
    /// Activity zone and share.
    static func newChildInvite(family: FamilySnapshot, store: CloudStore = .shared) async throws -> String {
        guard let familyShare = try await store.zoneShare(for: family.zone), let familyURL = familyShare.url else {
            throw CloudStoreError.shareURLMissing
        }
        let activityZone = ChildLocator.activityZone(for: family.zone)
        var activityShare = try? await store.zoneShare(for: activityZone)
        if activityShare == nil, family.zone.scope == .privateDB {
            // The child is the read-only participant on the Family share.
            guard let childLookup = familyShare.participants
                .first(where: { $0.role != .owner && $0.permission == .readOnly })?.userIdentity.lookupInfo else {
                throw CloudStoreError.participantNotFound("\(family.child.name) (add them again with their Apple ID)")
            }
            let zone = try await store.ensurePrivateZone(activityZone.zoneName)
            let me = try await store.currentUserRecordName()
            let myRecordName = ParentInfo.recordName(userRecordName: me)
            let parents = family.parents.filter { $0.recordName != myRecordName }
            activityShare = try await shareZone(zone, title: "\(family.child.name) – activity", childLookup: childLookup,
                                                childPermission: .readWrite, parents: parents, store: store)
        }
        var urls = [familyURL]
        if let url = activityShare?.url { urls.append(url) }
        return try await createInvite(kind: .child, urls: urls, store: store)
    }

    /// Shares both of a child's zones and returns their URLs (Family first).
    private static func shareChildZones(family: ZoneRef, activity: ZoneRef, childName: String,
                                        childLookup: CKUserIdentity.LookupInfo, parents: [ParentInfo],
                                        store: CloudStore) async throws -> [URL] {
        let familyShare = try await shareZone(family, title: "\(childName) – Go AFK", childLookup: childLookup,
                                              childPermission: .readOnly, parents: parents, store: store)
        let activityShare = try await shareZone(activity, title: "\(childName) – activity", childLookup: childLookup,
                                                childPermission: .readWrite, parents: parents, store: store)
        guard let familyURL = familyShare.url, let activityURL = activityShare.url else {
            throw CloudStoreError.shareURLMissing
        }
        return [familyURL, activityURL]
    }

    /// Creates or updates a zone-wide share: parents read-write, the child with `childPermission`.
    private static func shareZone(_ zone: ZoneRef, title: String, childLookup: CKUserIdentity.LookupInfo,
                                  childPermission: CKShare.ParticipantPermission, parents: [ParentInfo],
                                  store: CloudStore) async throws -> CKShare {
        let share = try await store.zoneShareOrNew(for: zone, title: title)
        let present = Set(share.participants.compactMap { CloudStore.key(for: $0) })

        var lookups = [childLookup]
        lookups += parents.compactMap { CloudStore.lookupInfo(email: $0.lookupEmail, phone: $0.lookupPhone) }
        lookups = lookups.filter { CloudStore.key(for: $0).map { !present.contains($0) } ?? false }

        let found = try await store.participants(for: lookups)
        let childKey = CloudStore.key(for: childLookup)
        for (key, participant) in found {
            participant.permission = key == childKey ? childPermission : .readWrite
            share.addParticipant(participant)
        }
        if let childKey, !present.contains(childKey), found[childKey] == nil {
            throw CloudStoreError.participantNotFound(childLookup.emailAddress ?? childLookup.phoneNumber ?? "the child")
        }
        return try await store.saveShare(share, scope: zone.scope)
    }

    /// Copies a child's Family and Activity zones from another parent's iCloud into this
    /// parent's, re-shares both and returns a new code for the child to re-join.
    static func takeOver(family: FamilySnapshot, childEmail: String?, childPhone: String?,
                         dropPreviousOwner: Bool, me: ParentProfile,
                         store: CloudStore = .shared) async throws -> String {
        guard family.zone.scope == .sharedDB else { throw FamilyServiceError.notShared }
        guard let childLookup = CloudStore.lookupInfo(email: childEmail?.trimmed, phone: childPhone?.trimmed) else {
            throw FamilyServiceError.noLookup
        }
        let ownerRecord = ParentInfo.recordName(userRecordName: family.zone.ownerName)
        let source = try await store.fetchAllRecords(in: family.zone)
        let zone = try await store.ensurePrivateZone(family.zone.zoneName)
        let copies = source
            .filter { !(dropPreviousOwner && $0.recordType == RecordType.parent && $0.recordID.recordName == ownerRecord) }
            .map { copy($0, to: zone.zoneID) }
        try await store.upsert(copies + [me.parentInfo.makeRecord(zoneID: zone.zoneID)], scope: .privateDB)

        // A child added before activity moved to the parent's iCloud has no Activity zone to copy.
        let sourceActivity = ChildLocator.activityZone(for: family.zone)
        let activityRecords = (try? await store.fetchAllRecords(in: sourceActivity)) ?? []
        let activity = try await store.ensurePrivateZone(sourceActivity.zoneName)
        try await store.upsert(activityRecords.map { copy($0, to: activity.zoneID) }, scope: .privateDB)

        let parents = family.parents.filter {
            $0.recordName != me.parentInfo.recordName && !(dropPreviousOwner && $0.recordName == ownerRecord)
        }
        let urls = try await shareChildZones(family: zone, activity: activity, childName: family.child.name,
                                             childLookup: childLookup, parents: parents, store: store)
        return try await createInvite(kind: .child, urls: urls, store: store)
    }

    private static func copy(_ record: CKRecord, to zoneID: CKRecordZone.ID) -> CKRecord {
        let new = CKRecord(recordType: record.recordType,
                           recordID: CKRecord.ID(recordName: record.recordID.recordName, zoneID: zoneID))
        for key in record.allKeys() {
            new.setObject(record.object(forKey: key), forKey: key)
        }
        return new
    }

    // MARK: Parents

    /// Adds another adult to every Family and Activity share this parent can change.
    /// Returns the invite code and the names of children that couldn't be shared (only
    /// the zone owner can add participants unless CloudKit grants more).
    static func inviteParent(name: String, email: String?, phone: String?, families: [FamilySnapshot],
                             store: CloudStore = .shared) async throws -> (code: String, skipped: [String]) {
        let email = email?.trimmed, phone = phone?.trimmed
        guard let lookup = CloudStore.lookupInfo(email: email, phone: phone),
              let key = CloudStore.key(for: lookup) else { throw FamilyServiceError.noLookup }

        var urls: [URL] = []
        var skipped: [String] = []
        for family in families {
            do {
                guard let familyURL = try await addParticipant(lookup, key: key, to: family.zone,
                                                               who: email ?? phone ?? name, store: store) else {
                    skipped.append(family.child.name)
                    continue
                }
                urls.append(familyURL)
                // Children added before activity moved to the parent's iCloud have no Activity share.
                let activity = ChildLocator.activityZone(for: family.zone)
                if let activityURL = try? await addParticipant(lookup, key: key, to: activity,
                                                               who: email ?? phone ?? name, store: store) {
                    urls.append(activityURL)
                }
                let recordName = ParentInfo.pendingRecordName(lookup: email ?? phone ?? name)
                let parent = ParentInfo(recordName: recordName, displayName: name, lookupEmail: email, lookupPhone: phone)
                try await store.upsert([parent.makeRecord(zoneID: family.zone.zoneID)], scope: family.zone.scope)
            } catch let error as CloudStoreError {
                throw error
            } catch {
                skipped.append(family.child.name)
            }
        }
        guard !urls.isEmpty else { throw FamilyServiceError.nothingToShare }
        let code = try await createInvite(kind: .parent, urls: urls, store: store)
        return (code, skipped)
    }

    /// Adds a read-write participant to a zone's share. Returns the share URL, or nil
    /// if the zone has no share.
    private static func addParticipant(_ lookup: CKUserIdentity.LookupInfo, key: String, to zone: ZoneRef,
                                       who: String, store: CloudStore) async throws -> URL? {
        guard let share = try await store.zoneShare(for: zone) else { return nil }
        if !share.participants.contains(where: { CloudStore.key(for: $0) == key }) {
            // Look up per share: a participant object belongs to one share.
            guard let participant = try await store.participants(for: [lookup]).values.first else {
                throw CloudStoreError.participantNotFound(who)
            }
            participant.permission = .readWrite
            share.addParticipant(participant)
        }
        let saved = try await store.saveShare(share, scope: zone.scope)
        return saved.url ?? share.url
    }

    /// Accepts every share in a parent invite (each child's Family and Activity zones)
    /// and adds this parent's record to each family.
    static func joinAsParent(code: String, me: ParentProfile, store: CloudStore = .shared) async throws {
        let invite = try await fetchInvite(code: code, kind: .parent, store: store)
        let shares = try await store.acceptShares(invite.shareURLs)
        for share in shares {
            let zone = ZoneRef(zoneID: share.recordID.zoneID, scope: .sharedDB)
            if zone.zoneName.hasPrefix(AppConfig.familyZonePrefix) {
                if let family = try? await SnapshotLoader.family(zone) {
                    await ensureMyParentRecord(family: family, me: me, store: store)
                }
            } else {
                try? await SyncEngine.shared.syncZone(zone)
            }
        }
    }

    /// Makes sure this parent's `Parent` record exists in a family zone and removes
    /// the placeholder written when they were invited.
    static func ensureMyParentRecord(family: FamilySnapshot, me: ParentProfile, store: CloudStore = .shared) async {
        let mine = me.parentInfo
        let myKeys = mine.lookupKeys
        let placeholders = family.parents.filter {
            $0.recordName.hasPrefix("parent-invite-") && !$0.lookupKeys.isDisjoint(with: myKeys)
        }
        let existing = family.parents.first { $0.recordName == mine.recordName }
        if existing != mine {
            try? await store.upsert([mine.makeRecord(zoneID: family.zone.zoneID)], scope: family.zone.scope)
        }
        if !placeholders.isEmpty {
            let ids = placeholders.map { CKRecord.ID(recordName: $0.recordName, zoneID: family.zone.zoneID) }
            try? await store.delete(ids, scope: family.zone.scope)
        }
    }

    /// Removes an adult from every Family and Activity share and deletes their Parent records.
    static func removeParent(_ parent: ParentInfo, families: [FamilySnapshot],
                             store: CloudStore = .shared) async -> [String] {
        let userRecordName = parent.recordName.hasPrefix("parent-invite-") ? nil
            : String(parent.recordName.dropFirst("parent-".count))
        var skipped: [String] = []
        for family in families {
            do {
                for zone in [family.zone, ChildLocator.activityZone(for: family.zone)] {
                    let share: CKShare?
                    if zone == family.zone {
                        share = try await store.zoneShare(for: zone)
                    } else {
                        // Children added before activity moved to the parent's iCloud have no Activity zone.
                        share = try? await store.zoneShare(for: zone)
                    }
                    guard let share else { continue }
                    let matches = share.participants.filter { p in
                        guard p.role != .owner else { return false }
                        if let key = CloudStore.key(for: p), parent.lookupKeys.contains(key) { return true }
                        if let userRecordName, p.userIdentity.userRecordID?.recordName == userRecordName { return true }
                        return false
                    }
                    if !matches.isEmpty {
                        matches.forEach(share.removeParticipant)
                        try await store.saveShare(share, scope: zone.scope)
                    }
                }
                let ids = family.parents
                    .filter { $0.recordName == parent.recordName || !$0.lookupKeys.isDisjoint(with: parent.lookupKeys) }
                    .map { CKRecord.ID(recordName: $0.recordName, zoneID: family.zone.zoneID) }
                try await store.delete(ids, scope: family.zone.scope)
            } catch {
                skipped.append(family.child.name)
            }
        }
        return skipped
    }

    // MARK: Balance and workouts

    static func addAdjustment(minutes: Int, note: String, family: FamilySnapshot, me: ParentProfile,
                              store: CloudStore = .shared) async throws {
        let note = try required(note)
        let entry = AdjustmentEntry(id: AdjustmentEntry.newRecordName(), minutes: minutes, note: note,
                                    at: Date(), byParent: me.displayName)
        try await store.upsert([entry.makeRecord(zoneID: family.zone.zoneID)], scope: family.zone.scope)
    }

    /// Replaces a workout's earned minutes (0 voids it). Saving again replaces the previous override.
    static func saveOverride(sessionId: String, minutes: Int, note: String, family: FamilySnapshot,
                             me: ParentProfile, store: CloudStore = .shared) async throws {
        let note = try required(note)
        let o = SessionOverrideInfo(sessionId: sessionId, earnedMinutes: max(0, minutes), note: note,
                                    at: Date(), byParent: me.displayName)
        try await store.upsert([o.makeRecord(zoneID: family.zone.zoneID)], scope: family.zone.scope)
    }

    static func removeOverride(sessionId: String, family: FamilySnapshot, store: CloudStore = .shared) async throws {
        let id = CKRecord.ID(recordName: SessionOverrideInfo.recordName(sessionId: sessionId), zoneID: family.zone.zoneID)
        try await store.delete([id], scope: family.zone.scope)
    }

    static func addBonus(multiplier: Double, startsAt: Date, endsAt: Date, note: String,
                         family: FamilySnapshot, me: ParentProfile, store: CloudStore = .shared) async throws {
        let note = try required(note)
        let bonus = BonusInfo(id: BonusInfo.newRecordName(), multiplier: multiplier, startsAt: startsAt,
                              endsAt: endsAt, note: note, at: Date(), byParent: me.displayName)
        try await store.upsert([bonus.makeRecord(zoneID: family.zone.zoneID)], scope: family.zone.scope)
    }

    static func deleteBonus(_ bonus: BonusInfo, family: FamilySnapshot, store: CloudStore = .shared) async throws {
        try await store.delete([CKRecord.ID(recordName: bonus.id, zoneID: family.zone.zoneID)], scope: family.zone.scope)
    }

    // MARK: Rules

    /// Saves rules plus a `RulesChange` describing the diff. Throws `RulesConflict`
    /// if another parent saved first; pass `base: conflict.serverRecord` to overwrite.
    static func saveRules(_ new: Rules, note: String, family: FamilySnapshot, me: ParentProfile,
                          base: CKRecord? = nil, store: CloudStore = .shared) async throws {
        let note = try required(note)
        let old = base.map(RulesRecord.rules(from:)) ?? family.rules
        let record = base ?? family.rulesRecord
            ?? CKRecord(recordType: RecordType.rules,
                        recordID: CKRecord.ID(recordName: RulesRecord.recordName, zoneID: family.zone.zoneID))
        RulesRecord.apply(new, to: record, updatedBy: me.displayName)
        do {
            try await store.saveIfUnchanged(record, scope: family.zone.scope)
        } catch let error as CKError where error.code == .serverRecordChanged {
            guard let server = error.serverRecord else { throw error }
            throw RulesConflict(serverRecord: server, theirRules: RulesRecord.rules(from: server),
                                updatedBy: server.string("updatedBy") ?? "Another parent")
        }
        let change = RulesChangeInfo(id: RulesChangeInfo.newRecordName(),
                                     summary: RulesDiff.summary(from: old, to: new),
                                     note: note, at: Date(), byParent: me.displayName)
        try await store.upsert([change.makeRecord(zoneID: family.zone.zoneID)], scope: family.zone.scope)
    }

    // MARK: Devices and alerts

    static func saveAllowList(deviceId: String, executables: [String], family: FamilySnapshot,
                              store: CloudStore = .shared) async throws {
        let list = AllowListInfo(deviceId: deviceId, executables: Array(Set(executables.map { $0.lowercased() })).sorted())
        try await store.upsert([list.makeRecord(zoneID: family.zone.zoneID)], scope: family.zone.scope)
    }

    /// From the private-database mirror; sync `.privateDB` first for fresh values.
    static func loadAlertPrefs() async -> [String: AlertPrefsInfo] {
        let records = await SyncEngine.shared.records(in: .privateZone(AppConfig.prefsZoneName))
        var result: [String: AlertPrefsInfo] = [:]
        for r in records where r.recordType == RecordType.alertPrefs {
            let childId = String(r.recordID.recordName.dropFirst("alerts-".count))
            result[childId] = AlertPrefsInfo(record: r, childId: childId)
        }
        return result
    }

    static func saveAlertPrefs(_ prefs: AlertPrefsInfo, store: CloudStore = .shared) async throws {
        let zone = try await store.ensurePrivateZone(AppConfig.prefsZoneName)
        try await store.upsert([prefs.makeRecord(zoneID: zone.zoneID)], scope: .privateDB)
    }

    private static func required(_ note: String) throws -> String {
        let n = note.trimmed
        guard !n.isEmpty else { throw FamilyServiceError.noteRequired }
        return n
    }
}
