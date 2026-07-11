import Foundation
import AppKit
import CryptoKit

/// Une mise à jour publiée sur les GitHub Releases du projet.
struct AppUpdate: Equatable {
    let version: String     // "1.2.0" (tag sans le « v »)
    let releasePage: URL    // page de la Release (notes de version)
    let dmgURL: URL         // asset DNS-Pilot-X.Y.Z.dmg
    let dmgName: String
    let checksumsURL: URL?  // asset checksums.txt publié par la CI
}

enum UpdaterError: LocalizedError {
    case notBundled
    case translocated
    case notWritable(String)
    case http(Int)
    case invalidResponse
    case dmgAssetMissing
    case checksumsMissing
    case checksumMismatch
    case mountFailed(String)
    case appNotFoundInDMG
    case unexpectedVersion(String)

    var errorDescription: String? {
        switch self {
        case .notBundled:
            return "Mise à jour impossible hors du bundle .app (lancement via swift run)."
        case .translocated:
            return "L'app tourne depuis un emplacement temporaire (translocation Gatekeeper) — déplacez « DNS Pilot.app » dans Applications et relancez-la."
        case .notWritable(let path):
            return "Le dossier \(path) n'est pas modifiable — mise à jour manuelle requise."
        case .http(let code):
            return "GitHub a répondu HTTP \(code)."
        case .invalidResponse:
            return "Réponse inattendue de l'API GitHub."
        case .dmgAssetMissing:
            return "Aucun DMG attaché à la dernière Release."
        case .checksumsMissing:
            return "checksums.txt absent de la Release — mise à jour refusée."
        case .checksumMismatch:
            return "Le SHA-256 du DMG téléchargé ne correspond pas à checksums.txt — mise à jour abandonnée."
        case .mountFailed(let message):
            return "Impossible de monter le DMG : \(message)"
        case .appNotFoundInDMG:
            return "Aucune app trouvée dans le DMG."
        case .unexpectedVersion(let found):
            return "Le DMG contient la version \(found), pas celle annoncée — mise à jour abandonnée."
        }
    }
}

