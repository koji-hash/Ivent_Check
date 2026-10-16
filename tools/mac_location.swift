// この Mac の現在地（macOS の位置情報サービス）を「緯度,経度」で出力する。
// 使い方: tools/sim_here.sh から呼ばれる。初回は macOS が位置情報の利用許可を求める。
import CoreLocation
import Foundation

final class Locator: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            FileHandle.standardError.write("位置情報の利用が許可されていません（システム設定 > プライバシーとセキュリティ > 位置情報サービス）\n".data(using: .utf8)!)
            exit(2)
        default:
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        print(String(format: "%.6f,%.6f", location.coordinate.latitude, location.coordinate.longitude))
        FileHandle.standardError.write("精度: 約\(Int(location.horizontalAccuracy))m\n".data(using: .utf8)!)
        exit(0)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        FileHandle.standardError.write("位置を取得できませんでした: \(error.localizedDescription)\n".data(using: .utf8)!)
    }
}

let locator = Locator()
locator.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
    FileHandle.standardError.write("120秒以内に位置を取得できませんでした\n".data(using: .utf8)!)
    exit(1)
}
RunLoop.main.run()
