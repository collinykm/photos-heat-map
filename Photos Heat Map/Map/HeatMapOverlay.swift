//
//  HeatMapOverlay.swift
//  Photos Heat Map
//
//  MapKit has no heat map, so this draws one. HeatMapOverlay is a world-spanning
//  MKOverlay; HeatMapRenderer does the work per tile in draw(_:zoomScale:in:):
//
//    1. Choose a bin size in map points so a bin is `cellPixels` wide on screen
//       (bin size therefore adapts to zoom automatically).
//    2. Bin every asset inside the tile (plus a blur-radius margin so blobs don't
//       get cut at tile seams) into a small Float raster.
//    3. Separable Gaussian blur over the raster.
//    4. Normalize with a per-zoom-level reference density (the densest blob
//       anywhere in the data at that zoom), log-scaled, then map through the
//       color ramp's RGBA lookup table.
//    5. Blit the raster into the tile's CGContext.
//
//  Because the renderer draws in map-point space, the result stays aligned
//  while panning and zooming; MapKit re-tiles when the zoom level changes.
//

import Foundation
import MapKit
import CoreGraphics
import CoreLocation

final class HeatMapOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: MKMapRect.world.midX, y: MKMapRect.world.midY).coordinate
    }
    var boundingMapRect: MKMapRect { .world }
}

final class HeatMapRenderer: MKOverlayRenderer {

    private let lock = NSLock()
    private var index: SpatialIndex = .empty
    private var style: HeatMapStyle
    private var lut: [UInt8]
    /// Reference density per quantized zoom level (log2 of zoomScale, rounded).
    private var referenceCache: [Int: Double] = [:]

    init(overlay: MKOverlay, style: HeatMapStyle) {
        self.style = style
        self.lut = style.makeLookupTable()
        super.init(overlay: overlay)
    }

    // MARK: - Updates (main thread)

    func update(index newIndex: SpatialIndex) {
        lock.lock()
        index = newIndex
        referenceCache.removeAll()
        lock.unlock()
        setNeedsDisplay()
    }

    func update(style newStyle: HeatMapStyle) {
        lock.lock()
        style = newStyle
        lut = newStyle.makeLookupTable()
        referenceCache.removeAll()
        lock.unlock()
        setNeedsDisplay()
    }

