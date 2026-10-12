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

MapKit has no heat map, so `HeatMapRenderer` (an `MKOverlayRenderer` on an
overlay that covers the data's bounding box) draws one tile at a time in
`draw(_:zoomScale:in:)`, which MapKit calls on background threads:

1. **Bins follow the zoom.** A bin is `cellPixels` wide *on screen*, so its size
   in map points is `cellPixels / zoomScale`.
2. **Gather.** The renderer asks `SpatialIndex` (all assets sorted by map-point
   x, binary-searched by x and filtered by y) for every point inside the tile
   *plus a margin of one kernel radius*, so shapes are not clipped at tile
   seams. Points are counted into a small `Float` raster.
3. **Stamp.** A separable, peak-1 Gaussian (radius `kernelRadiusPixels` on
   screen, sigma = radius / 2.5) is convolved over the raster. Because the
   kernel peaks at 1, the result at any pixel is the number of *stacked photo
   equivalents* there. Since the radius is fixed in screen pixels, photos taken
   a few hundred metres apart chain into one shape at city zoom and merge into
   one hot blob when zoomed out; this is what makes the map read like Google
   Photos' rather than a field of dots.
4. **Normalize.** With `.absolute` scaling (default), `t = (density / saturation) ^ gamma`:
   a lone photo is a faint violet bump and `saturation` stacked photos are the
   hottest colour, regardless of zoom. With `.relative` scaling (the Classic
   preset), density is log-scaled against the densest blob anywhere in the data
   at this zoom level (binned over all points at the quantized zoom, then the
   2-D kernel evaluated at the 48 densest raw bins, cached per level).
5. **Colorize + blit.** `t` indexes a 256-entry premultiplied RGBA lookup table.
   Colour comes from the ramp; opacity is 0 below `alphaEdge` (crisp translucent
   edge), `edgeAlpha` right at the edge and rises to `maxAlpha` by `alphaFull`.
   The raster becomes a `CGImage` and is drawn into the tile (flipped, because
   MapKit's drawing context is y-down).

Because everything is drawn in map-point coordinates, the layer stays aligned
while panning and zooming; MapKit re-requests tiles at each new zoom level.

### Tweaking the look

The toolbar's **View** menu switches between three presets (Soft, Classic,
Thermal), an opacity level, and can hide the layer; all are remembered. The
presets and every knob live in `Map/HeatMapStyle.swift`:

| Knob | Effect |
| --- | --- |
| `kernelRadiusPixels` | Radius of one photo's bump on screen (Soft: 34 px). The main "how connected" knob: bigger joins photos that are farther apart. |
| `cellPixels` | Raster bin size on screen (Soft: 2 px). Smaller = finer, more work per tile. |
| `scaling` | `.absolute` (photo counts, zoom-independent) or `.relative` (to the hottest spot at this zoom). |
| `saturation` | Absolute mode: stacked photos needed for the hottest colour (Soft: 10). Lower = more yellow. |
| `gamma` | Exponent on the normalized density. < 1 brightens sparse areas, > 1 emphasises the densest clusters. |
| `alphaEdge` / `edgeAlpha` / `alphaFull` / `maxAlpha` | The opacity curve: where the edge cuts off, how translucent the halo is, and how fast it reaches full opacity. |
| `minReference` | Relative mode: floor for the normalization reference. |
| `ramp` | Colour stops. `softRamp` (violet→magenta→orange→yellow) is the default; `classicRamp` and `thermalRamp` are alternatives. |

To add a preset, append a `HeatMapStyle` to `HeatMapStyle.presets`; it shows up
in the menu automatically.

If the heat tiles ever appear vertically mirrored on some OS version, the one
place to look is the flip at the end of `HeatMapRenderer.draw`.

## Map view

The **View** menu also picks the base map (Standard, Muted, Satellite, Hybrid)
and the projection: *Flat*, or *Globe & Terrain* (MapKit's realistic elevation,
which shows a 3-D globe when zoomed far out and terrain when the map is tilted
with the pitch control or Option-drag). These are `MKMapConfiguration`s built in
`Map/MapAppearance.swift` and persisted in UserDefaults.

MapKit forces the elevation style back to flat when any overlay is added at
`.aboveLabels`, so the heat overlay is added at `.aboveRoads` and is limited to
the data's bounding box. If the globe still does not appear, use View › Show
Heat Layer to check whether the overlay is the cause, and try Hybrid, which is
reported to keep the globe where Standard sometimes falls back to 2-D.

On launch the map opens on your current area (about 40 km across) using a
one-shot CoreLocation fix; your position is never drawn. If location access is
denied or slow, it falls back to fitting the central 96 % of your photos. The
**My Location** toolbar button jumps back there at any time.

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

* Deployment target 14.0; App Sandbox with the Photos Library, Location and
  outgoing network (map tiles, iCloud originals) entitlements in `Photos Heat Map.entitlements`.
* `NSPhotoLibraryUsageDescription` and the location usage strings are set through
  `INFOPLIST_KEY_…` build settings in the target.
* Default actor isolation is `nonisolated` (classic model): `AppModel` is
  explicitly `@MainActor`, PhotoKit reads live in the `PhotoLibraryIndexer`
  actor, and the renderer is lock-protected because MapKit draws on multiple threads.
