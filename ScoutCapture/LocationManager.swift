//
//  LocationManager.swift
//  ScoutCapture
//
//  Created by Brian Bennett on 2/7/26.
//

import Foundation
import CoreLocation
import Combine

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var lastLocation: CLLocation? = nil
    @Published private(set) var headingDegrees: Double? = nil
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let authorizationStatusProvider: (CLLocationManager) -> CLAuthorizationStatus

    private static func permitsLocation(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    static func locationForCapture(_ location: CLLocation?, authorizationStatus: CLAuthorizationStatus) -> CLLocation? {
        permitsLocation(authorizationStatus) ? location : nil
    }

    private func clearCachedLocation() {
        lastLocation = nil
        headingDegrees = nil
    }

    func currentLocationForCapture() -> CLLocation? {
        let status = authorizationStatusProvider(manager)
        authorizationStatus = status
        guard Self.permitsLocation(status) else {
            clearCachedLocation()
            return nil
        }
        return Self.locationForCapture(lastLocation, authorizationStatus: status)
    }

    init(authorizationStatusProvider: @escaping (CLLocationManager) -> CLAuthorizationStatus = { $0.authorizationStatus }) {
        self.authorizationStatusProvider = authorizationStatusProvider
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.headingFilter = 1
    }

    func requestPermissionIfNeeded() {
        let status = authorizationStatusProvider(manager)
        authorizationStatus = status

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        requestPermissionIfNeeded()

        let status = authorizationStatusProvider(manager)
        authorizationStatus = status

        guard Self.permitsLocation(status) else {
            clearCachedLocation()
            return
        }

        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        clearCachedLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = authorizationStatusProvider(manager)

        if Self.permitsLocation(authorizationStatus) {
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            clearCachedLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard Self.permitsLocation(authorizationStatusProvider(manager)) else {
            clearCachedLocation()
            return
        }
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No-op, we simply save photos without GPS if location fails
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard Self.permitsLocation(authorizationStatusProvider(manager)) else {
            clearCachedLocation()
            return
        }
        let trueHeading = newHeading.trueHeading
        let heading = trueHeading >= 0 ? trueHeading : newHeading.magneticHeading
        guard heading >= 0 else { return }
        headingDegrees = heading.truncatingRemainder(dividingBy: 360)
    }
}
