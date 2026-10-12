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

    @ObservationIgnored private let indexer = PhotoLibraryIndexer()
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var imageCount: Int { allAssets.reduce(0) { $0 + ($1.kind == .image ? 1 : 0) } }
    var videoCount: Int { allAssets.count - imageCount }

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
    }
}
