//
//  PhotoGridView.swift
//  Photos Heat Map
//
//  Right-hand pane: a lazy grid of the photos inside the visible map region,
//  newest first, paged (50 items or 7 days, whichever is more).
//

import SwiftUI

struct PhotoGridView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 180), spacing: 3)]
    private static let topAnchor = "grid-top"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id(Self.topAnchor)

                    if model.visibleAssets.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(model.displayedAssets) { asset in
                                ThumbnailCell(asset: asset, isSelected: model.selectedAssetID == asset.id)
                                    .onTapGesture { model.select(asset) }
                            }
                        }
                        .padding(3)

                        footer
                    }
                }
                .onChange(of: model.pageGeneration) { _, _ in
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(headerText)
                .font(.callout)
                .lineLimit(1)
            Spacer()
            if model.isQuerying {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var headerText: String {
        let total = model.visibleAssets.count
        let shown = model.displayedAssets.count
        if total == 0 { return "No photos in view" }
        if shown >= total {
            return "\(total.formatted()) in view"
        }
        return "\(total.formatted()) in view · showing \(shown.formatted())"
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing here", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Pan or zoom the map to an area with photos.")
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    @ViewBuilder
    private var footer: some View {
        if model.canLoadMore {
            Button {
                model.loadMore()
            } label: {
                Label("Load More (\((model.visibleAssets.count - model.displayedAssets.count).formatted()) remaining)",
                      systemImage: "arrow.down.circle")
            }
            .controlSize(.large)
            .padding(.vertical, 14)
        } else if !model.displayedAssets.isEmpty {
            Text("All \(model.displayedAssets.count.formatted()) shown")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
        }
    }
}
