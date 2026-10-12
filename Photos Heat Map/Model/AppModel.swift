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

    // MARK: Grid state

    /// Every asset inside the visible map rect, newest first.
    private(set) var visibleAssets: [GeoAsset] = []
    /// The part of `visibleAssets` currently shown in the grid (paged).
    private(set) var displayedAssets: [GeoAsset] = []
    /// Bumped whenever the grid should scroll back to the top.
    private(set) var pageGeneration = 0
    private(set) var isQuerying = false
    var selectedAssetID: String?

    static let pageSize = 50
    static let pageDays = 7

    // MARK: Filters

    private(set) var filters = PhotoFilters()
    /// When true the heat map shows only the filtered assets; when false the filters
    /// only narrow the grid and the map shows the whole selection.
    private(set) var filtersAffectMap = true

    @ObservationIgnored private let indexer = PhotoLibraryIndexer()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private var regionDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var latestMapRect: MKMapRect = .world
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration = 0

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var imageCount: Int { allAssets.reduce(0) { $0 + ($1.kind == .image ? 1 : 0) } }
    var videoCount: Int { allAssets.count - imageCount }

    /// Applies the current album/filter selection to a list of assets. Static and
    /// nonisolated so it can run inside detached tasks.
    nonisolated static func applySelection(_ assets: [GeoAsset], filters: PhotoFilters) -> [GeoAsset] {
        if filters.isDefault { return assets }
        return assets.filter { filters.matches($0) }
    }

    func updateFilters(_ newFilters: PhotoFilters) {
        guard newFilters != filters else { return }
        filters = newFilters
        if filtersAffectMap {
            rebuildIndex(fitMap: false)
        } else {
            requeryVisible()
        }
    }

    func setFiltersAffectMap(_ value: Bool) {
        guard value != filtersAffectMap else { return }
        filtersAffectMap = value
        rebuildIndex(fitMap: false)
    }

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

    /// Rebuilds the spatial index from the current selection off the main thread.
    func rebuildIndex(fitMap: Bool) {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        let assets = allAssets
        let mapFilters = filtersAffectMap ? filters : PhotoFilters()
        indexTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                SpatialIndex(assets: Self.applySelection(assets, filters: mapFilters))
            }.value
            guard !Task.isCancelled, generation == self.indexGeneration else { return }
            self.heatIndex = built
            if fitMap, !built.isEmpty {
                self.fitRequest = MapFitRequest(rect: built.rectContaining(fraction: 0.96), animated: false)
            }
            self.requeryVisible()
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
            self.requeryVisible()
        }
    }
}

// MARK: - Grid queries & paging

extension AppModel {

    var canLoadMore: Bool { displayedAssets.count < visibleAssets.count }

    /// End index of a page that starts at `start`: at least `pageSize` items, or every
    /// item within `pageDays` of the first one in the page, whichever is more.
    nonisolated static func pageEnd(in sorted: [GeoAsset], from start: Int) -> Int {
        guard start < sorted.count else { return sorted.count }
        let byCount = min(sorted.count, start + pageSize)
        guard let anchor = sorted[start].date else { return byCount }
        let cutoff = anchor.addingTimeInterval(-Double(pageDays) * 86_400)
        var end = start
        while end < sorted.count, let d = sorted[end].date, d >= cutoff {
            end += 1
        }
        return max(byCount, end)
    }

    /// Re-runs the visible-region query against the current index (off the main thread),
    /// then resets the grid to its first page.
    func requeryVisible() {
        queryTask?.cancel()
        queryGeneration += 1
        let generation = queryGeneration
        let index = heatIndex
        let rect = visibleMapRect
        let filters = self.filters
        isQuerying = true

        queryTask = Task {
            let sorted: [GeoAsset] = await Task.detached(priority: .userInitiated) {
                // The index may already be filtered (filtersAffectMap); applying the
                // filters again is cheap and keeps the grid correct either way.
                var found = Self.applySelection(index.assets(in: rect), filters: filters)
                found.sort { a, b in
                    let da = a.sortDate, db = b.sortDate
                    if da != db { return da > db }
                    return a.id < b.id
                }
                return found
            }.value
            guard !Task.isCancelled, generation == self.queryGeneration else { return }

            let end = Self.pageEnd(in: sorted, from: 0)
            let page = Array(sorted.prefix(end))
            _ = await ThumbnailProvider.shared.resolveAssets(page.map(\.id))
            guard !Task.isCancelled, generation == self.queryGeneration else { return }

            self.visibleAssets = sorted
            self.displayedAssets = page
            self.pageGeneration += 1
            self.isQuerying = false
        }
    }

    func loadMore() {
        guard canLoadMore else { return }
        let generation = queryGeneration
        let sorted = visibleAssets
        let start = displayedAssets.count
        let end = Self.pageEnd(in: sorted, from: start)
        let next = Array(sorted[start..<end])
        isQuerying = true
        Task {
            _ = await ThumbnailProvider.shared.resolveAssets(next.map(\.id))
            guard generation == self.queryGeneration else { return }
            self.displayedAssets.append(contentsOf: next)
            self.isQuerying = false
        }
    }

    func select(_ asset: GeoAsset) {
        selectedAssetID = asset.id
    }
}
