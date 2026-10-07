//
//  LocationManager.swift
//  ScoutCapture
//
//  Created by Brian Bennett on 2/7/26.
//

import Foundation
import CoreLocation
import CoreMotion
import Combine

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    @Published private(set) var lastLocation: CLLocation? = nil
    @Published private(set) var headingDegrees: Double? = nil
    @Published private(set) var cameraFacingHeadingDegrees: Double? = nil
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private let motion = CMMotionManager()
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
        cameraFacingHeadingDegrees = nil
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
        startCameraFacingHeading()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        motion.stopDeviceMotionUpdates()
        clearCachedLocation()
    }

    private func startCameraFacingHeading() {
        guard motion.isDeviceMotionAvailable,
              CMMotionManager.availableAttitudeReferenceFrames().contains(.xMagneticNorthZVertical),
              !motion.isDeviceMotionActive else { return }

        motion.deviceMotionUpdateInterval = 0.15
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical, to: .main) { [weak self] sample, _ in
            guard let self else { return }
            guard let sample, sample.magneticField.accuracy != .uncalibrated else {
                self.cameraFacingHeadingDegrees = nil
                return
            }
            let gravity = sample.gravity
            let field = sample.magneticField.field
            self.cameraFacingHeadingDegrees = Self.cameraFacingHeadingDegrees(
                gravity: SIMD3(gravity.x, gravity.y, gravity.z),
                magneticField: SIMD3(field.x, field.y, field.z)
            )
        }
    }

    static func cameraFacingHeadingDegrees(
        gravity: SIMD3<Double>,
        magneticField: SIMD3<Double>
    ) -> Double? {
        func dot(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
            lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
        }
        func normalized(_ vector: SIMD3<Double>) -> SIMD3<Double>? {
            let magnitude = sqrt(dot(vector, vector))
            guard magnitude > 0.05 else { return nil }
            return vector / magnitude
        }

        guard let down = normalized(gravity) else { return nil }
        let horizontalNorth = magneticField - down * dot(magneticField, down)
        guard let north = normalized(horizontalNorth) else { return nil }
        let east = SIMD3(
            down.y * north.z - down.z * north.y,
            down.z * north.x - down.x * north.z,
            down.x * north.y - down.y * north.x
        )
        let rearCamera = SIMD3<Double>(0, 0, -1)
        let horizontalCamera = rearCamera - down * dot(rearCamera, down)
        guard let facing = normalized(horizontalCamera) else { return nil }
        let degrees = atan2(dot(facing, east), dot(facing, north)) * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = authorizationStatusProvider(manager)

        if Self.permitsLocation(authorizationStatus) {
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() {
                manager.startUpdatingHeading()
            }
            startCameraFacingHeading()
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            motion.stopDeviceMotionUpdates()
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
