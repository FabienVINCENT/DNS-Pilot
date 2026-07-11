import Foundation
import Combine

/// Charge et persiste les profils DNS dans
/// ~/Library/Application Support/DNSPilot/profiles.json
final class ProfileStore: ObservableObject {

    @Published var profiles: [DNSProfile] = [] {
        didSet { save() }
    }

    static let directoryURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DNSPilot", isDirectory: true)

    static let fileURL: URL = directoryURL.appendingPathComponent("profiles.json")

    private static let defaultProfiles: [DNSProfile] = [
        DNSProfile(name: "AdGuard Home", servers: ["192.168.1.104"]),
        DNSProfile(name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"]),
    ]

    init() {
        if let loaded = Self.loadFromDisk() {
            profiles = loaded
        } else {
            profiles = Self.defaultProfiles
            save()
        }
    }

    private static func loadFromDisk() -> [DNSProfile]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([DNSProfile].self, from: data)
        } catch {
            // Fichier corrompu : on le met de côté plutôt que de l'écraser.
            NSLog("DNSPilot: profiles.json illisible (%@), sauvegarde en .bak", String(describing: error))
            let backup = fileURL.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            return nil
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("DNSPilot: échec de l'enregistrement des profils — %@", String(describing: error))
        }
    }
}
