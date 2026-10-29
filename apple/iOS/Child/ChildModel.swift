import CloudKit
import Foundation
import Observation
import RewardsCore
import UIKit

/// Child mode: the child's balance and history, plus keeping the Watch and the
/// Activity share up to date.
@MainActor
@Observable
final class ChildModel {
    enum Phase {
        case loading, needsJoin, ready
    }

    private(set) var phase: Phase = .loading
    private(set) var state: ChildState?
    private(set) var isRefreshing = false
    var errorMessage: String?

    private let store = CloudStore.shared
    private var lastParentKeys: Set<String> = []
    private var lastDeviceWrite: Date = .distantPast
    private var subscribed = false

    var history: [HistoryItem] { state.map(HistoryBuilder.items(for:)) ?? [] }

    func refresh() async {
        // Show the local mirror straight away; the fetch below only brings changes.
        if let local = await localState() {
            state = local
            phase = .ready
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            guard await store.accountAvailable() else { throw CloudStoreError.notSignedIn }
            try await SyncEngine.shared.sync(.sharedDB)
            try await SyncEngine.shared.sync(.privateDB)
            guard let familyZone = await ChildLocator.findFamilyZone(),
                  let family = await SnapshotLoader.cachedFamily(familyZone) else {
                state = nil
                phase = .needsJoin
                return
            }

            var activity = await SnapshotLoader.cachedActivity(ChildLocator.activityZone)
            if activity.link?.childId != family.childId {
                // First run on this account, or re-joined after a take-over.
                try await ChildSetup.setUpActivity(family: familyZone, store: store)
                activity = try await SnapshotLoader.activity(ChildLocator.activityZone)
                lastParentKeys = parentKeys(family)
            }

            let newState = ChildState(family: family, activity: activity)
            state = newState
            phase = .ready
            errorMessage = nil

            await afterRefresh(newState)
        } catch {
            errorMessage = error.userMessage
            // Offline or failed: keep showing what this device has, including its own writes.
            if let local = await localState() {
                state = local
                phase = .ready
            } else if state == nil, phase == .loading {
                phase = .needsJoin
            }
        }
    }

    /// The child's state from the local mirror only.
    private func localState() async -> ChildState? {
        guard let zone = await ChildLocator.findFamilyZone(),
              let family = await SnapshotLoader.cachedFamily(zone) else { return nil }
        let activity = await SnapshotLoader.cachedActivity(ChildLocator.activityZone)
        return ChildState(family: family, activity: activity.link?.childId == family.childId ? activity : nil)
    }

    func join(code: String) async throws {
        try await ChildSetup.join(code: code, store: store)
        await refresh()
    }

    // MARK: Housekeeping after each refresh

    private func afterRefresh(_ state: ChildState) async {
        let family = state.family

        // Keep the Activity share in step with the family's parents.
        let keys = parentKeys(family)
        if keys != lastParentKeys {
            do {
                try await ChildSetup.reconcileActivityShare(parents: family.parents, childName: family.child.name,
                                                            store: store)
                lastParentKeys = keys
            } catch {
                errorMessage = error.userMessage
            }
        }

        WatchSync.shared.push(WatchContext(childId: family.childId, childName: family.child.name,
                                           birthYear: family.child.birthYear, rules: family.rules,
                                           bonuses: family.bonuses, familyZone: family.zone, updatedAt: Date()))

        if Date().timeIntervalSince(lastDeviceWrite) > 3600 {
            let device = DeviceInfo(deviceId: DeviceIdentity.id, kind: .ios, name: UIDevice.current.name,
                                    lastSeenAt: Date(), detectedApps: nil)
            if (try? await store.upsert([device.makeRecord(zoneID: ChildLocator.activityZone.zoneID)],
                                        scope: .privateDB)) != nil {
                lastDeviceWrite = Date()
            }
        }

        if !subscribed {
            do {
                try await store.ensureDatabaseSubscription(.sharedDB)
                try await store.ensureDatabaseSubscription(.privateDB)
                subscribed = true
            } catch {
                // Not fatal: pull-to-refresh and app foregrounding still update.
            }
        }
    }

    private func parentKeys(_ family: FamilySnapshot) -> Set<String> {
        family.parents.reduce(into: Set<String>()) { $0.formUnion($1.lookupKeys) }
    }
}
