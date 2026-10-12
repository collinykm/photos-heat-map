//
//  HeatMapStyle.swift
//  Photos Heat Map
//
//  Everything tweakable about how the heat layer looks. See README.md
//  ("How the heat map works") for what each knob does.
//

import Foundation

struct HeatMapStyle: Sendable, Equatable {

    /// How blurred density maps onto the 0…1 color range.
    enum Scaling: String, Sendable, Equatable {
        /// `(density / reference) ^ gamma`: keeps gradient inside blobs (Google Photos look).
        case power
        /// `log1p(density) / log1p(reference)`: flattens very skewed libraries.
        case log
    }

    /// Preset name shown in the Heat Style menu.
    var name: String = "Soft"

    /// Size of one density bin in *screen* pixels. Because it is fixed in pixels the
    /// bin size in map units automatically adapts to the zoom level.
    /// Smaller = sharper hot spots, more work per tile.
    var cellPixels: Double = 2

    /// Gaussian blur radius in screen pixels. Kernel radius in cells is
    /// ceil(blurPixels / cellPixels); sigma is radius / 2.5.
    var blurPixels: Double = 8

    /// Overall opacity of the layer (the Heat Style › Opacity menu scales this).
    var maxAlpha: Double = 0.62

    /// Fraction of the normalized range over which alpha fades in from 0. Small values
    /// give a crisp translucent edge (Google Photos); larger values dissolve the fringe.
    var alphaFadeIn: Double = 0.07

    var scaling: Scaling = .power

    /// Exponent applied to the normalized density. < 1 brightens sparse areas,
    /// > 1 emphasises the densest clusters.
    var gamma: Double = 0.5

    /// Minimum reference density (in blurred photo-count units). The reference is
    /// normally the densest blob at the current zoom level; this floor stops a single
    /// photo from being painted as the hottest spot in an otherwise empty library.
    var minReference: Double = 3

    /// Color ramp from cool (t = 0) to hot (t = 1). Alpha is handled separately.
    var ramp: [RampStop] = HeatMapStyle.softRamp

    struct RampStop: Sendable, Equatable {
        var t: Double
        var r: Double
        var g: Double
        var b: Double
    }

    // MARK: Ramps

    /// Violet → magenta → salmon → orange → yellow, in the spirit of Google Photos.
    static let softRamp: [RampStop] = [
        RampStop(t: 0.00, r: 0.42, g: 0.30, b: 0.95),
        RampStop(t: 0.25, r: 0.70, g: 0.32, b: 0.92),
        RampStop(t: 0.50, r: 0.96, g: 0.42, b: 0.62),
        RampStop(t: 0.75, r: 1.00, g: 0.62, b: 0.25),
        RampStop(t: 1.00, r: 1.00, g: 0.93, b: 0.35),
    ]

    /// Blue → cyan → green → yellow → red.
    static let classicRamp: [RampStop] = [
        RampStop(t: 0.00, r: 0.05, g: 0.10, b: 0.70),
        RampStop(t: 0.22, r: 0.00, g: 0.60, b: 1.00),
        RampStop(t: 0.45, r: 0.00, g: 0.90, b: 0.45),
        RampStop(t: 0.65, r: 1.00, g: 0.95, b: 0.00),
        RampStop(t: 0.85, r: 1.00, g: 0.45, b: 0.00),
        RampStop(t: 1.00, r: 0.92, g: 0.05, b: 0.05),
    ]

    /// Dark purple → red → orange → white-hot.
    static let thermalRamp: [RampStop] = [
        RampStop(t: 0.00, r: 0.20, g: 0.00, b: 0.40),
        RampStop(t: 0.35, r: 0.80, g: 0.00, b: 0.30),
        RampStop(t: 0.65, r: 1.00, g: 0.50, b: 0.00),
        RampStop(t: 0.85, r: 1.00, g: 0.90, b: 0.20),
        RampStop(t: 1.00, r: 1.00, g: 1.00, b: 1.00),
    ]

    // MARK: Presets

    static let soft = HeatMapStyle()

    static let classic = HeatMapStyle(name: "Classic", cellPixels: 3, blurPixels: 14, maxAlpha: 0.85,
                                      alphaFadeIn: 0.15, scaling: .log, gamma: 0.8, ramp: classicRamp)

    static let thermal = HeatMapStyle(name: "Thermal", cellPixels: 2, blurPixels: 10, maxAlpha: 0.75,
                                      alphaFadeIn: 0.12, scaling: .power, gamma: 0.55, ramp: thermalRamp)

    static let presets: [HeatMapStyle] = [soft, classic, thermal]

    static func preset(named name: String) -> HeatMapStyle? {
        presets.first { $0.name == name }
    }

    // MARK: Color lookup

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
