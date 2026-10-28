import SwiftUI

struct ChildDetailView: View {
    let childId: String
    @Environment(ParentModel.self) var model
    @State var showAdjust = false
    @State var overrideTarget: ResolvedSession?
    @State var newCode: String?
    @State var error: String?

    var body: some View {
        if let entry = model.entry(childId) {
            content(entry)
        } else {
            ContentUnavailableView("Child not found", systemImage: "person.crop.circle.badge.questionmark")
        }
    }

    private func content(_ entry: ChildEntry) -> some View {
        List {
            Section {
                BalanceCard(state: entry.state)
                TodayStrip(state: entry.state)
            }
            if !entry.hasActivity {
                Section {
                    Text("\(entry.state.name) hasn't joined yet, or their iPhone hasn't shared their activity with you. Pull to refresh after they join.")
                        .font(.footnote)
                    Button("New invite code for \(entry.state.name)") {
                        Task { await makeCode(entry) }
                    }
                }
            }
            Section {
                Button("Add or remove minutes", systemImage: "plusminus.circle") { showAdjust = true }
                NavigationLink {
                    RulesEditorView(childId: childId)
                } label: {
                    Label("Rules", systemImage: "slider.horizontal.3")
                }
                NavigationLink {
                    BonusesView(childId: childId)
                } label: {
                    Label("Bonuses", systemImage: "sparkles")
                }
                NavigationLink {
                    DevicesView(childId: childId)
                } label: {
                    Label("Devices", systemImage: "desktopcomputer")
                }
                NavigationLink {
                    AlertPrefsView(childId: childId)
                } label: {
                    Label("Alerts", systemImage: "bell")
                }
                if entry.family.zone.scope == .sharedDB {
                    NavigationLink {
                        TakeOverView(childId: childId)
                    } label: {
                        Label("Take over child", systemImage: "arrow.down.doc")
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            Section {
                ForEach(HistoryBuilder.items(for: entry.state)) { item in
                    if case .workout(let resolved) = item.kind {
                        Button { overrideTarget = resolved } label: { HistoryRow(item: item) }
                            .buttonStyle(.plain)
                    } else {
                        HistoryRow(item: item)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Tap a workout to change or void its minutes.")
            }
        }
        .navigationTitle(entry.state.name)
        .refreshable { await model.refresh() }
        .sheet(isPresented: $showAdjust) {
            NavigationStack { AdjustmentView(childId: childId) }
        }
        .sheet(item: $overrideTarget) { resolved in
            NavigationStack { SessionOverrideView(childId: childId, resolved: resolved) }
        }
        .sheet(isPresented: Binding(get: { newCode != nil }, set: { if !$0 { newCode = nil } })) {
            NavigationStack {
                InviteCodeView(code: newCode ?? "",
                               message: "On \(entry.state.name)'s iPhone, open DigitalRewards, choose \"I'm a child\" and enter:")
            }
        }
    }

    private func makeCode(_ entry: ChildEntry) async {
        do {
            newCode = try await FamilyService.newChildInvite(family: entry.family)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AdjustmentView: View {
    let childId: String
    @Environment(ParentModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var minutes = 30
    @State var note = ""
    @State var isSaving = false
    @State var error: String?

    private let presets = [-60, -30, -15, 15, 30, 60]

    var body: some View {
        Form {
            Section {
                HStack {
                    ForEach(presets, id: \.self) { p in
                        Button(p > 0 ? "+\(p)" : "\(p)") { minutes = p }
                            .buttonStyle(.bordered)
                            .tint(p > 0 ? .green : .red)
                            .font(.caption)
                    }
                }
                Stepper(value: $minutes, in: -600...600, step: 5) {
                    Text(Fmt.signed(minutes))
                        .font(.title3.bold())
                        .foregroundStyle(minutes >= 0 ? Color.green : Color.red)
                }
            }
            Section("Why?") {
                RequiredNoteField(note: $note)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add or remove minutes")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(minutes == 0 || note.trimmed.isEmpty || isSaving)
            }
        }
    }

    private func save() async {
        guard let me = model.profile, let entry = model.entry(childId) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await FamilyService.addAdjustment(minutes: minutes, note: note, family: entry.family, me: me)
            await model.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct SessionOverrideView: View {
    let childId: String
    let resolved: ResolvedSession
    @Environment(ParentModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var minutes: Int
    @State var note: String
    @State var isSaving = false
    @State var error: String?

    init(childId: String, resolved: ResolvedSession) {
        self.childId = childId
        self.resolved = resolved
        _minutes = State(initialValue: resolved.earnMinutes)
        _note = State(initialValue: resolved.sessionOverride?.note ?? "")
    }

    var body: some View {
        let s = resolved.session
        Form {
            Section("Workout") {
                LabeledContent("Activity", value: s.activityType.title)
                LabeledContent("When", value: s.startedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Above the bar", value: "\(s.qualifyingMinutes) of \(s.minutes.count) min")
                LabeledContent("Earned (original)", value: Fmt.minutes(resolved.originalMinutes))
                if let bonus = resolved.bonus { LabeledContent("Bonus", value: bonus.label) }
                if let reason = AlertMonitor.suspicionReason(s, among: model.entry(childId)?.state.activity?.sessions ?? []) {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Section {
                Stepper(value: $minutes, in: 0...2000, step: 5) {
                    Text(minutes == 0 ? "Void (0 min)" : Fmt.minutes(minutes)).font(.title3.bold())
                }
                Button("Void this workout", role: .destructive) { minutes = 0 }
            } header: {
                Text("Counts as")
            } footer: {
                Text("Bonuses don't apply on top of an edited value.")
            }
            Section("Why?") {
                RequiredNoteField(note: $note)
            }
            if resolved.sessionOverride != nil {
                Section {
                    Button("Remove edit (restore original)") { Task { await removeOverride() } }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Edit workout")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(note.trimmed.isEmpty || isSaving)
            }
        }
    }

    private func save() async {
        guard let me = model.profile, let entry = model.entry(childId) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await FamilyService.saveOverride(sessionId: resolved.session.id, minutes: minutes, note: note,
                                                 family: entry.family, me: me)
            await model.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeOverride() async {
        guard let entry = model.entry(childId) else { return }
        do {
            try await FamilyService.removeOverride(sessionId: resolved.session.id, family: entry.family)
            await model.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
