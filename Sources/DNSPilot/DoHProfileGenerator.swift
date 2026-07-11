import Foundation

/// Génère un profil de configuration système (.mobileconfig) DNS-over-HTTPS
/// (payload `com.apple.dnsSettings.managed`) à partir d'un profil DNS Pilot.
///
/// macOS n'offre aucune API pour installer un tel profil silencieusement
/// (hors MDM) : le fichier est écrit dans Téléchargements puis ouvert, et
/// l'utilisateur termine l'installation dans Réglages Système › Général ›
/// Gestion des appareils. Une fois installé, le DoH prend le pas sur les DNS
/// classiques (`networksetup`) pour tout le système.
enum DoHProfileGenerator {

    enum GeneratorError: LocalizedError {
        case missingOrInvalidURL
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingOrInvalidURL:
                return "L'URL DoH doit commencer par https:// (ex. https://dns.adguard.com/dns-query)."
            case .writeFailed(let message):
                return "Impossible d'écrire le fichier .mobileconfig : \(message)"
            }
        }
    }

    /// Écrit le .mobileconfig dans ~/Downloads et renvoie son URL.
    static func generate(for profile: DNSProfile) throws -> URL {
        guard let dohURL = profile.dohURL?.trimmingCharacters(in: .whitespaces),
              dohURL.lowercased().hasPrefix("https://"),
              URL(string: dohURL) != nil else {
            throw GeneratorError.missingOrInvalidURL
        }

        var dnsSettings: [String: Any] = [
            "DNSProtocol": "HTTPS",
            "ServerURL": dohURL,
        ]
        // Les IP du profil servent d'amorce (bootstrap) : le résolveur les utilise
        // pour joindre le serveur DoH sans dépendre d'un autre DNS.
        let bootstrapIPs = profile.servers.filter(DNSManager.isValidServerAddress)
        if !bootstrapIPs.isEmpty {
            dnsSettings["ServerAddresses"] = bootstrapIPs
        }

        let identifier = "com.fabien.dns-pilot.doh.\(slug(for: profile.name))"
        let payload: [String: Any] = [
            "PayloadType": "com.apple.dnsSettings.managed",
            "PayloadVersion": 1,
            "PayloadIdentifier": "\(identifier).payload",
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "DNS over HTTPS — \(profile.name)",
            "DNSSettings": dnsSettings,
        ]
        let root: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": identifier,
            "PayloadUUID": UUID().uuidString,
            "PayloadDisplayName": "DNS Pilot — \(profile.name) (DoH)",
            "PayloadDescription": "Résolution DNS chiffrée (DoH) via \(dohURL), généré par DNS Pilot.",
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [payload],
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            let fileURL = downloads.appendingPathComponent("DNSPilot-\(slug(for: profile.name))-doh.mobileconfig")
            try data.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            throw GeneratorError.writeFailed(error.localizedDescription)
        }
    }

    private static func slug(for name: String) -> String {
        let folded = name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let mapped = folded.map { character -> Character in
            (character.isLetter || character.isNumber) ? character : "-"
        }
        return String(mapped)
    }
}
