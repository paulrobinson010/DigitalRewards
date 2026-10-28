import SwiftUI

@main
struct DigitalRewardsWatchApp: App {
    @State private var store = WatchStore.shared
    @State private var workout = WorkoutManager()
    @State private var uploader = SessionUploader.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .environment(workout)
                .environment(uploader)
        }
    }
}

struct WatchRootView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WorkoutManager.self) private var workout
    @Environment(SessionUploader.self) private var uploader
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            switch workout.phase {
            case .idle:
                StartView()
            case .running, .paused, .ending:
                WorkoutView()
            case .finished:
                SummaryView()
            }
        }
        .task {
            store.activate()
            await workout.requestAuthorization()
            await store.refreshFromCloud()
            await uploader.flush()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await uploader.flush()
                await store.refreshFromCloud()
            }
        }
    }
}
