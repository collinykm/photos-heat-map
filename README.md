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

1. **Bins follow the zoom.** A bin is `cellPixels` wide *on screen* (3 px), so
   its size in map points is `cellPixels / zoomScale`.
2. **Count.** The renderer asks `SpatialIndex` (all assets sorted by map-point
   x, binary-searched by x and filtered by y) for every point inside the tile
   *plus a margin of one stamp radius*, so shapes are not clipped at tile
   seams, and counts them into a small raster.
3. **Stamp.** Every non-empty bin adds `count ×` a radial bump: a 2-D lookup
   table with a Gaussian profile (sigma = radius / 3.5) that reaches exactly
   zero at `stampRadiusPixels` (42 px on screen). The result at any bin is the
   number of *stacked photo equivalents* there. Two things follow from the
   stamp being radial and fixed in screen pixels: a lone photo is a round
   ~18 px halo, the densest cluster grows into a ~39 px circle and stops
   (never a square, which is what a separable blur produces once it
   saturates), and photos within ~50 px of each other on screen join into one
   connected shape, so a road trip reads as a ribbon at city zoom and as one
   blob when zoomed out.
4. **Normalize.** `t = (density / saturation) ^ gamma` with `saturation` = 10
   stacked photos and `gamma` = 0.6. This is absolute, not relative to the
   hottest spot: a lone photo is faint violet at every zoom and ten stacked
   photos are yellow at every zoom, exactly like Google Photos' map.
5. **Colorize + blit.** `t` indexes a 256-entry premultiplied RGBA lookup table.
   Colour comes from the ramp; opacity is 0 below `alphaEdge` (crisp translucent
   edge), `edgeAlpha` right at the edge and rises to `maxAlpha` by `alphaFull`.
   The raster becomes a `CGImage` and is drawn into the tile (flipped, because
   MapKit's drawing context is y-down).

Because everything is drawn in map-point coordinates, the layer stays aligned
while panning and zooming; MapKit re-requests tiles at each new zoom level.
Cost per tile is (non-empty bins) × (stamp table size ≈ 29×29), a few
milliseconds even when every bin is occupied.

### Tweaking the look

The toolbar's **View** menu switches between three presets (Soft, Classic,
Thermal), an opacity level, and can hide the layer; all are remembered. The
presets and every knob live in `Map/HeatMapStyle.swift`:

| Knob | Effect |
| --- | --- |
| `stampRadiusPixels` | Support radius of one photo's bump on screen (42 px). The "how connected" knob: a lone photo's halo is about half this, clusters grow to all of it. |
| `saturation` | Stacked photos needed for the hottest colour (10). Lower = more yellow. |
| `gamma` | Exponent on the normalized density. < 1 brightens sparse areas, > 1 emphasises the densest clusters. |
| `cellPixels` | Raster bin size on screen (3 px). Smaller = finer, more work per tile. |
| `alphaEdge` / `edgeAlpha` / `alphaFull` / `maxAlpha` | The opacity curve: where the edge cuts off, how translucent the halo is, and how fast it reaches full opacity. |
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
