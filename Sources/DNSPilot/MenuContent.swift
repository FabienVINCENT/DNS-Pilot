import SwiftUI
import AppKit

/// Contenu du menu déroulant de la barre de menus.
struct MenuContent: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var updater: Updater

    var body: some View {
        Text(appState.statusDescription)
        if let failover = appState.failover {
            Text("⚠️ Failover : \(failover.fallbackDescription) — \(failover.originalProfileName) en panne")
        } else if appState.health == .unreachable {
            Text("⚠️ Le DNS actif ne répond pas")
        }

        Divider()

        Group {
            ForEach(store.profiles) { profile in
                Toggle(isOn: binding(for: profile)) {
                    Text("\(profile.name) — \(profile.servers.joined(separator: ", "))")
                }
            }
            Toggle(isOn: dhcpBinding) {
                Text("DHCP (auto)")
            }
        }
        .disabled(appState.isBusy)

        if let adguard = appState.adguardInfo {
            Divider()
            if adguard.authRequired {
                Text("AdGuard Home : identifiants requis (Préférences › AdGuard Home)")
            } else {
                Text(adguardStatusLine(adguard))
                if adguard.protectionEnabled {
                    Button("Suspendre le blocage 5 min") {
                        appState.snoozeAdGuard(minutes: 5)
                    }
                } else {
                    Button("Réactiver la protection") {
                        appState.resumeAdGuard()
                    }
                }
            }
            Button("Ouvrir l'interface AdGuard Home…") {
                appState.openAdGuardUI()
            }
        }

        Divider()

        Button("Vider le cache DNS") {
            appState.flushDNSCache()
        }
        .disabled(appState.isBusy)

        Button("Actualiser l'état") {
            appState.refresh()
        }

        if let update = updater.availableUpdate {
            Divider()
            Button(updater.isInstalling
                   ? "Mise à jour \(update.version) en cours…"
                   : "Installer la mise à jour \(update.version)…") {
                updater.installAvailableUpdate()
            }
            .disabled(updater.isInstalling)
        }

        Divider()

        SettingsLink {
            Text("Préférences…")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Quitter DNS Pilot") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func adguardStatusLine(_ info: AdGuardInfo) -> String {
        var line = "AdGuard Home — protection \(info.protectionEnabled ? "activée" : "suspendue")"
        if let blocked = info.blocked, let queries = info.queries {
            line += " · \(blocked.formatted()) bloquées / \(queries.formatted())"
        }
        return line
    }

    private func binding(for profile: DNSProfile) -> Binding<Bool> {
        Binding(
            get: { appState.activeProfile?.id == profile.id },
            set: { isOn in if isOn { appState.apply(profile) } }
        )
    }

    private var dhcpBinding: Binding<Bool> {
        Binding(
            get: { appState.isDHCP },
            set: { isOn in if isOn { appState.resetToDHCP() } }
        )
    }
}
