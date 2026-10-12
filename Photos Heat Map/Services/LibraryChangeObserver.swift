//
//  LibraryChangeObserver.swift
//  Photos Heat Map
//
//  Forwards PhotoKit change notifications (delivered on a background queue)
//  to a closure. The heavy diffing happens in PhotoLibraryIndexer.applyChange.
//

import Foundation
import Photos

/// Wrapper so non-Sendable PhotoKit objects can cross actor boundaries. PHChange and
/// friends are immutable once delivered, so this is safe in practice.
struct SendableBox<T>: @unchecked Sendable {
    let value: T
}

final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    private let handler: @Sendable (SendableBox<PHChange>) -> Void
    private var isRegistered = false

    init(handler: @escaping @Sendable (SendableBox<PHChange>) -> Void) {
        self.handler = handler
        super.init()
    }

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        PHPhotoLibrary.shared().register(self)
    }

    func unregister() {
        guard isRegistered else { return }
        isRegistered = false
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        handler(SendableBox(value: changeInstance))
    }

    deinit {
        if isRegistered {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }
}

/// What changed in the library, in terms of our value types.
struct LibraryDelta: Sendable {
    var needsFullRescan = false
    var removedIDs: [String] = []
    /// Inserted or changed assets that (still) have a location.
    var upserted: [GeoAsset] = []
    /// Every changed asset id, for thumbnail cache invalidation.
    var changedIDs: [String] = []
    /// The currently selected album's membership changed.
    var selectedAlbumChanged = false
    /// Albums were created/deleted/renamed.
    var albumListChanged = false

    var isEmpty: Bool {
        !needsFullRescan && removedIDs.isEmpty && upserted.isEmpty && changedIDs.isEmpty
            && !selectedAlbumChanged && !albumListChanged
    }
}
