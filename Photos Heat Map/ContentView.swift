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
            ToolbarItemGroup(placement: .navigation) {
                LibraryMenu()
                AlbumMenu()
                    .disabled(model.phase != .ready)
                if model.isLoadingAlbum {
                    ProgressView().controlSize(.small)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.goToCurrentLocation() }
                } label: {
                    Label("My Location", systemImage: "location")
                }
                .help("Show the map around your current location")
                MapViewMenu()
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

    private var readyContent: some View {
        ZStack {
            HSplitView {
                mapSection
                    .frame(minWidth: 340, idealWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
                PhotoGridView()
                    .frame(minWidth: 280, idealWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let selected = model.selectedAsset {
                PhotoDetailView(asset: selected)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.selectedAssetID == nil)
        .alert("Photos", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    private var mapSection: some View {
        HeatMapView(
            index: model.heatIndex,
            style: model.heatStyle,
            appearance: model.mapAppearance,
            showsHeatLayer: model.showsHeatLayer,
            fitRequest: model.fitRequest,
            onVisibleRectChange: { rect in model.mapVisibleRectChanged(rect) }
        )
        // Bottom-left keeps clear of MapKit's zoom/compass controls on the right.
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                LibrarySummaryView()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                HeatLegendView(style: model.heatStyle)
            }
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
