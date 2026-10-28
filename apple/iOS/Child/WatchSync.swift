import Foundation
import WatchConnectivity

/// Pushes the child's rules, birth year and bonuses to the Watch app.
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    private var pending: WatchContext?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func push(_ context: WatchContext) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            pending = context
            return
        }
        guard session.isPaired, session.isWatchAppInstalled,
              let data = try? JSONEncoder().encode(context) else { return }
        try? session.updateApplicationContext([WatchContext.contextKey: data])
        pending = nil
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            if let pending = self.pending { self.push(pending) }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate after switching to a different watch.
        session.activate()
    }
}
