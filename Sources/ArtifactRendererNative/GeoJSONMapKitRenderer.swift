import SwiftUI
import MapKit
import _MapKit_SwiftUI
import CoreLocation
import ArtifactCore
import ArtifactRenderer
import ArtifactView

/// Renders GeoJSON payloads on a SwiftUI `Map`. Supports `Point`, `LineString`,
/// and `Polygon` features at MVP scope; multi-geometries fall back to their
/// constituent parts.
public struct GeoJSONMapKitRenderer: ArtifactRenderable, Sendable {
    public static let artifactType: ArtifactType = .geoJSON

    public init() {}

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.payload.isEmpty { return .empty }
        // Partial JSON typically fails to parse, so wait for complete before
        // attempting to render geometry.
        return artifact.isComplete ? .complete : .streaming
    }

    public func body(artifact: AnyArtifact) -> some View {
        let features = GeoJSONParser.parse(artifact.payload)
        let region = MapRegionResolver.region(for: features, attributes: artifact.attributes)
        let initialPosition: MapCameraPosition = .region(region)
        return Map(initialPosition: initialPosition) {
            ForEach(features) { feature in
                switch feature.geometry {
                case .point(let coordinate):
                    Marker(feature.title ?? "", coordinate: coordinate)
                case .lineString(let coords):
                    MapPolyline(coordinates: coords)
                        .stroke(.blue, lineWidth: 2)
                case .polygon(let coords):
                    MapPolygon(coordinates: coords)
                        .foregroundStyle(.blue.opacity(0.25))
                        .stroke(.blue, lineWidth: 1)
                }
            }
        }
        .frame(minHeight: 240, maxHeight: 360)
    }
}

struct GeoJSONFeature: Identifiable {
    let id: UUID
    let geometry: Geometry
    let title: String?

    enum Geometry {
        case point(CLLocationCoordinate2D)
        case lineString([CLLocationCoordinate2D])
        case polygon([CLLocationCoordinate2D])
    }
}

enum GeoJSONParser {
    static func parse(_ source: String) -> [GeoJSONFeature] {
        guard let data = source.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
            return []
        }
        var features: [GeoJSONFeature] = []
        collect(object: root, title: nil, into: &features)
        return features
    }

    private static func collect(object: [String: Any], title: String?, into features: inout [GeoJSONFeature]) {
        guard let type = object["type"] as? String else { return }
        switch type {
        case "FeatureCollection":
            if let array = object["features"] as? [[String: Any]] {
                for entry in array {
                    collect(object: entry, title: nil, into: &features)
                }
            }
        case "Feature":
            let nestedTitle = (object["properties"] as? [String: Any])?["title"] as? String ?? title
            if let geom = object["geometry"] as? [String: Any] {
                collect(object: geom, title: nestedTitle, into: &features)
            }
        case "Point":
            if let coords = object["coordinates"] as? [Double],
               let coordinate = coordinate(from: coords) {
                features.append(GeoJSONFeature(id: UUID(), geometry: .point(coordinate), title: title))
            }
        case "MultiPoint":
            if let array = object["coordinates"] as? [[Double]] {
                for pair in array {
                    if let coordinate = coordinate(from: pair) {
                        features.append(GeoJSONFeature(id: UUID(), geometry: .point(coordinate), title: title))
                    }
                }
            }
        case "LineString":
            if let coords = object["coordinates"] as? [[Double]] {
                let path = coords.compactMap(coordinate(from:))
                if !path.isEmpty {
                    features.append(GeoJSONFeature(id: UUID(), geometry: .lineString(path), title: title))
                }
            }
        case "MultiLineString":
            if let lines = object["coordinates"] as? [[[Double]]] {
                for coords in lines {
                    let path = coords.compactMap(coordinate(from:))
                    if !path.isEmpty {
                        features.append(GeoJSONFeature(id: UUID(), geometry: .lineString(path), title: title))
                    }
                }
            }
        case "Polygon":
            if let rings = object["coordinates"] as? [[[Double]]],
               let outer = rings.first {
                let path = outer.compactMap(coordinate(from:))
                if !path.isEmpty {
                    features.append(GeoJSONFeature(id: UUID(), geometry: .polygon(path), title: title))
                }
            }
        case "MultiPolygon":
            if let polys = object["coordinates"] as? [[[[Double]]]] {
                for rings in polys {
                    if let outer = rings.first {
                        let path = outer.compactMap(coordinate(from:))
                        if !path.isEmpty {
                            features.append(GeoJSONFeature(id: UUID(), geometry: .polygon(path), title: title))
                        }
                    }
                }
            }
        case "GeometryCollection":
            if let geometries = object["geometries"] as? [[String: Any]] {
                for geom in geometries {
                    collect(object: geom, title: title, into: &features)
                }
            }
        default:
            break
        }
    }

    private static func coordinate(from pair: [Double]) -> CLLocationCoordinate2D? {
        guard pair.count >= 2 else { return nil }
        // GeoJSON ordering is [longitude, latitude].
        return CLLocationCoordinate2D(latitude: pair[1], longitude: pair[0])
    }
}

