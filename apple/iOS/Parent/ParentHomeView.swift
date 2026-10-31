import SwiftUI

struct ParentRootView: View {
    @Environment(ParentModel.self) private var model

    var body: some View {
        NavigationStack {
            if model.profile == nil {
                ParentOnboardingView()
            } else {
                ParentHomeView()
            }
        }
    }
}

/// Navigation value for a child's detail screen.
struct ChildRoute: Hashable {
    var childId: String
}

struct ParentHomeView: View {
    @Environment(ParentModel.self) private var model
    @State private var showAddChild = false
    @State private var showParents = false
    @State private var schemaMessage: String?

    var body: some View {
        List {
            if !model.hasLoaded {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if model.children.isEmpty {
                Section {
                    Text("Add a child to get started, or join a family another parent set up (Parents › Join with a code).")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(model.children) { entry in
                NavigationLink(value: ChildRoute(childId: entry.id)) {
                    ChildSummaryRow(entry: entry)
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).font(.footnote).foregroundStyle(Theme.magenta) }
            }
        }
        .themedList()
        .navigationTitle("Family")
        .navigationDestination(for: ChildRoute.self) { route in
            ChildDetailView(childId: route.childId)
        }
        .refreshable { await model.refresh() }
        .task { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add child", systemImage: "plus") { showAddChild = true }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Parents", systemImage: "person.2") { showParents = true }
                    SwitchModeButton()
                    #if DEBUG
                    ScreenshotModeButton()
                    Button("Create CloudKit schema", systemImage: "hammer") {
                        Task {
                            do {
                                try await SchemaSeeder.run()
                                schemaMessage = "All record types now exist in the Development schema. "
                                    + "Deploy them to Production in the CloudKit Console."
                            } catch {
                                schemaMessage = error.userMessage
                            }
                        }
                    }
                    #endif
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showAddChild) {
            NavigationStack { AddChildView() }
        }
        .sheet(isPresented: $showParents) {
            NavigationStack { ParentsView() }
        }
        .alert("CloudKit schema", isPresented: Binding(get: { schemaMessage != nil },
                                                       set: { if !$0 { schemaMessage = nil } })) {
            Button("OK") { schemaMessage = nil }
        } message: {
            Text(schemaMessage ?? "")
        }
    }
}

struct ChildSummaryRow: View {
    let entry: ChildEntry

    var body: some View {
        let status = entry.state.status
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.state.name).font(.headline)
                if !entry.hasActivity {
                    Text("Waiting for \(entry.state.name) to join").font(.caption).foregroundStyle(Theme.yellow)
                } else if status.canPlay {
                    Text("Can play \(Fmt.minutes(status.minutesAvailable))").font(.caption).foregroundStyle(.secondary)
                } else if let reason = Fmt.reason(status.reason) {
                    Text(reason).font(.caption).foregroundStyle(Theme.magenta)
                }
            }
            Spacer()
            Text(Fmt.minutes(status.balance))
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(status.balance < 0 ? Theme.magenta : Theme.green)
        }
    }
}

struct ParentOnboardingView: View {
    @Environment(ParentModel.self) private var model
    @State private var name = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Your name (e.g. Mum)", text: $name)
                    .textContentType(.name)
            } footer: {
                Text("Your child sees this next to anything you change.")
            }
            Section {
                TextField("Apple ID email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("or Apple ID phone number", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
            } header: {
                Text("Your Apple ID")
            } footer: {
                Text("Your child's iPhone uses this to share their activity with you. It must match the Apple ID signed in to iCloud on this iPhone.")
            }
            if let error {
                Section { Text(error).foregroundStyle(Theme.magenta) }
            }
            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving { ProgressView() } else { Text("Continue") }
                }
                .disabled(name.trimmed.isEmpty || (email.trimmed.isEmpty && phone.trimmed.isEmpty) || isSaving)
            }
            Section {
                SwitchModeButton()
                #if DEBUG
                ScreenshotModeButton()
                #endif
            }
        }
        .themedList()
        .navigationTitle("Set up")
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.saveProfile(displayName: name, email: email, phone: phone)
        } catch {
            self.error = error.userMessage
        }
    }
}

/// Shows a 6-digit invite code with a share button.
struct InviteCodeView: View {
    let code: String
    let message: String
    var notes: [String] = []
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text(message)
                .multilineTextAlignment(.center)
            Text(String(code.prefix(3)) + " " + String(code.suffix(3)))
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            Text("The code works for 7 days.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(notes, id: \.self) { note in
                Text(note).font(.footnote).foregroundStyle(Theme.yellow).multilineTextAlignment(.center)
            }
            ShareLink(item: "Your DigitalRewards code is \(code)") {
                Label("Send code", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding()
        .navigationTitle("Invite code")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
