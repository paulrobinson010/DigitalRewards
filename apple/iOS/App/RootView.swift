import SwiftUI

struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        switch services.mode {
        case .child:
            ChildRootView()
        case .parent:
            ParentRootView()
        case nil:
            ModePickerView()
        }
    }
}

struct ModePickerView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "figure.walk.motion")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("DigitalRewards")
                .font(.largeTitle.bold())
            Text("Move to earn gaming time.")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                services.mode = .parent
                Task { await services.refresh() }
            } label: {
                Label("I'm a parent", systemImage: "person.2.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button {
                services.mode = .child
                Task { await services.refresh() }
            } label: {
                Label("I'm a child", systemImage: "figure.and.child.holdinghands")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Text("This is set once per device. Use your own Apple ID on your own iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

/// Lets a device switch modes from a settings menu, with confirmation.
struct SwitchModeButton: View {
    @Environment(AppServices.self) private var services
    @State private var confirm = false

    var body: some View {
        Button("Switch app mode…", systemImage: "arrow.left.arrow.right") { confirm = true }
            .confirmationDialog("Switch mode on this device?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Switch", role: .destructive) { services.mode = nil }
            } message: {
                Text("Your family data stays in iCloud. You'll choose Parent or Child again.")
            }
    }
}
