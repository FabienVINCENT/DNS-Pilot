import Foundation

enum AdGuardError: LocalizedError {
    case unauthorized
    case http(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "identifiants requis ou incorrects"
        case .http(let code): return "erreur HTTP \(code)"
        case .invalidResponse: return "réponse inattendue du serveur"
        }
    }
}

struct AdGuardStatus: Decodable {
    let protectionEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case protectionEnabled = "protection_enabled"
    }
}

struct AdGuardStats: Decodable {
    let queries: Int
    let blocked: Int

    enum CodingKeys: String, CodingKey {
        case queries = "num_dns_queries"
        case blocked = "num_blocked_filtering"
    }
}

private struct AdGuardQueryLog: Decodable {
    struct Entry: Decodable {
        struct Question: Decodable {
            let name: String
        }
        // Optionnel : une entrée atypique ne doit pas invalider tout le journal.
        let question: Question?
    }
    let data: [Entry]
}

private struct AdGuardFilteringStatus: Decodable {
    let userRules: [String]

    enum CodingKeys: String, CodingKey {
        case userRules = "user_rules"
    }
}

/// Client minimal de l'API AdGuard Home (auth HTTP Basic).
///
/// Endpoints utilisés :
/// - GET  /control/status            → protection activée ?
/// - GET  /control/stats             → requêtes / bloquées (fenêtre configurée côté AGH, 24 h par défaut)
/// - POST /control/protection        → activer / suspendre (avec durée en ms)
/// - GET  /control/querylog          → derniers domaines bloqués (response_status=blocked)
/// - GET  /control/filtering/status  → règles utilisateur existantes
/// - POST /control/filtering/set_rules → ajout d'une règle d'autorisation @@||domaine^
final class AdGuardClient {

    let baseURL: URL
    private let username: String?
    private let password: String?
    private let session: URLSession

    init(baseURL: URL, username: String?, password: String?) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.timeoutIntervalForResource = 6
        session = URLSession(configuration: config)
    }

    // MARK: - Détection automatique

    /// Sonde les ports web habituels d'AdGuard Home sur l'IP d'un serveur DNS.
    /// La page (interface ou écran de connexion) contient toujours « AdGuard Home ».
    static func detect(host: String) async -> URL? {
        let bracketed = host.contains(":") ? "[\(host)]" : host // IPv6
        let candidates = [
            "http://\(bracketed)",
            "http://\(bracketed):3000",
            "http://\(bracketed):8080",
        ]
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 4
        let session = URLSession(configuration: config)

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode < 500,
                  let body = String(data: data, encoding: .utf8),
                  body.contains("AdGuard Home") else { continue }
            return url
        }
        return nil
    }

    /// Résout un nom d'hôte en adresses IP (getaddrinfo, bloquant — à appeler hors main).
    /// Sert à associer l'instance AdGuard au DNS actif quand l'URL utilise un
    /// nom d'hôte (Tailscale MagicDNS, .local…) plutôt qu'une IP.
    static func resolveIPs(host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }

        var ips: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                ips.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return ips
    }

    // MARK: - API

    func status() async throws -> AdGuardStatus {
        try await get("control/status")
    }

    func stats() async throws -> AdGuardStats {
        try await get("control/stats")
    }

    /// `durationMs` : la protection se réactive d'elle-même côté serveur après ce délai.
    func setProtection(enabled: Bool, durationMs: Int?) async throws {
        var body: [String: Any] = ["enabled": enabled]
        if let durationMs, !enabled {
            body["duration"] = durationMs
        }
        _ = try await request(path: "control/protection", method: "POST", jsonBody: body)
    }

    /// Derniers domaines bloqués, dédupliqués, du plus récent au plus ancien.
    /// Journal désactivé côté serveur → liste vide (pas une erreur).
    func recentBlockedDomains(maxDomains: Int = 8) async throws -> [String] {
        let log: AdGuardQueryLog = try await get("control/querylog", queryItems: [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "response_status", value: "blocked"),
        ])
        var seen = Set<String>()
        var domains: [String] = []
        for entry in log.data {
            guard let domain = entry.question?.name.lowercased() else { continue }
            guard !domain.isEmpty, seen.insert(domain).inserted else { continue }
            domains.append(domain)
            if domains.count == maxDomains { break }
        }
        return domains
    }

    /// Débloque un domaine en ajoutant la règle d'autorisation `@@||domaine^`
    /// aux règles utilisateur (prioritaire sur les listes de blocage).
    func allow(domain: String) async throws {
        let rule = "@@||\(domain)^"
        let status: AdGuardFilteringStatus = try await get("control/filtering/status")
        var rules = status.userRules.filter { !$0.isEmpty }
        guard !rules.contains(rule) else { return }
        rules.append(rule)
        _ = try await request(path: "control/filtering/set_rules", method: "POST", jsonBody: ["rules": rules])
    }

    // MARK: - Interne

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path: path, queryItems: queryItems, method: "GET", jsonBody: nil)
        guard let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            throw AdGuardError.invalidResponse
        }
        return decoded
    }

    private func request(path: String, queryItems: [URLQueryItem] = [], method: String, jsonBody: [String: Any]?) async throws -> Data {
        var url = baseURL.appendingPathComponent(path)
        if !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            url = components.url ?? url
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        if let username, let password, !username.isEmpty {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            urlRequest.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AdGuardError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw AdGuardError.unauthorized
        default: throw AdGuardError.http(http.statusCode)
        }
    }
}
