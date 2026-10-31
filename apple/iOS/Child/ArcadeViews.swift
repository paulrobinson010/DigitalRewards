import RewardsCore
import SwiftUI

// Arcade-style pieces for Child mode. Everything here is derived from the existing
// family + activity data; nothing extra is stored in iCloud.

extension ChildState {
    /// Workouts that count towards streaks and levels.
    var countedWorkouts: [ResolvedSession] {
        resolved.filter { !$0.isVoided && $0.session.qualifyingMinutes > 0 }
    }

    var progress: PlayerProgress {
        PlayerProgress(lifetimeMinutes: countedWorkouts.reduce(0) { $0 + $1.session.qualifyingMinutes })
    }

    var streakDays: Int {
        Streak.days(activeDates: countedWorkouts.map(\.session.endedAt), timeZone: family.child.tz, now: computedAt)
    }

    /// Most credits earned in a single workout.
    var highScore: Int {
        resolved.filter { !$0.isVoided }.map(\.earnMinutes).max() ?? 0
    }

    var mascotMood: MascotMood {
        if status.reason == .outsidePlayWindow { return .sleepy }
        return status.balance > 0 && status.canPlay ? .happy : .nervous
    }
}

enum MascotMood: Equatable {
    case happy, nervous, sleepy
}

/// "PLAYER 1" and the child's name.
struct PlayerHeader: View {
    let name: String

