import SwiftUI

struct AddChildView: View {
    @Environment(ParentModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var birthYear = Calendar.current.component(.year, from: Date()) - 10
    @State private var timeZone = TimeZone.current.identifier
    @State private var email = ""
    @State private var phone = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var code: String?

    private var years: [Int] {
        let now = Calendar.current.component(.year, from: Date())
        return Array((now - 19)...(now - 3)).reversed()
    }

    private var valid: Bool {
        !name.trimmed.isEmpty && TimeZone(identifier: timeZone) != nil
            && !(email.trimmed.isEmpty && phone.trimmed.isEmpty)
    }

    var body: some View {
        if let code {
            InviteCodeView(code: code,
                           message: "On \(name)'s iPhone, open DigitalRewards, choose \"I'm a child\" and enter:")
        } else {
            form
        }
    }

    private var form: some View {
        Form {
            Section("Child") {
                TextField("Name", text: $name)
                Picker("Birth year", selection: $birthYear) {
                    ForEach(years, id: \.self) { Text(String($0)).tag($0) }
                }
                TextField("Time zone", text: $timeZone)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section {
                TextField("Child's Apple ID email", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("or phone number", text: $phone)
                    .keyboardType(.phonePad)
            } header: {
                Text("Child's Apple ID")
            } footer: {
                Text("The Apple ID signed in to iCloud on your child's iPhone. Only that account can join.")
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Add child")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Create") { Task { await create() } }
                        .disabled(!valid)
                }
            }
        }
    }

    private func create() async {
        guard let me = model.profile else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            code = try await FamilyService.addChild(
                name: name.trimmed, birthYear: birthYear, timeZone: timeZone.trimmed,
                childEmail: email, childPhone: phone, me: me, otherParents: model.allParents)
            await model.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TakeOverView: View {
    let childId: String
    @Environment(ParentModel.self) var model
    @State var email = ""
    @State var phone = ""
    @State var dropOwner = true
    @State var isWorking = false
    @State var error: String?
    @State var code: String?

    var body: some View {
        if let code {
            InviteCodeView(code: code,
                           message: "On your child's iPhone, open DigitalRewards › ••• › Join with a new code and enter:")
        } else if let entry = model.entry(childId) {
            let ownerName = entry.family.parents.first {
                $0.recordName == ParentInfo.recordName(userRecordName: entry.family.zone.ownerName)
            }?.displayName ?? "the parent who added them"
            Form {
                Section {
                    Text("\(entry.state.name)'s settings are stored in \(ownerName)'s iCloud. If \(ownerName) has left or deleted their account, copy them into your iCloud. History is kept: it's stored with \(entry.state.name).")
                }
                Section("Child's Apple ID") {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("or phone number", text: $phone)
                        .keyboardType(.phonePad)
                }
                Section {
                    Toggle("Remove \(ownerName)", isOn: $dropOwner)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Button("Take over \(entry.state.name)") {
                        Task { await takeOver(entry) }
                    }
                    .disabled(isWorking || (email.trimmed.isEmpty && phone.trimmed.isEmpty))
                }
            }
            .navigationTitle("Take over")
        }
    }

    private func takeOver(_ entry: ChildEntry) async {
        guard let me = model.profile else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            code = try await FamilyService.takeOver(family: entry.family, childEmail: email, childPhone: phone,
                                                    dropPreviousOwner: dropOwner, me: me)
            await model.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
