import RewardsCore
import SwiftUI

/// One line in a child's history. Every parent action shows who did it and why.
struct HistoryItem: Identifiable {
    enum Kind {
        case workout(ResolvedSession)
        case play(minutes: Int, apps: [String])
        case adjustment(AdjustmentEntry)
        case bonus(BonusInfo)
        case rulesChange(RulesChangeInfo)
    }

    var id: String
    var date: Date
    var kind: Kind
}

enum HistoryBuilder {
    static func items(for state: ChildState) -> [HistoryItem] {
        var items: [HistoryItem] = []
        items += state.resolved.map { HistoryItem(id: $0.id, date: $0.session.endedAt, kind: .workout($0)) }
        items += state.family.adjustments.map { HistoryItem(id: $0.id, date: $0.at, kind: .adjustment($0)) }
        items += state.family.bonuses.map { HistoryItem(id: $0.id, date: $0.at, kind: .bonus($0)) }
        items += state.family.rulesChanges.map { HistoryItem(id: $0.id, date: $0.at, kind: .rulesChange($0)) }

        // Play is one Spend per minute; group it by day in the child's time zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.family.child.tz
        let byDay = Dictionary(grouping: state.activity?.spends ?? []) { calendar.startOfDay(for: $0.at) }
        for (day, spends) in byDay {
            let apps = Array(Set(spends.map(\.app).filter { !$0.isEmpty })).sorted()
            let last = spends.map(\.at).max() ?? day
            items.append(HistoryItem(id: "play-\(Int(day.timeIntervalSince1970))", date: last,
                                     kind: .play(minutes: spends.reduce(0) { $0 + $1.minutes }, apps: apps)))
        }
        return items.sorted { $0.date > $1.date }
    }
}

struct HistoryRow: View {
    let item: HistoryItem
    /// Child mode: arcade-style titles. Parent notes are shown either way.
    var arcade = false

    var body: some View {
        switch item.kind {
        case .workout(let r): WorkoutRow(resolved: r, arcade: arcade)
        case .play(let minutes, let apps): playRow(minutes, apps)
        case .adjustment(let a): adjustmentRow(a)
        case .bonus(let b): bonusRow(b)
        case .rulesChange(let c): rulesRow(c)
        }
    }

    private func playRow(_ minutes: Int, _ apps: [String]) -> some View {
        let day = item.date.formatted(date: .abbreviated, time: .omitted)
        return row(icon: "gamecontroller.fill", tint: Theme.magenta,
                   title: arcade ? "GAME TIME · \(day)" : "Played \(day)",
                   detail: apps.isEmpty ? nil : apps.joined(separator: ", "),
                   amount: Fmt.signed(-minutes), amountColor: Theme.debit)
    }

    private func adjustmentRow(_ a: AdjustmentEntry) -> some View {
        let added = a.minutes >= 0
        let title = arcade ? "\(added ? "POWER-UP" : "PENALTY") from \(a.byParent)"
                           : "\(a.byParent) \(added ? "added" : "removed") minutes"
        return row(icon: added ? "plus.circle.fill" : "minus.circle.fill", tint: Theme.cyan,
                   title: title, detail: a.note, amount: Fmt.signed(a.minutes),
                   amountColor: added ? Theme.credit : Theme.debit)
    }

    private func bonusRow(_ b: BonusInfo) -> some View {
        let range = "\(b.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(b.endsAt.formatted(date: .abbreviated, time: .shortened))"
        return row(icon: "sparkles", tint: Theme.yellow,
                   title: arcade ? "MULTIPLIER \(b.label) by \(b.byParent)" : "\(b.label) by \(b.byParent)",
                   detail: "\(range)\n\(b.note)", amount: nil, amountColor: .primary)
    }

    private func rulesRow(_ c: RulesChangeInfo) -> some View {
        row(icon: "slider.horizontal.3", tint: Theme.cyan.opacity(0.7),
            title: arcade ? "NEW RULES from \(c.byParent)" : "Rules changed by \(c.byParent)",
            detail: "\(c.summary)\n\(c.note)", amount: nil, amountColor: .primary)
    }

    private func row(icon: String, tint: Color, title: String, detail: String?,
                     amount: String?, amountColor: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                if let detail, !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if let amount {
                Text(amount).font(.subheadline.monospacedDigit()).foregroundStyle(amountColor)
            }
        }
    }
}

struct WorkoutRow: View {
    let resolved: ResolvedSession
    var arcade = false

    var body: some View {
        let s = resolved.session
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: s.activityType.symbol).foregroundStyle(Theme.green).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(arcade ? "\(s.activityType.title.uppercased()) · \(s.qualifyingMinutes) min powered up"
                            : "\(s.activityType.title) · \(s.qualifyingMinutes) of \(s.minutes.count) min above the bar")
                    .font(.subheadline.weight(.semibold))
                if let bonus = resolved.bonus {
                    Text(bonus.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .foregroundStyle(Theme.bgBottom)
                        .background(Theme.yellow, in: Capsule())
                }
                if let o = resolved.sessionOverride {
                    Text(o.earnedMinutes == 0 ? "Voided by \(o.byParent): \(o.note)" : "Edited by \(o.byParent): \(o.note)")
                        .font(.caption)
                        .foregroundStyle(Theme.yellow)
                }
                Text(s.endedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                if resolved.sessionOverride != nil {
                    Text(Fmt.signed(resolved.originalMinutes))
                        .strikethrough()
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(resolved.isVoided ? "Void" : Fmt.signed(resolved.earnMinutes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(resolved.isVoided ? Color.secondary : Theme.green)
            }
        }
    }
}
