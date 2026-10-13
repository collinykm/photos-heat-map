//
//  Geocoder.swift
//  Photos Heat Map
//
//  Reverse-geocodes the location of the photo shown in the detail view, with a
//  small cache keyed by ~1 km grid cell so neighbouring photos share lookups.
//  Uses CLGeocoder (Apple's service, no API key). Purely cosmetic: failures
//  fall back to raw coordinates.
//

import Foundation
import CoreLocation

actor Geocoder {
    static let shared = Geocoder()

    private let geocoder = CLGeocoder()
    private var cache: [String: String] = [:]

    private static func cellKey(_ asset: GeoAsset) -> String {
        "\(Int((asset.latitude * 100).rounded())),\(Int((asset.longitude * 100).rounded()))"
    }

    func placeName(for asset: GeoAsset) async -> String? {
        let key = Self.cellKey(asset)
        if let cached = cache[key] { return cached }

        // CLGeocoder only runs one request at a time; drop the previous one.
        geocoder.cancelGeocode()
        let location = CLLocation(latitude: asset.latitude, longitude: asset.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else {
            return nil
        }

        var parts: [String] = []
        for candidate in [placemark.subLocality, placemark.locality, placemark.administrativeArea, placemark.country] {
            if let candidate, !candidate.isEmpty, !parts.contains(candidate) {
                parts.append(candidate)
            }
        }
        if parts.isEmpty, let name = placemark.name {
            parts.append(name)
        }
        guard !parts.isEmpty else { return nil }
        let name = parts.prefix(3).joined(separator: ", ")
        cache[key] = name
        return name
    }
}
