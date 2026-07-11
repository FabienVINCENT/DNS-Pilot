import SwiftUI
import AppKit

@main
struct DNSPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(appState)
                .environmentObject(appState.profileStore)
                .environmentObject(appState.updater)
        } label: {
            Image(systemName: appState.iconName)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            PreferencesView()
                .environmentObject(appState)
                .environmentObject(appState.profileStore)
                .environmentObject(appState.updater)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // App de barre de menus uniquement : pas d'icône dans le Dock.
        // (Doublé par LSUIElement dans l'Info.plist du bundle — ceci couvre `swift run`.)
        NSApp.setActivationPolicy(.accessory)
    }
}
