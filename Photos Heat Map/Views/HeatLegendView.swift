//
//  HeatLegendView.swift
//  Photos Heat Map
//

import SwiftUI

/// Small cool→hot color bar shown over the map.
struct HeatLegendView: View {
    let style: HeatMapStyle

    private var gradient: LinearGradient {
        let stops = style.ramp.sorted { $0.t < $1.t }.map { stop in
            Gradient.Stop(color: Color(red: stop.r, green: stop.g, blue: stop.b), location: stop.t)
        }
        return LinearGradient(gradient: Gradient(stops: stops), startPoint: .leading, endPoint: .trailing)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Fewer")
            RoundedRectangle(cornerRadius: 3)
                .fill(gradient)
                .frame(width: 90, height: 8)
            Text("More")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