    var body: some View {
        VStack(spacing: 2) {
            Text("PLAYER 1")
                .font(Theme.label(13))
                .tracking(5)
                .foregroundStyle(Theme.cyan)
                .neonGlow(Theme.cyan, radius: 4)
            Text(name.uppercased())
                .font(Theme.label(28))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The pixel alien, acting out how things are going.
struct Mascot: View {
    let mood: MascotMood
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    var body: some View {
        let color: Color = switch mood {
        case .happy: Theme.green
        case .nervous: Theme.magenta
        case .sleepy: Theme.cyan.opacity(0.65)
        }
        PixelAlien(color: color, animated: !reduceMotion && mood != .sleepy, glow: 10)
            .offset(x: mood == .nervous && phase ? 3 : 0,
                    y: mood == .happy ? (phase ? -10 : 2) : 0)
            .rotationEffect(.degrees(mood == .happy ? (phase ? 4 : -4) : 0))
            .scaleEffect(mood == .sleepy ? (phase ? 0.97 : 1.0) : 1.0)
            .overlay(alignment: .topTrailing) {
                if mood == .sleepy {
                    Text("z Z")
                        .font(Theme.arcade(16))
                        .foregroundStyle(Theme.cyan)
                        .offset(x: 8, y: phase ? -18 : -10)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                let duration: Double = switch mood {
                case .happy: 0.55
                case .nervous: 0.08
                case .sleepy: 1.6
                }
                withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                    phase = true
                }
            }
            // Restart the animation when the mood changes.
            .id(mood)
            .accessibilityLabel(mood == .happy ? "Happy alien" : mood == .nervous ? "Worried alien" : "Sleeping alien")
    }
}

/// The balance as a glowing scoreboard: green credits, magenta debit.
struct CreditsCounter: View {
    let state: ChildState

    var body: some View {
        let status = state.status
        let balance = status.balance
        let color = Theme.balanceColor(balance)
        let debitLimit = state.family.rules.debitLimit
        VStack(spacing: 6) {
            Text(balance < 0 ? "DEBIT" : "CREDITS")
                .font(Theme.label(14))
                .tracking(5)
                .foregroundStyle(color)
            Text((balance < 0 ? "−" : "") + String(format: "%03d", abs(balance)))
                .font(Theme.arcade(64))
                .foregroundStyle(color)
                .neonGlow(color, radius: 14)
                .contentTransition(.numericText(value: Double(balance)))
                .animation(.spring(duration: 0.8), value: balance)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("minutes of game time")
                .font(.caption)
                .foregroundStyle(.secondary)
            if debitLimit > 0 {
                let headroom = max(0, balance + debitLimit)
                Text("Debit allowed \(Fmt.minutes(debitLimit)) · \(Fmt.minutes(headroom)) left incl. debit")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let bonus = state.activeBonus {
                Label("\(bonus.label) until \(bonus.endsAt.formatted(date: .abbreviated, time: .shortened))",
                      systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.bgBottom)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.yellow, in: Capsule())
                    .neonGlow(Theme.yellow, radius: 6)
            }
        }
        .neonCard(border: color)
    }
}

/// A stopwatch ring like the app icon: time left today when there's a daily limit,
/// otherwise credits earned today towards a 30-minute activity goal.
struct TodayRing: View {
    let state: ChildState

    var body: some View {
        let ring = values
        ZStack {
            Circle()
                .stroke(Theme.cyan, lineWidth: 8)
                .neonGlow(Theme.cyan, radius: 6)
            Circle()
                .trim(from: 0, to: ring.fraction)
                .stroke(Theme.magenta, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(16)
                .neonGlow(Theme.magenta, radius: 6)
                .animation(.easeOut(duration: 0.8), value: ring.fraction)
            VStack(spacing: 2) {
                Text(ring.value)
                    .font(Theme.arcade(18))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(ring.caption)
                    .font(Theme.label(9))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
        }
        .overlay(alignment: .top) {
            Capsule()
                .fill(Theme.cyan)
                .frame(width: 26, height: 8)
                .offset(y: -14)
                .neonGlow(Theme.cyan, radius: 4)
        }
        .frame(width: 140, height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ring.caption.capitalized): \(ring.value)")
    }

    private var values: (fraction: Double, value: String, caption: String) {
        let rules = state.family.rules
        if let cap = rules.dailyPlayCap, cap > 0 {
            let left = max(0, cap - state.status.todayPlayed)
            return (Double(left) / Double(cap), Fmt.minutes(left), "LEFT TODAY")
        }
        let goal = max(1, rules.ratio * 30)
        let earned = state.todayEarned
        return (min(1, Double(earned) / Double(goal)), Fmt.minutes(earned), "EARNED TODAY")
    }
}

/// GAME OVER / INSERT COIN / READY, in kid language.
struct ArcadeBanner: View {
    let state: ChildState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var blink = false

    var body: some View {
        let status = state.status
        Group {
            if !status.canPlay {
                banner(title: "GAME OVER", color: Theme.magenta, message: Self.kidReason(status.reason))
            } else if status.balance <= 0 {
                banner(title: "INSERT COIN", color: Theme.yellow,
                       message: "Go for a walk to earn credits!"
                           + (status.minutesAvailable > 0 ? "\nYou can still play \(Fmt.minutes(status.minutesAvailable)) on debit." : ""))
            } else {
                banner(title: "READY!", color: Theme.green,
                       message: "You can play \(Fmt.minutes(status.minutesAvailable)) now.")
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { blink = true }
        }
    }

    private func banner(title: String, color: Color, message: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(Theme.arcade(28))
                .foregroundStyle(color)
                .neonGlow(color, radius: 10)
                .opacity(title == "READY!" || !blink ? 1 : 0.45)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
        }
        .neonCard(border: color)
    }

    static func kidReason(_ reason: PlayBlockReason?) -> String {
        switch reason {
        case .outsidePlayWindow: return "It's not play time right now. Come back later!"
        case .dailyCapReached: return "You've used all your play time for today. See you tomorrow!"
        case .debitLimitReached, nil: return "You're out of credits. Go for a walk to earn more!"
        }
    }
}

/// Streak, level and high score.
struct PlayerStatsCard: View {
    let state: ChildState

    var body: some View {
        let progress = state.progress
        let streak = state.streakDays
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(streak > 0 ? "🔥 \(streak)-day streak" : "Start a streak today!")
                    .font(Theme.label(17))
                    .foregroundStyle(streak > 0 ? Theme.yellow : .secondary)
                Spacer()
                if state.highScore > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("HIGH SCORE")
                            .font(Theme.label(9))
                            .tracking(2)
                            .foregroundStyle(.secondary)
                        Text("+\(state.highScore)")
                            .font(Theme.arcade(18))
                            .foregroundStyle(Theme.green)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("LEVEL \(progress.level.rawValue + 1)")
                        .font(Theme.label(11))
                        .tracking(2)
                        .foregroundStyle(.secondary)
                    Text(progress.level.title.uppercased())
                        .font(Theme.label(15))
                        .foregroundStyle(Theme.cyan)
                }
                ProgressView(value: progress.fractionToNext)
                    .tint(Theme.cyan)
                Text(progress.nextLevel.map { "\(progress.minutesToNext) active min to \($0.title)" }
                     ?? "Top level reached. Legend!")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .neonCard(border: Theme.cyan)
    }
}

// MARK: - Celebration

struct Celebration: Identifiable, Equatable {
    let id = UUID()
    let credits: Int
    let start = Date()
}

/// "+N CREDITS!" with pixel confetti (just the text when Reduce Motion is on).
struct CelebrationOverlay: View {
    let celebration: Celebration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if !reduceMotion {
                PixelConfetti(start: celebration.start)
            }
            Text("+\(celebration.credits) CREDITS!")
                .font(Theme.arcade(34))
                .foregroundStyle(Theme.green)
                .neonGlow(Theme.green, radius: 16)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.bgBottom.opacity(0.85)))
                .multilineTextAlignment(.center)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("You earned \(celebration.credits) credits")
    }
}

/// Falling neon pixels.
struct PixelConfetti: View {
    let start: Date
    @State private var pieces = PixelConfetti.makePieces()

    struct Piece {
        var x: Double
        var delay: Double
        var speed: Double
        var size: Double
        var drift: Double
        var color: Color
    }

    static func makePieces() -> [Piece] {
        let colors = [Theme.green, Theme.cyan, Theme.magenta, Theme.yellow]
        return (0..<90).map { _ in
            Piece(x: .random(in: 0...1), delay: .random(in: 0...0.6), speed: .random(in: 0.3...0.7),
                  size: .random(in: 6...12), drift: .random(in: -0.08...0.08),
                  color: colors.randomElement() ?? Theme.green)
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                context.opacity = max(0, min(1, 3.2 - t))
                for p in pieces {
                    let tt = t - p.delay
                    guard tt > 0 else { continue }
                    let y = -20 + tt * p.speed * size.height
                    guard y < size.height + 20 else { continue }
                    let x = (p.x + p.drift * tt) * size.width
                    context.fill(Path(CGRect(x: x, y: y, width: p.size, height: p.size)), with: .color(p.color))
                }
            }
        }
        .ignoresSafeArea()
    }
}
