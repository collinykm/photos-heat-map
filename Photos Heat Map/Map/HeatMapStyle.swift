//
//  HeatMapStyle.swift
//  Photos Heat Map
//
//  Everything tweakable about how the heat layer looks. See README.md
//  ("How the heat map works") for what each knob does.
//

import Foundation

struct HeatMapStyle: Sendable, Equatable {
    /// Size of one density bin in *screen* pixels. Because it is fixed in pixels the
    /// bin size in map units automatically adapts to the zoom level.
    /// Smaller = sharper hot spots, more work per tile.
    var cellPixels: Double = 3

    /// Gaussian blur radius in screen pixels. Kernel radius in cells is
    /// ceil(blurPixels / cellPixels); sigma is radius / 2.5.
    var blurPixels: Double = 14

    /// Overall opacity of the hottest color.
    var maxAlpha: Double = 0.85

    /// Fraction of the normalized range over which alpha fades in from 0, so the
    /// outer fringe of a blob dissolves into the map instead of ending in a hard edge.
    var alphaFadeIn: Double = 0.15

    /// Exponent applied after log normalization. < 1 brightens sparse areas,
    /// > 1 emphasises the densest clusters.
    var gamma: Double = 0.8

    /// Minimum reference density (in blurred photo-count units). The reference is
    /// normally the densest blob at the current zoom level; this floor stops a single
    /// photo from being painted as the hottest spot in an otherwise empty library.
    var minReference: Double = 3

    /// Color ramp from cool (t = 0) to hot (t = 1). Alpha is handled separately.
    var ramp: [RampStop] = HeatMapStyle.classicRamp

    struct RampStop: Sendable, Equatable {
        var t: Double
        var r: Double
        var g: Double
        var b: Double
    }

    static let classicRamp: [RampStop] = [
        RampStop(t: 0.00, r: 0.05, g: 0.10, b: 0.70),   // deep blue
        RampStop(t: 0.22, r: 0.00, g: 0.60, b: 1.00),   // sky blue
        RampStop(t: 0.45, r: 0.00, g: 0.90, b: 0.45),   // green
        RampStop(t: 0.65, r: 1.00, g: 0.95, b: 0.00),   // yellow
        RampStop(t: 0.85, r: 1.00, g: 0.45, b: 0.00),   // orange
        RampStop(t: 1.00, r: 0.92, g: 0.05, b: 0.05),   // red
    ]

    /// Alternative ramp: white-hot "thermal" look.
    static let thermalRamp: [RampStop] = [
        RampStop(t: 0.00, r: 0.20, g: 0.00, b: 0.40),
        RampStop(t: 0.35, r: 0.80, g: 0.00, b: 0.30),
        RampStop(t: 0.65, r: 1.00, g: 0.50, b: 0.00),
        RampStop(t: 0.85, r: 1.00, g: 0.90, b: 0.20),
        RampStop(t: 1.00, r: 1.00, g: 1.00, b: 1.00),
    ]

    func color(at t: Double) -> (r: Double, g: Double, b: Double) {
        let stops = ramp.sorted { $0.t < $1.t }
        guard let first = stops.first, let last = stops.last else { return (1, 0, 0) }
        if t <= first.t { return (first.r, first.g, first.b) }
        if t >= last.t { return (last.r, last.g, last.b) }
        for i in 1..<stops.count {
            let a = stops[i - 1], b = stops[i]
            if t <= b.t {
                let span = max(b.t - a.t, 1e-9)
                let u = (t - a.t) / span
                return (a.r + (b.r - a.r) * u, a.g + (b.g - a.g) * u, a.b + (b.b - a.b) * u)
            }
        }
        return (last.r, last.g, last.b)
    }

    /// 256-entry premultiplied RGBA lookup table (4 bytes per entry) used by the renderer.
    func makeLookupTable() -> [UInt8] {
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        for i in 1..<256 {
            let t = Double(i) / 255
            let c = color(at: t)
            let a = min(1, t / max(alphaFadeIn, 0.0001)) * maxAlpha
            lut[i * 4 + 0] = UInt8((c.r * a * 255).rounded())
            lut[i * 4 + 1] = UInt8((c.g * a * 255).rounded())
            lut[i * 4 + 2] = UInt8((c.b * a * 255).rounded())
            lut[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        return lut
    }
}
