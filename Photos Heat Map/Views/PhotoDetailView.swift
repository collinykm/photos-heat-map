//
//  PhotoDetailView.swift
//  Photos Heat Map
//
//  Full-window viewer in the spirit of Apple Photos: place + date on top with
//  a favorite / add-to-album / delete toolbar, the full-size photo (or video)
//  in the middle, and a filmstrip of the current grid page at the bottom.
//  The full-size image is only requested here, never for the grid.
//

import SwiftUI
import AppKit
import AVKit
import Photos
import CoreLocation

struct PhotoDetailView: View {
    @Environment(AppModel.self) private var model
    let asset: GeoAsset

    @State private var placeName: String?
    @State private var showNewAlbumSheet = false
    @State private var newAlbumName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            Divider()

            ZStack {
                Color.black
                if asset.kind == .video {
                    DetailVideoView(assetID: asset.id)
                } else {
                    DetailImageView(assetID: asset.id)
                }
                navigationArrows
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            FilmstripView(assets: model.displayedAssets, selectedID: asset.id) { model.select($0) }
                .frame(height: 84)
                .background(.bar)
        }
        .background(Color.black)
        .background(keyboardShortcuts)
        .task(id: asset.id) {
            placeName = nil
            placeName = await Geocoder.shared.placeName(for: asset)
        }
        .sheet(isPresented: $showNewAlbumSheet) {
            NewAlbumSheet(name: $newAlbumName) {
                let title = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                Task { await model.createAlbum(titled: title, adding: asset) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                model.closeDetail()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close (Esc)")

            Spacer()

            VStack(spacing: 2) {
                Text(placeName ?? coordinateText)
                    .font(.headline)
                    .lineLimit(1)
                Text(dateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 4) {
                Text(positionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)

                Button {
                    Task { await model.toggleFavorite(asset) }
                } label: {
                    Image(systemName: asset.isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(asset.isFavorite ? Color.pink : Color.primary)
                }
                .help(asset.isFavorite ? "Remove from Favorites" : "Add to Favorites")

                Menu {
                    if model.userAlbums.isEmpty {
                        Text("No albums")
                    } else {
                        ForEach(model.userAlbums) { album in
                            Button(album.title) {
                                Task { await model.add(asset, to: album) }
                            }
                        }
                    }
                    Divider()
                    Button("New Album…") {
                        newAlbumName = ""
                        showNewAlbumSheet = true
                    }
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add to Album")

                Button {
                    Task { await model.deleteAsset(asset) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
    }

    private var coordinateText: String {
        String(format: "%.4f, %.4f", asset.latitude, asset.longitude)
    }

    private var dateText: String {
        guard let date = asset.date else { return "Unknown date" }
        return date.formatted(date: .complete, time: .shortened)
    }

    private var positionText: String {
        if let index = model.selectedIndex {
            return "\(index + 1) of \(model.displayedAssets.count)"
        }
        return ""
    }

    // MARK: Navigation

    private var navigationArrows: some View {
        HStack {
            arrowButton("chevron.left", enabled: model.hasPrevious) { model.selectPrevious() }
            Spacer()
            arrowButton("chevron.right", enabled: model.hasNext) { model.selectNext() }
        }
        .padding(.horizontal, 12)
    }

    private func arrowButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.25)
        .disabled(!enabled)
    }

    /// Invisible buttons carry the keyboard shortcuts (works without focus juggling).
    private var keyboardShortcuts: some View {
        Group {
            Button("") { model.selectPrevious() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.selectNext() }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.closeDetail() }.keyboardShortcut(.cancelAction)
            Button("") { Task { await model.toggleFavorite(asset) } }.keyboardShortcut(".", modifiers: .command)
            Button("") { Task { await model.deleteAsset(asset) } }.keyboardShortcut(.delete, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}

// MARK: - Full-size image

struct DetailImageView: View {
    let assetID: String

    /// Pixel size to request. `PHImageManagerMaximumSize` is the original resolution;
    /// swap in e.g. `CGSize(width: 4096, height: 4096)` to cap decode cost.
    static let targetSize = PHImageManagerMaximumSize

    @State private var image: NSImage?
    @State private var isFinal = false
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .overlay(alignment: .topTrailing) {
            if image != nil && !isFinal {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
            }
        }
        .task(id: assetID) { await load() }
        .onDisappear { cancel() }
    }

    private func load() async {
        cancel()
        image = nil
        isFinal = false
        let id = assetID
        var phAsset = ThumbnailProvider.shared.cachedAsset(for: id)
        if phAsset == nil {
            phAsset = await ThumbnailProvider.shared.resolveAssets([id])[id]
        }
        guard let phAsset, !Task.isCancelled else { return }
        requestID = ThumbnailProvider.shared.requestFullImage(asset: phAsset, targetSize: Self.targetSize) { result, degraded in
            Task { @MainActor in
                guard assetID == id, let result else { return }
                if degraded && isFinal { return }
                image = result
                isFinal = !degraded
            }
        }
    }

    private func cancel() {
        ThumbnailProvider.shared.cancel(requestID)
        requestID = nil
    }
}

// MARK: - Video

struct DetailVideoView: View {
    let assetID: String
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task(id: assetID) { await load() }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func load() async {
        player?.pause()
        player = nil
        let id = assetID
        var phAsset = ThumbnailProvider.shared.cachedAsset(for: id)
        if phAsset == nil {
            phAsset = await ThumbnailProvider.shared.resolveAssets([id])[id]
        }
        guard let phAsset, !Task.isCancelled else { return }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic

        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            let box = ResumeOnce(continuation)
            PHImageManager.default().requestPlayerItem(forVideo: phAsset, options: options) { item, _ in
                box.resume(with: item)
            }
        }
        guard assetID == id, let item else { return }
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        newPlayer.play()
    }

    /// PhotoKit may invoke a result handler more than once; a continuation must resume once.
    private final class ResumeOnce: @unchecked Sendable {
        private var continuation: CheckedContinuation<AVPlayerItem?, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<AVPlayerItem?, Never>) { self.continuation = continuation }
        func resume(with item: AVPlayerItem?) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: item)
        }
    }
}

// MARK: - Filmstrip

struct FilmstripView: View {
    let assets: [GeoAsset]
    let selectedID: String
    let onSelect: (GeoAsset) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(assets) { asset in
                        ThumbnailCell(asset: asset,
                                      targetSize: ThumbnailProvider.stripThumbnailSize,
                                      isSelected: asset.id == selectedID)
                            .frame(width: 64, height: 64)
                            .onTapGesture { onSelect(asset) }
                            .id(asset.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
            }
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            .onChange(of: selectedID) { _, newValue in
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

// MARK: - New album sheet

struct NewAlbumSheet: View {
    @Binding var name: String
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Album").font(.headline)
            TextField("Album name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit(create)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func create() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onCreate()
        dismiss()
    }
}
