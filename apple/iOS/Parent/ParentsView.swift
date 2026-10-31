import SwiftUI

struct ParentsView: View {
    @Environment(ParentModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false
    @State private var showJoin = false
    @State private var removing: ParentInfo?
    @State private var message: String?

    var body: some View {
        List {
            Section {
                ForEach(model.allParents) { parent in
                    VStack(alignment: .leading) {
                        Text(parent.displayName + (isMe(parent) ? " (you)" : ""))
                        Text([parent.lookupEmail, parent.lookupPhone].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if parent.recordName.hasPrefix("parent-invite-") {
                            Text("Invited – hasn't joined yet").font(.caption).foregroundStyle(Theme.yellow)
                        }
                    }
                    .swipeActions {
                        if !isMe(parent) {
                            Button("Remove", role: .destructive) { removing = parent }
                        }
                    }
                }
            } footer: {
                Text("All parents can change rules, add or remove minutes and invite others.")
            }
            Section {
                Button("Invite a parent", systemImage: "person.badge.plus") { showInvite = true }
                    .disabled(model.children.isEmpty)
                Button("Join a family with a code", systemImage: "number") { showJoin = true }
            }
            if let message {
                Section { Text(message).font(.footnote) }
            }
        }
        .themedList()
        .navigationTitle("Parents")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .confirmationDialog("Remove \(removing?.displayName ?? "")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove from all children", role: .destructive) {
                if let parent = removing { Task { await remove(parent) } }
            }
        }
        .sheet(isPresented: $showInvite) {
            NavigationStack { InviteParentView() }
        }
        .sheet(isPresented: $showJoin) {
            NavigationStack { JoinParentView() }
        }
    }

    private func isMe(_ parent: ParentInfo) -> Bool {
        guard let me = model.profile else { return false }
        return parent.recordName == me.parentInfo.recordName
    }

    private func remove(_ parent: ParentInfo) async {
        let skipped = await FamilyService.removeParent(parent, families: model.families)
        message = skipped.isEmpty ? "\(parent.displayName) was removed."
            : "Couldn't remove \(parent.displayName) from: \(skipped.joined(separator: ", ")). Ask the parent who added those children."
        removing = nil
        await model.refresh()
    }
}

struct InviteParentView: View {
    @Environment(ParentModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var result: (code: String, skipped: [String])?

    var body: some View {
        if let result {
            InviteCodeView(code: result.code,
                           message: "On \(name)'s iPhone, open DigitalRewards, choose \"I'm a parent\", set up, then Parents › Join a family with a code:",
                           notes: result.skipped.isEmpty ? []
                               : ["Not shared: \(result.skipped.joined(separator: ", ")). Ask the parent who added them to invite \(name)."])
        } else {
            Form {
                Section {
                    TextField("Their name (e.g. Dad, Grandma)", text: $name)
                }
                Section {
                    TextField("Apple ID email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("or phone number", text: $phone)
                        .keyboardType(.phonePad)
                } header: {
                    Text("Their Apple ID")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.magenta) }
                }
            }
            .themedList()
            .navigationTitle("Invite a parent")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("Invite") { Task { await invite() } }
                            .disabled(name.trimmed.isEmpty || (email.trimmed.isEmpty && phone.trimmed.isEmpty))
                    }
                }
            }
        }
    }

    private func invite() async {
        isWorking = true
        defer { isWorking = false }
        do {
            result = try await FamilyService.inviteParent(name: name.trimmed,
                                                          email: email.trimmed.isEmpty ? nil : email,
                                                          phone: phone.trimmed.isEmpty ? nil : phone,
                                                          families: model.families)
            await model.refresh()
        } catch {
            self.error = error.userMessage
        }
    }
}

struct JoinParentView: View {
    @Environment(ParentModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Enter the code another parent gave you.")
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .font(.system(.title, design: .monospaced))
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.magenta) }
            }
            Section {
                Button {
                    Task { await join() }
                } label: {
                    if isWorking { ProgressView() } else { Text("Join") }
                }
                .disabled(code.filter(\.isNumber).count != 6 || isWorking)
            }
        }
        .themedList()
        .navigationTitle("Join a family")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
    }

    private func join() async {
        guard let me = model.profile else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await FamilyService.joinAsParent(code: code, me: me)
            await model.refresh()
            dismiss()
        } catch {
            self.error = error.userMessage
        }
    }
}
