import Foundation

#if DEBUG
/// App Store screenshot mode (debug builds only): a fixed demo family, no iCloud reads or
/// writes. Turn on from the in-app menu, or with the launch argument `-ScreenshotMode YES`,
/// which also works in the Simulator. See apple/README.md › App Store screenshots.
enum ScreenshotMode {
    static let defaultsKey = "ScreenshotMode"

    /// A launch argument lands in UserDefaults' argument domain, so this covers both.
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}
#endif
