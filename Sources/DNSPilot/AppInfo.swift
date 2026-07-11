import Foundation

/// Version de l'app, lue dans l'Info.plist du bundle.
/// Via `swift run` (pas de bundle, donc pas d'Info.plist), retombe sur "dev".
enum AppInfo {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

    /// Vrai quand l'app tourne depuis un bundle .app (faux via `swift run`).
    static let isBundled = Bundle.main.bundleURL.pathExtension == "app"

    /// "1.0.0 (42)" en bundle, "dev" via `swift run`.
    static var display: String {
        build.map { "\(version) (\($0))" } ?? version
    }
}
