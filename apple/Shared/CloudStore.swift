import CloudKit
import Foundation

enum CloudScope: String, Codable, Sendable {
    case privateDB, sharedDB, publicDB
}

/// Reference to a zone in one of the user's databases.
struct ZoneRef: Codable, Hashable, Sendable {
    var zoneName: String
    var ownerName: String
    var scope: CloudScope

    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName) }

    init(zoneID: CKRecordZone.ID, scope: CloudScope) {
        self.zoneName = zoneID.zoneName
        self.ownerName = zoneID.ownerName
        self.scope = scope
    }

    static func privateZone(_ name: String) -> ZoneRef {
        ZoneRef(zoneID: CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName), scope: .privateDB)
    }
}

enum CloudStoreError: LocalizedError {
    case notSignedIn
    case shareURLMissing
    case participantNotFound(String)
    case inviteNotFound
    case inviteExpired
    case inviteWrongKind

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to iCloud in Settings to use DigitalRewards."
        case .shareURLMissing: return "iCloud didn't return a share link. Try again."
        case .participantNotFound(let who): return "No iCloud account found for \(who)."
        case .inviteNotFound: return "That code wasn't found. Check it and try again."
        case .inviteExpired: return "That code has expired. Ask for a new one."
        case .inviteWrongKind: return "That code is for a different kind of invite."
        }
    }
}

extension Error {
    var ckCode: CKError.Code? { (self as? CKError)?.code }
}

/// Mutable box for collecting results inside CloudKit operation callbacks.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Thin async wrapper over CloudKit. Stateless apart from the container, so it is
/// safe to share across tasks.
final class CloudStore: @unchecked Sendable {
    static let shared = CloudStore()

    let container: CKContainer