/// Mises à jour automatiques via les GitHub Releases.
///
/// - Vérification : au lancement puis toutes les 24 h (silencieuse, une requête
///   à l'API GitHub), et à la demande depuis les Préférences. Une nouvelle
///   version déclenche une notification (une seule fois par version) et fait
///   apparaître une entrée dans le menu.
/// - Installation (toujours sur un clic explicite, jamais d'office) :
///   téléchargement du DMG, SHA-256 vérifié contre le checksums.txt de la
///   Release, montage, contrôle de la version du bundle, puis un script
///   détaché échange les bundles à la fermeture de l'app et la relance.
///   L'attribut quarantine est retiré au passage : pas de blocage Gatekeeper,
///   contrairement au premier lancement manuel d'un DMG téléchargé.
@MainActor
final class Updater: ObservableObject {

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppUpdate)
        case downloading(AppUpdate)
        case installing(AppUpdate)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?

    private var checkTimer: Timer?

    init() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutomatically() }
        }
        // Vérification de lancement différée : le temps que le réseau s'établisse.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.checkAutomatically()
        }
    }

    var availableUpdate: AppUpdate? {
        switch state {
        case .available(let update), .downloading(let update), .installing(let update):
            return update
        default:
            return nil
        }
    }

    var isInstalling: Bool {
        switch state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .checking: return "Vérification…"
        case .upToDate: return "DNS Pilot est à jour (\(AppInfo.version))."
        case .available(let update): return "Version \(update.version) disponible."
        case .downloading: return "Téléchargement de la mise à jour…"
        case .installing: return "Installation — l'app va se relancer…"
        case .failed(let message): return message
        }
    }

    // MARK: - Vérification

    /// Vérification manuelle (Préférences) : l'état reflète la progression.
    func checkNow() {
        guard !isInstalling else { return }
        state = .checking
        Task { await self.performCheck(userInitiated: true) }
    }

    /// Vérification silencieuse (lancement + toutes les 24 h) : ne touche à
    /// l'état qu'en cas de réponse — un échec réseau ne perturbe rien.
    private func checkAutomatically() {
        guard UserDefaults.standard.bool(forKey: PreferenceKeys.updateCheck),
              AppInfo.isBundled, !isInstalling else { return }
        Task { await self.performCheck(userInitiated: false) }
    }

    private func performCheck(userInitiated: Bool) async {
        do {
            let update = try await UpdateEngine.fetchAvailableUpdate()
            guard !isInstalling else { return } // une installation a démarré entre-temps
            lastCheck = Date()
            if let update {
                let firstSight = availableUpdate?.version != update.version
                state = .available(update)
                if !userInitiated, firstSight { notifyOnce(about: update) }
            } else {
                state = .upToDate
            }
        } catch {
            if userInitiated { state = .failed(error.localizedDescription) }
        }
    }

    /// Une seule notification par version : la découverte quotidienne de la
    /// même Release ne doit pas spammer.
    private func notifyOnce(about update: AppUpdate) {
        guard UserDefaults.standard.string(forKey: PreferenceKeys.lastNotifiedUpdate) != update.version else { return }
        UserDefaults.standard.set(update.version, forKey: PreferenceKeys.lastNotifiedUpdate)
        NotificationManager.shared.post(
            title: "DNS Pilot",
            body: "Version \(update.version) disponible — installez-la depuis le menu."
        )
    }

    // MARK: - Installation

    /// Télécharge, vérifie et installe la mise à jour ; l'app se relance seule.
    func installAvailableUpdate() {
        guard let update = availableUpdate, !isInstalling else { return }
        guard AppInfo.isBundled else {
            state = .failed(UpdaterError.notBundled.localizedDescription)
            return
        }
        let bundleURL = Bundle.main.bundleURL
        guard !bundleURL.path.contains("/AppTranslocation/") else {
            state = .failed(UpdaterError.translocated.localizedDescription)
            return
        }
        // Le swap exige d'écrire dans le dossier parent du bundle (mv).
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            state = .failed(UpdaterError.notWritable(parent.path).localizedDescription)
            return
        }

        state = .downloading(update)
        Task { [weak self] in
            do {
                let staged = try await UpdateEngine.downloadAndStage(update)
                self?.state = .installing(update)
                try UpdateEngine.launchSwapScript(staged: staged, target: bundleURL)
                try? await Task.sleep(for: .milliseconds(300))
                NSApp.terminate(nil)
            } catch {
                self?.state = .failed(error.localizedDescription)
            }
        }
    }

    func openReleasePage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.releasePage)
    }
}

// MARK: - Moteur (hors main actor) : API GitHub, téléchargement, vérification, swap

private enum UpdateEngine {

    /// Dépôt GitHub dont les Releases servent de canal de mise à jour.
    static let repo = "FabienVINCENT/DNS-Pilot"

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let downloadURL: URL

