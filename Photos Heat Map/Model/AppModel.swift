//
//  AppModel.swift
//  Photos Heat Map
//
//  Single source of truth for the UI. Lives on the main actor; all heavy
//  lifting is delegated to PhotoLibraryIndexer (an actor) and detached tasks.
//

import Foundation
import Observation
import Photos
import MapKit

@MainActor
@Observable
final class AppModel {

    enum Phase: Equatable {
        case idle
        case requestingAccess
        case accessDenied(PHAuthorizationStatus)
        case scanning(ScanProgress)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Every geotagged image/video in the library, newest first.
    private(set) var allAssets: [GeoAsset] = []
    /// Total number of images + videos in the library (geotagged or not).
    private(set) var librarySize: Int = 0

    // MARK: Map state

    /// Spatial index of the assets currently shown on the heat map.
    private(set) var heatIndex: SpatialIndex = .empty
    /// Set when the model wants the map to move to a rect (initial fit, album change).
    private(set) var fitRequest: MapFitRequest?
    var heatStyle = HeatMapStyle()
    /// Visible part of the map, debounced so the grid is not re-queried 60× a second.
    private(set) var visibleMapRect: MKMapRect = .world

    @ObservationIgnored private let indexer = PhotoLibraryIndexer()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private var regionDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var latestMapRect: MKMapRect = .world

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var imageCount: Int { allAssets.reduce(0) { $0 + ($1.kind == .image ? 1 : 0) } }
    var videoCount: Int { allAssets.count - imageCount }

    /// Assets after album and filter selection. Later stages narrow this down.
    var filteredAssets: [GeoAsset] { allAssets }

    // MARK: - Loading

    func startIfNeeded() {
        guard phase == .idle else { return }
        reload()
    }

    func reload() {
        scanTask?.cancel()
        scanTask = Task { await self.loadLibrary() }
    }

    private func loadLibrary() async {
        phase = .requestingAccess
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard status == .authorized || status == .limited else {
            phase = .accessDenied(status)
            return
        }

        phase = .scanning(ScanProgress(scanned: 0, total: 0, found: 0))
        let assets = await indexer.scanLibrary { [weak self] progress in
            Task { @MainActor in
                guard let self, self.isScanning else { return }
                self.phase = .scanning(progress)
                self.librarySize = progress.total
            }
        }
        allAssets = assets
        phase = .ready
        rebuildIndex(fitMap: true)
    }

    // MARK: - Heat index

    /// Rebuilds the spatial index from `filteredAssets` off the main thread.
    func rebuildIndex(fitMap: Bool) {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        let assets = filteredAssets
        indexTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                SpatialIndex(assets: assets)
            }.value
            guard !Task.isCancelled, generation == self.indexGeneration else { return }
            self.heatIndex = built
            if fitMap, !built.isEmpty {
                self.fitRequest = MapFitRequest(rect: built.rectContaining(fraction: 0.96), animated: false)
            }
        }
    }

    // MARK: - Map region

    /// Called by the map view on every pan/zoom/resize tick; publishes at most every 200 ms.
    func mapVisibleRectChanged(_ rect: MKMapRect) {
        latestMapRect = rect
        guard regionDebounceTask == nil else { return }
        regionDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            self.regionDebounceTask = nil
            self.visibleMapRect = self.latestMapRect
        }
    }
}
