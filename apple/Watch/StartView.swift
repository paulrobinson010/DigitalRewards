import RewardsCore
import SwiftUI

struct StartView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WorkoutManager.self) private var workout
    @Environment(SessionUploader.self) private var uploader

    var body: some View {
        List {
            VStack(spacing: 4) {
                PixelAlien(animated: true, glow: 5)
                    .frame(height: 34)
                Text("READY?")
                    .font(Theme.label(14))
                    .tracking(3)
                    .foregroundStyle(Theme.cyan)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            if let bonus = store.context?.activeBonus(at: Date()) {
                Label(bonus.label, systemImage: "sparkles")
                    .foregroundStyle(Theme.yellow)
            }
            ForEach(ActivityType.allCases, id: \.self) { activity in
                Button {
                    Task { await workout.start(activity, context: store.context) }
                } label: {
                    Label(activity.title, systemImage: activity.symbol)
                        .font(.headline)
                        .foregroundStyle(Theme.green)
                        .padding(.vertical, 8)
                }
            }
            #if DEBUG
            Button("Demo workout", systemImage: "camera") { workout.startDemo() }
                .foregroundStyle(Theme.yellow)
            Button("Demo summary", systemImage: "camera") { workout.showDemoSummary() }
                .foregroundStyle(Theme.yellow)
            #endif
            if store.context == nil && !Self.hidesJoinHint {
                Text("Open Go AFK on your iPhone and join your family first. Workouts will still be saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !uploader.pending.isEmpty {
                Label("\(uploader.pending.count) workout(s) waiting to upload", systemImage: "icloud.and.arrow.up")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = workout.errorMessage {
                Text(error).font(.footnote).foregroundStyle(Theme.magenta)
            }
        }
        .navigationTitle("Earn minutes")
    }

    /// Screenshot mode has no family on the watch; don't show the "join first" hint.
    private static var hidesJoinHint: Bool {
        #if DEBUG
        return ScreenshotMode.isOn
        #else
        return false
        #endif
    }
}

extension ActivityType {
    var title: String {
        switch self {
        case .walk: return "Walk / Run"
        case .cycle: return "Cycle"
        case .other: return "Other workout"
        }
    }

    var symbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .cycle: return "figure.outdoor.cycle"
        case .other: return "figure.mixed.cardio"
        }
    }
}
