//
//  LocationProvider.swift
//  Photos Heat Map
//
//  One-shot "where am I" so the map can open on the user's area. The user's
//  position is never drawn on the map; it is only used to pick the initial region.
//

import Foundation
import CoreLocation

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private(set) var lastLocation: CLLocation?
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var isRequesting = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var isDenied: Bool {
        switch manager.authorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Resolves with a location, or nil if access is denied, unavailable, or `timeout` passes.
    func currentLocation(timeout: Duration) async -> CLLocation? {
        if let lastLocation, Date().timeIntervalSince(lastLocation.timestamp) < 600 {
            return lastLocation
        }
        guard !isDenied else { return nil }

        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            startRequestIfNeeded()
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(with: self?.lastLocation)
            }
        }
    }

    private func startRequestIfNeeded() {
        guard !isRequesting else { return }
        isRequesting = true
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            finish(with: nil)
        }
    }

    private func finish(with location: CLLocation?) {
        let pending = waiters
        waiters.removeAll()
        isRequesting = false
        for waiter in pending {
            waiter.resume(returning: location)
        }
    }

    // MARK: CLLocationManagerDelegate (delivered on the main thread)

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isRequesting else { return }
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                self.finish(with: nil)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in
            if let latest { self.lastLocation = latest }
            self.finish(with: latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: self.lastLocation)
        }
    }
}
