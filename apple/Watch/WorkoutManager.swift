import CoreMotion
import Foundation
import HealthKit
import Observation
import RewardsCore
import WatchKit

/// Runs a workout, samples heart rate and cadence every 5 s of active time and
/// counts qualifying minutes (docs/CONTRACT.md §2).
@MainActor
@Observable
final class WorkoutManager: NSObject {
    enum Phase {
        case idle, running, paused, ending, finished
    }

    private(set) var phase: Phase = .idle
    private(set) var activity: ActivityType = .walk
    private(set) var heartRate: Double?
    private(set) var cadence: Double?
    private(set) var aboveBar = false
    private(set) var qualifyingMinutes = 0
    private(set) var completedMinutes = 0
    private(set) var ticksInMinute = 0
    private(set) var rules: Rules = .defaults
    private(set) var birthYear = 2015
    /// Display only: the largest active bonus when the workout started.
    private(set) var bonusMultiplier: Double = 1.0
    private(set) var lastSession: SessionInfo?
    var errorMessage: String?

    private let healthStore = HKHealthStore()
    private let pedometer = CMPedometer()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var accumulator = MinuteAccumulator(samplesPerMinute: AppConfig.samplesPerMinute)
    private var samplerTask: Task<Void, Never>?
    private var startDate: Date?
    private var heartRateAt: Date?
    private var cadenceAt: Date?
    private var sessionUUID = UUID()
    /// Screenshot mode's demo workout: when it "started" (no HealthKit session).
    private var demoStart: Date?

    /// Readings older than this don't count (e.g. watch off the wrist, standing still).
    private let staleAfter: TimeInterval = 15

    // MARK: Derived values

    /// Base minutes earned (what is saved in the Session).
    var earnedMinutes: Int { qualifyingMinutes * rules.ratio }

    /// Minutes shown to the child, including any bonus.
    var displayedMinutes: Int {
        Qualification.roundHalfAwayFromZero(Double(earnedMinutes) * bonusMultiplier)
    }

    var currentYear: Int { Calendar.current.component(.year, from: Date()) }

    var thresholdBpm: Int {
        Qualification.hrThresholdBpm(rules: rules, activity: activity, birthYear: birthYear, atYear: currentYear)
    }

    var elapsed: TimeInterval {
        if let builder { return builder.elapsedTime }
        return demoStart.map { Date().timeIntervalSince($0) } ?? 0
    }

