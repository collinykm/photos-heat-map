//
//  HeatMapOverlay.swift
//  Photos Heat Map
//
//  MapKit has no heat map, so this draws one. HeatMapOverlay is an MKOverlay
//  covering the data; HeatMapRenderer does the work per tile in
//  draw(_:zoomScale:in:), which MapKit calls on background threads:
//
//    1. Choose a bin size in map points so a bin is `cellPixels` wide on screen.
//    2. Count the assets inside the tile (plus a margin of one stamp radius so
//       shapes are not clipped at tile seams) into a small raster.
//    3. For every non-empty bin, add count × a radial bump (2-D lookup table,
//       Gaussian profile, zero at `stampRadiusPixels`). The result is the
//       number of stacked photo equivalents at each bin.
//    4. Map density through (density / saturation) ^ gamma and the colour /
//       opacity lookup table; blit the RGBA raster into the tile.
//
//  Because the renderer draws in map-point space, the result stays aligned
//  while panning and zooming; MapKit re-tiles when the zoom level changes.
//

import Foundation
import MapKit
import CoreGraphics
import CoreLocation

final class HeatMapOverlay: NSObject, MKOverlay {
    let boundingMapRect: MKMapRect

    /// Keep the overlay no larger than needed: MapKit culls tiles outside it, and a
    /// world-sized overlay is more likely to interfere with the 3-D globe.
    init(boundingMapRect: MKMapRect) {
        self.boundingMapRect = boundingMapRect.isNull ? .world : boundingMapRect
        super.init()
    }

    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    /// The data's bounding rect padded by the largest stamp extent the renderer can
    /// need (a few dozen pixels on a world-sized tile), clamped to the world.
    static func paddedRect(for data: MKMapRect) -> MKMapRect {
        guard !data.isNull else { return .world }
        let pad = MKMapRect.world.width * 0.15
        return data.insetBy(dx: -pad, dy: -pad).intersection(.world)
    }
}

final class HeatMapRenderer: MKOverlayRenderer {

    private let lock = NSLock()
    private var index: SpatialIndex = .empty
    private var style: HeatMapStyle
    private var lut: [UInt8]
    private var stamp: Stamp

    init(overlay: MKOverlay, style: HeatMapStyle) {
        self.style = style
        self.lut = style.makeLookupTable()
        self.stamp = Stamp(style: style)
        super.init(overlay: overlay)
    }

    // MARK: - Updates (main thread)

    func update(index newIndex: SpatialIndex) {
        lock.lock()
        index = newIndex
        lock.unlock()
        setNeedsDisplay()
    }

    func update(style newStyle: HeatMapStyle) {
        lock.lock()
        style = newStyle
        lut = newStyle.makeLookupTable()
        stamp = Stamp(style: newStyle)
        lock.unlock()
        setNeedsDisplay()
    }

    private func snapshot() -> (SpatialIndex, HeatMapStyle, [UInt8], Stamp) {
        lock.lock()
        defer { lock.unlock() }
        return (index, style, lut, stamp)
    }

    // MARK: - The stamp

    /// One photo's footprint: a (2r+1)² table of weights, Gaussian in the radius with
    /// sigma = r / 3.5, shifted so it reaches exactly 0 at the support edge. Radially
    /// symmetric, so a saturated cluster grows into a circle, never a square.
    private struct Stamp {
        let radius: Int           // in cells
        let size: Int             // 2 * radius + 1
        let weights: [Float]

