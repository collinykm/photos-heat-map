//
//  MapViewMenu.swift
//  Photos Heat Map
//
//  Toolbar menu: base map style, flat vs. globe, heat style and opacity.
//

import SwiftUI

struct MapViewMenu: View {
    @Environment(AppModel.self) private var model

    private static let opacitySteps: [Double] = [0.4, 0.6, 0.8, 1.0]

    var body: some View {
        Menu {
            Section("Map") {
                ForEach(MapAppearance.BaseStyle.allCases) { style in
                    Toggle(style.rawValue, isOn: Binding(
                        get: { model.mapAppearance.baseStyle == style },
                        set: { on in
                            if on {
                                var appearance = model.mapAppearance
                                appearance.baseStyle = style
                                model.setMapAppearance(appearance)
                            }
                        }
                    ))
                }
            }
            Section("Projection") {
                ForEach(MapAppearance.Elevation.allCases) { elevation in
                    Toggle(elevation.rawValue, isOn: Binding(
                        get: { model.mapAppearance.elevation == elevation },
                        set: { on in
                            if on {
                                var appearance = model.mapAppearance
                                appearance.elevation = elevation
                                model.setMapAppearance(appearance)
                            }
                        }
                    ))
                }
            }
            Section("Heat Style") {
                ForEach(HeatMapStyle.presets, id: \.name) { preset in
                    Toggle(preset.name, isOn: Binding(
                        get: { model.heatPresetName == preset.name },
                        set: { on in if on { model.selectHeatPreset(named: preset.name) } }
                    ))
                }
            }
            Section("Heat Opacity") {
                ForEach(Self.opacitySteps, id: \.self) { step in
                    Toggle("\(Int(step * 100))%", isOn: Binding(
                        get: { abs(model.heatOpacity - step) < 0.01 },
                        set: { on in if on { model.setHeatOpacity(step) } }
                    ))
                }
            }
        } label: {
            Label("View", systemImage: "globe.americas")
        }
        .help("Map style, globe view and heat map look")
    }
}
