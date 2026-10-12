//
//  MapAppearance.swift
//  Photos Heat Map
//
//  User-selectable map look (base map style and flat vs. globe), persisted in
//  UserDefaults.
//

import Foundation
import MapKit

struct MapAppearance: Equatable, Sendable {

    enum BaseStyle: String, CaseIterable, Identifiable, Sendable {
        case standard = "Standard"
        case muted = "Muted"
        case satellite = "Satellite"
        case hybrid = "Hybrid"
        var id: String { rawValue }
    }

    enum Elevation: String, CaseIterable, Identifiable, Sendable {
        case flat = "Flat"
        case realistic = "Globe & Terrain"
        var id: String { rawValue }
    }

    var baseStyle: BaseStyle = .standard
    var elevation: Elevation = .realistic
    /// Show place names and roads on the base map.
    var showsLabels = true

    // MARK: MapKit configuration

    func makeConfiguration() -> MKMapConfiguration {
        let elevationStyle: MKMapConfiguration.ElevationStyle = elevation == .realistic ? .realistic : .flat
        switch baseStyle {
        case .standard, .muted:
            let config = MKStandardMapConfiguration(elevationStyle: elevationStyle,
                                                    emphasisStyle: baseStyle == .muted ? .muted : .default)
            config.pointOfInterestFilter = .excludingAll
            config.showsTraffic = false
            return config
        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: elevationStyle)
        case .hybrid:
            let config = MKHybridMapConfiguration(elevationStyle: elevationStyle)
            config.pointOfInterestFilter = .excludingAll
            config.showsTraffic = false
            return config
        }
    }

    // MARK: Persistence

    private static let styleKey = "mapAppearance.baseStyle"
    private static let elevationKey = "mapAppearance.elevation"

    static func load() -> MapAppearance {
        var appearance = MapAppearance()
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: styleKey), let style = BaseStyle(rawValue: raw) {
            appearance.baseStyle = style
        }
        if let raw = defaults.string(forKey: elevationKey), let elevation = Elevation(rawValue: raw) {
            appearance.elevation = elevation
        }
        return appearance
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(baseStyle.rawValue, forKey: Self.styleKey)
        defaults.set(elevation.rawValue, forKey: Self.elevationKey)
    }
}
