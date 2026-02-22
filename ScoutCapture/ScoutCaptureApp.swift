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
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appState)
        }
    }
}

private struct AppRootView: View {
    @EnvironmentObject private var appState: AppState

    private var showPropertyPicker: Binding<Bool> {
        Binding(
            get: { !appState.isLoading && appState.selectedPropertyID == nil },
            set: { _ in }
        )
    }

    var body: some View {
        Group {
            if appState.isLoading {
                LoadingView()
            } else {
                ContentView()
            }
        }
        .task {
            appState.loadIfNeeded()
        }
        .sheet(isPresented: showPropertyPicker) {
            PropertyPickerSheet()
                .environmentObject(appState)
        }
    }
}
