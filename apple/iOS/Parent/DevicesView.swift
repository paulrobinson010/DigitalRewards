import SwiftUI

struct DevicesView: View {
    let childId: String
    @Environment(ParentModel.self) var model

    var body: some View {
        let devices = (model.entry(childId)?.state.activity?.devices ?? []).sorted { $0.lastSeenAt > $1.lastSeenAt }
        List {
            if devices.isEmpty {
                Text("No devices have reported yet. Devices appear after they sync for the first time.")
                    .foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                if device.kind == .windows {
                    NavigationLink {
                        AllowListEditorView(childId: childId, deviceId: device.deviceId)
                    } label: {
                        DeviceRow(device: device)
                    }
                } else {
                    DeviceRow(device: device)
                }
            }
        }
        .navigationTitle("Devices")
        .refreshable { await model.refresh() }
    }
}

struct DeviceRow: View {
    let device: DeviceInfo

    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 28)
            VStack(alignment: .leading) {
                Text(device.name)
                Text("Last seen \(Fmt.relative(device.lastSeenAt))")
                    .font(.caption)
                    .foregroundStyle(stale ? Color.orange : Color.secondary)
            }
        }
    }

    private var icon: String {
        switch device.kind {
        case .watch: return "applewatch"
        case .ios: return "iphone"
        case .windows: return "desktopcomputer"
        }
    }

    private var stale: Bool {
        device.kind == .windows && Date().timeIntervalSince(device.lastSeenAt) > AlertMonitor.deviceSilenceThreshold
    }
}

/// Which programs on a Windows PC are free to use. Everything else costs minutes.
struct AllowListEditorView: View {
    let childId: String
    let deviceId: String
    @Environment(ParentModel.self) var model
    @Environment(\.dismiss) var dismiss
    @State var allowed: Set<String> = []
    @State var loaded = false
    @State var manualExe = ""
    @State var search = ""
    @State var isSaving = false
    @State var error: String?

    var body: some View {
        let entry = model.entry(childId)
        let device = entry?.state.activity?.devices.first { $0.deviceId == deviceId }
        let detected = (device?.detectedApps ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let detectedExes = Set(detected.map { $0.exe.lowercased() })
        let extra = allowed.subtracting(detectedExes).sorted()
        let filtered = search.isEmpty ? detected : detected.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.exe.localizedCaseInsensitiveContains(search)
        }

        List {
            Section {
                Text("Windows system apps are always free. Tick anything else your child can use without spending minutes, like Word or a browser for homework.")
                    .font(.footnote)
            }
            Section("Programs found on \(device?.name ?? "this PC")") {
                ForEach(filtered) { app in
                    Toggle(isOn: Binding(
                        get: { allowed.contains(app.exe.lowercased()) },
                        set: { on in
                            if on { allowed.insert(app.exe.lowercased()) } else { allowed.remove(app.exe.lowercased()) }
                        })) {
                        VStack(alignment: .leading) {
                            Text(app.name)
                            Text(app.exe).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Other allowed programs") {
                ForEach(extra, id: \.self) { exe in Text(exe) }
                    .onDelete { offsets in offsets.map { extra[$0] }.forEach { allowed.remove($0) } }
                HStack {
                    TextField("program.exe", text: $manualExe)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") {
                        let exe = manualExe.trimmed.lowercased()
                        guard !exe.isEmpty else { return }
                        allowed.insert(exe.hasSuffix(".exe") ? exe : exe + ".exe")
                        manualExe = ""
                    }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Allowed programs")
        .toolbar {
            Button("Save") { Task { await save() } }
                .disabled(isSaving || !loaded)
        }
        .onAppear {
            guard !loaded, let entry else { return }
            allowed = Set(entry.family.allowLists.first { $0.deviceId == deviceId }?.executables ?? [])
            loaded = true
        }
    }

    private func save() async {
        guard let entry = model.entry(childId) else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await FamilyService.saveAllowList(deviceId: deviceId, executables: Array(allowed), family: entry.family)
            await model.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AlertPrefsView: View {
    let childId: String
    @Environment(ParentModel.self) var model
    @State var prefs: AlertPrefsInfo?
    @State var error: String?

    var body: some View {
        Form {
            if let current = prefs {
                Section {
                    toggle("Workout completed", \.workout, current)
                    toggle("Went into debit", \.debit, current)
                    toggle("Suspicious workout", \.suspicious, current)
                    toggle("PC stopped reporting", \.deviceSilent, current)
                } footer: {
                    Text("These alerts are just for you. Other parents choose their own. Alerts arrive when iOS lets the app refresh, so they can be delayed.")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Alerts")
        .onAppear {
            if prefs == nil { prefs = model.prefs(for: childId) }
        }
    }

    private func toggle(_ title: String, _ keyPath: WritableKeyPath<AlertPrefsInfo, Bool>,
                        _ current: AlertPrefsInfo) -> some View {
        Toggle(title, isOn: Binding(
            get: { current[keyPath: keyPath] },
            set: { on in
                var updated = current
                updated[keyPath: keyPath] = on
                prefs = updated
                Task {
                    do {
                        try await FamilyService.saveAlertPrefs(updated)
                        await model.refresh()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }))
    }
}
