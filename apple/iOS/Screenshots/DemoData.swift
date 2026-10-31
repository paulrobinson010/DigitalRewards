#if DEBUG
import CloudKit
import Foundation
import RewardsCore

/// The fixed demo family for App Store screenshots: Dad (signed in) and Mum, Jensen (12, the
/// featured child, in credit) and Lotus (6, slightly in debit). Built in memory; nothing
/// touches iCloud. Everything is relative to a fixed "now": the most recent weekday at 17:30.
@MainActor
enum DemoData {
    static let jensenId = "demo-jensen"
    static let lotusId = "demo-lotus"
    static let pcDeviceId = "demo-jensen-pc"

    static let dad = ParentInfo(recordName: ParentInfo.recordName(userRecordName: "demo-dad"),
                                displayName: "Dad", lookupEmail: "dad@example.com", lookupPhone: nil)
    static let mum = ParentInfo(recordName: ParentInfo.recordName(userRecordName: "demo-mum"),
                                displayName: "Mum", lookupEmail: "mum@example.com", lookupPhone: nil)
    static let profile = ParentProfile(displayName: "Dad", email: "dad@example.com", phone: nil,
                                       userRecordName: "demo-dad")

    /// The celebration frozen mid-burst for the "+120 CREDITS!" shot (today's walk).
    static let celebration = Celebration(credits: 120)

