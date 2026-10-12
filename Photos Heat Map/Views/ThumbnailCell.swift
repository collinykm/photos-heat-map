//
//  ThumbnailCell.swift
//  Photos Heat Map
//
//  One square tile in the grid. Loads a small thumbnail when it appears and
//  cancels the request when it scrolls away, so memory stays flat no matter how
//  big the page gets.
//

import SwiftUI
import AppKit
import Photos

struct ThumbnailCell: View {
    let asset: GeoAsset
    var targetSize: CGSize = ThumbnailProvider.gridThumbnailSize
    var isSelected: Bool = false

    @State private var image: NSImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .overlay {
                            Image(systemName: asset.kind == .video ? "video" : "photo")
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if asset.kind == .video {
                    Label(Self.durationText(asset.duration), systemImage: "video.fill")
                        .font(.caption2.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .overlay(alignment: .topLeading) {
                if asset.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .onAppear(perform: load)
            .onDisappear(perform: cancel)
            .onChange(of: asset.id) { _, _ in
                cancel()
                image = nil
                load()
            }
    }

    private func load() {
        guard image == nil, requestID == nil else { return }
        let id = asset.id
        if ThumbnailProvider.shared.cachedAsset(for: id) != nil {
            startRequest(id: id)
        } else {
            // The page was resolved before it was shown, but the PHAsset cache is bounded;
            // re-resolve this one and try again.
            Task {
                _ = await ThumbnailProvider.shared.resolveAssets([id])
                if asset.id == id, image == nil, requestID == nil {
                    startRequest(id: id)
                }
            }
        }
    }

    private func startRequest(id: String) {
        requestID = ThumbnailProvider.shared.requestThumbnail(id: id, targetSize: targetSize) { result, degraded in
            Task { @MainActor in
                guard let result else { return }
                // Don't replace a final image with a stale degraded one.
                if degraded && image != nil { return }
                image = result
                if !degraded { requestID = nil }
            }
        }
    }

    private func cancel() {
        ThumbnailProvider.shared.cancel(requestID)
        requestID = nil
    }

    static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
