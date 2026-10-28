import Foundation
import RewardsCore
import UserNotifications

/// Compares each refresh with what this parent's device saw last time and posts
/// local notifications. Runs after every parent refresh (foreground, silent push
/// or background refresh), so delivery is best-effort.
@MainActor
enum AlertMonitor {
    private static let memoryKey = "alertMemory"

    /// Thresholds for "suspicious session".
    static let maxPlausibleHeartRate = 220.0
    static let maxPlausibleCadence = 250.0
    /// A Windows device silent this long during likely-use hours triggers an alert.
    static let deviceSilenceThreshold: TimeInterval = 2 * 3600

    struct ChildMemory: Codable {
        var seenSessions: Set<String> = []
        var lastBalance: Int = 0
        /// deviceId -> the lastSeenAt we already alerted about.
        var alertedSilence: [String: Date] = [:]
    }

    static func process(children: [ChildEntry], prefs: [String: AlertPrefsInfo], now: Date) async {
        var memory = LocalCache.load([String: ChildMemory].self, key: memoryKey) ?? [:]
        var notes: [(title: String, body: String)] = []

        for entry in children where entry.hasActivity {
            let state = entry.state
            let p = prefs[state.childId] ?? AlertPrefsInfo(childId: state.childId)
            let sessions = state.activity?.sessions ?? []

            guard var m = memory[state.childId] else {
                // First time we see this child: remember everything, alert on nothing.
                memory[state.childId] = ChildMemory(seenSessions: Set(sessions.map(\.id)),
                                                    lastBalance: state.status.balance)
                continue
            }

            for resolved in state.resolved where !m.seenSessions.contains(resolved.id) {
                m.seenSessions.insert(resolved.id)
                if p.workout {
                    let bonus = resolved.bonus.map { " (\($0.label))" } ?? ""
                    notes.append(("\(state.name) finished a workout",
                                  "Earned \(Fmt.minutes(resolved.earnMinutes))\(bonus)."))
                }
                if p.suspicious, let reason = suspicionReason(resolved.session, among: sessions) {
                    notes.append(("Check \(state.name)'s workout", reason))
                }
            }

            let balance = state.status.balance
            if p.debit, m.lastBalance >= 0, balance < 0 {
                notes.append(("\(state.name) went into debit", "Balance is now \(Fmt.minutes(balance))."))
            }
            m.lastBalance = balance

            for device in state.activity?.devices ?? [] where device.kind == .windows {
                guard now.timeIntervalSince(device.lastSeenAt) > deviceSilenceThreshold,
                      m.alertedSilence[device.deviceId] != device.lastSeenAt,
                      likelyInUse(state: state, now: now) else { continue }
                m.alertedSilence[device.deviceId] = device.lastSeenAt
                if p.deviceSilent {
                    notes.append(("\(device.name) stopped reporting",
                                  "\(state.name)'s PC hasn't checked in since \(Fmt.relative(device.lastSeenAt)). It may be offline or the blocker may have been tampered with."))
                }
            }
            memory[state.childId] = m
        }

        LocalCache.save(memory, key: memoryKey)
        for note in notes {
            await post(title: note.title, body: note.body)
        }
    }

    static func suspicionReason(_ s: SessionInfo, among all: [SessionInfo]) -> String? {
        let wallMinutes = s.endedAt.timeIntervalSince(s.startedAt) / 60
        if Double(s.qualifyingMinutes) > wallMinutes + 0.5 {
            return "It counted more minutes than the workout lasted."
        }
        if s.minutes.contains(where: { ($0.hr ?? 0) > maxPlausibleHeartRate }) {
            return "It recorded an implausible heart rate."
        }
        if s.minutes.contains(where: { ($0.cad ?? 0) > maxPlausibleCadence }) {
            return "It recorded an implausible step rate."
        }
        if all.contains(where: { $0.id != s.id && $0.startedAt < s.endedAt && s.startedAt < $0.endedAt }) {
            return "It overlaps another workout."
        }
        return nil
    }

    /// Inside a play window, or 08:00–22:00 in the child's time zone.
    static func likelyInUse(state: ChildState, now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = state.family.child.tz
        if let windows = state.family.rules.playWindows, !windows.isEmpty {
            let c = calendar.dateComponents([.weekday, .hour, .minute], from: now)
            let iso = ((c.weekday ?? 1) + 5) % 7 + 1
            let t = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            if windows.contains(where: { w in
                w.days.contains(iso) && (w.startMinutes ?? 0) <= t && t < (w.endMinutes ?? 0)
            }) {
                return true
            }
        }
        let hour = calendar.component(.hour, from: now)
        return (8..<22).contains(hour)
    }

    private static func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
