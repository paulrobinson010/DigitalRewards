import SwiftUI

struct RootView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        #if DEBUG
        if services.screenshotMode {
            ScreenshotRootView()
        } else {
            modeView
        }
        #else
        modeView
        #endif
    }

    @ViewBuilder
    private var modeView: some View {
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
            PixelAlien(animated: true)
                .frame(height: 90)
            Text("Go AFK")
                .font(Theme.label(34))
                .foregroundStyle(.white)
            Text("Move to earn gaming time.")
                .foregroundStyle(Theme.cyan)
            Spacer()
            Button {
                services.mode = .parent
                Task { await services.refresh() }
            } label: {
                Label("I'm a parent", systemImage: "person.2.fill")
            }
            .buttonStyle(NeonButtonStyle(color: Theme.cyan))
            Button {
                services.mode = .child
                Task { await services.refresh() }
            } label: {
                Label("I'm a child", systemImage: "gamecontroller.fill")
            }
            .buttonStyle(NeonButtonStyle(color: Theme.green))
            Text("This is set once per device. Use your own Apple ID on your own iPhone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            #if DEBUG
            ScreenshotModeButton()
                .font(.footnote)
            #endif
        }
        .padding()
        .background(ThemeBackground())
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
