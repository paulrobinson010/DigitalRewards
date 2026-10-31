import RewardsCore
import SwiftUI

struct StartView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WorkoutManager.self) private var workout
    @Environment(SessionUploader.self) private var uploader

    var body: some View {
        List {
            if let bonus = store.context?.activeBonus(at: Date()) {
                Label(bonus.label, systemImage: "sparkles")
                    .foregroundStyle(.yellow)
            }
            ForEach(ActivityType.allCases, id: \.self) { activity in
                Button {
                    Task { await workout.start(activity, context: store.context) }
                } label: {
                    Label(activity.title, systemImage: activity.symbol)
                        .font(.headline)
                        .padding(.vertical, 8)
                }
            }
            if store.context == nil {
                Text("Open DigitalRewards on your iPhone and join your family first. Workouts will still be saved.")
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
