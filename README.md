# Photos Heat Map

A native macOS app (Swift + SwiftUI, macOS 14+) that draws a heat map of where
the photos and videos in your Photos library were taken, next to a grid of the
photos inside the part of the map you are looking at. No third-party
dependencies, no API keys: PhotoKit for the library, MapKit for the map, a
hand-rolled density layer for the heat.

## Building

1. Open `Photos Heat Map.xcodeproj` in Xcode 15 or newer.
2. Select the *Photos Heat Map* target › Signing & Capabilities › pick your team.
3. Run. Grant Photos access when asked (Full Access is needed to favorite,
   delete or add to albums; read-only access shows the map but writes fail).

The project uses an Xcode "synchronized folder", so every file under
`Photos Heat Map/` is part of the target automatically.

## What's where

| Area | Files |
| --- | --- |
| App state | `Model/AppModel.swift` (main-actor `@Observable`), `Model/GeoAsset.swift`, `Model/PhotoFilters.swift`, `Model/AlbumInfo.swift` |
| PhotoKit reads | `Services/PhotoLibraryIndexer.swift` (actor: scan, albums, change diffing) |
| PhotoKit writes | `Services/PhotoLibraryActions.swift`, `Services/LibraryChangeObserver.swift` |
| Thumbnails / full images | `Services/ThumbnailProvider.swift` |
| Map | `Map/HeatMapView.swift` (MKMapView wrapper), `Map/HeatMapOverlay.swift` (renderer), `Map/HeatMapStyle.swift` (knobs), `Model/SpatialIndex.swift` |
| UI | `ContentView.swift`, `Views/PhotoGridView.swift`, `Views/ThumbnailCell.swift`, `Views/FilterBar.swift`, `Views/PhotoDetailView.swift`, `Views/SourcePickers.swift`, `Views/StatusViews.swift`, `Views/HeatLegendView.swift` |

## How the heat map works

MapKit has no heat map, so `HeatMapRenderer` (an `MKOverlayRenderer` on a
world-spanning overlay) draws one tile at a time in `draw(_:zoomScale:in:)`,
which MapKit calls on background threads:

1. **Bin size follows the zoom.** A bin is `cellPixels` wide *on screen*, so its
   size in map points is `cellPixels / zoomScale`. Zooming in automatically
   makes bins (and the blur) cover a smaller area; zooming out merges photos
   into bigger bins.
2. **Gather.** The renderer asks `SpatialIndex` (all assets sorted by map-point
   x, binary-searched by x and filtered by y) for every point inside the tile
   *plus a margin of one blur radius*, so blobs are not clipped at tile seams.
   Points are accumulated into a small `Float` raster (roughly 90×90 cells for
   a 256 pt tile).
3. **Blur.** A separable Gaussian blur, radius `ceil(blurPixels / cellPixels)`
   cells, sigma = radius / 2.5. It "scatters" from non-empty cells, which is
   cheap because most cells are empty.
4. **Normalize.** The blurred density is log-scaled against a *reference*
   density: the densest blurred bin anywhere in the data set at this zoom
   level (binned over all points at the quantized zoom, then the 2-D kernel
   evaluated at the 48 densest raw bins). It is cached per zoom level, so every
   tile at that zoom shares one scale and there are no seams. `minReference`
   stops a single photo from being painted red in a sparse library.
   `t = (log1p(density) / log1p(reference)) ^ gamma`
5. **Colorize + blit.** `t` indexes a 256-entry premultiplied RGBA lookup table
   built from the color ramp. The raster becomes a `CGImage` and is drawn into
   the tile (flipped, because MapKit's drawing context is y-down).

Because everything is drawn in map-point coordinates, the layer stays aligned
while panning and zooming; MapKit re-requests tiles at each new zoom level.

### Tweaking the look

All knobs live in `Map/HeatMapStyle.swift`:

| Knob | Effect |
| --- | --- |
| `cellPixels` | Bin size on screen (default 3 px). Smaller = sharper, more work per tile. |
| `blurPixels` | Gaussian radius on screen (default 14 px). Bigger = smoother, wider blobs. |
| `maxAlpha` | Opacity of the hottest color. |
| `alphaFadeIn` | Fraction of the range over which the fringe fades from transparent. |
| `gamma` | < 1 brightens sparse areas, > 1 emphasises the densest clusters. |
| `minReference` | Floor for the normalization reference (blurred photo-count units). |
| `ramp` | The cool→hot color stops. `classicRamp` (blue→cyan→green→yellow→red) is the default; `thermalRamp` is an alternative. |

`AppModel.heatStyle` is the live style; changing it from code (or a future
settings UI) rebuilds the lookup table and redraws.

If the heat tiles ever appear vertically mirrored on some OS version, the one
place to look is the flip at the end of `HeatMapRenderer.draw`.

## Grid, paging and performance notes

* Only metadata is read for the map. The scan enumerates every image/video
  once (off the main thread, with a progress bar) and keeps a compact
  `GeoAsset` struct (id, coordinate, pre-projected map point, date, type,
  favorite flag, duration) for the ones with a location. 500k assets is tens of MB.
* The grid shows assets inside the *visible map rect*, newest first. The rect is
  reported on every pan/zoom/divider-drag tick but debounced (200 ms) before
  the query runs in a detached task.
* First page = 50 items **or** everything within 7 days of the newest item in
  view, whichever is more. *Load More* appends the next chunk by the same rule.
  Pages are reset when the region or filters change; in-place library changes
  (favorites, deletions, album edits) keep your page and scroll position.
* Thumbnails come from `PHCachingImageManager` at 256 px, requested on appear
  and cancelled on disappear. The full-size image is only requested in the
  detail viewer (`DetailImageView.targetSize`, default `PHImageManagerMaximumSize`;
  cap it if you want cheaper decodes).
* PhotoKit change notifications are diffed against the fetch results, so edits
  made in Photos.app show up live.

## Things PhotoKit cannot do (and how the app degrades)

* **Multiple libraries.** PhotoKit only exposes the *System Photo Library*.
  There is no public API to open another `.photoslibrary`. The Library menu
  says so and offers to open Photos, where you can switch the system library
  (Photos › Settings › General › *Use as System Photo Library*), then Rescan.
* **People filter.** There is no public People/faces API on macOS. The filter
  is omitted rather than faked. Available filters: date range, photos/videos,
  favorites; each can optionally be applied to the heat map as well as the grid.
* **Deleting** goes through `PHAssetChangeRequest.deleteAssets`, so Photos
  shows its own confirmation dialog; cancelling it is silently ignored.
* **Add to Album** lists regular user albums (`canPerform(.addContent)`); smart
  and shared albums are shown in the album picker but cannot receive photos.

## Project settings worth knowing

* Deployment target 14.0; App Sandbox with the Photos Library and outgoing
  network (map tiles, iCloud originals) entitlements in `Photos Heat Map.entitlements`.
* `NSPhotoLibraryUsageDescription` is set through `INFOPLIST_KEY_…` in the target.
* Default actor isolation is `nonisolated` (classic model): `AppModel` is
  explicitly `@MainActor`, PhotoKit reads live in the `PhotoLibraryIndexer`
  actor, and the renderer is lock-protected because MapKit draws on multiple threads.
