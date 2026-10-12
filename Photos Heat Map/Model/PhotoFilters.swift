//
//  PhotoFilters.swift
//  Photos Heat Map
//
//  Note: PhotoKit has no public API for People/faces on macOS, so a "people"
//  filter cannot be built without private frameworks. It is intentionally absent.
//

import Foundation

struct PhotoFilters: Equatable, Sendable {

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case all = "All"
        case images = "Photos"
        case videos = "Videos"
        var id: String { rawValue }
    }

    var kind: Kind = .all
    var favoritesOnly = false
    /// Inclusive lower bound (start of day).
    var startDate: Date?
    /// Inclusive upper bound (end of day).
    var endDate: Date?

    var isDefault: Bool { self == PhotoFilters() }

    var hasDateRange: Bool { startDate != nil || endDate != nil }

    func matches(_ asset: GeoAsset) -> Bool {
        switch kind {
        case .all: break
        case .images: if asset.kind != .image { return false }
        case .videos: if asset.kind != .video { return false }
        }
        if favoritesOnly && !asset.isFavorite { return false }
        if hasDateRange {
            guard let date = asset.date else { return false }
            if let startDate, date < startDate { return false }
            if let endDate, date > endDate { return false }
        }
        return true
    }

    // MARK: Date helpers

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    static func endOfDay(_ date: Date) -> Date {
        let start = Calendar.current.startOfDay(for: date)
        return Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? start
    }

    mutating func setRange(from: Date?, to: Date?) {
        startDate = from.map(Self.startOfDay)
        endDate = to.map(Self.endOfDay)
    }

    var dateRangeDescription: String {
        let fmt: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) }
        switch (startDate, endDate) {
        case (nil, nil): return "Any time"
        case (let s?, nil): return "From \(fmt(s))"
        case (nil, let e?): return "Until \(fmt(e))"
        case (let s?, let e?): return "\(fmt(s)) – \(fmt(e))"
        }
    }
}
