//
//  ThumbnailProvider.swift
//  Photos Heat Map
//
//  Resolves PHAssets for the identifiers in the current grid page and serves
//  small thumbnails through a PHCachingImageManager. Full-size images are only
//  requested by the detail view (see requestFullImage).
//

import Foundation
import AppKit
import Photos

final class ThumbnailProvider: @unchecked Sendable {

    static let shared = ThumbnailProvider()

    /// Pixel size requested for grid thumbnails (covers a ~128 pt cell on a Retina display).
    static let gridThumbnailSize = CGSize(width: 256, height: 256)
    /// Pixel size for the filmstrip under the detail view.
    static let stripThumbnailSize = CGSize(width: 120, height: 120)

    private let manager = PHCachingImageManager()
    private let lock = NSLock()
    private var assetCache: [String: PHAsset] = [:]
    private let resolveQueue = DispatchQueue(label: "PhotosHeatMap.resolve", qos: .userInitiated)

    private init() {
        manager.allowsCachingHighQualityImages = false
    }

    // MARK: - PHAsset lookup

    func cachedAsset(for id: String) -> PHAsset? {
        lock.lock()
        defer { lock.unlock() }
        return assetCache[id]
    }

    /// Fetches the PHAssets for `ids` that are not cached yet (one batched fetch, off
    /// the main thread) and returns the full mapping for the requested ids.
    func resolveAssets(_ ids: [String]) async -> [String: PHAsset] {
        await withCheckedContinuation { continuation in
            resolveQueue.async { [self] in
                lock.lock()
                let missing = ids.filter { assetCache[$0] == nil }
                lock.unlock()

                if !missing.isEmpty {
                    let result = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
                    var fetched: [String: PHAsset] = [:]
                    fetched.reserveCapacity(result.count)
                    result.enumerateObjects { asset, _, _ in
                        fetched[asset.localIdentifier] = asset
                    }
                    lock.lock()
                    // Keep the cache bounded; it only needs to cover the pages on screen.
                    if assetCache.count > 6_000 {
                        assetCache.removeAll(keepingCapacity: true)
                    }
                    assetCache.merge(fetched) { _, new in new }
                    lock.unlock()
                }

                lock.lock()
                var out: [String: PHAsset] = [:]
                out.reserveCapacity(ids.count)
                for id in ids {
                    if let asset = assetCache[id] { out[id] = asset }
                }
                lock.unlock()
                continuation.resume(returning: out)
            }
        }
    }

    /// Drops a cached PHAsset (after deletion or when a change notification says it changed).
    func invalidate(ids: [String]) {
        lock.lock()
        for id in ids { assetCache.removeValue(forKey: id) }
        lock.unlock()
    }

    // MARK: - Caching hints

    private static func thumbnailOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return options
    }

    func startCaching(ids: [String], targetSize: CGSize) {
        let assets = ids.compactMap { cachedAsset(for: $0) }
        guard !assets.isEmpty else { return }
        manager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: Self.thumbnailOptions())
    }

    func stopCaching(ids: [String], targetSize: CGSize) {
        let assets = ids.compactMap { cachedAsset(for: $0) }
        guard !assets.isEmpty else { return }
        manager.stopCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: Self.thumbnailOptions())
    }

    func stopCachingAll() {
        manager.stopCachingImagesForAllAssets()
    }

    // MARK: - Requests

    /// Requests a thumbnail. The handler runs on the main thread and may be called twice
    /// (a quick degraded version, then the final one). Returns nil if the asset is unknown.
    @discardableResult
    func requestThumbnail(id: String, targetSize: CGSize,
                          handler: @escaping @Sendable (NSImage?, Bool) -> Void) -> PHImageRequestID? {
        guard let asset = cachedAsset(for: id) else { return nil }
        return manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill,
                                    options: Self.thumbnailOptions()) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if cancelled { return }
            handler(image, degraded)
        }
    }

    /// Requests the full-resolution image for the detail view. Handler on main thread.
    @discardableResult
    func requestFullImage(asset: PHAsset, targetSize: CGSize,
                          handler: @escaping @Sendable (NSImage?, Bool) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return manager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFit,
                                    options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
            if cancelled { return }
            handler(image, degraded)
        }
    }

    func cancel(_ requestID: PHImageRequestID?) {
        guard let requestID else { return }
        manager.cancelImageRequest(requestID)
    }
}
