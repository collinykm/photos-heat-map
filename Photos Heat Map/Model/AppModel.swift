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
import CoreLocation

/// Paging rule for the grid: a page is at least `pageSize` items, or everything
/// within `pageDays` of the first item in the page, whichever is more.
enum GridPaging {
    static let pageSize = 50
    static let pageDays = 7
}

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
    /// Live heat style = selected preset with its opacity scaled by `heatOpacity`.
    private(set) var heatStyle: HeatMapStyle = .soft
    private(set) var heatPresetName: String = HeatMapStyle.soft.name
    private(set) var heatOpacity: Double = 1.0
    private(set) var mapAppearance: MapAppearance = .load()
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

    /// Regular user albums (for "Add to Album").
    private(set) var userAlbums: [AlbumInfo] = []

    // MARK: Album / library selection

    /// Everything the album picker offers (whole library first).
    private(set) var albums: [AlbumInfo] = [.entireLibrary]
    private(set) var selectedAlbum: AlbumInfo = .entireLibrary
    private(set) var isLoadingAlbum = false
    /// Identifiers of the assets in `selectedAlbum`; nil means the whole library.
    @ObservationIgnored private var albumAssetIDs: Set<String>?
    /// Last error from a Photos write, shown in an alert.
    var errorMessage: String?

    // MARK: Filters

    private(set) var filters = PhotoFilters()
    /// When true the heat map shows only the filtered assets; when false the filters
    /// only narrow the grid and the map shows the whole selection.
    private(set) var filtersAffectMap = true

    @ObservationIgnored private let indexer = PhotoLibraryIndexer()
    @ObservationIgnored private let locationProvider: LocationProvider
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexGeneration = 0
    @ObservationIgnored private var regionDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var latestMapRect: MKMapRect = .world
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration = 0
    @ObservationIgnored private var changeObserver: LibraryChangeObserver?
    /// Where the selection should land after the selected item disappears.
    @ObservationIgnored private var pendingSelectionIndex: Int?

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var imageCount: Int { allAssets.reduce(0) { $0 + ($1.kind == .image ? 1 : 0) } }
    var videoCount: Int { allAssets.count - imageCount }

    /// Applies the current album/filter selection to a list of assets. Static and
    /// nonisolated so it can run inside detached tasks.
    nonisolated static func applySelection(_ assets: [GeoAsset], filters: PhotoFilters,
                                           albumIDs: Set<String>? = nil) -> [GeoAsset] {
        if filters.isDefault && albumIDs == nil { return assets }
        return assets.filter { asset in
            if let albumIDs, !albumIDs.contains(asset.id) { return false }
            return filters.matches(asset)
        }
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

    init() {
        locationProvider = LocationProvider()
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "heat.preset"), HeatMapStyle.preset(named: name) != nil {
            heatPresetName = name
        }
        let opacity = defaults.double(forKey: "heat.opacity")
        if opacity > 0 { heatOpacity = opacity }
        applyHeatStyle()
    }

    private func loadLibrary() async {
        // Ask for the user's area while the (much slower) library scan runs.
        async let location = locationProvider.currentLocation(timeout: .seconds(8))

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
        // A rescan keeps the selected album; re-read its membership first.
        if !selectedAlbum.isEntireLibrary {
            albumAssetIDs = await indexer.albumMembership(albumID: selectedAlbum.id)
        }
        // Open on the user's area when we know it (no position marker is drawn);
        // otherwise fit the data.
        let focus = await location?.coordinate
        rebuildIndex(fitMap: true, focus: focus)
        installChangeObserver()
        userAlbums = await indexer.fetchUserAlbums()
        albums = await indexer.fetchAllAlbums()
        if !albums.contains(selectedAlbum) {
            selectedAlbum = .entireLibrary
            albumAssetIDs = nil
            rebuildIndex(fitMap: false)
        }
    }

    // MARK: - Album selection

    func selectAlbum(_ album: AlbumInfo) async {
        guard album != selectedAlbum else { return }
        selectedAlbum = album
        isLoadingAlbum = true
        albumAssetIDs = await indexer.albumMembership(albumID: album.isEntireLibrary ? nil : album.id)
        guard selectedAlbum == album else { return }   // user picked another album meanwhile
        isLoadingAlbum = false
        rebuildIndex(fitMap: true)
    }

    /// Re-reads the selected album's membership after Photos reported a change to it.
    private func refreshSelectedAlbum() async {
        guard !selectedAlbum.isEntireLibrary else { return }
        let album = selectedAlbum
        let ids = await indexer.albumMembership(albumID: album.id)
        guard selectedAlbum == album else { return }
        albumAssetIDs = ids
        rebuildIndex(fitMap: false, resetPage: false)
    }

    // MARK: - Heat index

    /// Rebuilds the spatial index from the current selection off the main thread.
    /// `resetPage` = false keeps the grid's current page/scroll position (used for
    /// in-place library changes such as favorites or deletions).
    func rebuildIndex(fitMap: Bool, resetPage: Bool = true, focus: CLLocationCoordinate2D? = nil) {
        indexTask?.cancel()
        indexGeneration += 1
        let generation = indexGeneration
        let assets = allAssets
        let mapFilters = filtersAffectMap ? filters : PhotoFilters()
        let albumIDs = albumAssetIDs
        indexTask = Task {
            let built = await Task.detached(priority: .userInitiated) {
                SpatialIndex(assets: Self.applySelection(assets, filters: mapFilters, albumIDs: albumIDs))
            }.value
            guard !Task.isCancelled, generation == self.indexGeneration else { return }
            self.heatIndex = built
            if fitMap {
                if let focus {
                    self.fitRequest = MapFitRequest(rect: Self.mapRect(around: focus, meters: Self.homeAreaMeters), animated: false)
                } else if !built.isEmpty {
                    self.fitRequest = MapFitRequest(rect: built.rectContaining(fraction: 0.96), animated: false)
                }
            }
            self.requeryVisible(resetPage: resetPage)
        }
    }

    // MARK: - Appearance

    func setMapAppearance(_ appearance: MapAppearance) {
        guard appearance != mapAppearance else { return }
        mapAppearance = appearance
        appearance.save()
    }

    func selectHeatPreset(named name: String) {
        guard HeatMapStyle.preset(named: name) != nil else { return }
        heatPresetName = name
        UserDefaults.standard.set(name, forKey: "heat.preset")
        applyHeatStyle()
    }

    func setHeatOpacity(_ opacity: Double) {
        heatOpacity = min(max(opacity, 0.1), 1.0)
        UserDefaults.standard.set(heatOpacity, forKey: "heat.opacity")
        applyHeatStyle()
    }

    private func applyHeatStyle() {
        var style = HeatMapStyle.preset(named: heatPresetName) ?? .soft
        style.maxAlpha = min(1, style.maxAlpha * heatOpacity)
        heatStyle = style
    }

    // MARK: - Location

    /// Width/height of the "current area" the map opens on.
    nonisolated static let homeAreaMeters: Double = 40_000

    nonisolated static func mapRect(around coordinate: CLLocationCoordinate2D, meters: Double) -> MKMapRect {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: meters, longitudinalMeters: meters)
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        let topLeft = MKMapPoint(CLLocationCoordinate2D(latitude: min(coordinate.latitude + halfLat, 85),
                                                        longitude: max(coordinate.longitude - halfLon, -180)))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(latitude: max(coordinate.latitude - halfLat, -85),
                                                            longitude: min(coordinate.longitude + halfLon, 180)))
        return MKMapRect(x: topLeft.x, y: topLeft.y,
                         width: max(bottomRight.x - topLeft.x, 1), height: max(bottomRight.y - topLeft.y, 1))
    }

    /// Toolbar action: pan/zoom to the user's current area (still without a marker).
    func goToCurrentLocation() async {
        guard let location = await locationProvider.currentLocation(timeout: .seconds(8)) else {
            errorMessage = locationProvider.isDenied
                ? "Location access is off for Photos Heat Map. Enable it in System Settings › Privacy & Security › Location Services."
                : "Your location could not be determined."
            return
        }
        fitRequest = MapFitRequest(rect: Self.mapRect(around: location.coordinate, meters: Self.homeAreaMeters), animated: true)
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
        let byCount = min(sorted.count, start + GridPaging.pageSize)
        guard let anchor = sorted[start].date else { return byCount }
        let cutoff = anchor.addingTimeInterval(-Double(GridPaging.pageDays) * 86_400)
        var end = start
        while end < sorted.count, let d = sorted[end].date, d >= cutoff {
            end += 1
        }
        return max(byCount, end)
    }

    /// Re-runs the visible-region query against the current index (off the main thread),
    /// then resets the grid to its first page (or keeps the current page size when
    /// `resetPage` is false).
    func requeryVisible(resetPage: Bool = true) {
        queryTask?.cancel()
        queryGeneration += 1
        let generation = queryGeneration
        let index = heatIndex
        let rect = visibleMapRect
        let filters = self.filters
        let keepCount = resetPage ? 0 : displayedAssets.count
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

            let end = max(Self.pageEnd(in: sorted, from: 0), min(keepCount, sorted.count))
            let page = Array(sorted.prefix(end))
            _ = await ThumbnailProvider.shared.resolveAssets(page.map(\.id))
            guard !Task.isCancelled, generation == self.queryGeneration else { return }

            self.visibleAssets = sorted
            self.displayedAssets = page
            if resetPage { self.pageGeneration += 1 }
            self.isQuerying = false
            self.fixUpSelection()
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

// MARK: - Selection

extension AppModel {

    var selectedIndex: Int? {
        guard let selectedAssetID else { return nil }
        return displayedAssets.firstIndex { $0.id == selectedAssetID }
    }

    var selectedAsset: GeoAsset? {
        selectedIndex.map { displayedAssets[$0] }
    }

    var hasPrevious: Bool { (selectedIndex ?? 0) > 0 }

    var hasNext: Bool {
        guard let selectedIndex else { return false }
        return selectedIndex + 1 < displayedAssets.count
    }

    func selectNext() {
        guard let selectedIndex, selectedIndex + 1 < displayedAssets.count else { return }
        selectedAssetID = displayedAssets[selectedIndex + 1].id
    }

    func selectPrevious() {
        guard let selectedIndex, selectedIndex > 0 else { return }
        selectedAssetID = displayedAssets[selectedIndex - 1].id
    }

    func closeDetail() {
        selectedAssetID = nil
        pendingSelectionIndex = nil
    }

    /// After the grid changed underneath the viewer, keep the viewer on a valid item.
    private func fixUpSelection() {
        guard selectedAssetID != nil, selectedIndex == nil else {
            pendingSelectionIndex = nil
            return
        }
        guard let wanted = pendingSelectionIndex, !displayedAssets.isEmpty else {
            selectedAssetID = nil
            pendingSelectionIndex = nil
            return
        }
        selectedAssetID = displayedAssets[min(wanted, displayedAssets.count - 1)].id
        pendingSelectionIndex = nil
    }
}

// MARK: - Library writes

extension AppModel {

    private func resolvePHAsset(_ id: String) async -> PHAsset? {
        if let cached = ThumbnailProvider.shared.cachedAsset(for: id) { return cached }
        let resolved = await ThumbnailProvider.shared.resolveAssets([id])
        if resolved[id] == nil { errorMessage = PhotoLibraryActionError.assetNotFound.localizedDescription }
        return resolved[id]
    }

    private func report(_ error: Error) {
        guard !PhotoLibraryActions.isUserCancellation(error) else { return }
        errorMessage = error.localizedDescription
    }

    /// Replaces one asset in every array that holds it (favorite flag changes).
    private func replaceAsset(_ updated: GeoAsset) {
        if let i = allAssets.firstIndex(where: { $0.id == updated.id }) { allAssets[i] = updated }
        if let i = visibleAssets.firstIndex(where: { $0.id == updated.id }) { visibleAssets[i] = updated }
        if let i = displayedAssets.firstIndex(where: { $0.id == updated.id }) { displayedAssets[i] = updated }
    }

    func toggleFavorite(_ asset: GeoAsset) async {
        guard let phAsset = await resolvePHAsset(asset.id) else { return }
        let newValue = !asset.isFavorite
        do {
            try await PhotoLibraryActions.setFavorite(phAsset, newValue)
            replaceAsset(asset.withFavorite(newValue))
            // The spatial index holds copies; refresh it without disturbing the grid.
            rebuildIndex(fitMap: false, resetPage: false)
        } catch {
            report(error)
        }
    }

    func deleteAsset(_ asset: GeoAsset) async {
        guard let phAsset = await resolvePHAsset(asset.id) else { return }
        do {
            try await PhotoLibraryActions.delete(phAsset)
            apply(LibraryDelta(removedIDs: [asset.id]))
        } catch {
            report(error)
        }
    }

    func add(_ asset: GeoAsset, to album: AlbumInfo) async {
        guard let phAsset = await resolvePHAsset(asset.id) else { return }
        do {
            try await PhotoLibraryActions.add(phAsset, toAlbumWithID: album.id)
        } catch {
            report(error)
        }
    }

    func createAlbum(titled title: String, adding asset: GeoAsset) async {
        guard let phAsset = await resolvePHAsset(asset.id) else { return }
        do {
            try await PhotoLibraryActions.createAlbum(titled: title, adding: phAsset)
            userAlbums = await indexer.fetchUserAlbums()
        } catch {
            report(error)
        }
    }
}

// MARK: - Library change notifications

extension AppModel {

    private func installChangeObserver() {
        guard changeObserver == nil else { return }
        let observer = LibraryChangeObserver { [weak self] box in
            Task { @MainActor in
                await self?.handleLibraryChange(box)
            }
        }
        observer.register()
        changeObserver = observer
    }

    private func handleLibraryChange(_ box: SendableBox<PHChange>) async {
        guard phase == .ready else { return }
        let delta = await indexer.applyChange(box)
        apply(delta)
    }

    /// Applies a delta to the in-memory asset list and refreshes the map/grid without
    /// losing the user's place in the grid.
    func apply(_ delta: LibraryDelta) {
        if delta.needsFullRescan {
            reload()
            return
        }
        if delta.albumListChanged {
            Task {
                self.userAlbums = await self.indexer.fetchUserAlbums()
                self.albums = await self.indexer.fetchAllAlbums()
            }
        }
        if delta.selectedAlbumChanged {
            Task { await self.refreshSelectedAlbum() }
        }

        var didChange = false
        if !delta.removedIDs.isEmpty || !delta.upserted.isEmpty {
            let removed = Set(delta.removedIDs)
            var upserts = Dictionary(delta.upserted.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            var next: [GeoAsset] = []
            next.reserveCapacity(allAssets.count + upserts.count)
            for asset in allAssets {
                if removed.contains(asset.id) {
                    didChange = true
                    continue
                }
                if let updated = upserts.removeValue(forKey: asset.id) {
                    if updated != asset { didChange = true }
                    next.append(updated)
                } else {
                    next.append(asset)
                }
            }
            if !upserts.isEmpty {
                didChange = true
                next.append(contentsOf: upserts.values)
            }
            if didChange {
                if let selected = selectedAssetID, removed.contains(selected) {
                    pendingSelectionIndex = selectedIndex
                }
                allAssets = next
            }
            ThumbnailProvider.shared.invalidate(ids: delta.changedIDs + delta.removedIDs)
        }

        if didChange {
            rebuildIndex(fitMap: false, resetPage: false)
        }
    }
}
