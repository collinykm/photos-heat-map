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
}
