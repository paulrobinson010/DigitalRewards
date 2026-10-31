import SwiftUI

struct ChildRootView: View {
    @Environment(ChildModel.self) private var model

    var body: some View {
        NavigationStack {
            switch model.phase {
            case .loading:
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ThemeBackground())
                    .task { await model.refresh() }
            case .needsJoin:
                ChildJoinView()
            case .ready:
                ChildHomeView()
            }
        }
    }
}

struct ChildJoinView: View {
    @Environment(ChildModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isJoining = false
    @State private var error: String?
    /// True when shown as a sheet from the home screen (re-join after a take-over).
    var isRejoin = false

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    PixelAlien(animated: true)
                        .frame(height: 64)
                    Text("PLAYER 1, GET READY")
                        .font(Theme.label(15))
                        .tracking(2)
                        .foregroundStyle(Theme.cyan)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                Text("Ask a parent to add you in their Go AFK app. They'll get a 6-digit code.")
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .monospaced))
            }
            if let error = error ?? model.errorMessage {
                Section { Text(error).foregroundStyle(Theme.magenta) }
            }
            Section {
                Button {
                    Task { await join() }
                } label: {
                    if isJoining { ProgressView() } else { Text("Join family") }
                }
                .disabled(code.filter(\.isNumber).count != 6 || isJoining)
            }
            if !isRejoin {
                Section {
                    SwitchModeButton()
                    #if DEBUG
                    ScreenshotModeButton()
                    #endif
                }
            }
        }
        .themedList()
        .navigationTitle("Join your family")
    }

    private func join() async {
        isJoining = true
        defer { isJoining = false }
        do {
            try await model.join(code: code)
            error = nil
            if isRejoin { dismiss() }
        } catch {
            self.error = error.userMessage
        }
    }
}

struct ChildHomeView: View {
    @Environment(ChildModel.self) private var model
    @State private var showRejoin = false
    @State private var celebration: Celebration?
    @State private var celebrationCount = 0
    /// Screenshot mode: show this celebration frozen instead of checking for new workouts.
    var frozenCelebration: Celebration?

    private static let historyPreviewCount = 5

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let state = model.state {
                    PlayerHeader(name: state.name)
                    HStack(spacing: 16) {
                        Mascot(mood: state.mascotMood)
                            .frame(width: 130, height: 100)
                            .frame(maxWidth: .infinity)
                        TodayRing(state: state)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 6)
                    CreditsCounter(state: state)
                    ArcadeBanner(state: state)
                    PlayerStatsCard(state: state)
                    historySection(state)
                }
                if let error = model.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(Theme.magenta)
                }
            }
            .padding()
        }
        .background(ThemeBackground())
        .overlay {
            if let shown = frozenCelebration ?? celebration {
                CelebrationOverlay(celebration: shown, frozen: frozenCelebration != nil)
                    .transition(.opacity)
            }
        }
        .sensoryFeedback(.success, trigger: celebrationCount)
        .navigationTitle("Go AFK")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .task { checkForNewWorkouts() }
        .onChange(of: newestWorkoutEnd) { _, _ in checkForNewWorkouts() }
        .toolbar {
            Menu {
                Button("Join with a new code", systemImage: "number") { showRejoin = true }
                SwitchModeButton()
                #if DEBUG
                ScreenshotModeButton()
                #endif
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $showRejoin) {
            NavigationStack { ChildJoinView(isRejoin: true) }
        }
    }

    @ViewBuilder
    private func historySection(_ state: ChildState) -> some View {
        let history = model.history
        VStack(alignment: .leading, spacing: 10) {
            Text("HISTORY")
                .font(Theme.label(13))
                .tracking(4)
                .foregroundStyle(Theme.cyan)
            if history.isEmpty {
                Text("No games yet. Start a workout on your Apple Watch to earn credits!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .neonCard(border: Theme.cyan.opacity(0.4))
            }
            ForEach(history.prefix(Self.historyPreviewCount)) { item in
                HistoryRow(item: item, arcade: true)
                    .neonCard(border: Theme.cyan.opacity(0.35), padding: 12)
            }
            if history.count > Self.historyPreviewCount {
                NavigationLink {
                    ChildHistoryView()
                } label: {
                    Text("ALL HISTORY")
                }
                .buttonStyle(NeonButtonStyle(color: Theme.cyan))
            }
        }
    }

    private var newestWorkoutEnd: Date? {
        model.state?.resolved.filter { !$0.isVoided }.map(\.session.endedAt).max()
    }

    /// Celebrates workouts that ended since this device last showed the child's screen.
    private func checkForNewWorkouts() {
        #if DEBUG
        if ScreenshotMode.isOn { return }
        #endif
        guard frozenCelebration == nil, let state = model.state, let newest = newestWorkoutEnd else { return }
        let key = "dr.arcade.lastSeenWorkout.\(state.childId)"
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else {
            // First time on this device: start from now, don't celebrate old workouts.
            defaults.set(newest.timeIntervalSince1970, forKey: key)
            return
        }
        let lastSeen = Date(timeIntervalSince1970: defaults.double(forKey: key))
        let fresh = state.resolved.filter { !$0.isVoided && $0.session.endedAt > lastSeen }
        guard !fresh.isEmpty else { return }
        defaults.set(newest.timeIntervalSince1970, forKey: key)
        let credits = fresh.reduce(0) { $0 + $1.earnMinutes }
        guard credits > 0 else { return }
        withAnimation { celebration = Celebration(credits: credits) }
        celebrationCount += 1
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation { celebration = nil }
        }
    }
}

/// Every history item, arcade style.
struct ChildHistoryView: View {
    @Environment(ChildModel.self) private var model

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(model.history) { item in
                    HistoryRow(item: item, arcade: true)
                        .neonCard(border: Theme.cyan.opacity(0.35), padding: 12)
                }
            }
            .padding()
        }
        .background(ThemeBackground())
        .navigationTitle("History")
        .refreshable { await model.refresh() }
    }
}
