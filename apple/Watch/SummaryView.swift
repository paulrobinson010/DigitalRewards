import RewardsCore
import SwiftUI

struct SummaryView: View {
    @Environment(WorkoutManager.self) private var workout
    @Environment(SessionUploader.self) private var uploader

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                if let s = workout.lastSession {
                    Text("\(workout.displayedMinutes) min earned")
                        .font(.title3.bold())
                    if workout.bonusMultiplier > 1 {
                        Text("Includes \(BonusInfo.label(workout.bonusMultiplier))").font(.footnote)
                    }
                    Text("\(s.qualifyingMinutes) of \(s.minutes.count) minutes above the bar")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    if s.minutes.isEmpty {
                        Text("Too short to save.").font(.footnote).foregroundStyle(.secondary)
                    } else if uploader.pending.contains(where: { $0.id == s.id }) {
                        Label("Will upload when online", systemImage: "icloud.and.arrow.up")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Label("Saved", systemImage: "icloud.fill")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Button("Done") { workout.reset() }
            }
        }
    }
}
