import XCTest
@testable import ScoutCapture

private struct AuthPasswordRecoveryTestError: LocalizedError {
    var errorDescription: String? {
        "Reset request failed."
    }
}

@MainActor
final class AuthPasswordRecoveryTests: XCTestCase {
    private func makeAppState() -> AppState {
        let suiteName = "AuthPasswordRecoveryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return AppState(
            localStore: LocalStore(testStorageRootURL: FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)),
            userDefaults: defaults,
            environment: [:],
            disableCloudBackupForTests: true
        )
    }

    func testForgotPasswordControlTextIsAvailable() {
        XCTAssertEqual(PasswordRecoveryFlow.forgotPasswordButtonTitle, "Forgot Password?")
    }

    func testPasswordResetConfirmationTextIsAvailable() {
        XCTAssertEqual(PasswordRecoveryFlow.successConfirmationTitle, "Password Reset Email Sent")
    }

    func testTypedSignInEmailPrefillsResetEmail() {
        let model = PasswordRecoveryFormModel()

        model.prepare(signInEmail: "  customer@example.com  ")

        XCTAssertEqual(model.email, "customer@example.com")
    }

    func testPasswordResetRequestUsesExactRedirectURL() async throws {
        let appState = makeAppState()
        var capturedEmail: String?
        var capturedRedirectURL: URL?
        appState._debugSetPasswordRecoveryRequestOverrideForTests { email, redirectURL in
            capturedEmail = email
            capturedRedirectURL = redirectURL
        }

        try await appState.requestPasswordReset(email: " customer@example.com ")

        XCTAssertEqual(capturedEmail, "customer@example.com")
        XCTAssertEqual(capturedRedirectURL?.absoluteString, "https://scoutclear.com/reset-password")
    }

    func testInFlightStatePreventsDuplicatePasswordResetRequest() async {
        let model = PasswordRecoveryFormModel()
        model.prepare(signInEmail: "customer@example.com")
        let started = expectation(description: "first request started")
        var requestCount = 0
        var releaseFirstRequest: CheckedContinuation<Void, Never>?

        let firstRequest = Task { @MainActor in
            await model.submit { _, _ in
                requestCount += 1
                started.fulfill()
                await withCheckedContinuation { continuation in
                    releaseFirstRequest = continuation
                }
            }
        }

        await fulfillment(of: [started], timeout: 1.0)

        let duplicateResult = await model.submit { _, _ in
            requestCount += 1
        }
        releaseFirstRequest?.resume()
        let firstResult = await firstRequest.value

        XCTAssertFalse(duplicateResult)
        XCTAssertTrue(firstResult)
        XCTAssertEqual(requestCount, 1)
    }

    func testSuccessStateIsShown() async {
        let model = PasswordRecoveryFormModel()
        model.prepare(signInEmail: "customer@example.com")

        let didSend = await model.submit { _, _ in }

        XCTAssertTrue(didSend)
        XCTAssertEqual(model.successMessage, PasswordRecoveryFlow.successMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isRequestInFlight)
    }

    func testFailureStateIsShownAndCanRetry() async {
        let model = PasswordRecoveryFormModel()
        model.prepare(signInEmail: "customer@example.com")

        let didSend = await model.submit { _, _ in
            throw AuthPasswordRecoveryTestError()
        }

        XCTAssertFalse(didSend)
        XCTAssertEqual(model.errorMessage, "Reset request failed.")
        XCTAssertNil(model.successMessage)
        XCTAssertFalse(model.isRequestInFlight)
        XCTAssertTrue(model.canSubmit)
    }
}
