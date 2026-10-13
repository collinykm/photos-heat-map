//
//  HeatMapStyle.swift
//  Photos Heat Map
//
//  Everything tweakable about how the heat layer looks.
//
//  The model: every photo stamps one radial bump (peak 1, Gaussian profile,
//  support radius `stampRadiusPixels` on screen). Bumps add up, so the value
//  at a pixel is the number of "stacked photo equivalents" there, independent
//  of zoom. That value is mapped to a colour and an opacity. Because the stamp
//  radius is fixed on screen, photos a few hundred metres apart join into one
//  shape at city zoom and whole trips merge into one blob when zoomed out.
//

import Foundation

struct HeatMapStyle: Sendable, Equatable {

    /// Preset name shown in the View › Heat Style menu.
    var name: String = "Soft"

    /// Size of one raster bin in screen pixels. Smaller = finer, more work per tile.
    var cellPixels: Double = 3

    /// Support radius of one photo's stamp, in screen points. The profile is Gaussian
    /// with sigma = radius / 3.5: a lone photo's visible halo is ~9 pt, the densest
    /// clusters grow to ~21 pt and stop, and photos within ~22 pt of each other on
    /// screen join into one shape.
    var stampRadiusPixels: Double = 24

    /// How many stacked photos reach the hottest colour. The mapping is logarithmic,
    /// `t = log(1 + density) / log(1 + saturation)`, so with 300: 1 photo is faint
    /// violet, 10 pink, 30 orange, 300+ yellow, at every zoom level.
    var saturation: Double = 300

    /// Extra exponent on t. < 1 brightens sparse areas, > 1 emphasises dense clusters.
    var gamma: Double = 1.0

    // Opacity curve, in normalized-density (t) space:
    /// Below this t the layer is fully transparent, which gives blobs a crisp edge.
    var alphaEdge: Double = 0.06
    /// Opacity right at the edge (the translucent halo).
    var edgeAlpha: Double = 0.20
    /// t at which opacity reaches `maxAlpha`.
    var alphaFull: Double = 0.50
    /// Opacity of the core (scaled by the View › Heat Opacity menu).
    var maxAlpha: Double = 0.62

    /// Colour ramp from cool (t = 0) to hot (t = 1).
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
        RampStop(t: 0.00, r: 0.45, g: 0.32, b: 0.95),
        RampStop(t: 0.30, r: 0.72, g: 0.34, b: 0.92),
        RampStop(t: 0.55, r: 0.97, g: 0.45, b: 0.60),
        RampStop(t: 0.78, r: 1.00, g: 0.64, b: 0.25),
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

    static let classic = HeatMapStyle(name: "Classic",
                                      alphaEdge: 0.04, edgeAlpha: 0.0, alphaFull: 0.35, maxAlpha: 0.8,
                                      ramp: classicRamp)

    static let thermal = HeatMapStyle(name: "Thermal",
                                      alphaEdge: 0.05, edgeAlpha: 0.15, alphaFull: 0.45, maxAlpha: 0.8,
                                      ramp: thermalRamp)

    static let presets: [HeatMapStyle] = [soft, classic, thermal]

    static func preset(named name: String) -> HeatMapStyle? {
        presets.first { $0.name == name }
    }

    // MARK: Lookups

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

    func alpha(at t: Double) -> Double {
        if t < alphaEdge { return 0 }
        let span = max(alphaFull - alphaEdge, 1e-6)
        let u = min(1, (t - alphaEdge) / span)
        return edgeAlpha + (maxAlpha - edgeAlpha) * u
    }

    /// 256-entry premultiplied RGBA lookup table (4 bytes per entry) used by the renderer.
    func makeLookupTable() -> [UInt8] {
        var lut = [UInt8](repeating: 0, count: 256 * 4)
        for i in 1..<256 {
            let t = Double(i) / 255
            let a = alpha(at: t)
            if a <= 0 { continue }
            let c = color(at: t)
            lut[i * 4 + 0] = UInt8((c.r * a * 255).rounded())
            lut[i * 4 + 1] = UInt8((c.g * a * 255).rounded())
            lut[i * 4 + 2] = UInt8((c.b * a * 255).rounded())
            lut[i * 4 + 3] = UInt8((a * 255).rounded())
        }
        return lut
    }
}