    init(containerIdentifier: String = AppConfig.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    func database(_ scope: CloudScope) -> CKDatabase {
        switch scope {
        case .privateDB: return container.privateCloudDatabase
        case .sharedDB: return container.sharedCloudDatabase
        case .publicDB: return container.publicCloudDatabase
        }
    }

    // MARK: Account

    func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    func currentUserRecordName() async throws -> String {
        try await container.userRecordID().recordName
    }

    // MARK: Zones

    func allZones(_ scope: CloudScope) async throws -> [CKRecordZone] {
        try await database(scope).allRecordZones()
    }

    /// Creates the zone in the private database if needed (saving an existing zone is a no-op).
    @discardableResult
    func ensurePrivateZone(_ name: String) async throws -> ZoneRef {
        let zone = CKRecordZone(zoneName: name)
        _ = try await database(.privateDB).save(zone)
        return .privateZone(name)
    }

    // MARK: Records

    /// Returns nil when the record doesn't exist.
    func fetch(_ id: CKRecord.ID, scope: CloudScope) async throws -> CKRecord? {
        do {
            return try await database(scope).record(for: id)
        } catch let error where error.ckCode == .unknownItem {
            return nil
        }
    }

    /// Every record in a zone, fetched from scratch. Routine refreshes go through
    /// `SyncEngine` instead; this is for one-off copies (take-over).
    func fetchAllRecords(in zone: ZoneRef) async throws -> [CKRecord] {
        var byName: [String: CKRecord] = [:]
        var token: CKServerChangeToken?
        while true {
            let page = try await fetchZoneChanges(zone, since: token)
            for event in page.events {
                byName[event.name] = event.record
            }
            let advanced = page.token != nil && page.token != token
            token = page.token ?? token
            if !page.moreComing || !advanced { break }
        }
        return Array(byName.values)
    }

    // MARK: Change fetches (used by SyncEngine)

    /// Changes in one zone since `token` (nil = everything). Excludes the zone's share record.
    struct ZoneChanges {
        /// In arrival order. A nil record means the record was deleted.
        var events: [(name: String, record: CKRecord?)] = []
        var token: CKServerChangeToken?
        var moreComing = false
    }

    func fetchZoneChanges(_ zone: ZoneRef, since token: CKServerChangeToken?) async throws -> ZoneChanges {
        let db = database(zone.scope)
        let zoneID = zone.zoneID
        return try await withCheckedThrowingContinuation { continuation in
            let changes = Box(ZoneChanges())
            let zoneError = Box<Error?>(nil)
            let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            config.previousServerChangeToken = token
            let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID],
                                                       configurationsByRecordZoneID: [zoneID: config])
            op.fetchAllChanges = true
            op.recordWasChangedBlock = { id, result in
                if case .success(let record) = result, record.recordType != "cloudkit.share" {
                    changes.value.events.append((name: id.recordName, record: record))
                }
            }
            op.recordWithIDWasDeletedBlock = { id, _ in
                changes.value.events.append((name: id.recordName, record: nil))
            }
            op.recordZoneChangeTokensUpdatedBlock = { _, newToken, _ in
                if let newToken { changes.value.token = newToken }
            }
            op.recordZoneFetchResultBlock = { _, result in
                switch result {
                case .success(let value):
                    changes.value.token = value.serverChangeToken
                    changes.value.moreComing = value.moreComing
                case .failure(let error):
                    zoneError.value = error
                }
            }
            op.fetchRecordZoneChangesResultBlock = { result in
                if let error = zoneError.value {
                    continuation.resume(throwing: error)
                    return
                }
                switch result {
                case .success:
                    continuation.resume(returning: changes.value)
                case .failure(let error):
                    continuation.resume(throwing: CloudStore.itemError(error, for: zoneID))
                }
            }
            db.add(op)
        }
    }

    /// Zones changed or deleted in a database since `token` (nil = all zones).
    struct DatabaseChanges {
        var changedZoneIDs: [CKRecordZone.ID] = []
        var deletedZoneIDs: [CKRecordZone.ID] = []
        var token: CKServerChangeToken?
        var moreComing = false
    }

    func fetchDatabaseChanges(_ scope: CloudScope, since token: CKServerChangeToken?) async throws -> DatabaseChanges {
        let db = database(scope)
        return try await withCheckedThrowingContinuation { continuation in
            let changes = Box(DatabaseChanges())
            let op = CKFetchDatabaseChangesOperation(previousServerChangeToken: token)
            op.fetchAllChanges = true
            op.recordZoneWithIDChangedBlock = { zoneID in
                changes.value.changedZoneIDs.append(zoneID)
            }
            op.recordZoneWithIDWasDeletedBlock = { zoneID in
                changes.value.deletedZoneIDs.append(zoneID)
            }
            op.recordZoneWithIDWasPurgedBlock = { zoneID in
                changes.value.deletedZoneIDs.append(zoneID)
            }
            op.changeTokenUpdatedBlock = { newToken in
                changes.value.token = newToken
            }
            op.fetchDatabaseChangesResultBlock = { result in
                switch result {
                case .success(let value):
                    changes.value.token = value.serverChangeToken
                    changes.value.moreComing = value.moreComing
                    continuation.resume(returning: changes.value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            db.add(op)
        }
    }

    /// The per-item error inside a partial failure, if there is one for `id`.
    static func itemError(_ error: Error, for id: AnyHashable) -> Error {
        guard let ck = error as? CKError, ck.code == .partialFailure,
              let item = ck.partialErrorsByItemID?[id] else { return error }
        return item
    }

    // MARK: Writes
    //
    // Every successful save or delete is also applied to the local mirror, so the
    // UI reflects it straight away, even before (or without) the next fetch.

    /// Saves records, overwriting whatever is on the server (records with
    /// deterministic names are idempotent this way).
    func upsert(_ records: [CKRecord], scope: CloudScope) async throws {
        guard !records.isEmpty else { return }
        let result = try await database(scope).modifyRecords(saving: records, deleting: [],
                                                             savePolicy: .allKeys, atomically: false)
        let saved = result.saveResults.values.compactMap { try? $0.get() }
        await SyncEngine.shared.didSave(saved, scope: scope)
        for (_, r) in result.saveResults {
            if case .failure(let error) = r { throw error }
        }
    }

    /// Saves only if nobody changed the record since it was fetched. Throws
    /// `CKError.serverRecordChanged` (with `serverRecord`) on conflict.
    @discardableResult
    func saveIfUnchanged(_ record: CKRecord, scope: CloudScope) async throws -> CKRecord {
        let result = try await database(scope).modifyRecords(saving: [record], deleting: [],
                                                             savePolicy: .ifServerRecordUnchanged, atomically: false)
        guard let r = result.saveResults[record.recordID] else { return record }
        let saved = try r.get()
        await SyncEngine.shared.didSave([saved], scope: scope)
        return saved
    }

    func delete(_ ids: [CKRecord.ID], scope: CloudScope) async throws {
        guard !ids.isEmpty else { return }
        let result = try await database(scope).modifyRecords(saving: [], deleting: ids,
                                                             savePolicy: .allKeys, atomically: false)
        let gone = result.deleteResults.compactMap { id, r -> CKRecord.ID? in
            switch r {
            case .success: return id
            case .failure(let error): return error.ckCode == .unknownItem ? id : nil
            }
        }
        await SyncEngine.shared.didDelete(gone, scope: scope)
        for (_, r) in result.deleteResults {
            if case .failure(let error) = r, error.ckCode != .unknownItem { throw error }
        }
    }

    // MARK: Shares

    static func zoneShareID(_ zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
    }

    func zoneShare(for zone: ZoneRef) async throws -> CKShare? {
        try await fetch(Self.zoneShareID(zone.zoneID), scope: zone.scope) as? CKShare
    }

    /// Returns the zone's existing share or a new, unsaved one.
    func zoneShareOrNew(for zone: ZoneRef, title: String) async throws -> CKShare {
        if let existing = try await zoneShare(for: zone) { return existing }
        let share = CKShare(recordZoneID: zone.zoneID)
        share.publicPermission = .none
        share.setObject(title as NSString, forKey: CKShare.SystemFieldKey.title)
        return share
    }

    @discardableResult
    func saveShare(_ share: CKShare, scope: CloudScope) async throws -> CKShare {
        let result = try await database(scope).modifyRecords(saving: [share], deleting: [],
                                                             savePolicy: .changedKeys, atomically: false)
        guard let r = result.saveResults[share.recordID] else { return share }
        guard let saved = try r.get() as? CKShare else { return share }
        return saved
    }

    /// Looks up iCloud users by email/phone for adding to a share. Returns
    /// participants keyed by `LookupKey`.
    func participants(for lookups: [CKUserIdentity.LookupInfo]) async throws -> [String: CKShare.Participant] {
        guard !lookups.isEmpty else { return [:] }
        return try await withCheckedThrowingContinuation { continuation in
            let found = Box<[String: CKShare.Participant]>([:])
            let op = CKFetchShareParticipantsOperation(userIdentityLookupInfos: lookups)
            op.perShareParticipantResultBlock = { lookup, result in
                if case .success(let participant) = result, let key = CloudStore.key(for: lookup) {
                    found.value[key] = participant
                }
            }
            op.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .success: continuation.resume(returning: found.value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            container.add(op)
        }
    }

    static func key(for lookup: CKUserIdentity.LookupInfo) -> String? {
        if let email = lookup.emailAddress { return LookupKey.email(email) }
        if let phone = lookup.phoneNumber { return LookupKey.phone(phone) }
        return nil
    }

    static func key(for participant: CKShare.Participant) -> String? {
        participant.userIdentity.lookupInfo.flatMap { key(for: $0) }
    }

    static func lookupInfo(email: String?, phone: String?) -> CKUserIdentity.LookupInfo? {
        if let email, !email.isEmpty { return CKUserIdentity.LookupInfo(emailAddress: email) }
        if let phone, !phone.isEmpty { return CKUserIdentity.LookupInfo(phoneNumber: phone) }
        return nil
    }

    /// Fetches metadata for share URLs and accepts them. Already-accepted shares succeed again.
    @discardableResult
    func acceptShares(_ urls: [URL]) async throws -> [CKShare] {
        guard !urls.isEmpty else { return [] }
        let metadatas = try await shareMetadata(for: urls)
        return try await accept(metadatas)
    }

    private func shareMetadata(for urls: [URL]) async throws -> [CKShare.Metadata] {
        try await withCheckedThrowingContinuation { continuation in
            let found = Box<[CKShare.Metadata]>([])
            let firstError = Box<Error?>(nil)
            let op = CKFetchShareMetadataOperation(shareURLs: urls)
            op.shouldFetchRootRecord = false
            op.perShareMetadataResultBlock = { _, result in
                switch result {
                case .success(let metadata): found.value.append(metadata)
                case .failure(let error): firstError.value = firstError.value ?? error
                }
            }
            op.fetchShareMetadataResultBlock = { result in
                switch result {
                case .success:
                    if found.value.isEmpty, let error = firstError.value {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: found.value)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            container.add(op)
        }
    }

    private func accept(_ metadatas: [CKShare.Metadata]) async throws -> [CKShare] {
        guard !metadatas.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let accepted = Box<[CKShare]>([])
            let firstError = Box<Error?>(nil)
            let op = CKAcceptSharesOperation(shareMetadatas: metadatas)
            op.perShareResultBlock = { _, result in
                switch result {
                case .success(let share): accepted.value.append(share)
                case .failure(let error): firstError.value = firstError.value ?? error
                }
            }
            op.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    if accepted.value.isEmpty, let error = firstError.value {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: accepted.value)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            container.add(op)
        }
    }

    // MARK: Subscriptions

    /// Silent-push subscription for any change in the private or shared database.
    func ensureDatabaseSubscription(_ scope: CloudScope) async throws {
        precondition(scope != .publicDB, "Database subscriptions aren't supported on the public database")
        let id = "dr-\(scope.rawValue)-changes"
        let subscription = CKDatabaseSubscription(subscriptionID: id)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database(scope).save(subscription)
    }
}
