import RewardsCore
import SwiftUI

enum Fmt {
    /// "45 min", "1 h 20 min"
    static func minutes(_ m: Int) -> String {
        let sign = m < 0 ? "−" : ""
        let a = abs(m)
        if a < 60 { return "\(sign)\(a) min" }
        let h = a / 60, r = a % 60
        return r == 0 ? "\(sign)\(h) h" : "\(sign)\(h) h \(r) min"
    }

    /// "+30 min" / "−30 min"
    static func signed(_ m: Int) -> String {
        m >= 0 ? "+" + minutes(m) : minutes(m)
    }

    static func reason(_ reason: PlayBlockReason?) -> String? {
        switch reason {
        case .outsidePlayWindow: return "Outside play time"
        case .dailyCapReached: return "Daily play limit reached"
        case .debitLimitReached: return "Out of minutes – go for a walk!"
        case nil: return nil
        }
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension ActivityType {
    var title: String {
        switch self {
        case .walk: return "Walk / Run"
        case .cycle: return "Cycle"
        case .other: return "Workout"
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

/// Big balance display: green in credit, red in debit.
struct BalanceCard: View {
    let state: ChildState

    var body: some View {
        let status = state.status
        VStack(spacing: 8) {
            Text(status.balance < 0 ? "In debit" : "Balance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(Fmt.minutes(status.balance))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .foregroundStyle(status.balance < 0 ? .red : .green)
                .contentTransition(.numericText())
            if status.canPlay {
                Text("Can play \(Fmt.minutes(status.minutesAvailable)) now")
                    .font(.headline)
            } else if let reason = Fmt.reason(status.reason) {
                Text(reason).font(.headline).foregroundStyle(.red)
            }
            let headroom = status.balance + state.family.rules.debitLimit
            if state.family.rules.debitLimit > 0 {
                Text("Debit allowed: \(Fmt.minutes(state.family.rules.debitLimit)) · \(Fmt.minutes(max(0, headroom))) left incl. debit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let bonus = state.activeBonus {
                Label("\(bonus.label) active until \(bonus.endsAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "sparkles")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.yellow.opacity(0.25), in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }
}

/// Today's earned / played / left.
struct TodayStrip: View {
    let state: ChildState

    var body: some View {
        HStack {
            stat("Earned today", Fmt.minutes(state.todayEarned))
            Divider()
            stat("Played today", Fmt.minutes(state.status.todayPlayed))
            if let cap = state.family.rules.dailyPlayCap {
                Divider()
                stat("Left today", Fmt.minutes(max(0, cap - state.status.todayPlayed)))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A multi-line note field used wherever a parent action needs a reason.
struct RequiredNoteField: View {
    @Binding var note: String
    var prompt = "Note (required) – the child sees this"

    var body: some View {
        TextField(prompt, text: $note, axis: .vertical)
            .lineLimit(2...4)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
