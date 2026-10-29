import Foundation
import Observation
import WatchConnectivity

/// Rules, birth year and bonuses for the Watch. Comes from the iPhone over
/// WatchConnectivity and, when reachable, straight from CloudKit.
@MainActor
@Observable
final class WatchStore: NSObject, WCSessionDelegate {
    static let shared = WatchStore()

    private static let cacheKey = "watchContext"

    private(set) var context: WatchContext?
    private(set) var lastError: String?

    override init() {
        context = LocalCache.load(WatchContext.self, key: Self.cacheKey)
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func refreshFromCloud() async {
        do {
            if let known = context?.familyZone, ChildLocator.preferredFamilyZone == nil {
                ChildLocator.preferredFamilyZone = known
            }
            try await SyncEngine.shared.sync(.sharedDB)
            guard let zone = await ChildLocator.findFamilyZone(),
                  let family = await SnapshotLoader.cachedFamily(zone) else { return }
            apply(WatchContext(childId: family.childId, childName: family.child.name,
                               birthYear: family.child.birthYear, rules: family.rules,
                               bonuses: family.bonuses, familyZone: zone, updatedAt: Date()))
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
    }

    private func apply(_ new: WatchContext) {
        if let current = context, current.updatedAt > new.updatedAt { return }
        context = new
        LocalCache.save(new, key: Self.cacheKey)
    }

    nonisolated private static func decode(_ dict: [String: Any]) -> WatchContext? {
        guard let data = dict[WatchContext.contextKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchContext.self, from: data)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        guard let ctx = Self.decode(session.receivedApplicationContext) else { return }
        Task { @MainActor in self.apply(ctx) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let ctx = Self.decode(applicationContext) else { return }
        Task { @MainActor in self.apply(ctx) }
    }
}
