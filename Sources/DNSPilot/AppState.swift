import SwiftUI
import AppKit
import Combine
import Network

/// État du failover en cours : on garde de quoi surveiller le serveur d'origine
/// et le rétablir dès qu'il répond de nouveau.
struct FailoverState: Equatable {
    let originalProfileID: UUID
    let originalProfileName: String
    let watchServer: String
    let fallbackDescription: String
}

/// Infos AdGuard Home du profil actif (section dédiée du menu).
struct AdGuardInfo: Equatable {
    var baseURL: URL
    var authRequired = false
    var protectionEnabled = true
    var queries: Int?
    var blocked: Int?
}

/// Coordinateur central : état courant (interface, DNS, santé), actions,
/// bascule auto par SSID, failover et intégration AdGuard Home.
@MainActor
final class AppState: ObservableObject {

    let profileStore = ProfileStore()
    let healthChecker = HealthChecker()
    let ssidProvider = SSIDProvider()
    private let dnsManager = DNSManager()
    private let pathMonitor = NWPathMonitor()
    private var refreshTimer: Timer?
    private var recoveryTimer: Timer?
    private var autoSwitchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// Dernier SSID pour lequel la bascule auto a été évaluée : un choix manuel
    /// n'est jamais écrasé tant qu'on reste sur le même réseau.
    private var lastAutoSwitchSSID: String?
    /// Hôtes déjà sondés pour la détection AdGuard (une tentative par session).
    private var adguardDetectionTriedHosts: Set<String> = []
    /// Cache de résolution DNS hôte → IPs pour l'association instance ↔ DNS actif.
    private var resolvedHostCache: [String: [String]] = [:]

    @Published private(set) var serviceName: String?
    @Published private(set) var currentServers: [String] = []
    @Published private(set) var health: HealthChecker.Status = .unknown
    @Published private(set) var isBusy = false
    @Published private(set) var passwordlessConfigured = false
    @Published private(set) var failover: FailoverState?
    @Published private(set) var adguardInfo: AdGuardInfo?

