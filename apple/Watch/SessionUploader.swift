import Foundation
import Observation
import WatchKit

/// Persistent queue of finished sessions. Saves are idempotent (fixed record
/// names), so retrying after a partial failure never double-counts.
@MainActor
@Observable
final class SessionUploader {
    static let shared = SessionUploader()

    private static let cacheKey = "pendingSessions"

    private(set) var pending: [SessionInfo]
    private(set) var lastError: String?
    private var isFlushing = false

    init() {
        pending = LocalCache.load([SessionInfo].self, key: Self.cacheKey) ?? []
    }

    func enqueue(_ session: SessionInfo) {
        pending.removeAll { $0.id == session.id }
        pending.append(session)
        persist()
        Task { await flush() }
    }

    func flush() async {
        guard !isFlushing, !pending.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        // Sessions go to the child's Activity zone in the parent's iCloud (shared database).
        var familyZone = await ChildLocator.findFamilyZone()
        if familyZone == nil { familyZone = WatchStore.shared.context?.familyZone }
        guard let family = familyZone else {
            lastError = "Join your family in DigitalRewards on your iPhone first."
            return
        }
        let zone = ChildLocator.activityZone(for: family)
        let zoneID = zone.zoneID
        for session in pending {
            let device = DeviceInfo(deviceId: DeviceIdentity.id, kind: .watch,
                                    name: WKInterfaceDevice.current().name,
                                    lastSeenAt: Date(), detectedApps: nil)
            do {
                try await CloudStore.shared.upsert([session.makeRecord(zoneID: zoneID), device.makeRecord(zoneID: zoneID)],
                                                   scope: zone.scope)
                pending.removeAll { $0.id == session.id }
                persist()
                lastError = nil
            } catch {
                // Typically offline. Retry later.
                lastError = error.userMessage
                break
            }
        }
    }

    private func persist() {
        LocalCache.save(pending, key: Self.cacheKey)
    }
}
