//
//  PhotoLibraryActions.swift
//  Photos Heat Map
//
//  Write operations against the Photos library. Every call goes through
//  PHPhotoLibrary.performChanges, so Photos shows its own confirmation
//  dialog for deletions and the change observer updates the UI afterwards.
//

import Foundation
import Photos

enum PhotoLibraryActionError: LocalizedError {
    case assetNotFound
    case albumNotFound
    case albumNotEditable

    var errorDescription: String? {
        switch self {
        case .assetNotFound: return "That item could not be found in the Photos library."
        case .albumNotFound: return "That album could not be found."
        case .albumNotEditable: return "Photos can't be added to that album."
        }
    }
}

enum PhotoLibraryActions {

    static func setFavorite(_ asset: PHAsset, _ isFavorite: Bool) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = isFavorite
        }
    }

    /// Photos presents a confirmation alert; cancelling throws `PHPhotosError.userCancelled`.
    static func delete(_ asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    static func add(_ asset: PHAsset, toAlbumWithID albumID: String) async throws {
        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil)
        guard let collection = collections.firstObject else { throw PhotoLibraryActionError.albumNotFound }
        guard collection.canPerform(.addContent) else { throw PhotoLibraryActionError.albumNotEditable }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCollectionChangeRequest(for: collection)?.addAssets([asset] as NSArray)
        }
    }

    static func createAlbum(titled title: String, adding asset: PHAsset) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            request.addAssets([asset] as NSArray)
        }
    }

    static func isUserCancellation(_ error: Error) -> Bool {
        if let photosError = error as? PHPhotosError, photosError.code == .userCancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.Code.userCancelled.rawValue
    }
}