        init(style: HeatMapStyle) {
            let cell = max(style.cellPixels, 1)
            let radius = max(2, Int((style.stampRadiusPixels / cell).rounded(.up)))
            let size = 2 * radius + 1
            let sigma = Double(radius) / 3.5
            let floor = exp(-Double(radius * radius) / (2 * sigma * sigma))
            var weights = [Float](repeating: 0, count: size * size)
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let d2 = Double(dx * dx + dy * dy)
                    let value = exp(-d2 / (2 * sigma * sigma)) - floor
                    if value > 0 {
                        weights[(dy + radius) * size + (dx + radius)] = Float(value)
                    }
                }
            }
            self.radius = radius
            self.size = size
            self.weights = weights
        }
    }

    // MARK: - Tile geometry

    private struct TileGeometry {
        let cols: Int
        let rows: Int
        let cellSize: Double        // map points per cell
        let originX: Double         // map-point origin of the padded raster
        let originY: Double
        let paddedRect: MKMapRect
    }

    private static func geometry(for mapRect: MKMapRect, zoomScale: MKZoomScale,
                                 style: HeatMapStyle, stamp: Stamp) -> TileGeometry {
        let cellSize = max(style.cellPixels, 1) / Double(zoomScale)
        let pad = stamp.radius
        let cols = Int((mapRect.width / cellSize).rounded(.up)) + 2 * pad
        let rows = Int((mapRect.height / cellSize).rounded(.up)) + 2 * pad
        let originX = mapRect.minX - Double(pad) * cellSize
        let originY = mapRect.minY - Double(pad) * cellSize
        let padded = MKMapRect(x: originX, y: originY, width: Double(cols) * cellSize, height: Double(rows) * cellSize)
        return TileGeometry(cols: cols, rows: rows, cellSize: cellSize, originX: originX, originY: originY, paddedRect: padded)
    }

    // MARK: - Drawing (background threads)

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        let (index, style, _, stamp) = snapshot()
        if index.isEmpty { return false }
        let geo = Self.geometry(for: mapRect, zoomScale: zoomScale, style: style, stamp: stamp)
        return index.count(in: geo.paddedRect) > 0
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let (index, style, lut, stamp) = snapshot()
        guard !index.isEmpty else { return }

        let geo = Self.geometry(for: mapRect, zoomScale: zoomScale, style: style, stamp: stamp)
        let cols = geo.cols, rows = geo.rows
        guard cols > 0, rows > 0, cols * rows < 4_000_000 else { return }

        // 1–2. Count the points that fall inside the padded tile.
        var counts = [Float](repeating: 0, count: cols * rows)
        var hit = false
        index.forEachPoint(in: geo.paddedRect) { i in
            let cx = Int((index.xs[i] - geo.originX) / geo.cellSize)
            let cy = Int((index.ys[i] - geo.originY) / geo.cellSize)
            if cx >= 0 && cx < cols && cy >= 0 && cy < rows {
                counts[cy * cols + cx] += 1
                hit = true
            }
        }
        guard hit else { return }

        // 3. Stamp every non-empty bin.
        var density = [Float](repeating: 0, count: cols * rows)
        let r = stamp.radius
        let ksize = stamp.size
        counts.withUnsafeBufferPointer { c in
            stamp.weights.withUnsafeBufferPointer { k in
                density.withUnsafeMutableBufferPointer { d in
                    for cy in 0..<rows {
                        let y0 = max(0, cy - r), y1 = min(rows - 1, cy + r)
                        for cx in 0..<cols {
                            let n = c[cy * cols + cx]
                            if n == 0 { continue }
                            let x0 = max(0, cx - r), x1 = min(cols - 1, cx + r)
                            var yy = y0
                            while yy <= y1 {
                                let krow = (yy - cy + r) * ksize + r - cx
                                let drow = yy * cols
                                var xx = x0
                                while xx <= x1 {
                                    d[drow + xx] += n * k[krow + xx]
                                    xx += 1
                                }
                                yy += 1
                            }
                        }
                    }
                }
            }
        }

        // 4. Normalize + colorize.
        let saturation = max(style.saturation, 0.001)
        let gamma = style.gamma
        var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
        pixels.withUnsafeMutableBufferPointer { px in
            lut.withUnsafeBufferPointer { table in
                for i in 0..<(cols * rows) {
                    let v = density[i]
                    if v <= 0 { continue }
                    var t = Double(v) / saturation
                    if t > 1 { t = 1 }
                    if gamma != 1 { t = pow(t, gamma) }
                    let li = Int(t * 255 + 0.5) * 4
                    let o = i * 4
                    px[o] = table[li]
                    px[o + 1] = table[li + 1]
                    px[o + 2] = table[li + 2]
                    px[o + 3] = table[li + 3]
                }
            }
        }

        // 5. Blit.
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: cols * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }

        // The MapKit drawing context is y-down (map-point space); Core Graphics draws images
        // y-up, so flip around the padded rect before blitting. If tiles ever appear
        // vertically mirrored, this is the place to look.
        let drawRect = rect(for: geo.paddedRect)
        context.saveGState()
        context.interpolationQuality = .default
        context.translateBy(x: drawRect.minX, y: drawRect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: drawRect.width, height: drawRect.height))
        context.restoreGState()
    }
}
