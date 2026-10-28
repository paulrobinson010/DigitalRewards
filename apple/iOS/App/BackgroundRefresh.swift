import BackgroundTasks
import Foundation

/// Periodic background refresh so parents get "device stopped reporting" alerts
/// even when nothing else changes. iOS decides when it actually runs.
enum BackgroundRefresh {
    /// Must match BGTaskSchedulerPermittedIdentifiers in project.yml.
    static let identifier = "com.digitalrewards.app.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    static func run() async {
        schedule()
        await AppServices.shared.refresh()
    }
}
