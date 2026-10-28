import SwiftUI

struct ChildRootView: View {
    @Environment(ChildModel.self) private var model

    var body: some View {
        NavigationStack {
            switch model.phase {
            case .loading:
                ProgressView("Loading…")
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
                Text("Ask a parent to add you in their DigitalRewards app. They'll get a 6-digit code.")
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .monospaced))
            }
            if let error = error ?? model.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
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
                Section { SwitchModeButton() }
            }
        }
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
            self.error = error.localizedDescription
        }
    }
}

struct ChildHomeView: View {
    @Environment(ChildModel.self) private var model
    @State private var showRejoin = false

    var body: some View {
        List {
            if let state = model.state {
                Section {
                    BalanceCard(state: state)
                    TodayStrip(state: state)
                }
                Section("History") {
                    if model.history.isEmpty {
                        Text("No activity yet. Start a workout on your Apple Watch!")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.history) { item in
                        HistoryRow(item: item)
                    }
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .navigationTitle(model.state.map { "Hi \($0.name)" } ?? "DigitalRewards")
        .refreshable { await model.refresh() }
        .toolbar {
            Menu {
                Button("Join with a new code", systemImage: "number") { showRejoin = true }
                SwitchModeButton()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $showRejoin) {
            NavigationStack { ChildJoinView(isRejoin: true) }
        }
    }
}