    static let now: Date = {
        let cal = Calendar.current
        let real = Date()
        var day = cal.startOfDay(for: real)
        for _ in 0..<8 {
            if let t = cal.date(bySettingHour: 17, minute: 30, second: 0, of: day), t <= real, !cal.isDateInWeekend(t) {
                return t
            }
            guard let previous = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return real
    }()

    static var jensen: ChildState { jensenState(balance: 145) }
    /// Same Jensen, more play: −20 with 40 min of debit left.
    static var jensenDebit: ChildState { jensenState(balance: -20) }
    static var lotus: ChildState { lotusState(balance: -20) }

    static var parentEntries: [ChildEntry] {
        [ChildEntry(state: jensen, hasActivity: true), ChildEntry(state: lotus, hasActivity: true)]
    }

    // MARK: Jensen

    private static let jensenRules = Rules(
        ratio: 10, debitLimit: 60, dailyPlayCap: 180,
        playWindows: [PlayWindow(days: [1, 2, 3, 4, 5], start: "16:00", end: "20:30"),
                      PlayWindow(days: [6, 7], start: "09:00", end: "20:30")])

    private static func jensenState(balance target: Int) -> ChildState {
        let child = ChildInfo(childId: jensenId, name: "Jensen", birthYear: year - 12,
                              timeZone: TimeZone.current.identifier)
        var rng = SeededRandom(seed: 7)

        // (days ago, type, start hour, start minute, total minutes, qualifying minutes)
        let plan: [(Int, ActivityType, Int, Int, Int, Int)] = [
            (0, .walk, 16, 10, 25, 12),
            (1, .cycle, 17, 0, 30, 20),
            (2, .walk, 7, 50, 20, 14),
            (3, .other, 16, 30, 40, 25),
            (4, .walk, 16, 40, 18, 10),
            (6, .walk, 10, 15, 30, 22),
            (7, .walk, 16, 20, 35, 30),
            (8, .other, 15, 0, 25, 18),
            (9, .cycle, 11, 0, 50, 40),
            (10, .walk, 16, 45, 40, 35),
            (12, .walk, 9, 30, 30, 25),
            (13, .other, 14, 0, 35, 28),
        ]
        let sessions = plan.enumerated().map { i, p in
            session(id: "session-demo-jensen-\(i)", daysAgo: p.0, type: p.1, hour: p.2, minute: p.3,
                    total: p.4, qualifying: p.5, rules: jensenRules, rng: &rng)
        }
        let devices = [
            DeviceInfo(deviceId: pcDeviceId, kind: .windows, name: "Jensen's PC",
                       lastSeenAt: now.addingTimeInterval(-120), detectedApps: pcApps),
            DeviceInfo(deviceId: "demo-jensen-iphone", kind: .ios, name: "Jensen's iPhone",
                       lastSeenAt: now.addingTimeInterval(-900), detectedApps: nil),
            DeviceInfo(deviceId: "demo-jensen-watch", kind: .watch, name: "Jensen's Apple Watch",
                       lastSeenAt: now.addingTimeInterval(-3000), detectedApps: nil),
        ]
        var family = FamilySnapshot(
            zone: .privateZone(AppConfig.familyZoneName(childId: jensenId)),
            child: child, rules: jensenRules,
            adjustments: [
                AdjustmentEntry(id: "adjust-demo-1", minutes: 30, note: "Tidied your room without being asked",
                                at: at(daysAgo: 2, hour: 19, minute: 5), byParent: "Dad"),
                AdjustmentEntry(id: "adjust-demo-2", minutes: -15, note: "Late to bed on a school night",
                                at: at(daysAgo: 8, hour: 21, minute: 40), byParent: "Mum"),
            ],
            overrides: [
                SessionOverrideInfo(sessionId: sessions[5].id, earnedMinutes: 100,
                                    note: "Lotus wore your watch for part of this one",
                                    at: at(daysAgo: 6, hour: 12, minute: 0), byParent: "Dad"),
            ],
            bonuses: [weekendBonus],
            rulesChanges: [
                RulesChangeInfo(id: "ruleschange-demo-1",
                                summary: "Daily play limit: none → 3 h; play times: any time → Mon–Fri 16:00–20:30, Sat–Sun 09:00–20:30",
                                note: "New school-night routine", at: at(daysAgo: 5, hour: 18, minute: 0),
                                byParent: "Dad"),
            ],
            parents: [dad, mum],
            allowLists: [AllowListInfo(deviceId: pcDeviceId, executables: ["winword.exe", "ms-teams.exe", "chrome.exe"])])
        family.lastModified = now

        // Play: about 4 h a day before the new limit, then within the limit; today 45 min so far.
        let playPlan: [(Int, Int, Int, Int, [String])] = [
            // (days ago, start hour, start minute, minutes, apps)
            (13, 13, 0, 230, ["Minecraft", "Roblox"]),
            (12, 14, 0, 240, ["Fortnite", "Minecraft"]),
            (11, 15, 30, 210, ["Rocket League"]),
            (10, 17, 30, 200, ["Minecraft"]),
            (9, 13, 0, 250, ["Fortnite", "Rocket League"]),
            (8, 16, 0, 220, ["Roblox"]),
            (7, 17, 0, 180, ["Minecraft"]),
            (6, 12, 30, 240, ["Fortnite"]),
            (4, 17, 0, 150, ["Minecraft"]),
            (3, 17, 15, 170, ["Rocket League", "Minecraft"]),
            (2, 16, 0, 160, ["Fortnite"]),
            (1, 18, 0, 140, ["Roblox", "Minecraft"]),
            (0, 16, 45, 45, ["Minecraft"]),
        ]
        var spends = playPlan.flatMap { play(daysAgo: $0.0, hour: $0.1, minute: $0.2, minutes: $0.3, apps: $0.4) }
        let activity = ActivitySnapshot(zone: .privateZone(AppConfig.activityZoneName(childId: jensenId)),
                                        sessions: sessions, spends: spends, devices: devices)
        // Tune the oldest day's play so the balance lands exactly on the target.
        let current = ChildState(family: family, activity: activity, now: now).status.balance
        spends += play(daysAgo: 14, hour: 15, minute: 0, minutes: max(0, current - target), apps: ["Minecraft"])
        let tuned = ActivitySnapshot(zone: activity.zone, sessions: sessions, spends: spends, devices: devices)
        return ChildState(family: family, activity: tuned, now: now)
    }

    // MARK: Lotus

    private static func lotusState(balance target: Int) -> ChildState {
        let rules = Rules(ratio: 10, debitLimit: 30)
        let child = ChildInfo(childId: lotusId, name: "Lotus", birthYear: year - 6,
                              timeZone: TimeZone.current.identifier)
        var rng = SeededRandom(seed: 11)
        let plan: [(Int, ActivityType, Int, Int, Int, Int)] = [
            (1, .walk, 16, 0, 15, 8),
            (3, .other, 10, 0, 20, 12),
            (5, .walk, 15, 30, 12, 6),
            (9, .other, 11, 0, 25, 15),
        ]
        let sessions = plan.enumerated().map { i, p in
            session(id: "session-demo-lotus-\(i)", daysAgo: p.0, type: p.1, hour: p.2, minute: p.3,
                    total: p.4, qualifying: p.5, rules: rules, rng: &rng)
        }
        let family = FamilySnapshot(zone: .privateZone(AppConfig.familyZoneName(childId: lotusId)),
                                    child: child, rules: rules, parents: [dad, mum])
        var spends = [(0, 16, 0, 40), (1, 17, 0, 60), (3, 15, 0, 90), (5, 16, 30, 50), (9, 14, 0, 120)]
            .flatMap { play(daysAgo: $0.0, hour: $0.1, minute: $0.2, minutes: $0.3, apps: ["Toca Boca"]) }
        let devices = [DeviceInfo(deviceId: "demo-lotus-ipad", kind: .ios, name: "Lotus's iPad",
                                  lastSeenAt: now.addingTimeInterval(-600), detectedApps: nil)]
        let zone = ZoneRef.privateZone(AppConfig.activityZoneName(childId: lotusId))
        let current = ChildState(family: family,
                                 activity: ActivitySnapshot(zone: zone, sessions: sessions, spends: spends, devices: devices),
                                 now: now).status.balance
        spends += play(daysAgo: 10, hour: 15, minute: 0, minutes: max(0, current - target), apps: ["Toca Boca"])
        return ChildState(family: family,
                          activity: ActivitySnapshot(zone: zone, sessions: sessions, spends: spends, devices: devices),
                          now: now)
    }

    // MARK: Building blocks

    private static var year: Int { Calendar.current.component(.year, from: now) }

    /// 2× from the most recent Saturday 00:00 to Monday 00:00 before "now".
    private static var weekendBonus: BonusInfo {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday = cal.component(.weekday, from: today)   // 1 = Sunday … 7 = Saturday
        let back = (weekday - 7 + 7) % 7
        let saturday = cal.date(byAdding: .day, value: back == 0 ? -7 : -back, to: today) ?? today
        let monday = cal.date(byAdding: .day, value: 2, to: saturday) ?? saturday
        return BonusInfo(id: "bonus-demo-weekend", multiplier: 2, startsAt: saturday, endsAt: monday,
                         note: "Double points weekend!", at: saturday.addingTimeInterval(-6 * 3600),
                         byParent: "Dad")
    }

    private static let pcApps: [DetectedApp] = [
        DetectedApp(exe: "javaw.exe", name: "Minecraft"),
        DetectedApp(exe: "robloxplayerbeta.exe", name: "Roblox"),
        DetectedApp(exe: "fortniteclient-win64-shipping.exe", name: "Fortnite"),
        DetectedApp(exe: "rocketleague.exe", name: "Rocket League"),
        DetectedApp(exe: "steam.exe", name: "Steam"),
        DetectedApp(exe: "chrome.exe", name: "Google Chrome"),
        DetectedApp(exe: "winword.exe", name: "Microsoft Word"),
        DetectedApp(exe: "ms-teams.exe", name: "Microsoft Teams"),
        DetectedApp(exe: "spotify.exe", name: "Spotify"),
    ]

    private static func at(daysAgo: Int, hour: Int, minute: Int) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: now)) ?? now
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func session(id: String, daysAgo: Int, type: ActivityType, hour: Int, minute: Int,
                                total: Int, qualifying: Int, rules: Rules,
                                rng: inout SeededRandom) -> SessionInfo {
        let start = at(daysAgo: daysAgo, hour: hour, minute: minute)
        // Qualifying minutes in the middle, warm-up and cool-down either side.
        let warmUp = max(0, (total - qualifying) / 2)
        let minutes: [MinuteResult] = (0..<total).map { i in
            let good = i >= warmUp && i < warmUp + qualifying
            let hr = good ? 126 + rng.next(14) : 98 + rng.next(18)
            let cad: Double? = type == .walk ? Double(good ? 110 + rng.next(14) : 84 + rng.next(14)) : nil
            return MinuteResult(p: good ? 10 + rng.next(3) : rng.next(8), t: 12, hr: Double(hr), cad: cad)
        }
        return SessionInfo(id: id, activityType: type, startedAt: start,
                           endedAt: start.addingTimeInterval(Double(total) * 60),
                           minutes: minutes, qualifyingMinutes: qualifying,
                           earnedMinutes: qualifying * rules.ratio, rulesSnapshot: rules, deviceId: "demo-watch")
    }

    /// One `Spend` per minute of play on the PC, as the Windows app writes them.
    private static func play(daysAgo: Int, hour: Int, minute: Int, minutes: Int, apps: [String]) -> [SpendInfo] {
        guard minutes > 0 else { return [] }
        let start = at(daysAgo: daysAgo, hour: hour, minute: minute)
        return (0..<minutes).map { i in
            let t = start.addingTimeInterval(Double(i) * 60)
            return SpendInfo(id: "spend-demo-\(daysAgo)-\(hour)-\(minute)-\(i)", minutes: 1, at: t,
                             deviceId: pcDeviceId, app: apps[(i / 45) % apps.count])
        }
    }
}

/// Deterministic numbers so the demo looks the same every launch.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }

    /// 0 ..< upperBound
    mutating func next(_ upperBound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(max(1, upperBound)))
    }
}

// MARK: - In-memory snapshots

extension FamilySnapshot {
    init(zone: ZoneRef, child: ChildInfo, rules: Rules, adjustments: [AdjustmentEntry] = [],
         overrides: [SessionOverrideInfo] = [], bonuses: [BonusInfo] = [], rulesChanges: [RulesChangeInfo] = [],
         parents: [ParentInfo] = [], allowLists: [AllowListInfo] = []) {
        self.zone = zone
        self.child = child
        self.rules = rules
        self.rulesRecord = nil
        self.adjustments = adjustments
        self.overrides = overrides
        self.bonuses = bonuses
        self.rulesChanges = rulesChanges
        self.parents = parents
        self.allowLists = allowLists
    }
}

extension ActivitySnapshot {
    init(zone: ZoneRef, sessions: [SessionInfo], spends: [SpendInfo], devices: [DeviceInfo]) {
        self.zone = zone
        self.sessions = sessions
        self.spends = spends
        self.devices = devices
    }
}
#endif
