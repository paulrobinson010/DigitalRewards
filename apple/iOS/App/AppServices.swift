import Foundation
import Observation

enum AppMode: String {
    case child, parent
}

/// Holds the mode and both models. The mode is chosen once on first launch.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    private static let modeKey = "dr.appMode"

    let child = ChildModel()
    let parent = ParentModel()

    /// Backing storage (tracked by @Observable); `mode` persists on every change.
    private var storedMode: AppMode?

    var mode: AppMode? {
        get { storedMode }
        set {
            storedMode = newValue
            UserDefaults.standard.set(newValue?.rawValue, forKey: Self.modeKey)
        }
    }

    #if DEBUG
    /// Backing storage for `screenshotMode` (tracked by @Observable).
    private var storedScreenshotMode = ScreenshotMode.isOn

    /// App Store screenshot mode: the demo family, no iCloud. Debug builds only.
    var screenshotMode: Bool {
        get { storedScreenshotMode }
        set {
            storedScreenshotMode = newValue
            ScreenshotMode.isOn = newValue
            if !newValue {
                child.clearDemo()
                parent.clearDemo()
                Task { await refresh() }
            }
        }
    }
    #endif

    init() {
        storedMode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(AppMode.init(rawValue:))
    }

    func refresh() async {
        switch mode {
        case .child: await child.refresh()
        case .parent: await parent.refresh()
        case nil: break
        }
    }
}
