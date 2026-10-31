#if DEBUG
import SwiftUI

/// The screens to capture for the App Store, each loaded with the demo family.
enum ScreenshotScene: String, CaseIterable, Identifiable {
    case childCredit = "Kid home (credit)"
    case childCelebration = "Kid home + \"+120 CREDITS!\""
    case childDebit = "Kid home (debit)"
    case childHistory = "Kid history"
    case parentHome = "Parent home"
    case childDetail = "Child detail / ledger"
    case rules = "Rules editor"
    case bonuses = "Bonuses"
    case devices = "Devices"
    case allowList = "PC allowed programs"

    var id: String { rawValue }
}

/// Screenshot mode: shows one scene at a time with the demo family. The yellow camera
/// button opens the scene picker; hide it before taking the shot and long-press anywhere
/// (1.5 s) to bring it back.
struct ScreenshotRootView: View {
    @Environment(AppServices.self) private var services
    @State private var scene: ScreenshotScene = .childCredit
    @State private var showControls = true
    @State private var showPicker = false

    var body: some View {
        content
            .id(scene)
            .overlay(alignment: .bottomTrailing) {
                if showControls {
                    Button { showPicker = true } label: {
                        Image(systemName: "camera.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.bgBottom)
                            .padding(14)
                            .background(Circle().fill(Theme.yellow))
                            .neonGlow(Theme.yellow, radius: 6)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 36)
                    .accessibilityLabel("Screenshot scenes")
                }
            }
            .simultaneousGesture(LongPressGesture(minimumDuration: 1.5).onEnded { _ in showControls = true })
            .sheet(isPresented: $showPicker) { picker }
            .onAppear { load(scene) }
            .onChange(of: scene) { _, new in load(new) }
    }

    @ViewBuilder
    private var content: some View {
        switch scene {
        case .childCredit, .childDebit:
            NavigationStack { ChildHomeView() }
        case .childCelebration:
            NavigationStack { ChildHomeView(frozenCelebration: DemoData.celebration) }
        case .childHistory:
            NavigationStack { ChildHistoryView() }
        case .parentHome:
            NavigationStack { ParentHomeView() }
        case .childDetail:
            NavigationStack { ChildDetailView(childId: DemoData.jensenId) }
        case .rules:
            NavigationStack { RulesEditorView(childId: DemoData.jensenId) }
        case .bonuses:
            NavigationStack { BonusesView(childId: DemoData.jensenId) }
        case .devices:
            NavigationStack { DevicesView(childId: DemoData.jensenId) }
        case .allowList:
            NavigationStack { AllowListEditorView(childId: DemoData.jensenId, deviceId: DemoData.pcDeviceId) }
        }
    }

    private var picker: some View {
        NavigationStack {
            List {
                Section("Scene") {
                    ForEach(ScreenshotScene.allCases) { s in
                        Button {
                            scene = s
                            showPicker = false
                        } label: {
                            HStack {
                                Text(s.rawValue).foregroundStyle(.white)
                                Spacer()
                                if s == scene { Image(systemName: "checkmark").foregroundStyle(Theme.cyan) }
                            }
                        }
                    }
                }
                Section {
                    Button("Hide camera button") {
                        showControls = false
                        showPicker = false
                    }
                } footer: {
                    Text("Long-press anywhere for 1.5 s to bring it back. In the Simulator, ⌘S saves a screenshot.")
                }
                Section {
                    Button("Exit screenshot mode", role: .destructive) {
                        showPicker = false
                        services.screenshotMode = false
                    }
                }
            }
            .themedList()
            .navigationTitle("Screenshot mode")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func load(_ scene: ScreenshotScene) {
        services.child.loadDemo(scene == .childDebit ? DemoData.jensenDebit : DemoData.jensen)
        services.parent.loadDemo(children: DemoData.parentEntries, profile: DemoData.profile)
    }
}

/// Menu item that turns screenshot mode on (debug builds only).
struct ScreenshotModeButton: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        Button("Screenshot mode", systemImage: "camera") { services.screenshotMode = true }
    }
}
#endif
