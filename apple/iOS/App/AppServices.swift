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

    var mode: AppMode? {
        didSet { UserDefaults.standard.set(mode?.rawValue, forKey: Self.modeKey) }
    }

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(AppMode.init(rawValue:))
    }

    func refresh() async {
        switch mode {
        case .child: await child.refresh()
        case .parent: await parent.refresh()
        case nil: break
        }
    }
}
