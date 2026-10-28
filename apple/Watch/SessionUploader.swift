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
        let zoneID = ChildLocator.activityZone.zoneID
        for session in pending {
            let device = DeviceInfo(deviceId: DeviceIdentity.id, kind: .watch,
                                    name: WKInterfaceDevice.current().name,
                                    lastSeenAt: Date(), detectedApps: nil)
            do {
                try await CloudStore.shared.upsert([session.makeRecord(zoneID: zoneID), device.makeRecord(zoneID: zoneID)],
                                                   scope: .privateDB)
                pending.removeAll { $0.id == session.id }
                persist()
                lastError = nil
            } catch {
                // Typically offline, or the iPhone hasn't created the Activity zone yet. Retry later.
                lastError = error.localizedDescription
                break
            }
        }
    }

    private func persist() {
        LocalCache.save(pending, key: Self.cacheKey)
    }
}
