import Foundation

enum DNSManagerError: LocalizedError {
    case userCancelled
    case invalidServer(String)
    case noActiveService
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "Opération annulée."
        case .invalidServer(let server):
            return "Adresse de serveur DNS invalide : \(server)"
        case .noActiveService:
            return "Aucune interface réseau active n'a été détectée."
        case .commandFailed(let message):
            return "La commande a échoué : \(message)"
        }
    }
}

/// Un service réseau macOS (entrée de Réglages Système > Réseau).
struct NetworkService: Equatable {
    let name: String    // ex. "Wi-Fi"
    let device: String  // ex. "en0"
}

/// Lit et applique la configuration DNS via `networksetup`.
///
/// - Lecture : sans privilèges.
/// - Écriture : `sudo -n` via la règle sudoers installée par l'app (aucune interaction),
///   sinon AppleScript `do shell script … with administrator privileges`.
///   Lors de cette unique invite admin, la règle sudoers est installée dans la foulée
///   (si la préférence « mémoriser » est active) : le mot de passe n'est demandé qu'une fois.
final class DNSManager {

    private let networksetupPath = "/usr/sbin/networksetup"
    static let sudoersFilePath = "/etc/sudoers.d/dns-pilot"

    // MARK: - Lecture (non privilégiée)

    /// Service réseau actuellement utilisé pour le trafic sortant.
    ///
    /// Stratégie : interface de la route par défaut, mappée sur l'ordre des
    /// services système. Si la route par défaut passe par un tunnel
    /// (utun* : VPN, Tailscale…), on retombe sur le premier service actif
    /// (celui qui porte une adresse IP) dans l'ordre système.
    func activeService() -> NetworkService? {
        let services = listEnabledServices()
        guard !services.isEmpty else { return nil }

        if let iface = defaultRouteInterface(),
           let match = services.first(where: { $0.device == iface }) {
            return match
        }
        return services.first { hasIPAddress(device: $0.device) } ?? services.first
    }