            enum CodingKeys: String, CodingKey {
                case name
                case downloadURL = "browser_download_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    /// Interroge la dernière Release (les préversions et brouillons sont
    /// exclus par l'API). Renvoie nil si la version courante est à jour.
    static func fetchAvailableUpdate() async throws -> AppUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdaterError.invalidResponse }
        guard http.statusCode == 200 else { throw UpdaterError.http(http.statusCode) }
        guard let release = try? JSONDecoder().decode(Release.self, from: data) else {
            throw UpdaterError.invalidResponse
        }

        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isVersion(version, newerThan: AppInfo.version) else { return nil }
        guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            throw UpdaterError.dmgAssetMissing
        }
        return AppUpdate(
            version: version,
            releasePage: release.htmlURL,
            dmgURL: dmg.downloadURL,
            dmgName: dmg.name,
            checksumsURL: release.assets.first { $0.name == "checksums.txt" }?.downloadURL
        )
    }

    /// Comparaison numérique composant par composant ("1.10.0" > "1.9.2").
    /// Tout composant non numérique vaut 0 — la version "dev" (swift run)
    /// est donc toujours dépassée, mais l'installation y est bloquée par ailleurs.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ string: String) -> [Int] {
            string.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Télécharge le DMG, vérifie son SHA-256 contre le checksums.txt de la
    /// Release, monte l'image, contrôle la version du bundle et le copie dans
    /// un dossier de travail temporaire. Renvoie l'URL du bundle prêt à poser.
    static func downloadAndStage(_ update: AppUpdate) async throws -> URL {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DNSPilot-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        do {
            return try await stage(update, in: workDir)
        } catch {
            try? FileManager.default.removeItem(at: workDir)
            throw error
        }
    }

    private static func stage(_ update: AppUpdate, in workDir: URL) async throws -> URL {
        let (downloaded, response) = try await session.download(from: update.dmgURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdaterError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let dmg = workDir.appendingPathComponent(update.dmgName)
        try FileManager.default.moveItem(at: downloaded, to: dmg)

        // Intégrité : le DMG doit correspondre au checksum publié par la CI.
        guard let checksumsURL = update.checksumsURL else { throw UpdaterError.checksumsMissing }
        let (checksumsData, _) = try await session.data(from: checksumsURL)
        guard let expected = expectedChecksum(in: checksumsData, for: update.dmgName) else {
            throw UpdaterError.checksumsMissing
        }
        guard try sha256Hex(of: dmg) == expected else { throw UpdaterError.checksumMismatch }

        let mountPoint = workDir.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let attach = DNSManager.run("/usr/bin/hdiutil", [
            "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
            "-mountpoint", mountPoint.path,
        ])
        guard attach.status == 0 else {
            throw UpdaterError.mountFailed(attach.err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer { DNSManager.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }

        let contents = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let appInDMG = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdaterError.appNotFoundInDMG
        }

        // Le bundle téléchargé doit annoncer la version promise par la Release.
        let plistURL = appInDMG.appendingPathComponent("Contents/Info.plist")
        let stagedVersion = (try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), options: [], format: nil
        ) as? [String: Any])?["CFBundleShortVersionString"] as? String
        guard stagedVersion == update.version else {
            throw UpdaterError.unexpectedVersion(stagedVersion ?? "inconnue")
        }

        let staged = workDir.appendingPathComponent(appInDMG.lastPathComponent)
        try FileManager.default.copyItem(at: appInDMG, to: staged)
        // Défensif : aucun attribut quarantine ne doit gêner le premier lancement.
        DNSManager.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// Format `shasum -a 256` : "<hex>  <fichier>" (parfois "*<fichier>" en mode binaire).
    static func expectedChecksum(in data: Data, for fileName: String) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count >= 2, parts.last == fileName || parts.last == "*\(fileName)" {
                return parts.first?.lowercased()
            }
        }
        return nil
    }

    static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Remplacer le bundle d'une app en cours d'exécution est impossible
    /// proprement : un script détaché attend la fin du processus, échange les
    /// bundles (l'ancien est restauré si la pose échoue), puis relance l'app.
    /// Aucun privilège requis : le bundle appartient à l'utilisateur.
    static func launchSwapScript(staged: URL, target: URL) throws {
        let script = """
        #!/bin/sh
        PID="$1"; STAGED="$2"; TARGET="$3"
        i=0
        while /bin/kill -0 "$PID" 2>/dev/null; do
          /bin/sleep 0.2
          i=$((i+1)); [ "$i" -gt 150 ] && exit 1
        done
        OLD="$TARGET.old.$$"
        /bin/mv "$TARGET" "$OLD" || { /usr/bin/open "$TARGET"; exit 1; }
        if /bin/mv "$STAGED" "$TARGET" 2>/dev/null || /bin/cp -R "$STAGED" "$TARGET"; then
          /bin/rm -rf "$OLD"
        else
          /bin/mv "$OLD" "$TARGET"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        /usr/bin/open "$TARGET"
        exec /bin/rm -rf "$(/usr/bin/dirname "$STAGED")"
        """
        let scriptURL = staged.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            target.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
