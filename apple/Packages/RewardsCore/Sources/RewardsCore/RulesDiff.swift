import Foundation

/// Human-readable summary of what changed between two rule sets, used for
/// `RulesChange.summary` (e.g. "Ratio 10 → 15; walk cadence 100 → 90").
public enum RulesDiff {
    public static func summary(from old: Rules, to new: Rules) -> String {
        var parts: [String] = []
        func add<T: Equatable>(_ label: String, _ a: T, _ b: T, _ fmt: (T) -> String) {
            if a != b { parts.append("\(label) \(fmt(a)) → \(fmt(b))") }
        }
        let int: (Int) -> String = { String($0) }
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        let optMin: (Int?) -> String = { $0.map { "\($0) min" } ?? "none" }

        add("Ratio", old.ratio, new.ratio, int)
        add("walk cadence", old.walkCadenceSpm, new.walkCadenceSpm, int)
        add("walk heart rate", old.walkHrPct, new.walkHrPct, pct)
        add("other heart rate", old.otherHrPct, new.otherHrPct, pct)
        add("minute threshold", old.qualifyFraction, new.qualifyFraction, pct)
        add("debit limit", old.debitLimit, new.debitLimit) { "\($0) min" }
        add("max balance", old.maxBank, new.maxBank, optMin)
        add("daily play cap", old.dailyPlayCap, new.dailyPlayCap, optMin)
        add("play windows", old.playWindows ?? [], new.playWindows ?? [], describe)

        if parts.isEmpty { return "No changes" }
        let text = parts.joined(separator: "; ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    public static func describe(_ windows: [PlayWindow]) -> String {
        guard !windows.isEmpty else { return "any time" }
        return windows.map { "\(describeDays($0.days)) \($0.start)–\($0.end)" }.joined(separator: ", ")
    }

    public static func describeDays(_ days: [Int]) -> String {
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let set = Set(days)
        if set == Set(1...7) { return "Every day" }
        if set == Set(1...5) { return "Mon–Fri" }
        if set == Set([6, 7]) { return "Sat–Sun" }
        return days.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: " ")
    }
}
