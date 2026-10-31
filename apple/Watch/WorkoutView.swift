import RewardsCore
import SwiftUI

struct WorkoutView: View {
    @Environment(WorkoutManager.self) private var workout
    @State private var confirmEnd = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ScrollView {
                VStack(spacing: 6) {
                    Text(Duration.seconds(workout.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                        .font(.system(.title3, design: .rounded).monospacedDigit())

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(workout.displayedMinutes)")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                        Text("min earned").font(.footnote).foregroundStyle(.secondary)
                    }
                    if workout.bonusMultiplier > 1 {
                        Text(BonusInfo.label(workout.bonusMultiplier))
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.yellow.opacity(0.25), in: Capsule())
                    }

                    barIndicator
                    readings

                    ProgressView(value: Double(workout.ticksInMinute), total: Double(AppConfig.samplesPerMinute))
                        .tint(workout.aboveBar ? Theme.green : Theme.magenta)

                    controls
                }
                .padding(.horizontal, 4)
            }
        }
        .navigationBarBackButtonHidden(true)
        .confirmationDialog("End workout?", isPresented: $confirmEnd) {
            Button("End", role: .destructive) { Task { await workout.end() } }
            Button("Keep going", role: .cancel) {}
        }
    }

    private var barIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(workout.phase == .paused ? Color.gray : (workout.aboveBar ? Theme.green : Theme.magenta))
                .frame(width: 12, height: 12)
            Text(workout.phase == .paused ? "Paused" : (workout.aboveBar ? "Above the bar" : "Speed up!"))
                .font(.footnote.bold())
        }
    }

    private var readings: some View {
        HStack {
            Label(workout.heartRate.map { "\(Int($0.rounded()))" } ?? "--", systemImage: "heart.fill")
                .foregroundStyle(.pink)
            Text("/ \(workout.thresholdBpm)").foregroundStyle(.secondary)
            if workout.activity == .walk {
                Spacer()
                Label(workout.cadence.map { "\(Int($0.rounded()))" } ?? "--", systemImage: "shoeprints.fill")
                Text("/ \(workout.rules.walkCadenceSpm)").foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }

    private var controls: some View {
        HStack {
            if workout.phase == .paused {
                Button { workout.resume() } label: { Image(systemName: "play.fill") }
                    .tint(Theme.green)
            } else {
                Button { workout.pause() } label: { Image(systemName: "pause.fill") }
                    .tint(.yellow)
                    .disabled(workout.phase != .running)
            }
            Button { confirmEnd = true } label: { Image(systemName: "stop.fill") }
                .tint(Theme.magenta)
                .disabled(workout.phase == .ending)
        }
    }
}
