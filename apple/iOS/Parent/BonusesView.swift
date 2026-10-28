import SwiftUI

struct BonusesView: View {
    let childId: String
    @Environment(ParentModel.self) var model
    @State var showAdd = false
    @State var deleting: BonusInfo?
    @State var error: String?

    var body: some View {
        let bonuses = (model.entry(childId)?.family.bonuses ?? []).sorted { $0.startsAt > $1.startsAt }
        List {
            Section {
                if bonuses.isEmpty {
                    Text("No bonuses yet.").foregroundStyle(.secondary)
                }
                ForEach(bonuses) { bonus in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(bonus.label).font(.headline)
                            Spacer()
                            Text(status(bonus)).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(bonus.startsAt.formatted(date: .abbreviated, time: .shortened)) – \(bonus.endsAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                        Text("\(bonus.byParent): \(bonus.note)").font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleting = bonus }
                    }
                }
            } footer: {
                Text("Workouts that start during a bonus earn more. Bonuses don't stack: the biggest one applies. They also count for past workouts in the window.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Bonuses")
        .toolbar {
            Button("Add bonus", systemImage: "plus") { showAdd = true }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack { AddBonusView(childId: childId) }
        }
        .confirmationDialog("Delete \(deleting?.label ?? "bonus")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let bonus = deleting { Task { await delete(bonus) } }
            }
        } message: {
            Text("Workouts in this window go back to normal minutes.")
        }
    }

    private func status(_ b: BonusInfo) -> String {
        let now = Date()
        if b.isActive(at: now) { return "Active" }
        return b.startsAt > now ? "Upcoming" : "Ended"
    }

    private func delete(_ bonus: BonusInfo) async {
        guard let entry = model.entry(childId) else { return }
        do {
            try await FamilyService.deleteBonus(bonus, family: entry.family)
            await model.refresh()
        } catch {
            self.error = error.localizedDescription
        }
        deleting = nil
    }
}

struct AddBonusView: View {
    let childId: String
    @Environment(ParentModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var preset: Double = 2.0
    @State var custom: Double = 1.5
    @State var startsAt = Calendar.current.startOfDay(for: Date())
    @State var endsAt = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date()
    @State var note = ""
    @State var isSaving = false
    @State var error: String?

    /// 0 means "custom".
    private let presets: [Double] = [1.5, 2.0, 3.0, 0]

    private var multiplier: Double { preset == 0 ? (custom * 10).rounded() / 10 : preset }

    var body: some View {
        Form {
            Section("Multiplier") {
                Picker("Multiplier", selection: $preset) {
                    ForEach(presets, id: \.self) { p in
                        Text(p == 0 ? "Custom" : BonusInfo.label(p).replacingOccurrences(of: " bonus", with: "")).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                if preset == 0 {
                    Stepper("\(BonusInfo.label(multiplier))", value: $custom, in: 1.1...5.0, step: 0.1)
                }
            }
            Section("When") {
                DatePicker("Starts", selection: $startsAt)
                DatePicker("Ends", selection: $endsAt, in: startsAt...)
            }
            Section("Why?") {
                RequiredNoteField(note: $note)
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add bonus")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(note.trimmed.isEmpty || endsAt <= startsAt || multiplier <= 1 || isSaving)
            }
        }
    }

    private func save() async {
        guard let me = model.profile, let entry = model.entry(childId) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await FamilyService.addBonus(multiplier: multiplier, startsAt: startsAt, endsAt: endsAt,
                                             note: note, family: entry.family, me: me)
            await model.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