enum MapRegionResolver {
    static func region(
        for features: [GeoJSONFeature],
        attributes: [String: String]
    ) -> MKCoordinateRegion {
        if let lat = attributes["centerLatitude"].flatMap(Double.init),
           let lon = attributes["centerLongitude"].flatMap(Double.init) {
            let span = MKCoordinateSpan(
                latitudeDelta: attributes["latitudeDelta"].flatMap(Double.init) ?? 0.05,
                longitudeDelta: attributes["longitudeDelta"].flatMap(Double.init) ?? 0.05
            )
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                span: span
            )
        }
        return boundingRegion(for: features) ?? defaultRegion
    }

    private static func boundingRegion(for features: [GeoJSONFeature]) -> MKCoordinateRegion? {
        var minLat = Double.infinity
        var maxLat = -Double.infinity
        var minLon = Double.infinity
        var maxLon = -Double.infinity
        var found = false

        func consume(_ coordinate: CLLocationCoordinate2D) {
            found = true
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        for feature in features {
            switch feature.geometry {
            case .point(let coordinate):
                consume(coordinate)
            case .lineString(let coords), .polygon(let coords):
                coords.forEach(consume)
            }
        }
        guard found else { return nil }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.005, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private static var defaultRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 60, longitudeDelta: 60)
        )
    }
}

#Preview("Card — single point — Tokyo Station") {
    ArtifactCard(
        AnyArtifact(
            id: ArtifactIdentifier("geo1"),
            type: .geoJSON,
            title: "Tokyo Station",
            payload: """
            {
              "type": "Feature",
              "properties": { "title": "Tokyo Station" },
              "geometry": {
                "type": "Point",
                "coordinates": [139.7671, 35.6812]
              }
            }
            """,
            isComplete: true
        ),
        renderer: GeoJSONMapKitRenderer()
    )
    .artifactCardContentInsets(EdgeInsets())
    .padding()
    .frame(width: 480, height: 420)
}

#Preview("Bare — FeatureCollection (line + polygon)") {
    ArtifactView(
        AnyArtifact(
            id: ArtifactIdentifier("geo2"),
            type: .geoJSON,
            title: "Route + zone",
            payload: """
            {
              "type": "FeatureCollection",
              "features": [
                {
                  "type": "Feature",
                  "geometry": {
                    "type": "LineString",
                    "coordinates": [
                      [139.7671, 35.6812],
                      [139.7036, 35.6580],
                      [139.7006, 35.6717]
                    ]
                  }
                },
                {
                  "type": "Feature",
                  "geometry": {
                    "type": "Polygon",
                    "coordinates": [[
                      [139.69, 35.66],
                      [139.72, 35.66],
                      [139.72, 35.69],
                      [139.69, 35.69],
                      [139.69, 35.66]
                    ]]
                  }
                }
              ]
            }
            """,
            isComplete: true
        )
    )
    .artifactRenderer(GeoJSONMapKitRenderer())
    .padding()
    .frame(width: 520, height: 480)
}
