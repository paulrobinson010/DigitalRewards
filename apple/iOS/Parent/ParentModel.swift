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
    private let engine = SyncEngine.shared
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
        guard let profile else { return }
        // Show the local mirror straight away: the last known state at launch, and this
        // device's own writes immediately after a save. The fetch below only brings changes.
        await showLocalCopy()
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard await store.accountAvailable() else { throw CloudStoreError.notSignedIn }
            try await engine.sync(.privateDB)
            try await engine.sync(.sharedDB)
            var (families, activities) = await loadZones()

            // Accept Activity shares for children who have joined but whose share we haven't accepted yet.
            var accepted: [CKShare] = []
            for family in families where activities[family.childId] == nil {
                accepted += await acceptActivityShare(childId: family.childId)
            }
            if !accepted.isEmpty {
                // Fetch the new zones directly rather than relying on them appearing in the
                // shared database's change feed straight away.
                for share in accepted {
                    try? await engine.syncZone(ZoneRef(zoneID: share.recordID.zoneID, scope: .sharedDB))
                }
                try await engine.sync(.sharedDB)
                (families, activities) = await loadZones()
            }

            for family in families {
                await FamilyService.ensureMyParentRecord(family: family, me: profile, store: store)
            }

            let now = Date()
            children = Self.entries(families: families, activities: activities, now: now)
            prefs = await FamilyService.loadAlertPrefs()
            hasLoaded = true
            errorMessage = nil

            await AlertMonitor.process(children: children, prefs: prefs, now: now)
            await subscribeIfNeeded()
        } catch {
            errorMessage = error.userMessage
            // Offline or failed: keep showing what this device has, including its own writes.
            await showLocalCopy()
            hasLoaded = true
        }
    }

    /// Children from the local mirror only (no network).
    private func showLocalCopy() async {
        let (families, activities) = await loadZones()
        guard !families.isEmpty else { return }
        children = Self.entries(families: families, activities: activities, now: Date())
        prefs = await FamilyService.loadAlertPrefs()
        hasLoaded = true
    }

    private static func entries(families: [FamilySnapshot], activities: [String: ActivitySnapshot],
                                now: Date) -> [ChildEntry] {
        families
            .map { ChildEntry(state: ChildState(family: $0, activity: activities[$0.childId], now: now),
                              hasActivity: activities[$0.childId] != nil) }
            .sorted { $0.state.name.localizedCaseInsensitiveCompare($1.state.name) == .orderedAscending }
    }

    /// Family zones (one per child; if a take-over left two, the one in this
    /// parent's own iCloud or the most recently changed wins) and Activity zones by
    /// child id, built from the local mirror.
    private func loadZones() async -> ([FamilySnapshot], [String: ActivitySnapshot]) {
        let privateZones = await engine.knownZones(.privateDB)
        let sharedZones = await engine.knownZones(.sharedDB)
        let refs = privateZones + sharedZones

        var familyByChild: [String: FamilySnapshot] = [:]
        for ref in refs where ref.zoneName.hasPrefix(AppConfig.familyZonePrefix) {
            guard let family = await SnapshotLoader.cachedFamily(ref) else { continue }
            if let existing = familyByChild[family.childId] {
                let preferNew = (ref.scope == .privateDB && existing.zone.scope != .privateDB)
                    || (ref.scope == existing.zone.scope && family.lastModified > existing.lastModified)
                if !preferNew { continue }
            }
            familyByChild[family.childId] = family
        }

        var activities: [String: ActivitySnapshot] = [:]
        for ref in refs where ref.scope == .sharedDB && ref.zoneName == AppConfig.activityZoneName {
            let activity = await SnapshotLoader.cachedActivity(ref)
            guard let childId = activity.link?.childId else { continue }
            activities[childId] = activity
        }
        return (Array(familyByChild.values), activities)
    }

    private func acceptActivityShare(childId: String) async -> [CKShare] {
        let id = CKRecord.ID(recordName: ShareLinkRecord.recordName(childId: childId))
        guard let record = try? await store.fetch(id, scope: .publicDB),
              let text = record.string("shareURL"), let url = URL(string: text) else { return [] }
        return (try? await store.acceptShares([url])) ?? []
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
