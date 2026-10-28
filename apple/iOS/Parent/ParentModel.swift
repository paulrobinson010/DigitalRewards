import CloudKit
import Foundation
import Observation
import RewardsCore
import UserNotifications

/// One child as seen by a parent.
struct ChildEntry: Identifiable {
    var state: ChildState
    /// False until the child has joined and this parent has accepted the child's Activity share.
    var hasActivity: Bool

    var id: String { state.childId }
    var family: FamilySnapshot { state.family }
}

/// Parent mode: all children this parent can see, from family zones they own
/// (private DB) or that other parents shared (shared DB).
@MainActor
@Observable
final class ParentModel {
    private(set) var profile: ParentProfile? = ParentProfile.saved
    private(set) var children: [ChildEntry] = []
    private(set) var prefs: [String: AlertPrefsInfo] = [:]
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    var errorMessage: String?

    private let store = CloudStore.shared
    private var subscribed = false

    /// Every parent across all families, de-duplicated.
    var allParents: [ParentInfo] {
        var byName: [String: ParentInfo] = [:]
        for parent in children.flatMap(\.family.parents) where byName[parent.recordName] == nil {
            byName[parent.recordName] = parent
        }
        var result: [ParentInfo] = []
        var seenKeys = Set<String>()
        for parent in byName.values.sorted(by: { $0.displayName < $1.displayName }) {
            // Drop invite placeholders once the real record (same email/phone) exists.
            if parent.recordName.hasPrefix("parent-invite-"),
               byName.values.contains(where: { !$0.recordName.hasPrefix("parent-invite-") && !$0.lookupKeys.isDisjoint(with: parent.lookupKeys) }) {
                continue
            }
            if !parent.lookupKeys.isEmpty, !parent.lookupKeys.isDisjoint(with: seenKeys) { continue }
            seenKeys.formUnion(parent.lookupKeys)
            result.append(parent)
        }
        return result
    }

    var families: [FamilySnapshot] { children.map(\.family) }

    func entry(_ childId: String) -> ChildEntry? {
        children.first { $0.id == childId }
    }

    func prefs(for childId: String) -> AlertPrefsInfo {
        prefs[childId] ?? AlertPrefsInfo(childId: childId)
    }

    // MARK: Profile

    func saveProfile(displayName: String, email: String?, phone: String?) async throws {
        guard await store.accountAvailable() else { throw CloudStoreError.notSignedIn }
        let userRecordName = try await store.currentUserRecordName()
        let email = email?.trimmed, phone = phone?.trimmed
        let profile = ParentProfile(displayName: displayName.trimmed,
                                    email: (email?.isEmpty ?? true) ? nil : email,
                                    phone: (phone?.isEmpty ?? true) ? nil : phone,
                                    userRecordName: userRecordName)
        ParentProfile.saved = profile
        self.profile = profile
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refresh()
    }

    // MARK: Loading

    func refresh() async {
        guard let profile, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard await store.accountAvailable() else { throw CloudStoreError.notSignedIn }
            var (families, activities) = try await loadZones()

            // Accept Activity shares for children who have joined but whose share we haven't accepted yet.
            var acceptedAny = false
            for family in families where activities[family.childId] == nil {
                if await acceptActivityShare(childId: family.childId) { acceptedAny = true }
            }
            if acceptedAny {
                (families, activities) = try await loadZones()
            }

            for family in families {
                await FamilyService.ensureMyParentRecord(family: family, me: profile, store: store)
            }

            let now = Date()
            children = families
                .map { ChildEntry(state: ChildState(family: $0, activity: activities[$0.childId], now: now),
                                  hasActivity: activities[$0.childId] != nil) }
                .sorted { $0.state.name.localizedCaseInsensitiveCompare($1.state.name) == .orderedAscending }
            prefs = await FamilyService.loadAlertPrefs(store: store)
            hasLoaded = true
            errorMessage = nil

            await AlertMonitor.process(children: children, prefs: prefs, now: now)
            await subscribeIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
            hasLoaded = true
        }
    }

    /// Family zones (one per child; if a take-over left two, the one in this
    /// parent's own iCloud or the most recently changed wins) and Activity zones by child id.
    private func loadZones() async throws -> ([FamilySnapshot], [String: ActivitySnapshot]) {
        let privateZones = try await store.allZones(.privateDB)
        let sharedZones = try await store.allZones(.sharedDB)

        var refs = privateZones.map { ZoneRef(zoneID: $0.zoneID, scope: .privateDB) }
        refs += sharedZones.map { ZoneRef(zoneID: $0.zoneID, scope: .sharedDB) }

        var familyByChild: [String: FamilySnapshot] = [:]
        for ref in refs where ref.zoneName.hasPrefix(AppConfig.familyZonePrefix) {
            guard let family = try? await SnapshotLoader.family(ref, store: store) else { continue }
            if let existing = familyByChild[family.childId] {
                let preferNew = (ref.scope == .privateDB && existing.zone.scope != .privateDB)
                    || (ref.scope == existing.zone.scope && family.lastModified > existing.lastModified)
                if !preferNew { continue }
            }
            familyByChild[family.childId] = family
        }

        var activities: [String: ActivitySnapshot] = [:]
        for ref in refs where ref.scope == .sharedDB && ref.zoneName == AppConfig.activityZoneName {
            guard let activity = try? await SnapshotLoader.activity(ref, store: store),
                  let childId = activity.link?.childId else { continue }
            activities[childId] = activity
        }
        return (Array(familyByChild.values), activities)
    }

    private func acceptActivityShare(childId: String) async -> Bool {
        let id = CKRecord.ID(recordName: ShareLinkRecord.recordName(childId: childId))
        guard let record = try? await store.fetch(id, scope: .publicDB),
              let text = record.string("shareURL"), let url = URL(string: text) else { return false }
        return (try? await store.acceptShares([url]))?.isEmpty == false
    }

    private func subscribeIfNeeded() async {
        guard !subscribed else { return }
        do {
            try await store.ensureDatabaseSubscription(.sharedDB)
            try await store.ensureDatabaseSubscription(.privateDB)
            subscribed = true
        } catch {
            // Not fatal: refreshes still happen on launch, pull-to-refresh and background refresh.
        }
    }
}