    private func snapshot() -> (SpatialIndex, HeatMapStyle, [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        return (index, style, lut)
    }

    // MARK: - Tile geometry

    private struct TileGeometry {
        let cols: Int
        let rows: Int
        let cellSize: Double        // map points per cell
        let originX: Double         // map-point origin of the padded raster
        let originY: Double
        let paddedRect: MKMapRect
        let blurCells: Int          // kernel radius in cells
    }

    private static func geometry(for mapRect: MKMapRect, zoomScale: MKZoomScale, style: HeatMapStyle) -> TileGeometry {
        let mapPointsPerPixel = 1.0 / Double(zoomScale)
        let cellSize = max(style.cellPixels, 1) * mapPointsPerPixel
        let blurCells = max(1, Int((style.blurPixels / max(style.cellPixels, 1)).rounded(.up)))
        let pad = blurCells
        let cols = Int((mapRect.width / cellSize).rounded(.up)) + 2 * pad
        let rows = Int((mapRect.height / cellSize).rounded(.up)) + 2 * pad
        let originX = mapRect.minX - Double(pad) * cellSize
        let originY = mapRect.minY - Double(pad) * cellSize
        let padded = MKMapRect(x: originX, y: originY, width: Double(cols) * cellSize, height: Double(rows) * cellSize)
        return TileGeometry(cols: cols, rows: rows, cellSize: cellSize, originX: originX, originY: originY,
                            paddedRect: padded, blurCells: blurCells)
    }

    private static func gaussianKernel(radius: Int, sigma: Double) -> [Float] {
        var kernel = [Float](repeating: 0, count: 2 * radius + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
            kernel[i + radius] = v
            sum += v
        }
        return kernel.map { $0 / sum }
    }

    /// Separable blur using "scatter" loops, which is cheap on sparse rasters.
    private static func blur(_ src: [Float], cols: Int, rows: Int, kernel: [Float]) -> [Float] {
        let r = kernel.count / 2
        var tmp = [Float](repeating: 0, count: src.count)
        var out = [Float](repeating: 0, count: src.count)
        src.withUnsafeBufferPointer { s in
            tmp.withUnsafeMutableBufferPointer { t in
                kernel.withUnsafeBufferPointer { k in
                    for y in 0..<rows {
                        let row = y * cols
                        for x in 0..<cols {
                            let v = s[row + x]
                            if v == 0 { continue }
                            let lo = max(0, x - r)
                            let hi = min(cols - 1, x + r)
                            var xx = lo
                            while xx <= hi {
                                t[row + xx] += v * k[xx - x + r]
                                xx += 1
                            }
                        }
                    }
                }
            }
        }
        tmp.withUnsafeBufferPointer { t in
            out.withUnsafeMutableBufferPointer { o in
                kernel.withUnsafeBufferPointer { k in
                    for y in 0..<rows {
                        let lo = max(0, y - r)
                        let hi = min(rows - 1, y + r)
                        let row = y * cols
                        for x in 0..<cols {
                            let v = t[row + x]
                            if v == 0 { continue }
                            var yy = lo
                            while yy <= hi {
                                o[yy * cols + x] += v * k[yy - y + r]
                                yy += 1
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Normalization

    private struct Cell: Hashable {
        let x: Int32
        let y: Int32
    }

    /// Densest blurred bin anywhere in the data set at this zoom level. Cached per
    /// level so every tile at the same zoom shares one scale (no seams between tiles).
    private func referenceDensity(zoomScale: MKZoomScale, index: SpatialIndex, style: HeatMapStyle, kernel: [Float]) -> Double {
        let level = Int(log2(Double(zoomScale)).rounded())
        lock.lock()
        if let cached = referenceCache[level] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let cellSize = max(style.cellPixels, 1) / pow(2.0, Double(level))
        var bins: [Cell: Float] = [:]
        bins.reserveCapacity(min(index.count, 1 << 16))
        for i in 0..<index.count {
            let c = Cell(x: Int32(truncatingIfNeeded: Int(index.xs[i] / cellSize)),
                         y: Int32(truncatingIfNeeded: Int(index.ys[i] / cellSize)))
            bins[c, default: 0] += 1
        }

        // The blurred maximum sits at or next to one of the densest raw bins, so it is
        // enough to evaluate the full 2-D kernel at the top few of them.
        let candidates = bins.sorted { $0.value > $1.value }.prefix(48)
        let r = kernel.count / 2
        var best: Float = 0
        for (cell, _) in candidates {
            var sum: Float = 0
            for dy in -r...r {
                let ky = kernel[dy + r]
                for dx in -r...r {
                    if let v = bins[Cell(x: cell.x &+ Int32(dx), y: cell.y &+ Int32(dy))] {
                        sum += v * ky * kernel[dx + r]
                    }
                }
            }
            if sum > best { best = sum }
        }
        let reference = max(Double(best), style.minReference)

        lock.lock()
        referenceCache[level] = reference
        lock.unlock()
        return reference
    }

    // MARK: - Drawing (background threads)

    override func canDraw(_ mapRect: MKMapRect, zoomScale: MKZoomScale) -> Bool {
        let (index, style, _) = snapshot()
        if index.isEmpty { return false }
        let geo = Self.geometry(for: mapRect, zoomScale: zoomScale, style: style)
        return index.count(in: geo.paddedRect) > 0
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let (index, style, lut) = snapshot()
        guard !index.isEmpty else { return }

        let geo = Self.geometry(for: mapRect, zoomScale: zoomScale, style: style)
        let cols = geo.cols, rows = geo.rows
        guard cols > 0, rows > 0, cols * rows < 4_000_000 else { return }

        // 1–2. Bin the points that fall inside the padded tile.
        var grid = [Float](repeating: 0, count: cols * rows)
        var hit = false
        index.forEachPoint(in: geo.paddedRect) { i in
            let cx = Int((index.xs[i] - geo.originX) / geo.cellSize)
            let cy = Int((index.ys[i] - geo.originY) / geo.cellSize)
            if cx >= 0 && cx < cols && cy >= 0 && cy < rows {
                grid[cy * cols + cx] += 1
                hit = true
            }
        }
        guard hit else { return }

        // 3. Blur.
        let kernel = Self.gaussianKernel(radius: geo.blurCells, sigma: Double(geo.blurCells) / 2.5)
        let blurred = Self.blur(grid, cols: cols, rows: rows, kernel: kernel)

        // 4. Normalize + colorize.
        let reference = referenceDensity(zoomScale: zoomScale, index: index, style: style, kernel: kernel)
        let logReference = log1p(reference)
        let gamma = style.gamma
        var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
        pixels.withUnsafeMutableBufferPointer { px in
            lut.withUnsafeBufferPointer { table in
                for i in 0..<(cols * rows) {
                    let v = blurred[i]
                    if v <= 0 { continue }
                    var t = log1p(Double(v)) / logReference
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