    /// Serveurs DNS configurés manuellement sur un service. Vide = DHCP.
    func currentDNSServers(service: String) -> [String] {
        let result = Self.run(networksetupPath, ["-getdnsservers", service])
        // Sortie DHCP : "There aren't any DNS Servers set on Wi-Fi."
        return result.out
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Self.isValidServerAddress($0) }
    }

    /// Services réseau activés, dans l'ordre de priorité système.
    func listEnabledServices() -> [NetworkService] {
        let output = Self.run(networksetupPath, ["-listnetworkserviceorder"]).out
        var services: [NetworkService] = []
        var pendingName: String?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(*)") {
                pendingName = nil // service désactivé
            } else if line.range(of: #"^\(\d+\) "#, options: .regularExpression) != nil {
                pendingName = String(line.drop(while: { $0 != " " }).dropFirst())
            } else if let name = pendingName,
                      line.hasPrefix("(Hardware Port:"),
                      let deviceRange = line.range(of: "Device: ") {
                let device = String(line[deviceRange.upperBound...])
                    .replacingOccurrences(of: ")", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    services.append(NetworkService(name: name, device: device))
                }
                pendingName = nil
            }
        }
        return services
    }

    private func defaultRouteInterface() -> String? {
        let output = Self.run("/sbin/route", ["-n", "get", "default"]).out
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("interface:") {
                return trimmed
                    .replacingOccurrences(of: "interface:", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func hasIPAddress(device: String) -> Bool {
        let result = Self.run("/usr/sbin/ipconfig", ["getifaddr", device])
        return !result.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Écriture (privilégiée)

    func apply(servers: [String], service: String) throws {
        guard !servers.isEmpty else { throw DNSManagerError.invalidServer("(liste vide)") }
        for server in servers where !Self.isValidServerAddress(server) {
            throw DNSManagerError.invalidServer(server)
        }
        try runPrivileged([[networksetupPath, "-setdnsservers", service] + servers])
    }

    func resetToDHCP(service: String) throws {
        try runPrivileged([[networksetupPath, "-setdnsservers", service, "Empty"]])
    }

    func flushCache() throws {
        try runPrivileged([
            ["/usr/bin/dscacheutil", "-flushcache"],
            ["/usr/bin/killall", "-HUP", "mDNSResponder"],
        ])
    }

    /// Applique un profil sans AUCUNE interaction (`sudo -n` uniquement).
    /// Utilisé par la bascule automatique et le failover : jamais de boîte de dialogue.
    /// Renvoie false si la règle sudoers n'est pas en place.
    func applyPasswordless(servers: [String], service: String) -> Bool {
        guard !servers.isEmpty, servers.allSatisfy(Self.isValidServerAddress) else { return false }
        return runWithPasswordlessSudo([[networksetupPath, "-setdnsservers", service] + servers])
    }

    /// Retour au DHCP sans interaction (`sudo -n` uniquement) — cible de failover par défaut.
    func resetToDHCPPasswordless(service: String) -> Bool {
        runWithPasswordlessSudo([[networksetupPath, "-setdnsservers", service, "Empty"]])
    }

    // MARK: - Règle sudoers (mot de passe demandé une seule fois)

    func isPasswordlessConfigured() -> Bool {
        if FileManager.default.fileExists(atPath: Self.sudoersFilePath) { return true }
        return Self.run("/usr/bin/sudo", ["-n", "-l", networksetupPath]).status == 0
    }

    /// Installe la règle sudoers immédiatement (une invite admin).
    func installPasswordlessRule() throws {
        guard let command = Self.sudoersInstallShellCommand() else {
            throw DNSManagerError.commandFailed("nom d'utilisateur incompatible avec sudoers")
        }
        try runWithAdministratorPrivileges(shellCommand: command)
    }

    /// Supprime la règle sudoers (une invite admin — `rm` n'est pas couvert par la règle).
    func removePasswordlessRule() throws {
        try runWithAdministratorPrivileges(shellCommand: "/bin/rm -f \(Self.sudoersFilePath)")
    }

    /// Script d'installation : écrit un fichier temporaire, le valide avec `visudo -c`
    /// puis le met en place — jamais de sudoers cassé, même en cas de bug.
    private static func sudoersInstallShellCommand() -> String? {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        let line = "\(user) ALL=(root) NOPASSWD: /usr/sbin/networksetup, /usr/bin/dscacheutil, /usr/bin/killall -HUP mDNSResponder"
        let tmp = "/etc/sudoers.d/.dns-pilot.tmp"
        return "/usr/bin/printf '%s\\n' '\(line)' > \(tmp)"
            + " && /bin/chmod 0440 \(tmp)"
            + " && /usr/sbin/visudo -c -q -f \(tmp)"
            + " && /bin/mv \(tmp) \(sudoersFilePath)"
            + " || { /bin/rm -f \(tmp); exit 1; }"
    }

    private var rememberAdminEnabled: Bool {
        UserDefaults.standard.object(forKey: PreferenceKeys.rememberAdmin) as? Bool ?? true
    }

    // MARK: - Exécution privilégiée

    /// Exécute une série de commandes avec les droits root :
    /// d'abord `sudo -n` (silencieux, fonctionne dès que la règle sudoers est en place),
    /// sinon tout le lot en une seule invite admin AppleScript — en y greffant
    /// l'installation de la règle sudoers pour ne plus jamais redemander le mot de passe.
    private func runPrivileged(_ commands: [[String]]) throws {
        if runWithPasswordlessSudo(commands) { return }
        var shell = Self.shellCommand(from: commands)
        if rememberAdminEnabled, !isPasswordlessConfigured(),
           let install = Self.sudoersInstallShellCommand() {
            // Un échec de la commande DNS doit remonter (exit 1) ; un échec
            // d'installation de la règle, lui, est silencieux (sous-shell ignoré).
            shell = "{ \(shell) ; } || exit 1 ; ( \(install) ) > /dev/null 2>&1 ; true"
        }
        try runWithAdministratorPrivileges(shellCommand: shell)
    }

    private func runWithPasswordlessSudo(_ commands: [[String]]) -> Bool {
        for argv in commands {
            let result = Self.run("/usr/bin/sudo", ["-n"] + argv)
            if result.status != 0 { return false }
        }
        return true
    }

    private static func shellCommand(from commands: [[String]]) -> String {
        commands
            .map { argv in argv.map(shellQuoted).joined(separator: " ") }
            .joined(separator: " && ")
    }

    private func runWithAdministratorPrivileges(shellCommand: String) throws {
        let script = """
        do shell script "\(Self.appleScriptEscaped(shellCommand))" \
        with administrator privileges \
        with prompt "DNS Pilot doit modifier la configuration réseau."
        """
        let result = Self.run("/usr/bin/osascript", ["-e", script])
        guard result.status == 0 else {
            let stderr = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.contains("-128") || stderr.localizedCaseInsensitiveContains("canceled") {
                throw DNSManagerError.userCancelled
            }
            throw DNSManagerError.commandFailed(stderr)
        }
    }

    // MARK: - Utilitaires

    /// IPv4 ou IPv6 uniquement — garantit qu'aucun contenu de profiles.json
    /// ne peut injecter autre chose dans la commande shell privilégiée.
    static func isValidServerAddress(_ string: String) -> Bool {
        guard !string.isEmpty, string.count <= 45, string.contains(where: { $0 == "." || $0 == ":" }) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF.:%")
        return string.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return ("", error.localizedDescription, -1)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }
}
