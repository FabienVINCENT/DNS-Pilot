import Foundation

/// Un profil DNS applicable à l'interface réseau active.
struct DNSProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var servers: [String]

    /// Bascule automatique quand le Mac rejoint l'un de ces SSID.
    var autoSSIDs: [String]?
    /// URL DNS-over-HTTPS, appliquée via un profil système généré (.mobileconfig).
    var dohURL: String?

    // Note : l'instance AdGuard Home est une configuration GLOBALE (Préférences ›
    // AdGuard Home), pas une propriété de profil — l'association se fait par IP.

    enum CodingKeys: String, CodingKey {
        case id, name, servers, autoSSIDs, dohURL
    }

    init(
        id: UUID = UUID(),
        name: String,
        servers: [String],
        autoSSIDs: [String]? = nil,
        dohURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.servers = servers
        self.autoSSIDs = autoSSIDs
        self.dohURL = dohURL
    }

    // `id` optionnel au décodage : un profiles.json écrit à la main sans "id" reste valide.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        servers = try container.decode([String].self, forKey: .servers)
        autoSSIDs = try container.decodeIfPresent([String].self, forKey: .autoSSIDs)
        dohURL = try container.decodeIfPresent(String.self, forKey: .dohURL)
    }
}
