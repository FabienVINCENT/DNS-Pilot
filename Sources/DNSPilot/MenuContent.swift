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
        if appState.dohHealth == .unreachable {
            Text("⚠️ L'endpoint DoH ne répond pas")
        }

        Divider()

        Group {
            ForEach(store.profiles) { profile in
                Toggle(isOn: binding(for: profile)) {
                    Text(profileLabel(profile))
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
                    Menu("Suspendre le blocage") {
                        Button("1 minute") { appState.snoozeAdGuard(minutes: 1) }
                        Button("5 minutes") { appState.snoozeAdGuard(minutes: 5) }
                        Button("30 minutes") { appState.snoozeAdGuard(minutes: 30) }
                        Button("1 heure") { appState.snoozeAdGuard(minutes: 60) }
                    }
                } else {
                    Button("Réactiver la protection") {
                        appState.resumeAdGuard()
                    }
                }
                if !adguard.recentlyBlocked.isEmpty {
                    Menu("Débloquer un domaine récent") {
                        Text("Ajoute une règle d'autorisation @@||domaine^")
                        Divider()
                        ForEach(adguard.recentlyBlocked, id: \.self) { domain in
                            Button(domain) {
                                appState.unblockDomain(domain)
                            }
                        }
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
            appState.refresh(forceLatencyProbe: true)
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

    private func profileLabel(_ profile: DNSProfile) -> String {
        var label = "\(profile.name) — \(profile.servers.joined(separator: ", "))"
        switch appState.profileLatencies[profile.id] {
        case .reachable(let ms)?:
            label += " · \(ms < 1 ? "<1" : String(ms)) ms"
        case .unreachable?:
            label += " · ne répond pas"
        case nil:
            break
        }
        return label
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
