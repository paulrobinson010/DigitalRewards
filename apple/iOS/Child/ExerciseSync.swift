import CloudKit
import Foundation
import HealthKit
import Observation
import RewardsCore
import SwiftUI

/// Earning from Apple Exercise minutes (docs/CONTRACT.md §2a): reads HealthKit's
/// `appleExerciseTime` on the child's iPhone and writes one `session-exm-<yyyyMMddHH>` Session
/// per UTC hour into the child's Activity zone.
///
/// Runs after every Child-mode refresh (launch, foreground, pull to refresh, silent push,
/// background app refresh) and when HealthKit wakes the app through background delivery.
@MainActor
@Observable
final class ExerciseSync {
    static let shared = ExerciseSync()

    private static let askedKey = "dr.exercise.askedHealth"
    /// How far back to look; anything older was either uploaded already or predates the switch.
    private static let lookBack: TimeInterval = 7 * 24 * 3600

    @ObservationIgnored private let health = HKHealthStore()
    @ObservationIgnored private let exerciseType = HKQuantityType(.appleExerciseTime)
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var running = false

    /// iOS never says whether read access was granted, only whether we've asked.
    private(set) var hasAsked = UserDefaults.standard.bool(forKey: ExerciseSync.askedKey)

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization() async throws {
        try await health.requestAuthorization(toShare: [], read: [exerciseType])
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        hasAsked = true
        startObserving()
    }

    /// Registers for HealthKit background delivery. Call at launch in Child mode: HealthKit only
    /// wakes the app for observer queries that are set up again on every launch.
    func startObserving() {
        guard !observing, isAvailable, hasAsked else { return }
        observing = true
        let query = HKObserverQuery(sampleType: exerciseType, predicate: nil) { _, completion, error in
            guard error == nil else {
                completion()
                return
            }
            Task { @MainActor in
                await AppServices.shared.refresh()   // Child refresh runs sync(_:) below.
                completion()
            }
        }
        health.execute(query)
        health.enableBackgroundDelivery(for: exerciseType, frequency: .hourly) { _, _ in }
    }

    /// Uploads hours whose minutes changed. Returns true if anything was written.
    @discardableResult
    func sync(_ state: ChildState) async -> Bool {
        #if DEBUG
        if ScreenshotMode.isOn { return false }
        #endif
        let rules = state.family.rules
        guard rules.earnSource == .exercise, isAvailable, hasAsked, !running else { return false }
        running = true
        defer { running = false }

        let floor = Date().addingTimeInterval(-Self.lookBack)
        let since = max(rules.earnSourceSince ?? floor, floor)
        guard let samples = try? await fetchSamples(since: since) else { return false }
        let hours = ExerciseHours.buckets(samples, since: since, ratio: rules.ratio)

        // The Activity zone is the record of what's been uploaded (from any of the child's devices),
        // so compare against it rather than a local list.
        let uploaded = Dictionary((state.activity?.sessions ?? []).map { ($0.id, $0.qualifyingMinutes) },
                                  uniquingKeysWith: { a, _ in a })
        let changed = hours.filter { uploaded[$0.recordName] != $0.minutes }
        guard !changed.isEmpty else { return false }

        let zone = ChildLocator.activityZone(for: state.family.zone)
        let records = changed.map { hour in
            SessionInfo(id: hour.recordName, activityType: .exercise,
                        startedAt: hour.hourStart, endedAt: hour.endedAt, minutes: [],
                        qualifyingMinutes: hour.minutes, earnedMinutes: hour.earned,
                        rulesSnapshot: rules, deviceId: DeviceIdentity.id)
                .makeRecord(zoneID: zone.zoneID)
        }
        do {
            try await CloudStore.shared.upsert(records, scope: zone.scope)
            return true
        } catch {
            return false
        }
    }

    /// Exercise minutes measured by an Apple Watch, not typed in by hand.
    private func fetchSamples(since: Date) async throws -> [ExerciseHours.Sample] {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: exerciseType, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let results = try await descriptor.result(for: health)
        return results.compactMap { sample in
            let fromWatch = sample.device?.model == "Watch"
                || (sample.sourceRevision.productType?.hasPrefix("Watch") ?? false)
            let typedIn = (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) ?? false
            guard fromWatch, !typedIn else { return nil }
            return ExerciseHours.Sample(start: sample.startDate, end: sample.endDate,
                                        minutes: sample.quantity.doubleValue(for: .minute()))
        }
    }
}

/// Asks the child to let Go AFK read their exercise minutes. Shown only until they've been asked.
struct HealthConnectCard: View {
    @State private var sync = ExerciseSync.shared
    @Environment(ChildModel.self) private var model
    @State private var error: String?

    var body: some View {
        if sync.isAvailable && !sync.hasAsked {
            VStack(alignment: .leading, spacing: 10) {
                Label("Connect Apple Health to earn from your exercise", systemImage: "heart.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.green)
                Text("Wear your Apple Watch and move: every exercise minute it counts turns into credits. "
                     + "Go AFK only reads your exercise minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Connect Apple Health") {
                    Task {
                        do {
                            try await sync.requestAuthorization()
                            await model.refresh()
                        } catch {
                            self.error = error.userMessage
                        }
                    }
                }
                .buttonStyle(NeonButtonStyle(color: Theme.green))
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.magenta)
                }
            }
            .neonCard(border: Theme.green)
        }
    }
}
