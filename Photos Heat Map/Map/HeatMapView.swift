//
//  HeatMapView.swift
//  Photos Heat Map
//
//  SwiftUI wrapper around MKMapView with the heat overlay attached. Reports the
//  visible map rect back to the model whenever it changes (pan, zoom, resize).
//

import SwiftUI
import AppKit
import MapKit

/// A one-shot request to make the map show a given rect.
struct MapFitRequest: Equatable {
    let id = UUID()
    let rect: MKMapRect
    let animated: Bool

    static func == (lhs: MapFitRequest, rhs: MapFitRequest) -> Bool { lhs.id == rhs.id }
}

struct HeatMapView: NSViewRepresentable {
    let index: SpatialIndex
    let style: HeatMapStyle
    let appearance: MapAppearance
    let fitRequest: MapFitRequest?
    let onVisibleRectChange: (MKMapRect) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.preferredConfiguration = appearance.makeConfiguration()
        context.coordinator.appearance = appearance
        map.showsUserLocation = false
        map.showsZoomControls = true
        map.showsCompass = true
        map.showsScale = true
        map.showsPitchControl = true
        map.isPitchEnabled = true
        map.isRotateEnabled = true

        let overlay = HeatMapOverlay()
        let renderer = HeatMapRenderer(overlay: overlay, style: style)
        context.coordinator.renderer = renderer
        context.coordinator.style = style
        map.addOverlay(overlay, level: .aboveRoads)

        map.postsFrameChangedNotifications = true
        context.coordinator.observeFrame(of: map)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onVisibleRectChange = onVisibleRectChange

        if coordinator.indexID != index.id {
            coordinator.indexID = index.id
            coordinator.renderer?.update(index: index)
        }
        if coordinator.style != style {
            coordinator.style = style
            coordinator.renderer?.update(style: style)
        }
        if coordinator.appearance != appearance {
            coordinator.appearance = appearance
            map.preferredConfiguration = appearance.makeConfiguration()
        }
        if let fit = fitRequest, fit.id != coordinator.lastFitID {
            coordinator.lastFitID = fit.id
            let padding = NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
            map.setVisibleMapRect(fit.rect, edgePadding: padding, animated: fit.animated)
        }
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil
        coordinator.stopObserving()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var renderer: HeatMapRenderer?
        var indexID: UUID?
        var style: HeatMapStyle?
        var appearance: MapAppearance?
        var lastFitID: UUID?
        var onVisibleRectChange: ((MKMapRect) -> Void)?
        private var frameObserver: NSObjectProtocol?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is HeatMapOverlay, let renderer {
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onVisibleRectChange?(mapView.visibleMapRect)
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            onVisibleRectChange?(mapView.visibleMapRect)
        }

        /// Dragging the split-view divider resizes the map; make sure that counts as a
        /// region change too.
        func observeFrame(of map: MKMapView) {
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: map, queue: .main
            ) { [weak self, weak map] _ in
                guard let map else { return }
                self?.onVisibleRectChange?(map.visibleMapRect)
            }
        }

        func stopObserving() {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            frameObserver = nil
        }

        deinit { stopObserving() }
    }
}
