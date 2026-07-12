import Foundation
import Combine
import Network

/// Vérifie périodiquement (60 s) que le DNS actif répond, en envoyant une
/// vraie requête DNS UDP (A apple.com) sur le port 53 — aucune dépendance,
/// pas de shell. Si le profil actif a une URL DoH, l'endpoint HTTPS est
/// sondé en parallèle (requête application/dns-message, RFC 8484).
final class HealthChecker: ObservableObject {

    enum Status: Equatable {
        case unknown      // pas de DNS custom actif, ou premier check en cours
        case healthy
        case unreachable
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var dohStatus: Status = .unknown

    private(set) var monitoredServer: String?
    private(set) var monitoredDoHURL: URL?
    private var timer: Timer?
    private let queue = DispatchQueue(label: "dnspilot.healthcheck")
    private let checkInterval: TimeInterval = 60
    private let timeout: TimeInterval = 2.5

    private lazy var dohSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        return URLSession(configuration: config)
    }()

    /// À appeler depuis le main thread (le Timer s'accroche à la runloop courante).
    func start(server: String, dohURL: URL? = nil) {
        guard server != monitoredServer || dohURL != monitoredDoHURL || timer == nil else { return }
        stop()
        monitoredServer = server
        monitoredDoHURL = dohURL
        check()
        let timer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.check()
        }
        timer.tolerance = 5
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitoredServer = nil
        monitoredDoHURL = nil
        status = .unknown
        dohStatus = .unknown
    }

    private func check() {
        if let server = monitoredServer { checkServer(server) }
        if let url = monitoredDoHURL { checkDoH(url) }
    }

    private func checkServer(_ server: String) {
        probeOnce(server: server) { [weak self] reachable in
            if reachable {
                self?.publish(.healthy, for: server)
                return
            }
            // Une requête UDP peut se perdre : on confirme avant d'alerter
            // (et potentiellement de déclencher un failover).
            self?.probeOnce(server: server) { confirmed in
                self?.publish(confirmed ? .healthy : .unreachable, for: server)
            }
        }
    }

    private func checkDoH(_ url: URL) {
        probeDoHOnce(url: url) { [weak self] reachable in
            if reachable {
                self?.publishDoH(.healthy, for: url)
                return
            }
            // Même politique que l'UDP : deux échecs d'affilée avant d'alerter.
            self?.probeDoHOnce(url: url) { confirmed in
                self?.publishDoH(confirmed ? .healthy : .unreachable, for: url)
            }
        }
    }

    private func publish(_ newStatus: Status, for server: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.monitoredServer == server else { return }
            self.status = newStatus
        }
    }

    private func publishDoH(_ newStatus: Status, for url: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.monitoredDoHURL == url else { return }
            self.dohStatus = newStatus
        }
    }

    /// Sonde un endpoint DoH : POST application/dns-message (RFC 8484) avec la
    /// même question A apple.com que l'UDP, réponse validée par l'ID écho.
    private func probeDoHOnce(url: URL, completion: @escaping (Bool) -> Void) {
        let queryID = UInt16.random(in: 1...UInt16.max)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Self.dnsQuery(id: queryID, host: "apple.com")

        let task = dohSession.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, data.count >= 12 else {
                completion(false)
                return
            }
            let bytes = [UInt8](data.prefix(2))
            let responseID = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            completion(responseID == queryID)
        }
        task.resume()
    }

    /// Envoie une requête DNS au serveur et attend une réponse dans le délai imparti.
    /// Publique : sert aussi au failover pour surveiller le retour du serveur d'origine.
    func probeOnce(server: String, completion: @escaping (Bool) -> Void) {
        measureLatency(server: server) { completion($0 != nil) }
    }

    /// Comme `probeOnce`, mais renvoie le temps de réponse (nil = pas de réponse valide).
    /// Tout (état, timeout, réception) s'exécute sur `queue` — pas de course sur `finished`.
    func measureLatency(server: String, completion: @escaping (TimeInterval?) -> Void) {
        let connection = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        let queryID = UInt16.random(in: 1...UInt16.max)
        var finished = false
        var sentAt: DispatchTime?
        let finish: (TimeInterval?) -> Void = { elapsed in
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(elapsed)
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                sentAt = DispatchTime.now()
                connection.send(
                    content: Self.dnsQuery(id: queryID, host: "apple.com"),
                    completion: .contentProcessed { error in
                        if error != nil { finish(nil) }
                    }
                )
                connection.receiveMessage { data, _, _, _ in
                    guard let data, data.count >= 12 else {
                        finish(nil)
                        return
                    }
                    let bytes = [UInt8](data.prefix(2))
                    let responseID = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                    guard responseID == queryID, let sentAt else {
                        finish(nil)
                        return
                    }
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - sentAt.uptimeNanoseconds) / 1_000_000_000
                    finish(elapsed)
                }
            case .failed:
                finish(nil)
            default:
                break
            }
        }

        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }

    /// Construit un paquet de requête DNS minimal (question A/IN, récursion demandée).
    private static func dnsQuery(id: UInt16, host: String) -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8(id >> 8), UInt8(id & 0xFF)])
        data.append(contentsOf: [0x01, 0x00])                          // flags : RD
        data.append(contentsOf: [0x00, 0x01])                          // QDCOUNT = 1
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // AN/NS/AR = 0
        for label in host.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: Array(label.utf8))
        }
        data.append(0x00)
        data.append(contentsOf: [0x00, 0x01, 0x00, 0x01])              // QTYPE=A, QCLASS=IN
        return data
    }
}
