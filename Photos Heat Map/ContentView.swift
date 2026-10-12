//
//  ContentView.swift
//  Photos Heat Map
//

import SwiftUI
import Photos
import MapKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .requestingAccess:
                ProgressView("Requesting access to Photos…")
            case .accessDenied(let status):
                AccessDeniedView(status: status)
            case .scanning(let progress):
                ScanningView(progress: progress)
            case .failed(let message):
                ContentUnavailableView("Couldn't read the library",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(message))
            case .ready:
                readyContent
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task { model.startIfNeeded() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.reload()
                } label: {
                    Label("Rescan Library", systemImage: "arrow.clockwise")
                }
                .help("Scan the Photos library again")
                .disabled(model.isScanning)
            }
        }
    }

    // Stage 2: full-window heat map. Stage 3 adds the split view + grid.
    private var readyContent: some View {
        HeatMapView(
            index: model.heatIndex,
            style: model.heatStyle,
            fitRequest: model.fitRequest,
            onVisibleRectChange: { rect in model.mapVisibleRectChanged(rect) }
        )
        .overlay(alignment: .bottomLeading) {
            LibrarySummaryView()
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            HeatLegendView(style: model.heatStyle)
                .padding(10)
        }
        .overlay {
            if model.heatIndex.isEmpty && !model.allAssets.isEmpty {
                ProgressView("Indexing…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if model.allAssets.isEmpty {
                ContentUnavailableView("No geotagged photos",
                                       systemImage: "mappin.slash",
                                       description: Text("None of the items in this library carry a location."))
                    .background(.regularMaterial)
            }
        }
    }
}
