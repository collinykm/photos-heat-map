//
//  GeoAsset.swift
//  Photos Heat Map
//
//  A lightweight, value-type snapshot of the metadata the app needs from a
//  geotagged PHAsset. It never references PhotoKit objects, so arrays of these
//  are cheap to copy between threads and small enough to hold for libraries
//  with hundreds of thousands of items (~80 bytes + identifier per asset).
//

import Foundation
import CoreLocation
import MapKit
import Photos

/// Image or video.
enum MediaKind: UInt8, Sendable, Hashable, CaseIterable {
    case image
    case video
}

struct GeoAsset: Sendable, Identifiable, Hashable {
    /// `PHAsset.localIdentifier`
    let id: String
    let latitude: Double
    let longitude: Double
    /// Position in MapKit's map-point space (`MKMapPoint`), projected once at scan
    /// time so the heat map and the visible-region queries never re-project.
    let mapX: Double
    let mapY: Double
    let date: Date?
    let kind: MediaKind
    let isFavorite: Bool
    /// Seconds; 0 for images.
    let duration: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var mapPoint: MKMapPoint { MKMapPoint(x: mapX, y: mapY) }

    /// Date used for ordering; undated items sort last.
    var sortDate: Date { date ?? .distantPast }

    /// Same asset with an updated favorite flag.
    func withFavorite(_ favorite: Bool) -> GeoAsset {
        GeoAsset(id: id, latitude: latitude, longitude: longitude, mapX: mapX, mapY: mapY,
                 date: date, kind: kind, isFavorite: favorite, duration: duration)
    }
}

extension GeoAsset {
    /// Returns nil when the asset has no usable location.
    init?(asset: PHAsset) {
        guard let location = asset.location else { return nil }
        let c = location.coordinate
        // (0, 0) is almost always bogus metadata rather than a real photo of the Gulf of Guinea.
        guard CLLocationCoordinate2DIsValid(c), !(c.latitude == 0 && c.longitude == 0) else { return nil }
        let p = MKMapPoint(c)
        let isVideo = asset.mediaType == .video
        self.init(
            id: asset.localIdentifier,
            latitude: c.latitude,
            longitude: c.longitude,
            mapX: p.x,
            mapY: p.y,
            date: asset.creationDate,
            kind: isVideo ? .video : .image,
            isFavorite: asset.isFavorite,
            duration: isVideo ? asset.duration : 0
        )
    }
}
