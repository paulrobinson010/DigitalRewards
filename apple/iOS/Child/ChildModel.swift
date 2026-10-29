import CloudKit
import Foundation
import Observation
import RewardsCore
import UIKit

/// Child mode: the child's balance and history, plus keeping the Watch up to date.
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
            guard let familyZone = await ChildLocator.findFamilyZone(),
                  let family = await SnapshotLoader.cachedFamily(familyZone) else {
                state = nil
                phase = .needsJoin
                return
            }

            let activityZone = ChildLocator.activityZone(for: familyZone)
            let activity: ActivitySnapshot
            if await SyncEngine.shared.knownZones(.sharedDB).contains(activityZone) {
                activity = await SnapshotLoader.cachedActivity(activityZone)
            } else {
                // Just joined: fetch it directly. A child added before activity moved to the
                // parent's iCloud has no Activity zone until a parent sends a new code.
                activity = (try? await SnapshotLoader.activity(activityZone)) ?? .empty(activityZone)
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
        let activity = await SnapshotLoader.cachedActivity(ChildLocator.activityZone(for: zone))
        return ChildState(family: family, activity: activity)
    }

    func join(code: String) async throws {
        try await ChildSetup.join(code: code, store: store)
        await refresh()
    }

    // MARK: Housekeeping after each refresh

    private func afterRefresh(_ state: ChildState) async {
        let family = state.family

        WatchSync.shared.push(WatchContext(childId: family.childId, childName: family.child.name,
                                           birthYear: family.child.birthYear, rules: family.rules,
                                           bonuses: family.bonuses, familyZone: family.zone, updatedAt: Date()))

        if Date().timeIntervalSince(lastDeviceWrite) > 3600 {
            let device = DeviceInfo(deviceId: DeviceIdentity.id, kind: .ios, name: UIDevice.current.name,
                                    lastSeenAt: Date(), detectedApps: nil)
            let zone = ChildLocator.activityZone(for: family.zone)
            if (try? await store.upsert([device.makeRecord(zoneID: zone.zoneID)], scope: zone.scope)) != nil {
                lastDeviceWrite = Date()
            }
        }

        if !subscribed {
            do {
                try await store.ensureDatabaseSubscription(.sharedDB)
                subscribed = true
            } catch {
                // Not fatal: pull-to-refresh and app foregrounding still update.
            }
        }
    }
}
