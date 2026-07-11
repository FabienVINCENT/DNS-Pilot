import Foundation
import ServiceManagement

enum PreferenceKeys {
    /// Bascule automatique de profil selon le SSID Wi-Fi.
    static let autoSwitch = "autoSwitchBySSID"
    /// Installer la règle sudoers à la première invite admin
    /// (mot de passe demandé une seule fois, plus jamais ensuite).
    static let rememberAdmin = "rememberAdminAuthorization"
    /// Failover : basculer sur la cible de secours quand le DNS actif ne répond plus.
    static let failoverEnabled = "failoverEnabled"
    /// Cible du failover : "dhcp" ou l'UUID d'un profil.
    static let failoverTarget = "failoverTarget"
    /// Notifications macOS (bascules auto, failover, rétablissement).
    static let notifications = "notificationsEnabled"
    /// URL de l'interface web de l'instance AdGuard Home (config globale).
    static let adguardURL = "adguardInstanceURL"
    /// Identifiant AdGuard Home (le mot de passe vit dans le trousseau).
    static let adguardUsername = "adguardInstanceUsername"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoSwitch: true,
            rememberAdmin: true,
            failoverEnabled: true,
            failoverTarget: "dhcp",
            notifications: true,
        ])
    }
}

/// Lancement à l'ouverture de session (SMAppService).
/// Ne fonctionne que depuis le bundle .app — pas via `swift run`.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
