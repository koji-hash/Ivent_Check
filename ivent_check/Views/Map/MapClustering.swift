import Foundation
import MapKit

/// F-EVT-04 ピンのクラスタリング
struct MapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let hits: [EventHit]
}

enum ClusterEngine {
    /// 表示範囲を divisions × divisions のグリッドに区切り、同じセルのピンを1つにまとめる
    static func clusters(for hits: [EventHit], in region: MKCoordinateRegion?, divisions: Double = 7) -> [MapCluster] {
        guard let region, region.span.latitudeDelta > 0, region.span.longitudeDelta > 0 else {
            return hits.map { single($0) }
        }
        let cellLat = region.span.latitudeDelta / divisions
        let cellLon = region.span.longitudeDelta / divisions

        var buckets: [String: [EventHit]] = [:]
        for hit in hits {
            let key = "\(Int((hit.event.latitude / cellLat).rounded(.down))):\(Int((hit.event.longitude / cellLon).rounded(.down)))"
            buckets[key, default: []].append(hit)
        }
        return buckets.map { key, members in
            guard members.count > 1 else { return single(members[0]) }
            let lat = members.map(\.event.latitude).reduce(0, +) / Double(members.count)
            let lon = members.map(\.event.longitude).reduce(0, +) / Double(members.count)
            return MapCluster(id: "cluster-\(key)", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), hits: members)
        }
        .sorted { $0.id < $1.id }
    }

    private static func single(_ hit: EventHit) -> MapCluster {
        MapCluster(id: hit.id.uuidString, coordinate: hit.event.coordinate, hits: [hit])
    }
}
