//
//  SpatialIndex.swift
//  Photos Heat Map
//
//  Immutable snapshot of a set of GeoAssets sorted by map-point x, giving fast
//  rectangular range queries (binary search on x, linear filter on y).
//  It is shared between the main actor, the heat-map renderer's drawing threads
//  and background query tasks, and is never mutated after construction.
//

import Foundation
import MapKit

final class SpatialIndex: @unchecked Sendable {
    /// Identity, so views can tell when the index was replaced.
    let id = UUID()
    /// Assets sorted ascending by mapX.
    let assets: [GeoAsset]
    /// Parallel arrays for cache-friendly scanning.
    let xs: [Double]
    let ys: [Double]
    /// Bounding rect of all points (`MKMapRect.null` when empty).
    let boundingRect: MKMapRect

    var count: Int { assets.count }
    var isEmpty: Bool { assets.isEmpty }

    static let empty = SpatialIndex(assets: [])

    init(assets input: [GeoAsset]) {
        let sorted = input.sorted { $0.mapX < $1.mapX }
        assets = sorted
        xs = sorted.map(\.mapX)
        ys = sorted.map(\.mapY)
        if sorted.isEmpty {
            boundingRect = .null
        } else {
            var minY = Double.greatestFiniteMagnitude
            var maxY = -Double.greatestFiniteMagnitude
            for y in ys {
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
            boundingRect = MKMapRect(x: xs[0], y: minY, width: xs[xs.count - 1] - xs[0], height: maxY - minY)
        }
    }

    // MARK: - Queries

    /// Index of the first element whose x is >= `value`.
    func lowerBound(_ value: Double) -> Int {
        var lo = 0
        var hi = xs.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if xs[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Index one past the last element whose x is <= `value`.
    func upperBound(_ value: Double) -> Int {
        var lo = 0
        var hi = xs.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if xs[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Splits a map rect that may extend past the antimeridian (MKMapView lets you
    /// scroll across it) into x-ranges inside the canonical world.
    private static func wrappedXRanges(_ rect: MKMapRect) -> [(Double, Double)] {
        let world = MKMapRect.world.width
        if rect.width >= world { return [(0, world)] }
        var minX = rect.minX.truncatingRemainder(dividingBy: world)
        if minX < 0 { minX += world }
        let maxX = minX + rect.width
        if maxX <= world {
            return [(minX, maxX)]
        }
        return [(minX, world), (0, maxX - world)]
    }

    /// Calls `body` with the index of every point inside `rect` (edges inclusive).
    func forEachPoint(in rect: MKMapRect, _ body: (Int) -> Void) {
        guard !isEmpty, !rect.isNull, !rect.isEmpty else { return }
        let minY = rect.minY
        let maxY = rect.maxY
        for (x0, x1) in Self.wrappedXRanges(rect) {
            let start = lowerBound(x0)
            let end = upperBound(x1)
            if start >= end { continue }
            for i in start..<end {
                let y = ys[i]
                if y >= minY && y <= maxY { body(i) }
            }
        }
    }

    func count(in rect: MKMapRect) -> Int {
        var n = 0
        forEachPoint(in: rect) { _ in n += 1 }
        return n
    }

    func assets(in rect: MKMapRect) -> [GeoAsset] {
        var out: [GeoAsset] = []
        forEachPoint(in: rect) { out.append(assets[$0]) }
        return out
    }

    /// A rect that contains the central `fraction` of points along each axis, which
    /// keeps a single stray photo on the other side of the planet from zooming the
    /// initial view all the way out.
    func rectContaining(fraction: Double) -> MKMapRect {
        guard !isEmpty else { return .null }
        let f = min(max(fraction, 0.01), 1)
        let n = xs.count
        let lo = Int(Double(n - 1) * (1 - f) / 2)
        let hi = Int(Double(n - 1) * (1 + f) / 2)
        let sortedY = ys.sorted()
        let minX = xs[lo], maxX = xs[hi]
        let minY = sortedY[lo], maxY = sortedY[hi]
        // Never collapse to a degenerate rect: give at least ~2 km of room.
        let minSize = 2_000 / MKMetersPerMapPointAtLatitude(0)
        return MKMapRect(x: minX, y: minY, width: max(maxX - minX, minSize), height: max(maxY - minY, minSize))
    }
}
