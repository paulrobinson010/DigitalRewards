import RewardsCore
import SwiftUI

/// A play window with a stable id for editing in a list.
struct EditableWindow: Identifiable, Hashable {
    var id = UUID()
    var window: PlayWindow

    var isValid: Bool {
        guard let s = window.startMinutes, let e = window.endMinutes else { return false }
        return !window.days.isEmpty && s < e
    }
}

struct RulesEditorView: View {
    let childId: String
    @Environment(ParentModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var draft: Rules?
    @State var windows: [EditableWindow] = []
    @State var note = ""
    @State var isSaving = false
    @State var error: String?
    @State var conflict: RulesConflict?

    var body: some View {
        Group {
            if let entry = model.entry(childId), draft != nil {
                form(entry)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Rules")
        .onAppear { load(force: false) }
        .alert("\(conflict?.updatedBy ?? "Another parent") changed the rules",
               isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }),
               presenting: conflict) { c in
            Button("Use their rules") {
                conflict = nil
                Task { await model.refresh(); load(force: true) }
            }
            Button("Save mine anyway", role: .destructive) {
                conflict = nil
                Task { await save(base: c) }
            }
        } message: { c in
            Text("Their version differs from yours: \(RulesDiff.summary(from: c.theirRules, to: currentRules ?? c.theirRules))")
        }
    }

    private var currentRules: Rules? {
        guard var r = draft else { return nil }
        let valid = windows.map(\.window)
        r.playWindows = valid.isEmpty ? nil : valid
        r.walkHrPct = round2(r.walkHrPct)
        r.otherHrPct = round2(r.otherHrPct)
        r.qualifyFraction = round2(r.qualifyFraction)
        return r
    }

    private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    private func load(force: Bool) {
        guard force || draft == nil, let entry = model.entry(childId) else { return }
        draft = entry.family.rules
        windows = (entry.family.rules.playWindows ?? []).map { EditableWindow(window: $0) }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Rules, T>) -> Binding<T> {
        Binding(get: { draft![keyPath: keyPath] }, set: { draft![keyPath: keyPath] = $0 })
    }

    private func optionalBinding(_ keyPath: WritableKeyPath<Rules, Int?>, default value: Int) -> (on: Binding<Bool>, value: Binding<Int>) {
        (Binding(get: { draft![keyPath: keyPath] != nil }, set: { draft![keyPath: keyPath] = $0 ? value : nil }),
         Binding(get: { draft![keyPath: keyPath] ?? value }, set: { draft![keyPath: keyPath] = $0 }))
    }

    private func form(_ entry: ChildEntry) -> some View {
        let rules = draft!
        let child = entry.family.child
        let year = Calendar.current.component(.year, from: Date())
        let maxHr = Qualification.maxHeartRate(birthYear: child.birthYear, atYear: year)
        let walkBpm = Qualification.hrThresholdBpm(pct: rules.walkHrPct, birthYear: child.birthYear, atYear: year)
        let otherBpm = Qualification.hrThresholdBpm(pct: rules.otherHrPct, birthYear: child.birthYear, atYear: year)
        let bank = optionalBinding(\.maxBank, default: 600)
        let cap = optionalBinding(\.dailyPlayCap, default: 120)
        let changed = currentRules != entry.family.rules
        let windowsValid = windows.allSatisfy(\.isValid)

        return Form {
            Section {
                Stepper("1 active min = \(rules.ratio) gaming min", value: binding(\.ratio), in: 1...60)
            } header: {
                Text("Earning")
            }
            Section {
                Stepper("Step rate ≥ \(rules.walkCadenceSpm)/min", value: binding(\.walkCadenceSpm), in: 60...180, step: 5)
                Stepper("Heart rate ≥ \(pct(rules.walkHrPct)) (\(walkBpm) bpm)", value: binding(\.walkHrPct),
                        in: 0.3...0.9, step: 0.05)
            } header: {
                Text("Walk / run")
            }
            Section {
                Stepper("Heart rate ≥ \(pct(rules.otherHrPct)) (\(otherBpm) bpm)", value: binding(\.otherHrPct),
                        in: 0.3...0.95, step: 0.05)
            } header: {
                Text("Cycling and other workouts")
            } footer: {
                Text("Estimated max heart rate for \(child.name): \(maxHr) bpm (220 − age).")
            }
            Section {
                Stepper("\(pct(rules.qualifyFraction)) of each minute", value: binding(\.qualifyFraction),
                        in: 0.5...1.0, step: 0.05)
            } header: {
                Text("A minute counts when above the bar for")
            }
            Section("Balance") {
                Stepper("Debit allowed: \(Fmt.minutes(rules.debitLimit))", value: binding(\.debitLimit),
                        in: 0...600, step: 15)
                Toggle("Limit saved-up minutes", isOn: bank.on)
                if rules.maxBank != nil {
                    Stepper("Max balance: \(Fmt.minutes(bank.value.wrappedValue))", value: bank.value,
                            in: 30...6000, step: 30)
                }
            }
            Section("Play time") {
                Toggle("Daily play limit", isOn: cap.on)
                if rules.dailyPlayCap != nil {
                    Stepper("Up to \(Fmt.minutes(cap.value.wrappedValue)) a day", value: cap.value,
                            in: 15...720, step: 15)
                }
                PlayWindowsEditor(windows: $windows)
            }
            Section("Why are you changing this?") {
                RequiredNoteField(note: $note)
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.magenta) }
            }
            Section {
                Button {
                    Task { await save(base: nil) }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save rules") }
                }
                .disabled(!changed || !windowsValid || note.trimmed.isEmpty || isSaving)
            } footer: {
                if changed, let rules = currentRules {
                    Text(RulesDiff.summary(from: entry.family.rules, to: rules))
                }
            }
        }
        .themedList()
    }

    private func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    private func save(base: RulesConflict?) async {
        guard let me = model.profile, let entry = model.entry(childId), let rules = currentRules else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await FamilyService.saveRules(rules, note: note, family: entry.family, me: me, base: base?.serverRecord)
            await model.refresh()
            dismiss()
        } catch let c as RulesConflict {
            conflict = c
        } catch {
            self.error = error.userMessage
        }
    }
}

struct PlayWindowsEditor: View {
    @Binding var windows: [EditableWindow]

    private static let times: [String] = stride(from: 0, through: 1440, by: 30).map { PlayWindow.format(minutes: $0) }
    private static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        if windows.isEmpty {
            Text("No play windows: play is allowed any time there are minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        ForEach($windows) { $item in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    ForEach(1...7, id: \.self) { day in
                        let on = item.window.days.contains(day)
                        Button(Self.dayLetters[day - 1]) {
                            if on {
                                item.window.days.removeAll { $0 == day }
                            } else {
                                item.window.days = (item.window.days + [day]).sorted()
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(on ? .accentColor : .gray)
                        .font(.caption.bold())
                    }
                }
                HStack {
                    Picker("From", selection: $item.window.start) {
                        ForEach(Self.times.dropLast(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("To", selection: $item.window.end) {
                        ForEach(Self.times.dropFirst(), id: \.self) { Text($0).tag($0) }
                    }
                }
                if !item.isValid {
                    Text("Pick at least one day and an end time after the start.")
                        .font(.caption).foregroundStyle(Theme.magenta)
                }
            }
            .buttonStyle(.borderless)
        }
        .onDelete { windows.remove(atOffsets: $0) }
        Button("Add play window", systemImage: "plus") {
            windows.append(EditableWindow(window: PlayWindow(days: [1, 2, 3, 4, 5], start: "16:00", end: "20:00")))
        }
    }
}
