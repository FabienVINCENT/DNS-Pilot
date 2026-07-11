import SwiftUI
import AppKit

/// Fenêtre Préférences : profils DNS (onglet Profils) et réglages généraux
/// (launch at login, bascule auto par SSID, autorisation admin mémorisée).
struct PreferencesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            ProfilesTab()
                .tabItem { Label("Profils", systemImage: "list.bullet") }
            AdGuardTab()
                .tabItem { Label("AdGuard Home", systemImage: "shield.lefthalf.filled") }
            GeneralTab(ssidProvider: appState.ssidProvider)
                .tabItem { Label("Général", systemImage: "gearshape") }
        }
        .frame(width: 660, height: 480)
        .onAppear {
            // La fenêtre Réglages d'une app .accessory s'ouvre sinon en arrière-plan.
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Onglet Profils

private struct ProfilesTab: View {
    @EnvironmentObject private var store: ProfileStore
    @State private var selection: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.profiles) { profile in
                        Text(profile.name)
                            .tag(profile.id)
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    Button {
                        let profile = DNSProfile(name: "Nouveau profil", servers: ["1.1.1.1"])
                        store.profiles.append(profile)
                        selection = profile.id
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Ajouter un profil")

                    Button {
                        if let selection {
                            store.profiles.removeAll { $0.id == selection }
                            self.selection = nil
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selection == nil)
                    .help("Supprimer le profil sélectionné")

                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 190)

            Divider()

            if let index = store.profiles.firstIndex(where: { $0.id == selection }) {
                ProfileDetail(profile: $store.profiles[index])
                    .id(selection) // réinitialise les champs locaux au changement de sélection
            } else {
                VStack(spacing: 6) {
                    Text("Sélectionnez un profil")
                        .foregroundStyle(.secondary)
                    Text("ou créez-en un avec +")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct ProfileDetail: View {
    @Binding var profile: DNSProfile
    @State private var serversText = ""
    @State private var ssidsText = ""
    @State private var dohURLText = ""
    @State private var dohFeedback: String?

    var body: some View {
        Form {
            Section("Profil") {
                TextField("Nom", text: $profile.name)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Serveurs DNS", text: $serversText)
                        .onChange(of: serversText) { _, value in
                            profile.servers = value
                                .split(whereSeparator: { $0 == "," || $0 == " " })
                                .map(String.init)
                                .filter { !$0.isEmpty }
                        }
                    Text("Adresses IPv4/IPv6, séparées par des virgules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Bascule automatique") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Réseaux Wi-Fi (SSID)", text: $ssidsText)
                        .onChange(of: ssidsText) { _, value in
                            let ssids = value
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                            profile.autoSSIDs = ssids.isEmpty ? nil : ssids
                        }
                    Text("Ce profil s'applique automatiquement sur ces réseaux. Séparez par des virgules — les espaces à l'intérieur d'un SSID sont conservés.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("DNS-over-HTTPS") {
                TextField("URL DoH", text: $dohURLText, prompt: Text("https://dns.adguard.com/dns-query"))
                    .onChange(of: dohURLText) { _, value in
                        let trimmed = value.trimmingCharacters(in: .whitespaces)
                        profile.dohURL = trimmed.isEmpty ? nil : trimmed
                    }
                Button("Générer le profil système (.mobileconfig)…") {
                    generateDoHProfile()
                }
                .disabled(profile.dohURL == nil)
                if let dohFeedback {
                    Text(dohFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("macOS n'autorise pas l'installation silencieuse : le fichier est déposé dans Téléchargements puis ouvert — terminez dans Réglages Système › Général › Gestion des appareils. Une fois installé, le DoH prend le pas sur les DNS classiques.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            serversText = profile.servers.joined(separator: ", ")
            ssidsText = (profile.autoSSIDs ?? []).joined(separator: ", ")
            dohURLText = profile.dohURL ?? ""
        }
    }

    private func generateDoHProfile() {
        do {
            let url = try DoHProfileGenerator.generate(for: profile)
            NSWorkspace.shared.open(url)
            dohFeedback = "Profil généré : ~/Downloads/\(url.lastPathComponent)"
        } catch {
            dohFeedback = error.localizedDescription
        }
    }
}

// MARK: - Onglet AdGuard Home

/// Configuration globale de l'instance AdGuard Home (il n'y en a qu'une).
/// La section du menu apparaît automatiquement quand le DNS actif pointe
/// vers cette instance — rien à configurer dans les profils.
private struct AdGuardTab: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(PreferenceKeys.adguardURL) private var adguardURL = ""
    @AppStorage(PreferenceKeys.adguardUsername) private var adguardUsername = ""
    @State private var password = ""
    @State private var feedback: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("Instance") {
                TextField("URL de l'interface", text: $adguardURL, prompt: Text("http://adresse-ip:port"))
                TextField("Utilisateur", text: $adguardUsername)
                SecureField("Mot de passe", text: $password)
                    .onChange(of: password) { _, value in
                        Keychain.setPassword(value, account: Keychain.adguardAccount)
                    }
                HStack(spacing: 10) {
                    Button("Tester la connexion") { testConnection() }
                        .disabled(adguardURL.isEmpty || busy)
                    Button("Détecter sur le DNS actif") { detect() }
                        .disabled(busy)
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
                if let feedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text("La section AdGuard Home du menu apparaît automatiquement quand le DNS actif pointe vers cette instance (correspondance par adresse IP, noms d'hôte résolus). Le mot de passe est stocké dans le trousseau macOS, jamais en clair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Si aucune instance n'est configurée, DNS Pilot tente de la détecter tout seul sur le serveur DNS actif (ports web 80, 3000, 8080).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            password = Keychain.password(account: Keychain.adguardAccount) ?? ""
        }
    }

    private func testConnection() {
        guard let url = URL(string: adguardURL.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            feedback = "URL invalide — attendu : http(s)://hôte[:port]"
            return
        }
        busy = true
        feedback = nil
        let client = AdGuardClient(
            baseURL: url,
            username: adguardUsername.isEmpty ? nil : adguardUsername,
            password: Keychain.password(account: Keychain.adguardAccount)
        )
        Task {
            defer { busy = false }
            do {
                let status = try await client.status()
                feedback = "Connecté ✓ — protection \(status.protectionEnabled ? "activée" : "suspendue")"
                appState.refreshAdGuard()
            } catch AdGuardError.unauthorized {
                feedback = "Le serveur répond, mais identifiants requis ou incorrects."
            } catch {
                feedback = "Injoignable : \(error.localizedDescription)"
            }
        }
    }

    private func detect() {
        guard let host = appState.currentServers.first else {
            feedback = "Aucun DNS personnalisé actif — appliquez d'abord un profil."
            return
        }
        busy = true
        feedback = nil
        Task {
            defer { busy = false }
            if let url = await AdGuardClient.detect(host: host) {
                adguardURL = url.absoluteString
                feedback = "AdGuard Home détecté ✓ (\(url.absoluteString))"
                appState.refreshAdGuard()
            } else {
                feedback = "Rien trouvé sur \(host) (ports 80, 3000, 8080) — saisissez l'URL à la main."
            }
        }
    }
}

// MARK: - Onglet Général

private struct GeneralTab: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var updater: Updater
    @ObservedObject var ssidProvider: SSIDProvider
    @AppStorage(PreferenceKeys.autoSwitch) private var autoSwitch = true
    @AppStorage(PreferenceKeys.updateCheck) private var updateCheck = true
    @AppStorage(PreferenceKeys.rememberAdmin) private var rememberAdmin = true
    @AppStorage(PreferenceKeys.failoverEnabled) private var failoverEnabled = true
    @AppStorage(PreferenceKeys.failoverTarget) private var failoverTarget = "dhcp"
    @AppStorage(PreferenceKeys.notifications) private var notificationsEnabled = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Démarrage") {
                Toggle("Lancer DNS Pilot à l'ouverture de session", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        guard enabled != LoginItem.isEnabled else { return }
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginItemError = nil
                        } catch {
                            loginItemError = "Impossible — lancez l'app depuis le bundle .app (\(error.localizedDescription))"
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Failover") {
                Toggle("Basculer automatiquement si le DNS actif ne répond plus", isOn: $failoverEnabled)
                Picker("Cible de secours", selection: $failoverTarget) {
                    Text("DHCP (auto)").tag("dhcp")
                    ForEach(store.profiles) { profile in
                        Text(profile.name).tag(profile.id.uuidString)
                    }
                }
                Text("Deux requêtes DNS perdues d'affilée déclenchent la bascule ; le profil d'origine est rétabli automatiquement dès que son serveur répond (vérification toutes les 60 s). Silencieux : nécessite l'autorisation admin mémorisée.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Notifier les bascules (SSID, failover, rétablissement)", isOn: $notificationsEnabled)
            }

            Section("Bascule automatique") {
                Toggle("Appliquer automatiquement un profil selon le réseau Wi-Fi", isOn: $autoSwitch)
                LabeledContent("SSID actuel", value: ssidProvider.currentSSID ?? "—")
                if ssidProvider.currentSSID == nil {
                    Text("SSID illisible : Wi-Fi éteint, ou autorisation Localisation manquante (macOS l'exige pour lire le nom du réseau).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Autoriser l'accès à la localisation…") {
                        ssidProvider.requestAuthorization()
                    }
                }
                Text("Les SSID se configurent dans chaque profil (onglet Profils). La bascule est silencieuse : elle n'opère que si l'autorisation admin est mémorisée ci-dessous.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Autorisation admin") {
                Toggle("Mémoriser l'autorisation (mot de passe demandé une seule fois)", isOn: $rememberAdmin)
                LabeledContent("Règle sudoers", value: appState.passwordlessConfigured ? "installée ✓" : "non installée")
                if appState.passwordlessConfigured {
                    Button("Supprimer la règle sudoers…") {
                        rememberAdmin = false // sinon elle serait réinstallée au prochain changement
                        appState.removePasswordlessRule()
                    }
                } else if rememberAdmin {
                    Button("Configurer maintenant…") {
                        appState.installPasswordlessRule()
                    }
                    Text("Sinon, la règle s'installera d'elle-même à la prochaine invite admin (changement de DNS ou vidage du cache).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("La règle (\(DNSManager.sudoersFilePath)) n'autorise sans mot de passe que networksetup, dscacheutil et killall -HUP mDNSResponder, pour votre utilisateur uniquement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Profils") {
                    Button("Afficher profiles.json dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ProfileStore.fileURL])
                    }
                }
            }

            Section("Mises à jour") {
                Toggle("Vérifier automatiquement (une fois par jour)", isOn: $updateCheck)
                    .onChange(of: updateCheck) { _, enabled in
                        if enabled { updater.checkNow() }
                    }
                HStack(spacing: 10) {
                    Button("Rechercher maintenant") { updater.checkNow() }
                        .disabled(updater.state == .checking || updater.isInstalling)
                    if let update = updater.availableUpdate {
                        Button("Installer la version \(update.version)") {
                            updater.installAvailableUpdate()
                        }
                        .disabled(updater.isInstalling || !AppInfo.isBundled)
                        Button("Notes de version…") { updater.openReleasePage() }
                    }
                    if updater.state == .checking || updater.isInstalling {
                        ProgressView().controlSize(.small)
                    }
                }
                if let status = updater.statusText {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Les mises à jour viennent des Releases GitHub du projet : DMG vérifié (SHA-256 contre checksums.txt), puis l'app se remplace et se relance toute seule. Rien n'est installé sans votre clic.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("À propos") {
                LabeledContent("Version", value: AppInfo.display)
            }
        }
        .formStyle(.grouped)
    }
}
