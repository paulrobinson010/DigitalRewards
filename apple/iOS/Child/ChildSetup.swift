import CloudKit
import Foundation

/// Child-side CloudKit setup: joining with an invite code. Both of the child's
/// zones live in a parent's iCloud, so joining only accepts the shares.
enum ChildSetup {
    static func fetchInvite(code: String, kind: InviteKind, store: CloudStore = .shared) async throws -> InviteInfo {
        let clean = code.filter(\.isNumber)
        let id = CKRecord.ID(recordName: InviteInfo.recordName(code: clean))
        guard let record = try await store.fetch(id, scope: .publicDB),
              let invite = InviteInfo(record: record) else { throw CloudStoreError.inviteNotFound }
        guard invite.expiresAt > Date() else { throw CloudStoreError.inviteExpired }
        guard invite.kind == kind else { throw CloudStoreError.inviteWrongKind }
        return invite
    }

    /// Accepts the child's `Family` (read-only) and `Activity` (read-write) shares.
    static func join(code: String, store: CloudStore = .shared) async throws {
        let invite = try await fetchInvite(code: code, kind: .child, store: store)
        let shares = try await store.acceptShares(invite.shareURLs)
        let zones = shares.map { ZoneRef(zoneID: $0.recordID.zoneID, scope: .sharedDB) }
        guard let family = zones.first(where: { $0.zoneName.hasPrefix(AppConfig.familyZonePrefix) }) else {
            throw CloudStoreError.inviteNotFound
        }
        ChildLocator.preferredFamilyZone = family
        // Mirror both zones now rather than waiting for them to show up in the
        // shared database's change feed.
        for zone in zones {
            try? await SyncEngine.shared.syncZone(zone)
        }
    }
}
