import Foundation
import Combine
import CoreLocation
import CoreWLAN

/// Lit le SSID du réseau Wi-Fi courant.
///
/// Depuis macOS 14, `CWInterface.ssid()` renvoie nil tant que l'app n'a pas
/// l'autorisation Localisation — le SSID est considéré comme une donnée de
/// position. L'autorisation se demande depuis les Préférences, et exige de
/// lancer l'app depuis le bundle .app (pas `swift run`).
final class SSIDProvider: NSObject, ObservableObject {

    @Published private(set) var currentSSID: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private lazy var locationManager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways
    }

    override init() {
        super.init()
        authorizationStatus = locationManager.authorizationStatus
        refresh()
    }

    /// À appeler sur le main thread.
    func refresh() {
        currentSSID = CWWiFiClient.shared().interface()?.ssid()
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }
}

extension SSIDProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        refresh()
    }
}