    init() {
        PreferenceKeys.registerDefaults()

        healthChecker.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                Task { @MainActor in self?.applyHealthUpdate(status) }
            }
            .store(in: &cancellables)

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.handleNetworkChange() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dnspilot.pathmonitor"))

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        refresh()
        scheduleAutoSwitch() // applique le bon profil dès le lancement si un SSID correspond
    }

    // MARK: - État dérivé

    var isDHCP: Bool { currentServers.isEmpty }

    /// Profil correspondant aux serveurs DNS actuellement configurés.
    var activeProfile: DNSProfile? {
        guard !currentServers.isEmpty else { return nil }
        return profileStore.profiles.first { $0.servers == currentServers }
            ?? profileStore.profiles.first { Set($0.servers) == Set(currentServers) }
    }

    /// Icône : pleine = DNS custom, contour = DHCP, alerte pleine = DNS muet,
    /// alerte contour = failover actif (on tourne sur la cible de secours).
    var iconName: String {
        if failover != nil { return "exclamationmark.shield" }
        if isDHCP { return "shield" }
        return health == .unreachable ? "exclamationmark.shield.fill" : "shield.fill"
    }

    var statusDescription: String {
        guard let serviceName else { return "Aucune interface active" }
        if isDHCP { return "\(serviceName) · DHCP (auto)" }
        if let profile = activeProfile { return "\(serviceName) · \(profile.name)" }
        return "\(serviceName) · DNS : \(currentServers.joined(separator: ", "))"
    }

    // MARK: - Actions utilisateur

    func refresh() {
        Task.detached(priority: .utility) { [dnsManager] in
            let service = dnsManager.activeService()
            let servers = service.map { dnsManager.currentDNSServers(service: $0.name) } ?? []
            let passwordless = dnsManager.isPasswordlessConfigured()
            await MainActor.run {
                self.update(serviceName: service?.name, servers: servers, passwordless: passwordless)
            }
        }
    }

    func apply(_ profile: DNSProfile) {
        clearFailover() // l'utilisateur reprend la main
        runPrivilegedAction { manager, service in
            try manager.apply(servers: profile.servers, service: service)
        }
    }

    func resetToDHCP() {
        clearFailover()
        runPrivilegedAction { manager, service in
            try manager.resetToDHCP(service: service)
        }
    }

    func flushDNSCache() {
        runAction { manager in try manager.flushCache() }
    }

    /// Installe la règle sudoers tout de suite (une seule invite admin).
    func installPasswordlessRule() {
        runAction { manager in try manager.installPasswordlessRule() }
    }

    /// Supprime la règle sudoers (une invite admin).
    func removePasswordlessRule() {
        runAction { manager in try manager.removePasswordlessRule() }
    }

    // MARK: - Bascule automatique par SSID

    private func handleNetworkChange() {
        refresh()
        scheduleAutoSwitch()
    }

    /// Debounce : un changement de réseau déclenche plusieurs événements de chemin,
    /// et il faut laisser le DHCP/Wi-Fi se stabiliser avant de lire le SSID.
    private func scheduleAutoSwitch() {
        autoSwitchTask?.cancel()
        autoSwitchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.performAutoSwitchIfNeeded()
        }
    }

    private func performAutoSwitchIfNeeded() {
        guard UserDefaults.standard.bool(forKey: PreferenceKeys.autoSwitch) else { return }
        ssidProvider.refresh()
        guard let ssid = ssidProvider.currentSSID, ssid != lastAutoSwitchSSID else { return }
        lastAutoSwitchSSID = ssid
        guard let match = profileStore.profiles.first(where: { ($0.autoSSIDs ?? []).contains(ssid) }),
              activeProfile?.id != match.id else { return }

        Task.detached(priority: .utility) { [dnsManager] in
            guard let service = dnsManager.activeService()?.name else { return }
            // Silencieux par contrat : uniquement via sudo -n. Sans règle sudoers,
            // on ne fait rien — jamais de boîte de dialogue surprise.
            if dnsManager.applyPasswordless(servers: match.servers, service: service) {
                await MainActor.run {
                    self.clearFailover() // nouveau réseau, contexte de panne obsolète
                    NotificationManager.shared.post(
                        title: "DNS Pilot",
                        body: "Réseau « \(ssid) » : profil \(match.name) appliqué."
                    )
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Failover

    private func applyHealthUpdate(_ status: HealthChecker.Status) {
        guard status != health else { return }
        health = status
        if status == .unreachable {
            triggerFailoverIfNeeded()
        }
    }

    private enum FailoverTarget {
        case dhcp
        case profile(DNSProfile)
    }

    private func resolvedFailoverTarget() -> FailoverTarget {
        let raw = UserDefaults.standard.string(forKey: PreferenceKeys.failoverTarget) ?? "dhcp"
        if let uuid = UUID(uuidString: raw),
           let profile = profileStore.profiles.first(where: { $0.id == uuid }) {
            return .profile(profile)
        }
        return .dhcp
    }

    private func triggerFailoverIfNeeded() {
        guard UserDefaults.standard.bool(forKey: PreferenceKeys.failoverEnabled),
              failover == nil,
              let original = activeProfile,
              let watchServer = original.servers.first else { return }

        let target = resolvedFailoverTarget()
        if case .profile(let fallback) = target, fallback.id == original.id {
            return // la cible de secours EST le profil en panne : rien à faire
        }
        let fallbackDescription: String
        switch target {
        case .dhcp: fallbackDescription = "DHCP (auto)"
        case .profile(let fallback): fallbackDescription = fallback.name
        }
        let state = FailoverState(
            originalProfileID: original.id,
            originalProfileName: original.name,
            watchServer: watchServer,
            fallbackDescription: fallbackDescription
        )

        Task.detached(priority: .userInitiated) { [dnsManager] in
            guard let service = dnsManager.activeService()?.name else { return }
            let applied: Bool
            switch target {
            case .dhcp:
                applied = dnsManager.resetToDHCPPasswordless(service: service)
            case .profile(let fallback):
                applied = dnsManager.applyPasswordless(servers: fallback.servers, service: service)
            }
            await MainActor.run {
                if applied {
                    self.failover = state
                    self.startRecoveryTimer()
                    NotificationManager.shared.post(
                        title: "DNS Pilot — failover",
                        body: "\(state.originalProfileName) ne répond plus. Basculé sur \(state.fallbackDescription)."
                    )
                    self.refresh()
                } else {
                    NotificationManager.shared.post(
                        title: "DNS Pilot",
                        body: "\(state.originalProfileName) ne répond plus — failover impossible sans autorisation admin mémorisée (Préférences › Général)."
                    )
                }
            }
        }
    }

    private func startRecoveryTimer() {
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkRecovery() }
        }
    }

    private func checkRecovery() {
        guard let failover else {
            recoveryTimer?.invalidate()
            recoveryTimer = nil
            return
        }
        guard let original = profileStore.profiles.first(where: { $0.id == failover.originalProfileID }) else {
            clearFailover() // profil supprimé entre-temps
            return
        }
        healthChecker.probeOnce(server: failover.watchServer) { [weak self] reachable in
            guard reachable else { return }
            Task { @MainActor in
                guard let self, self.failover == failover else { return }
                self.restoreAfterRecovery(original)
            }
        }
    }

    private func restoreAfterRecovery(_ original: DNSProfile) {
        Task.detached(priority: .userInitiated) { [dnsManager] in
            guard let service = dnsManager.activeService()?.name else { return }
            if dnsManager.applyPasswordless(servers: original.servers, service: service) {
                await MainActor.run {
                    self.clearFailover()
                    NotificationManager.shared.post(
                        title: "DNS Pilot — rétabli",
                        body: "\(original.name) répond de nouveau. Profil rétabli."
                    )
                    self.refresh()
                }
            }
        }
    }

    private func clearFailover() {
        failover = nil
        recoveryTimer?.invalidate()
        recoveryTimer = nil
    }

    // MARK: - AdGuard Home
    // L'instance est une config GLOBALE (une seule, Préférences › AdGuard Home).
    // La section du menu n'apparaît que si le DNS actif pointe vers elle
    // (correspondance par IP, avec résolution si l'URL utilise un nom d'hôte).

    func snoozeAdGuard(minutes: Int = 5) {
        setAdGuardProtection(enabled: false, durationMs: minutes * 60_000)
    }

    func resumeAdGuard() {
        setAdGuardProtection(enabled: true, durationMs: nil)
    }

    func openAdGuardUI() {
        guard let info = adguardInfo else { return }
        NSWorkspace.shared.open(info.baseURL)
    }

    /// Force une resynchronisation (utilisé par les Préférences après un test réussi).
    func refreshAdGuard() {
        refreshAdGuardInfo()
    }

    private func adguardClient() -> AdGuardClient? {
        guard let urlString = UserDefaults.standard.string(forKey: PreferenceKeys.adguardURL),
              !urlString.isEmpty,
              let baseURL = URL(string: urlString), baseURL.host != nil else { return nil }
        return AdGuardClient(
            baseURL: baseURL,
            username: UserDefaults.standard.string(forKey: PreferenceKeys.adguardUsername),
            password: Keychain.password(account: Keychain.adguardAccount)
        )
    }

    private func refreshAdGuardInfo() {
        guard let client = adguardClient(), let host = client.baseURL.host, !currentServers.isEmpty else {
            adguardInfo = nil
            return
        }
        let servers = currentServers
        Task { [weak self] in
            guard let self else { return }
            let linked: Bool
            if servers.contains(host) {
                linked = true
            } else {
                let ips = await self.resolveIPs(for: host)
                linked = ips.contains(where: servers.contains)
            }
            guard linked else {
                self.adguardInfo = nil
                return
            }
            do {
                let status = try await client.status()
                let stats = try? await client.stats()
                self.adguardInfo = AdGuardInfo(
                    baseURL: client.baseURL,
                    protectionEnabled: status.protectionEnabled,
                    queries: stats?.queries,
                    blocked: stats?.blocked
                )
            } catch AdGuardError.unauthorized {
                self.adguardInfo = AdGuardInfo(baseURL: client.baseURL, authRequired: true)
            } catch {
                self.adguardInfo = nil // injoignable : section masquée
            }
        }
    }

    private func resolveIPs(for host: String) async -> [String] {
        if let cached = resolvedHostCache[host] { return cached }
        let ips = await Task.detached(priority: .utility) {
            AdGuardClient.resolveIPs(host: host)
        }.value
        resolvedHostCache[host] = ips
        return ips
    }

    private func setAdGuardProtection(enabled: Bool, durationMs: Int?) {
        guard let client = adguardClient() else { return }
        Task { [weak self] in
            do {
                try await client.setProtection(enabled: enabled, durationMs: durationMs)
            } catch {
                await MainActor.run {
                    self?.presentError("AdGuard Home : \(error.localizedDescription)")
                }
            }
            await MainActor.run { self?.refreshAdGuardInfo() }
            // La protection se réactive côté serveur à la fin de la pause :
            // on resynchronise le menu à ce moment-là.
            if let durationMs, !enabled {
                try? await Task.sleep(for: .milliseconds(durationMs + 5_000))
                await MainActor.run { self?.refreshAdGuardInfo() }
            }
        }
    }

    /// Détection automatique : tant qu'aucune instance n'est configurée, on sonde
    /// le serveur DNS actif ; s'il héberge un AdGuard Home, l'URL est préremplie.
    /// Une seule tentative par hôte et par session.
    private func detectAdGuardIfNeeded() {
        let existing = UserDefaults.standard.string(forKey: PreferenceKeys.adguardURL) ?? ""
        guard existing.isEmpty,
              let host = currentServers.first,
              !adguardDetectionTriedHosts.contains(host) else { return }
        adguardDetectionTriedHosts.insert(host)
        Task { [weak self] in
            guard let url = await AdGuardClient.detect(host: host) else { return }
            await MainActor.run {
                UserDefaults.standard.set(url.absoluteString, forKey: PreferenceKeys.adguardURL)
                self?.refreshAdGuardInfo()
            }
        }
    }

    // MARK: - Interne

    private func update(serviceName: String?, servers: [String], passwordless: Bool) {
        self.serviceName = serviceName
        self.currentServers = servers
        self.passwordlessConfigured = passwordless
        if let primary = servers.first {
            healthChecker.start(server: primary)
        } else {
            healthChecker.stop()
        }
        detectAdGuardIfNeeded()
        refreshAdGuardInfo()
    }

    private func runAction(_ operation: @escaping (DNSManager) throws -> Void) {
        isBusy = true
        Task.detached(priority: .userInitiated) { [dnsManager] in
            let failure = Self.perform { try operation(dnsManager) }
            await MainActor.run { self.finishAction(failure: failure) }
        }
    }

    private func runPrivilegedAction(_ operation: @escaping (DNSManager, String) throws -> Void) {
        isBusy = true
        Task.detached(priority: .userInitiated) { [dnsManager] in
            let failure = Self.perform {
                guard let service = dnsManager.activeService()?.name else {
                    throw DNSManagerError.noActiveService
                }
                try operation(dnsManager, service)
            }
            await MainActor.run { self.finishAction(failure: failure) }
        }
    }

    /// Exécute l'opération et renvoie un message d'erreur à afficher, ou nil.
    /// L'annulation par l'utilisateur (boîte admin) est silencieuse.
    private nonisolated static func perform(_ operation: () throws -> Void) -> String? {
        do {
            try operation()
            return nil
        } catch DNSManagerError.userCancelled {
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func finishAction(failure: String?) {
        isBusy = false
        if let failure { presentError(failure) }
        refresh()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "DNS Pilot"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
