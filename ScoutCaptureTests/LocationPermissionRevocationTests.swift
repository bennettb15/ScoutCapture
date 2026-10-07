import CoreLocation
import XCTest
@testable import ScoutCapture

@MainActor
final class LocationPermissionRevocationTests: XCTestCase {
    func testRevocationWhileCameraIsOpenDiscardsCachedGPSAndDelayedUpdates() {
        var status: CLAuthorizationStatus = .authorizedWhenInUse
        let manager = LocationManager(authorizationStatusProvider: { _ in status })
        let delegateManager = CLLocationManager()
        let previousFix = CLLocation(latitude: 40.0, longitude: -73.0)

        manager.locationManager(delegateManager, didUpdateLocations: [previousFix])
        XCTAssertNotNil(manager.currentLocationForCapture())

        status = .denied
        XCTAssertNil(manager.currentLocationForCapture())
        XCTAssertNil(manager.lastLocation)

        manager.locationManager(delegateManager, didUpdateLocations: [previousFix])
        XCTAssertNil(manager.currentLocationForCapture())
        XCTAssertNil(manager.lastLocation)
    }

    func testRearCameraHeadingTracksViewingDirectionInPortrait() {
        let gravity = SIMD3<Double>(0, -1, 0)
        let bearings: [(magneticNorth: SIMD3<Double>, expected: Double)] = [
            (SIMD3(0, 0, -1), 0),
            (SIMD3(-1, 0, 0), 90),
            (SIMD3(0, 0, 1), 180),
            (SIMD3(1, 0, 0), 270)
        ]
        for bearing in bearings {
            let actual = LocationManager.cameraFacingHeadingDegrees(
                gravity: gravity,
                magneticField: bearing.magneticNorth
            )
            XCTAssertNotNil(actual)
            XCTAssertEqual(actual ?? -1, bearing.expected, accuracy: 0.01)
        }
    }

    func testRearCameraHeadingIsUnavailableWhenPointedStraightDown() {
        XCTAssertNil(LocationManager.cameraFacingHeadingDegrees(
            gravity: SIMD3<Double>(0, 0, -1),
            magneticField: SIMD3<Double>(0, 1, 0)
        ))
    }

    func testRelaunchAfterRevocationHasNoGPSUntilNewAuthorizedFix() {
        var status: CLAuthorizationStatus = .authorizedWhenInUse
        let delegateManager = CLLocationManager()
        let previousFix = CLLocation(latitude: 40.0, longitude: -73.0)
        let firstLaunch = LocationManager(authorizationStatusProvider: { _ in status })
        firstLaunch.locationManager(delegateManager, didUpdateLocations: [previousFix])
        XCTAssertNotNil(firstLaunch.currentLocationForCapture())

        status = .denied
        firstLaunch.locationManagerDidChangeAuthorization(delegateManager)
        XCTAssertNil(firstLaunch.lastLocation)

        let reopened = LocationManager(authorizationStatusProvider: { _ in status })
        XCTAssertNil(reopened.currentLocationForCapture())
        status = .authorizedWhenInUse
        XCTAssertNil(reopened.currentLocationForCapture())
        reopened.locationManager(delegateManager, didUpdateLocations: [previousFix])
        XCTAssertNotNil(reopened.currentLocationForCapture())
    }
}
