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
