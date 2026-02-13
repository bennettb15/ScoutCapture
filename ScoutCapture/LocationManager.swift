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
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
    }

    func requestPermissionIfNeeded() {
        let status = manager.authorizationStatus
        authorizationStatus = status

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        requestPermissionIfNeeded()

        let status = manager.authorizationStatus
        authorizationStatus = status

        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return
        }

        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus

        if authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No-op, we simply save photos without GPS if location fails
    }
}
