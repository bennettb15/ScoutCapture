//
//  ScoutCaptureApp.swift
//  ScoutCapture
//
//  Created by Brian Bennett on 2/3/26.
//

import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // Keep the app in portrait.
        return .portrait
    }
}

@main
struct ScoutCaptureApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
