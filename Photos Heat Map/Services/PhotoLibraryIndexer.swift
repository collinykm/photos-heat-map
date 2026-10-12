//
//  PhotoLibraryIndexer.swift
//  Photos Heat Map
//
//  All PhotoKit *reads* happen inside this actor, i.e. off the main thread.
//  Only metadata is touched here; no pixel data is ever requested.
//

import Foundation
import Photos

/// Progress of a library scan, reported periodically from a background thread.
struct ScanProgress: Sendable, Equatable {
    var scanned: Int
    var total: Int
    var found: Int
}

actor PhotoLibraryIndexer {

    /// Fetch result for the whole library (images + videos). Kept so library change
    /// notifications can later be diffed against it.
    private(set) var libraryFetchResult: PHFetchResult<PHAsset>?
    /// Fetch result of the currently selected album's assets (nil = whole library).
    private var albumFetchResult: PHFetchResult<PHAsset>?
    /// Fetch result of the user's regular albums, for the "Add to Album" menu.
    private var userAlbumsFetchResult: PHFetchResult<PHAssetCollection>?

    static func allMediaFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = true
        return options
    }

    /// Enumerates every image/video in the library and returns the ones that carry a
    /// location. `progress` is invoked on the actor's thread; hop to the main actor
    /// before touching UI state.
    func scanLibrary(progress: @escaping @Sendable (ScanProgress) -> Void) -> [GeoAsset] {
        let result = PHAsset.fetchAssets(with: Self.allMediaFetchOptions())
        libraryFetchResult = result
        let total = result.count

        var found: [GeoAsset] = []
        found.reserveCapacity(max(1024, total / 4))
        var lastReport = ContinuousClock.now
        let reportInterval: Duration = .milliseconds(150)

        result.enumerateObjects { asset, index, _ in
            if let geo = GeoAsset(asset: asset) {
                found.append(geo)
            }
            if index & 255 == 0 {
                let now = ContinuousClock.now
                if now - lastReport >= reportInterval {
                    lastReport = now
                    progress(ScanProgress(scanned: index + 1, total: total, found: found.count))
                }
            }
        }
        progress(ScanProgress(scanned: total, total: total, found: found.count))
        return found
    }

    // MARK: - Albums

    /// Regular user albums that accept new content, sorted by title.
    func fetchUserAlbums() -> [AlbumInfo] {
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        userAlbumsFetchResult = result
        var albums: [AlbumInfo] = []
        result.enumerateObjects { collection, _, _ in
            guard collection.canPerform(.addContent) else { return }
            albums.append(AlbumInfo(id: collection.localIdentifier,
                                    title: collection.localizedTitle ?? "Untitled",
                                    kind: .user,
                                    count: nil,
                                    canAddContent: true))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: - Change handling

    /// Diffs a PhotoKit change against the fetch results we hold and describes it in
    /// terms of GeoAssets. Runs on the actor, never on the main thread.
    func applyChange(_ box: SendableBox<PHChange>) -> LibraryDelta {
        let change = box.value
        var delta = LibraryDelta()

        if let result = libraryFetchResult, let details = change.changeDetails(for: result) {
            libraryFetchResult = details.fetchResultAfterChanges
            if details.hasIncrementalChanges {
                for asset in details.removedObjects {
                    delta.removedIDs.append(asset.localIdentifier)
                }
                for asset in details.insertedObjects {
                    if let geo = GeoAsset(asset: asset) { delta.upserted.append(geo) }
                }
                for asset in details.changedObjects {
                    delta.changedIDs.append(asset.localIdentifier)
                    if let geo = GeoAsset(asset: asset) {
                        delta.upserted.append(geo)
                    } else {
                        delta.removedIDs.append(asset.localIdentifier)
                    }
                }
            } else {
                delta.needsFullRescan = true
            }
        }

        if let albumResult = albumFetchResult, let details = change.changeDetails(for: albumResult) {
            albumFetchResult = details.fetchResultAfterChanges
            delta.selectedAlbumChanged = true
        }

        if let albumsResult = userAlbumsFetchResult, let details = change.changeDetails(for: albumsResult) {
            userAlbumsFetchResult = details.fetchResultAfterChanges
            delta.albumListChanged = true
        }

        return delta
    }
}
