import Foundation
import CoreLocation
import Observation

/// 4.1 位置情報。常時GPSは使わず、前景での単発取得と Significant Location Change のみを使う
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var authorizationStatus: CLAuthorizationStatus
    private(set) var currentLocation: CLLocation?
    private(set) var lastError: Error?

    /// 大幅な位置変更を検知したときに呼ばれる（F-LOC-03）
    var onSignificantChange: ((CLLocation) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var isMonitoringSignificantChanges = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    func requestWhenInUse() {
        manager.requestWhenInUseAuthorization()
    }

    /// Always は通知機能（移動先でも検知）を使うときだけ要求する
    func requestAlways() {
        manager.requestAlwaysAuthorization()
    }

    func requestLocation() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    func startSignificantChanges() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable(), !isMonitoringSignificantChanges else { return }
        isMonitoringSignificantChanges = true
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopSignificantChanges() {
        guard isMonitoringSignificantChanges else { return }
        isMonitoringSignificantChanges = false
        manager.stopMonitoringSignificantLocationChanges()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            authorizationStatus = status
            if isAuthorized { requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        MainActor.assumeIsolated {
            let previous = currentLocation
            currentLocation = location
            lastError = nil
            if isMonitoringSignificantChanges, previous.map({ $0.distance(from: location) > 500 }) ?? true {
                onSignificantChange?(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            lastError = error
        }
    }
}