    // MARK: Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType(),
        ]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: read)
        } catch {
            errorMessage = error.userMessage
        }
    }

    // MARK: Control

    func start(_ activity: ActivityType, context: WatchContext?) async {
        guard phase == .idle else { return }
        self.activity = activity
        rules = context?.rules ?? .defaults
        birthYear = context?.birthYear ?? birthYear
        bonusMultiplier = context?.activeBonus(at: Date())?.multiplier ?? 1.0
        resetCounters()

        let config = HKWorkoutConfiguration()
        switch activity {
        case .walk:
            config.activityType = .walking
            config.locationType = .outdoor
        case .cycle:
            config.activityType = .cycling
            config.locationType = .outdoor
        case .other:
            config.activityType = .other
            config.locationType = .unknown
        }

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder

            let start = Date()
            startDate = start
            session.startActivity(with: start)
            try await builder.beginCollection(at: start)
            phase = .running
            startPedometer()
            startSampler()
        } catch {
            errorMessage = error.userMessage
            session = nil
            builder = nil
            phase = .idle
        }
    }

    func pause() {
        guard phase == .running else { return }
        session?.pause()
        setPaused(true)
    }

    func resume() {
        guard phase == .paused else { return }
        session?.resume()
        setPaused(false)
    }

    func end() async {
        guard phase == .running || phase == .paused else { return }
        #if DEBUG
        if demoStart != nil {
            showDemoSummary()
            return
        }
        #endif
        phase = .ending
        samplerTask?.cancel()
        samplerTask = nil
        pedometer.stopUpdates()

        let endDate = Date()
        session?.end()
        do {
            try await builder?.endCollection(at: endDate)
            _ = try await builder?.finishWorkout()
        } catch {
            // The session still counts even if saving to Health fails.
            errorMessage = error.userMessage
        }

        let minutes = accumulator.completed
        let qualifying = Qualification.qualifyingMinutes(rules: rules, minutes: minutes)
        let info = SessionInfo(
            id: SessionInfo.recordName(uuid: sessionUUID),
            activityType: activity,
            startedAt: startDate ?? endDate,
            endedAt: endDate,
            minutes: minutes,
            qualifyingMinutes: qualifying,
            earnedMinutes: qualifying * rules.ratio,
            rulesSnapshot: rules,
            deviceId: DeviceIdentity.id
        )
        lastSession = info
        if !minutes.isEmpty {
            SessionUploader.shared.enqueue(info)
        }
        session = nil
        builder = nil
        phase = .finished
    }

    /// Back to the start screen after the summary.
    func reset() {
        demoStart = nil
        lastSession = nil
        resetCounters()
        phase = .idle
    }

    // MARK: Internals

    private func resetCounters() {
        accumulator = MinuteAccumulator(samplesPerMinute: AppConfig.samplesPerMinute)
        qualifyingMinutes = 0
        completedMinutes = 0
        ticksInMinute = 0
        aboveBar = false
        heartRate = nil
        cadence = nil
        heartRateAt = nil
        cadenceAt = nil
        sessionUUID = UUID()
    }

    private func setPaused(_ paused: Bool) {
        if paused {
            samplerTask?.cancel()
            samplerTask = nil
            aboveBar = false
            phase = .paused
        } else {
            phase = .running
            startSampler()
        }
    }

    private func startPedometer() {
        guard activity == .walk, CMPedometer.isCadenceAvailable() else { return }
        // Delivered on a background queue: hop to the main actor explicitly.
        pedometer.startUpdates(from: Date()) { @Sendable [weak self] data, _ in
            // currentCadence is steps per second.
            let stepsPerMinute = data?.currentCadence.map { $0.doubleValue * 60 }
            Task { @MainActor [weak self] in
                self?.updateCadence(stepsPerMinute)
            }
        }
    }

    private func startSampler() {
        samplerTask?.cancel()
        let interval = UInt64(AppConfig.sampleInterval * 1_000_000_000)
        samplerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { return }
                self?.tick()
            }
        }
    }

    private func tick() {
        guard phase == .running else { return }
        let now = Date()
        let hr = heartRateAt.map { now.timeIntervalSince($0) <= staleAfter } == true ? heartRate : nil
        let cad = cadenceAt.map { now.timeIntervalSince($0) <= staleAfter } == true ? cadence : nil
        let passes = Qualification.samplePasses(rules: rules, activity: activity, birthYear: birthYear,
                                                atYear: currentYear, hr: hr.map { Int($0.rounded()) }, cadence: cad)
        aboveBar = passes
        if let minute = accumulator.add(passed: passes, hr: hr, cadence: cad) {
            completedMinutes += 1
            if Qualification.minuteQualifies(rules: rules, passed: minute.p, total: minute.t) {
                qualifyingMinutes += 1
                WKInterfaceDevice.current().play(.success)
            }
        }
        ticksInMinute = accumulator.ticksInCurrentMinute
    }

    private func updateHeartRate(_ bpm: Double?) {
        guard let bpm else { return }
        heartRate = bpm
        heartRateAt = Date()
    }

    private func updateCadence(_ spm: Double?) {
        guard let spm else { return }
        cadence = spm
        cadenceAt = Date()
    }

    private func sessionStateChanged(_ state: HKWorkoutSessionState) {
        // Keep the UI in step if the system pauses/resumes (e.g. auto-pause or water lock).
        switch state {
        case .paused where phase == .running: setPaused(true)
        case .running where phase == .paused: setPaused(false)
        default: break
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.sessionStateChanged(toState) }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.userMessage
        Task { @MainActor in self.errorMessage = message }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType) else { return }
        let bpm = workoutBuilder.statistics(for: hrType)?
            .mostRecentQuantity()?
            .doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        Task { @MainActor in self.updateHeartRate(bpm) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

#if DEBUG
// MARK: - Screenshot mode

extension WorkoutManager {
    /// A live-looking brisk walk with a 2× bonus, without HealthKit: HR 132, cadence 118,
    /// above the bar, 6 qualifying minutes (120 game minutes with the bonus).
    func startDemo() {
        guard phase == .idle else { return }
        activity = .walk
        rules = .defaults
        birthYear = Calendar.current.component(.year, from: Date()) - 12
        bonusMultiplier = 2
        resetCounters()
        heartRate = 132
        cadence = 118
        aboveBar = true
        qualifyingMinutes = 6
        completedMinutes = 7
        ticksInMinute = 8
        demoStart = Date().addingTimeInterval(-(7 * 60 + 40))
        phase = .running
    }

    /// The summary screen for the demo walk. Nothing is uploaded.
    func showDemoSummary() {
        if phase == .idle { startDemo() }
        let end = Date()
        let good = MinuteResult(p: 12, t: 12, hr: 132, cad: 118)
        lastSession = SessionInfo(
            id: "session-demo", activityType: .walk,
            startedAt: demoStart ?? end.addingTimeInterval(-480), endedAt: end,
            minutes: Array(repeating: good, count: 6) + [MinuteResult(p: 7, t: 12, hr: 121, cad: 101)],
            qualifyingMinutes: 6, earnedMinutes: 6 * rules.ratio, rulesSnapshot: rules, deviceId: "demo")
        phase = .finished
    }
}
#endif
