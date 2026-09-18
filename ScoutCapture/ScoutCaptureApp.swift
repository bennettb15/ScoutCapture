//
//  ScoutCaptureApp.swift
//  ScoutCapture
//
//  Created by Brian Bennett on 2/3/26.
//

import SwiftUI
import UIKit
import MapKit
import Combine
import ImageIO
import UniformTypeIdentifiers

private let isVerboseConsoleLoggingEnabled = false

@inline(__always)
private func verboseLog(_ message: @autoclosure () -> String) {
    guard isVerboseConsoleLoggingEnabled else { return }
    print(message())
}

#if DEBUG
enum DebugSessionSnapshotAutoUploadDefaultsBootstrap {
    static let argumentName = "--scoutcapture-debug-session-snapshot-auto-upload-defaults"

    private static let requiredTrueKeys: Set<String> = [
        "session_snapshot_auto_upload_enabled",
        "session_snapshot_production_auto_upload_target_enabled",
        "session_snapshot_shadow_write_enabled"
    ]
    private static let requiredFalseKeys: Set<String> = [
        "supabase_read_enabled",
        "canonical_read_candidate_enabled"
    ]
    private static let orgAllowlistKey = "session_snapshot_auto_upload_org_allowlist"
    private static let clearedKeys: Set<String> = [
        "session_snapshot_auto_upload_property_allowlist",
        "canonical_read_candidate_org_allowlist",
        "canonical_read_candidate_property_allowlist",
        "canonical_read_candidate_session_allowlist"
    ]

    @discardableResult
    static func applyIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        userDefaults: UserDefaults = .standard,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        guard let argumentIndex = arguments.firstIndex(of: argumentName) else { return false }
        let payloadIndex = arguments.index(after: argumentIndex)
        guard arguments.indices.contains(payloadIndex) else {
            print("[DebugSessionSnapshotAutoUploadDefaultsBootstrap] skipped reason=missing_payload")
            return false
        }
        guard isAllowedBundleIdentifier(bundleIdentifier) else {
            print("[DebugSessionSnapshotAutoUploadDefaultsBootstrap] skipped reason=bundle_not_allowed")
            return false
        }
        guard let data = Data(base64Encoded: arguments[payloadIndex]),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              validate(values: values) else {
            print("[DebugSessionSnapshotAutoUploadDefaultsBootstrap] skipped reason=invalid_payload")
            return false
        }

        for key in requiredTrueKeys {
            userDefaults.set(true, forKey: key)
        }
        for key in requiredFalseKeys {
            userDefaults.set(false, forKey: key)
        }
        userDefaults.set(values[orgAllowlistKey] as? String, forKey: orgAllowlistKey)
        for key in clearedKeys {
            userDefaults.removeObject(forKey: key)
        }
        userDefaults.synchronize()
        let appliedKeys = requiredTrueKeys.union(requiredFalseKeys).union([orgAllowlistKey])
        print("[DebugSessionSnapshotAutoUploadDefaultsBootstrap] applied keys=\(appliedKeys.sorted().joined(separator: ",")) cleared=\(clearedKeys.sorted().joined(separator: ","))")
        return true
    }

    private static func isAllowedBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.scoutsystems.scoutcapture.dev" || bundleIdentifier.hasSuffix(".dev")
    }

    private static func validate(values: [String: Any]) -> Bool {
        let allowedKeys = requiredTrueKeys.union(requiredFalseKeys).union([orgAllowlistKey])
        guard Set(values.keys) == allowedKeys else { return false }
        guard requiredTrueKeys.allSatisfy({ values[$0] as? Bool == true }) else { return false }
        guard requiredFalseKeys.allSatisfy({ values[$0] as? Bool == false }) else { return false }
        guard let rawAllowlist = values[orgAllowlistKey] as? String else { return false }
        return parsedUUIDs(from: rawAllowlist).isEmpty == false
    }

    private static func parsedUUIDs(from rawValue: String) -> [UUID] {
        rawValue
            .split { character in
                character == "," || character == ";" || character == "\n" || character == "\t" || character == " "
            }
            .compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
#endif

final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // Keep the app in portrait.
        return .portrait
    }
}

private final class PortraitLockedHostingController<Content: View>: UIHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.insetsLayoutMarginsFromSafeArea = false
        if #available(iOS 16.4, *) {
            safeAreaRegions = [.container]
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .portrait
    }

    override var shouldAutorotate: Bool {
        false
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .portrait
    }
}

private struct PortraitLockedRootView<Content: View>: UIViewControllerRepresentable {
    let rootView: Content

    func makeUIViewController(context: Context) -> PortraitLockedHostingController<Content> {
        PortraitLockedHostingController(rootView: rootView)
    }

    func updateUIViewController(_ uiViewController: PortraitLockedHostingController<Content>, context: Context) {
        uiViewController.rootView = rootView
        uiViewController.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

@main
struct ScoutCaptureApp: App {
    private static let firstLaunchCompletedKey = "scoutcapture.firstLaunchCompleted"
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState: AppState
    @State private var hasCompletedFirstLaunch: Bool
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        DebugSessionSnapshotAutoUploadDefaultsBootstrap.applyIfRequested()
        #endif
        let hasCompleted = UserDefaults.standard.bool(forKey: Self.firstLaunchCompletedKey)
        _hasCompletedFirstLaunch = State(initialValue: hasCompleted)
        #if DEBUG
        if Self.isRunningUnderXCTest {
            _appState = State(initialValue: AppState(disableCloudBackupForTests: true))
        } else {
            _appState = State(initialValue: AppState())
        }
        #else
        _appState = State(initialValue: AppState())
        #endif
    }

    var body: some Scene {
        WindowGroup {
            PortraitLockedRootView(
                rootView: AppRootView(
                    skipStartupLoading: false,
                    onInitialLaunchCompleted: markInitialLaunchCompleted
                )
                    .environmentObject(appState)
            )
                .ignoresSafeArea()
                .onChange(of: scenePhase) { _, newValue in
                    if newValue == .background {
                        appState.setLiveSyncMonitoringActive(false)
                        appState.handleSceneDidEnterBackground()
                    } else if newValue == .inactive {
                        appState.setLiveSyncMonitoringActive(false)
                    } else if newValue == .active {
                        appState.setLiveSyncMonitoringActive(true)
                        appState.handleSceneDidBecomeActive()
                    }
                }
        }
    }

    private func markInitialLaunchCompleted() {
        guard !hasCompletedFirstLaunch else { return }
        hasCompletedFirstLaunch = true
        UserDefaults.standard.set(true, forKey: Self.firstLaunchCompletedKey)
    }
}

private struct CloudBackupSheet: View {
    let onOpenSessionRestore: (() -> Void)?
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showRestoreConfirmation: Bool = false
    @State private var restoreErrorMessage: String? = nil
    @State private var isRestoring: Bool = false
    @State private var showRestoreSuccess: Bool = false

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.65)
    }

    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }

    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Color.clear
                        .frame(width: 76, height: 36)

                    Spacer(minLength: 0)

                    Text("iCloud Backup")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(buttonLabel)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(buttonFill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(buttonStroke, lineWidth: 1)
                    )
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(statusTitle)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                    Text(appState.backupStatusSubtitle())
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    iCloudAvailabilityRow
                    backupRow(
                        title: "Status",
                        value: statusLine
                    )
                    if let snapshotSummary {
                        backupRow(
                            title: "Snapshot",
                            value: snapshotSummary
                        )
                    }
                    if let lastRunSummary {
                        backupRow(
                            title: "Last Delta",
                            value: lastRunSummary
                        )
                    }
                    if let lastFailureMessage = appState.cloudBackupStatus.lastFailureMessage,
                       !lastFailureMessage.isEmpty {
                        backupRow(title: "Last Error", value: lastFailureMessage)
                    }
                    if appState.cloudBackupStatus.isRunning,
                       let progressCompleted = appState.cloudBackupStatus.progressCompleted,
                       let progressTotal = appState.cloudBackupStatus.progressTotal,
                       progressTotal > 0 {
                        backupRow(
                            title: appState.cloudBackupStatus.progressPhase ?? "Progress",
                            value: "\(Int((Double(progressCompleted) / Double(progressTotal)) * 100))% (\(progressCompleted)/\(progressTotal))"
                        )
                        backupRow(
                            title: "Remaining",
                            value: "\(max(progressTotal - progressCompleted, 0)) entries"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button(action: {
                    appState.backupNow()
                }) {
                    Text(appState.cloudBackupStatus.isRunning ? "Backing Up..." : "Back Up Now")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundColor(.white)
                        .background(Color.blue.opacity(appState.cloudBackupStatus.iCloudAvailable ? 1.0 : 0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!appState.cloudBackupStatus.iCloudAvailable || appState.cloudBackupStatus.isRunning || isRestoring)

                VStack(alignment: .leading, spacing: 6) {
                    Button(action: {
                        showRestoreConfirmation = true
                    }) {
                        Text(isRestoring ? "Restoring..." : "Restore Full App Backup")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundColor(.white)
                            .background(canRestore ? Color.green : Color.gray)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRestore || isRestoring || appState.cloudBackupStatus.isRunning)

                    Text("Restores missing app-level data from the latest iCloud backup.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                if let onOpenSessionRestore {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(action: {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                onOpenSessionRestore()
                            }
                        }) {
                            Text("Restore Session Snapshot")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .foregroundColor(.white)
                                .background(Color.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isRestoring || appState.cloudBackupStatus.isRunning)

                        Text("Opens per-session recovery for a specific property/session snapshot.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }
            .padding(16)
        }
        .alert("Restore Full App Backup?", isPresented: $showRestoreConfirmation) {
            Button("Restore", role: .destructive) {
                isRestoring = true
                appState.restoreLatestBackup { errorMessage in
                    isRestoring = false
                    restoreErrorMessage = errorMessage
                    if errorMessage == nil {
                        showRestoreSuccess = true
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This restores missing app-level data from the latest iCloud backup. For one property/session only, use Restore Session Snapshot.")
        }
        .alert("Restore Complete", isPresented: $showRestoreSuccess) {
            Button("OK", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("App backup restore finished successfully.")
        }
        .alert("Restore Failed", isPresented: Binding(
            get: { restoreErrorMessage != nil },
            set: { if !$0 { restoreErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(restoreErrorMessage ?? "Unable to restore the backup.")
        }
        .onAppear {
            appState.refreshBackupStatus()
        }
    }

    private var canRestore: Bool {
        appState.cloudBackupStatus.iCloudAvailable &&
        appState.cloudBackupStatus.hasBackup &&
        !appState.cloudBackupStatus.isRunning
    }

    private var statusTitle: String {
        switch appState.cloudBackupStatus.state {
        case .backedUp:
            return "Backed Up"
        case .pending:
            return appState.cloudBackupStatus.isRunning ? "Backup Running" : "Backup Pending"
        case .unavailable:
            return "iCloud Unavailable"
        }
    }

    private var statusLine: String {
        if let pauseUntil = appState.cloudBackupStatus.safetyPauseUntil, pauseUntil > Date() {
            let minutesRemaining = max(1, Int(ceil(pauseUntil.timeIntervalSinceNow / 60)))
            let reason = appState.cloudBackupStatus.safetyPauseReason ?? "after a destructive action"
            return "Automatic backup paused \(reason) (\(minutesRemaining)m left)."
        }
        switch appState.cloudBackupStatus.state {
        case .backedUp:
            return "Latest local data is backed up."
        case .pending:
            return appState.cloudBackupStatus.isRunning
                ? "Backup is running now."
                : "Changes are queued for backup."
        case .unavailable:
            return "Sign in to iCloud or re-enable iCloud Drive."
        }
    }

    private var snapshotSummary: String? {
        guard let fileCount = appState.cloudBackupStatus.snapshotFileCount,
              let byteCount = appState.cloudBackupStatus.snapshotByteCount else {
            return nil
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let sizeString = formatter.string(fromByteCount: Int64(byteCount))
        return "\(fileCount) files • \(sizeString)"
    }

    private var lastRunSummary: String? {
        guard let added = appState.cloudBackupStatus.lastRunAddedCount,
              let updated = appState.cloudBackupStatus.lastRunUpdatedCount,
              let pruned = appState.cloudBackupStatus.lastRunPrunedCount else {
            return nil
        }
        let sizeString: String
        if let changedBytes = appState.cloudBackupStatus.lastRunChangedByteCount {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            sizeString = formatter.string(fromByteCount: Int64(changedBytes))
        } else {
            sizeString = "n/a"
        }
        return "+\(added) • ~\(updated) • -\(pruned) • \(sizeString)"
    }

    @ViewBuilder
    private func backupRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
        }
    }

    @ViewBuilder
    private var iCloudAvailabilityRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("iCloud")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Image(systemName: appState.cloudBackupStatus.iCloudAvailable ? "checkmark.circle.fill" : "xmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(appState.cloudBackupStatus.iCloudAvailable ? .green : .gray)
                Text(appState.cloudBackupStatus.iCloudAvailable ? "Available" : "Unavailable")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
    }
}

private struct AppRootView: View {
    @EnvironmentObject private var appState: AppState
    let skipStartupLoading: Bool
    let onInitialLaunchCompleted: () -> Void
    @State private var sessionHubReady: Bool = false
    @State private var minimumLaunchDelayMet: Bool = false
    @State private var didStartWarmup: Bool = false
    @State private var launchProgress: Double = 0
    @State private var showsProgressBar: Bool = false
    @State private var propertyListReadinessTimedOut: Bool = false
    @State private var homePropertyListReady: Bool = false
    @State private var didStartHomePropertyListReadiness: Bool = false
    @State private var homePropertyListReadinessTimedOut: Bool = false
    // Keep first property-row badge/cloud hydration behind splash when possible.
    private let warmLaunchTimeoutSeconds: TimeInterval = 15.0

    private var isAppReady: Bool {
        skipStartupLoading || (sessionHubReady && minimumLaunchDelayMet)
    }

    private var canPrepareHomePropertyList: Bool {
        guard isAppReady else { return false }
        guard appState.requiresAuthentication else { return true }
        return appState.isAuthenticationReady &&
            appState.isAuthenticated &&
            appState.isOrganizationContextReady
    }

    private var initialPropertyListTimedOut: Bool {
        propertyListReadinessTimedOut || homePropertyListReadinessTimedOut
    }

    private var shouldShowInitialPropertyListUpdatingBanner: Bool {
        initialPropertyListTimedOut && appState.isInitialPropertyListUpdateStillActive
    }

    var body: some View {
        Group {
            if !isAppReady {
                LoadingView(
                    progress: launchProgress,
                    showsProgressBar: showsProgressBar,
                    showsLogo: true,
                    message: "Loading properties...",
                    showsSpinner: false
                )
            } else if appState.requiresAuthentication && !appState.isAuthenticationReady {
                LoadingView(
                    progress: 0,
                    showsProgressBar: false,
                    showsLogo: true
                )
            } else if appState.requiresAuthentication && !appState.isAuthenticated {
                AuthView()
            } else if appState.requiresAuthentication && !appState.isOrganizationContextReady {
                LoadingView(
                    progress: 0,
                    showsProgressBar: false,
                    showsLogo: true
                )
            } else if !homePropertyListReady {
                LoadingView(
                    progress: launchProgress,
                    showsProgressBar: true,
                    showsLogo: true,
                    message: "Loading properties...",
                    showsSpinner: false
                )
            } else {
                SessionHubView(initialPropertyListTimedOut: shouldShowInitialPropertyListUpdatingBanner)
            }
        }
        .onChange(of: appState.isAuthenticationReady) { _, _ in
            startHomePropertyListReadinessIfNeeded()
        }
        .onChange(of: appState.isAuthenticated) { _, _ in
            startHomePropertyListReadinessIfNeeded()
        }
        .onChange(of: appState.isOrganizationContextReady) { _, _ in
            startHomePropertyListReadinessIfNeeded()
        }
        .onChange(of: sessionHubReady) { _, _ in
            startHomePropertyListReadinessIfNeeded()
        }
        .onChange(of: minimumLaunchDelayMet) { _, _ in
            startHomePropertyListReadinessIfNeeded()
        }
        .task {
            guard !didStartWarmup else { return }
            didStartWarmup = true

            if skipStartupLoading {
                sessionHubReady = true
                minimumLaunchDelayMet = true
                CameraManager.prewarm()
                appState.warmLaunchReadiness {
                    if appState.properties.isEmpty {
                        appState.refreshPropertiesInBackground()
                    }
                    startHomePropertyListReadinessIfNeeded()
                }
                AddPropertyWarmup.prewarm()
                OptionalDetailNoteWarmup.prewarm()
                return
            }

            withAnimation(.easeOut(duration: 0.16)) {
                showsProgressBar = true
            }

            advanceLaunchProgress(to: 0.22)
            async let minDelay: Void = {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
            }()

            CameraManager.prewarm()
            advanceLaunchProgress(to: 0.40)

            await withCheckedContinuation { continuation in
                var didResume = false
                let resumeOnce: () -> Void = {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + warmLaunchTimeoutSeconds) {
                    guard !sessionHubReady else {
                        resumeOnce()
                        return
                    }
                    propertyListReadinessTimedOut = true
                    sessionHubReady = true
                    advanceLaunchProgress(to: 0.88)
                    resumeOnce()
                }

                appState.warmLaunchReadiness {
                    propertyListReadinessTimedOut = false
                    sessionHubReady = true
                    advanceLaunchProgress(to: 0.88)
                    resumeOnce()
                }
            }

            _ = await minDelay
            advanceLaunchProgress(to: 0.96)
            AddPropertyWarmup.prewarm()
            OptionalDetailNoteWarmup.prewarm()
            try? await Task.sleep(nanoseconds: 60_000_000)
            minimumLaunchDelayMet = true
            startHomePropertyListReadinessIfNeeded()
            onInitialLaunchCompleted()
        }
    }

    private func advanceLaunchProgress(to value: Double) {
        let clamped = min(max(value, 0), 1)
        guard clamped > launchProgress else { return }
        withAnimation(.easeOut(duration: 0.20)) {
            launchProgress = clamped
        }
    }

    private func startHomePropertyListReadinessIfNeeded() {
        guard canPrepareHomePropertyList else { return }
        guard !homePropertyListReady, !didStartHomePropertyListReadiness else { return }
        didStartHomePropertyListReadiness = true

        DispatchQueue.main.asyncAfter(deadline: .now() + warmLaunchTimeoutSeconds) {
            guard !homePropertyListReady else { return }
            homePropertyListReadinessTimedOut = true
            advanceLaunchProgress(to: 1.0)
            homePropertyListReady = true
        }

        Task { @MainActor in
            await appState.prepareInitialHomePropertyListForDisplay(reason: "home_property_list_readiness")
            guard !homePropertyListReady else {
                if homePropertyListReadinessTimedOut {
                    homePropertyListReadinessTimedOut = false
                }
                return
            }
            homePropertyListReadinessTimedOut = false
            advanceLaunchProgress(to: 1.0)
            homePropertyListReady = true
        }
    }
}

struct SessionHubView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let initialPropertyListTimedOut: Bool
    private var localStore: LocalStore { appState.sharedLocalStore }
    @State private var path: [HubRoute] = []
    @State private var showAddProperty: Bool = false
    @State private var showArchivedProperties: Bool = false
    @State private var showSettingsSheet: Bool = false
    @State private var propertyToArchive: Property? = nil
    @State private var propertyToDelete: Property? = nil
    @State private var editContactProperty: Property? = nil
    @State private var manageSessionsProperty: Property? = nil
    @State private var pendingExportPromptSession: Session? = nil
    @State private var pendingExportPromptProperty: Property? = nil
    @State private var initialSessionTypePickerProperty: Property? = nil
    @State private var fastLaneOpeningProperty: Property? = nil
    @State private var fastLanePreviewRequest: FastRuntimeCameraPreviewRequest? = nil
    @State private var fastLaneCloseResult: AppState.FastRuntimePrototypeCloseResult? = nil
    @State private var fastLaneDraftIssue: FastLaneDraftIssue? = nil
    @State private var isPreparingPendingExport: Bool = false
    @State private var pendingExportFile: PendingExportFile? = nil
    @State private var pendingExportChecklist = ExportChecklistState()
    @State private var pendingExportErrorMessage: String? = nil
    @State private var showPendingExportError: Bool = false
    @State private var mapLookupPropertyID: UUID? = nil
    @State private var showMapsErrorToast: Bool = false
    @State private var mapsErrorToastToken: Int = 0
    @State private var showPhoneNumberErrorToast: Bool = false
    @State private var phoneErrorToastToken: Int = 0
    @State private var hubTransientStatusToastToken: Int = 0
    @State private var isSearchExpanded: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    @State private var propertyListFilter: PropertyListFilter = .all
    @State private var showCalendarComingSoonPopup: Bool = false
    @State private var showTemporaryMigrationExport: Bool = false
    @State private var showTemporaryMigrationImport: Bool = false
    @State private var showCloudBackupSheet: Bool = false
    @State private var showSessionRestoreSheet: Bool = false
    @State private var showDebugTools: Bool = false
    @State private var hiddenDebugTapCount: Int = 0
    @State private var lastHiddenDebugTapAt: Date? = nil
    @State private var propertyTapToken: Int = 0
    @State private var pressedPropertyID: UUID? = nil
    @State private var isOpeningProperty: Bool = false
    @State private var placeholderHoldUntil: Date? = nil
    @State private var dismissedPendingInvitationIDs: Set<UUID> = []
    @State private var isPendingInviteActionInFlight: Bool = false
    @State private var pendingInvitePromptErrorMessage: String? = nil
    @State private var isManualPropertyRefreshInFlight: Bool = false

    private let selectionHaptic = UIImpactFeedbackGenerator(style: .light)
    private let hiddenDebugTapWindow: TimeInterval = 1.5
    private let startupPlaceholderHoldSeconds: TimeInterval = 8.0
    private let diagnosticMinimalHomeRows: Bool = true

    private enum HubRoute: Hashable {
        case propertySession(propertyID: UUID, resumeDraft: Bool, initialSessionType: SessionType?)
    }

    private enum PropertyListFilter {
        case all
        case drafts
        case pendingExport
    }

    private struct PendingExportFile: Identifiable {
        let id = UUID()
        let propertyID: UUID
        let sessionID: UUID
        let url: URL
    }

    private struct ExportChecklistState {
        var originalsComplete: Bool = false
        var sessionDataComplete: Bool = false
        var zipReady: Bool = false
    }

    private enum ExportChecklistStep {
        case originals
        case sessionData
        case zipReady
    }

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.85)
    }
    
    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }
    
    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }
    
    private var headerPrimaryLabel: Color {
        colorScheme == .light ? .black : .white
    }

    private var draftCount: Int {
        appState.draftPropertyCount()
    }

    private var pendingExportCount: Int {
        appState.pendingExportCountAcrossProperties()
    }

    private var activeProperties: [Property] {
        appState.properties.filter { $0.deletedAt == nil && !$0.isArchived }
    }

    private var archivedProperties: [Property] {
        appState.properties.filter { $0.deletedAt == nil && $0.isArchived }
    }

    private var normalizedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredActiveProperties: [Property] {
        activeProperties
            .filter(matchesSearch(_:))
            .filter(matchesPropertyFilter(_:))
    }

    private var filteredArchivedProperties: [Property] {
        archivedProperties
            .filter(matchesSearch(_:))
            .filter(matchesPropertyFilter(_:))
    }

    private var shouldShowStartupPlaceholders: Bool {
        guard appState.properties.isEmpty else { return false }
        if appState.isLoading || appState.isLoadingPropertiesForOrgSwitch {
            return true
        }
        if let holdUntil = placeholderHoldUntil, Date() < holdUntil {
            return true
        }
        return false
    }

    private var initialPropertyListUpdatingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.9)

            Text("Still updating...")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(headerPrimaryLabel)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            colorScheme == .light
                ? Color(.systemBlue).opacity(0.10)
                : Color(.systemBlue).opacity(0.22)
        )
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Still updating property details")
    }

    private var isCompactSearchMode: Bool {
        (isSearchExpanded && isSearchFieldFocused) || !normalizedSearchQuery.isEmpty
    }

    private var visiblePendingInvitationPrompt: PendingOrganizationInvitation? {
        appState.pendingOrganizationInvitations.first { !dismissedPendingInvitationIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if let invitation = visiblePendingInvitationPrompt {
                    pendingInvitationPrompt(invitation)
                }

                if initialPropertyListTimedOut && !diagnosticMinimalHomeRows {
                    initialPropertyListUpdatingBanner
                }

                Group {
                    let showArchivedSection = showArchivedProperties
                    let hasNoMatches = filteredActiveProperties.isEmpty && (!showArchivedSection || filteredArchivedProperties.isEmpty)
                    let hasNoPropertiesAtAll = activeProperties.isEmpty && (!showArchivedSection || archivedProperties.isEmpty)
                    if shouldShowStartupPlaceholders {
                        List {
                            Section {
                                ForEach(0..<4, id: \.self) { index in
                                    startupPlaceholderRow(index: index)
                                }
                            } header: {
                                Text("Syncing Properties...")
                                    .font(.system(size: 13, weight: .semibold))
                                    .textCase(nil)
                            }
                        }
                        .listStyle(.plain)
                    } else if appState.requiresAuthentication && appState.activeOrganizationID == nil {
                        ContentUnavailableView(
                            "No Organization Access",
                            systemImage: "building.2.crop.circle",
                            description: Text("You don’t currently have access to any organizations.")
                        )
                    } else if hasNoPropertiesAtAll {
                        ContentUnavailableView {
                            Label("No Properties", systemImage: "house")
                        } description: {
                            Text("Add a property to start a session.")
                        } actions: {
                            Button("Retry Sync") {
                                Task {
                                    await appState.refreshPropertiesAwaitingForegroundRefresh()
                                }
                            }
                        }
                    } else {
                        List {
                            let rowDraftBadges = appState.propertyRowDraftBadgeByPropertyID
                            let rowSubtitles = appState.propertyRowSubtitleByPropertyID
                            let rowCloudGlyphs = appState.propertyRowCloudGlyphByPropertyID
                            if !filteredActiveProperties.isEmpty {
                                Section {
                                    ForEach(filteredActiveProperties) { property in
                                        diagnosticPropertyRow(
                                            property,
                                            hasDraft: rowDraftBadges[property.id] == true,
                                            subtitleLine: rowSubtitles[property.id],
                                            cloudGlyph: rowCloudGlyphs[property.id]
                                        )
                                    }
                                }
                            }

                            if showArchivedSection && !filteredArchivedProperties.isEmpty {
                                Section("Archived") {
                                    ForEach(filteredArchivedProperties) { property in
                                        diagnosticPropertyRow(
                                            property,
                                            hasDraft: rowDraftBadges[property.id] == true,
                                            subtitleLine: rowSubtitles[property.id],
                                            cloudGlyph: rowCloudGlyphs[property.id]
                                        )
                                    }
                                }
                            }

                            if hasNoMatches {
                                Section {
                                    Text("No matching properties")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 10)
                                }
                            }
                        }
                        .id(appState.hubRowRefreshToken)
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                countersHeader
            }
            .navigationDestination(for: HubRoute.self) { route in
                switch route {
                case let .propertySession(propertyID, resumeDraft, initialSessionType):
                    PropertySessionView(
                        propertyID: propertyID,
                        resumeDraft: resumeDraft,
                        initialSessionType: initialSessionType,
                        onPendingExportRecovered: { property, session in
                            pendingExportPromptProperty = property
                            pendingExportPromptSession = session
                        }
                    )
                        .environmentObject(appState)
                }
            }
            .fullScreenCover(isPresented: $showAddProperty, onDismiss: {
                appState.triggerBackupForLifecycleEvent()
            }) {
                HubAddPropertySheet()
                    .environmentObject(appState)
            }
            .sheet(item: $manageSessionsProperty) { property in
                PropertySessionsManagerView(property: property)
                    .environmentObject(appState)
            }
            .sheet(item: $editContactProperty) { property in
                EditContactSheet(property: property)
                    .environmentObject(appState)
            }
            .sheet(item: $pendingExportFile) { file in
                HubSessionDocumentExportPicker(
                    fileURL: file.url,
                    onComplete: { didExport in
                        print("[DeliverResult] sessionID=\(file.sessionID.uuidString) success=\(didExport)")
                        if didExport {
                            _ = appState.markSessionExported(propertyID: file.propertyID, sessionID: file.sessionID)
                            if let updated = appState.sessions(for: file.propertyID).first(where: { $0.id == file.sessionID }) {
                                let pending = appState.isPendingDelivery(updated)
                                let reExportEligible = appState.isReExportEligible(updated)
                                print("[DeliveryState] sessionID=\(updated.id.uuidString) firstDeliveredAt=\(String(describing: updated.firstDeliveredAt)) reExportExpiresAt=\(String(describing: updated.reExportExpiresAt)) pending=\(pending) reExportEligible=\(reExportEligible)")
                            }
                        }
                        pendingExportFile = nil
                        isPreparingPendingExport = false
                        appState.refreshProperties()
                        appState.triggerBackupForLifecycleEvent()
                    }
                )
            }
            .sheet(isPresented: $showTemporaryMigrationExport) {
                TemporaryMigrationExportView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showTemporaryMigrationImport) {
                TemporaryMigrationImportView()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showCloudBackupSheet) {
                CloudBackupSheet(
                    onOpenSessionRestore: { showSessionRestoreSheet = true }
                )
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showSessionRestoreSheet) {
                SessionArchiveRestoreSheet()
                    .environmentObject(appState)
            }
            .sheet(isPresented: $showSettingsSheet) {
                HubSettingsSheet(
                    showArchivedProperties: $showArchivedProperties,
                    onOpenCloudBackup: { showCloudBackupSheet = true },
                    onOpenDebugTools: { showDebugTools = true }
                )
            }
            .fullScreenCover(isPresented: $showDebugTools) {
                DebugToolsView(
                    onShowMigrationExport: { showTemporaryMigrationExport = true },
                    onShowMigrationImport: { showTemporaryMigrationImport = true }
                )
                    .environmentObject(appState)
            }
            .fullScreenCover(item: $fastLanePreviewRequest) { request in
                DebugFastRuntimePrototypeCameraPreviewView(
                    context: request.context,
                    propertyName: request.propertyName,
                    prototypeResult: request.result,
                    buttonTappedAt: request.buttonTappedAt,
                    contextReadyAt: request.contextReadyAt,
                    previewRequestedAt: request.previewRequestedAt,
                    initialCapturedCount: request.initialCapturedCount,
                    storageRoot: request.storageRoot,
                    isDraftResume: request.isDraftResume,
                    initialLocationMode: request.initialLocationMode,
                    initialMetadataContext: request.initialMetadataContext,
                    isDebugMode: false,
                    onDismiss: { closeResult in
                        if closeResult.errorMessage != nil {
                            fastLaneCloseResult = closeResult
                        }
                        fastLanePreviewRequest = nil
                        fastLaneOpeningProperty = nil
                        isOpeningProperty = false
                    }
                )
                .environmentObject(appState)
                .interactiveDismissDisabled(true)
            }
            .alert(item: $fastLaneDraftIssue) { issue in
                Alert(
                    title: Text("Fast-Lane Draft Needs Cleanup"),
                    message: Text(issue.message),
                    primaryButton: .destructive(Text("Clear Fast-Lane Drafts")) {
                        clearFastLaneDraftsFromIssue()
                    },
                    secondaryButton: .default(Text("Use Legacy Path")) {
                        openLegacyPathAfterFastLaneIssue(issue.property)
                    }
                )
            }
            .onAppear {
                isOpeningProperty = false
                pressedPropertyID = nil
                appState.markHomePropertyListVisible()
                if appState.properties.isEmpty {
                    beginStartupPlaceholderHoldWindow()
                } else {
                    placeholderHoldUntil = nil
                }
                appState.triggerBackupForLifecycleEvent(after: 8.0)
                selectionHaptic.prepare()
            }
            .onChange(of: appState.hubTransientStatusMessage) { _, newValue in
                guard let newValue, !newValue.isEmpty else { return }
                hubTransientStatusToastToken += 1
                let token = hubTransientStatusToastToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    guard token == hubTransientStatusToastToken else { return }
                    appState.clearHubTransientStatusMessageIfMatching(newValue)
                }
            }
            .onChange(of: appState.properties.count) { _, newCount in
                if newCount > 0 {
                    placeholderHoldUntil = nil
                } else if placeholderHoldUntil == nil {
                    beginStartupPlaceholderHoldWindow()
                }
            }
            .onChange(of: appState.pendingOrganizationInvitations.map(\.id)) { _, newIDs in
                dismissedPendingInvitationIDs.formIntersection(Set(newIDs))
                if !newIDs.contains(where: { dismissedPendingInvitationIDs.contains($0) }) {
                    pendingInvitePromptErrorMessage = nil
                }
            }
            .onChange(of: path) { oldPath, newPath in
                if case let .propertySession(propertyID, _, _) = oldPath.last,
                   newPath.isEmpty {
                    appState.refreshPropertySessionState(propertyID: propertyID)
                }
                if newPath.isEmpty {
                    isOpeningProperty = false
                    pressedPropertyID = nil
                }
            }
            .alert("Archive Property?", isPresented: Binding(
                get: { propertyToArchive != nil },
                set: { if !$0 { propertyToArchive = nil } }
            )) {
                Button("Archive") {
                    guard let property = propertyToArchive else { return }
                    _ = appState.setPropertyArchived(id: property.id, archived: true)
                    propertyToArchive = nil
                }
                Button("Cancel", role: .cancel) {
                    propertyToArchive = nil
                }
            } message: {
                Text("This will hide \"\(propertyToArchive?.name ?? "Property")\" from the main list. You can show it again from Archived.")
            }
            .alert("Delete Property?", isPresented: Binding(
                get: { propertyToDelete != nil },
                set: { if !$0 { propertyToDelete = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    guard let property = propertyToDelete else { return }
                    propertyToDelete = nil
                    Task {
                        await appState.remoteSoftDeleteProperty(id: property.id)
                    }
                }
                Button("Cancel", role: .cancel) {
                    propertyToDelete = nil
                }
            } message: {
                Text("This property will move to Recently Deleted and can be restored for 30 days.")
            }
            .alert("Export Failed", isPresented: $showPendingExportError) {
                Button("Retry") {
                    guard let property = pendingExportPromptProperty, let session = pendingExportPromptSession else { return }
                    beginPendingExport(for: property, session: session)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(pendingExportErrorMessage ?? "Unable to prepare export.")
            }
            .overlay {
                if pendingExportPromptSession != nil, pendingExportPromptProperty != nil {
                    pendingExportPromptOverlay
                }
            }
            .overlay {
                if let property = initialSessionTypePickerProperty {
                    initialSessionTypePickerOverlay(for: property)
                }
            }
            .overlay {
                if let property = fastLaneOpeningProperty {
                    fastLaneOpeningOverlay(for: property)
                }
            }
            .overlay(alignment: .bottom) {
                if let closeResult = fastLaneCloseResult {
                    fastLaneCloseResultOverlay(closeResult)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 22)
                }
            }
            .overlay {
                if isPreparingPendingExport {
                    preparingExportOverlay
                }
            }
            .overlay {
                if showCalendarComingSoonPopup {
                    ZStack {
                        Color.black.opacity(0.45)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showCalendarComingSoonPopup = false
                            }

                        VStack(spacing: 14) {
                            Text("Calendar")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(.white)

                            Text("Calendar integration coming soon.")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .multilineTextAlignment(.center)

                            customCapsuleToolbarButton(
                                title: "OK",
                                isEnabled: true,
                                fill: .blue,
                                stroke: .blue.opacity(0.9),
                                label: .white
                            ) {
                                showCalendarComingSoonPopup = false
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 430)
                        .background(Color.black.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    }
                    .animation(.easeInOut(duration: 0.18), value: showCalendarComingSoonPopup)
                }
            }
            .overlay(alignment: .top) {
                if !diagnosticMinimalHomeRows {
                    VStack(spacing: 8) {
                        if let hubTransientStatusMessage = appState.hubTransientStatusMessage {
                            toastCapsule(hubTransientStatusMessage)
                        }
                        if showMapsErrorToast {
                            toastCapsule("Unable to open Maps for this address.")
                        }
                        if showPhoneNumberErrorToast {
                            toastCapsule("No phone number on file")
                        }
                    }
                }
            }
        }
    }

    private func runManualPropertyRefresh() {
        guard !isManualPropertyRefreshInFlight else { return }
        isManualPropertyRefreshInFlight = true
        Task {
            await appState.refreshPropertiesAwaitingForegroundRefresh()
            isManualPropertyRefreshInFlight = false
        }
    }

    @ViewBuilder
    private func pendingInvitationPrompt(_ invitation: PendingOrganizationInvitation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Organization Invitation")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(headerPrimaryLabel)

            Text("You’ve been invited to join \(invitation.orgName) as \(invitation.role.capitalized).")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

            if let pendingInvitePromptErrorMessage, !pendingInvitePromptErrorMessage.isEmpty {
                Text(pendingInvitePromptErrorMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.red)
            }

            HStack(spacing: 10) {
                Button(isPendingInviteActionInFlight ? "Accepting..." : "Accept Invite") {
                    acceptPendingInvitation(invitation)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPendingInviteActionInFlight)

                Button("Ignore for Now") {
                    dismissedPendingInvitationIDs.insert(invitation.id)
                    pendingInvitePromptErrorMessage = nil
                }
                .buttonStyle(.bordered)
                .disabled(isPendingInviteActionInFlight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(colorScheme == .light ? 0.08 : 0.18))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color.blue.opacity(0.20)),
            alignment: .bottom
        )
    }

    private func acceptPendingInvitation(_ invitation: PendingOrganizationInvitation) {
        pendingInvitePromptErrorMessage = nil
        isPendingInviteActionInFlight = true

        Task {
            defer { isPendingInviteActionInFlight = false }
            do {
                try await appState.acceptOrganizationInvitation(invitationID: invitation.id)
                dismissedPendingInvitationIDs.remove(invitation.id)
            } catch {
                pendingInvitePromptErrorMessage = error.localizedDescription
            }
        }
    }

    private func beginStartupPlaceholderHoldWindow() {
        let holdUntil = Date().addingTimeInterval(startupPlaceholderHoldSeconds)
        placeholderHoldUntil = holdUntil
        DispatchQueue.main.asyncAfter(deadline: .now() + startupPlaceholderHoldSeconds) {
            guard let currentHold = placeholderHoldUntil, currentHold == holdUntil else { return }
            placeholderHoldUntil = nil
        }
    }

    @ViewBuilder
    private func startupPlaceholderRow(index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 180, height: 18)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 120, height: 13)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .frame(width: 210, height: 13)
            }
            Spacer(minLength: 0)
            ProgressView()
                .scaleEffect(0.85)
                .padding(.top, 3)
        }
        .opacity(0.95 - (Double(index) * 0.08))
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private func diagnosticPropertyRow(
        _ property: Property,
        hasDraft: Bool,
        subtitleLine: String?,
        cloudGlyph: AppState.PropertyRowCloudGlyphState?
    ) -> some View {
        if diagnosticMinimalHomeRows {
            minimalPropertyRow(
                property,
                hasDraft: hasDraft,
                subtitleLine: subtitleLine,
                cloudGlyph: cloudGlyph
            )
        } else {
            propertyRow(property)
        }
    }

    private func minimalPropertyRow(
        _ property: Property,
        hasDraft: Bool,
        subtitleLine: String?,
        cloudGlyph: AppState.PropertyRowCloudGlyphState?
    ) -> some View {
        let addressLine = propertyAddressLine(property) ?? property.address

        return Button {
            handlePropertyTap(property)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    propertyRowTitleText(
                        property.name,
                        cloudGlyph: cloudGlyph
                    )
                        .font(.system(size: 18, weight: .semibold))
                        .lineLimit(1)

                    if let subtitleLine,
                       !subtitleLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtitleLine)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if let addressLine,
                       !addressLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(addressLine)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                if hasDraft {
                    chipLabel("Draft", tint: .orange)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(pressedPropertyID == property.id ? 0.70 : 1.0)
        .animation(.easeOut(duration: 0.10), value: pressedPropertyID)
    }

    @ViewBuilder
    private func propertyRowStatusChip(_ state: AppState.PropertyRowStatusChipState) -> some View {
        Text(state == .uploading ? "Uploading" : "Pending Export")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.blue)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func propertyRowTitleText(
        _ title: String,
        cloudGlyph: AppState.PropertyRowCloudGlyphState?
    ) -> Text {
        guard let cloudGlyph else {
            return Text(title).foregroundColor(.primary)
        }
        return Text(title).foregroundColor(.primary)
            + Text(" \(propertyRowCloudGlyphText(cloudGlyph))")
                .foregroundColor(propertyRowCloudGlyphColor(cloudGlyph))
    }

    private func propertyRowCloudGlyphText(_ state: AppState.PropertyRowCloudGlyphState) -> String {
        switch state {
        case .current:
            return "✓"
        case .uploading:
            return "↑"
        case .warning:
            return "!"
        }
    }

    private func propertyRowCloudGlyphColor(_ state: AppState.PropertyRowCloudGlyphState) -> Color {
        switch state {
        case .current, .uploading:
            return .blue
        case .warning:
            return .orange
        }
    }

    @ViewBuilder
    private func propertyRow(_ property: Property) -> some View {
        let badgeModel = appState.propertyCardBadgeModel(for: property.id)
        let pendingSession = appState.propertyRowPendingDeliverySession(for: property.id)
        let sessionUploadStatus = appState.propertyRowSessionSnapshotCloudStatus(propertyID: property.id)
        let rawHasDraft = badgeModel.showDraft
        let uploadStatusChip = sessionUploadStatus.flatMap(sessionSnapshotUploadStatusChip)
        let isActivelyUploading = sessionUploadStatus?.state == .uploading &&
            sessionUploadStatus?.isConfigurationBlocked == false
        let hasDraft = rawHasDraft && !isActivelyUploading
        let hasPendingExport = badgeModel.showPendingExport && !isActivelyUploading
        let latestReExportSession = appState.propertyRowReExportCandidateSession(for: property.id)
        let hasReExportGlyph = badgeModel.showReExport && latestReExportSession != nil
        let manualExportSession = latestReExportSession ?? pendingSession
        let hasManualExportAction = manualExportSession != nil && (hasReExportGlyph || hasPendingExport)
        let clientLine = propertyClientLine(property)
        let addressLine = propertyAddressLine(property)
        let hasMapsButton = mapsAddressQuery(for: property) != nil
        let hasPhoneActions = hasValidPhoneNumber(property)
        let hasStatusRow = hasDraft || hasPendingExport || hasReExportGlyph || uploadStatusChip != nil
        let showLock = badgeModel.showLock
        Button {
            handlePropertyTap(property)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if hasReExportGlyph {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(Color.green.opacity(0.92))
                        }
                        if showLock {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        Text(property.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if let sessionUploadStatus {
                            sessionSnapshotCloudIcon(sessionUploadStatus)
                        }
                    }

                    if let clientLine {
                        Text(clientLine)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if let addressLine {
                        Text(addressLine)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    if hasStatusRow {
                        VStack(alignment: .trailing, spacing: 4) {
                            HStack(spacing: 8) {
                                if hasDraft {
                                    chipLabel("Draft", tint: .orange)
                                }

                                if hasPendingExport {
                                    chipLabel("Pending Export", tint: .blue)
                                }

                                if let uploadStatusChip {
                                    chipLabel(uploadStatusChip.title, tint: uploadStatusChip.tint)
                                }
                            }

                        }
                    }

                }
                .frame(minHeight: (addressLine != nil ? (clientLine != nil ? 58 : 40) : 24), alignment: .top)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Manage Sessions") {
                manageSessionsProperty = property
            }
            Button("Edit Contact") {
                editContactProperty = property
            }
            if property.isArchived {
                Button("Unarchive Property") {
                    _ = appState.setPropertyArchived(id: property.id, archived: false)
                }
            } else {
                Button("Archive Property") {
                    propertyToArchive = property
                }
            }
            Button("Delete Property", role: .destructive) {
                requestDeleteProperty(property)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if hasMapsButton {
                Button {
                    openMaps(for: property)
                } label: {
                    Label("Maps", systemImage: "map.fill")
                }
                .tint(.blue)
            }

            if hasPhoneActions {
                Button {
                    triggerPhoneAction(.message, for: property)
                } label: {
                    Label("Message", systemImage: "message.fill")
                }
                .tint(.green)

                Button {
                    triggerPhoneAction(.call, for: property)
                } label: {
                    Label("Call", systemImage: "phone.fill")
                }
                .tint(.green)
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if hasManualExportAction, let manualExportSession {
                Button {
                    print("[ReExportInvoke] propertyID=\(property.id.uuidString) sessionID=\(manualExportSession.id.uuidString) source=leadingSwipe")
                    beginPendingExport(for: property, session: manualExportSession)
                } label: {
                    Label("Re-export", systemImage: "clock.arrow.circlepath")
                }
                .tint(.green)
            }
        }
    }

    private func propertyClientLine(_ property: Property) -> String? {
        let client = appState.hubMeta(for: property.id)?.clientLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let organization = appState.organizations.first(where: { $0.id == property.orgId })?.name
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if client.isEmpty { return organization.isEmpty ? nil : organization }
        if organization.isEmpty { return client }
        return "\(client) (\(organization))"
    }

    private func propertyAddressLine(_ property: Property) -> String? {
        appState.hubMeta(for: property.id)?.addressLine
    }

    private func mapsAddressQuery(for property: Property) -> String? {
        let rawAddress = property.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleaned = rawAddress
            .replacingOccurrences(of: ", United States", with: "", options: [.caseInsensitive, .anchored, .backwards], range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func hasValidPhoneNumber(_ property: Property) -> Bool {
        let digits = (property.clientPhone ?? "").filter(\.isNumber)
        return digits.count >= 7
    }

    private func openMaps(for property: Property) {
        guard mapLookupPropertyID == nil else { return }
        guard let address = mapsAddressQuery(for: property) else { return }
        mapLookupPropertyID = property.id

        Task {
            do {
                if #available(iOS 26.0, *) {
                    guard let request = MKGeocodingRequest(addressString: address) else {
                        throw NSError(domain: "SessionHubView.Geocoding", code: 1)
                    }
                    let items = try await request.mapItems
                    guard let first = items.first else {
                        throw NSError(domain: "SessionHubView.Geocoding", code: 2)
                    }
                    _ = first
                } else {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = address
                    let response = try await MKLocalSearch(request: request).start()
                    guard let first = response.mapItems.first else {
                        throw NSError(domain: "SessionHubView.Geocoding", code: 3)
                    }
                    _ = first
                }
                await MainActor.run {
                    mapLookupPropertyID = nil
                    openAppleMapsSearch(address: address)
                }
            } catch {
                await MainActor.run {
                    mapLookupPropertyID = nil
                    showMapsErrorToastNow()
                }
            }
        }
    }

    private func openAppleMapsSearch(address: String) {
        let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !encoded.isEmpty, let url = URL(string: "http://maps.apple.com/?q=\(encoded)") else {
            showMapsErrorToastNow()
            return
        }
        UIApplication.shared.open(url)
    }

    private func showMapsErrorToastNow() {
        mapsErrorToastToken += 1
        let token = mapsErrorToastToken
        showMapsErrorToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard token == mapsErrorToastToken else { return }
            showMapsErrorToast = false
        }
    }

    private enum PhoneQuickAction {
        case call
        case message
    }

    private func triggerPhoneAction(_ action: PhoneQuickAction, for property: Property) {
        let digits = (property.clientPhone ?? "").filter(\.isNumber)
        guard digits.count >= 7 else {
            showPhoneNumberErrorToastNow()
            return
        }

        let scheme: String
        switch action {
        case .call:
            scheme = "tel://\(digits)"
        case .message:
            scheme = "sms://\(digits)"
        }
        guard let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) else {
            showPhoneNumberErrorToastNow()
            return
        }
        UIApplication.shared.open(url)
    }

    private func showPhoneNumberErrorToastNow() {
        phoneErrorToastToken += 1
        let token = phoneErrorToastToken
        showPhoneNumberErrorToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard token == phoneErrorToastToken else { return }
            showPhoneNumberErrorToast = false
        }
    }

    @ViewBuilder
    private func toastCapsule(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.78))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.top, 10)
            .transition(.opacity)
    }

    @ViewBuilder
    private func chipLabel(_ text: String, tint: Color, systemImage: String? = nil) -> some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tint.opacity(0.15))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(tint.opacity(0.35), lineWidth: 1)
        )
    }

    private func sessionSnapshotCloudTint(_ tint: AppState.SessionSnapshotCloudStatus.Tint) -> Color {
        switch tint {
        case .neutral:
            return .secondary
        case .blue:
            return .blue
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }

    @ViewBuilder
    private func sessionSnapshotCloudIcon(_ status: AppState.SessionSnapshotCloudStatus) -> some View {
        Image(systemName: status.symbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(sessionSnapshotCloudTint(status.tint))
            .accessibilityLabel(Text(status.accessibilityLabel))
            .help(status.helpText)
    }

    private func sessionSnapshotUploadStatusChip(
        _ status: AppState.SessionSnapshotCloudStatus
    ) -> (title: String, tint: Color)? {
        if status.isConfigurationBlocked {
            return nil
        }
        switch status.state {
        case .queued:
            return ("Pending Upload", .blue)
        case .uploading:
            return ("Uploading", .blue)
        case .retryScheduled:
            return ("Retrying Upload", .orange)
        case .failed:
            return ("Upload Failed", .red)
        case .uploaded:
            return nil
        }
    }

    private var countersHeader: some View {
        VStack(spacing: 12) {
            if isSearchExpanded {
                propertiesSearchRow
            }

            if !isSearchExpanded {
                ZStack {
                    HStack {
                        Button {
                            runManualPropertyRefresh()
                        } label: {
                            Group {
                                if isManualPropertyRefreshInFlight {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.82)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 18, weight: .medium))
                                }
                            }
                            .foregroundColor(buttonLabel)
                            .frame(width: 42, height: 42)
                            .background(buttonFill)
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(buttonStroke, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isManualPropertyRefreshInFlight)
                        .accessibilityLabel("Refresh properties")

                        Spacer(minLength: 0)
                        Button {
                            showSettingsSheet = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(buttonLabel)
                                .frame(width: 42, height: 42)
                                .background(buttonFill)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(buttonStroke, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !isCompactSearchMode {
                Image(colorScheme == .light ? "ScoutCaptureLogoBlue" : "ScoutCaptureLogoWhite")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 58)
                    .accessibilityHidden(true)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handleHiddenDebugTap()
                    }
                
                Text("Session View")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)

                HStack(spacing: 12) {
                    counterCard(
                        title: "Drafts",
                        value: draftCount,
                        tint: .orange,
                        isActive: propertyListFilter == .drafts
                    ) {
                        togglePropertyFilter(.drafts)
                    }
                    counterCard(
                        title: "Pending Export",
                        value: pendingExportCount,
                        tint: .blue,
                        isActive: propertyListFilter == .pendingExport
                    ) {
                        togglePropertyFilter(.pendingExport)
                    }
                }
                
                HStack(spacing: 8) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("Select a property below to continue")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(headerPrimaryLabel)
                        .opacity(0.72)
                        .fixedSize(horizontal: true, vertical: true)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
            }

            if !isSearchExpanded {
                propertiesSearchRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, isCompactSearchMode ? 4 : 6)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground))
        .animation(.easeInOut(duration: 0.18), value: isSearchExpanded)
        .animation(.easeInOut(duration: 0.18), value: isCompactSearchMode)
    }

    private var propertiesSearchRow: some View {
        HStack(spacing: 10) {
            if !isSearchExpanded {
                Text("Properties")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)

                Spacer(minLength: 0)
            }

            if isSearchExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    TextField("Search name, org, or address", text: $searchQuery)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFieldFocused)
                        .font(.system(size: 15, weight: .medium))

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            DispatchQueue.main.async {
                                isSearchFieldFocused = true
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))

                Button("Cancel") {
                    collapseSearch()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(buttonLabel)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(buttonFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(buttonStroke, lineWidth: 1)
                )
                .buttonStyle(.plain)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isSearchExpanded = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isSearchFieldFocused = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(buttonLabel)
                        .frame(width: 34, height: 34)
                        .background(buttonFill)
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(buttonStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))

                addCircleButton
            }
        }
    }

    private var cloudStatusTint: Color {
        cloudIconMode == .offline ? .gray : .blue
    }

    private enum CloudIconMode {
        case offline
        case errorOnline
        case backedUp
        case pending
    }

    private var cloudIconMode: CloudIconMode {
        let status = appState.cloudBackupStatus
        if !status.iCloudAvailable {
            return .offline
        }
        if let lastFailureMessage = status.lastFailureMessage,
           !lastFailureMessage.isEmpty,
           !status.isRunning {
            return .errorOnline
        }
        if status.state == .backedUp && !status.isRunning {
            return .backedUp
        }
        return .pending
    }

    @ViewBuilder
    private var cloudStatusIcon: some View {
        switch cloudIconMode {
        case .offline, .errorOnline:
            Image(systemName: "icloud.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(cloudStatusTint)
        case .backedUp:
            Image(systemName: "icloud.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(cloudStatusTint)
        case .pending:
            ZStack {
                Image(systemName: "icloud")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(cloudStatusTint)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(cloudStatusTint)
                    .offset(y: 1)
                    .symbolEffect(.rotate.clockwise, options: .repeating, isActive: shouldAnimateCloudIcon)
            }
        }
    }

    private var shouldAnimateCloudIcon: Bool {
        appState.cloudBackupStatus.isRunning && cloudIconMode == .pending
    }

    @ViewBuilder
    private var addCircleButton: some View {
        Button {
            showAddProperty = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(buttonLabel)
                .frame(width: 34, height: 34)
                .background(buttonFill)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(buttonStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func collapseSearch() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isSearchExpanded = false
            searchQuery = ""
        }
        isSearchFieldFocused = false
    }

    private func togglePropertyFilter(_ filter: PropertyListFilter) {
        if propertyListFilter == filter {
            propertyListFilter = .all
        } else {
            propertyListFilter = filter
        }
    }

    private func propertyHasDraft(_ property: Property) -> Bool {
        appState.propertyCardBadgeModel(for: property.id).showDraft
    }

    private func propertyHasPendingExport(_ property: Property) -> Bool {
        appState.propertyCardBadgeModel(for: property.id).showPendingExport
    }

    private func matchesPropertyFilter(_ property: Property) -> Bool {
        switch propertyListFilter {
        case .all:
            return true
        case .drafts:
            return propertyHasDraft(property)
        case .pendingExport:
            return propertyHasPendingExport(property)
        }
    }

    @ViewBuilder
    private func counterCard(
        title: String,
        value: Int,
        tint: Color,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isActive ? .white : headerPrimaryLabel)
                Text("\(value)")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(isActive ? .white : tint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isActive ? tint.opacity(0.86) : Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isActive ? tint : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private struct HubSettingsSheet: View {
        private struct PropertyAccessManagementPresentation: Identifiable {
            let id = UUID()
            let member: OrganizationAccessMember
        }

        private struct PendingMembershipRevoke: Identifiable {
            let id = UUID()
            let member: OrganizationAccessMember
        }

        @EnvironmentObject private var appState: AppState
        @Binding var showArchivedProperties: Bool
        let onOpenCloudBackup: (() -> Void)?
        let onOpenDebugTools: (() -> Void)?
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @State private var inviteEmail: String = ""
        @State private var inviteRole: String = "viewer"
        @State private var collaborationStatusMessage: String?
        @State private var collaborationErrorMessage: String?
        @State private var isCollaborationActionInFlight: Bool = false
        @State private var memberForPropertyAccessManagement: PropertyAccessManagementPresentation?
        @State private var pendingMembershipRevoke: PendingMembershipRevoke?
        private let showDeveloperSection: Bool = false
        private let inviteRoleOptions = ["viewer", "field", "manager", "owner"]

        private var buttonFill: Color {
            colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.65)
        }

        private var buttonStroke: Color {
            colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
        }

        private var buttonLabel: Color {
            colorScheme == .light ? Color.black.opacity(0.88) : .white
        }

        private var shouldShowCollaborationSection: Bool {
            appState.requiresAuthentication && appState.isOwnerOfActiveOrganization
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack {
                        Text("Settings")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.primary)

                        Spacer(minLength: 0)

                        Button("Done") {
                            dismiss()
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(buttonLabel)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(buttonFill)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(buttonStroke, lineWidth: 1)
                        )
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 2)

                    List {
                        Section("View") {
                            Toggle("Show Archived", isOn: $showArchivedProperties)
                                .tint(.blue)
                        }

                        Section("Backup") {
                            Button("iCloud Backup") {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                    onOpenCloudBackup?()
                                }
                            }
                        }

                        if let activeOrganizationID = appState.activeOrganizationID {
                            Section("Activity") {
                                NavigationLink("View Activity") {
                                    ActivityFeedView(orgID: activeOrganizationID)
                                        .environmentObject(appState)
                                }
                            }

                            if appState.canRecoverDeletedPropertiesInActiveOrganization {
                                Section("Recovery") {
                                    NavigationLink("Recently Deleted Properties") {
                                        RecentlyDeletedPropertiesRecoveryView()
                                            .environmentObject(appState)
                                    }
                                    NavigationLink("Recently Deleted Sessions") {
                                        RecentlyDeletedSessionsRecoveryView()
                                            .environmentObject(appState)
                                    }
                                }
                            }
                        }

                        if let authenticatedSupabaseUser = appState.authenticatedSupabaseUser {
                            Section("Account") {
                                if let email = authenticatedSupabaseUser.email, !email.isEmpty {
                                    Text(email)
                                } else {
                                    Text(authenticatedSupabaseUser.id.uuidString)
                                        .font(.footnote.monospaced())
                                }

                                if appState.requiresAuthentication {
                                    if let activeOrganization = appState.activeOrganization {
                                        Picker("Active Organization", selection: Binding(
                                            get: { activeOrganization.id.uuidString },
                                            set: { newValue in
                                                if let id = UUID(uuidString: newValue) {
                                                    appState.setActiveOrganization(id: id)
                                                }
                                            }
                                        )) {
                                            ForEach(appState.organizationSelectionOptions) { organization in
                                                Text(organization.name)
                                                    .tag(organization.id.uuidString)
                                            }
                                        }
                                    } else {
                                        Text("No active organization")
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Button("Sign Out", role: .destructive) {
                                    Task {
                                        await appState.signOut()
                                        dismiss()
                                    }
                                }
                            }

                            if appState.requiresAuthentication && !appState.pendingOrganizationInvitations.isEmpty {
                                Section("Pending Invites") {
                                    ForEach(appState.pendingOrganizationInvitations) { invitation in
                                        VStack(alignment: .leading, spacing: 8) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(invitation.orgName)
                                                    .font(.system(size: 15, weight: .semibold))
                                                Text("\(invitation.role.capitalized) access")
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundStyle(.secondary)
                                            }

                                            Button(isCollaborationActionInFlight ? "Accepting..." : "Accept") {
                                                accept(invitation: invitation)
                                            }
                                            .disabled(isCollaborationActionInFlight)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }

                            if shouldShowCollaborationSection,
                               let activeOrganization = appState.activeOrganization {
                                Section("Collaboration") {
                                    Text("Manage access for \(activeOrganization.name)")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)

                                    TextField("Invite by email", text: $inviteEmail)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .keyboardType(.emailAddress)

                                    Picker("Invite Role", selection: $inviteRole) {
                                        ForEach(inviteRoleOptions, id: \.self) { role in
                                            Text(role.capitalized).tag(role)
                                        }
                                    }

                                    Button(isCollaborationActionInFlight ? "Inviting..." : "Send Invite") {
                                        sendInvite()
                                    }
                                    .disabled(
                                        isCollaborationActionInFlight ||
                                        inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                        appState.activeOrganizationID == nil
                                    )

                                    if let collaborationStatusMessage, !collaborationStatusMessage.isEmpty {
                                        Text(collaborationStatusMessage)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }

                                    if let collaborationErrorMessage, !collaborationErrorMessage.isEmpty {
                                        Text(collaborationErrorMessage)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.red)
                                    }

                                    if appState.activeOrganizationMembers.isEmpty {
                                        Text("No members found.")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        ForEach(appState.activeOrganizationMembers) { member in
                                            HStack(alignment: .center, spacing: 12) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(member.displayName)
                                                        .font(.system(size: 15, weight: .semibold))
                                                    if let email = member.email, !email.isEmpty, email != member.displayName {
                                                        Text(email)
                                                            .font(.system(size: 13, weight: .medium))
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    Text(member.role.capitalized)
                                                        .font(.system(size: 12, weight: .medium))
                                                        .foregroundStyle(.secondary)
                                                }

                                                Spacer(minLength: 0)

                                                if member.role != "owner" {
                                                    HStack(spacing: 10) {
                                                        Button("Manage") {
                                                            memberForPropertyAccessManagement = PropertyAccessManagementPresentation(member: member)
                                                        }
                                                        .disabled(isCollaborationActionInFlight)
                                                        .buttonStyle(.borderless)
                                                        .font(.system(size: 13, weight: .semibold))
                                                        .foregroundStyle(.white)
                                                        .padding(.horizontal, 14)
                                                        .frame(height: 32)
                                                        .background(Color.blue)
                                                        .clipShape(Capsule())

                                                        Button {
                                                            pendingMembershipRevoke = PendingMembershipRevoke(member: member)
                                                        } label: {
                                                            ZStack {
                                                                Circle()
                                                                    .fill(Color.red)
                                                                    .frame(width: 32, height: 32)
                                                                Text("X")
                                                                    .font(.system(size: 13, weight: .bold))
                                                                    .foregroundStyle(.white)
                                                            }
                                                        }
                                                        .disabled(isCollaborationActionInFlight)
                                                        .buttonStyle(.borderless)
                                                    }
                                                }
                                            }
                                            .padding(.vertical, 4)
                                        }
                                    }
                                }
                            }
                        }

                        if showDeveloperSection, let onOpenDebugTools {
                            Section("Developer") {
                                Button("Debug Tools") {
                                    dismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                        onOpenDebugTools()
                                    }
                                }
                                .foregroundStyle(.white)
                                .listRowBackground(Color.red)
                            }
                        }
                    }
                    .listSectionSpacing(18)
                }
            }
            .task {
                await refreshCollaborationState()
            }
            .sheet(
                item: $memberForPropertyAccessManagement,
                onDismiss: {
                    memberForPropertyAccessManagement = nil
                }
            ) { presentation in
                if let activeOrganizationID = appState.activeOrganizationID,
                   let activeOrganization = appState.activeOrganization {
                    PropertyAccessManagementSheet(
                        member: presentation.member,
                        organizationID: activeOrganizationID,
                        organizationName: activeOrganization.name,
                        onClose: {
                            memberForPropertyAccessManagement = nil
                        }
                    )
                    .environmentObject(appState)
                }
            }
            .alert(item: $pendingMembershipRevoke) { pendingRevoke in
                Alert(
                    title: Text("Revoke Access?"),
                    message: Text(revokeConfirmationMessage(for: pendingRevoke.member)),
                    primaryButton: .destructive(Text("Revoke Access")) {
                        revoke(member: pendingRevoke.member)
                    },
                    secondaryButton: .cancel(Text("Cancel"))
                )
            }
        }

        private func refreshCollaborationState() async {
            await appState.refreshPendingOrganizationInvitations()
            await appState.refreshActiveOrganizationMembers()
        }

        private func sendInvite() {
            guard let activeOrganizationID = appState.activeOrganizationID else { return }
            let trimmedEmail = inviteEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedEmail.isEmpty else { return }

            collaborationErrorMessage = nil
            collaborationStatusMessage = nil
            isCollaborationActionInFlight = true

            Task {
                defer { isCollaborationActionInFlight = false }
                do {
                    try await appState.inviteUserToOrganization(
                        email: trimmedEmail,
                        role: inviteRole,
                        orgID: activeOrganizationID
                    )
                    inviteEmail = ""
                    collaborationStatusMessage = "Invite sent."
                } catch {
                    collaborationErrorMessage = error.localizedDescription
                }
            }
        }

        private func accept(invitation: PendingOrganizationInvitation) {
            collaborationErrorMessage = nil
            collaborationStatusMessage = nil
            isCollaborationActionInFlight = true

            Task {
                defer { isCollaborationActionInFlight = false }
                do {
                    try await appState.acceptOrganizationInvitation(invitationID: invitation.id)
                    collaborationStatusMessage = "Access accepted."
                } catch {
                    collaborationErrorMessage = error.localizedDescription
                }
            }
        }

        private func revoke(member: OrganizationAccessMember) {
            guard let activeOrganizationID = appState.activeOrganizationID else { return }

            collaborationErrorMessage = nil
            collaborationStatusMessage = nil
            isCollaborationActionInFlight = true

            Task {
                defer { isCollaborationActionInFlight = false }
                do {
                    try await appState.revokeOrganizationMembership(
                        userID: member.id,
                        orgID: activeOrganizationID
                    )
                    collaborationStatusMessage = "Access revoked."
                } catch {
                    collaborationErrorMessage = error.localizedDescription
                }
            }
        }

        private func revokeConfirmationMessage(for member: OrganizationAccessMember) -> String {
            let memberIdentifier = member.email ?? member.displayName
            return "\(memberIdentifier) will lose access to this organization and its associated data."
        }
    }

    private struct RecentlyDeletedPropertiesRecoveryView: View {
        @EnvironmentObject private var appState: AppState
        @State private var properties: [AppState.RecentlyDeletedProperty] = []
        @State private var isLoading: Bool = true
        @State private var restoringPropertyID: UUID?
        @State private var errorMessage: String?

        var body: some View {
            List {
                if isLoading {
                    ProgressView("Loading recently deleted properties...")
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if properties.isEmpty {
                    Text("No recently deleted properties.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(properties) { property in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(property.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(deletedDetail(for: property))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            Button(restoringPropertyID == property.id ? "Restoring..." : "Restore") {
                                restore(property)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(restoringPropertyID != nil)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .task {
                await loadProperties()
            }
            .refreshable {
                await loadProperties()
            }
        }

        private func loadProperties() async {
            isLoading = true
            errorMessage = nil
            do {
                properties = try await appState.fetchRecentlyDeletedPropertiesRemote()
            } catch {
                errorMessage = "Recently deleted properties could not be loaded. \(error.localizedDescription)"
            }
            isLoading = false
        }

        private func restore(_ property: AppState.RecentlyDeletedProperty) {
            restoringPropertyID = property.id
            Task {
                let restored = await appState.remoteRestoreProperty(id: property.id)
                if restored {
                    await loadProperties()
                }
                restoringPropertyID = nil
            }
        }

        private func deletedDetail(for property: AppState.RecentlyDeletedProperty) -> String {
            let deletedText = property.deletedAt.formatted(date: .abbreviated, time: .shortened)
            return "Deleted \(deletedText) - restorable for 30 days"
        }
    }

    private struct RecentlyDeletedSessionsRecoveryView: View {
        @EnvironmentObject private var appState: AppState
        @State private var sessions: [AppState.RecentlyDeletedSession] = []
        @State private var isLoading: Bool = true
        @State private var restoringSessionID: UUID?
        @State private var errorMessage: String?

        var body: some View {
            List {
                if isLoading {
                    ProgressView("Loading recently deleted sessions...")
                } else if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else if sessions.isEmpty {
                    Text("No recently deleted sessions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions) { session in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title(for: session))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(appState.displayNameForProperty(id: session.propertyID))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(deletedDetail(for: session))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            Button(restoringSessionID == session.id ? "Restoring..." : "Restore") {
                                restore(session)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(restoringSessionID != nil)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Recently Deleted Sessions")
            .task {
                await loadSessions()
            }
            .refreshable {
                await loadSessions()
            }
        }

        private func loadSessions() async {
            isLoading = true
            errorMessage = nil
            do {
                sessions = try await appState.fetchRecentlyDeletedSessionsRemote()
            } catch {
                errorMessage = "Recently deleted sessions could not be loaded. \(error.localizedDescription)"
            }
            isLoading = false
        }

        private func restore(_ session: AppState.RecentlyDeletedSession) {
            restoringSessionID = session.id
            Task {
                let restored = await appState.remoteRestoreSession(session)
                if restored {
                    await loadSessions()
                } else {
                    errorMessage = "The session could not be restored."
                }
                restoringSessionID = nil
            }
        }

        private func title(for session: AppState.RecentlyDeletedSession) -> String {
            let date = session.startedAt.formatted(date: .abbreviated, time: .shortened)
            return "\(session.status.capitalized) Session - \(date)"
        }

        private func deletedDetail(for session: AppState.RecentlyDeletedSession) -> String {
            let deletedText = session.deletedAt.formatted(date: .abbreviated, time: .shortened)
            return "Deleted \(deletedText) - restorable for 30 days"
        }
    }

    private struct ActivityFeedView: View {
        @EnvironmentObject private var appState: AppState
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        let orgID: UUID

        @State private var items: [AppState.ActivityFeedItem] = []
        @State private var isLoading: Bool = true
        @State private var errorMessage: String?

        private var buttonFill: Color {
            colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.65)
        }

        private var buttonStroke: Color {
            colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
        }

        private var buttonLabel: Color {
            colorScheme == .light ? Color.black.opacity(0.88) : .white
        }

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    Text("Activity")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)

                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(buttonLabel)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(buttonFill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(buttonStroke, lineWidth: 1)
                    )
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 2)

                List {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                    } else if let errorMessage, !errorMessage.isEmpty {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else if items.isEmpty {
                        Text("No activity yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.displayTitle)
                                    .font(.system(size: 15, weight: .semibold))
                                if !item.displaySubtitle.isEmpty {
                                    Text(item.displaySubtitle)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await load()
                }
            }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await load()
            }
        }

        private func load() async {
            isLoading = true
            errorMessage = nil
            defer {
                isLoading = false
            }

            do {
                items = try await appState.fetchActivityFeed(orgID: orgID)
            } catch {
                items = []
                errorMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Unable to load activity."
                    : error.localizedDescription
            }
        }
    }

    private struct PropertyAccessManagementSheet: View {
        private enum AccessMode: String, CaseIterable, Identifiable {
            case fullOrg = "org"
            case selectedProperties = "property"

            var id: String { rawValue }

            var title: String {
                switch self {
                case .fullOrg:
                    return "Full Org Access"
                case .selectedProperties:
                    return "Selected Properties Only"
                }
            }
        }

        @EnvironmentObject private var appState: AppState

        let member: OrganizationAccessMember
        let organizationID: UUID
        let organizationName: String
        let onClose: () -> Void

        @State private var accessMode: AccessMode = .fullOrg
        @State private var grantedPropertyIDs: Set<UUID> = []
        @State private var isLoading: Bool = true
        @State private var isSaving: Bool = false
        @State private var errorMessage: String?
        @State private var explicitSaveRequested: Bool = false

        private var organizationProperties: [Property] {
            appState.properties.filter { $0.orgId == organizationID }
        }

        private var memberSubtitle: String {
            guard let email = member.email, !email.isEmpty, email != member.displayName else {
                return ""
            }
            return email
        }

        private var canEditPropertyToggles: Bool {
            accessMode == .selectedProperties && !isSaving && !isLoading
        }

        var body: some View {
            NavigationStack {
                List {
                    Section("Member") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(member.displayName)
                                .font(.system(size: 17, weight: .semibold))
                            if !memberSubtitle.isEmpty {
                                Text(memberSubtitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(member.role.capitalized)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Text("Managing access for \(organizationName)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Section("Access Mode") {
                        VStack(spacing: 0) {
                            ForEach(Array(AccessMode.allCases.enumerated()), id: \.element.id) { index, mode in
                                Button {
                                    accessMode = mode
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(mode.title)
                                                .foregroundStyle(.primary)
                                        }
                                        Spacer(minLength: 0)
                                        if accessMode == mode {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.blue)
                                                .font(.system(size: 18, weight: .bold))
                                        }
                                    }
                                    .padding(.horizontal, 2)
                                    .padding(.vertical, 10)
                                    .overlay(alignment: .bottom) {
                                        if index < AccessMode.allCases.count - 1 {
                                            Divider()
                                                .padding(.leading, 2)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Section("Properties") {
                        if isLoading {
                            ProgressView("Loading property access…")
                        } else if organizationProperties.isEmpty {
                            Text("No active properties found.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(organizationProperties) { property in
                                Toggle(
                                    isOn: Binding(
                                        get: { grantedPropertyIDs.contains(property.id) },
                                        set: { isGranted in
                                            if isGranted {
                                                grantedPropertyIDs.insert(property.id)
                                            } else {
                                                grantedPropertyIDs.remove(property.id)
                                            }
                                        }
                                    )
                                ) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(property.name)
                                        if let address = property.address, !address.isEmpty {
                                            Text(address)
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .disabled(!canEditPropertyToggles)
                            }
                        }

                        if accessMode == .fullOrg {
                            Text("Full Org Access ignores property grant filtering while active.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Zero selected properties is allowed and means this member will see no properties.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let errorMessage, !errorMessage.isEmpty {
                        Section {
                            Text(errorMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                        }
                    }
                }
                .navigationTitle("Manage Properties")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onClose()
                        }
                        .disabled(isSaving)
                    }

                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? "Saving…" : "Save") {
                            explicitSaveRequested = true
                            save()
                        }
                        .disabled(isLoading || isSaving)
                    }
                }
            }
            .task {
                await load()
            }
        }

        private func load() async {
            isLoading = true
            errorMessage = nil
            do {
                let grants = try await appState.fetchPropertyAccessGrants(
                    for: member.id,
                    orgID: organizationID
                )
                await MainActor.run {
                    grantedPropertyIDs = grants
                    accessMode = member.accessScope == "property" ? .selectedProperties : .fullOrg
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }

        @MainActor
        private func save() {
            guard explicitSaveRequested else {
                assertionFailure("PropertyAccessManagementSheet.save() called without explicit Save tap")
                errorMessage = "Unable to save property access changes."
                return
            }
            errorMessage = nil
            isSaving = true
            let requestedScope = accessMode.rawValue
            let selectedPropertyIDs = grantedPropertyIDs

            Task {
                do {
                    try await appState.savePropertyAccessConfiguration(
                        userID: member.id,
                        orgID: organizationID,
                        accessScope: requestedScope,
                        grantedPropertyIDs: selectedPropertyIDs
                    )
                    await MainActor.run {
                        explicitSaveRequested = false
                        isSaving = false
                        onClose()
                    }
                } catch {
                    await MainActor.run {
                        print(
                            "[PropertyAccessSaveUI] phase=save_error " +
                            "targetUserID=\(member.id.uuidString) " +
                            "orgID=\(organizationID.uuidString) " +
                            "error=\(error.localizedDescription)"
                        )
                        explicitSaveRequested = false
                        isSaving = false
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private struct SessionArchiveRestoreSheet: View {
        private enum DeviceFilterMode: String, CaseIterable, Identifiable {
            case all
            case onDevice
            case notOnDevice

            var id: String { rawValue }

            var title: String {
                switch self {
                case .all: return "All"
                case .onDevice: return "On Device"
                case .notOnDevice: return "Not On Device"
                }
            }
        }

        @EnvironmentObject private var appState: AppState
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @State private var archives: [LocalStore.SessionArchiveSummary] = []
        @State private var searchQuery: String = ""
        @State private var isSearchActive: Bool = false
        @State private var selectedArchive: LocalStore.SessionArchiveSummary?
        @State private var pendingDeleteArchive: LocalStore.SessionArchiveSummary?
        @State private var isRestoring: Bool = false
        @State private var isRefreshingArchives: Bool = false
        @State private var deviceFilterMode: DeviceFilterMode = .all
        @State private var showRestoreSuccess: Bool = false
        @State private var restoreErrorMessage: String?
        @State private var showRestoreError: Bool = false
        @State private var deleteErrorMessage: String?
        @State private var showDeleteError: Bool = false

        private var buttonFill: Color {
            colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.65)
        }

        private var buttonStroke: Color {
            colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
        }

        private var buttonLabel: Color {
            colorScheme == .light ? Color.black.opacity(0.88) : .white
        }

        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }()

        private var filteredArchives: [LocalStore.SessionArchiveSummary] {
            let baseArchives: [LocalStore.SessionArchiveSummary]
            switch deviceFilterMode {
            case .all:
                baseArchives = archives
            case .onDevice:
                baseArchives = archives.filter { !isDeletedProperty($0) }
            case .notOnDevice:
                baseArchives = archives.filter { isDeletedProperty($0) }
            }
            let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return baseArchives }
            return baseArchives.filter { archive in
                let propertyName = (archive.propertyNameAtCapture ?? appState.properties.first(where: { $0.id == archive.propertyID })?.name ?? "").lowercased()
                let clientName = (archive.clientNameAtCapture ?? appState.properties.first(where: { $0.id == archive.propertyID })?.clientName ?? "").lowercased()
                let orgName = (archive.orgNameAtCapture ?? appState.organizations.first(where: { $0.id == appState.properties.first(where: { $0.id == archive.propertyID })?.orgId })?.name ?? "").lowercased()
                let address = (archive.propertyAddressAtCapture ?? "").lowercased()
                let session = archive.sessionID.uuidString.lowercased()
                return propertyName.contains(query)
                    || clientName.contains(query)
                    || orgName.contains(query)
                    || address.contains(query)
                    || session.contains(query)
            }
        }

        var body: some View {
            NavigationStack {
                let items = filteredArchives
                let hasQuery = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                VStack(alignment: .leading, spacing: 0) {
                    if !isSearchActive {
                        HStack {
                            Button("Done") { dismiss() }
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(buttonLabel)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(buttonFill)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(buttonStroke, lineWidth: 1)
                                )
                                .buttonStyle(.plain)

                            Spacer(minLength: 0)

                            Text("Restore Session Snapshots")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            HStack(spacing: 8) {
                                Button {
                                    reloadArchives()
                                } label: {
                                    Group {
                                        if isRefreshingArchives {
                                            ProgressView()
                                                .progressViewStyle(.circular)
                                                .tint(.primary)
                                        } else {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.system(size: 16, weight: .regular))
                                                .foregroundColor(.primary)
                                        }
                                    }
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(buttonFill)
                                    )
                                    .overlay(
                                        Circle()
                                            .stroke(buttonStroke, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Refresh")
                                .disabled(isRestoring || isRefreshingArchives)

                                Menu {
                                    ForEach(DeviceFilterMode.allCases) { mode in
                                        Button {
                                            deviceFilterMode = mode
                                        } label: {
                                            if deviceFilterMode == mode {
                                                Label(mode.title, systemImage: "checkmark")
                                            } else {
                                                Text(mode.title)
                                            }
                                        }
                                    }
                                } label: {
                                    Image(systemName: "line.3.horizontal.decrease")
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundColor(deviceFilterMode == .all ? .primary : .orange)
                                        .frame(width: 36, height: 36)
                                        .background(
                                            Circle()
                                                .fill(buttonFill)
                                        )
                                        .overlay(
                                            Circle()
                                                .stroke(buttonStroke, lineWidth: 1)
                                        )
                                }
                                .accessibilityLabel("Filter")
                                .disabled(isRestoring)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, -58)
                        .padding(.bottom, 4)
                    }

                    List {
                        if archives.isEmpty {
                            Section {
                                Text("No archived snapshots found yet. Finish and seal/export a session first.")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Section("Session Snapshots") {
                                ForEach(items) { archive in
                                    Button {
                                        selectedArchive = archive
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack(spacing: 6) {
                                                Text(archiveTitle(archive))
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                if archive.isDeliveredCheckpoint {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .font(.system(size: 14, weight: .semibold))
                                                        .foregroundColor(.green)
                                                } else if archive.isSealedCheckpoint {
                                                    Image(systemName: "lock.fill")
                                                        .font(.system(size: 13, weight: .semibold))
                                                        .foregroundColor(.orange)
                                                }
                                                Spacer(minLength: 0)
                                                if isDeletedProperty(archive) {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: "xmark.circle.fill")
                                                            .font(.system(size: 14, weight: .semibold))
                                                            .foregroundColor(.red)
                                                        Text("Not On Device")
                                                            .font(.system(size: 11, weight: .semibold))
                                                            .foregroundColor(.red)
                                                    }
                                                }
                                            }
                                            if let clientOrgLine = archiveClientOrgLine(archive) {
                                                Text(clientOrgLine)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            if let contextLine = archiveContextLine(archive) {
                                                Text(contextLine)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                            Text("Created \(dateFormatter.string(from: archive.createdAt))  File: \(archive.fileCount)")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            pendingDeleteArchive = archive
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            if hasQuery && items.isEmpty {
                                Section {
                                    Text("No matching snapshots")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .searchable(
                    text: $searchQuery,
                    isPresented: $isSearchActive,
                    prompt: "Search property, org, address, session ID"
                )
            }
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(.keyboard, edges: .all)
            .onAppear(perform: reloadArchives)
            .alert("Restore Snapshot?", isPresented: Binding(
                get: { selectedArchive != nil },
                set: { if !$0 { selectedArchive = nil } }
            )) {
                Button("Restore", role: .destructive) {
                    guard let archive = selectedArchive else { return }
                    restore(archive)
                }
                Button("Cancel", role: .cancel) {
                    selectedArchive = nil
                }
            } message: {
                if let archive = selectedArchive {
                    Text("Restore session \(archive.sessionID.uuidString.prefix(8)) from this snapshot created \(dateFormatter.string(from: archive.createdAt))?")
                }
            }
            .alert("Restore Complete", isPresented: $showRestoreSuccess) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Session snapshot restored successfully.")
            }
            .alert("Delete Snapshot?", isPresented: Binding(
                get: { pendingDeleteArchive != nil },
                set: { if !$0 { pendingDeleteArchive = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    guard let archive = pendingDeleteArchive else { return }
                    delete(archive)
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteArchive = nil
                }
            } message: {
                if let archive = pendingDeleteArchive {
                    Text("Delete archive snapshot for \(archiveTitle(archive)) created \(dateFormatter.string(from: archive.createdAt))?")
                }
            }
            .alert("Restore Failed", isPresented: $showRestoreError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(restoreErrorMessage ?? "Unable to restore snapshot.")
            }
            .alert("Delete Failed", isPresented: $showDeleteError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(deleteErrorMessage ?? "Unable to delete snapshot.")
            }
            .overlay {
                if isRestoring {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView("Restoring...")
                            .padding(18)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }

        private func archiveTitle(_ archive: LocalStore.SessionArchiveSummary) -> String {
            let propertyName = archive.propertyNameAtCapture
                ?? appState.properties.first(where: { $0.id == archive.propertyID })?.name
                ?? "Restorable Property"
            return propertyName
        }

        private func isDeletedProperty(_ archive: LocalStore.SessionArchiveSummary) -> Bool {
            !appState.properties.contains(where: { $0.id == archive.propertyID })
        }

        private func archiveClientOrgLine(_ archive: LocalStore.SessionArchiveSummary) -> String? {
            let property = appState.properties.first(where: { $0.id == archive.propertyID })
            let clientName = (archive.clientNameAtCapture ?? property?.clientName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackOrgName: String? = {
                guard let orgId = property?.orgId else { return nil }
                return appState.organizations.first(where: { $0.id == orgId })?.name
            }()
            let orgName = (archive.orgNameAtCapture ?? fallbackOrgName)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let clientName, !clientName.isEmpty, let orgName, !orgName.isEmpty {
                return "\(clientName) (\(orgName))"
            }
            if let clientName, !clientName.isEmpty {
                return clientName
            }
            if let orgName, !orgName.isEmpty {
                return "(\(orgName))"
            }
            return nil
        }

        private func archiveContextLine(_ archive: LocalStore.SessionArchiveSummary) -> String? {
            let property = appState.properties.first(where: { $0.id == archive.propertyID })
            let address = archive.propertyAddressAtCapture
                ?? property?.address
                ?? property?.street
            let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
            return "Session \(archive.sessionID.uuidString.prefix(8))"
        }


        private func reloadArchives() {
            isRefreshingArchives = true
            DispatchQueue.global(qos: .userInitiated).async {
                let refreshed = appState.sessionArchiveSummaries()
                DispatchQueue.main.async {
                    archives = refreshed
                    isRefreshingArchives = false
                }
            }
        }

        private func restore(_ archive: LocalStore.SessionArchiveSummary) {
            isRestoring = true
            selectedArchive = nil
            DispatchQueue.global(qos: .userInitiated).async {
                let success = appState.restoreSessionArchiveSnapshot(
                    propertyID: archive.propertyID,
                    sessionID: archive.sessionID,
                    snapshotName: archive.snapshotName
                )
                DispatchQueue.main.async {
                    isRestoring = false
                    if success {
                        showRestoreSuccess = true
                        reloadArchives()
                    } else {
                        restoreErrorMessage = "Snapshot restore failed. Check console for [SessionRestore] details."
                        showRestoreError = true
                    }
                }
            }
        }

        private func delete(_ archive: LocalStore.SessionArchiveSummary) {
            let success = appState.deleteSessionArchiveSnapshot(
                propertyID: archive.propertyID,
                sessionID: archive.sessionID,
                snapshotName: archive.snapshotName
            )
            pendingDeleteArchive = nil
            if success {
                reloadArchives()
            } else {
                deleteErrorMessage = "Snapshot delete failed. Check console for [SessionArchiveDelete] details."
                showDeleteError = true
            }
        }
    }

    @ViewBuilder
    private var pendingExportPromptOverlay: some View {
        let actionTitle = "Deliver Now"
        let titleText = "Delivery required"
        let messageText = "This property has a completed session waiting to be delivered. Deliver it now to start a new session."
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text(titleText)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                Text(messageText)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    customCapsuleToolbarButton(title: "Cancel", isEnabled: true) {
                        if let session = pendingExportPromptSession {
                            print("[DeliverPrompt] sessionID=\(session.id.uuidString) userAction=cancel")
                        }
                        dismissPendingExportPrompt()
                    }
                    customCapsuleToolbarButton(
                        title: actionTitle,
                        isEnabled: true,
                        fill: .blue,
                        stroke: .blue.opacity(0.9),
                        label: .white
                    ) {
                        guard let property = pendingExportPromptProperty, let session = pendingExportPromptSession else { return }
                        print("[DeliverPrompt] sessionID=\(session.id.uuidString) userAction=deliver")
                        beginPendingExport(for: property, session: session)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: 430)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
        .animation(.easeInOut(duration: 0.18), value: isSearchExpanded)
    }

    @ViewBuilder
    private func initialSessionTypePickerOverlay(for property: Property) -> some View {
        ZStack {
            Color.black.opacity(colorScheme == .light ? 0.52 : 0.68)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Session Type")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(headerPrimaryLabel)

                VStack(spacing: 10) {
                    initialSessionChoiceButton(
                        title: "Full Documentation",
                        subtitle: "Guided photos + flags + resolution required",
                        systemImage: "camera.metering.matrix",
                        isEnabled: true,
                        disabledCaption: nil
                    ) {
                        beginInitialFullDocumentationEntry(for: property)
                    }
                    initialSessionChoiceButton(
                        title: "Punchlist Visit",
                        subtitle: "Active/RR items only, no guided requirements",
                        systemImage: "checklist",
                        isEnabled: true,
                        disabledCaption: nil
                    ) {
                        beginInitialPunchlistEntry(for: property)
                    }
                }

                Button {
                    dismissInitialSessionTypePicker(for: property)
                } label: {
                    Text("Back")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(maxWidth: 430)
            .background(colorScheme == .light ? Color(.systemBackground) : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(colorScheme == .light ? Color.black.opacity(0.12) : Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 10)
            .padding(.horizontal, 20)
        }
        .allowsHitTesting(true)
    }

    private func initialSessionChoiceButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isEnabled: Bool,
        disabledCaption: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    if let disabledCaption {
                        Text(disabledCaption)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary.opacity(0.82))
                    }
                }
                Spacer(minLength: 0)
                if isEnabled {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.blue)
                } else {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.secondary.opacity(0.70))
                }
            }
            .foregroundColor(isEnabled ? headerPrimaryLabel : .secondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 82)
            .background(isEnabled ? Color.blue.opacity(colorScheme == .light ? 0.10 : 0.18) : Color(.tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isEnabled ? Color.blue.opacity(0.30) : Color.secondary.opacity(0.18), lineWidth: 1)
            )
            .opacity(isEnabled ? 1 : 0.78)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func matchesSearch(_ property: Property) -> Bool {
        let query = normalizedSearchQuery
        guard !query.isEmpty else { return true }

        let name = property.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let clientLine = propertyClientLine(property)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let addressLine = propertyAddressLine(property)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return name.contains(query) || clientLine.contains(query) || addressLine.contains(query)
    }

    @ViewBuilder
    private var preparingExportOverlay: some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Preparing Export")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                VStack(spacing: 10) {
                    checklistRow(title: "Originals", isComplete: pendingExportChecklist.originalsComplete)
                    checklistRow(title: "Session Data", isComplete: pendingExportChecklist.sessionDataComplete)
                    checklistRow(title: "ZIP Ready", isComplete: pendingExportChecklist.zipReady)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(minWidth: 280)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private func fastLaneOpeningOverlay(for property: Property) -> some View {
        ZStack {
            Color.black.opacity(0.46)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Opening Camera")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)

                Text(property.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                ProgressView()
                    .tint(.white)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(minWidth: 280, maxWidth: 430)
            .background(Color.black.opacity(0.82))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
        .allowsHitTesting(true)
    }

    private func fastLaneCloseResultOverlay(
        _ result: AppState.FastRuntimePrototypeCloseResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fast-Lane Close Needs Attention")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            if let error = result.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(3)
            } else {
                Text("Your draft state may need cleanup from Debug Tools.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 430, alignment: .leading)
        .background(Color.black.opacity(0.84))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .onTapGesture {
            fastLaneCloseResult = nil
        }
    }

    private func millisecondsText(_ value: Double) -> String {
        String(format: "%.1f ms", value)
    }

    private func optionalMillisecondsText(_ value: Double?) -> String {
        guard let value else { return "not run" }
        return millisecondsText(value)
    }

    @ViewBuilder
    private func checklistRow(title: String, isComplete: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(isComplete ? .white : .white.opacity(0.55))
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.94))
            Spacer(minLength: 0)
        }
    }

    private func openProperty(_ property: Property) {
        // PropertySessionView sets selected property on appear.
        // Avoid duplicating that state write during the navigation push.
        path.append(.propertySession(propertyID: property.id, resumeDraft: false, initialSessionType: nil))
    }

    private func openProperty(_ property: Property, initialSessionType: SessionType) {
        path.append(.propertySession(propertyID: property.id, resumeDraft: false, initialSessionType: initialSessionType))
    }

    private func beginPropertyPressFeedback(propertyID: UUID) {
        guard !isOpeningProperty, pressedPropertyID != propertyID else { return }
        pressedPropertyID = propertyID
        selectionHaptic.impactOccurred()
        selectionHaptic.prepare()
    }

    private func isPropertyPressWithinTapDistance(_ translation: CGSize) -> Bool {
        abs(translation.width) <= 12 && abs(translation.height) <= 12
    }

    private func handlePropertyPressChanged(propertyID: UUID, translation: CGSize) {
        guard isPropertyPressWithinTapDistance(translation) else {
            if pressedPropertyID == propertyID, !isOpeningProperty {
                pressedPropertyID = nil
            }
            return
        }
        beginPropertyPressFeedback(propertyID: propertyID)
    }

    private func handlePropertyPressEnded(_ property: Property, translation: CGSize) {
        guard isPropertyPressWithinTapDistance(translation) else {
            if pressedPropertyID == property.id, !isOpeningProperty {
                pressedPropertyID = nil
            }
            return
        }
        handlePropertyTap(property)
    }

    private func handlePropertyTap(_ property: Property) {
        guard !isOpeningProperty else { return }
        isOpeningProperty = true
        propertyTapToken += 1
        let tapToken = propertyTapToken
        beginPropertyPressFeedback(propertyID: property.id)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            guard tapToken == propertyTapToken else { return }
            continueAcceptedPropertyTap(property, tapToken: tapToken)
        }
    }

    private func continueAcceptedPropertyTap(_ property: Property, tapToken: Int) {
        let badgeModel = appState.propertyCardBadgeModel(for: property.id)
        let pendingSession = appState.propertyRowPendingDeliverySession(for: property.id)
        let fastDraftResumeState = appState.fastRuntimeDraftResumeState(for: property.id)
        let hasPendingExport = badgeModel.showPendingExport
        let hasDraft = badgeModel.showDraft
        let isFastLaneUploading = appState.isFastRuntimeCompletionUploading(propertyID: property.id)

        let latestID = pendingSession?.id.uuidString ??
            badgeModel.activeOccupancySessionID?.uuidString ??
            badgeModel.materialDraftSessionID?.uuidString ??
            "NONE"
        let isBaseline = pendingSession.map { property.baselineSessionID == $0.id } ?? false
        let sealed = pendingSession?.isSealed ?? false
        let firstDelivered = pendingSession?.firstDeliveredAt.map { "\($0)" } ?? "nil"
        let action: String
        if isFastLaneUploading {
            action = "blockFastLaneUploading"
        } else if pendingSession != nil {
            action = "promptDeliver"
        } else if hasPendingExport {
            action = "openPendingExportGate"
        } else if fastDraftResumeState != nil {
            action = "resumeFastLaneDraft"
        } else if !hasDraft {
            action = "showSessionTypePicker"
        } else {
            action = "openCamera"
        }
        verboseLog("[PropertyTap] propertyID=\(property.id.uuidString) latestSessionID=\(latestID) isBaseline=\(isBaseline) sealed=\(sealed) firstDeliveredAt=\(firstDelivered) pending=\(pendingSession != nil) cachedPendingExport=\(hasPendingExport) draft=\(hasDraft) action=\(action) badgeSource=\(badgeModel.badgeSource)")
        if isFastLaneUploading {
            isOpeningProperty = false
            appState.showHubTransientStatusMessage("Uploading. Finishing this session now.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                guard tapToken == propertyTapToken else { return }
                if pressedPropertyID == property.id { pressedPropertyID = nil }
            }
            return
        }
        if let pendingSession {
            isOpeningProperty = false
            pendingExportPromptProperty = property
            pendingExportPromptSession = pendingSession
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                guard tapToken == propertyTapToken else { return }
                if pressedPropertyID == property.id { pressedPropertyID = nil }
            }
            return
        }
        if hasPendingExport {
            openProperty(property)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard tapToken == propertyTapToken else { return }
                if pressedPropertyID == property.id { pressedPropertyID = nil }
            }
            return
        }
        if let fastDraftResumeState {
            if fastDraftResumeState.canResume,
               let context = fastDraftResumeState.context,
               let storageRoot = fastDraftResumeState.storageRoot,
               let summary = fastDraftResumeState.summary {
                beginFastLaneDraftResume(
                    property: property,
                    context: context,
                    summary: summary,
                    storageRoot: storageRoot
                )
            } else {
                isOpeningProperty = false
                fastLaneDraftIssue = FastLaneDraftIssue(
                    property: property,
                    message: fastDraftResumeState.errorMessage ?? "Fast-lane draft resume state is unavailable."
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                guard tapToken == propertyTapToken else { return }
                if pressedPropertyID == property.id { pressedPropertyID = nil }
            }
            return
        }
        if !hasDraft {
            isOpeningProperty = false
            initialSessionTypePickerProperty = property
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                guard tapToken == propertyTapToken else { return }
                if pressedPropertyID == property.id { pressedPropertyID = nil }
            }
            return
        }
        openProperty(property)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard tapToken == propertyTapToken else { return }
            if pressedPropertyID == property.id { pressedPropertyID = nil }
        }
    }

    private func beginFastLaneDraftResume(
        property: Property,
        context: ActiveCaptureContext,
        summary: AppState.FastRuntimeDraftSummary,
        storageRoot: URL
    ) {
        let buttonTappedAt = Date()
        fastLaneCloseResult = nil
        fastLaneOpeningProperty = nil
        fastLanePreviewRequest = FastRuntimeCameraPreviewRequest(
            context: context,
            propertyName: property.name,
            result: AppState.FastRuntimePrototypeResult(
                propertyID: property.id,
                propertyName: property.name,
                sessionType: summary.sessionType,
                entryState: .lockedByCurrentUser,
                lockSessionID: summary.sessionID,
                isCurrentDeviceOccupiedClaim: true,
                requiresFallback: false,
                reason: "fast_runtime_draft_index",
                contextSource: "fast_runtime_draft_index",
                context: context,
                tempStorageRoot: storageRoot,
                didReleasePrototypeClaim: false,
                releaseErrorMessage: nil,
                timings: AppState.FastRuntimePrototypeTimings(
                    targetSessionID: summary.sessionID,
                    rpcMilliseconds: 0,
                    contextMilliseconds: 0,
                    tempStorageMilliseconds: nil,
                    releaseMilliseconds: nil,
                    totalMilliseconds: 0
                )
            ),
            buttonTappedAt: buttonTappedAt,
            contextReadyAt: buttonTappedAt,
            previewRequestedAt: Date(),
            initialCapturedCount: summary.photoCount,
            storageRoot: storageRoot,
            isDraftResume: true,
            initialLocationMode: CameraChromeLocationMode(fastRuntimeRawValue: summary.lastMetadataContext?.locationMode ?? summary.lastLocationMode),
            initialMetadataContext: summary.lastMetadataContext
        )
    }

    private func clearFastLaneDraftsFromIssue() {
        fastLaneCloseResult = nil
        Task {
            let result = await appState.clearFastRuntimePrototypeState()
            await MainActor.run {
                fastLaneCloseResult = AppState.FastRuntimePrototypeCloseResult(
                    propertyID: UUID(),
                    propertyName: "Fast-Lane Cleanup",
                    sessionID: UUID(),
                    draftPersisted: false,
                    photoCount: 0,
                    lockAction: "cleanup \(result.claimReleaseSuccessCount)/\(result.claimReleaseAttemptCount)",
                    tempDiscarded: result.draftFolderDeleted || result.tempFoldersDeletedCount > 0,
                    draftRootPath: nil,
                    errorMessage: result.summary,
                    timings: AppState.FastRuntimePrototypeCloseTimings(
                        persistMilliseconds: nil,
                        releaseMilliseconds: nil,
                        cleanupMilliseconds: nil,
                        totalMilliseconds: 0
                    )
                )
            }
        }
    }

    private func openLegacyPathAfterFastLaneIssue(_ property: Property) {
        isOpeningProperty = true
        openProperty(property)
    }

    private func handleHiddenDebugTap() {
        let now = Date()
        if let lastTapAt = lastHiddenDebugTapAt,
           now.timeIntervalSince(lastTapAt) > hiddenDebugTapWindow {
            hiddenDebugTapCount = 0
        }

        lastHiddenDebugTapAt = now
        hiddenDebugTapCount += 1

        if hiddenDebugTapCount >= 5 {
            hiddenDebugTapCount = 0
            lastHiddenDebugTapAt = nil
            selectionHaptic.impactOccurred()
            showDebugTools = true
        }
    }

    private func dismissPendingExportPrompt() {
        pendingExportPromptProperty = nil
        pendingExportPromptSession = nil
    }

    private func dismissInitialSessionTypePicker(for property: Property) {
        guard initialSessionTypePickerProperty?.id == property.id else { return }
        initialSessionTypePickerProperty = nil
        isOpeningProperty = false
        if pressedPropertyID == property.id {
            pressedPropertyID = nil
        }
        selectionHaptic.prepare()
    }

    private func beginInitialFullDocumentationEntry(for property: Property) {
        beginInitialSessionEntry(for: property, sessionType: .fullDocumentation)
    }

    private func beginInitialPunchlistEntry(for property: Property) {
        beginInitialSessionEntry(for: property, sessionType: .punchlistVisit)
    }

    private func beginInitialSessionEntry(for property: Property, sessionType: SessionType) {
        guard initialSessionTypePickerProperty?.id == property.id else { return }
        initialSessionTypePickerProperty = nil
        isOpeningProperty = true
        propertyTapToken += 1
        if pressedPropertyID == property.id {
            pressedPropertyID = nil
        }
        selectionHaptic.impactOccurred()
        selectionHaptic.prepare()
        beginFastLaneInitialSessionEntry(for: property, sessionType: sessionType, buttonTappedAt: Date())
    }

    private func beginFastLaneInitialSessionEntry(
        for property: Property,
        sessionType: SessionType,
        buttonTappedAt: Date
    ) {
        fastLaneCloseResult = nil
        fastLaneOpeningProperty = property
        Task {
            var result = await appState.runFastRuntimePrototype(
                propertyID: property.id,
                sessionType: sessionType,
                prepareTempStorage: true,
                releaseClaim: false,
                allowCurrentUserOccupiedContext: false
            )
            var contextReadyAt = Date()
            var blockedMessage: String?

            if !fastLaneInitialEntryIsOpenable(result, property: property, sessionType: sessionType),
               result.entryState == .lockedByCurrentUser,
               result.isCurrentDeviceOccupiedClaim {
                if let resumeState = appState.fastRuntimeDraftResumeState(for: property.id),
                   resumeState.canResume,
                   let context = resumeState.context,
                   let storageRoot = resumeState.storageRoot,
                   let summary = resumeState.summary,
                   result.lockSessionID == nil || result.lockSessionID == summary.sessionID {
                    await MainActor.run {
                        guard fastLaneOpeningProperty?.id == property.id else { return }
                        fastLaneOpeningProperty = nil
                        isOpeningProperty = false
                        if pressedPropertyID == property.id {
                            pressedPropertyID = nil
                        }
                        beginFastLaneDraftResume(
                            property: property,
                            context: context,
                            summary: summary,
                            storageRoot: storageRoot
                        )
                    }
                    return
                }

                let release = await appState.releaseFastRuntimePrototypeCurrentUserClaim(
                    propertyID: property.id,
                    requireCurrentDeviceMatch: true
                )
                if release.didRelease {
                    result = await appState.runFastRuntimePrototype(
                        propertyID: property.id,
                        sessionType: sessionType,
                        prepareTempStorage: true,
                        releaseClaim: false,
                        allowCurrentUserOccupiedContext: false
                    )
                    contextReadyAt = Date()
                    if !fastLaneInitialEntryIsOpenable(result, property: property, sessionType: sessionType) {
                        blockedMessage = "Cleared the stale fast-camera claim, but this property is still not ready to open. Please try again."
                    }
                } else {
                    blockedMessage = "This property is already open on this device, and the stale fast-camera claim could not be cleared. Use Debug Tools to clear fast-lane state, then try again."
                }
            }

            await MainActor.run {
                guard fastLaneOpeningProperty?.id == property.id else { return }
                guard fastLaneInitialEntryIsOpenable(result, property: property, sessionType: sessionType),
                      let context = result.context else {
                    fastLaneOpeningProperty = nil
                    isOpeningProperty = false
                    if pressedPropertyID == property.id {
                        pressedPropertyID = nil
                    }
                    appState.showHubTransientStatusMessage(blockedMessage ?? fastLaneInitialEntryBlockedMessage(for: result))
                    return
                }

                fastLaneOpeningProperty = nil
                fastLanePreviewRequest = FastRuntimeCameraPreviewRequest(
                    context: context,
                    propertyName: result.propertyName,
                    result: result,
                    buttonTappedAt: buttonTappedAt,
                    contextReadyAt: contextReadyAt,
                    previewRequestedAt: Date(),
                    initialCapturedCount: 0,
                    storageRoot: result.tempStorageRoot,
                    isDraftResume: false,
                    initialLocationMode: .exterior,
                    initialMetadataContext: nil
                )
            }
        }
    }

    private func fastLaneInitialEntryIsOpenable(
        _ result: AppState.FastRuntimePrototypeResult,
        property: Property,
        sessionType: SessionType
    ) -> Bool {
        guard result.entryState == .unlockedAndClaimed,
              result.requiresFallback == false,
              result.contextSource == "unlocked_and_claimed",
              let context = result.context,
              context.propertyID == property.id,
              context.sessionID == result.timings.targetSessionID,
              context.sessionType == sessionType,
              context.canCapture else {
            return false
        }
        return true
    }

    private func fastLaneInitialEntryBlockedMessage(for result: AppState.FastRuntimePrototypeResult) -> String {
        let reason = result.reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = reason?.lowercased()

        switch result.entryState {
        case .lockedByCurrentUser?:
            if normalizedReason == "current_user_occupied" {
                if result.isCurrentDeviceOccupiedClaim {
                    return "This property is already open on this device. Use the Draft badge or clear fast-lane state from Debug Tools."
                }
                return "This property is already open on your account. Close it on the other device, then try again."
            }
            return "This property is already open on this account. Use the draft or clear the fast-lane test state."
        case .lockedByOtherUser?:
            return "This property is locked by another user."
        case .pendingExport?:
            return "This property is waiting for export to finish."
        case .staleClaimable?:
            return "This property needs a quick refresh before opening."
        case .unlockedAndClaimed?:
            return "Fast camera could not open cleanly. Please try again."
        case .unknownRequiresFallback?, nil:
            if let reason, !reason.isEmpty {
                return "Unable to confirm property availability: \(reason)"
            }
            return "Unable to confirm property availability."
        }
    }

    private func beginPendingExport(for property: Property, session: Session) {
        guard !isPreparingPendingExport else { return }
        pendingExportErrorMessage = nil
        showPendingExportError = false
        isPreparingPendingExport = true
        pendingExportChecklist = ExportChecklistState()
        dismissPendingExportPrompt()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try buildPendingSessionExportArchive(
                    property: property,
                    session: session,
                    progress: { step in
                        DispatchQueue.main.async {
                            switch step {
                            case .originals:
                                pendingExportChecklist.originalsComplete = true
                            case .sessionData:
                                pendingExportChecklist.sessionDataComplete = true
                            case .zipReady:
                                pendingExportChecklist.zipReady = true
                            }
                        }
                    }
                )
                DispatchQueue.main.async {
                    isPreparingPendingExport = false
                    pendingExportFile = PendingExportFile(
                        propertyID: property.id,
                        sessionID: session.id,
                        url: url
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    isPreparingPendingExport = false
                    pendingExportErrorMessage = error.localizedDescription
                    showPendingExportError = true
                    pendingExportPromptProperty = property
                    pendingExportPromptSession = session
                }
            }
        }
    }

    private func buildPendingSessionExportArchive(
        property: Property,
        session: Session,
        progress: ((ExportChecklistStep) -> Void)? = nil
    ) throws -> URL {
        let validationArtifacts = try localStore.validatedSessionExportArtifacts(for: session)
        let propertyFolderName = try localStore.exportPropertyFolderName(propertyID: property.id)
        let exportRoot = try StorageRoot.makeSessionExportRootFolder(
            propertyFolderName: propertyFolderName,
            sessionID: session.id
        )
        let originalsRoot = exportRoot.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originalsRoot, withIntermediateDirectories: true)
        var expectedPaths = Set([
            "session.json",
            "validation.txt",
            "sessions.csv",
            "shots.csv",
            "issues.csv",
            "issue_history.csv",
            "guided_rows.csv",
            "Originals/"
        ])
        let sessionMetadata = try localStore.loadSessionMetadata(propertyID: property.id, sessionID: session.id)
#if DEBUG
        print("Pending export sessionStartedAt: \(sessionMetadata.startedAt)")
        print("Pending export sessionStartedAtLocal: \(sessionMetadata.sessionStartedAtLocal)")
        if let firstShot = sessionMetadata.shots.sorted(by: { $0.createdAt < $1.createdAt }).first {
            print("Pending export first shot createdAt: \(firstShot.createdAt)")
            print("Pending export first shot createdAtLocal: \(firstShot.capturedAtLocal ?? "nil")")
        }
        if let firstDeliveredAt = sessionMetadata.firstDeliveredAt {
            print("Pending export firstDeliveredAt: \(firstDeliveredAt)")
        }
        if let reExportExpiresAt = sessionMetadata.reExportExpiresAt {
            print("Pending export reExportExpiresAt: \(reExportExpiresAt)")
        }
#endif
        for originalFile in validationArtifacts.originalFiles {
            let data = try Data(contentsOf: originalFile.sourceURL)
            let attrs = try? FileManager.default.attributesOfItem(atPath: originalFile.sourceURL.path)
            let modifiedAt = (attrs?[.modificationDate] as? Date) ?? (attrs?[.creationDate] as? Date)
            let destinationURL = originalsRoot.appendingPathComponent(originalFile.filename)
            try data.write(to: destinationURL, options: .atomic)
            if let modifiedAt {
                try? FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: destinationURL.path)
            }
            expectedPaths.insert("Originals/\(originalFile.filename)")
        }
        progress?(.originals)
        try validationArtifacts.sessionData.write(to: exportRoot.appendingPathComponent("session.json"), options: .atomic)
        try validationArtifacts.validationData.write(to: exportRoot.appendingPathComponent("validation.txt"), options: .atomic)
        for csvFile in localStore.exportCSVFiles(for: validationArtifacts.metadata) {
            try csvFile.data.write(to: exportRoot.appendingPathComponent(csvFile.filename), options: .atomic)
        }
        if !validationArtifacts.prewritePassed || !validationArtifacts.postwritePassed {
            let message = String(data: validationArtifacts.validationData, encoding: .utf8) ?? "Export validation failed."
            throw NSError(
                domain: "ScoutCapture.PendingExport",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Export validation failed before ZIP creation.\n\n\(message)"]
            )
        }
#if DEBUG
        print("EXPORT ROOT: \(exportRoot.path)")
        print("EXPORT ROOT FILES: \((try? StorageRoot.exportRootFilenames(exportRoot)) ?? [])")
#endif
        progress?(.sessionData)

        let zipEntries = try StorageRoot.zipEntriesForExportRoot(exportRoot).map { ($0.path, $0.data, $0.modifiedAt) }
        let zipData = buildZipData(entries: zipEntries)
        let fileManager = FileManager.default
        let finalURL = fileManager.temporaryDirectory.appendingPathComponent(exportZipFilename(for: property, session: session))
        let tempURL = fileManager.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tmp.zip")
#if DEBUG
        print("Pending export ZIP temp path: \(tempURL.path)")
        print("Pending export ZIP final path: \(finalURL.path)")
#endif
        if fileManager.fileExists(atPath: tempURL.path) {
            try fileManager.removeItem(at: tempURL)
        }
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }
        try zipData.write(to: tempURL, options: [.atomic])
        let tempExists = fileManager.fileExists(atPath: tempURL.path)
        let tempSize = ((try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("Pending export ZIP temp exists: \(tempExists ? "YES" : "NO"), bytes: \(tempSize)")
#endif
        guard tempExists, tempSize > 0 else {
            throw NSError(domain: "ScoutCapture.PendingExport", code: 5, userInfo: [NSLocalizedDescriptionKey: "Temporary ZIP write failed."])
        }

        try fileManager.moveItem(at: tempURL, to: finalURL)
        let finalExists = fileManager.fileExists(atPath: finalURL.path)
        let finalSize = ((try? fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("Pending export ZIP final exists: \(finalExists ? "YES" : "NO"), bytes: \(finalSize)")
#endif
        guard finalExists, finalSize > 0 else {
            throw NSError(domain: "ScoutCapture.PendingExport", code: 6, userInfo: [NSLocalizedDescriptionKey: "Final ZIP write failed."])
        }

        let listedEntries = try listPendingExportZipEntryPaths(at: finalURL)
#if DEBUG
        let preview = Array(listedEntries.prefix(12))
        print("Pending export ZIP entries count: \(listedEntries.count)")
        print("Pending export ZIP entries preview: \(preview)")
#endif
        let zipRootFolderName = exportRoot.deletingLastPathComponent().lastPathComponent
        let normalizedExpectedPaths = Set(expectedPaths.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
        let actualPaths = Set(listedEntries.compactMap { path -> String? in
            let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !normalized.isEmpty else { return nil }
            if normalized == zipRootFolderName { return nil }
            let prefix = "\(zipRootFolderName)/"
            if normalized.hasPrefix(prefix) {
                return String(normalized.dropFirst(prefix.count))
            }
            return normalized
        })
        guard normalizedExpectedPaths.isSubset(of: actualPaths) else {
            throw NSError(domain: "ScoutCapture.PendingExport", code: 7, userInfo: [NSLocalizedDescriptionKey: "ZIP integrity check failed."])
        }
#if DEBUG
        guard actualPaths.contains("session.json"), actualPaths.contains("validation.txt") else {
            assertionFailure("Pending export ZIP root missing session.json or validation.txt")
            throw NSError(domain: "ScoutCapture.PendingExport", code: 10, userInfo: [NSLocalizedDescriptionKey: "ZIP root missing validation artifacts."])
        }
#endif
        progress?(.zipReady)
        return finalURL
    }

    private func requestImageData(for fileURL: URL) -> Data? {
        try? Data(contentsOf: fileURL)
    }

    private func ensurePendingStampedJPEGs(
        propertyID: UUID,
        sessionID: UUID,
        propertyName: String,
        propertyAddress: String?,
        sessionMetadata: SessionMetadata
    ) throws -> [String: URL] {
        let fileManager = FileManager.default
        var metadata = sessionMetadata
        var didUpdateMetadata = false
        var output: [String: URL] = [:]
        var reservedNames = Set(
            ((try? fileManager.contentsOfDirectory(atPath: localStore.stampedDirectoryURL(propertyID: propertyID, sessionID: sessionID).path)) ?? [])
                .map { $0.lowercased() }
        )

        for index in metadata.shots.indices {
            let shot = metadata.shots[index]
            let originalURL = localStore.originalsDirectoryURL(propertyID: propertyID, sessionID: sessionID)
                .appendingPathComponent(shot.originalFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: originalURL.path) else { continue }

            let stampedName = nextReadablePendingStampedFilename(shot: shot, reservedNames: &reservedNames)
            if metadata.shots[index].stampedFilename != stampedName {
                metadata.shots[index].stampedFilename = stampedName
                didUpdateMetadata = true
            }
            let stampedRelative = "Stamped/\(stampedName)"
            if metadata.shots[index].stampedRelativePath != stampedRelative {
                metadata.shots[index].stampedRelativePath = stampedRelative
                didUpdateMetadata = true
            }
            if (metadata.shots[index].imageWidth ?? 0) <= 0 || (metadata.shots[index].imageHeight ?? 0) <= 0 {
                let sourceImage = UIImage(contentsOfFile: originalURL.path)
                if let sourceImage {
                    metadata.shots[index].imageWidth = max(1, Int(sourceImage.size.width))
                    metadata.shots[index].imageHeight = max(1, Int(sourceImage.size.height))
                    didUpdateMetadata = true
                }
            }

            let stampedURL = localStore.stampedDirectoryURL(propertyID: propertyID, sessionID: sessionID)
                .appendingPathComponent(stampedName, isDirectory: false)
            try createPendingStampedJPEGIfMissing(
                sourceURL: originalURL,
                destinationURL: stampedURL,
                captureDate: shot.updatedAt,
                overlayLines: pendingStampOverlayLines(
                    propertyName: propertyName,
                    shot: shot,
                    isBaselineSession: metadata.isBaselineSession
                ),
                metadataContext: pendingStampedMetadataContext(
                    propertyID: propertyID,
                    propertyName: propertyName,
                    propertyAddress: propertyAddress,
                    sessionID: sessionID,
                    shot: shot,
                    schemaVersion: metadata.schemaVersion
                ),
                fileManager: fileManager
            )
            output[shot.originalFilename] = stampedURL
        }

        if didUpdateMetadata {
            try localStore.saveSessionMetadataAtomically(
                propertyID: propertyID,
                sessionID: sessionID,
                metadata: metadata
            )
#if DEBUG
            if let firstStamped = metadata.shots.first?.stampedRelativePath {
                print("[Stamp] metadata stampedRelativePath sample=\(firstStamped)")
            }
#endif
        }

        return output
    }

    private func createPendingStampedJPEGIfMissing(
        sourceURL: URL,
        destinationURL: URL,
        captureDate: Date,
        overlayLines: [String],
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destinationURL.path),
           ((try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0 > 0 {
            return
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let sourceData = try Data(contentsOf: sourceURL)
        let stampedData = try encodePendingStampedJPEG(
            from: sourceData,
            captureDate: captureDate,
            overlayLines: overlayLines,
            metadataContext: metadataContext
        )
        try stampedData.write(to: destinationURL, options: [.atomic])

        let size = ((try? fileManager.attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber) ?? nil)?.intValue ?? 0
#if DEBUG
        print("[Stamp] destination=\(destinationURL.path) utType=\(UTType.jpeg.identifier) bytes=\(size)")
#endif
        guard fileManager.fileExists(atPath: destinationURL.path), size > 0 else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stamped JPEG write failed"])
        }

        try fileManager.setAttributes(
            [
                .creationDate: captureDate,
                .modificationDate: captureDate
            ],
            ofItemAtPath: destinationURL.path
        )
#if DEBUG
        if let attrs = try? fileManager.attributesOfItem(atPath: destinationURL.path) {
            let created = attrs[.creationDate] as? Date
            let modified = attrs[.modificationDate] as? Date
            print("[Stamp] readback creation=\(String(describing: created)) modification=\(String(describing: modified))")
        }
        if let source = CGImageSourceCreateWithURL(destinationURL as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
            print("[Stamp] readback pixelWidth=\(width) pixelHeight=\(height) orientation=\(orientation)")
        }
#endif
    }

    private func encodePendingStampedJPEG(
        from sourceData: Data,
        captureDate: Date,
        overlayLines: [String],
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing source image for pending stamped export"])
        }

        let sourceCGImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        let sourceProps = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let sourceOrientationRaw = (sourceProps[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        let capturedOrientationRaw = metadataContext.capturedExifOrientationRaw
        let resolvedOrientationRaw = sourceOrientationRaw ?? capturedOrientationRaw ?? 1
        print("[Stamp] orientation capturedRaw=\(capturedOrientationRaw.map(String.init) ?? "nil") sourceRaw=\(sourceOrientationRaw.map(String.init) ?? "nil") resolvedRaw=\(resolvedOrientationRaw)")
        if let sourceCGImage {
            print("[Stamp] before encode pixelWidth=\(sourceCGImage.width) pixelHeight=\(sourceCGImage.height)")
        }
        let image = normalizedPendingUprightCGImage(from: sourceData)
            ?? sourceCGImage
        guard let image else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing source image for pending stamped export"])
        }
        print("[Stamp] after upright pixelWidth=\(image.width) pixelHeight=\(image.height)")
        var mergedProps = sourceProps
        var exif = (mergedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        var tiff = (mergedProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]

        let captureTime = ReportLibraryModel.EmbeddedCaptureTime(captureDate: captureDate)
        exif[kCGImagePropertyExifDateTimeOriginal] = captureTime.localDateTimeString
        exif[kCGImagePropertyExifDateTimeDigitized] = captureTime.localDateTimeString
        exif[kCGImagePropertyExifSubsecTimeOriginal] = captureTime.subsecString
        exif[kCGImagePropertyExifSubsecTimeDigitized] = captureTime.subsecString
        exif[kCGImagePropertyExifOffsetTimeOriginal] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifOffsetTimeDigitized] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifOffsetTime] = captureTime.tzOffsetString
        exif[kCGImagePropertyExifUserComment] = pendingStructuredComment(
            captureTime: captureTime,
            metadataContext: metadataContext
        )
        tiff[kCGImagePropertyTIFFDateTime] = captureTime.localDateTimeString
        mergedProps[kCGImagePropertyExifDictionary] = exif
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        mergedProps[kCGImagePropertyOrientation] = 1
        tiff[kCGImagePropertyTIFFOrientation] = 1
        mergedProps[kCGImagePropertyTIFFDictionary] = tiff
        mergedProps[kCGImageDestinationLossyCompressionQuality] = 0.90
        print("[Stamp] orientation writeTag exif/tiff=1")
        if let gps = makePendingGPSDictionary(
            latitude: metadataContext.latitude,
            longitude: metadataContext.longitude,
            accuracyMeters: metadataContext.accuracyMeters,
            captureDate: captureDate
        ) {
            mergedProps[kCGImagePropertyGPSDictionary] = gps
        }
        let caption = overlayLines.joined(separator: "\n")
        if !caption.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription] = caption
            mergedProps[kCGImagePropertyTIFFDictionary] = tiff
            var iptc = (mergedProps[kCGImagePropertyIPTCDictionary] as? [CFString: Any]) ?? [:]
            iptc[kCGImagePropertyIPTCCaptionAbstract] = caption
            iptc[kCGImagePropertyIPTCKeywords] = pendingKeywordList(metadataContext: metadataContext)
            mergedProps[kCGImagePropertyIPTCDictionary] = iptc
        }

#if DEBUG
        let topKeys = mergedProps.keys.map { $0 as String }.sorted()
        let exifKeys = ((mergedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String }.sorted()
        let gpsKeys = ((mergedProps[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]).keys.map { $0 as String }.sorted()
        let hasDateTimeOriginal = ((mergedProps[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:])[kCGImagePropertyExifDateTimeOriginal] != nil
        let hasGpsAccuracy = ((mergedProps[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:])[kCGImagePropertyGPSHPositioningError] != nil
        print("[Stamp] captureDate=\(captureTime.captureDate) localDateTimeString=\(captureTime.localDateTimeString) tzOffset=\(captureTime.tzOffsetString) iso8601WithOffset=\(captureTime.iso8601WithOffset)")
        let accuracyText = metadataContext.accuracyMeters.map { String(format: "%.3f", $0) } ?? "nil"
        print("[Stamp] gps present=\(gpsKeys.isEmpty ? "NO" : "YES") accuracyMeters=\(accuracyText)")
        print("[Stamp] metadata top-level keys: \(topKeys)")
        print("[Stamp] metadata EXIF keys: \(exifKeys)")
        print("[Stamp] metadata GPS keys: \(gpsKeys)")
        print("[Stamp] metadata has DateTimeOriginal=\(hasDateTimeOriginal) has GPSHPositioningError=\(hasGpsAccuracy)")
#endif

        let stampedCGImage = drawPendingStampOverlay(on: image, lines: overlayLines) ?? image

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create JPEG destination"])
        }
        if let xmpMetadata = buildPendingXMPMetadata(
            source: source,
            captureTime: captureTime,
            metadataContext: metadataContext
        ) {
            CGImageDestinationAddImageAndMetadata(
                destination,
                stampedCGImage,
                xmpMetadata,
                mergedProps as CFDictionary
            )
        } else {
            CGImageDestinationAddImage(destination, stampedCGImage, mergedProps as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ScoutCapture.PendingStamp", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize JPEG destination"])
        }
        return destinationData as Data
    }

    private func pendingStampedMetadataContext(
        propertyID: UUID,
        propertyName: String,
        propertyAddress: String?,
        sessionID: UUID,
        shot: ShotMetadata,
        schemaVersion: Int
    ) -> ReportLibraryModel.EmbeddedMetadataContext {
        ReportLibraryModel.EmbeddedMetadataContext(
            propertyID: propertyID,
            propertyName: propertyName,
            propertyAddress: propertyAddress,
            sessionID: sessionID,
            shotID: shot.shotID,
            shotKey: shot.shotKey,
            building: shot.building,
            elevation: shot.elevation,
            detailType: shot.detailType,
            angleIndex: shot.angleIndex,
            trade: shot.trade,
            priority: shot.priority,
            isGuided: shot.isGuided,
            isFlagged: shot.isFlagged,
            issueStatus: shot.issueStatus,
            detailNote: shot.noteText,
            captureMode: shot.captureMode,
            lens: shot.lens,
            orientation: shot.exifOrientation.map { "exif:\($0)" } ?? shot.orientation,
            capturedExifOrientationRaw: shot.exifOrientation.flatMap(UInt32.init) ?? pendingParseExifOrientationRaw(from: shot.orientation),
            latitude: shot.latitude,
            longitude: shot.longitude,
            accuracyMeters: shot.accuracyMeters,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            schemaVersion: schemaVersion
        )
    }

    private func pendingParseExifOrientationRaw(from orientation: String?) -> UInt32? {
        let trimmed = orientation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        if let direct = UInt32(trimmed), direct >= 1, direct <= 8 {
            return direct
        }
        let prefix = "exif:"
        if trimmed.lowercased().hasPrefix(prefix),
           let value = UInt32(trimmed.dropFirst(prefix.count)),
           value >= 1, value <= 8 {
            return value
        }
        return nil
    }

    private func pendingStructuredComment(
        captureTime: ReportLibraryModel.EmbeddedCaptureTime,
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext
    ) -> String {
        var pairs: [String] = []
        func append(_ key: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                pairs.append("\(key)=\(trimmed)")
            }
        }
        append("propertyID", metadataContext.propertyID?.uuidString)
        append("propertyName", metadataContext.propertyName)
        append("propertyAddress", metadataContext.propertyAddress)
        append("sessionID", metadataContext.sessionID?.uuidString)
        append("shotID", metadataContext.shotID?.uuidString)
        append("shotKey", metadataContext.shotKey)
        append("building", metadataContext.building)
        append("elevation", metadataContext.elevation)
        append("detailType", metadataContext.detailType)
        append("angleIndex", metadataContext.angleIndex.map(String.init))
        append("captureMode", metadataContext.captureMode)
        append("lens", metadataContext.lens)
        append("orientation", metadataContext.orientation)
        append("trade", metadataContext.trade)
        append("priority", metadataContext.priority)
        append("captureDateLocal", captureTime.localDateTimeString)
        append("captureDateISO8601", captureTime.iso8601WithOffset)
        if let accuracy = metadataContext.accuracyMeters {
            append("gpsAccuracyMeters", String(format: "%.3f", accuracy))
        }
        return pairs.joined(separator: ";")
    }

    private func pendingKeywordList(metadataContext: ReportLibraryModel.EmbeddedMetadataContext) -> [String] {
        var keywords: [String] = ["SCOUT"]
        let values = [
            metadataContext.propertyName,
            metadataContext.building,
            metadataContext.elevation,
            metadataContext.detailType,
            metadataContext.trade,
            metadataContext.priority
        ]
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                keywords.append(trimmed)
            }
        }
        keywords.append(metadataContext.isGuided == true ? "Guided" : "Free")
        if metadataContext.isFlagged == true {
            keywords.append("Flagged")
        }
        if let angle = metadataContext.angleIndex {
            keywords.append("Angle \(angle)")
        }
        return Array(NSOrderedSet(array: keywords)) as? [String] ?? keywords
    }

    private func makePendingGPSDictionary(
        latitude: Double?,
        longitude: Double?,
        accuracyMeters: Double?,
        captureDate: Date
    ) -> [CFString: Any]? {
        guard let latitude, let longitude else { return nil }
        var gps: [CFString: Any] = [:]
        gps[kCGImagePropertyGPSLatitude] = abs(latitude)
        gps[kCGImagePropertyGPSLatitudeRef] = latitude >= 0 ? "N" : "S"
        gps[kCGImagePropertyGPSLongitude] = abs(longitude)
        gps[kCGImagePropertyGPSLongitudeRef] = longitude >= 0 ? "E" : "W"
        gps[kCGImagePropertyGPSDateStamp] = Self.pendingExportGPSDateFormatter.string(from: captureDate)
        gps[kCGImagePropertyGPSTimeStamp] = Self.pendingExportGPSTimeFormatter.string(from: captureDate)
        if let accuracyMeters, accuracyMeters >= 0 {
            gps[kCGImagePropertyGPSHPositioningError] = accuracyMeters
        }
        return gps
    }

    private func buildPendingXMPMetadata(
        source: CGImageSource,
        captureTime: ReportLibraryModel.EmbeddedCaptureTime,
        metadataContext: ReportLibraryModel.EmbeddedMetadataContext
    ) -> CGMutableImageMetadata? {
        let baseMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        let mutable = baseMetadata.flatMap(CGImageMetadataCreateMutableCopy) ?? CGImageMetadataCreateMutable()
        var registrationError: Unmanaged<CFError>?
        _ = CGImageMetadataRegisterNamespaceForPrefix(
            mutable,
            "https://scoutcapture.app/ns/1.0/" as CFString,
            "scout" as CFString,
            &registrationError
        )
        func setTag(_ path: String, _ value: String?) {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }
            let components = path.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return }
            let prefix = components[0]
            let name = components[1]
            let namespace: String
            switch prefix {
            case "xmp":
                namespace = "http://ns.adobe.com/xap/1.0/"
            case "scout":
                namespace = "https://scoutcapture.app/ns/1.0/"
            default:
                return
            }
            guard let tag = CGImageMetadataTagCreate(
                namespace as CFString,
                prefix as CFString,
                name as CFString,
                .string,
                trimmed as CFString
            ) else {
                return
            }
            CGImageMetadataSetTagWithPath(mutable, nil, path as CFString, tag)
        }
        setTag("xmp:CreateDate", captureTime.iso8601WithOffset)
        setTag("xmp:ModifyDate", captureTime.iso8601WithOffset)
        setTag("scout:propertyID", metadataContext.propertyID?.uuidString)
        setTag("scout:propertyName", metadataContext.propertyName)
        setTag("scout:propertyAddress", metadataContext.propertyAddress)
        setTag("scout:sessionID", metadataContext.sessionID?.uuidString)
        setTag("scout:shotID", metadataContext.shotID?.uuidString)
        setTag("scout:shotKey", metadataContext.shotKey)
        setTag("scout:building", metadataContext.building)
        setTag("scout:elevation", metadataContext.elevation)
        setTag("scout:detailType", metadataContext.detailType)
        setTag("scout:angleIndex", metadataContext.angleIndex.map(String.init))
        setTag("scout:isGuided", metadataContext.isGuided.map { $0 ? "true" : "false" })
        setTag("scout:isFlagged", metadataContext.isFlagged.map { $0 ? "true" : "false" })
        setTag("scout:captureMode", metadataContext.captureMode)
        setTag("scout:lens", metadataContext.lens)
        setTag("scout:orientation", metadataContext.orientation)
        setTag("scout:appVersion", metadataContext.appVersion)
        setTag("scout:osVersion", metadataContext.osVersion)
        setTag("scout:deviceModel", metadataContext.deviceModel)
        setTag("scout:schemaVersion", metadataContext.schemaVersion.map(String.init))
        setTag("scout:issueStatus", metadataContext.issueStatus)
        setTag("scout:issueNote", metadataContext.detailNote)
        setTag("scout:trade", metadataContext.trade)
        setTag("scout:priority", metadataContext.priority)
        if let accuracy = metadataContext.accuracyMeters {
            setTag("scout:gpsAccuracyMeters", String(format: "%.3f", accuracy))
        }
        return mutable
    }

    private func normalizedPendingUprightCGImage(from sourceData: Data) -> CGImage? {
        guard let uiImage = UIImage(data: sourceData) else { return nil }
        let size = uiImage.size
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            uiImage.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    private func drawPendingStampOverlay(on image: CGImage, lines: [String]) -> CGImage? {
        guard !lines.isEmpty else { return image }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        format.scale = 1
        let size = CGSize(width: width, height: height)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))

            let shortEdge = CGFloat(min(width, height))
            let sideInset = max(16, shortEdge * 0.025)
            let bottomInset = max(16, shortEdge * 0.025)
            let lineSpacing = max(2, shortEdge * 0.004)
            let cornerRadius = max(8, shortEdge * 0.016)
            let primarySize = max(14, shortEdge * 0.030)
            let secondarySize = max(12, shortEdge * 0.024)

            let styled: [NSAttributedString] = lines.enumerated().map { idx, line in
                NSAttributedString(
                    string: line,
                    attributes: [
                        .font: idx == 0
                            ? UIFont.systemFont(ofSize: primarySize, weight: .semibold)
                            : UIFont.systemFont(ofSize: secondarySize, weight: .regular),
                        .foregroundColor: UIColor.white
                    ]
                )
            }
            let maxTextWidth = size.width - (sideInset * 3)
            let lineSizes = styled.map { text in
                text.boundingRect(
                    with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).integral.size
            }
            let textHeight = lineSizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, lineSizes.count - 1)) * lineSpacing
            let textWidth = min(maxTextWidth, lineSizes.map(\.width).max() ?? maxTextWidth)
            let padX = max(8, shortEdge * 0.013)
            let padY = max(5, shortEdge * 0.009)
            let panelRect = CGRect(
                x: sideInset,
                y: size.height - bottomInset - (textHeight + padY * 2),
                width: textWidth + (padX * 2),
                height: textHeight + (padY * 2)
            )

            let panelPath = UIBezierPath(roundedRect: panelRect, cornerRadius: cornerRadius)
            UIColor.black.withAlphaComponent(0.58).setFill()
            panelPath.fill()

            var y = panelRect.minY + padY
            for (idx, text) in styled.enumerated() {
                let drawRect = CGRect(
                    x: panelRect.minX + padX,
                    y: y,
                    width: textWidth,
                    height: lineSizes[idx].height
                )
                text.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                y += lineSizes[idx].height + lineSpacing
            }
        }
        return rendered.cgImage
    }

    private static let pendingExportExifTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()

    private static let pendingExportExifSubsecFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "SSS"
        return formatter
    }()

    private static let pendingExportGPSDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd"
        return formatter
    }()

    private static let pendingExportGPSTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static func pendingExportExifOffsetString(for date: Date) -> String {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        return String(format: "%@%02d:%02d", sign, hours, minutes)
    }

    private func pendingStampOverlayLines(propertyName: String, shot: ShotMetadata, isBaselineSession: Bool) -> [String] {
        let line1 = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let line2 = [
            shot.building,
            shot.elevation,
            shot.detailType,
            "Angle \(max(1, shot.angleIndex))"
        ]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
        let line3 = Self.pendingOverlayDateFormatter.string(from: shot.updatedAt)
        let noteLine = (shot.noteText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line4 = (shot.isFlagged && !noteLine.isEmpty) ? noteLine : ""
        _ = isBaselineSession
        return [line1, line2, line3, line4].filter { !$0.isEmpty }
    }

    private func nextReadablePendingStampedFilename(shot: ShotMetadata, reservedNames: inout Set<String>) -> String {
        let base = readablePendingStampedBaseName(for: shot)
        var candidate = "\(base).jpg"
        var counter = 1
        while reservedNames.contains(candidate.lowercased()) {
            candidate = "\(base)_\(String(format: "%02d", counter)).jpg"
            counter += 1
        }
        reservedNames.insert(candidate.lowercased())
        return candidate
    }

    private func readablePendingStampedBaseName(for shot: ShotMetadata) -> String {
        let datePart = Self.pendingFilenameDateFormatter.string(from: shot.updatedAt)
        let parts = [
            sanitizePendingStampFilenamePart(shot.building),
            sanitizePendingStampFilenamePart(shot.elevation),
            sanitizePendingStampFilenamePart(shot.detailType),
            "A\(max(1, shot.angleIndex))",
            datePart
        ].filter { !$0.isEmpty }
        let base = parts.joined(separator: "_")
        return base.isEmpty ? shot.shotID.uuidString : base
    }

    private func sanitizePendingStampFilenamePart(_ raw: String) -> String {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let scalars = normalized.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let collapsed = String(scalars)
            .replacingOccurrences(of: "__", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return String(collapsed.prefix(40))
    }

    private static let pendingFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let pendingOverlayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "MM-dd-yyyy h:mm:ss a"
        return formatter
    }()

    private func exportFilename(for fileURL: URL, index: Int) -> String {
        let fallback = "photo-\(index).jpg"
        let original = fileURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = original.isEmpty ? fallback : normalizedContextFilename(original)
        return String(format: "%04d-%@", index, base.replacingOccurrences(of: "/", with: "-"))
    }

    private func normalizedContextFilename(_ filename: String) -> String {
        var output = filename
        let replacements: [(String, String)] = [
            ("North Elevation", "N"),
            ("South Elevation", "S"),
            ("East Elevation", "E"),
            ("West Elevation", "W")
        ]
        for (source, target) in replacements {
            output = output.replacingOccurrences(of: source, with: target, options: .caseInsensitive)
        }
        output = output.replacingOccurrences(of: "Elevation", with: "", options: .caseInsensitive)
        output = output.replacingOccurrences(of: "__", with: "_")
        output = output.replacingOccurrences(of: "  ", with: " ")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func exportZipFilename(for property: Property, session: Session) -> String {
        let safeProperty = sanitizedExportName(property.name, fallback: "ScoutCapture-Export")
        let propertyPrefix = String(property.id.uuidString.prefix(8))
        let sessionPrefix = String(session.id.uuidString.prefix(8))
        return "\(safeProperty)_\(propertyPrefix)_\(sessionPrefix).zip"
    }

    private func sanitizedExportName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let compact = cleaned.replacingOccurrences(of: "  ", with: " ")
        return compact.isEmpty ? fallback : compact
    }

    private func buildZipData(entries: [(path: String, data: Data, modifiedAt: Date?)]) -> Data {
        struct CentralRecord {
            let pathData: Data
            let crc32: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
            let dosTime: UInt16
            let dosDate: UInt16
        }

        var zip = Data()
        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(zip.count)
            let (dosTime, dosDate) = dosDateTime(entry.modifiedAt ?? Date())

            appendUInt32LE(0x04034B50, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(dosTime, to: &zip)
            appendUInt16LE(dosDate, to: &zip)
            appendUInt32LE(crc, to: &zip)
            appendUInt32LE(size, to: &zip)
            appendUInt32LE(size, to: &zip)
            appendUInt16LE(UInt16(pathData.count), to: &zip)
            appendUInt16LE(0, to: &zip)
            zip.append(pathData)
            zip.append(entry.data)

            centralRecords.append(
                CentralRecord(
                    pathData: pathData,
                    crc32: crc,
                    size: size,
                    localHeaderOffset: localHeaderOffset,
                    dosTime: dosTime,
                    dosDate: dosDate
                )
            )
        }

        let centralDirectoryOffset = UInt32(zip.count)
        for record in centralRecords {
            appendUInt32LE(0x02014B50, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(record.dosTime, to: &zip)
            appendUInt16LE(record.dosDate, to: &zip)
            appendUInt32LE(record.crc32, to: &zip)
            appendUInt32LE(record.size, to: &zip)
            appendUInt32LE(record.size, to: &zip)
            appendUInt16LE(UInt16(record.pathData.count), to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt32LE(0, to: &zip)
            appendUInt32LE(record.localHeaderOffset, to: &zip)
            zip.append(record.pathData)
        }

        let centralDirectorySize = UInt32(zip.count) - centralDirectoryOffset
        let count = UInt16(centralRecords.count)
        appendUInt32LE(0x06054B50, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(count, to: &zip)
        appendUInt16LE(count, to: &zip)
        appendUInt32LE(centralDirectorySize, to: &zip)
        appendUInt32LE(centralDirectoryOffset, to: &zip)
        appendUInt16LE(0, to: &zip)
        return zip
    }

    private func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents(in: TimeZone.current, from: date)
        let year = min(max(comps.year ?? 1980, 1980), 2107)
        let month = min(max(comps.month ?? 1, 1), 12)
        let day = min(max(comps.day ?? 1, 1), 31)
        let hour = min(max(comps.hour ?? 0, 0), 23)
        let minute = min(max(comps.minute ?? 0, 0), 59)
        let second = min(max(comps.second ?? 0, 0), 59)

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    private func listPendingExportZipEntryPaths(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data)
        let eocdSignature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard let eocdIndex = bytes.lastIndex(of: eocdSignature[0]).flatMap({ idx -> Int? in
            var i = idx
            while i >= 0 {
                if i + 3 < bytes.count && bytes[i...i+3].elementsEqual(eocdSignature) { return i }
                if i == 0 { break }
                i -= 1
            }
            return nil
        }) else {
            throw NSError(domain: "ScoutCapture.PendingExport", code: 8, userInfo: [NSLocalizedDescriptionKey: "EOCD not found."])
        }

        func u16(_ offset: Int) -> Int {
            Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) |
            (Int(bytes[offset + 1]) << 8) |
            (Int(bytes[offset + 2]) << 16) |
            (Int(bytes[offset + 3]) << 24)
        }

        guard eocdIndex + 22 <= bytes.count else {
            throw NSError(domain: "ScoutCapture.PendingExport", code: 9, userInfo: [NSLocalizedDescriptionKey: "EOCD truncated."])
        }

        let totalEntries = u16(eocdIndex + 10)
        let centralOffset = u32(eocdIndex + 16)
        var cursor = centralOffset
        var paths: [String] = []
        paths.reserveCapacity(totalEntries)

        while paths.count < totalEntries, cursor + 46 <= bytes.count {
            guard cursor + 3 < bytes.count,
                  bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B, bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else {
                break
            }
            let nameLength = u16(cursor + 28)
            let extraLength = u16(cursor + 30)
            let commentLength = u16(cursor + 32)
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { break }
            let nameBytes = Array(bytes[nameStart..<nameEnd])
            let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
            paths.append(name)
            cursor = nameEnd + extraLength + commentLength
        }

        return paths
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func requestDeleteProperty(_ property: Property) {
        propertyToDelete = property
    }
    
    @ViewBuilder
    private func customCapsuleToolbarButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 42)
                .padding(.horizontal, 14)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .tint(.clear)
        .disabled(!isEnabled)
    }
}

private struct HubSessionDocumentExportPicker: UIViewControllerRepresentable {
    let fileURL: URL
    let onComplete: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.modalPresentationStyle = .formSheet
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Bool) -> Void

        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onComplete(!urls.isEmpty)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(false)
        }
    }
}

private struct HubAddPropertySheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var selectedOrganizationID: UUID? = nil
    @State private var showAddOrganizationPrompt: Bool = false
    @State private var newOrganizationName: String = ""
    @State private var propertyCreationErrorMessage: String? = nil
    @State private var showPropertyCreationError: Bool = false
    @State private var isSavingProperty: Bool = false
    @State private var clientName: String = ""
    @State private var clientPhone: String = ""
    @State private var clientEmail: String = ""
    @State private var showContactPicker: Bool = false
    @State private var propertyName: String = ""
    @State private var streetAddress: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    @State private var normalizedAddress: String = ""
    @StateObject private var propertyNameAutocomplete = AddressAutocompleteModel(resultTypes: [.pointOfInterest, .address])
    @StateObject private var addressAutocomplete = AddressAutocompleteModel(resultTypes: .address)
    @FocusState private var focusedField: Field?
    @State private var hasAppliedInitialFocus: Bool = false
    private let addOrganizationToken = "__add_new_organization__"

    private enum Field: Int, CaseIterable {
        case clientName
        case clientPhone
        case clientEmail
        case propertyName
        case streetAddress
        case city
        case state
        case zipCode
    }
    
    private var canSave: Bool {
        !isSavingProperty &&
        !propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPropertyNameResults: Bool {
        focusedField == .propertyName &&
        !propertyNameAutocomplete.completions.isEmpty &&
        !propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasAddressResults: Bool {
        focusedField == .streetAddress &&
        !addressAutocomplete.completions.isEmpty &&
        !streetAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }
    
    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }
    
    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    private var primaryButtonFill: Color { .blue }
    private var primaryButtonStroke: Color { .blue.opacity(0.85) }
    private var primaryButtonLabel: Color { .white }

    private var selectedOrganizationContacts: [OrganizationContact] {
        appState.organizationContacts(for: selectedOrganizationID)
    }

    private var selectedOrganizationName: String {
        appState.organizationSelectionOptions.first(where: { $0.id == selectedOrganizationID })?.name ?? "Organization"
    }

    private var resolvedDefaultOrganizationID: UUID? {
        let options = appState.organizationSelectionOptions
        if let activeOrganizationID = appState.activeOrganizationID,
           options.contains(where: { $0.id == activeOrganizationID }) {
            return activeOrganizationID
        }
        return options.first?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Cancel", isEnabled: true) {
                    dismiss()
                }

                Spacer(minLength: 0)

                Text("Add Property")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(buttonLabel)

                Spacer(minLength: 0)

                customCapsuleButton(
                    title: "Save",
                    isEnabled: canSave,
                    fill: primaryButtonFill,
                    stroke: primaryButtonStroke,
                    label: primaryButtonLabel
                ) {
                    submitProperty()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            ScrollViewReader { proxy in
                Form {
                    Section("Organization") {
                        Picker("Organization", selection: organizationSelectionToken) {
                            ForEach(appState.organizationSelectionOptions) { organization in
                                Text(organization.name)
                                    .tag(organization.id.uuidString)
                            }
                            if !appState.requiresAuthentication {
                                Text("Add new organization")
                                    .tag(addOrganizationToken)
                            }
                        }
                    }

                    Section("Primary Contact") {
                        HStack(spacing: 12) {
                            TextField("Primary Contact Name", text: $clientName)
                                .textInputAutocapitalization(.words)
                                .focused($focusedField, equals: .clientName)
                                .submitLabel(.next)
                                .onSubmit {
                                    focusedField = .clientPhone
                                }
                                .id(Field.clientName)

                            Button {
                                showContactPicker = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Choose saved contact")
                        }

                        TextField("Phone (optional)", text: $clientPhone)
                            .focused($focusedField, equals: .clientPhone)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .clientEmail
                            }
                            .keyboardType(.phonePad)
                            .id(Field.clientPhone)
                            .onChange(of: clientPhone) { _, newValue in
                                let digits = newValue.filter(\.isNumber)
                                let limited = String(digits.prefix(15))
                                let formatted = formatContactPhoneDisplay(limited)
                                if formatted != clientPhone {
                                    clientPhone = formatted
                                }
                            }

                        TextField("Email (optional)", text: $clientEmail)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.emailAddress)
                            .focused($focusedField, equals: .clientEmail)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .propertyName
                            }
                            .id(Field.clientEmail)
                    }

                    Section("Property") {
                        TextField("Property name", text: $propertyName)
                            .focused($focusedField, equals: .propertyName)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .streetAddress
                            }
                            .onChange(of: propertyName) { _, newValue in
                                propertyNameAutocomplete.update(query: newValue)
                            }
                            .id(Field.propertyName)
                        if hasPropertyNameResults {
                            ForEach(propertyNameAutocomplete.completions, id: \.id) { completion in
                                autocompleteRow(completion) {
                                    selectPropertyNameCompletion(completion)
                                }
                            }
                        }
                        TextField("Address", text: $streetAddress)
                            .focused($focusedField, equals: .streetAddress)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .city
                            }
                            .onChange(of: streetAddress) { _, newValue in
                                addressAutocomplete.update(query: newValue)
                                syncNormalizedAddress()
                            }
                            .id(Field.streetAddress)
                        if hasAddressResults {
                            ForEach(addressAutocomplete.completions, id: \.id) { completion in
                                autocompleteRow(completion) {
                                    selectAddressCompletion(completion)
                                }
                            }
                        }
                        TextField("City", text: $city)
                            .focused($focusedField, equals: .city)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .state
                            }
                            .onChange(of: city) { _, _ in
                                syncNormalizedAddress()
                            }
                            .id(Field.city)
                        TextField("State", text: $state)
                            .focused($focusedField, equals: .state)
                            .submitLabel(.next)
                            .onSubmit {
                                focusedField = .zipCode
                            }
                            .textInputAutocapitalization(.characters)
                            .id(Field.state)
                            .onChange(of: state) { _, newValue in
                                let filtered = newValue.uppercased().filter(\.isLetter)
                                let limited = String(filtered.prefix(2))
                                if limited != state {
                                    state = limited
                                }
                                syncNormalizedAddress()
                            }
                        TextField("Zip Code", text: $zipCode)
                            .focused($focusedField, equals: .zipCode)
                            .submitLabel(.go)
                            .keyboardType(.numberPad)
                            .id(Field.zipCode)
                            .onSubmit {
                                if canSave {
                                    submitProperty()
                                } else {
                                    focusFirstInvalidField()
                                }
                            }
                            .onChange(of: zipCode) { _, newValue in
                                let filtered = newValue.filter(\.isNumber)
                                let limited = String(filtered.prefix(5))
                                if limited != zipCode {
                                    zipCode = limited
                                }
                                syncNormalizedAddress()
                            }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color(uiColor: .systemBackground))
                .onChange(of: focusedField) { _, newValue in
                    guard let newValue else { return }
                    scrollToField(newValue, with: proxy)
                }
                .onChange(of: propertyNameAutocomplete.completions.count) { _, newValue in
                    guard focusedField == .propertyName, newValue > 0 else { return }
                    scrollToField(.propertyName, with: proxy)
                }
                .onChange(of: addressAutocomplete.completions.count) { _, newValue in
                    guard focusedField == .streetAddress, newValue > 0 else { return }
                    scrollToField(.streetAddress, with: proxy)
                }
            }
        }
        .onAppear {
            syncSelectedOrganizationIfNeeded()
            applyInitialClientFocusIfNeeded()
        }
        .onChange(of: appState.organizations) { _, _ in
            syncSelectedOrganizationIfNeeded()
        }
        .onChange(of: appState.activeOrganizationID) { _, _ in
            syncSelectedOrganizationIfNeeded()
        }
        .onChange(of: appState.organizationSelectionOptions.map(\.id)) { _, _ in
            syncSelectedOrganizationIfNeeded()
        }
        .alert("Add Organization", isPresented: $showAddOrganizationPrompt) {
            TextField("Organization Name", text: $newOrganizationName)
            Button("Save") {
                saveOrganization()
            }
            Button("Cancel", role: .cancel) {
                syncSelectedOrganizationIfNeeded()
            }
        } message: {
            Text("Enter the organization name.")
        }
        .alert("Unable to Save Property", isPresented: $showPropertyCreationError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(propertyCreationErrorMessage ?? "The property could not be saved.")
        }
        .sheet(isPresented: $showContactPicker) {
            OrganizationContactPickerSheet(
                organizationID: selectedOrganizationID,
                organizationName: selectedOrganizationName,
                contacts: selectedOrganizationContacts
            ) { contact in
                apply(contact: contact)
            }
        }
    }

    private var organizationSelectionToken: Binding<String> {
        Binding(
            get: { selectedOrganizationID?.uuidString ?? "" },
            set: { newValue in
                if newValue == addOrganizationToken {
                    showAddOrganizationPrompt = true
                    return
                }
                selectedOrganizationID = UUID(uuidString: newValue)
            }
        )
    }

    private var formattedAddress: String {
        let street = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let locality = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let postal = zipCode.trimmingCharacters(in: .whitespacesAndNewlines)

        let regionPostal = [region, postal]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [street, locality, regionPostal]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var addressForStorage: String {
        let normalized = normalizedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? formattedAddress : normalized
    }

    private var orderedFields: [Field] {
        Field.allCases
    }

    private var previousField: Field? {
        guard let focusedField else { return nil }
        guard let index = orderedFields.firstIndex(of: focusedField), index > 0 else { return nil }
        return orderedFields[index - 1]
    }

    private var nextField: Field? {
        guard let focusedField else { return orderedFields.first }
        guard let index = orderedFields.firstIndex(of: focusedField), index < orderedFields.count - 1 else { return nil }
        return orderedFields[index + 1]
    }

    private func moveFocusToPreviousField() {
        focusedField = previousField
    }

    private func moveFocusToNextField() {
        focusedField = nextField
    }

    private func applyInitialClientFocusIfNeeded() {
        guard !hasAppliedInitialFocus else { return }
        hasAppliedInitialFocus = true

        focusedField = .clientName

        // Modal and pushed presentations can race first responder assignment.
        // Re-apply once after presentation settles so keyboard appears consistently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if focusedField == nil {
                focusedField = .clientName
            }
        }
    }

    private func focusFirstInvalidField() {
        if propertyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            focusedField = .propertyName
            return
        }
        focusedField = .streetAddress
    }

    private func submitProperty() {
        guard !isSavingProperty else { return }
        guard canSave else {
            focusFirstInvalidField()
            return
        }
        guard let organizationID = selectedOrganizationID else {
            propertyCreationErrorMessage = "Select an organization."
            showPropertyCreationError = true
            return
        }

        isSavingProperty = true
        Task { @MainActor in
            defer { isSavingProperty = false }
            do {
                let created = try await appState.createPropertyRemoteAware(
                    organizationID: organizationID,
                    clientName: clientName,
                    propertyName: propertyName,
                    address: addressForStorage,
                    street: streetAddress,
                    city: city,
                    state: state,
                    zip: zipCode,
                    clientPhone: clientPhone,
                    clientEmail: clientEmail
                )
                appState.selectProperty(id: created.id)
                dismiss()
            } catch {
                propertyCreationErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                showPropertyCreationError = true
            }
        }
    }

    private func syncSelectedOrganizationIfNeeded() {
        if let selectedOrganizationID,
           appState.organizationSelectionOptions.contains(where: { $0.id == selectedOrganizationID }) {
            return
        }
        selectedOrganizationID = resolvedDefaultOrganizationID
    }

    private func saveOrganization() {
        let trimmedName = newOrganizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            syncSelectedOrganizationIfNeeded()
            return
        }
        if let organization = appState.createOrganization(name: trimmedName) {
            selectedOrganizationID = organization.id
        } else {
            syncSelectedOrganizationIfNeeded()
        }
        newOrganizationName = ""
    }

    private func apply(contact: OrganizationContact) {
        clientName = contact.name
        clientPhone = contact.phone ?? ""
        clientEmail = contact.email ?? ""
        focusedField = .propertyName
    }

    @ViewBuilder
    private func autocompleteRow(
        _ completion: AddressAutocompleteModel.CompletionItem,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(completion.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !completion.subtitle.isEmpty {
                    Text(completion.subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }

    private func selectPropertyNameCompletion(_ completion: AddressAutocompleteModel.CompletionItem) {
        Task { @MainActor in
            propertyName = completion.title.trimmingCharacters(in: .whitespacesAndNewlines)
            propertyNameAutocomplete.clearResults()
            if let components = await propertyNameAutocomplete.resolve(completion: completion) {
                streetAddress = components.street
                city = components.city
                state = components.state
                zipCode = components.zip
                normalizedAddress = components.normalized
                addressAutocomplete.clearResults()
            }
            focusedField = nil
        }
    }

    private func selectAddressCompletion(_ completion: AddressAutocompleteModel.CompletionItem) {
        Task { @MainActor in
            guard let components = await addressAutocomplete.resolve(completion: completion) else { return }
            streetAddress = components.street
            city = components.city
            state = components.state
            zipCode = components.zip
            normalizedAddress = components.normalized
            addressAutocomplete.clearResults()
            focusedField = nil
        }
    }

    private func syncNormalizedAddress() {
        let normalized = normalizedAddressString(
            street: streetAddress,
            city: city,
            state: state,
            zip: zipCode
        )
        normalizedAddress = normalized
    }

    private func normalizedAddressString(street: String, city: String, state: String, zip: String) -> String {
        let trimmedStreet = street.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedState = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedZip = zip.trimmingCharacters(in: .whitespacesAndNewlines)

        let stateZip = [trimmedState, trimmedZip]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [trimmedStreet, trimmedCity, stateZip]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private func scrollToField(_ field: Field, with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(field, anchor: .center)
            }
        }
    }
    
    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 42)
                .padding(.horizontal, 14)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct EditContactSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let property: Property

    @State private var selectedOrganizationID: UUID? = nil
    @State private var showAddOrganizationPrompt: Bool = false
    @State private var newOrganizationName: String = ""
    @State private var propertyName: String = ""
    @State private var clientName: String = ""
    @State private var clientEmail: String = ""
    @State private var streetAddress: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    @State private var phoneInput: String = ""
    @State private var showContactPicker: Bool = false
    @State private var showPendingExportRenameConfirm: Bool = false
    private let addOrganizationToken = "__add_new_organization__"

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }

    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }

    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    private var primaryButtonFill: Color { .blue }
    private var primaryButtonStroke: Color { .blue.opacity(0.85) }
    private var primaryButtonLabel: Color { .white }

    private var selectedOrganizationContacts: [OrganizationContact] {
        appState.organizationContacts(for: selectedOrganizationID)
    }

    private var selectedOrganizationName: String {
        appState.organizationSelectionOptions.first(where: { $0.id == selectedOrganizationID })?.name ?? "Organization"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Cancel", isEnabled: true) {
                    dismiss()
                }

                Spacer(minLength: 0)

                Text("Edit Property")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(buttonLabel)

                Spacer(minLength: 0)

                customCapsuleButton(
                    title: "Save",
                    isEnabled: true,
                    fill: primaryButtonFill,
                    stroke: primaryButtonStroke,
                    label: primaryButtonLabel
                ) {
                    saveChanges()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            Form {
                Section("Organization") {
                    Picker("Organization", selection: organizationSelectionToken) {
                        ForEach(appState.organizationSelectionOptions) { organization in
                            Text(organization.name)
                                .tag(organization.id.uuidString)
                        }
                        if !appState.requiresAuthentication {
                            Text("Add new organization")
                                .tag(addOrganizationToken)
                        }
                    }
                }

                Section("Primary Contact") {
                    HStack(spacing: 12) {
                        TextField("Primary Contact Name", text: $clientName)
                            .textInputAutocapitalization(.words)

                        Button {
                            showContactPicker = true
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Choose saved contact")
                    }

                    TextField("Phone (optional)", text: $phoneInput)
                        .keyboardType(.phonePad)
                        .onChange(of: phoneInput) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            let limited = String(digits.prefix(15))
                            let formatted = formatPhoneDisplay(limited)
                            if formatted != phoneInput {
                                phoneInput = formatted
                            }
                        }

                    TextField("Email (optional)", text: $clientEmail)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }

                Section("Property") {
                    TextField("Property name", text: $propertyName)
                        .textInputAutocapitalization(.words)

                    TextField("Address", text: $streetAddress)
                        .textInputAutocapitalization(.words)

                    TextField("City", text: $city)
                        .textInputAutocapitalization(.words)

                    TextField("State", text: $state)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: state) { _, newValue in
                            let filtered = newValue.uppercased().filter(\.isLetter)
                            let limited = String(filtered.prefix(2))
                            if limited != state {
                                state = limited
                            }
                        }

                    TextField("Zip Code", text: $zipCode)
                        .keyboardType(.numberPad)
                        .onChange(of: zipCode) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            let limited = String(filtered.prefix(5))
                            if limited != zipCode {
                                zipCode = limited
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemBackground))
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            loadFromProperty()
        }
        .onChange(of: appState.organizations) { _, _ in
            syncSelectedOrganizationIfNeeded()
        }
        .alert("Add Organization", isPresented: $showAddOrganizationPrompt) {
            TextField("Organization Name", text: $newOrganizationName)
            Button("Save") {
                saveOrganization()
            }
            Button("Cancel", role: .cancel) {
                syncSelectedOrganizationIfNeeded()
            }
        } message: {
            Text("Enter the organization name.")
        }
        .alert("Rename Pending Export Property?", isPresented: $showPendingExportRenameConfirm) {
            Button("Continue") {
                persistChanges()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This property has pending exports. Export filenames will use the updated property name.")
        }
        .sheet(isPresented: $showContactPicker) {
            OrganizationContactPickerSheet(
                organizationID: selectedOrganizationID,
                organizationName: selectedOrganizationName,
                contacts: selectedOrganizationContacts
            ) { contact in
                apply(contact: contact)
            }
        }
    }

    private var composedAddress: String {
        let trimmedStreet = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedState = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let trimmedZip = zipCode.trimmingCharacters(in: .whitespacesAndNewlines)

        let stateZip = [trimmedState, trimmedZip]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        return [trimmedStreet, trimmedCity, stateZip]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var organizationSelectionToken: Binding<String> {
        Binding(
            get: {
                selectedOrganizationID?.uuidString
                    ?? property.orgId?.uuidString
                    ?? appState.organizationSelectionOptions.first?.id.uuidString
                    ?? ""
            },
            set: { newValue in
                if newValue == addOrganizationToken {
                    showAddOrganizationPrompt = true
                    return
                }
                selectedOrganizationID = UUID(uuidString: newValue)
            }
        )
    }

    private func saveChanges() {
        if shouldConfirmPendingExportRename() {
            showPendingExportRenameConfirm = true
            return
        }
        persistChanges()
    }

    private func persistChanges() {
        let digits = phoneInput.filter(\.isNumber)
        _ = appState.updatePropertyContact(
            id: property.id,
            organizationID: selectedOrganizationID,
            propertyName: propertyName,
            clientName: clientName,
            address: composedAddress,
            street: streetAddress,
            city: city,
            state: state,
            zip: zipCode,
            clientPhone: digits,
            clientEmail: clientEmail
        )
        dismiss()
    }

    private func shouldConfirmPendingExportRename() -> Bool {
        let trimmedOriginal = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUpdated = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUpdated.isEmpty, trimmedUpdated != trimmedOriginal else { return false }
        return appState.sessions(for: property.id).contains(where: { appState.isPendingDeliveryLocallyAvailable($0) })
    }

    private func loadFromProperty() {
        syncSelectedOrganizationIfNeeded()
        selectedOrganizationID = property.orgId ?? appState.activeOrganizationID ?? appState.organizationSelectionOptions.first?.id
        propertyName = property.name
        clientName = property.clientName ?? ""
        clientEmail = property.clientEmail ?? ""
        if property.street != nil || property.city != nil || property.state != nil || property.zip != nil {
            streetAddress = property.street ?? ""
            city = property.city ?? ""
            state = property.state ?? ""
            zipCode = property.zip ?? ""
        } else {
            let parsed = parseAddress(property.address)
            streetAddress = parsed.street
            city = parsed.city
            state = parsed.state
            zipCode = parsed.zip
        }
        phoneInput = formatPhoneDisplay((property.clientPhone ?? "").filter(\.isNumber))
    }

    private func syncSelectedOrganizationIfNeeded() {
        if let selectedOrganizationID,
           appState.organizationSelectionOptions.contains(where: { $0.id == selectedOrganizationID }) {
            return
        }
        selectedOrganizationID = property.orgId ?? appState.activeOrganizationID ?? appState.organizationSelectionOptions.first?.id
    }

    private func saveOrganization() {
        let trimmedName = newOrganizationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            syncSelectedOrganizationIfNeeded()
            return
        }
        if let organization = appState.createOrganization(name: trimmedName) {
            selectedOrganizationID = organization.id
        } else {
            syncSelectedOrganizationIfNeeded()
        }
        newOrganizationName = ""
    }

    private func apply(contact: OrganizationContact) {
        clientName = contact.name
        phoneInput = formatPhoneDisplay(contact.phone ?? "")
        clientEmail = contact.email ?? ""
    }

    private func parseAddress(_ raw: String?) -> (street: String, city: String, state: String, zip: String) {
        let cleaned = (raw ?? "")
            .replacingOccurrences(of: ", United States", with: "", options: [.caseInsensitive, .anchored, .backwards], range: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return ("", "", "", "") }

        let parts = cleaned
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        let street = parts.first ?? ""
        let city = parts.count > 1 ? parts[1] : ""
        let stateZip = parts.count > 2 ? parts[2] : ""
        let tokens = stateZip.split(separator: " ").map(String.init)
        let state = tokens.first.map { String($0.uppercased().prefix(2)) } ?? ""
        let zip = tokens.dropFirst().joined(separator: "").filter(\.isNumber)
        return (street, city, state, String(zip.prefix(5)))
    }

    private func formatPhoneDisplay(_ digits: String) -> String {
        if digits.count <= 3 { return digits }
        if digits.count <= 6 {
            let area = digits.prefix(3)
            let rest = digits.dropFirst(3)
            return "(\(area)) \(rest)"
        }
        if digits.count <= 10 {
            let area = digits.prefix(3)
            let mid = digits.dropFirst(3).prefix(3)
            let end = digits.dropFirst(6)
            return "(\(area)) \(mid)-\(end)"
        }
        return digits
    }

    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 42)
                .padding(.horizontal, 14)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct DebugLocalOrgRepairView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    private let localStore = LocalStore()

    @State private var candidates: [Property] = []
    @State private var selectedPropertyIDs: Set<UUID> = []
    @State private var isLoading: Bool = true
    @State private var isSaving: Bool = false
    @State private var statusMessage: String? = nil
    @State private var errorMessage: String? = nil
    @State private var showError: Bool = false

    private var activeOrganizationID: UUID? {
        appState.activeOrganizationID
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading mismatched local properties...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let activeOrganizationID {
                    List {
                        Section {
                            Text("Active org: \(activeOrganizationID.uuidString)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                            if let statusMessage {
                                Text(statusMessage)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        }

                        if candidates.isEmpty {
                            Section {
                                Text("No mismatched local properties found.")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Section("Mismatched Local Properties") {
                                ForEach(candidates) { property in
                                    Button {
                                        toggleSelection(for: property.id)
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Image(systemName: selectedPropertyIDs.contains(property.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(selectedPropertyIDs.contains(property.id) ? .green : .secondary)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(property.name)
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundColor(.primary)
                                                if let folderID = property.folderId, !folderID.isEmpty {
                                                    Text("Folder: \(folderID)")
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(.secondary)
                                                }
                                                if let address = property.address,
                                                   !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                    Text(address)
                                                        .font(.system(size: 13, weight: .medium))
                                                        .foregroundColor(.secondary)
                                                }
                                                Text("Current orgId: \(property.orgId?.uuidString ?? "nil")")
                                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                                    .foregroundColor(.secondary)
                                            }
                                            Spacer(minLength: 0)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    VStack(spacing: 12) {
                        Text("No active organization selected.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("Select an active organization before using local org repair.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                }
            }
            .navigationTitle("Local Org Repair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSaving ? "Saving..." : "Apply") {
                        applySelectedRepairs()
                    }
                    .disabled(
                        isSaving ||
                        activeOrganizationID == nil ||
                        selectedPropertyIDs.isEmpty
                    )
                }
            }
        }
        .task {
            loadCandidates()
        }
        .alert("Local Org Repair Failed", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Unable to repair local property organization assignments.")
        }
    }

    private func loadCandidates() {
        isLoading = true
        selectedPropertyIDs = []
        statusMessage = nil

        guard let activeOrganizationID else {
            candidates = []
            isLoading = false
            return
        }

        let allProperties = (try? localStore.fetchProperties()) ?? []
        candidates = allProperties
            .filter { $0.orgId != activeOrganizationID }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        isLoading = false
    }

    private func toggleSelection(for propertyID: UUID) {
        if selectedPropertyIDs.contains(propertyID) {
            selectedPropertyIDs.remove(propertyID)
        } else {
            selectedPropertyIDs.insert(propertyID)
        }
    }

    private func applySelectedRepairs() {
        guard let activeOrganizationID else { return }
        guard !selectedPropertyIDs.isEmpty else { return }

        isSaving = true
        statusMessage = nil
        errorMessage = nil
        showError = false

        do {
            try ensureActiveOrganizationExistsLocally(activeOrganizationID: activeOrganizationID)
            let selectedProperties = candidates.filter { selectedPropertyIDs.contains($0.id) }
            for property in selectedProperties {
                var updated = property
                updated.orgId = activeOrganizationID
                _ = try localStore.updateProperty(updated)
            }

            appState.refreshProperties()
            let repairedCount = selectedProperties.count
            statusMessage = repairedCount == 1
                ? "Reassigned 1 local property to the active organization."
                : "Reassigned \(repairedCount) local properties to the active organization."
            loadCandidates()
            isSaving = false
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    private func ensureActiveOrganizationExistsLocally(activeOrganizationID: UUID) throws {
        let localOrganizations = (try? localStore.fetchOrganizations()) ?? []
        if localOrganizations.contains(where: { $0.id == activeOrganizationID }) {
            return
        }

        let organizationName =
            appState.organizationSelectionOptions.first(where: { $0.id == activeOrganizationID })?.name
            ?? appState.organizations.first(where: { $0.id == activeOrganizationID })?.name
            ?? "Organization \(activeOrganizationID.uuidString)"

        _ = try localStore.createOrganization(
            Organization(
                id: activeOrganizationID,
                name: organizationName,
                contacts: []
            )
        )
    }
}

private struct OrganizationContactPickerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let organizationID: UUID?
    let organizationName: String
    let contacts: [OrganizationContact]
    let onSelect: (OrganizationContact) -> Void

    @State private var contactToEdit: OrganizationContact? = nil

    private var canManageContacts: Bool {
        organizationID != nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if contacts.isEmpty {
                    ContentUnavailableView(
                        "No Saved Contacts",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Saved contacts for \(organizationName) will appear here after you use them on a property.")
                    )
                } else {
                    List(contacts) { contact in
                        Button {
                            onSelect(contact)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(contact.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.primary)

                                if let phone = contact.phone, !phone.isEmpty {
                                    Text(formatContactPhoneDisplay(phone))
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }

                                if let email = contact.email, !email.isEmpty {
                                    Text(email)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if canManageContacts {
                                Button(role: .destructive) {
                                    delete(contact: contact)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    contactToEdit = contact
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle(organizationName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .sheet(item: $contactToEdit) { contact in
            EditOrganizationContactSheet(contact: contact) { updated in
                save(contact: updated)
            }
        }
    }

    private func save(contact: OrganizationContact) {
        guard let organizationID else { return }
        _ = appState.updateOrganizationContact(organizationID: organizationID, contact: contact)
    }

    private func delete(contact: OrganizationContact) {
        guard let organizationID else { return }
        _ = appState.deleteOrganizationContact(organizationID: organizationID, contactID: contact.id)
    }
}

private struct EditOrganizationContactSheet: View {
    @Environment(\.dismiss) private var dismiss

    let contact: OrganizationContact
    let onSave: (OrganizationContact) -> Void

    @State private var name: String
    @State private var phone: String
    @State private var email: String

    init(contact: OrganizationContact, onSave: @escaping (OrganizationContact) -> Void) {
        self.contact = contact
        self.onSave = onSave
        _name = State(initialValue: contact.name)
        _phone = State(initialValue: formatContactPhoneDisplay(contact.phone ?? ""))
        _email = State(initialValue: contact.email ?? "")
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Contact") {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)

                    TextField("Phone (optional)", text: $phone)
                        .keyboardType(.phonePad)
                        .onChange(of: phone) { _, newValue in
                            let digits = newValue.filter(\.isNumber)
                            let limited = String(digits.prefix(15))
                            let formatted = formatContactPhoneDisplay(limited)
                            if formatted != phone {
                                phone = formatted
                            }
                        }

                    TextField("Email (optional)", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                }
            }
            .navigationTitle("Edit Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(OrganizationContact(
                            id: contact.id,
                            name: name,
                            phone: phone.filter(\.isNumber),
                            email: email
                        ))
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

private func formatContactPhoneDisplay(_ digits: String) -> String {
    let digitsOnly = digits.filter(\.isNumber)
    if digitsOnly.count <= 3 { return digitsOnly }
    if digitsOnly.count <= 6 {
        let area = digitsOnly.prefix(3)
        let rest = digitsOnly.dropFirst(3)
        return "(\(area)) \(rest)"
    }
    if digitsOnly.count <= 10 {
        let area = digitsOnly.prefix(3)
        let mid = digitsOnly.dropFirst(3).prefix(3)
        let end = digitsOnly.dropFirst(6)
        return "(\(area)) \(mid)-\(end)"
    }
    return digitsOnly
}

@MainActor
private final class AddressAutocompleteModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    struct CompletionItem {
        let id: String
        let title: String
        let subtitle: String
        let completion: MKLocalSearchCompletion
    }

    @Published private(set) var completions: [CompletionItem] = []
    private let completer: MKLocalSearchCompleter
    private static var warmupRetainer: [AddressAutocompleteModel] = []

    init(resultTypes: MKLocalSearchCompleter.ResultType) {
        let completer = MKLocalSearchCompleter()
        completer.resultTypes = resultTypes
        self.completer = completer
        super.init()
        self.completer.delegate = self
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            completions = []
            completer.queryFragment = ""
            return
        }
        completer.queryFragment = trimmed
    }

    func clearResults() {
        completions = []
    }

    func resolve(completion: CompletionItem) async -> AddressAutocompleteComponents? {
        let request = MKLocalSearch.Request(completion: completion.completion)
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let mapItem = response.mapItems.first else { return nil }
            return AddressAutocompleteComponents(mapItem: mapItem)
        } catch {
            return nil
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        completions = completer.results.map { result in
            CompletionItem(
                id: "\(result.title)|\(result.subtitle)",
                title: result.title,
                subtitle: result.subtitle,
                completion: result
            )
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        completions = []
    }

    static func prewarm() {
        guard warmupRetainer.isEmpty else { return }
        let propertyName = AddressAutocompleteModel(resultTypes: [.pointOfInterest, .address])
        let address = AddressAutocompleteModel(resultTypes: .address)
        propertyName.update(query: "")
        address.update(query: "")
        warmupRetainer = [propertyName, address]
    }
}

private enum AddPropertyWarmup {
    private static var didPrewarm = false

    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        DispatchQueue.main.async {
            AddressAutocompleteModel.prewarm()
        }
    }
}

private enum OptionalDetailNoteWarmup {
    private static var didPrewarm = false

    static func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        // Detail note sheet does not require heavy setup today.
        // Keep this as a no-op hook so it never blocks launch.
    }
}

private struct AddressAutocompleteComponents {
    let street: String
    let city: String
    let state: String
    let zip: String
    let normalized: String

    init(mapItem: MKMapItem) {
        let fullAddress = mapItem.address?.fullAddress.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortAddress = mapItem.address?.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawAddress = fullAddress.isEmpty ? shortAddress : fullAddress

        let lines = rawAddress
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let fallbackParts = rawAddress
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let streetCandidate = Self.extractStreet(from: rawAddress, lines: lines, fallbackParts: fallbackParts, mapItemName: mapItem.name)
        street = streetCandidate

        let contextLine = lines.dropFirst().first
            ?? mapItem.addressRepresentations?.cityWithContext
            ?? (fallbackParts.count > 1 ? fallbackParts[1] : "")
        let parsedCityState = Self.parseCityState(from: contextLine)
        let cityFromLine = parsedCityState.city.isEmpty && fallbackParts.count > 1 ? fallbackParts[1] : parsedCityState.city
        let stateFromLine = parsedCityState.state
        city = cityFromLine

        state = String(stateFromLine.uppercased().filter(\.isLetter).prefix(2))
        let postalCodeHint: String? = nil
        let extractedZip = Self.extractZip(from: rawAddress, postalCodeHint: postalCodeHint)
        zip = String(extractedZip.filter(\.isNumber).prefix(5))

        let stateZip = [state, zip]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        normalized = [street, city, stateZip]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private static func parseCityState(from text: String) -> (city: String, state: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("", "") }

        let parts = trimmed.split(separator: ",", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let city = parts.first ?? ""
        let rhs = parts.count > 1 ? parts[1] : ""
        let state = rhs
            .split(separator: " ")
            .map(String.init)
            .first(where: { $0.count == 2 && $0.allSatisfy(\.isLetter) }) ?? ""
        return (city, state)
    }

    private static func extractStreet(
        from rawAddress: String,
        lines: [String],
        fallbackParts: [String],
        mapItemName: String?
    ) -> String {
        let singleLine = lines.first ?? fallbackParts.first ?? rawAddress
        let trimmed = singleLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return completionSafeText(mapItemName)
        }

        if let firstComma = trimmed.firstIndex(of: ",") {
            let candidate = String(trimmed[..<firstComma]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty {
                return candidate
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"^(.+?),\s*[^,]+,\s*[A-Z]{2}\s+\d{5}(?:-\d{4})?(?:,\s*.*)?$"#) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: range),
               match.numberOfRanges > 1,
               let streetRange = Range(match.range(at: 1), in: trimmed) {
                return String(trimmed[streetRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return trimmed
    }

    private static func extractZip(from text: String, postalCodeHint: String?) -> String {
        let hinted = (postalCodeHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !hinted.isEmpty {
            return hinted
        }

        if let stateZipRegex = try? NSRegularExpression(pattern: #"\b[A-Z]{2}\s+(\d{5}(?:-\d{4})?)\b"#) {
            let uppercaseText = text.uppercased()
            let range = NSRange(uppercaseText.startIndex..<uppercaseText.endIndex, in: uppercaseText)
            if let match = stateZipRegex.firstMatch(in: uppercaseText, options: [], range: range),
               match.numberOfRanges > 1,
               let zipRange = Range(match.range(at: 1), in: uppercaseText) {
                return String(uppercaseText[zipRange])
            }
        }

        guard let regex = try? NSRegularExpression(pattern: #"\b\d{5}(?:-\d{4})?\b"#) else {
            return ""
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard let match = matches.last,
              let zipRange = Range(match.range, in: text) else {
            return ""
        }
        return String(text[zipRange])
    }

    private static func completionSafeText(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct PropertySessionsManagerView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let property: Property

    @State private var sessions: [Session] = []
    @State private var deleteTarget: Session? = nil
    @State private var showPendingExportWarning: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var isDeletingSession: Bool = false
    @State private var showDeleteError: Bool = false
    @State private var deleteErrorMessage: String? = nil

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }

    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }

    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    private var destructiveFill: Color { Color.red.opacity(0.86) }
    private var destructiveStroke: Color { Color.red.opacity(0.90) }
    private var destructiveLabel: Color { .white }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Done", isEnabled: true) {
                    dismiss()
                }

                Spacer(minLength: 0)

                VStack(spacing: 2) {
                    Text("Manage Sessions")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(buttonLabel)
                    Text(property.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(buttonLabel.opacity(0.72))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                customCapsuleButton(title: "Refresh", isEnabled: true) {
                    reloadSessions()
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            if sessions.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "tray",
                    description: Text("No sessions found for this property.")
                )
            } else {
                List(sessions) { session in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(session.status == .draft ? "Draft Session" : "Completed Session")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundColor(.primary)
                                if let cloudStatus = appState.sessionSnapshotCloudStatus(for: session) {
                                    sessionSnapshotCloudIcon(cloudStatus)
                                }
                            }
                            Text("Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            if appState.isPendingDeliveryLocallyAvailable(session) {
                                Text("Pending Export")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                        }

                        Spacer(minLength: 0)

                        customCapsuleButton(
                            title: isDeletingSession && deleteTarget?.id == session.id ? "Deleting..." : "Delete",
                            isEnabled: !isDeletingSession,
                            fill: destructiveFill,
                            stroke: destructiveStroke,
                            label: destructiveLabel
                        ) {
                            handleDeleteTap(session)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
        }
        .onAppear {
            reloadSessions()
        }
        .alert("Pending Export Session", isPresented: $showPendingExportWarning) {
            Button("Continue") {
                showDeleteConfirm = true
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This session is pending export. Deleting it moves the session to Recently Deleted for 30 days. Media, records, and export data are retained.")
        }
        .alert(deleteConfirmationTitle, isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                confirmDelete()
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text(deleteConfirmationMessage)
        }
        .alert("Delete Failed", isPresented: $showDeleteError) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "The session could not be deleted.")
        }
    }

    private var deleteConfirmationTitle: String {
        guard let target = deleteTarget else { return "Delete Session?" }
        if target.status == .draft {
            return "Delete Draft Session?"
        }
        return "Delete Completed Session?"
    }

    private var deleteConfirmationMessage: String {
        guard let target = deleteTarget else {
            return "This session will move to Recently Deleted for 30 days. Media and records are retained."
        }
        if target.status == .draft {
            return "This draft session will move to Recently Deleted for 30 days. Media and records are retained."
        }
        if appState.isPendingDelivery(target) {
            return "This session is pending export. It will move to Recently Deleted for 30 days. Media, records, and export data are retained."
        }
        return "This completed session will move to Recently Deleted for 30 days. Media and records are retained."
    }

    private func reloadSessions() {
        sessions = appState.sessions(for: property.id)
            .filter { appState.shouldDisplaySessionInSessionList($0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    @ViewBuilder
    private func sessionSnapshotCloudIcon(_ status: AppState.SessionSnapshotCloudStatus) -> some View {
        Image(systemName: status.symbolName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(sessionSnapshotCloudTint(status.tint))
            .accessibilityLabel(Text(status.accessibilityLabel))
            .help(status.helpText)
    }

    private func sessionSnapshotCloudTint(_ tint: AppState.SessionSnapshotCloudStatus.Tint) -> Color {
        switch tint {
        case .neutral:
            return .secondary
        case .blue:
            return .blue
        case .orange:
            return .orange
        case .red:
            return .red
        }
    }

    private func handleDeleteTap(_ session: Session) {
        deleteTarget = session
        if appState.isPendingDelivery(session) {
            showPendingExportWarning = true
            return
        }
        showDeleteConfirm = true
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }
        isDeletingSession = true
        Task {
            let deleted = await appState.remoteSoftDeleteSession(propertyID: property.id, sessionID: target.id)
            await MainActor.run {
                isDeletingSession = false
                if deleted {
                    deleteTarget = nil
                    reloadSessions()
                } else {
                    deleteErrorMessage = appState.lastSessionDeleteErrorMessage ?? "The session could not be deleted."
                    showDeleteError = true
                }
            }
        }
    }

    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(maxWidth: .infinity, minHeight: 38)
                .padding(.horizontal, 12)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct DebugQueueDiagnosticSnapshotItem: Identifiable, Equatable {
    let id: UUID
    let entityType: String
    let entityID: String
    let operation: String
    let status: String
    let attemptCount: String
    let lastAttempt: String
    let nextAttempt: String
    let age: String
    let lastErrorPreview: String
    let lastErrorFull: String?
    let acknowledgedAt: String
    let acknowledgedReason: String
    let acknowledgedClassification: String
    let acknowledgementSource: String
    let isAcknowledged: Bool

    nonisolated init(_ item: AppState.OfflineQueueDiagnosticItem) {
        id = item.id
        entityType = item.entityType
        entityID = item.entityID.uuidString
        operation = item.operation
        status = item.status
        attemptCount = String(item.attemptCount)
        lastAttempt = formattedDate(item.lastAttemptAt)
        nextAttempt = formattedDate(item.nextAttemptAt)
        age = formattedAge(item.ageSeconds)
        lastErrorPreview = AppState.diagnosticsPreviewText(item.lastError) ?? "none"
        lastErrorFull = item.lastError
        acknowledgedAt = formattedDate(item.acknowledgedAt)
        acknowledgedReason = AppState.diagnosticsPreviewText(item.acknowledgedReason, maxLength: 160) ?? "none"
        acknowledgedClassification = item.acknowledgedClassification ?? "none"
        acknowledgementSource = item.acknowledgementSource ?? "none"
        isAcknowledged = item.acknowledgedAt != nil
    }
}

private struct DebugMediaDiagnosticSnapshotItem: Identifiable, Equatable {
    let id: UUID
    let shotID: String
    let sessionID: String
    let propertyID: String
    let uploadState: String
    let attemptCount: String
    let localFilename: String
    let hasStoragePath: String
    let lastUploadErrorPreview: String
    let lastUploadErrorFull: String?

    nonisolated init(_ item: AppState.MediaDiagnosticItem) {
        id = item.id
        shotID = item.shotID.uuidString
        sessionID = item.sessionID.uuidString
        propertyID = item.propertyID.uuidString
        uploadState = item.uploadState
        attemptCount = String(item.attemptCount)
        localFilename = item.localFilename ?? "unknown"
        hasStoragePath = item.hasStoragePath ? "yes" : "no"
        lastUploadErrorPreview = AppState.diagnosticsPreviewText(item.lastUploadError) ?? "none"
        lastUploadErrorFull = item.lastUploadError
    }
}

private struct DebugMediaRecoverySnapshot {
    let inspectedAt: String
    let activeOrganizationID: String
    let remotePreflightAvailable: String
    let candidatesFound: String
    let fileExistsCount: String
    let retryableCount: String
    let needsOrgReconciliationCount: String
    let missingRemoteParentCount: String
    let alreadyRemoteCompleteCount: String
    let missingLocalFileCount: String
    let manualReviewCount: String
    let items: [DebugMediaRecoverySnapshotItem]
    let snapshotText: String

    init(_ summary: AppState.MediaRecoveryInspectionSummary) {
        inspectedAt = formattedDate(summary.inspectedAt)
        activeOrganizationID = summary.activeOrganizationID?.uuidString ?? "none"
        remotePreflightAvailable = summary.remotePreflightAvailable ? "yes" : "no"
        candidatesFound = String(summary.candidatesFound)
        fileExistsCount = String(summary.fileExistsCount)
        retryableCount = String(summary.retryableCount)
        needsOrgReconciliationCount = String(summary.needsOrgReconciliationCount)
        missingRemoteParentCount = String(summary.missingRemoteParentCount)
        alreadyRemoteCompleteCount = String(summary.alreadyRemoteCompleteCount)
        missingLocalFileCount = String(summary.missingLocalFileCount)
        manualReviewCount = String(summary.manualReviewCount)
        items = summary.candidates.map(DebugMediaRecoverySnapshotItem.init)
        snapshotText = AppState.mediaRecoverySnapshotText(summary)
    }
}

private struct DebugMediaRecoverySnapshotItem: Identifiable, Equatable {
    let id: UUID
    let propertyName: String
    let propertyID: String
    let sessionID: String
    let sessionStatus: String
    let sessionStartedAt: String
    let sessionIsSealed: String
    let shotID: String
    let shotIsFlagged: String
    let uploadState: String
    let uploadAttempts: String
    let lastUploadErrorPreview: String
    let lastUploadErrorFull: String?
    let fileExists: String
    let localFilename: String
    let activeOrganizationID: String
    let reconciledOrganizationID: String
    let propertyOrgID: String
    let sessionOrgID: String
    let staleLocalOrg: String
    let remotePreflightAvailable: String
    let remotePropertyExists: String
    let remoteSessionExists: String
    let remoteShotExists: String
    let remoteStoragePathPresent: String
    let classification: String
    let importanceHint: String
    let sourceReasons: String
    let canRetry: Bool
    let retryUnavailableReason: String

    nonisolated init(_ candidate: AppState.MediaRecoveryCandidate) {
        id = candidate.id
        propertyName = candidate.propertyName
        propertyID = candidate.propertyID.uuidString
        sessionID = candidate.sessionID.uuidString
        sessionStatus = candidate.sessionStatus
        sessionStartedAt = formattedDate(candidate.sessionStartedAt)
        sessionIsSealed = candidate.sessionIsSealed ? "yes" : "no"
        shotID = candidate.shotID.uuidString
        shotIsFlagged = candidate.shotIsFlagged ? "yes" : "no"
        uploadState = candidate.uploadState
        uploadAttempts = String(candidate.uploadAttempts)
        lastUploadErrorPreview = AppState.diagnosticsPreviewText(candidate.lastUploadError) ?? "none"
        lastUploadErrorFull = candidate.lastUploadError
        fileExists = candidate.fileExists ? "yes" : "no"
        localFilename = candidate.localFilename ?? "unknown"
        activeOrganizationID = candidate.activeOrganizationID?.uuidString ?? "none"
        reconciledOrganizationID = candidate.reconciledOrganizationID?.uuidString ?? "none"
        propertyOrgID = candidate.propertyOrgID?.uuidString ?? "none"
        sessionOrgID = candidate.sessionOrgID?.uuidString ?? "none"
        staleLocalOrg = candidate.staleLocalOrg ? "yes" : "no"
        remotePreflightAvailable = candidate.remotePreflightAvailable ? "yes" : "no"
        remotePropertyExists = Self.optionalBool(candidate.remotePropertyExists)
        remoteSessionExists = Self.optionalBool(candidate.remoteSessionExists)
        remoteShotExists = Self.optionalBool(candidate.remoteShotExists)
        remoteStoragePathPresent = Self.optionalBool(candidate.remoteStoragePathPresent)
        classification = candidate.classification.rawValue
        importanceHint = candidate.importanceHint
        sourceReasons = candidate.sourceReasons.joined(separator: ", ")
        let remoteParentReady = candidate.remotePropertyExists == true
        let sessionReadyOrEnsureable = candidate.remoteSessionExists == true || candidate.remotePropertyExists == true
        canRetry = candidate.fileExists &&
            candidate.activeOrganizationID != nil &&
            candidate.reconciledOrganizationID == candidate.activeOrganizationID &&
            remoteParentReady &&
            sessionReadyOrEnsureable &&
            candidate.classification != .alreadyRemoteComplete &&
            candidate.classification != .missingLocalFile &&
            candidate.classification != .missingRemoteParent
        retryUnavailableReason = Self.retryUnavailableReason(for: candidate)
    }

    private nonisolated static func optionalBool(_ value: Bool?) -> String {
        guard let value else { return "not scanned" }
        return value ? "yes" : "no"
    }

    private nonisolated static func retryUnavailableReason(for candidate: AppState.MediaRecoveryCandidate) -> String {
        if !candidate.fileExists { return "Local file is missing." }
        if candidate.activeOrganizationID == nil { return "Active organization is unavailable." }
        if candidate.reconciledOrganizationID != candidate.activeOrganizationID {
            return "Candidate is not reconciled to the current active organization."
        }
        if candidate.classification == .alreadyRemoteComplete { return "Remote shot already appears complete." }
        if candidate.remotePropertyExists == false { return "Remote property is missing under the active organization." }
        if candidate.remotePreflightAvailable == false { return "Remote preflight is unavailable." }
        if candidate.classification == .missingRemoteParent { return "Remote parent preflight failed." }
        return "Preflight does not currently allow retry."
    }
}

private struct DebugDivergenceAuditSnapshot {
    let ranAt: String
    let activeOrganizationID: String
    let remoteScopeAvailable: String
    let localPropertyCount: String
    let remotePropertyCount: String
    let localSessionCount: String
    let remoteSessionCount: String
    let localShotCount: String
    let remoteShotCount: String
    let matchedPropertyCount: String
    let matchedSessionCount: String
    let matchedShotCount: String
    let localOnlyPropertyCount: String
    let remoteOnlyPropertyCount: String
    let localOnlySessionCount: String
    let remoteOnlySessionCount: String
    let localOnlyShotCount: String
    let remoteOnlyShotCount: String
    let staleOrgReconciledPropertyCount: String
    let staleOrgReconciledShotCount: String
    let activeSyncIssueCount: String
    let recoverableIssueCount: String
    let historicalInformationalCount: String
    let totalFindings: String
    let categoryCounts: [(AppState.DivergenceAuditCategory, Int)]
    let items: [DebugDivergenceAuditSnapshotItem]
    let historicalGroups: [DebugDivergenceAuditHistoricalGroup]
    let snapshotText: String

    init(_ summary: AppState.DivergenceAuditSummary) {
        ranAt = formattedDate(summary.ranAt)
        activeOrganizationID = summary.activeOrganizationID?.uuidString ?? "none"
        remoteScopeAvailable = summary.remoteScopeAvailable ? "yes" : "no"
        localPropertyCount = String(summary.localPropertyCount)
        remotePropertyCount = String(summary.remotePropertyCount)
        localSessionCount = String(summary.localSessionCount)
        remoteSessionCount = String(summary.remoteSessionCount)
        localShotCount = String(summary.localShotCount)
        remoteShotCount = String(summary.remoteShotCount)
        matchedPropertyCount = String(summary.matchedPropertyCount)
        matchedSessionCount = String(summary.matchedSessionCount)
        matchedShotCount = String(summary.matchedShotCount)
        localOnlyPropertyCount = String(summary.localOnlyPropertyCount)
        remoteOnlyPropertyCount = String(summary.remoteOnlyPropertyCount)
        localOnlySessionCount = String(summary.localOnlySessionCount)
        remoteOnlySessionCount = String(summary.remoteOnlySessionCount)
        localOnlyShotCount = String(summary.localOnlyShotCount)
        remoteOnlyShotCount = String(summary.remoteOnlyShotCount)
        staleOrgReconciledPropertyCount = String(summary.staleOrgReconciledPropertyCount)
        staleOrgReconciledShotCount = String(summary.staleOrgReconciledShotCount)
        activeSyncIssueCount = String(summary.activeSyncIssueCount)
        recoverableIssueCount = String(summary.recoverableIssueCount)
        historicalInformationalCount = String(summary.historicalInformationalCount)
        totalFindings = String(summary.items.count)
        let counts = summary.countsByCategory
        categoryCounts = AppState.DivergenceAuditCategory.allCases
            .map { ($0, counts[$0] ?? 0) }
            .filter { $0.1 > 0 }
        items = summary.items.map(DebugDivergenceAuditSnapshotItem.init)
        historicalGroups = summary.groupedHistoricalFindings.map { group in
            DebugDivergenceAuditHistoricalGroup(
                summary: group,
                allItems: summary.items
            )
        }
        snapshotText = AppState.divergenceAuditSnapshotText(summary)
    }

    var corePropertyStatus: String {
        remoteOnlyPropertyCount == "0" && localOnlyPropertyCount == "0" ? "OK" : "Needs Review"
    }

    var coreSessionStatus: String {
        remoteOnlySessionCount == "0" && localOnlySessionCount == "0" ? "OK" : "Needs Review"
    }

}

private struct DebugSyncDebtInspectionSnapshot {
    let ranAt: String
    let activeOrganizationID: String
    let failedQueueItemCount: String
    let divergenceItemCount: String
    let groupedHistoricalCount: String
    let queueClassificationCounts: [(AppState.QueueDebtClassification, Int)]
    let divergenceClassificationCounts: [(AppState.DivergenceDebtClassification, Int)]
    let snapshotText: String

    init(_ report: AppState.SyncDebtInspectionReport) {
        ranAt = formattedDate(report.ranAt)
        activeOrganizationID = report.activeOrganizationID?.uuidString ?? "none"
        failedQueueItemCount = String(report.failedQueueItems.count)
        divergenceItemCount = String(report.divergenceItems.count)
        groupedHistoricalCount = String(report.groupedHistoricalFindings.count)
        let queueCounts = Dictionary(grouping: report.failedQueueItems, by: \.classification).mapValues(\.count)
        queueClassificationCounts = AppState.QueueDebtClassification.allCases
            .map { ($0, queueCounts[$0] ?? 0) }
            .filter { $0.1 > 0 }
        let divergenceCounts = Dictionary(grouping: report.divergenceItems, by: \.classification).mapValues(\.count)
        divergenceClassificationCounts = AppState.DivergenceDebtClassification.allCases
            .map { ($0, divergenceCounts[$0] ?? 0) }
            .filter { $0.1 > 0 }
        snapshotText = AppState.syncDebtInspectionReportText(report)
    }
}

private struct DebugRemoteOnlySessionDetailSnapshot {
    let inspectedAt: String
    let activeOrganizationID: String
    let remoteScopeAvailable: String
    let remoteOnlySessionCount: String
    let emptyRemoteDraftShellCount: String
    let missingLocalHydrationCount: String
    let historicalRemoteOnlyCount: String
    let trueParityDebtCount: String
    let manualReviewCount: String
    let possibleHydrationCandidateCount: String
    let draftCautionCount: String
    let snapshotText: String

    init(_ report: AppState.RemoteOnlySessionDetailReport) {
        inspectedAt = report.inspectedAt.formatted(date: .abbreviated, time: .standard)
        activeOrganizationID = report.activeOrganizationID?.uuidString ?? "none"
        remoteScopeAvailable = report.remoteScopeAvailable ? "yes" : "no"
        remoteOnlySessionCount = String(report.items.count)
        emptyRemoteDraftShellCount = String(report.items.filter { $0.classification == .emptyRemoteDraftShell }.count)
        missingLocalHydrationCount = String(report.items.filter { $0.classification == .missingLocalHydration }.count)
        historicalRemoteOnlyCount = String(report.items.filter { $0.classification == .historicalRemoteOnly }.count)
        trueParityDebtCount = String(report.items.filter { $0.classification == .trueParityDebt }.count)
        manualReviewCount = String(report.items.filter { $0.classification == .manualReview }.count)
        possibleHydrationCandidateCount = String(report.items.filter { $0.labels.contains(.possibleHydrationCandidate) }.count)
        draftCautionCount = String(report.items.filter { $0.labels.contains(.cautionDraftIncomplete) }.count)
        snapshotText = AppState.remoteOnlySessionDetailReportText(report)
    }
}

private struct DebugCanonicalReadinessSnapshot {
    let inspectedAt: String
    let activeOrganizationID: String
    let overallStatus: String
    let sections: [AppState.CanonicalReadinessSection]
    let snapshotText: String

    init(_ report: AppState.CanonicalReadinessReport) {
        inspectedAt = report.inspectedAt.formatted(date: .abbreviated, time: .standard)
        activeOrganizationID = report.activeOrganizationID?.uuidString ?? "none"
        overallStatus = report.overallStatus.rawValue
        sections = report.sections
        snapshotText = AppState.canonicalReadinessReportText(report)
    }
}

private struct DebugCompletenessGatesSnapshot {
    let inspectedAt: String
    let activeOrganizationID: String
    let propertyCounts: [AppState.CompletenessGateCount]
    let sessionCounts: [AppState.CompletenessGateCount]
    let shotCounts: [AppState.CompletenessGateCount]
    let issueCounts: [AppState.CompletenessGateCount]
    let guidedCounts: [AppState.CompletenessGateCount]
    let mediaCounts: [AppState.CompletenessGateCount]
    let freshnessCounts: [AppState.CompletenessFreshnessCount]
    let exportCompleteSessionCount: String
    let notExportCompleteSessionCount: String
    let diagnosticOnlyRowCount: String
    let snapshotText: String

    init(_ report: AppState.CompletenessGatesReport) {
        inspectedAt = report.inspectedAt.formatted(date: .abbreviated, time: .standard)
        activeOrganizationID = report.activeOrganizationID?.uuidString ?? "none"
        propertyCounts = report.propertyCounts
        sessionCounts = report.sessionCounts
        shotCounts = report.shotCounts
        issueCounts = report.issueCounts
        guidedCounts = report.guidedCounts
        mediaCounts = report.mediaCounts
        freshnessCounts = report.freshnessCounts
        exportCompleteSessionCount = String(report.exportCompleteSessionCount)
        notExportCompleteSessionCount = String(report.notExportCompleteSessionCount)
        diagnosticOnlyRowCount = String(report.totalDiagnosticOnlyRows)
        snapshotText = AppState.completenessGatesReportText(report)
    }
}

private struct DebugSessionSnapshotPreviewSnapshot {
    let inspectedAt: String
    let activeOrganizationID: String
    let sessionsInspected: String
    let previewableSessions: String
    let missingOrUnreadableSessionJSONCount: String
    let checksumGenerationPassCount: String
    let checksumGenerationFailCount: String
    let totalShotCount: String
    let totalIssueCount: String
    let totalGuidedCount: String
    let totalMediaManifestCount: String
    let totalMissingLocalOriginalsCount: String
    let totalSupabaseStorageMetadataCount: String
    let rows: [AppState.SessionSnapshotPreviewRow]
    let snapshotText: String

    init(_ report: AppState.SessionSnapshotPreviewReport) {
        inspectedAt = report.inspectedAt.formatted(date: .abbreviated, time: .standard)
        activeOrganizationID = report.activeOrganizationID?.uuidString ?? "none"
        sessionsInspected = String(report.sessionsInspected)
        previewableSessions = String(report.previewableSessions)
        missingOrUnreadableSessionJSONCount = String(report.missingOrUnreadableSessionJSONCount)
        checksumGenerationPassCount = String(report.checksumGenerationPassCount)
        checksumGenerationFailCount = String(report.checksumGenerationFailCount)
        totalShotCount = String(report.totalShotCount)
        totalIssueCount = String(report.totalIssueCount)
        totalGuidedCount = String(report.totalGuidedCount)
        totalMediaManifestCount = String(report.totalMediaManifestCount)
        totalMissingLocalOriginalsCount = String(report.totalMissingLocalOriginalsCount)
        totalSupabaseStorageMetadataCount = String(report.totalSupabaseStorageMetadataCount)
        rows = report.rows
        snapshotText = AppState.sessionSnapshotPreviewReportText(report)
    }
}

private struct DebugExportSealPreflightSnapshot {
    let inspectedAt: String
    let activeOrganizationID: String
    let hardBlockCandidateRawCount: Int
    let hardBlockCandidateCount: String
    let softWarningCandidateCount: String
    let informationalOnlyCount: String
    let unknownNeedsReviewCount: String
    let statusMessage: String
    let sections: [AppState.ExportSealPreflightSection]
    let futureWarningGroups: [AppState.EnforcementWarningGroupSummary]
    let futureWarningsText: String
    let snapshotText: String

    init(_ report: AppState.ExportSealPreflightReport) {
        inspectedAt = report.inspectedAt.formatted(date: .abbreviated, time: .standard)
        activeOrganizationID = report.activeOrganizationID?.uuidString ?? "none"
        sections = report.sections
        snapshotText = AppState.exportSealPreflightReportText(report)
        let warnings = AppState.makeEnforcementWarningSummaryReport(inspectedAt: report.inspectedAt)
        futureWarningGroups = warnings.groups
        futureWarningsText = AppState.enforcementWarningSummaryReportText(warnings)
        hardBlockCandidateRawCount = Self.countValue(.hardBlockCandidate, in: report.totalCounts)
        hardBlockCandidateCount = String(hardBlockCandidateRawCount)
        softWarningCandidateCount = Self.count(.softWarningCandidate, in: report.totalCounts)
        informationalOnlyCount = Self.count(.informationalOnly, in: report.totalCounts)
        unknownNeedsReviewCount = Self.count(.unknownNeedsReview, in: report.totalCounts)
        statusMessage = AppState.exportSealPreflightStatusMessage(
            hardBlockCandidateCount: hardBlockCandidateRawCount
        )
    }

    private static func count(
        _ category: AppState.ExportSealPreflightCategory,
        in counts: [AppState.ExportSealPreflightCount]
    ) -> String {
        String(countValue(category, in: counts))
    }

    private static func countValue(
        _ category: AppState.ExportSealPreflightCategory,
        in counts: [AppState.ExportSealPreflightCount]
    ) -> Int {
        counts.first { $0.category == category }?.count ?? 0
    }
}

private struct DebugEnforcementPolicyMatrixSnapshot {
    let inspectedAt: String
    let sections: [AppState.EnforcementPolicyMatrixSection]
    let rowCount: String
    let snapshotText: String

    init(_ report: AppState.EnforcementPolicyMatrixReport) {
        inspectedAt = report.inspectedAt.formatted(date: .abbreviated, time: .standard)
        sections = report.sections
        rowCount = String(report.rows.count)
        snapshotText = AppState.enforcementPolicyMatrixReportText(report)
    }
}

private struct DebugDivergenceAuditHistoricalGroup: Identifiable, Equatable {
    let id: String
    let category: String
    let title: String
    let context: String
    let totalCount: String
    let affectedPropertyCount: String
    let affectedSessionCount: String
    let affectedShotCount: String
    let sampleItems: [DebugDivergenceAuditSnapshotItem]
    let allItems: [DebugDivergenceAuditSnapshotItem]

    init(
        summary: AppState.DivergenceAuditFindingGroupSummary,
        allItems: [AppState.DivergenceAuditItem]
    ) {
        id = summary.category.rawValue
        category = summary.category.rawValue
        title = Self.title(for: summary.category)
        context = Self.context(for: summary.category)
        totalCount = String(summary.totalCount)
        affectedPropertyCount = String(summary.affectedPropertyCount)
        affectedSessionCount = String(summary.affectedSessionCount)
        affectedShotCount = String(summary.affectedShotCount)
        sampleItems = summary.sampleItems.map(DebugDivergenceAuditSnapshotItem.init)
        self.allItems = allItems
            .filter { $0.category == summary.category }
            .map(DebugDivergenceAuditSnapshotItem.init)
    }

    init(
        category: String,
        items: [DebugDivergenceAuditSnapshotItem],
        sampleLimit: Int = 5
    ) {
        id = category
        self.category = category
        title = Self.title(for: category)
        context = Self.context(for: category)
        totalCount = String(items.count)
        affectedPropertyCount = String(Set(items.map(\.propertyID).filter { $0 != "none" }).count)
        affectedSessionCount = String(Set(items.map(\.sessionID).filter { $0 != "none" }).count)
        affectedShotCount = String(Set(items.map(\.shotID).filter { $0 != "none" }).count)
        sampleItems = Array(items.prefix(max(0, sampleLimit)))
        allItems = items
    }

    private static func title(for category: AppState.DivergenceAuditCategory) -> String {
        title(for: category.rawValue)
    }

    private static func title(for category: String) -> String {
        switch category {
        case AppState.DivergenceAuditCategory.legacyOrgReconciliation.rawValue:
            return "Stale Org Reconciled"
        case AppState.DivergenceAuditCategory.legacyRemoteSchema.rawValue:
            return "Legacy Remote Schema"
        case AppState.DivergenceAuditCategory.legacyCaptureProfile.rawValue:
            return "Legacy Capture Profile"
        default:
            return category
        }
    }

    private static func context(for category: AppState.DivergenceAuditCategory) -> String {
        context(for: category.rawValue)
    }

    private static func context(for category: String) -> String {
        switch category {
        case AppState.DivergenceAuditCategory.legacyOrgReconciliation.rawValue:
            return "Historical local org metadata differed, but remote active-org ownership reconciled these records for audit."
        case AppState.DivergenceAuditCategory.legacyRemoteSchema.rawValue:
            return "Remote rows use an older schema shape, but lineage resolves through accessible active-org sessions/properties."
        case AppState.DivergenceAuditCategory.legacyCaptureProfile.rawValue:
            return "Local capture_profile metadata is legacy/null from before canonical profile propagation."
        default:
            return "Historical informational finding group."
        }
    }
}

private struct DebugDivergenceAuditSnapshotItem: Identifiable, Equatable {
    let id: UUID
    let category: String
    let entityType: String
    let entityID: String
    let propertyID: String
    let sessionID: String
    let shotID: String
    let orgID: String
    let reasonPreview: String
    let reasonFull: String
    let severity: String

    var searchableText: String {
        [
            entityID,
            propertyID,
            sessionID,
            shotID,
            orgID,
            reasonFull,
            reasonPreview,
            category,
            severity,
            entityType
        ]
            .joined(separator: " ")
            .lowercased()
    }

    var isGroupedHistorical: Bool {
        category == AppState.DivergenceAuditCategory.legacyOrgReconciliation.rawValue ||
            category == AppState.DivergenceAuditCategory.legacyRemoteSchema.rawValue ||
            category == AppState.DivergenceAuditCategory.legacyCaptureProfile.rawValue
    }

    nonisolated init(_ item: AppState.DivergenceAuditItem) {
        id = item.id
        category = item.category.rawValue
        entityType = item.entityType
        entityID = item.entityID?.uuidString ?? "none"
        propertyID = item.propertyID?.uuidString ?? "none"
        sessionID = item.sessionID?.uuidString ?? "none"
        shotID = item.shotID?.uuidString ?? "none"
        orgID = item.orgID?.uuidString ?? "none"
        reasonPreview = AppState.diagnosticsPreviewText(item.reason) ?? "none"
        reasonFull = item.reason
        severity = item.severity.rawValue
    }

    func filterMatches(_ filter: DebugDivergenceAuditFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .needsReview:
            return severity == AppState.DivergenceAuditSeverity.needsReview.rawValue ||
                severity == AppState.DivergenceAuditSeverity.warning.rawValue ||
                severity == AppState.DivergenceAuditSeverity.critical.rawValue
        case .media:
            return category == AppState.DivergenceAuditCategory.localOnlyShot.rawValue ||
                category == AppState.DivergenceAuditCategory.remoteOnlyShot.rawValue ||
                category == AppState.DivergenceAuditCategory.mediaDrift.rawValue
        case .captureProfile:
            return category == AppState.DivergenceAuditCategory.captureProfile.rawValue ||
                category == AppState.DivergenceAuditCategory.legacyCaptureProfile.rawValue
        case .parentMissing:
            return category == AppState.DivergenceAuditCategory.missingParent.rawValue ||
                category == AppState.DivergenceAuditCategory.legacyRemoteSchema.rawValue
        case .orgReconciliation:
            return category == AppState.DivergenceAuditCategory.staleOrgMismatch.rawValue ||
                category == AppState.DivergenceAuditCategory.legacyOrgReconciliation.rawValue
        }
    }

    func matches(_ filters: DebugDivergenceAuditFindingFilters) -> Bool {
        if filters.severity != DebugDivergenceAuditFindingFilters.allValue,
           severity != filters.severity {
            return false
        }
        if filters.category != DebugDivergenceAuditFindingFilters.allValue,
           category != filters.category {
            return false
        }
        if filters.entityType != DebugDivergenceAuditFindingFilters.allValue,
           entityType != filters.entityType {
            return false
        }
        let search = filters.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return search.isEmpty || searchableText.contains(search)
    }
}

private struct DebugDivergenceAuditFindingFilters: Equatable {
    static let allValue = "All"

    var severity: String = allValue
    var category: String = allValue
    var entityType: String = allValue
    var searchText: String = ""

    var isDefault: Bool {
        severity == Self.allValue &&
            category == Self.allValue &&
            entityType == Self.allValue &&
            searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum DebugDivergenceAuditFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsReview = "Needs Review"
    case media = "Media"
    case captureProfile = "Capture Profile"
    case parentMissing = "Parent/Missing"
    case orgReconciliation = "Org Reconciliation"

    var id: String { rawValue }
}

enum DebugLocalDiagnosticsPresentationRoute: Hashable, Identifiable {
    case sessionSnapshotUpload

    var id: Self { self }
}

private struct DebugLocalDiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm: Bool = false
    @State private var isRunningDivergenceAudit: Bool = false
    @State private var isInspectingMediaRecovery: Bool = false
    @State private var isInspectingSyncDebt: Bool = false
    @State private var isInspectingRemoteOnlySessions: Bool = false
    @State private var failedQueueItems: [DebugQueueDiagnosticSnapshotItem] = []
    @State private var retryCappedMediaItems: [DebugMediaDiagnosticSnapshotItem] = []
    @State private var pendingMediaItems: [DebugMediaDiagnosticSnapshotItem] = []
    @State private var mediaRecoverySnapshot: DebugMediaRecoverySnapshot?
    @State private var mediaRecoverySummary: AppState.MediaRecoveryInspectionSummary?
    @State private var divergenceAuditSummary: AppState.DivergenceAuditSummary?
    @State private var divergenceAuditSnapshot: DebugDivergenceAuditSnapshot?
    @State private var syncDebtReport: AppState.SyncDebtInspectionReport?
    @State private var syncDebtSnapshot: DebugSyncDebtInspectionSnapshot?
    @State private var remoteOnlySessionDetailReport: AppState.RemoteOnlySessionDetailReport?
    @State private var remoteOnlySessionDetailSnapshot: DebugRemoteOnlySessionDetailSnapshot?
    @State private var canonicalReadinessSnapshot: DebugCanonicalReadinessSnapshot?
    @State private var completenessGatesSnapshot: DebugCompletenessGatesSnapshot?
    @State private var sessionSnapshotPreviewSnapshot: DebugSessionSnapshotPreviewSnapshot?
    @State private var exportSealPreflightSnapshot: DebugExportSealPreflightSnapshot?
    @State private var enforcementPolicyMatrixSnapshot: DebugEnforcementPolicyMatrixSnapshot?
    @State private var presentedRoute: DebugLocalDiagnosticsPresentationRoute?
    @State private var isStageSnapshotUploadDetailsExpanded: Bool = false
    @State private var isStageUploadingSessionSnapshot: Bool = false
    @State private var isStageRunningPackageValidation: Bool = false
    @State private var stagePackageValidationReport: AppState.LocalHealthSessionSnapshotPackageValidationReport?
    @State private var isStageAuthorizingSelectedSessionQA: Bool = false
    @State private var isStageClearingSelectedSessionQA: Bool = false
    @State private var stageSelectedSessionQAAuthorizationResult: AppState.RuntimeSelectedSessionQAAuthorizationStatus?
    @State private var isStageBuildingCanonicalCandidateOverlay: Bool = false
    @State private var stageCanonicalCandidateOverlayBuildResult: AppState.CanonicalCandidateOverlayBuildResult?
    @State private var isStageShowingCanonicalCandidateActivationConfirmation: Bool = false
    @State private var isStageActivatingCanonicalCandidate: Bool = false
    @State private var isStageRollingBackCanonicalCandidate: Bool = false
    @State private var stageCanonicalCandidateActivationResult: AppState.CanonicalCandidateActivationResult?
    @State private var stageCanonicalCandidateRollbackResult: AppState.CanonicalCandidateActivationResult?
    @State private var isStageRunningSelectedSessionValidationPipeline: Bool = false
    @State private var stageSelectedSessionValidationPipelineReport: AppState.LocalHealthSelectedSessionValidationPipelineReport?
    @State private var isStageReplayingSelectedSessionLifecycleShadowWrite: Bool = false
    @State private var stageSelectedSessionLifecycleReplayResult: AppState.SelectedSessionLifecycleReplayActionResult?
    @State private var isStageCheckingCanonicalReadDiagnostics: Bool = false
    @State private var isStageReplayingFlaggedObservationShadowWrites: Bool = false
    @State private var stageFlaggedObservationReplayActionResult: AppState.SelectedSessionFlaggedObservationReplayActionResult?
    @State private var isStageRecordingOperatorApproval: Bool = false
    @State private var isStageClearingOperatorApproval: Bool = false
    @State private var stageOperatorApproval: AppState.ProductionCohortOperatorApprovalDiagnostics?
    @State private var stageOperatorApprovalCheckedAt: Date?
    @State private var stageOperatorApprovalClearReason: String?
    @State private var stageTestSessionCreationMessage: String?
    @State private var isStageRefreshingAuthPreflight: Bool = false
    @State private var isStageRepairingLocalOrgDrift: Bool = false
    @State private var isStageRunningLocalOrgDriftAudit: Bool = false
    @State private var isStageRepairingConfirmedLocalOrgDrift: Bool = false
    @State private var isStageCheckingSnapshotReadback: Bool = false
    @State private var isStageCheckingSnapshotRestoreDiagnostics: Bool = false
    @State private var isStageHydratingSnapshotMetadata: Bool = false
    @State private var isStageShowingHydrationConfirmation: Bool = false
    @State private var isStageRetrievingSnapshotMedia: Bool = false
    @State private var isStageShowingMediaRetrievalConfirmation: Bool = false
    @State private var isStageCheckingRecoveryCohort: Bool = false

    private var diagnostics: AppState.LocalDiagnosticsState {
        appState.localDiagnostics
    }

    private var stageSessionSnapshotEnvironmentFlagDetected: Bool {
        ProcessInfo.processInfo.environment["session_snapshot_shadow_write_enabled"] != nil ||
            ProcessInfo.processInfo.environment["SCOUTCAPTURE_SESSION_SNAPSHOT_SHADOW_WRITE_ENABLED"] != nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Local diagnostic state only. Clearing this screen resets counters and last-error memory; it does not clear queues, files, Supabase rows, exports, reports, or app data.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Section("Overview / Summary") {
                    diagnosticRow("Active Sync Issues", divergenceAuditSnapshot?.activeSyncIssueCount ?? "not run")
                    diagnosticRow("Recoverable Findings", divergenceAuditSnapshot?.recoverableIssueCount ?? "not run")
                    diagnosticRow("Debt Report Findings", syncDebtSnapshot?.divergenceItemCount ?? "not run")
                    diagnosticRow("Remote-Only Detail Items", remoteOnlySessionDetailSnapshot?.remoteOnlySessionCount ?? "not run")
                    diagnosticRow("Retryable Failed Queue Items", diagnostics.offlineQueue.failedCount)
                    diagnosticRow("Acknowledged Historical Queue Debt", diagnostics.offlineQueue.acknowledgedHistoricalCount)
                    diagnosticRow("Retry-Capped Media", retryCappedMediaItems.count)
                    diagnosticRow("Pending Media", pendingMediaItems.count)
                    diagnosticRow("Last Error", diagnostics.lastError?.category.rawValue ?? "none")
                    diagnosticRow("Offline Replay", formattedRunDate(diagnostics.offlineReplay.lastRunAt))
                    diagnosticRow("Media Backfill", formattedRunDate(diagnostics.media.lastBackfillAt))
                    Text(overviewHelperText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Section("Health Areas") {
                    NavigationLink {
                        canonicalReadinessPage
                    } label: {
                        localHealthAreaLabel(
                            "Canonical Readiness",
                            subtitle: "Read-only Phase C readiness gates and blockers",
                            value: canonicalReadinessSnapshot?.overallStatus ?? "not inspected"
                        )
                    }
                    NavigationLink {
                        completenessGatesPage
                    } label: {
                        localHealthAreaLabel(
                            "Completeness Gates",
                            subtitle: "Read-only local metadata/media/export completeness",
                            value: completenessGatesSnapshot.map { "\($0.diagnosticOnlyRowCount) diagnostic rows" } ?? "not inspected"
                        )
                    }
                    NavigationLink {
                        sessionSnapshotPreviewPage
                    } label: {
                        localHealthAreaLabel(
                            "Session Snapshot Preview",
                            subtitle: "Read-only local session.json snapshot preview",
                            value: sessionSnapshotPreviewSnapshot.map { "\($0.previewableSessions) previewable" } ?? "not inspected"
                        )
                    }
                    Button {
                        presentedRoute = .sessionSnapshotUpload
                    } label: {
                        HStack(alignment: .center, spacing: 8) {
                            localHealthAreaLabel(
                                "Session Snapshot Upload",
                                subtitle: "Default-off shadow-write upload diagnostics",
                                value: diagnostics.sessionSnapshotUpload.remoteAvailability
                            )
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    NavigationLink {
                        exportSealPreflightPage
                    } label: {
                        localHealthAreaLabel(
                            "Export / Seal Preflight",
                            subtitle: "Read-only advisory export, re-export, and sealing candidates",
                            value: exportSealPreflightSnapshot.map { "\($0.hardBlockCandidateCount) future hard blocks" } ?? "not inspected"
                        )
                    }
                    NavigationLink {
                        enforcementPolicyMatrixPage
                    } label: {
                        localHealthAreaLabel(
                            "Enforcement Policy Matrix",
                            subtitle: "Read-only future enforcement policy by operation",
                            value: enforcementPolicyMatrixSnapshot.map { "\($0.rowCount) policy rows" } ?? "not inspected"
                        )
                    }
                    NavigationLink {
                        offlineQueuePage
                    } label: {
                        localHealthAreaLabel(
                            "Offline Queue",
                            subtitle: "Replay counters, queue totals, failed items",
                            value: "\(diagnostics.offlineQueue.failedCount) retryable failed"
                        )
                    }
                    NavigationLink {
                        mediaHealthPage
                    } label: {
                        localHealthAreaLabel(
                            "Media Health / Recovery",
                            subtitle: "Backfill counters, pending media, recovery candidates",
                            value: "\(retryCappedMediaItems.count) capped"
                        )
                    }
                    NavigationLink {
                        divergenceAuditPage
                    } label: {
                        localHealthAreaLabel(
                            "Divergence Audit",
                            subtitle: "Local/remote audit, grouped findings, snapshots",
                            value: divergenceAuditSnapshot.map { "\($0.totalFindings) findings" } ?? "not run"
                        )
                    }
                    NavigationLink {
                        captureProfileMaintenancePage
                    } label: {
                        localHealthAreaLabel(
                            "Capture Profile Maintenance",
                            subtitle: "Last backfill summary and profile sync counters",
                            value: diagnostics.captureProfileMaintenance.map { "\($0.failed) historical failed" } ?? "No recorded run"
                        )
                    }
                    NavigationLink {
                        diagnosticsUtilitiesPage
                    } label: {
                        localHealthAreaLabel(
                            "Last Error / Utilities",
                            subtitle: "Sanitized last error, shadow writes, clear diagnostics",
                            value: diagnostics.lastError?.category.rawValue ?? "none"
                        )
                    }
                }
            }
            .navigationTitle("Local Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            refreshDiagnosticDetailSnapshots()
        }
        .onChange(of: appState.activeOrganizationID) { _, _ in
            mediaRecoverySnapshot = nil
            mediaRecoverySummary = nil
            divergenceAuditSummary = nil
            divergenceAuditSnapshot = nil
            syncDebtReport = nil
            syncDebtSnapshot = nil
            remoteOnlySessionDetailReport = nil
            remoteOnlySessionDetailSnapshot = nil
            canonicalReadinessSnapshot = nil
            completenessGatesSnapshot = nil
            sessionSnapshotPreviewSnapshot = nil
            exportSealPreflightSnapshot = nil
            enforcementPolicyMatrixSnapshot = nil
            refreshDiagnosticDetailSnapshots()
        }
        .alert("Clear Local Diagnostics?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                appState.clearLocalDiagnostics()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only local diagnostic counters and the last sanitized error will be reset. Queues, files, Supabase data, exports, and app records are not changed.")
        }
        .sheet(item: $presentedRoute) { route in
            NavigationStack {
                switch route {
                case .sessionSnapshotUpload:
                    sessionSnapshotUploadTargetSummaryStageView
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") {
                                    presentedRoute = nil
                                }
                            }
                        }
                    }
            }
        }
    }

    private var sessionSnapshotUploadTargetSummaryStageView: some View {
        let uploadTarget = appState.manualSessionSnapshotUploadTarget
        let uploadTargetResolution = appState.manualSessionSnapshotUploadTargetResolution
        let uploadAvailability = appState.manualSessionSnapshotUploadAvailability
        let snapshotDiagnostics = appState.localDiagnostics.sessionSnapshotUpload
        let qaControlsPresentation = appState.localHealthSelectedSessionQAControlsPresentationState
        let testSessionCreationAvailability = appState.manualSessionSnapshotTestSessionCreationAvailability
        let stagePackageEvidenceReady = stagePackageValidationReport?.packageParity.state == .testOnlyPackageParityPassed &&
            stagePackageValidationReport?.packageParity.blockers.isEmpty == true &&
            stagePackageValidationReport?.fullyRestoredRollback.state == .testOnlyFullyRestoredPackageRollbackPassed &&
            stagePackageValidationReport?.fullyRestoredRollback.blockers.isEmpty == true
        let pipelineControlsAvailable = qaControlsPresentation.controlsMounted
        let lifecycleReplayTargetAvailable = uploadTarget != nil
        let lifecycleReplayButtonDisabled = !lifecycleReplayTargetAvailable || isStageReplayingSelectedSessionLifecycleShadowWrite
        let lifecycleReplayGuardPreview = lifecycleReplayTargetAvailable ? "package_validation_evidence_required_until_validated" : "selected_session_snapshot_target_required"
        let storedPipelineReportText = snapshotDiagnostics.lastSelectedSessionValidationPipelineReportText
        let actionPipelineReportText = stageSelectedSessionValidationPipelineReport?.reportText
        let authPreflightCheckedDisplay = formattedRunDate(snapshotDiagnostics.lastAuthPreflightAt)
        let authPreflightAppUserDisplay = snapshotDiagnostics.lastAuthPreflightAppUserID ?? "none"
        let authPreflightClientUserDisplay = snapshotDiagnostics.lastAuthPreflightClientUserID ?? "none"
        let authPreflightUsersMatchDisplay = optionalBoolText(snapshotDiagnostics.lastAuthPreflightUsersMatch)
        let authPreflightPayloadOrgDisplay = snapshotDiagnostics.lastAuthPreflightPayloadOrgID?.uuidString ?? "none"
        let authPreflightPayloadPropertyDisplay = snapshotDiagnostics.lastAuthPreflightPayloadPropertyID?.uuidString ?? "none"
        let authPreflightPayloadSessionDisplay = snapshotDiagnostics.lastAuthPreflightPayloadSessionID?.uuidString ?? "none"
        let authPreflightRows = [
            StageDiagnosticDisplayRow("Remote Property", optionalBoolText(snapshotDiagnostics.lastAuthPreflightRemotePropertyExists)),
            StageDiagnosticDisplayRow("Remote Session", optionalBoolText(snapshotDiagnostics.lastAuthPreflightRemoteSessionExists)),
            StageDiagnosticDisplayRow("Remote Property Org", snapshotDiagnostics.lastAuthPreflightRemotePropertyOrgID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Remote Session Org", snapshotDiagnostics.lastAuthPreflightRemoteSessionOrgID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Remote Session Property", optionalBoolText(snapshotDiagnostics.lastAuthPreflightRemoteSessionPropertyMatches)),
            StageDiagnosticDisplayRow("Remote Org Match", optionalBoolText(snapshotDiagnostics.lastAuthPreflightRemoteOrgIDsMatch)),
            StageDiagnosticDisplayRow("Preflight Ready", optionalBoolText(snapshotDiagnostics.lastAuthPreflightReady))
        ]
        let authPreflightFailure = AppState.diagnosticsPreviewText(snapshotDiagnostics.lastAuthPreflightFailureMessage, maxLength: 160)
        let hydrationPolicy = appState.sessionSnapshotHydrationPolicyDiagnostics
        let hydrationConfirmation = AppState.makeSessionSnapshotHydrationConfirmation(
            diagnostics: snapshotDiagnostics,
            policy: hydrationPolicy
        )
        let mediaRetrievalConfirmation = AppState.makeSessionSnapshotMediaRetrievalConfirmation(
            diagnostics: snapshotDiagnostics,
            targetClassification: appState.supabaseConfiguration.targetClassification
        )
        let sessionSnapshotUploadRows = [
            StageDiagnosticDisplayRow("Flag Enabled", appState.backendFeatureFlags.sessionSnapshotShadowWriteEnabled ? "true" : "false"),
            StageDiagnosticDisplayRow("Remote Availability", snapshotDiagnostics.remoteAvailability),
            StageDiagnosticDisplayRow("Attempts", String(snapshotDiagnostics.attemptedCount)),
            StageDiagnosticDisplayRow("Successes", String(snapshotDiagnostics.successCount)),
            StageDiagnosticDisplayRow("Failures", String(snapshotDiagnostics.failureCount)),
            StageDiagnosticDisplayRow("Orphan Risk", String(snapshotDiagnostics.orphanRiskCount)),
            StageDiagnosticDisplayRow("Final Upload Outcome", snapshotDiagnostics.lastUploadOutcome),
            StageDiagnosticDisplayRow("Last Attempt", formattedRunDate(snapshotDiagnostics.lastAttemptAt)),
            StageDiagnosticDisplayRow("Last Success", formattedRunDate(snapshotDiagnostics.lastSuccessAt)),
            StageDiagnosticDisplayRow("Last Failure", formattedRunDate(snapshotDiagnostics.lastFailureAt))
        ]
        let sessionSnapshotUploadError = AppState.diagnosticsPreviewText(snapshotDiagnostics.lastUploadErrorMessage, maxLength: 160)
        let lastSanitizedAttemptRows = [
            StageDiagnosticDisplayRow("Snapshot ID", snapshotDiagnostics.lastSnapshotID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Property ID", snapshotDiagnostics.lastPropertyID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Session ID", snapshotDiagnostics.lastSessionID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Snapshot Kind", snapshotDiagnostics.lastKind ?? "none"),
            StageDiagnosticDisplayRow("Trigger", snapshotDiagnostics.lastTrigger ?? "none"),
            StageDiagnosticDisplayRow("Generated Payload Path", AppState.diagnosticsPreviewText(snapshotDiagnostics.lastUploadPath) == nil ? "false" : "true"),
            StageDiagnosticDisplayRow("Storage Upload Completed", snapshotDiagnostics.lastStorageUploadCompleted ? "true" : "false"),
            StageDiagnosticDisplayRow("Row Insert Completed", snapshotDiagnostics.lastRowInsertCompleted ? "true" : "false")
        ]
        let authRepairRows = [
            StageDiagnosticDisplayRow("Repair Outcome", snapshotDiagnostics.lastLocalOrgRepairOutcome),
            StageDiagnosticDisplayRow("Repair Previous Org", snapshotDiagnostics.lastLocalOrgRepairPreviousOrgID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Repair Canonical Org", snapshotDiagnostics.lastLocalOrgRepairCanonicalOrgID?.uuidString ?? "none")
        ]
        let authRepairMessage = AppState.diagnosticsPreviewText(snapshotDiagnostics.lastLocalOrgRepairMessage, maxLength: 160)
        let localOrgDriftAuditRows = [
            StageDiagnosticDisplayRow("Checked", formattedRunDate(snapshotDiagnostics.lastLocalOrgDriftAuditAt)),
            StageDiagnosticDisplayRow("Properties Checked", String(snapshotDiagnostics.lastLocalOrgDriftAuditPropertiesChecked)),
            StageDiagnosticDisplayRow("Sessions Checked", String(snapshotDiagnostics.lastLocalOrgDriftAuditSessionsChecked)),
            StageDiagnosticDisplayRow("Property Mismatches", String(snapshotDiagnostics.lastLocalOrgDriftAuditPropertyMismatchCount)),
            StageDiagnosticDisplayRow("Session Mismatches", String(snapshotDiagnostics.lastLocalOrgDriftAuditSessionMismatchCount)),
            StageDiagnosticDisplayRow("Unable To Confirm", String(snapshotDiagnostics.lastLocalOrgDriftAuditUnableToConfirmCount))
        ]
        let localOrgDriftAuditSamples = snapshotDiagnostics.lastLocalOrgDriftAuditSamples.map {
            AppState.diagnosticsPreviewText($0, maxLength: 180) ?? "sample_unavailable"
        }
        let localOrgDriftRepairRows = [
            StageDiagnosticDisplayRow("Repair Checked", formattedRunDate(snapshotDiagnostics.lastLocalOrgDriftRepairAt)),
            StageDiagnosticDisplayRow("Repair Attempts", String(snapshotDiagnostics.lastLocalOrgDriftRepairAttemptedCount)),
            StageDiagnosticDisplayRow("Repaired Properties", String(snapshotDiagnostics.lastLocalOrgDriftRepairPropertyCount)),
            StageDiagnosticDisplayRow("Repaired Sessions", String(snapshotDiagnostics.lastLocalOrgDriftRepairSessionCount)),
            StageDiagnosticDisplayRow("Repair Skipped", String(snapshotDiagnostics.lastLocalOrgDriftRepairSkippedCount)),
            StageDiagnosticDisplayRow("Repair Failures", String(snapshotDiagnostics.lastLocalOrgDriftRepairFailureCount))
        ]
        let localOrgDriftRepairSamples = snapshotDiagnostics.lastLocalOrgDriftRepairSamples.map {
            AppState.diagnosticsPreviewText($0, maxLength: 180) ?? "sample_unavailable"
        }
        let remoteReadbackRows = [
            StageDiagnosticDisplayRow("Status", snapshotDiagnostics.lastReadbackStatus),
            StageDiagnosticDisplayRow("Last Checked", formattedRunDate(snapshotDiagnostics.lastReadbackAt)),
            StageDiagnosticDisplayRow("Snapshot ID", snapshotDiagnostics.lastReadbackSnapshotID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Row Found", snapshotDiagnostics.lastReadbackRowFound ? "true" : "false"),
            StageDiagnosticDisplayRow("Payload Readable", snapshotDiagnostics.lastReadbackPayloadReadable ? "true" : "false"),
            StageDiagnosticDisplayRow("Checksum Verified", snapshotDiagnostics.lastReadbackChecksumVerified ? "true" : "false"),
            StageDiagnosticDisplayRow("Row/Object Consistent", snapshotDiagnostics.lastReadbackRowObjectConsistent ? "true" : "false"),
            StageDiagnosticDisplayRow("Payload Byte Size", snapshotDiagnostics.lastReadbackPayloadByteSize.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Snapshot Created", formattedRunDate(snapshotDiagnostics.lastReadbackSnapshotCreatedAt))
        ]
        let remoteReadbackFailure = AppState.diagnosticsPreviewText(snapshotDiagnostics.lastReadbackFailureMessage, maxLength: 160)
        let restoreDiagnosticsRows = [
            StageDiagnosticDisplayRow("Result", snapshotDiagnostics.lastRestoreDiagnosticsResult),
            StageDiagnosticDisplayRow("Last Checked", formattedRunDate(snapshotDiagnostics.lastRestoreDiagnosticsAt)),
            StageDiagnosticDisplayRow("Property ID", snapshotDiagnostics.lastRestoreDiagnosticsPropertyID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Session ID", snapshotDiagnostics.lastRestoreDiagnosticsSessionID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Snapshot ID", snapshotDiagnostics.lastRestoreDiagnosticsSnapshotID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Row Found", snapshotDiagnostics.lastRestoreDiagnosticsRowFound ? "true" : "false"),
            StageDiagnosticDisplayRow("Object Readable", snapshotDiagnostics.lastRestoreDiagnosticsObjectReadable ? "true" : "false"),
            StageDiagnosticDisplayRow("Checksum Verified", snapshotDiagnostics.lastRestoreDiagnosticsChecksumVerified ? "true" : "false"),
            StageDiagnosticDisplayRow("Byte Size Matches", snapshotDiagnostics.lastRestoreDiagnosticsByteSizeMatches ? "true" : "false"),
            StageDiagnosticDisplayRow("Row/Object Verified", snapshotDiagnostics.lastRestoreDiagnosticsRowObjectVerified ? "true" : "false"),
            StageDiagnosticDisplayRow("Parent Remote Verified", snapshotDiagnostics.lastRestoreDiagnosticsParentRemoteVerified ? "true" : "false"),
            StageDiagnosticDisplayRow("Snapshot Schema", snapshotDiagnostics.lastRestoreDiagnosticsSnapshotSchemaVersion.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Snapshot Created", formattedRunDate(snapshotDiagnostics.lastRestoreDiagnosticsSnapshotCreatedAt)),
            StageDiagnosticDisplayRow("Snapshot Generated", formattedRunDate(snapshotDiagnostics.lastRestoreDiagnosticsSnapshotGeneratedAt)),
            StageDiagnosticDisplayRow("Local Known State", formattedRunDate(snapshotDiagnostics.lastRestoreDiagnosticsLocalKnownStateAt)),
            StageDiagnosticDisplayRow("Local Known Source", snapshotDiagnostics.lastRestoreDiagnosticsLocalKnownStateSource ?? "none"),
            StageDiagnosticDisplayRow("Freshness", snapshotDiagnostics.lastRestoreDiagnosticsFreshness),
            StageDiagnosticDisplayRow("Local Session Exists", snapshotDiagnostics.lastRestoreDiagnosticsLocalSessionExists ? "true" : "false"),
            StageDiagnosticDisplayRow("Local Session Status", snapshotDiagnostics.lastRestoreDiagnosticsLocalSessionStatus ?? "none"),
            StageDiagnosticDisplayRow("Local Shots", snapshotDiagnostics.lastRestoreDiagnosticsLocalShotCount.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Local Issues", snapshotDiagnostics.lastRestoreDiagnosticsLocalIssueCount.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Local Guided", snapshotDiagnostics.lastRestoreDiagnosticsLocalGuidedCount.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Snapshot Shots", snapshotDiagnostics.lastRestoreDiagnosticsSnapshotShotCount.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Snapshot Issues", snapshotDiagnostics.lastRestoreDiagnosticsSnapshotIssueCount.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Snapshot Guided", snapshotDiagnostics.lastRestoreDiagnosticsSnapshotGuidedCount.map(String.init) ?? "none"),
            StageDiagnosticDisplayRow("Media Manifest Count", snapshotDiagnostics.lastRestoreDiagnosticsSnapshotMediaManifestCount.map(String.init) ?? "none")
        ]
        let restoreDiagnosticsFailure = AppState.diagnosticsPreviewText(snapshotDiagnostics.lastRestoreDiagnosticsFailureReason, maxLength: 160)
        let metadataHydrationRows = [
            StageDiagnosticDisplayRow("Hydration Allowed", snapshotDiagnostics.lastHydrationAllowed ? "true" : "false"),
            StageDiagnosticDisplayRow("Hydration Blocked", snapshotDiagnostics.lastHydrationBlockedReason ?? "none"),
            StageDiagnosticDisplayRow("Hydration Source", snapshotDiagnostics.lastHydrationSourceSnapshotID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Hydrated At", formattedRunDate(snapshotDiagnostics.lastHydrationAt)),
            StageDiagnosticDisplayRow("Hydrated Session", snapshotDiagnostics.lastHydrationSessionID?.uuidString ?? "none"),
            StageDiagnosticDisplayRow("Hydrated Shots", String(snapshotDiagnostics.lastHydrationShotCount)),
            StageDiagnosticDisplayRow("Hydrated Issues", String(snapshotDiagnostics.lastHydrationIssueCount)),
            StageDiagnosticDisplayRow("Hydrated Guided", String(snapshotDiagnostics.lastHydrationGuidedCount)),
            StageDiagnosticDisplayRow("Production Hydration Allowed", hydrationPolicy.productionHydrationAllowed ? "true" : "false"),
            StageDiagnosticDisplayRow("Hydration Mode", hydrationPolicy.hydrationMode),
            StageDiagnosticDisplayRow("Hydration Scope", hydrationPolicy.hydrationScope),
            StageDiagnosticDisplayRow("Production Hydration Blocked Reason", hydrationPolicy.productionHydrationBlockedReason ?? "none"),
            StageDiagnosticDisplayRow("Hydration Confirmation Required", hydrationConfirmation.confirmationRequired ? "true" : "false"),
            StageDiagnosticDisplayRow("Hydration Action Available", hydrationConfirmation.canHydrate ? "true" : "false"),
            StageDiagnosticDisplayRow("Hydration Action Blocked Reason", hydrationConfirmation.blockedReason ?? "none")
        ]
        let mediaRetrievalRows = [
            StageDiagnosticDisplayRow("Media Retrieval Allowed", mediaRetrievalConfirmation.canRetrieve ? "true" : "false"),
            StageDiagnosticDisplayRow("Media Retrieval Blocked", mediaRetrievalConfirmation.blockedReason ?? "none"),
            StageDiagnosticDisplayRow("Media Retrieval Attempted", String(snapshotDiagnostics.lastMediaRetrievalAttemptedCount)),
            StageDiagnosticDisplayRow("Media Retrieval Downloaded", String(snapshotDiagnostics.lastMediaRetrievalDownloadedCount)),
            StageDiagnosticDisplayRow("Media Retrieval Checksums", String(snapshotDiagnostics.lastMediaRetrievalChecksumVerifiedCount)),
            StageDiagnosticDisplayRow("Media Retrieval Existing", String(snapshotDiagnostics.lastMediaRetrievalSkippedExistingCount)),
            StageDiagnosticDisplayRow("Media Retrieval Failed", String(snapshotDiagnostics.lastMediaRetrievalFailedCount)),
            StageDiagnosticDisplayRow("Recovered Local Paths", String(snapshotDiagnostics.lastMediaRetrievalRecoveredLocalPathCount))
        ]
        let recoveryCohortRows = [
            StageDiagnosticDisplayRow("Cohort", snapshotDiagnostics.lastRecoveryCohortCategory),
            StageDiagnosticDisplayRow("Readiness", snapshotDiagnostics.lastRecoveryReadiness),
            StageDiagnosticDisplayRow("Risk", snapshotDiagnostics.lastRecoveryRiskLevel),
            StageDiagnosticDisplayRow("Snapshot Age Seconds", snapshotDiagnostics.lastRecoverySnapshotFreshnessAgeSeconds.map { String(Int($0)) } ?? "none"),
            StageDiagnosticDisplayRow("Hydration Eligibility", snapshotDiagnostics.lastRecoveryHydrationEligibilityReason),
            StageDiagnosticDisplayRow("Latest Snapshot Covered", snapshotDiagnostics.lastRecoveryLatestSnapshotCovered ? "true" : "false"),
            StageDiagnosticDisplayRow("Restore Result", snapshotDiagnostics.lastRecoveryRestoreDiagnosticsResult)
        ]
        let canonicalReadDiagnosticsActionRows = [
            StageDiagnosticDisplayRow("Diagnostics Result", snapshotDiagnostics.lastCanonicalReadDiagnosticsResult),
            StageDiagnosticDisplayRow("Diagnostics Checked", formattedDate(snapshotDiagnostics.lastCanonicalReadDiagnosticsAt)),
            StageDiagnosticDisplayRow("Diagnostics Blocker", snapshotDiagnostics.lastCanonicalReadDiagnosticsBlockedReason ?? "none")
        ]
        let flaggedObservationReplayRows: [StageDiagnosticDisplayRow]
        if let stageFlaggedObservationReplayActionResult {
            let replay = stageFlaggedObservationReplayActionResult.replayResult
            flaggedObservationReplayRows = [
                StageDiagnosticDisplayRow("Replay Action", stageFlaggedObservationReplayActionResult.allowed ? "allowed" : "blocked"),
                StageDiagnosticDisplayRow("Replay Checked", formattedDate(stageFlaggedObservationReplayActionResult.checkedAt)),
                StageDiagnosticDisplayRow("Replay Blocked", stageFlaggedObservationReplayActionResult.blockedReason ?? "none"),
                StageDiagnosticDisplayRow("Replay Scope", "property \(stageFlaggedObservationReplayActionResult.propertyID?.uuidString ?? "none"), session \(stageFlaggedObservationReplayActionResult.sessionID?.uuidString ?? "none")"),
                StageDiagnosticDisplayRow("Replay Planned", replay.map { String($0.attemptedCount) } ?? "not run"),
                StageDiagnosticDisplayRow("Replay Executed", replay.map { String($0.upsertedCount) } ?? "not run"),
                StageDiagnosticDisplayRow("Replay Skipped", replay.map { String($0.skippedCount) } ?? "not run"),
                StageDiagnosticDisplayRow("Replay Remote Newer", replay.map { String($0.remoteNewerConflictCount) } ?? "not run"),
                StageDiagnosticDisplayRow("Replay Failed", replay.map { String($0.failedCount) } ?? "not run"),
                StageDiagnosticDisplayRow("Replay Result", AppState.diagnosticsPreviewText(replay?.message, maxLength: 160) ?? "not run"),
                StageDiagnosticDisplayRow("Post-Replay Diagnostics", stageFlaggedObservationReplayActionResult.diagnosticsAfterReplay == nil ? "not run" : "refreshed"),
                StageDiagnosticDisplayRow("Post-Replay Result", stageFlaggedObservationReplayActionResult.diagnosticsAfterReplay?.result.rawValue ?? "not run")
            ]
        } else {
            flaggedObservationReplayRows = [
                StageDiagnosticDisplayRow("Replay Action", "not run"),
                StageDiagnosticDisplayRow("Replay Blocked", "none"),
                StageDiagnosticDisplayRow("Replay Planned", "not run"),
                StageDiagnosticDisplayRow("Replay Executed", "not run"),
                StageDiagnosticDisplayRow("Replay Skipped", "not run"),
                StageDiagnosticDisplayRow("Replay Remote Newer", "not run"),
                StageDiagnosticDisplayRow("Post-Replay Diagnostics", "not run")
            ]
        }
        let operatorApprovalRows = [
            StageDiagnosticDisplayRow("Approval Result", stageOperatorApproval?.state.rawValue ?? "not recorded"),
            StageDiagnosticDisplayRow("Approval Eligible", stageOperatorApproval.map { $0.approvalEligible ? "true" : "false" } ?? "not recorded"),
            StageDiagnosticDisplayRow("Approval Checked", formattedDate(stageOperatorApprovalCheckedAt)),
            StageDiagnosticDisplayRow("Approved Scope", stageOperatorApproval?.approvedScope.description ?? "none"),
            StageDiagnosticDisplayRow("Approved At", formattedDate(stageOperatorApproval?.approvalTimestamp)),
            StageDiagnosticDisplayRow("Approval Expires", formattedDate(stageOperatorApproval?.expirationTimestamp)),
            StageDiagnosticDisplayRow("Approval Freshness", stageOperatorApproval.map { $0.staleApproval ? "stale" : "fresh" } ?? "not recorded"),
            StageDiagnosticDisplayRow("Approval Blocker", stageOperatorApproval?.approvalBlockedReason ?? "none"),
            StageDiagnosticDisplayRow("Next Action", stageOperatorApproval?.nextRecommendedAction ?? "none"),
            StageDiagnosticDisplayRow("Clear Result", stageOperatorApprovalClearReason ?? "not run")
        ]
        let packageValidationReportAvailable = stagePackageValidationReport?.combinedReportText.isEmpty == false
        let reportDisplaySource: String
        let reportDisplayText: String?
        if let actionPipelineReportText, !actionPipelineReportText.isEmpty {
            reportDisplaySource = "action_result"
            reportDisplayText = actionPipelineReportText
        } else if !storedPipelineReportText.isEmpty {
            reportDisplaySource = "stored_diagnostics"
            reportDisplayText = storedPipelineReportText
        } else {
            reportDisplaySource = "none"
            reportDisplayText = nil
        }

        return List {
            Section("Supabase Target") {
                diagnosticRow("URL", appState.supabaseConfiguration.sanitizedURLDisplay)
                diagnosticRow("Target", appState.supabaseConfiguration.targetClassification.rawValue)
                diagnosticRow("Override Active", appState.supabaseConfiguration.isOverrideActive ? "true" : "false")
                diagnosticRow("Config Source", appState.supabaseConfiguration.source.rawValue)
                diagnosticRow("Anon Key", appState.supabaseConfiguration.redactedAnonKeyDisplay)
                diagnosticRow("Snapshot Flag Env", stageSessionSnapshotEnvironmentFlagDetected ? "detected" : "not detected")
                diagnosticRow("Production Validation Allowed", appState.supabaseConfiguration.productionSnapshotValidationAllowed ? "true" : "false")
                diagnosticRow("Manual Only", appState.supabaseConfiguration.isProductionSnapshotValidationManualOnly ? "true" : "false")
                diagnosticRow("Snapshot Override Allowed", appState.supabaseConfiguration.isSessionSnapshotShadowWriteOverrideAllowed ? "true" : "false")
                diagnosticRow("Production Hydration Gate", appState.supabaseConfiguration.productionSnapshotHydrationAllowed ? "true" : "false")
            }

            StageSessionSnapshotUploadSummarySection(
                rows: sessionSnapshotUploadRows,
                uploadError: sessionSnapshotUploadError,
                reportText: {
                    AppState.sessionSnapshotUploadReportText(snapshotDiagnostics)
                }
            )

            Section("Snapshot Upload Details") {
                DisclosureGroup(isExpanded: $isStageSnapshotUploadDetailsExpanded) {
                    Text("Automatic upload guard display only. Expanding this disclosure does not upload, validate, query Supabase, load packages, repair local state, hydrate metadata, retrieve media, or run recovery checks.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    diagnosticRow("Auto Flag Enabled", appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled ? "true" : "false")
                    diagnosticRow("Kill Switch Active", appState.backendFeatureFlags.sessionSnapshotAutoUploadKillSwitch ? "true" : "false")
                    diagnosticRow("Allowlist Match", snapshotDiagnostics.autoUploadAllowlistMatch ? "true" : "false")
                    diagnosticRow("Skipped Reason", snapshotDiagnostics.autoUploadSkippedReason ?? "none")
                    diagnosticRow("Trigger Source", snapshotDiagnostics.autoUploadTriggerSource ?? "none")
                    diagnosticRow("Last Auto Attempt", formattedRunDate(snapshotDiagnostics.lastAutoAttemptAt))
                    diagnosticRow("Last Auto Success", formattedRunDate(snapshotDiagnostics.lastAutoSuccessAt))
                    diagnosticRow("Last Auto Failure", formattedRunDate(snapshotDiagnostics.lastAutoFailureAt))
                    diagnosticRow("Last Auto Outcome", snapshotDiagnostics.lastAutoUploadOutcome)

                    StageTestSessionCreationSummaryView(
                        isAvailable: testSessionCreationAvailability.isAvailable,
                        reason: testSessionCreationAvailability.reason,
                        message: stageTestSessionCreationMessage,
                        onCreate: {
                            let result = appState.createManualSessionSnapshotTestSessionForLocalDev()
                            if let sessionID = result.sessionID {
                                stageTestSessionCreationMessage = "\(result.message): \(sessionID.uuidString)"
                            } else {
                                stageTestSessionCreationMessage = result.message
                            }
                        }
                    )

                    StageAuthPreflightSummaryView(
                        checked: authPreflightCheckedDisplay,
                        appUser: authPreflightAppUserDisplay,
                        clientUser: authPreflightClientUserDisplay,
                        usersMatch: authPreflightUsersMatchDisplay,
                        payloadOrg: authPreflightPayloadOrgDisplay,
                        payloadProperty: authPreflightPayloadPropertyDisplay,
                        payloadSession: authPreflightPayloadSessionDisplay,
                        rows: authPreflightRows,
                        failure: authPreflightFailure,
                        buttonTitle: isStageRefreshingAuthPreflight ? "Checking..." : "Refresh Auth Preflight",
                        isButtonDisabled: isStageRefreshingAuthPreflight || uploadTarget == nil,
                        onRefresh: {
                            guard !isStageRefreshingAuthPreflight else { return }
                            isStageRefreshingAuthPreflight = true
                            Task {
                                _ = await appState.refreshManualSessionSnapshotAuthPreflight()
                                await MainActor.run {
                                    isStageRefreshingAuthPreflight = false
                                }
                            }
                        }
                    )
                    StageAuthRepairSummaryView(
                        rows: authRepairRows,
                        repairMessage: authRepairMessage,
                        buttonTitle: isStageRepairingLocalOrgDrift ? "Repairing..." : "Repair Selected Local Org Drift",
                        isButtonDisabled: isStageRepairingLocalOrgDrift || uploadTarget == nil,
                        onRepair: {
                            guard !isStageRepairingLocalOrgDrift else { return }
                            isStageRepairingLocalOrgDrift = true
                            Task {
                                _ = await appState.repairSelectedManualSessionSnapshotLocalOrgDrift()
                                await MainActor.run {
                                    isStageRepairingLocalOrgDrift = false
                                }
                            }
                        }
                    )
                    StageLocalOrgDriftAuditSummaryView(
                        rows: localOrgDriftAuditRows,
                        samples: localOrgDriftAuditSamples,
                        buttonTitle: isStageRunningLocalOrgDriftAudit ? "Auditing..." : "Run Local Org Drift Audit",
                        isButtonDisabled: isStageRunningLocalOrgDriftAudit,
                        onRun: {
                            guard !isStageRunningLocalOrgDriftAudit else { return }
                            isStageRunningLocalOrgDriftAudit = true
                            Task {
                                _ = await appState.runLocalOrgDriftAudit()
                                await MainActor.run {
                                    isStageRunningLocalOrgDriftAudit = false
                                }
                            }
                        }
                    )
                    StageLocalOrgDriftRepairSummaryView(
                        rows: localOrgDriftRepairRows,
                        samples: localOrgDriftRepairSamples,
                        buttonTitle: isStageRepairingConfirmedLocalOrgDrift ? "Repairing..." : "Repair Confirmed Local Org Drift",
                        isButtonDisabled: isStageRepairingConfirmedLocalOrgDrift,
                        onRepair: {
                            guard !isStageRepairingConfirmedLocalOrgDrift else { return }
                            isStageRepairingConfirmedLocalOrgDrift = true
                            Task {
                                _ = await appState.repairConfirmedLocalOrgDrift()
                                await MainActor.run {
                                    isStageRepairingConfirmedLocalOrgDrift = false
                                }
                            }
                        }
                    )
                    StageRemoteReadbackSummaryView(
                        rows: remoteReadbackRows,
                        failure: remoteReadbackFailure,
                        buttonTitle: isStageCheckingSnapshotReadback ? "Checking..." : "Check Remote Readback",
                        isButtonDisabled: isStageCheckingSnapshotReadback,
                        onCheck: {
                            guard !isStageCheckingSnapshotReadback else { return }
                            isStageCheckingSnapshotReadback = true
                            Task {
                                _ = await appState.validateLatestSessionSnapshotRemoteReadback()
                                await MainActor.run {
                                    isStageCheckingSnapshotReadback = false
                                }
                            }
                        }
                    )
                    StageRestoreDiagnosticsSummaryView(
                        rows: restoreDiagnosticsRows,
                        failure: restoreDiagnosticsFailure,
                        buttonTitle: isStageCheckingSnapshotRestoreDiagnostics ? "Checking..." : "Check Restore Diagnostics",
                        isButtonDisabled: isStageCheckingSnapshotRestoreDiagnostics,
                        onCheck: {
                            guard !isStageCheckingSnapshotRestoreDiagnostics else { return }
                            isStageCheckingSnapshotRestoreDiagnostics = true
                            Task {
                                _ = await appState.validateLatestSessionSnapshotRestoreDiagnostics()
                                await MainActor.run {
                                    isStageCheckingSnapshotRestoreDiagnostics = false
                                }
                            }
                        }
                    )
                    StageMetadataHydrationSummaryView(
                        rows: metadataHydrationRows,
                        buttonTitle: isStageHydratingSnapshotMetadata ? "Hydrating..." : "Review Metadata Hydration...",
                        isButtonDisabled: isStageHydratingSnapshotMetadata,
                        onReview: {
                            isStageShowingHydrationConfirmation = true
                        }
                    )
                    StageMediaRetrievalSummaryView(
                        rows: mediaRetrievalRows,
                        buttonTitle: isStageRetrievingSnapshotMedia ? "Retrieving..." : "Retrieve Snapshot Media Test-Only",
                        isButtonDisabled: isStageRetrievingSnapshotMedia,
                        onRetrieve: {
                            isStageShowingMediaRetrievalConfirmation = true
                        }
                    )
                    StageRecoveryCohortSummaryView(
                        rows: recoveryCohortRows,
                        buttonTitle: isStageCheckingRecoveryCohort ? "Checking..." : "Check Recovery Cohort",
                        isButtonDisabled: isStageCheckingRecoveryCohort,
                        onCheck: {
                            guard !isStageCheckingRecoveryCohort else { return }
                            isStageCheckingRecoveryCohort = true
                            Task {
                                _ = await appState.validateSnapshotRecoveryCohort()
                                await MainActor.run {
                                    isStageCheckingRecoveryCohort = false
                                }
                            }
                        }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upload Diagnostics And Repair Tools")
                            .font(.system(size: 14, weight: .semibold))
                        Text(isStageSnapshotUploadDetailsExpanded ? "Hide snapshot upload controls" : "Show snapshot upload controls")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Selected Upload Target") {
                if let uploadTarget {
                    diagnosticRow("Source", uploadTarget.source.rawValue)
                    diagnosticRow("Property Name", uploadTarget.propertyName)
                    diagnosticRow("Property ID", uploadTarget.propertyID.uuidString)
                    diagnosticRow("Session ID", uploadTarget.sessionID.uuidString)
                    diagnosticRow("Session Status", uploadTarget.sessionStatus.rawValue)
                    diagnosticRow("Session Started", formattedRunDate(uploadTarget.sessionStartedAt))
                } else {
                    diagnosticRow("Target", "none")
                    diagnosticRow("Selected Property ID", uploadTargetResolution.selectedPropertyID?.uuidString ?? "none")
                    diagnosticRow("Sessions Found", uploadTargetResolution.sessionsFoundForPropertyCount)
                    diagnosticRow("Session Index Available", uploadTargetResolution.localSessionIndexAvailable ? "true" : "false")
                    diagnosticRow("Reason", uploadTargetResolution.reason)
                }
            }

            Section("Snapshot Package Validation") {
                Text("Selected-session package validation. Opening this sheet does not load, validate, inspect, or scan packages; validation runs only after the explicit button tap.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Package Checked", formattedDate(stagePackageValidationReport?.checkedAt))
                diagnosticRow("Package Scope", "property \(stagePackageValidationReport?.targetScope.propertyID?.uuidString ?? "none"), session \(stagePackageValidationReport?.targetScope.sessionID?.uuidString ?? "none")")
                diagnosticRow("Package Parity", stagePackageValidationReport?.packageParity.state.rawValue ?? "not run")
                diagnosticRow("Package Blockers", stagePackageValidationReport.map { $0.packageParity.blockers.isEmpty ? "none" : $0.packageParity.blockers.joined(separator: ", ") } ?? "not run")
                diagnosticRow("Rollback", stagePackageValidationReport?.fullyRestoredRollback.state.rawValue ?? "not run")
                diagnosticRow("Rollback Blockers", stagePackageValidationReport.map { $0.fullyRestoredRollback.blockers.isEmpty ? "none" : $0.fullyRestoredRollback.blockers.joined(separator: ", ") } ?? "not run")
                diagnosticRow("Snapshot ID", stagePackageValidationReport?.snapshotID?.uuidString ?? "none")
                diagnosticRow("Package Evidence", stagePackageValidationReport == nil ? "not generated" : "available_in_view_state")
                diagnosticRow("Package Report Text", stagePackageValidationReport?.combinedReportText.isEmpty == false ? "available" : "none")
                StagePackageValidationReportNavigationView(
                    isReportAvailable: packageValidationReportAvailable,
                    reportText: {
                        stagePackageValidationReport?.combinedReportText ?? ""
                    }
                )
                Button(isStageRunningPackageValidation ? "Running..." : AppState.localHealthSessionSnapshotPackageValidationActionTitle) {
                    guard !isStageRunningPackageValidation else { return }
                    isStageRunningPackageValidation = true
                    Task {
                        let report = await appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
                        await MainActor.run {
                            stagePackageValidationReport = report
                            isStageRunningPackageValidation = false
                        }
                    }
                }
                .disabled(isStageRunningPackageValidation)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Manual Diagnostic Trigger") {
                Button(isStageUploadingSessionSnapshot ? "Uploading..." : "Upload Selected Session Snapshot") {
                    guard uploadAvailability.isAvailable else { return }
                    isStageUploadingSessionSnapshot = true
                    Task {
                        _ = await appState.uploadCurrentSessionSnapshotShadowWrite(
                            kind: .manual,
                            trigger: "manual_diagnostic"
                        )
                        await MainActor.run {
                            isStageUploadingSessionSnapshot = false
                        }
                    }
                }
                .disabled(!uploadAvailability.isAvailable || isStageUploadingSessionSnapshot)
                .font(.system(size: 14, weight: .semibold))
                Text(uploadAvailability.reason)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            StageLastSanitizedAttemptSection(rows: lastSanitizedAttemptRows)

            Section("Canonical Read Diagnostics") {
                Text("Display-only canonical diagnostics summary. Opening this sheet does not run diagnostics, switch reads, hydrate data, restore files, download media, or change local or remote state.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Result", snapshotDiagnostics.lastCanonicalReadDiagnosticsResult)
                diagnosticRow("Checked", formattedDate(snapshotDiagnostics.lastCanonicalReadDiagnosticsAt))
                diagnosticRow("Verified Org", snapshotDiagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID?.uuidString ?? "none")
                diagnosticRow("Property ID", snapshotDiagnostics.lastCanonicalReadDiagnosticsPropertyID?.uuidString ?? "none")
                diagnosticRow("Session ID", snapshotDiagnostics.lastCanonicalReadDiagnosticsSessionID?.uuidString ?? "none")
                diagnosticRow("Local Property", snapshotDiagnostics.lastCanonicalReadDiagnosticsLocalPropertyFound ? "true" : "false")
                diagnosticRow("Local Session", snapshotDiagnostics.lastCanonicalReadDiagnosticsLocalSessionFound ? "true" : "false")
                diagnosticRow("Remote Property", snapshotDiagnostics.lastCanonicalReadDiagnosticsRemotePropertyFound ? "true" : "false")
                diagnosticRow("Remote Session", snapshotDiagnostics.lastCanonicalReadDiagnosticsRemoteSessionFound ? "true" : "false")
                diagnosticRow("Count Parity", snapshotDiagnostics.lastCanonicalReadDiagnosticsCountParity.map { $0 ? "true" : "false" } ?? "not checked")
                diagnosticRow("Status Parity", snapshotDiagnostics.lastCanonicalReadDiagnosticsStatusParity.map { $0 ? "true" : "false" } ?? "not checked")
                diagnosticRow("Parent Org", snapshotDiagnostics.lastCanonicalReadDiagnosticsParentOrgConsistent.map { $0 ? "true" : "false" } ?? "not checked")
                diagnosticRow("Parent Property", snapshotDiagnostics.lastCanonicalReadDiagnosticsParentPropertyConsistent.map { $0 ? "true" : "false" } ?? "not checked")
                diagnosticRow("Local Shots", snapshotDiagnostics.lastCanonicalReadDiagnosticsLocalShotCount.map(String.init) ?? "none")
                diagnosticRow("Remote Shots", snapshotDiagnostics.lastCanonicalReadDiagnosticsRemoteShotCount.map(String.init) ?? "none")
                diagnosticRow("Local Issues/Obs", snapshotDiagnostics.lastCanonicalReadDiagnosticsLocalIssueObservationCount.map(String.init) ?? "none")
                diagnosticRow("Remote Issues/Obs", snapshotDiagnostics.lastCanonicalReadDiagnosticsRemoteIssueObservationCount.map(String.init) ?? "none")
                diagnosticRow("Local Guided", snapshotDiagnostics.lastCanonicalReadDiagnosticsLocalGuidedCount.map(String.init) ?? "none")
                diagnosticRow("Local Known State", formattedDate(snapshotDiagnostics.lastCanonicalReadDiagnosticsLocalKnownStateAt))
                diagnosticRow("Known State Source", snapshotDiagnostics.lastCanonicalReadDiagnosticsLocalKnownStateSource ?? "none")
                diagnosticRow("Remote Freshness Seconds", snapshotDiagnostics.lastCanonicalReadDiagnosticsRemoteFreshnessAgeSeconds.map { String(Int($0)) } ?? "unknown")
                diagnosticRow("Remote Revision", snapshotDiagnostics.lastCanonicalReadDiagnosticsRemoteRevision.map(String.init) ?? "none")
                diagnosticRow("Recommendation", snapshotDiagnostics.lastCanonicalReadDiagnosticsRecommendation)
                diagnosticRow("Blocked Reason", snapshotDiagnostics.lastCanonicalReadDiagnosticsBlockedReason ?? "none")
            }

            Section("Canonical Parity Summary") {
                diagnosticRow("Parity Gaps", snapshotDiagnostics.lastNormalizedParityGapTaxonomy.isEmpty ? "none" : snapshotDiagnostics.lastNormalizedParityGapTaxonomy.joined(separator: ", "))
                diagnosticRow("Completeness", snapshotDiagnostics.lastNormalizedParityCompleteness)
                diagnosticRow("Shadow Coverage", snapshotDiagnostics.lastRemoteShadowWriteCoverage)
                diagnosticRow("Missing Remote", snapshotDiagnostics.lastMissingRemoteEntityClassification)
                diagnosticRow("Canonical Blocked", snapshotDiagnostics.lastCanonicalReadsRemainBlocked ? "true" : "false")
                diagnosticRow("Completeness Score", String(format: "%.2f", snapshotDiagnostics.lastParityCompletenessScore))
                diagnosticRow("Shadow Score", String(format: "%.2f", snapshotDiagnostics.lastShadowWriteCoverageScore))
                diagnosticRow("Missing Child Count", "\(snapshotDiagnostics.lastMissingChildCount)")
                diagnosticRow("Replay Eligibility", snapshotDiagnostics.lastReplayEligibility)
                diagnosticRow("Backfill Eligible", snapshotDiagnostics.lastNormalizedBackfillEligible ? "true" : "false")
                diagnosticRow("Backfill Blocked", snapshotDiagnostics.lastNormalizedBackfillBlockedReason)
                diagnosticRow("Remote Newer Conflicts", "\(snapshotDiagnostics.lastNormalizedBackfillRemoteNewerConflictCount)")
                diagnosticRow("Production Backfill", snapshotDiagnostics.lastNormalizedBackfillProductionBlocked ? "blocked" : "not blocked")
            }

            StageCanonicalReadDiagnosticsActionView(
                buttonTitle: isStageCheckingCanonicalReadDiagnostics ? "Checking..." : "Check Canonical Read Diagnostics",
                isButtonDisabled: isStageCheckingCanonicalReadDiagnostics,
                rows: canonicalReadDiagnosticsActionRows,
                onCheck: {
                    guard !isStageCheckingCanonicalReadDiagnostics else { return }
                    isStageCheckingCanonicalReadDiagnostics = true
                    Task {
                        _ = await appState.runCanonicalReadDiagnosticsForSelectedSession(
                            productionValidationEvidence: stagePackageValidationReport
                        )
                        await MainActor.run {
                            isStageCheckingCanonicalReadDiagnostics = false
                        }
                    }
                }
            )

            StageFlaggedObservationReplayActionView(
                buttonTitle: isStageReplayingFlaggedObservationShadowWrites ? "Replaying..." : AppState.localHealthFlaggedObservationReplayActionTitle,
                isButtonDisabled: isStageReplayingFlaggedObservationShadowWrites,
                rows: flaggedObservationReplayRows,
                onReplay: {
                    guard !isStageReplayingFlaggedObservationShadowWrites else { return }
                    isStageReplayingFlaggedObservationShadowWrites = true
                    Task {
                        let result = await appState.replayFlaggedObservationShadowWritesForSelectedSession(
                            productionValidationEvidence: stagePackageValidationReport
                        )
                        await MainActor.run {
                            stageFlaggedObservationReplayActionResult = result
                            isStageReplayingFlaggedObservationShadowWrites = false
                        }
                    }
                }
            )

            StageOperatorApprovalActionView(
                recordButtonTitle: isStageRecordingOperatorApproval ? "Recording..." : "Record Fresh Operator Approval",
                clearButtonTitle: isStageClearingOperatorApproval ? "Clearing..." : "Clear Operator Approval",
                isRecordDisabled: isStageRecordingOperatorApproval,
                isClearDisabled: isStageClearingOperatorApproval || stageOperatorApproval == nil,
                rows: operatorApprovalRows,
                onRecord: {
                    guard !isStageRecordingOperatorApproval else { return }
                    isStageRecordingOperatorApproval = true
                    Task {
                        let checkedAt = Date()
                        let approval = await MainActor.run {
                            appState.makeProductionSingleSessionOperatorApprovalForSelectedSession(approvedAt: checkedAt)
                        }
                        await MainActor.run {
                            stageOperatorApproval = approval
                            stageOperatorApprovalCheckedAt = checkedAt
                            stageOperatorApprovalClearReason = nil
                            isStageRecordingOperatorApproval = false
                        }
                    }
                },
                onClear: {
                    guard !isStageClearingOperatorApproval, stageOperatorApproval != nil else { return }
                    isStageClearingOperatorApproval = true
                    stageOperatorApproval = nil
                    stageOperatorApprovalCheckedAt = nil
                    stageOperatorApprovalClearReason = "operator_approval_cleared"
                    isStageClearingOperatorApproval = false
                }
            )

            StageCanonicalRolloutReportNavigationView {
                AppState.canonicalReadRolloutReportText(
                    snapshotDiagnostics,
                    operatorApproval: stageOperatorApproval,
                    singleSessionActivationGatePolicy: AppState.loadProductionSingleSessionActivationGatePolicy()
                )
            }

            Section("Selected Session Overlay") {
                Text("Selected-session overlay controls. Opening this sheet does not build overlays, activate overlays, switch reads, enable broad reads, authorize QA, validate packages, run the pipeline, replay lifecycle data, or mutate hosted data; overlay building runs only after the explicit button tap.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Stage Package Evidence", stagePackageEvidenceReady ? "ready" : "not ready")
                diagnosticRow("Stage QA Authorization", snapshotDiagnostics.runtimeSelectedSessionQAAuthAuthorized ? "authorized" : "not authorized")
                diagnosticRow("Overlay Built", snapshotDiagnostics.lastCanonicalCandidateOverlayBuilt ? "true" : "false")
                diagnosticRow("Overlay Allowed", snapshotDiagnostics.lastCanonicalCandidateOverlayAllowed ? "true" : "false")
                diagnosticRow("Overlay Blocked", snapshotDiagnostics.lastCanonicalCandidateOverlayBlockedReason)
                diagnosticRow("Overlay Source", snapshotDiagnostics.lastCanonicalCandidateOverlaySource)
                diagnosticRow("Overlay Property", snapshotDiagnostics.lastCanonicalCandidateOverlayPropertyID?.uuidString ?? "none")
                diagnosticRow("Overlay Session", snapshotDiagnostics.lastCanonicalCandidateOverlaySessionID?.uuidString ?? "none")
                diagnosticRow("Overlay Shots", "\(snapshotDiagnostics.lastCanonicalCandidateOverlayShotCount)")
                diagnosticRow("Overlay Issues", "\(snapshotDiagnostics.lastCanonicalCandidateOverlayIssueObservationCount)")
                diagnosticRow("Overlay Guided", snapshotDiagnostics.lastCanonicalCandidateOverlayGuidedCount.map(String.init) ?? "not represented")
                diagnosticRow("Overlay Fallback", snapshotDiagnostics.lastCanonicalCandidateOverlayFallbackSource)
                diagnosticRow("Overlay Active Source", snapshotDiagnostics.lastCanonicalCandidateOverlayActiveSource)
                diagnosticRow("Overlay Rollback", snapshotDiagnostics.lastCanonicalCandidateOverlayRollbackAvailable ? "available" : "missing")
                diagnosticRow("Overlay Production", snapshotDiagnostics.lastCanonicalCandidateOverlayProductionBlocked ? "blocked" : "not blocked")
                diagnosticRow("Candidate Match", snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonResult)
                diagnosticRow("Comparison Local Status", snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonLocalStatus)
                diagnosticRow("Comparison Candidate Status", snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonRemoteStatus)
                diagnosticRow("Comparison Local Counts", "shots \(snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonLocalShotCount.map(String.init) ?? "none"), issues \(snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonLocalIssueObservationCount.map(String.init) ?? "none")")
                diagnosticRow("Comparison Candidate Counts", "shots \(snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonRemoteShotCount.map(String.init) ?? "none"), issues \(snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonRemoteIssueObservationCount.map(String.init) ?? "none")")
                diagnosticRow("Comparison Freshness", "local \(snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonLocalFreshness), candidate \(snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonRemoteFreshness)")
                diagnosticRow("Comparison Trusted", snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonTrustedReason)
                diagnosticRow("Comparison Blocked", snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonBlockedReason)
                diagnosticRow("Overlay Action Result", stageCanonicalCandidateOverlayBuildResult.map { $0.allowed ? "allowed" : "blocked" } ?? "not run")
                diagnosticRow("Overlay Action Checked", formattedDate(stageCanonicalCandidateOverlayBuildResult?.checkedAt))
                diagnosticRow("Overlay Action Blocker", stageCanonicalCandidateOverlayBuildResult?.blockedReason ?? "none")
                diagnosticRow("Overlay Action Source", stageCanonicalCandidateOverlayBuildResult?.overlay?.source ?? "none")
                diagnosticRow("Overlay Action Scope", "property \(stageCanonicalCandidateOverlayBuildResult?.overlay?.propertyID?.uuidString ?? "none"), session \(stageCanonicalCandidateOverlayBuildResult?.overlay?.sessionID?.uuidString ?? "none")")
                diagnosticRow("Overlay Action Fallback", stageCanonicalCandidateOverlayBuildResult.map { $0.localFallbackRetained ? "retained" : "missing" } ?? "not run")
                diagnosticRow("Overlay Action Active Source", stageCanonicalCandidateOverlayBuildResult.map { $0.activeSourceRemainsLocal ? "local" : "not local" } ?? "not run")
                diagnosticRow("Overlay Action Rollback", stageCanonicalCandidateOverlayBuildResult.map { $0.rollbackAvailable ? "available" : "missing" } ?? "not run")
                diagnosticRow("Overlay Action Production", stageCanonicalCandidateOverlayBuildResult.map { $0.productionBlocked ? "blocked" : "not blocked" } ?? "not run")
                Button(isStageBuildingCanonicalCandidateOverlay ? "Building..." : "Build Canonical Candidate Overlay") {
                    guard !isStageBuildingCanonicalCandidateOverlay else { return }
                    isStageBuildingCanonicalCandidateOverlay = true
                    Task {
                        let result = await appState.buildCanonicalCandidateOverlayForSelectedSession(
                            productionValidationEvidence: stagePackageValidationReport
                        )
                        await MainActor.run {
                            stageCanonicalCandidateOverlayBuildResult = result
                            isStageBuildingCanonicalCandidateOverlay = false
                        }
                    }
                }
                .disabled(isStageBuildingCanonicalCandidateOverlay)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Selected Session Activation") {
                Text("Selected-session activation controls. Opening this sheet does not activate candidates, switch reads, enable broad reads, build overlays, authorize QA, validate packages, run the pipeline, replay lifecycle data, or mutate hosted production data; activation or rollback runs only after an explicit button tap.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Activation Package Evidence", stagePackageEvidenceReady ? "ready" : "not ready")
                diagnosticRow("Activation QA Authorization", snapshotDiagnostics.runtimeSelectedSessionQAAuthAuthorized ? "authorized" : "not authorized")
                diagnosticRow("Activation Pipeline State", snapshotDiagnostics.lastSelectedSessionValidationPipelineState)
                diagnosticRow("Activation Overlay Built", snapshotDiagnostics.lastCanonicalCandidateOverlayBuilt ? "true" : "false")
                diagnosticRow("Activation Overlay Allowed", snapshotDiagnostics.lastCanonicalCandidateOverlayAllowed ? "true" : "false")
                diagnosticRow("Activation Candidate Match", snapshotDiagnostics.lastCanonicalCandidateOverlayComparisonResult)
                diagnosticRow("Activation Allowed", snapshotDiagnostics.lastCanonicalCandidateActivationAllowed ? "true" : "false")
                diagnosticRow("Activation Blocked", snapshotDiagnostics.lastCanonicalCandidateActivationBlockedReason)
                diagnosticRow("Activation Active Source", snapshotDiagnostics.lastCanonicalCandidateActivationActiveSource)
                diagnosticRow("Activation Rollback Source", snapshotDiagnostics.lastCanonicalCandidateActivationRollbackSource)
                diagnosticRow("Activation Scope", snapshotDiagnostics.lastCanonicalCandidateActivationScope)
                diagnosticRow("Activation Property", snapshotDiagnostics.lastCanonicalCandidateActivationPropertyID?.uuidString ?? "none")
                diagnosticRow("Activation Session", snapshotDiagnostics.lastCanonicalCandidateActivationSessionID?.uuidString ?? "none")
                diagnosticRow("Activation Rollback", snapshotDiagnostics.lastCanonicalCandidateActivationRollbackAvailable ? "available" : "missing")
                diagnosticRow("Activation Last Activated", formattedDate(snapshotDiagnostics.lastCanonicalCandidateActivationLastActivatedAt))
                diagnosticRow("Activation Last Rolled Back", formattedDate(snapshotDiagnostics.lastCanonicalCandidateActivationLastRolledBackAt))
                diagnosticRow("Activation Production", snapshotDiagnostics.lastCanonicalCandidateActivationProductionBlocked ? "blocked" : "not blocked")
                diagnosticRow("Activation Result", stageCanonicalCandidateActivationResult.map { $0.allowed ? "allowed" : "blocked" } ?? "not run")
                diagnosticRow("Activation Result Checked", formattedDate(stageCanonicalCandidateActivationResult?.checkedAt))
                diagnosticRow("Activation Result Blocker", stageCanonicalCandidateActivationResult?.blockedReason ?? "none")
                diagnosticRow("Activation Result Source", stageCanonicalCandidateActivationResult?.activeSource.rawValue ?? "not run")
                diagnosticRow("Activation Result Rollback Source", stageCanonicalCandidateActivationResult?.rollbackSource.rawValue ?? "not run")
                diagnosticRow("Activation Result Scope", stageCanonicalCandidateActivationResult?.activationScope ?? "not run")
                diagnosticRow("Activation Result Property", stageCanonicalCandidateActivationResult?.propertyID?.uuidString ?? "none")
                diagnosticRow("Activation Result Session", stageCanonicalCandidateActivationResult?.sessionID?.uuidString ?? "none")
                diagnosticRow("Activation Result Fallback", stageCanonicalCandidateActivationResult.map { $0.rollbackAvailable ? "available" : "missing" } ?? "not run")
                diagnosticRow("Activation Result Production", stageCanonicalCandidateActivationResult.map { $0.productionBlocked ? "blocked" : "not blocked" } ?? "not run")
                diagnosticRow("Rollback Result", stageCanonicalCandidateRollbackResult.map { $0.allowed ? "allowed" : "blocked" } ?? "not run")
                diagnosticRow("Rollback Result Checked", formattedDate(stageCanonicalCandidateRollbackResult?.checkedAt))
                diagnosticRow("Rollback Result Blocker", stageCanonicalCandidateRollbackResult?.blockedReason ?? "none")
                diagnosticRow("Rollback Result Source", stageCanonicalCandidateRollbackResult?.activeSource.rawValue ?? "not run")
                diagnosticRow("Rollback Result Fallback", stageCanonicalCandidateRollbackResult.map { $0.rollbackAvailable ? "available" : "missing" } ?? "not run")
                Button(isStageActivatingCanonicalCandidate ? "Activating..." : "Activate Canonical Candidate For Session") {
                    guard !isStageActivatingCanonicalCandidate else { return }
                    isStageShowingCanonicalCandidateActivationConfirmation = true
                }
                .disabled(isStageActivatingCanonicalCandidate)
                .font(.system(size: 14, weight: .semibold))
                .alert("Activate Canonical Candidate?", isPresented: $isStageShowingCanonicalCandidateActivationConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Activate") {
                        guard !isStageActivatingCanonicalCandidate else { return }
                        isStageActivatingCanonicalCandidate = true
                        Task {
                            let result = await MainActor.run {
                                appState.activateCanonicalCandidateForSelectedSession(operatorApproval: nil)
                            }
                            await MainActor.run {
                                stageCanonicalCandidateActivationResult = result
                                isStageActivatingCanonicalCandidate = false
                            }
                        }
                    }
                } message: {
                    Text("Selected session only. Active read source changes to the candidate overlay for this diagnostic scope, local fallback stays retained, export/seal/sync/media/iCloud behavior is unchanged, and production remains blocked.")
                }
                Button(isStageRollingBackCanonicalCandidate ? "Rolling Back..." : "Rollback To Local Source") {
                    guard !isStageRollingBackCanonicalCandidate else { return }
                    isStageRollingBackCanonicalCandidate = true
                    Task {
                        let result = await MainActor.run {
                            appState.rollbackCanonicalCandidateToLocalSource()
                        }
                        await MainActor.run {
                            stageCanonicalCandidateRollbackResult = result
                            isStageRollingBackCanonicalCandidate = false
                        }
                    }
                }
                .disabled(isStageRollingBackCanonicalCandidate)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Runtime QA Authorization") {
                Text("Display-only selected-session QA authorization summary. Opening this sheet does not authorize, clear, refresh, run validation, switch reads, approve, or activate anything.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("QA Authorization", snapshotDiagnostics.runtimeSelectedSessionQAAuthAuthorized ? "authorized" : "not authorized")
                diagnosticRow("QA Authorized Org", snapshotDiagnostics.runtimeSelectedSessionQAAuthOrgID?.uuidString ?? "none")
                diagnosticRow("QA Authorized Property", snapshotDiagnostics.runtimeSelectedSessionQAAuthPropertyID?.uuidString ?? "none")
                diagnosticRow("QA Authorized Session", snapshotDiagnostics.runtimeSelectedSessionQAAuthSessionID?.uuidString ?? "none")
                diagnosticRow("QA Authorized At", formattedDate(snapshotDiagnostics.runtimeSelectedSessionQAAuthAuthorizedAt))
                diagnosticRow("QA Expires", formattedDate(snapshotDiagnostics.runtimeSelectedSessionQAAuthExpiresAt))
                diagnosticRow("QA Freshness", snapshotDiagnostics.runtimeSelectedSessionQAAuthFreshness)
                diagnosticRow("QA Scope Match", snapshotDiagnostics.runtimeSelectedSessionQAAuthScopeMatches ? "true" : "false")
                diagnosticRow("QA Clear Reason", snapshotDiagnostics.runtimeSelectedSessionQAAuthClearReason ?? "none")
                diagnosticRow("QA Controls", qaControlsPresentation.controlsMounted ? "available" : "blocked")
                diagnosticRow("QA Controls Blocker", qaControlsPresentation.blocker ?? "none")
                diagnosticRow("QA Selected Property", qaControlsPresentation.selectedPropertyID?.uuidString ?? "none")
                diagnosticRow("QA Selected Session", qaControlsPresentation.selectedSessionID?.uuidString ?? "none")
                diagnosticRow("QA Target Reason", qaControlsPresentation.targetResolutionReason)
                diagnosticRow("Package Evidence Ready", stagePackageEvidenceReady ? "true" : "false")
                diagnosticRow("QA Action Result", stageSelectedSessionQAAuthorizationResult?.state.rawValue ?? "not run")
                diagnosticRow("QA Action Checked", formattedDate(stageSelectedSessionQAAuthorizationResult?.checkedAt))
                diagnosticRow("QA Action Selected Scope", stageSelectedSessionQAAuthorizationResult?.selectedScope.description ?? "none")
                diagnosticRow("QA Action Authorized Scope", stageSelectedSessionQAAuthorizationResult?.authorizedScope.description ?? "none")
                diagnosticRow("QA Action Authorized At", formattedDate(stageSelectedSessionQAAuthorizationResult?.authorizedAt))
                diagnosticRow("QA Action Expires", formattedDate(stageSelectedSessionQAAuthorizationResult?.expiresAt))
                diagnosticRow("QA Action Freshness", stageSelectedSessionQAAuthorizationResult?.freshness ?? "not run")
                diagnosticRow("QA Action Scope Match", stageSelectedSessionQAAuthorizationResult.map { $0.scopeMatches ? "true" : "false" } ?? "not run")
                diagnosticRow("QA Action Clear Reason", stageSelectedSessionQAAuthorizationResult?.clearReason ?? "none")
                diagnosticRow("QA Action Supabase Reads", stageSelectedSessionQAAuthorizationResult.map { $0.supabaseReadEnabled ? "enabled" : "disabled" } ?? "not run")
                diagnosticRow("QA Action Broad Reads", stageSelectedSessionQAAuthorizationResult.map { $0.productionWideCanonicalReadsEnabled ? "enabled" : "disabled" } ?? "not run")
                diagnosticRow("QA Action Local Fallback", stageSelectedSessionQAAuthorizationResult.map { $0.localFallbackAvailable ? "available" : "missing" } ?? "not run")
                diagnosticRow("QA Action Rollback", stageSelectedSessionQAAuthorizationResult.map { $0.rollbackAvailable ? "available" : "missing" } ?? "not run")
                Button(isStageAuthorizingSelectedSessionQA ? "Authorizing..." : AppState.localHealthAuthorizeSelectedSessionQAActionTitle) {
                    guard qaControlsPresentation.controlsMounted, !isStageAuthorizingSelectedSessionQA else { return }
                    isStageAuthorizingSelectedSessionQA = true
                    Task {
                        let result = await MainActor.run {
                            appState.authorizeSelectedSessionForQAValidation()
                        }
                        await MainActor.run {
                            stageSelectedSessionQAAuthorizationResult = result
                            isStageAuthorizingSelectedSessionQA = false
                        }
                    }
                }
                .disabled(!qaControlsPresentation.controlsMounted || isStageAuthorizingSelectedSessionQA)
                .font(.system(size: 14, weight: .semibold))
                Button(isStageClearingSelectedSessionQA ? "Clearing..." : AppState.localHealthClearSelectedSessionQAActionTitle) {
                    guard snapshotDiagnostics.runtimeSelectedSessionQAAuthAuthorized, !isStageClearingSelectedSessionQA else { return }
                    isStageClearingSelectedSessionQA = true
                    Task {
                        let result = await MainActor.run {
                            appState.clearSelectedSessionQAValidationAuthorization()
                        }
                        await MainActor.run {
                            stageSelectedSessionQAAuthorizationResult = result
                            isStageClearingSelectedSessionQA = false
                        }
                    }
                }
                .disabled(!snapshotDiagnostics.runtimeSelectedSessionQAAuthAuthorized || isStageClearingSelectedSessionQA)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Selected Session Validation Pipeline") {
                Text("Selected-session validation pipeline controls. Opening this sheet does not start, resume, retry, cancel, reset, or report on the pipeline; the pipeline runs only after the explicit button tap.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Pipeline State", snapshotDiagnostics.lastSelectedSessionValidationPipelineState)
                diagnosticRow("Pipeline Checked", formattedDate(snapshotDiagnostics.lastSelectedSessionValidationPipelineCheckedAt))
                diagnosticRow("Pipeline Blocker", snapshotDiagnostics.lastSelectedSessionValidationPipelineBlocker ?? "none")
                diagnosticRow("Pipeline Report", snapshotDiagnostics.lastSelectedSessionValidationPipelineReportText.isEmpty ? "none" : "available")
                diagnosticRow("Pipeline Result", stageSelectedSessionValidationPipelineReport?.state.rawValue ?? "not run")
                diagnosticRow("Pipeline Final Blocker", stageSelectedSessionValidationPipelineReport?.finalBlocker ?? "none")
                diagnosticRow("Pipeline Next Action", stageSelectedSessionValidationPipelineReport?.recommendedNextAction ?? "unknown")
                diagnosticRow("Pipeline Button Availability", pipelineControlsAvailable ? "available" : "blocked")
                diagnosticRow("Pipeline Button Blocker", pipelineControlsAvailable ? "none" : (qaControlsPresentation.blocker ?? "selected_session_required"))
                StageValidationPipelineReportNavigationView(
                    isReportAvailable: reportDisplayText?.isEmpty == false,
                    reportText: {
                        reportDisplayText ?? ""
                    }
                )
                Button(isStageRunningSelectedSessionValidationPipeline ? "Running..." : AppState.localHealthSelectedSessionValidationPipelineActionTitle) {
                    guard pipelineControlsAvailable, !isStageRunningSelectedSessionValidationPipeline else { return }
                    isStageRunningSelectedSessionValidationPipeline = true
                    Task {
                        let report = await appState.runSelectedSessionValidationPipeline()
                        await MainActor.run {
                            stageSelectedSessionValidationPipelineReport = report
                            isStageRunningSelectedSessionValidationPipeline = false
                        }
                    }
                }
                .disabled(!pipelineControlsAvailable || isStageRunningSelectedSessionValidationPipeline)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Selected Session Lifecycle Replay") {
                Text("Selected-session lifecycle replay controls. Opening this sheet does not run replay, validate packages, authorize QA, start the pipeline, switch reads, activate overlays, or mutate hosted data; replay runs only after the explicit button tap.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Lifecycle Button Availability", lifecycleReplayTargetAvailable ? "available_for_guarded_action" : "blocked")
                diagnosticRow("Lifecycle Guard Preview", lifecycleReplayGuardPreview)
                diagnosticRow("Lifecycle Package Evidence", "not available in isolated stage")
                diagnosticRow("Lifecycle Stored Planned", "\(snapshotDiagnostics.lastNormalizedBackfillPlannedSessionUpserts)")
                diagnosticRow("Lifecycle Stored Executed", "\(snapshotDiagnostics.lastNormalizedBackfillExecutedEntityCount)")
                diagnosticRow("Lifecycle Stored Skipped", "\(snapshotDiagnostics.lastNormalizedBackfillSkippedEntityCount)")
                diagnosticRow("Lifecycle Stored Remote Newer", "\(snapshotDiagnostics.lastNormalizedBackfillRemoteNewerConflictCount)")
                diagnosticRow("Lifecycle Stored Production", snapshotDiagnostics.lastNormalizedBackfillProductionBlocked ? "blocked" : "not blocked")
                Button(isStageReplayingSelectedSessionLifecycleShadowWrite ? "Replaying..." : AppState.localHealthSelectedSessionLifecycleReplayActionTitle) {
                    guard !lifecycleReplayButtonDisabled else { return }
                    isStageReplayingSelectedSessionLifecycleShadowWrite = true
                    Task {
                        let result = await appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
                            productionValidationEvidence: nil
                        )
                        await MainActor.run {
                            stageSelectedSessionLifecycleReplayResult = result
                            isStageReplayingSelectedSessionLifecycleShadowWrite = false
                        }
                    }
                }
                .disabled(lifecycleReplayButtonDisabled)
                .font(.system(size: 14, weight: .semibold))
                diagnosticRow("Lifecycle Replay Action", stageSelectedSessionLifecycleReplayResult.map { $0.allowed ? "allowed" : "blocked" } ?? "not run")
                diagnosticRow("Lifecycle Replay Blocked", stageSelectedSessionLifecycleReplayResult?.blockedReason ?? "none")
                diagnosticRow("Lifecycle Replay Scope", "property \(stageSelectedSessionLifecycleReplayResult?.propertyID?.uuidString ?? "none"), session \(stageSelectedSessionLifecycleReplayResult?.sessionID?.uuidString ?? "none")")
                diagnosticRow("Lifecycle Checked", formattedDate(stageSelectedSessionLifecycleReplayResult?.checkedAt))
                diagnosticRow("Lifecycle Planned", stageSelectedSessionLifecycleReplayResult?.replayResult.map { "\($0.attemptedCount)" } ?? "not run")
                diagnosticRow("Lifecycle Executed", stageSelectedSessionLifecycleReplayResult?.replayResult.map { "\($0.upsertedCount)" } ?? "not run")
                diagnosticRow("Lifecycle Skipped", stageSelectedSessionLifecycleReplayResult?.replayResult.map { "\($0.skippedCount)" } ?? "not run")
                diagnosticRow("Lifecycle Remote Newer", stageSelectedSessionLifecycleReplayResult?.replayResult.map { "\($0.remoteNewerConflictCount)" } ?? "not run")
                diagnosticRow("Lifecycle Failed", stageSelectedSessionLifecycleReplayResult?.replayResult.map { "\($0.failedCount)" } ?? "not run")
                diagnosticRow("Lifecycle Result", stageSelectedSessionLifecycleReplayResult?.replayResult?.message ?? "not run")
                diagnosticRow("Lifecycle Post-Replay Diagnostics", stageSelectedSessionLifecycleReplayResult?.diagnosticsAfterReplay == nil ? "not run" : "refreshed")
            }

            Section("Validation Pipeline Report Display") {
                Text("Display-only selected-session validation pipeline report summary and plain text. Opening this sheet does not generate, refresh, copy, export, share, render, preview, load, or save reports.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Stored Report", storedPipelineReportText.isEmpty ? "none" : "available")
                diagnosticRow("Stored Report State", snapshotDiagnostics.lastSelectedSessionValidationPipelineState)
                diagnosticRow("Stored Report Checked", formattedDate(snapshotDiagnostics.lastSelectedSessionValidationPipelineCheckedAt))
                diagnosticRow("Stored Report Blocker", snapshotDiagnostics.lastSelectedSessionValidationPipelineBlocker ?? "none")
                diagnosticRow("Action Report", actionPipelineReportText?.isEmpty == false ? "available" : "none")
                diagnosticRow("Action Report State", stageSelectedSessionValidationPipelineReport?.state.rawValue ?? "not run")
                diagnosticRow("Action Report Checked", formattedDate(stageSelectedSessionValidationPipelineReport?.checkedAt))
                diagnosticRow("Action Report Blocker", stageSelectedSessionValidationPipelineReport?.finalBlocker ?? "none")
                diagnosticRow("Report Text Source", reportDisplaySource)
                diagnosticRow("Report Text Characters", reportDisplayText.map { "\($0.count)" } ?? "0")
                Text(reportDisplayText ?? "none")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(reportDisplayText == nil ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Snapshot Upload")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Hydrate Metadata From Snapshot?", isPresented: $isStageShowingHydrationConfirmation) {
            Button("Cancel", role: .cancel) {}
            if hydrationConfirmation.canHydrate {
                Button("Hydrate Local Metadata Only", role: .destructive) {
                    guard !isStageHydratingSnapshotMetadata else { return }
                    isStageHydratingSnapshotMetadata = true
                    Task {
                        _ = await appState.hydrateMetadataFromLatestSessionSnapshot()
                        await MainActor.run {
                            isStageHydratingSnapshotMetadata = false
                        }
                    }
                }
            }
        } message: {
            Text(hydrationConfirmation.messageText)
        }
        .alert("Retrieve Snapshot Media Test-Only?", isPresented: $isStageShowingMediaRetrievalConfirmation) {
            Button("Cancel", role: .cancel) {}
            if mediaRetrievalConfirmation.canRetrieve {
                Button("Retrieve Test Media", role: .destructive) {
                    guard !isStageRetrievingSnapshotMedia else { return }
                    isStageRetrievingSnapshotMedia = true
                    Task {
                        _ = await appState.retrieveSnapshotMediaTestOnly()
                        await MainActor.run {
                            isStageRetrievingSnapshotMedia = false
                        }
                    }
                }
            }
        } message: {
            Text(mediaRetrievalConfirmation.messageText)
        }
    }

    private var offlineQueuePage: some View {
        List {
            Section("Offline Replay Last Run") {
                diagnosticRow("Discovered", diagnostics.offlineReplay.discoveredCount)
                diagnosticRow("Attempted", diagnostics.offlineReplay.attemptedCount)
                diagnosticRow("Succeeded", diagnostics.offlineReplay.succeededCount)
                diagnosticRow("Failed Attempts", diagnostics.offlineReplay.failedCount)
                diagnosticRow("Skipped Backoff", diagnostics.offlineReplay.skippedBackoffCount)
                diagnosticRow("Normalized In-Flight", diagnostics.offlineReplay.normalizedInFlightCount)
                diagnosticRow("Last Run", formattedRunDate(diagnostics.offlineReplay.lastRunAt))
            }

            Section("Offline Queue") {
                diagnosticRow("Total", diagnostics.offlineQueue.totalQueued)
                diagnosticRow("Pending", diagnostics.offlineQueue.pendingCount)
                diagnosticRow("Retryable Failed Items", diagnostics.offlineQueue.failedCount)
                diagnosticRow("Acknowledged Historical Queue Debt", diagnostics.offlineQueue.acknowledgedHistoricalCount)
                diagnosticRow("Oldest Failure Age", formattedAge(diagnostics.offlineQueue.oldestFailureAgeSeconds))
                diagnosticRow("Refreshed", formattedRunDate(diagnostics.offlineQueue.refreshedAt))
                NavigationLink {
                    DebugOfflineQueueItemsView(items: failedQueueItems) {
                        refreshDiagnosticDetailSnapshots()
                        syncDebtSnapshot = nil
                    }
                } label: {
                    diagnosticNavigationLabel("Failed Queue Items", count: failedQueueItems.count)
                }
            }
        }
        .navigationTitle("Offline Queue")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var canonicalReadinessPage: some View {
        List {
            Section("Canonical Readiness") {
                Text("Read-only Phase C readiness panel. It does not switch canonical reads, change flags, hydrate sessions, retry queues, download media, change exports, change sync, or reduce iCloud fallback.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let snapshot = canonicalReadinessSnapshot {
                    diagnosticRow("Inspected", snapshot.inspectedAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow("Overall Status", snapshot.overallStatus)
                    NavigationLink {
                        DebugCanonicalReadinessSnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Readiness Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No canonical readiness snapshot has been generated in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = canonicalReadinessSnapshot {
                ForEach(snapshot.sections) { section in
                    Section(section.title) {
                        diagnosticRow("Status", section.status.rawValue)
                        Text(section.summary)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(section.rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(row.label)
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer(minLength: 12)
                                    Text("\(row.status.rawValue): \(row.value)")
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.trailing)
                                        .textSelection(.enabled)
                                }
                                Text(row.detail)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .navigationTitle("Canonical Readiness")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var completenessGatesPage: some View {
        List {
            Section("Completeness Gates") {
                Text("Read-only local completeness diagnostics. It does not enforce gates, block export or sealing, change history visibility, switch canonical reads, hydrate sessions, download media, alter sync, media recovery, iCloud fallback, migrations, RLS, or data.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let snapshot = completenessGatesSnapshot {
                    diagnosticRow("Inspected", snapshot.inspectedAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow("Export Complete Sessions", snapshot.exportCompleteSessionCount)
                    diagnosticRow("Not Export Complete Sessions", snapshot.notExportCompleteSessionCount)
                    diagnosticRow("Diagnostic-Only Rows", snapshot.diagnosticOnlyRowCount)
                    NavigationLink {
                        DebugCompletenessGatesSnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Completeness Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No completeness gates snapshot has been generated in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = completenessGatesSnapshot {
                completenessCountsSection("Properties", snapshot.propertyCounts)
                completenessCountsSection("Sessions", snapshot.sessionCounts)
                completenessCountsSection("Shots", snapshot.shotCounts)
                completenessCountsSection("Issues", snapshot.issueCounts)
                completenessCountsSection("Guided Rows", snapshot.guidedCounts)
                completenessCountsSection("Media", snapshot.mediaCounts)
                Section("Freshness") {
                    ForEach(snapshot.freshnessCounts) { count in
                        diagnosticRow(count.state.rawValue, count.count)
                    }
                }
            }
        }
        .navigationTitle("Completeness")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sessionSnapshotPreviewPage: some View {
        List {
            Section("Session Snapshot Preview") {
                Text("Read-only local-only session.json snapshot preview. It does not upload snapshots, change schema or RLS, switch canonical reads, hydrate sessions, download media, relink files, repair data, change export, sealing, sync, media recovery, or iCloud fallback.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let snapshot = sessionSnapshotPreviewSnapshot {
                    diagnosticRow("Inspected", snapshot.inspectedAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow("Sessions Inspected", snapshot.sessionsInspected)
                    diagnosticRow("Previewable Sessions", snapshot.previewableSessions)
                    diagnosticRow("Missing / Unreadable session.json", snapshot.missingOrUnreadableSessionJSONCount)
                    diagnosticRow("Checksum Pass", snapshot.checksumGenerationPassCount)
                    diagnosticRow("Checksum Fail", snapshot.checksumGenerationFailCount)
                    NavigationLink {
                        DebugSessionSnapshotPreviewTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Snapshot Preview Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No session snapshot preview has been generated in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = sessionSnapshotPreviewSnapshot {
                Section("Snapshot Counts") {
                    diagnosticRow("Shots", snapshot.totalShotCount)
                    diagnosticRow("Issues", snapshot.totalIssueCount)
                    diagnosticRow("Guided Rows", snapshot.totalGuidedCount)
                    diagnosticRow("Media Manifest", snapshot.totalMediaManifestCount)
                    diagnosticRow("Missing Local Originals", snapshot.totalMissingLocalOriginalsCount)
                    diagnosticRow("Supabase Storage Metadata", snapshot.totalSupabaseStorageMetadataCount)
                }

                Section("Sanitized Rows") {
                    ForEach(snapshot.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppState.diagnosticsPreviewText(row.localPropertyName, maxLength: 80) ?? "Unnamed Property")
                                .font(.system(size: 13, weight: .semibold))
                                .textSelection(.enabled)
                            Text(row.sessionID.uuidString)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                            Text(row.isPreviewable ? "previewable" : "not previewable")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(row.isPreviewable ? Color.secondary : Color.orange)
                            if let envelope = row.envelope {
                                Text("shots \(envelope.shotCount) | issues \(envelope.issueCount) | guided \(envelope.guidedCount) | missing originals \(envelope.missingLocalOriginalsCount)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            } else if let reason = AppState.diagnosticsPreviewText(row.failureReason, maxLength: 120) {
                                Text(reason)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("Snapshot Preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var exportSealPreflightPage: some View {
        List {
            Section("Export / Seal Preflight") {
                Text(AppState.exportSealPreflightAdvisoryMessage())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let snapshot = exportSealPreflightSnapshot {
                    Text(snapshot.statusMessage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(snapshot.hardBlockCandidateRawCount == 0 ? Color.secondary : Color.orange)
                    diagnosticRow("Inspected", snapshot.inspectedAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow(AppState.ExportSealPreflightCategory.hardBlockCandidate.visibleLabel, snapshot.hardBlockCandidateCount)
                    diagnosticRow(AppState.ExportSealPreflightCategory.softWarningCandidate.visibleLabel, snapshot.softWarningCandidateCount)
                    diagnosticRow(AppState.ExportSealPreflightCategory.informationalOnly.visibleLabel, snapshot.informationalOnlyCount)
                    diagnosticRow(AppState.ExportSealPreflightCategory.unknownNeedsReview.visibleLabel, snapshot.unknownNeedsReviewCount)
                    NavigationLink {
                        DebugExportSealPreflightSnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Preflight Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No export/seal preflight snapshot has been generated in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = exportSealPreflightSnapshot {
                Section("Category Guide") {
                    ForEach(AppState.ExportSealPreflightCategory.allCases, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category.visibleLabel)
                                .font(.system(size: 14, weight: .semibold))
                            Text(category.visibleExplanation)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section("Future Enforcement Warnings") {
                    Text("Warning-only policy visibility. These warnings do not block export, re-export, sealing, or completion.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        DebugFutureEnforcementWarningsSnapshotTextView(snapshotText: snapshot.futureWarningsText)
                    } label: {
                        Text("View Copyable Warning Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    ForEach(snapshot.futureWarningGroups) { group in
                        futureEnforcementWarningGroupRow(group)
                    }
                }

                ForEach(snapshot.sections) { section in
                    Section(section.scope.title) {
                        ForEach(section.counts) { count in
                            diagnosticRow(count.category.visibleLabel, count.count)
                        }
                        if section.reasonSummaries.isEmpty {
                            Text("No grouped preflight details for this section.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(section.reasonSummaries) { summary in
                                preflightReasonSummaryRow(summary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Preflight")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func futureEnforcementWarningGroupRow(
        _ group: AppState.EnforcementWarningGroupSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(group.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                Text(String(group.count))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(group.explanation)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Status: \(group.posture.visibleLabel)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func preflightReasonSummaryRow(
        _ summary: AppState.ExportSealPreflightReasonSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(summary.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                Text(String(summary.count))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(summary.explanation)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Classification: \(summary.category.drilldownClassificationLabel)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var enforcementPolicyMatrixPage: some View {
        List {
            Section("Enforcement Policy Matrix") {
                Text("Read-only policy diagnostics. This matrix documents future enforcement posture only; it does not enforce gates, block export, block sealing, hydrate data, download media, relink files, repair data, or change sync.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if let snapshot = enforcementPolicyMatrixSnapshot {
                    diagnosticRow("Inspected", snapshot.inspectedAt)
                    diagnosticRow("Policy Rows", snapshot.rowCount)
                    NavigationLink {
                        DebugEnforcementPolicyMatrixSnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Policy Matrix")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No enforcement policy matrix snapshot has been generated in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = enforcementPolicyMatrixSnapshot {
                ForEach(snapshot.sections) { section in
                    Section(section.operation.title) {
                        ForEach(section.rows) { row in
                            enforcementPolicyMatrixRow(row)
                        }
                    }
                }
            }
        }
        .navigationTitle("Policy Matrix")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func enforcementPolicyMatrixRow(
        _ row: AppState.EnforcementPolicyMatrixRow
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(row.friendlyTitle)
                .font(.system(size: 14, weight: .semibold))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Current: \(row.currentSeverity.visibleLabel)")
                Spacer(minLength: 8)
                Text("Eventual: \(row.eventualSeverity.visibleLabel)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            Text(row.readiness.visibleLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(row.deferralReason)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var mediaHealthPage: some View {
        List {
            Section("Media Summary") {
                diagnosticRow("Last Backfill Discovered", diagnostics.media.lastBackfillDiscoveredCount)
                diagnosticRow("Last Backfill Attempted", diagnostics.media.lastBackfillAttemptedCount)
                diagnosticRow("Skipped Retry Cap", diagnostics.media.lastBackfillSkippedRetryCapCount)
                diagnosticRow("Upload Successes", diagnostics.media.uploadSuccessCount)
                diagnosticRow("Upload Failures", diagnostics.media.uploadFailureCount)
                diagnosticRow("Pending Local Media", optionalCount(diagnostics.media.pendingLocalMediaCount))
                diagnosticRow("Last Backfill", formattedRunDate(diagnostics.media.lastBackfillAt))
                if pendingMediaItems.isEmpty {
                    Text("No pending media uploads.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Media Detail Lists") {
                NavigationLink {
                    DebugMediaDiagnosticItemsView(
                        title: "Retry-Capped Media",
                        items: retryCappedMediaItems
                    )
                } label: {
                    diagnosticNavigationLabel("Retry-Capped Media", count: retryCappedMediaItems.count)
                }
                NavigationLink {
                    DebugMediaDiagnosticItemsView(
                        title: "Pending Media",
                        items: pendingMediaItems
                    )
                } label: {
                    diagnosticNavigationLabel("Pending Media Items", count: pendingMediaItems.count)
                }
            }

            Section("Media Recovery Candidates") {
                Text("Read-only inspector for retry-capped and divergence-linked media candidates. It does not retry, reset, delete, ignore, or mutate app data.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(isInspectingMediaRecovery ? "Inspecting..." : "Inspect Candidates") {
                    inspectMediaRecoveryCandidates()
                }
                .disabled(isInspectingMediaRecovery)

                if let snapshot = mediaRecoverySnapshot {
                    diagnosticRow("Inspected", snapshot.inspectedAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow("Remote Preflight", snapshot.remotePreflightAvailable)
                    diagnosticRow("Candidates Found", snapshot.candidatesFound)
                    diagnosticRow("File Exists", snapshot.fileExistsCount)
                    diagnosticRow("Retryable", snapshot.retryableCount)
                    diagnosticRow("Needs Org Reconciliation", snapshot.needsOrgReconciliationCount)
                    diagnosticRow("Missing Remote Parent", snapshot.missingRemoteParentCount)
                    diagnosticRow("Already Remote Complete", snapshot.alreadyRemoteCompleteCount)
                    diagnosticRow("Missing Local File", snapshot.missingLocalFileCount)
                    diagnosticRow("Manual Review", snapshot.manualReviewCount)
                    Text("Retry-capped does not mean lost. Historical findings are retained for forensic visibility.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        DebugMediaRecoverySnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Snapshot")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    NavigationLink {
                        DebugMediaRecoveryCandidatesView(items: snapshot.items)
                    } label: {
                        diagnosticNavigationLabel("Candidate Details", count: snapshot.items.count)
                    }
                } else {
                    Text("No media recovery inspection has been run in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Media Health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var divergenceAuditPage: some View {
        List {
            Section("Divergence Audit") {
                Text("Read-only local/remote audit. It does not repair, retry, delete, reset, or mutate app data.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(isRunningDivergenceAudit ? "Running Audit..." : "Run Divergence Audit") {
                    runDivergenceAudit()
                }
                .disabled(isRunningDivergenceAudit)

                if let snapshot = divergenceAuditSnapshot {
                    diagnosticRow("Ran", snapshot.ranAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow("Remote Scope", snapshot.remoteScopeAvailable)
                    NavigationLink {
                        DebugDivergenceAuditSnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Snapshot")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No divergence audit has been run in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Queue and Divergence Debt Inspector") {
                Text("Read-only classifier for failed queue items and divergence findings. It does not retry, clear, archive, hydrate, delete, or change sync behavior.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(isInspectingSyncDebt ? "Inspecting..." : "Inspect Sync Debt") {
                    inspectSyncDebt()
                }
                .disabled(isInspectingSyncDebt)

                if let snapshot = syncDebtSnapshot {
                    diagnosticRow("Inspected", snapshot.ranAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow("Failed Queue Items", snapshot.failedQueueItemCount)
                    diagnosticRow("Divergence Findings", snapshot.divergenceItemCount)
                    diagnosticRow("Grouped Historical", snapshot.groupedHistoricalCount)
                    ForEach(snapshot.queueClassificationCounts, id: \.0) { classification, count in
                        diagnosticRow(classification.rawValue, count)
                    }
                    ForEach(snapshot.divergenceClassificationCounts, id: \.0) { classification, count in
                        diagnosticRow(classification.rawValue, count)
                    }
                    NavigationLink {
                        DebugSyncDebtInspectionSnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Debt Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No sync debt inspection has been run in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote-Only Session Detail Inspector") {
                Text("Read-only detail report for remote sessions missing locally. It uses Supabase selects and local existence checks only; it does not hydrate, create folders, download media, retry queues, delete data, or change sync behavior.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Button(isInspectingRemoteOnlySessions ? "Inspecting..." : "Inspect Remote-Only Sessions") {
                    inspectRemoteOnlySessionDetails()
                }
                .disabled(isInspectingRemoteOnlySessions)

                if let snapshot = remoteOnlySessionDetailSnapshot {
                    diagnosticRow("Inspected", snapshot.inspectedAt)
                    diagnosticRow("Active Org", snapshot.activeOrganizationID)
                    diagnosticRow("Remote Scope", snapshot.remoteScopeAvailable)
                    diagnosticRow("Remote-Only Sessions", snapshot.remoteOnlySessionCount)
                    diagnosticRow("Empty Remote Draft Shells", snapshot.emptyRemoteDraftShellCount)
                    diagnosticRow("Missing Local Hydration", snapshot.missingLocalHydrationCount)
                    diagnosticRow("Historical Remote-Only", snapshot.historicalRemoteOnlyCount)
                    diagnosticRow("True Parity Debt", snapshot.trueParityDebtCount)
                    diagnosticRow("Manual Review", snapshot.manualReviewCount)
                    diagnosticRow("Possible Hydration Candidate", snapshot.possibleHydrationCandidateCount)
                    diagnosticRow("Draft Caution", snapshot.draftCautionCount)
                    NavigationLink {
                        DebugRemoteOnlySessionDetailSnapshotTextView(snapshotText: snapshot.snapshotText)
                    } label: {
                        Text("View Copyable Remote-Only Detail Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    Text("No remote-only session detail inspection has been run in this view.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = divergenceAuditSnapshot {
                Section("Core Sync Health") {
                    diagnosticRow("Property Match Status", snapshot.corePropertyStatus)
                    diagnosticRow("Matched Properties", snapshot.matchedPropertyCount)
                    diagnosticRow("Local-Only Properties", snapshot.localOnlyPropertyCount)
                    diagnosticRow("Remote-Only Properties", snapshot.remoteOnlyPropertyCount)
                    diagnosticRow("Session Match Status", snapshot.coreSessionStatus)
                    diagnosticRow("Matched Sessions", snapshot.matchedSessionCount)
                    diagnosticRow("Local-Only Sessions", snapshot.localOnlySessionCount)
                    diagnosticRow("Remote-Only Sessions", snapshot.remoteOnlySessionCount)
                }

                Section("Active Sync Issues") {
                    diagnosticRow("Actionable Findings", snapshot.activeSyncIssueCount)
                    Text(snapshot.activeSyncIssueCount == "0" ? "No active sync issues detected." : "Warning and critical findings should be reviewed before treating historical findings as operational failures.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Section("Recoverable Issues") {
                    diagnosticRow("Recoverable Findings", snapshot.recoverableIssueCount)
                    diagnosticRow("Matched Shots", snapshot.matchedShotCount)
                    diagnosticRow("Local-Only Shots", snapshot.localOnlyShotCount)
                    diagnosticRow("Remote-Only Shots", snapshot.remoteOnlyShotCount)
                    Text("Local-only shots may be legacy captures or uploads that have not reached remote storage yet. Historical findings are retained for forensic visibility.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Section("Historical / Informational States") {
                    diagnosticRow("Historical Findings", snapshot.historicalInformationalCount)
                    diagnosticRow("Stale Org Reconciled Properties", snapshot.staleOrgReconciledPropertyCount)
                    diagnosticRow("Stale Org Reconciled Shots", snapshot.staleOrgReconciledShotCount)
                    diagnosticRow("All Findings", snapshot.totalFindings)
                    ForEach(snapshot.categoryCounts, id: \.0) { category, count in
                        diagnosticRow(label(for: category), count)
                    }
                    ForEach(snapshot.historicalGroups) { group in
                        NavigationLink {
                            DebugDivergenceAuditHistoricalGroupView(group: group)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(group.title): \(group.totalCount)")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Properties \(group.affectedPropertyCount) / Sessions \(group.affectedSessionCount) / Shots \(group.affectedShotCount)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    NavigationLink {
                        DebugDivergenceAuditItemsView(
                            items: snapshot.items,
                            historicalGroups: snapshot.historicalGroups
                        )
                    } label: {
                        diagnosticNavigationLabel("Audit Findings", count: snapshot.items.count)
                    }
                }
            }
        }
        .navigationTitle("Divergence Audit")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var captureProfileMaintenancePage: some View {
        List {
            Section("Capture Profile Maintenance") {
                if let summary = diagnostics.captureProfileMaintenance {
                    diagnosticRow("Local Properties Found", summary.localPropertiesFound)
                    diagnosticRow("Properties Scanned", summary.propertiesScanned)
                    diagnosticRow("Sessions Scanned", summary.sessionsScanned)
                    diagnosticRow("Remote Properties Checked", summary.remotePropertiesChecked)
                    diagnosticRow("Remote Sessions Checked", summary.remoteSessionsChecked)
                    diagnosticRow("Remote Active Properties", summary.remoteActivePropertyCount)
                    diagnosticRow("Property Profiles Filled", summary.propertyProfilesFilled)
                    diagnosticRow("Session Profiles Filled", summary.sessionProfilesFilled)
                    diagnosticRow("Sessions Ensured", summary.sessionsEnsured)
                    diagnosticRow("Skipped", summary.skipped)
                    diagnosticRow("Historical Failed", summary.failed)
                    diagnosticRow("Stale Org Reconciled", summary.staleOrgReconciledCount)
                    diagnosticRow("True Org Mismatch", summary.trueOrgMismatchCount)
                    diagnosticRow("Filtered Deleted", summary.propertiesFilteredDeleted)
                    diagnosticRow("Filtered Archived", summary.propertiesFilteredArchived)
                    diagnosticRow("Filtered Org Mismatch", summary.propertiesFilteredOrgMismatch)
                    diagnosticRow("Filtered Inaccessible", summary.propertiesFilteredInaccessible)
                    diagnosticRow("Session Metadata Missing", summary.sessionMetadataMissing)
                    diagnosticRow("Session Profile Unknown", summary.sessionProfileUnknown)
                } else {
                    Text("No maintenance backfill summary recorded.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Capture Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var diagnosticsUtilitiesPage: some View {
        List {
            Section("Shadow Writes") {
                shadowWriteRow("Property", diagnostics.shadowWrites.property)
                shadowWriteRow("Session", diagnostics.shadowWrites.session)
                shadowWriteRow("Shot Metadata", diagnostics.shadowWrites.shotMetadata)
                shadowWriteRow("Capture Profile", diagnostics.shadowWrites.captureProfile)
            }

            Section("Last Error") {
                if let error = diagnostics.lastError {
                    diagnosticRow("Category", error.category.rawValue)
                    diagnosticRow("Recorded", formattedDate(error.recordedAt))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Message")
                            .font(.system(size: 14, weight: .semibold))
                        Text(error.message)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                } else {
                    Text("No sanitized error recorded.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Clear Local Diagnostics", role: .destructive) {
                    showClearConfirm = true
                }
            } footer: {
                Text("This reset affects diagnostic counters only.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func refreshDiagnosticDetailSnapshots() {
        failedQueueItems = appState.diagnosticsFailedQueueItems().map(DebugQueueDiagnosticSnapshotItem.init)
        retryCappedMediaItems = appState.diagnosticsRetryCappedMediaItems().map(DebugMediaDiagnosticSnapshotItem.init)
        pendingMediaItems = appState.diagnosticsPendingMediaItems().map(DebugMediaDiagnosticSnapshotItem.init)
        let completenessReport = appState.inspectCompletenessGates()
        completenessGatesSnapshot = DebugCompletenessGatesSnapshot(completenessReport)
        sessionSnapshotPreviewSnapshot = DebugSessionSnapshotPreviewSnapshot(
            appState.inspectSessionSnapshotPreview()
        )
        exportSealPreflightSnapshot = DebugExportSealPreflightSnapshot(
            AppState.makeExportSealPreflightReport(from: completenessReport)
        )
        enforcementPolicyMatrixSnapshot = DebugEnforcementPolicyMatrixSnapshot(
            AppState.makeEnforcementPolicyMatrixReport()
        )
        refreshCanonicalReadinessSnapshot()
    }

    private func refreshCanonicalReadinessSnapshot() {
        let report = AppState.makeCanonicalReadinessReport(
            activeOrganizationID: appState.activeOrganizationID,
            diagnostics: diagnostics,
            retryCappedMediaCount: retryCappedMediaItems.count,
            pendingMediaCount: pendingMediaItems.count,
            mediaRecoveryCandidateCount: mediaRecoverySummary?.candidatesFound,
            divergenceAuditSummary: divergenceAuditSummary,
            syncDebtInspectionReport: syncDebtReport,
            remoteOnlySessionDetailReport: remoteOnlySessionDetailReport
        )
        canonicalReadinessSnapshot = DebugCanonicalReadinessSnapshot(report)
    }

    private func runDivergenceAudit() {
        guard !isRunningDivergenceAudit else { return }
        isRunningDivergenceAudit = true
        Task {
            let summary = await appState.runDivergenceAudit()
            await MainActor.run {
                divergenceAuditSummary = summary
                divergenceAuditSnapshot = DebugDivergenceAuditSnapshot(summary)
                refreshCanonicalReadinessSnapshot()
                isRunningDivergenceAudit = false
            }
        }
    }

    private func inspectMediaRecoveryCandidates() {
        guard !isInspectingMediaRecovery else { return }
        isInspectingMediaRecovery = true
        let currentDivergenceSummary = divergenceAuditSummary
        let previousSnapshotOrgID = mediaRecoverySnapshot
            .flatMap { UUID(uuidString: $0.activeOrganizationID) }
        Task {
            let summary = await appState.inspectMediaRecoveryCandidates(
                divergenceAuditSummary: currentDivergenceSummary,
                previousSnapshotOrgID: previousSnapshotOrgID
            )
            await MainActor.run {
                mediaRecoverySnapshot = DebugMediaRecoverySnapshot(summary)
                mediaRecoverySummary = summary
                refreshCanonicalReadinessSnapshot()
                isInspectingMediaRecovery = false
            }
        }
    }

    private func inspectSyncDebt() {
        guard !isInspectingSyncDebt else { return }
        isInspectingSyncDebt = true
        let currentDivergenceSummary = divergenceAuditSummary
        Task {
            let report = await appState.inspectSyncDebt(divergenceAuditSummary: currentDivergenceSummary)
            await MainActor.run {
                syncDebtReport = report
                syncDebtSnapshot = DebugSyncDebtInspectionSnapshot(report)
                if currentDivergenceSummary == nil {
                    divergenceAuditSummary = nil
                    divergenceAuditSnapshot = nil
                }
                refreshCanonicalReadinessSnapshot()
                isInspectingSyncDebt = false
            }
        }
    }

    private func inspectRemoteOnlySessionDetails() {
        guard !isInspectingRemoteOnlySessions else { return }
        isInspectingRemoteOnlySessions = true
        Task {
            let report = await appState.inspectRemoteOnlySessionDetails()
            await MainActor.run {
                remoteOnlySessionDetailReport = report
                remoteOnlySessionDetailSnapshot = DebugRemoteOnlySessionDetailSnapshot(report)
                refreshCanonicalReadinessSnapshot()
                isInspectingRemoteOnlySessions = false
            }
        }
    }

    @ViewBuilder
    private func shadowWriteRow(
        _ label: String,
        _ counters: AppState.ShadowWriteEntityDiagnostics
    ) -> some View {
        diagnosticRow(label, "ok \(counters.successCount) / fail \(counters.failureCount)")
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: Int) -> some View {
        diagnosticRow(label, String(value))
    }

    private func optionalBoolText(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "not checked"
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func completenessCountsSection(
        _ title: String,
        _ counts: [AppState.CompletenessGateCount]
    ) -> some View {
        Section(title) {
            ForEach(counts) { count in
                diagnosticRow(count.state.rawValue, count.count)
            }
        }
    }

    @ViewBuilder
    private func diagnosticNavigationLabel(_ label: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 12)
            Text(String(count))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func localHealthAreaLabel(
        _ title: String,
        subtitle: String,
        value: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 4)
    }

    private func optionalCount(_ value: Int?) -> String {
        value.map(String.init) ?? "not scanned"
    }

    private var overviewHelperText: String {
        if divergenceAuditSnapshot?.activeSyncIssueCount == "0",
           divergenceAuditSnapshot?.recoverableIssueCount == "0",
           failedQueueItems.isEmpty,
           retryCappedMediaItems.isEmpty,
           pendingMediaItems.isEmpty {
            return "No active sync issues detected."
        }
        return "Historical findings are retained for forensic visibility."
    }

    private func label(for category: AppState.DivergenceAuditCategory) -> String {
        switch category {
        case .localOnlyShot:
            return "Local-only shots"
        case .remoteOnlyShot:
            return "Remote-only shots"
        case .mediaDrift:
            return "Media drift"
        case .staleOrgMismatch:
            return "Stale org needs review"
        case .legacyOrgReconciliation:
            return "Stale org reconciled"
        case .captureProfile:
            return "Capture profile"
        case .legacyCaptureProfile:
            return "Legacy capture profile"
        case .missingParent:
            return "Parent/missing"
        case .legacyRemoteSchema:
            return "Legacy remote schema"
        default:
            return category.rawValue
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    private func formattedRunDate(_ date: Date?) -> String {
        guard let date else { return "No recorded run" }
        return formattedDate(date)
    }

    private func formattedAge(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "none" }
        let clamped = max(0, Int(seconds.rounded()))
        let days = clamped / 86_400
        let hours = (clamped % 86_400) / 3_600
        let minutes = (clamped % 3_600) / 60
        let remainingSeconds = clamped % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(remainingSeconds)s" }
        return "\(remainingSeconds)s"
    }
}

private struct StageSnapshotDetailsHeadingView: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct StageSessionSnapshotUploadSummarySection: View {
    let rows: [StageDiagnosticDisplayRow]
    let uploadError: String?
    let reportText: () -> String

    var body: some View {
        Section("Session Snapshot Upload") {
            Text("Shadow-write only diagnostics. The feature flag defaults off. Upload failures do not block capture, export, sealing, sync, media recovery, or iCloud fallback.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            StageDiagnosticRowsView(rows: rows)
            if let uploadError {
                StageDiagnosticRowView(label: "Last Upload Error", value: uploadError)
            }
            StageUploadReportNavigationView(reportText: reportText)
        }
    }
}

private struct StageLastSanitizedAttemptSection: View {
    let rows: [StageDiagnosticDisplayRow]

    var body: some View {
        Section("Last Sanitized Attempt") {
            StageDiagnosticRowsView(rows: rows)
        }
    }
}

private struct StageAuthPreflightSummaryView: View {
    let checked: String
    let appUser: String
    let clientUser: String
    let usersMatch: String
    let payloadOrg: String
    let payloadProperty: String
    let payloadSession: String
    let rows: [StageDiagnosticDisplayRow]
    let failure: String?
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onRefresh: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Auth Preflight")
        diagnosticRow("Checked", checked)
        diagnosticRow("App Auth User", appUser)
        diagnosticRow("Client Session User", clientUser)
        diagnosticRow("Users Match", usersMatch)
        diagnosticRow("Payload Org ID", payloadOrg)
        diagnosticRow("Payload Property ID", payloadProperty)
        diagnosticRow("Payload Session ID", payloadSession)
        StageDiagnosticRowsView(rows: rows)
        if let failure {
            StageDiagnosticRowView(label: "Preflight Failure", value: failure)
        }
        Button(buttonTitle) {
            onRefresh()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private struct StageTestSessionCreationSummaryView: View {
    let isAvailable: Bool
    let reason: String
    let message: String?
    let onCreate: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Test Session Creation")
        StageDiagnosticRowView(label: "Creation Available", value: isAvailable ? "true" : "false")
        StageDiagnosticRowView(label: "Creation Reason", value: reason)
        Button("Create Local Snapshot Test Session") {
            onCreate()
        }
        .disabled(!isAvailable)
        .font(.system(size: 14, weight: .semibold))
        Text(message ?? reason)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

private struct StageDiagnosticDisplayRow: Identifiable {
    let id: String
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.id = label
        self.label = label
        self.value = value
    }
}

private struct StageAuthRepairSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let repairMessage: String?
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onRepair: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Auth Repair")
        StageDiagnosticRowsView(rows: rows)
        if let repairMessage {
            StageDiagnosticRowView(label: "Repair Message", value: repairMessage)
        }
        Button(buttonTitle) {
            onRepair()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageLocalOrgDriftAuditSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let samples: [String]
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onRun: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Local Org Drift Audit")
        Text("Read-only manual audit. Confirms canonical org only when active remote property/session rows exist, agree, and the remote session belongs to the local property.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        StageDiagnosticRowsView(rows: rows)
        if samples.isEmpty {
            StageDiagnosticRowView(label: "Samples", value: "none")
        } else {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                StageDiagnosticRowView(label: "Sample \(index + 1)", value: sample)
            }
        }
        Button(buttonTitle) {
            onRun()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageLocalOrgDriftRepairSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let samples: [String]
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onRepair: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Local Org Drift Repair")
        StageDiagnosticRowsView(rows: rows)
        if samples.isEmpty {
            StageDiagnosticRowView(label: "Repair Samples", value: "none")
        } else {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                StageDiagnosticRowView(label: "Repair \(index + 1)", value: sample)
            }
        }
        Button(buttonTitle) {
            onRepair()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageRemoteReadbackSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let failure: String?
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onCheck: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Remote Readback")
        Text("Read-only row and payload consistency check. It does not hydrate sessions, restore data, switch reads, download media, or change local session state.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        StageDiagnosticRowsView(rows: rows)
        if let failure {
            StageDiagnosticRowView(label: "Readback Failure", value: failure)
        }
        Button(buttonTitle) {
            onCheck()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageRestoreDiagnosticsSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let failure: String?
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onCheck: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Restore Diagnostics")
        Text("Diagnostics are read-only. Opening this disclosure does not hydrate metadata, restore media, download originals, switch canonical reads, or bypass freshness or production policy blocks.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        StageDiagnosticRowsView(rows: rows)
        if let failure {
            StageDiagnosticRowView(label: "Failure Reason", value: failure)
        }
        Button(buttonTitle) {
            onCheck()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageMetadataHydrationSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onReview: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Metadata Hydration")
        StageDiagnosticRowsView(rows: rows)
        Button(buttonTitle) {
            onReview()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageMediaRetrievalSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onRetrieve: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Media Retrieval")
        StageDiagnosticRowsView(rows: rows)
        Button(buttonTitle) {
            onRetrieve()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageRecoveryCohortSummaryView: View {
    let rows: [StageDiagnosticDisplayRow]
    let buttonTitle: String
    let isButtonDisabled: Bool
    let onCheck: () -> Void

    var body: some View {
        StageSnapshotDetailsHeadingView("Recovery Cohort")
        Text("Read-only recovery cohort and readiness summary. It does not hydrate metadata, download media, switch canonical reads, or change local or remote state.")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        StageDiagnosticRowsView(rows: rows)
        Button(buttonTitle) {
            onCheck()
        }
        .disabled(isButtonDisabled)
        .font(.system(size: 14, weight: .semibold))
    }
}

private struct StageCanonicalReadDiagnosticsActionView: View {
    let buttonTitle: String
    let isButtonDisabled: Bool
    let rows: [StageDiagnosticDisplayRow]
    let onCheck: () -> Void

    var body: some View {
        Section("Canonical Read Diagnostics Action") {
            Text("Runs only after tapping the button. It preserves selected-session scope, package evidence checks, read-switch blocks, and local fallback behavior.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button(buttonTitle) {
                onCheck()
            }
            .disabled(isButtonDisabled)
            .font(.system(size: 14, weight: .semibold))
            StageDiagnosticRowsView(rows: rows)
        }
    }
}

private struct StageFlaggedObservationReplayActionView: View {
    let buttonTitle: String
    let isButtonDisabled: Bool
    let rows: [StageDiagnosticDisplayRow]
    let onReplay: () -> Void

    var body: some View {
        Section("Flagged Observation Replay Action") {
            Text("Runs only after tapping the button. Package evidence, runtime QA authorization, exact selected scope, local active source, fallback, production, broad-read, and supabase_read_enabled guards remain enforced.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button(buttonTitle) {
                onReplay()
            }
            .disabled(isButtonDisabled)
            .font(.system(size: 14, weight: .semibold))
            StageDiagnosticRowsView(rows: rows)
        }
    }
}

private struct StageOperatorApprovalActionView: View {
    let recordButtonTitle: String
    let clearButtonTitle: String
    let isRecordDisabled: Bool
    let isClearDisabled: Bool
    let rows: [StageDiagnosticDisplayRow]
    let onRecord: () -> Void
    let onClear: () -> Void

    var body: some View {
        Section("Operator Approval Actions") {
            Text("Diagnostic approval state only. These controls do not activate candidates, enable Supabase reads, enable broad canonical reads, mutate hosted data, or bypass exact selected-session scope requirements.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Button(recordButtonTitle) {
                onRecord()
            }
            .disabled(isRecordDisabled)
            .font(.system(size: 14, weight: .semibold))
            Button(clearButtonTitle) {
                onClear()
            }
            .disabled(isClearDisabled)
            .font(.system(size: 14, weight: .semibold))
            StageDiagnosticRowsView(rows: rows)
        }
    }
}

private struct StageUploadReportNavigationView: View {
    let reportText: () -> String

    var body: some View {
        NavigationLink {
            StageLazySessionSnapshotUploadTextView(reportText: reportText)
        } label: {
            Text("View Copyable Upload Report")
                .font(.system(size: 14, weight: .semibold))
        }
    }
}

private struct StagePackageValidationReportNavigationView: View {
    let isReportAvailable: Bool
    let reportText: () -> String

    var body: some View {
        if isReportAvailable {
            NavigationLink {
                StageLazySessionSnapshotUploadTextView(
                    title: "Package Validation",
                    footerText: "Copies the selected-session package validation reports as plain text. It does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads.",
                    reportText: reportText
                )
            } label: {
                Text("View Copyable Package Validation Report")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }
}

private struct StageCanonicalRolloutReportNavigationView: View {
    let reportText: () -> String

    var body: some View {
        Section("Canonical Rollout Report") {
            Text("Display-only report navigation. Opening this link copies or displays existing sanitized report text only after explicit navigation; it does not rerun diagnostics, upload data, switch reads, activate, or mutate hosted data.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            NavigationLink {
                StageLazySessionSnapshotUploadTextView(
                    title: "Canonical Read Report",
                    footerText: "Copies the sanitized canonical-read rollout report as plain text. It keeps full canonical details out of the primary diagnostic rows and does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads.",
                    reportText: reportText
                )
            } label: {
                Text("View Canonical Read Rollout Report")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }
}

private struct StageValidationPipelineReportNavigationView: View {
    let isReportAvailable: Bool
    let reportText: () -> String

    var body: some View {
        if isReportAvailable {
            NavigationLink {
                StageLazySessionSnapshotUploadTextView(
                    title: "Validation Pipeline",
                    footerText: "Copies the selected-session validation pipeline report as plain text. It is diagnostic-only and does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads.",
                    reportText: reportText
                )
            } label: {
                Text("View Copyable Validation Pipeline Report")
                    .font(.system(size: 14, weight: .semibold))
            }
        }
    }
}

private struct StageDiagnosticRowsView: View {
    let rows: [StageDiagnosticDisplayRow]

    var body: some View {
        ForEach(rows) { row in
            StageDiagnosticRowView(label: row.label, value: row.value)
        }
    }
}

private struct StageDiagnosticRowView: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private struct DebugOfflineQueueItemsView: View {
    let items: [DebugQueueDiagnosticSnapshotItem]
    let onAcknowledged: () -> Void

    var body: some View {
        List {
            Section {
                Text("Local queue diagnostics. Eligible stale RLS debt can be acknowledged to stop replay; queue items, payloads, local records, and remote data are preserved.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Section {
                    Text("No failed queue items.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Failed Items") {
                    ForEach(items) { item in
                        NavigationLink {
                            DebugOfflineQueueItemDetailView(item: item, onAcknowledged: onAcknowledged)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(item.entityType) / \(item.operation)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(item.entityID)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("attempts \(item.attemptCount) | next \(item.nextAttempt)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                if item.isAcknowledged {
                                    Text("acknowledged historical queue debt")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.lastErrorPreview)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle("Queue Items")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugMediaDiagnosticItemsView: View {
    let title: String
    let items: [DebugMediaDiagnosticSnapshotItem]

    var body: some View {
        List {
            Section {
                Text("Read-only local media diagnostics. Full file paths and storage paths are hidden.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Section {
                    Text("No matching media items.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Media Items") {
                    ForEach(items) { item in
                        NavigationLink {
                            DebugMediaDiagnosticItemDetailView(item: item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.localFilename)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(item.shotID)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("state \(item.uploadState) | attempts \(item.attemptCount) | storage \(item.hasStoragePath)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text(item.lastUploadErrorPreview)
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugMediaRecoveryCandidatesView: View {
    let items: [DebugMediaRecoverySnapshotItem]

    private var groupedItems: [(String, [DebugMediaRecoverySnapshotItem])] {
        [
            ("Retryable", items.matchingClassification("retryable")),
            ("Needs Org Reconciliation", items.matchingClassification("needs_org_reconciliation")),
            ("Missing Remote Parent", items.matchingClassification("missing_remote_parent")),
            ("Already Remote Complete", items.matchingClassification("already_remote_complete")),
            ("Missing Local File", items.matchingClassification("missing_local_file")),
            ("Needs Manual Review", items.matchingClassification("needs_manual_review"))
        ].filter { !$0.1.isEmpty }
    }

    var body: some View {
        List {
            Section {
                Text("Read-only media recovery candidates. Full file paths, storage paths, tokens, and auth payloads are hidden.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Section {
                    Text("No media recovery candidates.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groupedItems, id: \.0) { title, grouped in
                    Section("\(title) (\(grouped.count))") {
                        ForEach(grouped) { item in
                            NavigationLink {
                                DebugMediaRecoveryCandidateDetailView(item: item)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.propertyName)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.shotID)
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Text("state \(item.uploadState) | attempts \(item.uploadAttempts) | file \(item.fileExists)")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Text(item.importanceHint)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                    Text(item.lastUploadErrorPreview)
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .navigationTitle("Media Recovery")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension Array where Element == DebugMediaRecoverySnapshotItem {
    func matchingClassification(_ classification: String) -> [DebugMediaRecoverySnapshotItem] {
        filter { $0.classification == classification }
    }
}

private struct DebugDivergenceAuditItemsView: View {
    let items: [DebugDivergenceAuditSnapshotItem]
    let historicalGroups: [DebugDivergenceAuditHistoricalGroup]
    @State private var filter: DebugDivergenceAuditFilter = .all
    @State private var findingFilters = DebugDivergenceAuditFindingFilters()
    @State private var filteredItemsCache: [DebugDivergenceAuditSnapshotItem] = []
    @State private var foregroundItemsCache: [DebugDivergenceAuditSnapshotItem] = []
    @State private var historicalGroupsCache: [DebugDivergenceAuditHistoricalGroup] = []

    private var severityOptions: [String] {
        [DebugDivergenceAuditFindingFilters.allValue] +
            Array(Set(items.map(\.severity))).sorted()
    }

    private var categoryOptions: [String] {
        [DebugDivergenceAuditFindingFilters.allValue] +
            Array(Set(items.map(\.category))).sorted()
    }

    private var entityTypeOptions: [String] {
        [DebugDivergenceAuditFindingFilters.allValue] +
            Array(Set(items.map(\.entityType))).sorted()
    }

    private var displaysGroupedDefaultView: Bool {
        filter == .all && findingFilters.isDefault
    }

    var body: some View {
        List {
            Section {
                Text("Read-only divergence findings. No repair, retry, delete, or reset actions are available here.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Picker("Filter", selection: $filter) {
                    ForEach(DebugDivergenceAuditFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Search / Filters") {
                TextField("Search IDs or reasons", text: $findingFilters.searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Severity", selection: $findingFilters.severity) {
                    ForEach(severityOptions, id: \.self) { severity in
                        Text(severity).tag(severity)
                    }
                }
                Picker("Category", selection: $findingFilters.category) {
                    ForEach(categoryOptions, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
                Picker("Entity Type", selection: $findingFilters.entityType) {
                    ForEach(entityTypeOptions, id: \.self) { entityType in
                        Text(entityType).tag(entityType)
                    }
                }
                Button("Clear Filters") {
                    filter = .all
                    findingFilters = DebugDivergenceAuditFindingFilters()
                }
                .font(.system(size: 14, weight: .semibold))
                .disabled(filter == .all && findingFilters.isDefault)
            }

            if displaysGroupedDefaultView {
                if foregroundItemsCache.isEmpty {
                    Section("Active / Recoverable Findings") {
                        Text("No active sync issues or recoverable findings.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Active / Recoverable Findings") {
                        ForEach(foregroundItemsCache) { item in
                            DebugDivergenceAuditFindingRow(item: item)
                        }
                    }
                }

                if historicalGroupsCache.isEmpty {
                    Section("Grouped Historical Findings") {
                        Text("No grouped historical findings.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Grouped Historical Findings") {
                        Text("Historical groups are informational and non-operational unless a separate active finding is present.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(historicalGroupsCache) { group in
                            NavigationLink {
                                DebugDivergenceAuditHistoricalGroupView(group: group)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(group.title) (\(group.totalCount))")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text("Properties \(group.affectedPropertyCount) / Sessions \(group.affectedSessionCount) / Shots \(group.affectedShotCount)")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    Text(group.context)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        DebugDivergenceAuditRawItemsView(
                            title: "All Raw Findings",
                            items: items
                        )
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("View All Raw Findings")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer(minLength: 12)
                            Text(String(items.count))
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("Raw findings preserve every forensic ID and category.")
                }
            } else if filteredItemsCache.isEmpty {
                Section {
                    Text("No findings match this filter.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                if foregroundItemsCache.isEmpty {
                    Section("Active / Recoverable Findings") {
                        Text(activeRecoverableEmptyText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Active / Recoverable Findings") {
                        ForEach(foregroundItemsCache) { item in
                            DebugDivergenceAuditFindingRow(item: item)
                        }
                    }
                }

                if !historicalGroupsCache.isEmpty {
                    Section("Grouped Historical Findings") {
                        ForEach(historicalGroupsCache) { group in
                            NavigationLink {
                                DebugDivergenceAuditHistoricalGroupView(group: group)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(group.title) (\(group.totalCount))")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.primary)
                                    Text("Properties \(group.affectedPropertyCount) / Sessions \(group.affectedSessionCount) / Shots \(group.affectedShotCount)")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                            }
                        }
                    }
                }

                Section("Findings") {
                    ForEach(filteredItemsCache) { item in
                        DebugDivergenceAuditFindingRow(item: item)
                    }
                }
            }
        }
        .navigationTitle("Divergence Audit")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            refreshFilteredItems()
        }
        .onChange(of: filter) { _, _ in
            refreshFilteredItems()
        }
        .onChange(of: findingFilters) { _, _ in
            refreshFilteredItems()
        }
    }

    private var activeRecoverableEmptyText: String {
        if filter == .needsReview {
            return "No active sync issues or recoverable findings."
        }
        return "No active or recoverable findings match this filter."
    }

    private func refreshFilteredItems() {
        let filtered = items.filter { item in
            item.filterMatches(filter) && item.matches(findingFilters)
        }
        filteredItemsCache = filtered
        foregroundItemsCache = filtered.filter { !$0.isGroupedHistorical }
        if displaysGroupedDefaultView {
            historicalGroupsCache = historicalGroups
        } else {
            historicalGroupsCache = Self.makeHistoricalGroups(from: filtered)
        }
    }

    private static func makeHistoricalGroups(
        from items: [DebugDivergenceAuditSnapshotItem]
    ) -> [DebugDivergenceAuditHistoricalGroup] {
        let categories = [
            AppState.DivergenceAuditCategory.legacyOrgReconciliation.rawValue,
            AppState.DivergenceAuditCategory.legacyRemoteSchema.rawValue,
            AppState.DivergenceAuditCategory.legacyCaptureProfile.rawValue
        ]
        return categories.compactMap { category in
            let categoryItems = items.filter { $0.category == category }
            guard !categoryItems.isEmpty else { return nil }
            return DebugDivergenceAuditHistoricalGroup(
                category: category,
                items: categoryItems
            )
        }
    }
}

private struct DebugDivergenceAuditFindingRow: View {
    let item: DebugDivergenceAuditSnapshotItem

    var body: some View {
        NavigationLink {
            DebugDivergenceAuditItemDetailView(item: item)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.severity) / \(item.category)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(item.entityType) \(item.entityID)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(item.reasonPreview)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct DebugDivergenceAuditRawItemsView: View {
    let title: String
    let items: [DebugDivergenceAuditSnapshotItem]

    var body: some View {
        List {
            Section {
                Text("Raw read-only forensic findings. This view intentionally includes historical detail and all visible IDs.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Section("Findings") {
                ForEach(items) { item in
                    DebugDivergenceAuditFindingRow(item: item)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugDivergenceAuditHistoricalGroupView: View {
    let group: DebugDivergenceAuditHistoricalGroup
    @State private var showsAll: Bool = false

    private var visibleItems: [DebugDivergenceAuditSnapshotItem] {
        showsAll ? group.allItems : group.sampleItems
    }

    var body: some View {
        List {
            Section {
                Text(group.context)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Severity", "Info")
                diagnosticRow("Category", group.category)
                diagnosticRow("Total", group.totalCount)
                diagnosticRow("Affected Properties", group.affectedPropertyCount)
                diagnosticRow("Affected Sessions", group.affectedSessionCount)
                diagnosticRow("Affected Shots", group.affectedShotCount)
            } footer: {
                Text("Grouped for operator readability only. Raw findings remain available and unchanged.")
            }

            Section(showsAll ? "All Findings" : "Sample Findings") {
                ForEach(visibleItems) { item in
                    DebugDivergenceAuditFindingRow(item: item)
                }
                if group.allItems.count > group.sampleItems.count {
                    Button(showsAll ? "Show Sample Only" : "Show All") {
                        showsAll.toggle()
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugDivergenceAuditSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Snapshot") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized snapshot as plain text only.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Audit Snapshot")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugMediaRecoverySnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Snapshot") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized media recovery snapshot as plain text only.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Media Snapshot")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugSyncDebtInspectionSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized sync debt report as plain text only.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Debt Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugRemoteOnlySessionDetailSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized remote-only session detail report as plain text only. It does not include local paths, signed URLs, media, or auth material.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Session Details")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugCanonicalReadinessSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized canonical readiness report as plain text only. It does not include local paths, signed URLs, media, or auth material.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Readiness Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugCompletenessGatesSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized completeness gates report as plain text only. It does not include local paths, signed URLs, media, or auth material.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Completeness Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugSessionSnapshotPreviewTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized local-only snapshot preview report as plain text. It does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Snapshot Preview Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugSessionSnapshotUploadDiagnosticsView: View {
    @ObservedObject var appState: AppState
    @State private var isUploadingSessionSnapshot: Bool = false
    @State private var isCheckingSnapshotReadback: Bool = false
    @State private var isCheckingSnapshotRestoreDiagnostics: Bool = false
    @State private var isCheckingRecoveryCohort: Bool = false
    @State private var isHydratingSnapshotMetadata: Bool = false
    @State private var isShowingHydrationConfirmation: Bool = false
    @State private var isRetrievingSnapshotMedia: Bool = false
    @State private var isShowingMediaRetrievalConfirmation: Bool = false
    @State private var isCheckingCanonicalReadDiagnostics: Bool = false
    @State private var isBuildingCanonicalCandidateOverlay: Bool = false
    @State private var isRunningPackageValidation: Bool = false
    @State private var packageValidationReport: AppState.LocalHealthSessionSnapshotPackageValidationReport?
    @State private var isRefreshingAuthPreflight: Bool = false
    @State private var isRepairingLocalOrgDrift: Bool = false
    @State private var isRunningLocalOrgDriftAudit: Bool = false
    @State private var isRepairingConfirmedLocalOrgDrift: Bool = false
    @State private var isSnapshotUploadDetailsExpanded: Bool = false
    @State private var testSessionCreationMessage: String?

    init(appState: AppState, diagnostics: AppState.SessionSnapshotUploadDiagnostics) {
        self.appState = appState
    }

    private var diagnostics: AppState.SessionSnapshotUploadDiagnostics {
        appState.localDiagnostics.sessionSnapshotUpload
    }

    private var reportText: String {
        AppState.sessionSnapshotUploadReportText(diagnostics)
    }

    private var uploadAvailability: (isAvailable: Bool, reason: String) {
        appState.manualSessionSnapshotUploadAvailability
    }

    private var uploadTarget: AppState.ManualSessionSnapshotUploadTarget? {
        appState.manualSessionSnapshotUploadTarget
    }

    private var uploadTargetResolution: AppState.ManualSessionSnapshotUploadTargetResolution {
        appState.manualSessionSnapshotUploadTargetResolution
    }

    private var hydrationPolicy: AppState.SessionSnapshotHydrationPolicyDiagnostics {
        appState.sessionSnapshotHydrationPolicyDiagnostics
    }

    private var hydrationConfirmation: AppState.SessionSnapshotHydrationConfirmation {
        AppState.makeSessionSnapshotHydrationConfirmation(
            diagnostics: diagnostics,
            policy: hydrationPolicy
        )
    }

    private var mediaRetrievalConfirmation: AppState.SessionSnapshotMediaRetrievalConfirmation {
        AppState.makeSessionSnapshotMediaRetrievalConfirmation(
            diagnostics: diagnostics,
            targetClassification: appState.supabaseConfiguration.targetClassification
        )
    }

    private var testSessionCreationAvailability: (isAvailable: Bool, reason: String) {
        appState.manualSessionSnapshotTestSessionCreationAvailability
    }

    private var effectiveFlagEnabled: Bool {
        appState.backendFeatureFlags.sessionSnapshotShadowWriteEnabled
    }

    private var effectiveAutoUploadFlagEnabled: Bool {
        appState.backendFeatureFlags.sessionSnapshotAutoUploadEnabled
    }

    private var effectiveAutoUploadKillSwitchActive: Bool {
        appState.backendFeatureFlags.sessionSnapshotAutoUploadKillSwitch
    }

    private var environmentFlagDetected: Bool {
        ProcessInfo.processInfo.environment["session_snapshot_shadow_write_enabled"] != nil ||
            ProcessInfo.processInfo.environment["SCOUTCAPTURE_SESSION_SNAPSHOT_SHADOW_WRITE_ENABLED"] != nil
    }

    var body: some View {
        List {
            Section("Supabase Target") {
                diagnosticRow("URL", appState.supabaseConfiguration.sanitizedURLDisplay)
                diagnosticRow("Target", appState.supabaseConfiguration.targetClassification.rawValue)
                diagnosticRow("Override Active", appState.supabaseConfiguration.isOverrideActive ? "true" : "false")
                diagnosticRow("Config Source", appState.supabaseConfiguration.source.rawValue)
                diagnosticRow("Anon Key", appState.supabaseConfiguration.redactedAnonKeyDisplay)
                diagnosticRow("Snapshot Flag Env", environmentFlagDetected ? "detected" : "not detected")
                diagnosticRow(
                    "Production Validation Allowed",
                    appState.supabaseConfiguration.productionSnapshotValidationAllowed ? "true" : "false"
                )
                diagnosticRow(
                    "Manual Only",
                    appState.supabaseConfiguration.isProductionSnapshotValidationManualOnly ? "true" : "false"
                )
                diagnosticRow(
                    "Snapshot Override Allowed",
                    appState.supabaseConfiguration.isSessionSnapshotShadowWriteOverrideAllowed ? "true" : "false"
                )
                diagnosticRow(
                    "Production Hydration Gate",
                    appState.supabaseConfiguration.productionSnapshotHydrationAllowed ? "true" : "false"
                )
            }

            Section("Snapshot Upload Details") {
                DisclosureGroup(isExpanded: $isSnapshotUploadDetailsExpanded) {
                    Text("Upload, preflight, readback, restore, and recovery diagnostics remain available here. Keep this collapsed during controlled activation evaluation unless fresh snapshot evidence needs investigation.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Upload Diagnostics And Repair Tools")
                            .font(.system(size: 14, weight: .semibold))
                        Text(isSnapshotUploadDetailsExpanded ? "Hide snapshot upload controls" : "Show snapshot upload controls")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if isSnapshotUploadDetailsExpanded {
            Section("Session Snapshot Upload") {
                Text("Shadow-write only diagnostics. The feature flag defaults off. Upload failures do not block capture, export, sealing, sync, media recovery, or iCloud fallback.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Flag Enabled", effectiveFlagEnabled ? "true" : "false")
                diagnosticRow("Remote Availability", diagnostics.remoteAvailability)
                diagnosticRow("Attempts", diagnostics.attemptedCount)
                diagnosticRow("Successes", diagnostics.successCount)
                diagnosticRow("Failures", diagnostics.failureCount)
                diagnosticRow("Orphan Risk", diagnostics.orphanRiskCount)
                diagnosticRow("Final Upload Outcome", diagnostics.lastUploadOutcome)
                diagnosticRow("Last Attempt", formattedRunDate(diagnostics.lastAttemptAt))
                diagnosticRow("Last Success", formattedRunDate(diagnostics.lastSuccessAt))
                diagnosticRow("Last Failure", formattedRunDate(diagnostics.lastFailureAt))
                if let uploadError = AppState.diagnosticsPreviewText(diagnostics.lastUploadErrorMessage, maxLength: 160) {
                    diagnosticRow("Last Upload Error", uploadError)
                }
                NavigationLink {
                    DebugSessionSnapshotUploadTextView(snapshotText: reportText)
                } label: {
                    Text("View Copyable Upload Report")
                        .font(.system(size: 14, weight: .semibold))
                }
            }

            Section("Automatic Upload Guard") {
                diagnosticRow("Auto Flag Enabled", effectiveAutoUploadFlagEnabled ? "true" : "false")
                diagnosticRow("Kill Switch Active", effectiveAutoUploadKillSwitchActive ? "true" : "false")
                diagnosticRow("Allowlist Match", diagnostics.autoUploadAllowlistMatch ? "true" : "false")
                diagnosticRow("Skipped Reason", diagnostics.autoUploadSkippedReason ?? "none")
                diagnosticRow("Trigger Source", diagnostics.autoUploadTriggerSource ?? "none")
                diagnosticRow("Last Auto Attempt", formattedRunDate(diagnostics.lastAutoAttemptAt))
                diagnosticRow("Last Auto Success", formattedRunDate(diagnostics.lastAutoSuccessAt))
                diagnosticRow("Last Auto Failure", formattedRunDate(diagnostics.lastAutoFailureAt))
                diagnosticRow("Last Auto Outcome", diagnostics.lastAutoUploadOutcome)
                if let autoError = AppState.diagnosticsPreviewText(diagnostics.lastAutoFailureMessage, maxLength: 160) {
                    diagnosticRow("Last Auto Failure", autoError)
                }
            }

            Section("Selected Upload Target") {
                if let uploadTarget {
                    diagnosticRow("Source", uploadTarget.source.rawValue)
                    diagnosticRow("Property Name", uploadTarget.propertyName)
                    diagnosticRow("Property ID", uploadTarget.propertyID.uuidString)
                    diagnosticRow("Session ID", uploadTarget.sessionID.uuidString)
                    diagnosticRow("Session Status", uploadTarget.sessionStatus.rawValue)
                    diagnosticRow("Session Started", formattedRunDate(uploadTarget.sessionStartedAt))
                } else {
                    diagnosticRow("Target", "none")
                    diagnosticRow("Selected Property ID", uploadTargetResolution.selectedPropertyID?.uuidString ?? "none")
                    diagnosticRow("Sessions Found", uploadTargetResolution.sessionsFoundForPropertyCount)
                    diagnosticRow("Session Index Available", uploadTargetResolution.localSessionIndexAvailable ? "true" : "false")
                    diagnosticRow("Reason", uploadTargetResolution.reason)
                }
                Button("Create Local Snapshot Test Session") {
                    let result = appState.createManualSessionSnapshotTestSessionForLocalDev()
                    if let sessionID = result.sessionID {
                        testSessionCreationMessage = "\(result.message): \(sessionID.uuidString)"
                    } else {
                        testSessionCreationMessage = result.message
                    }
                }
                .disabled(!testSessionCreationAvailability.isAvailable)
                .font(.system(size: 14, weight: .semibold))
                Text(testSessionCreationMessage ?? testSessionCreationAvailability.reason)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Section("Auth Preflight") {
                diagnosticRow("Checked", formattedRunDate(diagnostics.lastAuthPreflightAt))
                diagnosticRow("App Auth User", diagnostics.lastAuthPreflightAppUserID ?? "none")
                diagnosticRow("Client Session User", diagnostics.lastAuthPreflightClientUserID ?? "none")
                diagnosticRow("Users Match", optionalBoolText(diagnostics.lastAuthPreflightUsersMatch))
                diagnosticRow("Payload Org ID", diagnostics.lastAuthPreflightPayloadOrgID?.uuidString ?? "none")
                diagnosticRow("Payload Property ID", diagnostics.lastAuthPreflightPayloadPropertyID?.uuidString ?? "none")
                diagnosticRow("Payload Session ID", diagnostics.lastAuthPreflightPayloadSessionID?.uuidString ?? "none")
                diagnosticRow("Remote Property", optionalBoolText(diagnostics.lastAuthPreflightRemotePropertyExists))
                diagnosticRow("Remote Session", optionalBoolText(diagnostics.lastAuthPreflightRemoteSessionExists))
                diagnosticRow("Remote Property Org", diagnostics.lastAuthPreflightRemotePropertyOrgID?.uuidString ?? "none")
                diagnosticRow("Remote Session Org", diagnostics.lastAuthPreflightRemoteSessionOrgID?.uuidString ?? "none")
                diagnosticRow("Remote Session Property", optionalBoolText(diagnostics.lastAuthPreflightRemoteSessionPropertyMatches))
                diagnosticRow("Remote Org Match", optionalBoolText(diagnostics.lastAuthPreflightRemoteOrgIDsMatch))
                diagnosticRow("Preflight Ready", optionalBoolText(diagnostics.lastAuthPreflightReady))
                if let failure = AppState.diagnosticsPreviewText(diagnostics.lastAuthPreflightFailureMessage, maxLength: 160) {
                    diagnosticRow("Preflight Failure", failure)
                }
                diagnosticRow("Repair Outcome", diagnostics.lastLocalOrgRepairOutcome)
                diagnosticRow("Repair Previous Org", diagnostics.lastLocalOrgRepairPreviousOrgID?.uuidString ?? "none")
                diagnosticRow("Repair Canonical Org", diagnostics.lastLocalOrgRepairCanonicalOrgID?.uuidString ?? "none")
                if let repairMessage = AppState.diagnosticsPreviewText(diagnostics.lastLocalOrgRepairMessage, maxLength: 160) {
                    diagnosticRow("Repair Message", repairMessage)
                }
                Button(isRefreshingAuthPreflight ? "Checking..." : "Refresh Auth Preflight") {
                    guard !isRefreshingAuthPreflight else { return }
                    isRefreshingAuthPreflight = true
                    Task {
                        _ = await appState.refreshManualSessionSnapshotAuthPreflight()
                        await MainActor.run {
                            isRefreshingAuthPreflight = false
                        }
                    }
                }
                .disabled(isRefreshingAuthPreflight || uploadTarget == nil)
                .font(.system(size: 14, weight: .semibold))
                Button(isRepairingLocalOrgDrift ? "Repairing..." : "Repair Selected Local Org Drift") {
                    guard !isRepairingLocalOrgDrift else { return }
                    isRepairingLocalOrgDrift = true
                    Task {
                        _ = await appState.repairSelectedManualSessionSnapshotLocalOrgDrift()
                        await MainActor.run {
                            isRepairingLocalOrgDrift = false
                        }
                    }
                }
                .disabled(isRepairingLocalOrgDrift || uploadTarget == nil)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Local Org Drift Audit") {
                Text("Read-only manual audit. Confirms canonical org only when active remote property/session rows exist, agree, and the remote session belongs to the local property.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Checked", formattedRunDate(diagnostics.lastLocalOrgDriftAuditAt))
                diagnosticRow("Properties Checked", diagnostics.lastLocalOrgDriftAuditPropertiesChecked)
                diagnosticRow("Sessions Checked", diagnostics.lastLocalOrgDriftAuditSessionsChecked)
                diagnosticRow("Property Mismatches", diagnostics.lastLocalOrgDriftAuditPropertyMismatchCount)
                diagnosticRow("Session Mismatches", diagnostics.lastLocalOrgDriftAuditSessionMismatchCount)
                diagnosticRow("Unable To Confirm", diagnostics.lastLocalOrgDriftAuditUnableToConfirmCount)
                diagnosticRow("Repair Checked", formattedRunDate(diagnostics.lastLocalOrgDriftRepairAt))
                diagnosticRow("Repair Attempts", diagnostics.lastLocalOrgDriftRepairAttemptedCount)
                diagnosticRow("Repaired Properties", diagnostics.lastLocalOrgDriftRepairPropertyCount)
                diagnosticRow("Repaired Sessions", diagnostics.lastLocalOrgDriftRepairSessionCount)
                diagnosticRow("Repair Skipped", diagnostics.lastLocalOrgDriftRepairSkippedCount)
                diagnosticRow("Repair Failures", diagnostics.lastLocalOrgDriftRepairFailureCount)
                if diagnostics.lastLocalOrgDriftAuditSamples.isEmpty {
                    diagnosticRow("Samples", "none")
                } else {
                    ForEach(Array(diagnostics.lastLocalOrgDriftAuditSamples.enumerated()), id: \.offset) { index, sample in
                        diagnosticRow(
                            "Sample \(index + 1)",
                            AppState.diagnosticsPreviewText(sample, maxLength: 180) ?? "sample_unavailable"
                        )
                    }
                }
                if diagnostics.lastLocalOrgDriftRepairSamples.isEmpty {
                    diagnosticRow("Repair Samples", "none")
                } else {
                    ForEach(Array(diagnostics.lastLocalOrgDriftRepairSamples.enumerated()), id: \.offset) { index, sample in
                        diagnosticRow(
                            "Repair \(index + 1)",
                            AppState.diagnosticsPreviewText(sample, maxLength: 180) ?? "sample_unavailable"
                        )
                    }
                }
                Button(isRunningLocalOrgDriftAudit ? "Auditing..." : "Run Local Org Drift Audit") {
                    guard !isRunningLocalOrgDriftAudit else { return }
                    isRunningLocalOrgDriftAudit = true
                    Task {
                        _ = await appState.runLocalOrgDriftAudit()
                        await MainActor.run {
                            isRunningLocalOrgDriftAudit = false
                        }
                    }
                }
                .disabled(isRunningLocalOrgDriftAudit)
                .font(.system(size: 14, weight: .semibold))
                Button(isRepairingConfirmedLocalOrgDrift ? "Repairing..." : "Repair Confirmed Local Org Drift") {
                    guard !isRepairingConfirmedLocalOrgDrift else { return }
                    isRepairingConfirmedLocalOrgDrift = true
                    Task {
                        _ = await appState.repairConfirmedLocalOrgDrift()
                        await MainActor.run {
                            isRepairingConfirmedLocalOrgDrift = false
                        }
                    }
                }
                .disabled(isRepairingConfirmedLocalOrgDrift)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Manual Diagnostic Trigger") {
                Button(isUploadingSessionSnapshot ? "Uploading..." : "Upload Selected Session Snapshot") {
                    guard uploadAvailability.isAvailable else { return }
                    isUploadingSessionSnapshot = true
                    Task {
                        _ = await appState.uploadCurrentSessionSnapshotShadowWrite(
                            kind: .manual,
                            trigger: "manual_diagnostic"
                        )
                        await MainActor.run {
                            isUploadingSessionSnapshot = false
                        }
                    }
                }
                .disabled(!uploadAvailability.isAvailable || isUploadingSessionSnapshot)
                .font(.system(size: 14, weight: .semibold))
                Text(uploadAvailability.reason)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Section("Last Sanitized Attempt") {
                diagnosticRow("Snapshot ID", diagnostics.lastSnapshotID?.uuidString ?? "none")
                diagnosticRow("Property ID", diagnostics.lastPropertyID?.uuidString ?? "none")
                diagnosticRow("Session ID", diagnostics.lastSessionID?.uuidString ?? "none")
                diagnosticRow("Snapshot Kind", diagnostics.lastKind ?? "none")
                diagnosticRow("Trigger", diagnostics.lastTrigger ?? "none")
                diagnosticRow("Generated Payload Path", AppState.diagnosticsPreviewText(diagnostics.lastUploadPath) == nil ? "false" : "true")
                diagnosticRow("Storage Upload Completed", diagnostics.lastStorageUploadCompleted ? "true" : "false")
                diagnosticRow("Row Insert Completed", diagnostics.lastRowInsertCompleted ? "true" : "false")
            }

            Section("Remote Readback") {
                Text("Read-only row and payload consistency check. It does not hydrate sessions, restore data, switch reads, download media, or change local session state.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Status", diagnostics.lastReadbackStatus)
                diagnosticRow("Last Checked", formattedRunDate(diagnostics.lastReadbackAt))
                diagnosticRow("Snapshot ID", diagnostics.lastReadbackSnapshotID?.uuidString ?? "none")
                diagnosticRow("Row Found", diagnostics.lastReadbackRowFound ? "true" : "false")
                diagnosticRow("Payload Readable", diagnostics.lastReadbackPayloadReadable ? "true" : "false")
                diagnosticRow("Checksum Verified", diagnostics.lastReadbackChecksumVerified ? "true" : "false")
                diagnosticRow("Row/Object Consistent", diagnostics.lastReadbackRowObjectConsistent ? "true" : "false")
                diagnosticRow("Payload Byte Size", diagnostics.lastReadbackPayloadByteSize.map(String.init) ?? "none")
                diagnosticRow("Snapshot Created", formattedRunDate(diagnostics.lastReadbackSnapshotCreatedAt))
                if let failure = AppState.diagnosticsPreviewText(diagnostics.lastReadbackFailureMessage, maxLength: 160) {
                    diagnosticRow("Readback Failure", failure)
                }
                Button(isCheckingSnapshotReadback ? "Checking..." : "Check Remote Readback") {
                    isCheckingSnapshotReadback = true
                    Task {
                        _ = await appState.validateLatestSessionSnapshotRemoteReadback()
                        await MainActor.run {
                            isCheckingSnapshotReadback = false
                        }
                    }
                }
                .disabled(isCheckingSnapshotReadback)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Snapshot Restore Diagnostics") {
                Text("Diagnostics are read-only. Metadata hydration is a separate manual action that writes local session, shot, issue, and guided metadata only; it does not restore media, download originals, switch canonical reads, or bypass local_newer_conflict / production policy blocks.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Result", diagnostics.lastRestoreDiagnosticsResult)
                diagnosticRow("Last Checked", formattedRunDate(diagnostics.lastRestoreDiagnosticsAt))
                diagnosticRow("Property ID", diagnostics.lastRestoreDiagnosticsPropertyID?.uuidString ?? "none")
                diagnosticRow("Session ID", diagnostics.lastRestoreDiagnosticsSessionID?.uuidString ?? "none")
                diagnosticRow("Snapshot ID", diagnostics.lastRestoreDiagnosticsSnapshotID?.uuidString ?? "none")
                diagnosticRow("Row Found", diagnostics.lastRestoreDiagnosticsRowFound ? "true" : "false")
                diagnosticRow("Object Readable", diagnostics.lastRestoreDiagnosticsObjectReadable ? "true" : "false")
                diagnosticRow("Checksum Verified", diagnostics.lastRestoreDiagnosticsChecksumVerified ? "true" : "false")
                diagnosticRow("Byte Size Matches", diagnostics.lastRestoreDiagnosticsByteSizeMatches ? "true" : "false")
                diagnosticRow("Row/Object Verified", diagnostics.lastRestoreDiagnosticsRowObjectVerified ? "true" : "false")
                diagnosticRow("Parent Remote Verified", diagnostics.lastRestoreDiagnosticsParentRemoteVerified ? "true" : "false")
                diagnosticRow("Snapshot Schema", diagnostics.lastRestoreDiagnosticsSnapshotSchemaVersion.map(String.init) ?? "none")
                diagnosticRow("Snapshot Created", formattedRunDate(diagnostics.lastRestoreDiagnosticsSnapshotCreatedAt))
                diagnosticRow("Snapshot Generated", formattedRunDate(diagnostics.lastRestoreDiagnosticsSnapshotGeneratedAt))
                diagnosticRow("Local Known State", formattedRunDate(diagnostics.lastRestoreDiagnosticsLocalKnownStateAt))
                diagnosticRow("Local Known Source", diagnostics.lastRestoreDiagnosticsLocalKnownStateSource ?? "none")
                diagnosticRow("Freshness", diagnostics.lastRestoreDiagnosticsFreshness)
                diagnosticRow("Local Session Exists", diagnostics.lastRestoreDiagnosticsLocalSessionExists ? "true" : "false")
                diagnosticRow("Local Session Status", diagnostics.lastRestoreDiagnosticsLocalSessionStatus ?? "none")
                diagnosticRow("Local Shots", diagnostics.lastRestoreDiagnosticsLocalShotCount.map(String.init) ?? "none")
                diagnosticRow("Local Issues", diagnostics.lastRestoreDiagnosticsLocalIssueCount.map(String.init) ?? "none")
                diagnosticRow("Local Guided", diagnostics.lastRestoreDiagnosticsLocalGuidedCount.map(String.init) ?? "none")
                diagnosticRow("Snapshot Shots", diagnostics.lastRestoreDiagnosticsSnapshotShotCount.map(String.init) ?? "none")
                diagnosticRow("Snapshot Issues", diagnostics.lastRestoreDiagnosticsSnapshotIssueCount.map(String.init) ?? "none")
                diagnosticRow("Snapshot Guided", diagnostics.lastRestoreDiagnosticsSnapshotGuidedCount.map(String.init) ?? "none")
                diagnosticRow("Media Manifest Count", diagnostics.lastRestoreDiagnosticsSnapshotMediaManifestCount.map(String.init) ?? "none")
                if let failure = AppState.diagnosticsPreviewText(diagnostics.lastRestoreDiagnosticsFailureReason, maxLength: 160) {
                    diagnosticRow("Failure Reason", failure)
                }
                diagnosticRow("Media Retrieval Allowed", mediaRetrievalConfirmation.canRetrieve ? "true" : "false")
                diagnosticRow("Media Retrieval Blocked", mediaRetrievalConfirmation.blockedReason ?? "none")
                diagnosticRow("Media Retrieval Attempted", diagnostics.lastMediaRetrievalAttemptedCount)
                diagnosticRow("Media Retrieval Downloaded", diagnostics.lastMediaRetrievalDownloadedCount)
                diagnosticRow("Media Retrieval Checksums", diagnostics.lastMediaRetrievalChecksumVerifiedCount)
                diagnosticRow("Media Retrieval Existing", diagnostics.lastMediaRetrievalSkippedExistingCount)
                diagnosticRow("Media Retrieval Failed", diagnostics.lastMediaRetrievalFailedCount)
                diagnosticRow("Recovered Local Paths", diagnostics.lastMediaRetrievalRecoveredLocalPathCount)
                diagnosticRow("Hydration Allowed", diagnostics.lastHydrationAllowed ? "true" : "false")
                diagnosticRow("Hydration Blocked", diagnostics.lastHydrationBlockedReason ?? "none")
                diagnosticRow("Hydration Source", diagnostics.lastHydrationSourceSnapshotID?.uuidString ?? "none")
                diagnosticRow("Hydrated At", formattedRunDate(diagnostics.lastHydrationAt))
                diagnosticRow("Hydrated Session", diagnostics.lastHydrationSessionID?.uuidString ?? "none")
                diagnosticRow("Hydrated Shots", diagnostics.lastHydrationShotCount)
                diagnosticRow("Hydrated Issues", diagnostics.lastHydrationIssueCount)
                diagnosticRow("Hydrated Guided", diagnostics.lastHydrationGuidedCount)
                diagnosticRow("Production Hydration Allowed", hydrationPolicy.productionHydrationAllowed ? "true" : "false")
                diagnosticRow("Hydration Mode", hydrationPolicy.hydrationMode)
                diagnosticRow("Hydration Scope", hydrationPolicy.hydrationScope)
                diagnosticRow("Production Hydration Blocked Reason", hydrationPolicy.productionHydrationBlockedReason ?? "none")
                diagnosticRow("Hydration Confirmation Required", hydrationConfirmation.confirmationRequired ? "true" : "false")
                diagnosticRow("Hydration Action Available", hydrationConfirmation.canHydrate ? "true" : "false")
                diagnosticRow("Hydration Action Blocked Reason", hydrationConfirmation.blockedReason ?? "none")
                Button(isCheckingSnapshotRestoreDiagnostics ? "Checking..." : "Check Restore Diagnostics") {
                    isCheckingSnapshotRestoreDiagnostics = true
                    Task {
                        _ = await appState.validateLatestSessionSnapshotRestoreDiagnostics()
                        await MainActor.run {
                            isCheckingSnapshotRestoreDiagnostics = false
                        }
                    }
                }
                .disabled(isCheckingSnapshotRestoreDiagnostics)
                .font(.system(size: 14, weight: .semibold))
                Button(isHydratingSnapshotMetadata ? "Hydrating..." : "Review Metadata Hydration...") {
                    isShowingHydrationConfirmation = true
                }
                .disabled(isHydratingSnapshotMetadata)
                .font(.system(size: 14, weight: .semibold))
                Button(isRetrievingSnapshotMedia ? "Retrieving..." : "Retrieve Snapshot Media Test-Only") {
                    isShowingMediaRetrievalConfirmation = true
                }
                .disabled(isRetrievingSnapshotMedia)
                .font(.system(size: 14, weight: .semibold))
            }

            Section("Snapshot Recovery Cohort") {
                Text("Read-only recovery cohort and readiness summary. It does not hydrate metadata, download media, switch canonical reads, or change local or remote state.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                diagnosticRow("Cohort", diagnostics.lastRecoveryCohortCategory)
                diagnosticRow("Readiness", diagnostics.lastRecoveryReadiness)
                diagnosticRow("Risk", diagnostics.lastRecoveryRiskLevel)
                diagnosticRow("Snapshot Age Seconds", diagnostics.lastRecoverySnapshotFreshnessAgeSeconds.map { String(Int($0)) } ?? "none")
                diagnosticRow("Hydration Eligibility", diagnostics.lastRecoveryHydrationEligibilityReason)
                diagnosticRow("Latest Snapshot Covered", diagnostics.lastRecoveryLatestSnapshotCovered ? "true" : "false")
                diagnosticRow("Restore Result", diagnostics.lastRecoveryRestoreDiagnosticsResult)
                Button(isCheckingRecoveryCohort ? "Checking..." : "Check Recovery Cohort") {
                    isCheckingRecoveryCohort = true
                    Task {
                        _ = await appState.validateSnapshotRecoveryCohort()
                        await MainActor.run {
                            isCheckingRecoveryCohort = false
                        }
                    }
                }
                .disabled(isCheckingRecoveryCohort)
                .font(.system(size: 14, weight: .semibold))
            }
            }

            Section("Snapshot Package Validation") {
                Text("Selected-session package validation. It keeps canonical reads disabled, does not activate, does not write remote state, and removes package-candidate diagnostic artifacts before a pass.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if let packageValidationReport {
                    diagnosticRow("Package Parity", packageValidationReport.packageParity.state.rawValue)
                    diagnosticRow("Package Blockers", packageValidationReport.packageParity.blockers.isEmpty ? "none" : packageValidationReport.packageParity.blockers.joined(separator: ", "))
                    diagnosticRow("Rollback", packageValidationReport.fullyRestoredRollback.state.rawValue)
                    diagnosticRow("Rollback Blockers", packageValidationReport.fullyRestoredRollback.blockers.isEmpty ? "none" : packageValidationReport.fullyRestoredRollback.blockers.joined(separator: ", "))
                    diagnosticRow("Snapshot ID", packageValidationReport.snapshotID?.uuidString ?? "none")
                    NavigationLink {
                        DebugSessionSnapshotUploadTextView(
                            snapshotText: packageValidationReport.combinedReportText,
                            title: "Package Validation",
                            footerText: "Copies the selected-session package validation reports as plain text. It does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads."
                        )
                    } label: {
                        Text("View Copyable Package Validation Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                } else {
                    diagnosticRow("Package Parity", "not run")
                    diagnosticRow("Rollback", "not run")
                }
                Button(isRunningPackageValidation ? "Running..." : AppState.localHealthSessionSnapshotPackageValidationActionTitle) {
                    guard !isRunningPackageValidation else { return }
                    isRunningPackageValidation = true
                    Task {
                        let report = await appState.runLocalHealthSelectedSessionSnapshotPackageValidation()
                        await MainActor.run {
                            packageValidationReport = report
                            isRunningPackageValidation = false
                        }
                    }
                }
                .disabled(isRunningPackageValidation)
                .font(.system(size: 14, weight: .semibold))
            }

            DebugSessionSnapshotCanonicalReadDiagnosticsSection(
                appState: appState,
                diagnostics: diagnostics,
                isCheckingCanonicalReadDiagnostics: $isCheckingCanonicalReadDiagnostics,
                isBuildingCanonicalCandidateOverlay: $isBuildingCanonicalCandidateOverlay,
                uploadTarget: uploadTarget,
                packageValidationReport: packageValidationReport
            )
        }
        .navigationTitle("Snapshot Upload")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Hydrate Metadata From Snapshot?", isPresented: $isShowingHydrationConfirmation) {
            Button("Cancel", role: .cancel) {}
            if hydrationConfirmation.canHydrate {
                Button("Hydrate Local Metadata Only", role: .destructive) {
                    isHydratingSnapshotMetadata = true
                    Task {
                        _ = await appState.hydrateMetadataFromLatestSessionSnapshot()
                        await MainActor.run {
                            isHydratingSnapshotMetadata = false
                        }
                    }
                }
            }
        } message: {
            Text(hydrationConfirmation.messageText)
        }
        .alert("Retrieve Snapshot Media Test-Only?", isPresented: $isShowingMediaRetrievalConfirmation) {
            Button("Cancel", role: .cancel) {}
            if mediaRetrievalConfirmation.canRetrieve {
                Button("Retrieve Test Media", role: .destructive) {
                    isRetrievingSnapshotMedia = true
                    Task {
                        _ = await appState.retrieveSnapshotMediaTestOnly()
                        await MainActor.run {
                            isRetrievingSnapshotMedia = false
                        }
                    }
                }
            }
        } message: {
            Text(mediaRetrievalConfirmation.messageText)
        }
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: Int) -> some View {
        diagnosticRow(label, String(value))
    }

    private func optionalBoolText(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "not checked"
    }

    @ViewBuilder
    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func formattedRunDate(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "never"
    }
}

private struct DebugSessionSnapshotCanonicalReadDiagnosticsSection: View {
    @ObservedObject var appState: AppState
    let diagnostics: AppState.SessionSnapshotUploadDiagnostics
    @Binding var isCheckingCanonicalReadDiagnostics: Bool
    @Binding var isBuildingCanonicalCandidateOverlay: Bool
    let uploadTarget: AppState.ManualSessionSnapshotUploadTarget?
    let packageValidationReport: AppState.LocalHealthSessionSnapshotPackageValidationReport?
    @State private var isShowingCanonicalCandidateActivationConfirmation = false
    @State private var isActivatingCanonicalCandidate = false
    @State private var isRollingBackCanonicalCandidate = false
    @State private var isReplayingFlaggedObservationShadowWrites = false
    @State private var flaggedObservationReplayActionResult: AppState.SelectedSessionFlaggedObservationReplayActionResult?
    @State private var isReplayingSelectedSessionLifecycleShadowWrite = false
    @State private var selectedSessionLifecycleReplayActionResult: AppState.SelectedSessionLifecycleReplayActionResult?
    @State private var operatorApproval: AppState.ProductionCohortOperatorApprovalDiagnostics?
    @State private var isAuthorizingSelectedSessionQA = false
    @State private var isRunningSelectedSessionValidationPipeline = false
    @State private var selectedSessionValidationPipelineReport: AppState.LocalHealthSelectedSessionValidationPipelineReport?

    private var rolloutReadiness: AppState.CanonicalRolloutReadinessDiagnostics {
        AppState.makeCanonicalRolloutReadinessDiagnostics(diagnostics)
    }

    private var activationGate: AppState.ProductionSingleSessionActivationGateDiagnostics {
        appState.productionSingleSessionActivationGateForSelectedSession(approval: operatorApproval)
    }

    private var packageEvidenceReady: Bool {
        packageValidationReport?.packageParity.state == .testOnlyPackageParityPassed &&
            packageValidationReport?.packageParity.blockers.isEmpty == true &&
            packageValidationReport?.fullyRestoredRollback.state == .testOnlyFullyRestoredPackageRollbackPassed &&
            packageValidationReport?.fullyRestoredRollback.blockers.isEmpty == true
    }

    private var qaControlsPresentation: AppState.LocalHealthSelectedSessionQAControlsPresentationState {
        appState.localHealthSelectedSessionQAControlsPresentationState
    }

    var body: some View {
        Group {
        Section("Controlled Activation Evaluation") {
            Text("Selected-session diagnostic activation evaluation only. This does not enable broad canonical reads, change supabase_read_enabled, write remote state, or change export, seal, sync, media, or iCloud behavior.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if let uploadTarget {
                diagnosticRow("Selected Property", uploadTarget.propertyName)
                diagnosticRow("Selected Org", diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID?.uuidString ?? "none")
                diagnosticRow("Property ID", uploadTarget.propertyID.uuidString)
                diagnosticRow("Session ID", uploadTarget.sessionID.uuidString)
                diagnosticRow("Session Status", uploadTarget.sessionStatus.rawValue)
            } else {
                diagnosticRow("Selected Org", diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID?.uuidString ?? "none")
                diagnosticRow("Selected Property", diagnostics.lastCanonicalReadDiagnosticsPropertyID?.uuidString ?? "none")
                diagnosticRow("Session ID", diagnostics.lastCanonicalReadDiagnosticsSessionID?.uuidString ?? "none")
            }
            diagnosticRow("Snapshot ID", packageValidationReport?.snapshotID?.uuidString ?? diagnostics.lastRestoreDiagnosticsSnapshotID?.uuidString ?? "none")
            diagnosticRow("Package Parity", packageValidationReport?.packageParity.state.rawValue ?? "not run")
            diagnosticRow("Package Blockers", packageValidationReport.map { $0.packageParity.blockers.isEmpty ? "none" : compactListSummary($0.packageParity.blockers) } ?? "not run")
            diagnosticRow("Rollback Validation", packageValidationReport?.fullyRestoredRollback.state.rawValue ?? "not run")
            diagnosticRow("Rollback Blockers", packageValidationReport.map { $0.fullyRestoredRollback.blockers.isEmpty ? "none" : compactListSummary($0.fullyRestoredRollback.blockers) } ?? "not run")
            diagnosticRow("Package Evidence Ready", packageEvidenceReady ? "true" : "false")
            diagnosticRow("Candidate Diagnostics Ready", diagnostics.lastCanonicalReadCandidateAllowed ? "true" : "false")
            diagnosticRow("Overlay Ready", diagnostics.lastCanonicalCandidateOverlayAllowed ? "true" : "false")
            diagnosticRow("Operator Approval", operatorApproval?.state.rawValue ?? "not recorded")
            diagnosticRow("Approval Scope", operatorApproval?.approvedScope.description ?? "none")
            diagnosticRow("Approval Expires", formattedDate(operatorApproval?.expirationTimestamp))
            diagnosticRow("Approval Blocked", compactValue(operatorApproval?.approvalBlockedReason ?? "none"))
            diagnosticRow("Activation Gate", activationGate.productionSingleSessionActivationGateEnabled ? "enabled" : "disabled")
            diagnosticRow("Gate Allowed", activationGate.gateAllowed ? "true" : "false")
            diagnosticRow("Gate Blocked", compactValue(activationGate.gateBlockedReason ?? "none"))
            diagnosticRow("Gate Selected Scope", activationGate.selectedScope.description)
            diagnosticRow("Gate Approved Scope", activationGate.approvedScope.description)
            diagnosticRow("Activation Allowed", diagnostics.lastCanonicalCandidateActivationAllowed ? "true" : "false")
            diagnosticRow("Activation Blocked", compactValue(diagnostics.lastCanonicalCandidateActivationBlockedReason))
            diagnosticRow("Active Source", diagnostics.lastCanonicalCandidateActivationActiveSource)
            diagnosticRow("Rollback Availability", diagnostics.lastCanonicalCandidateActivationRollbackAvailable ? "available" : "missing")
            diagnosticRow("supabase_read_enabled", appState.backendFeatureFlags.supabaseReadEnabled ? "true" : "false")
            diagnosticRow("Broad Canonical Reads", diagnostics.lastCanonicalReadCandidateProductionWideEnabled ? "enabled" : "disabled")
            diagnosticRow("QA Authorization", diagnostics.runtimeSelectedSessionQAAuthAuthorized ? "authorized" : "not authorized")
            diagnosticRow("QA Authorized Org", diagnostics.runtimeSelectedSessionQAAuthOrgID?.uuidString ?? "none")
            diagnosticRow("QA Authorized Property", diagnostics.runtimeSelectedSessionQAAuthPropertyID?.uuidString ?? "none")
            diagnosticRow("QA Authorized Session", diagnostics.runtimeSelectedSessionQAAuthSessionID?.uuidString ?? "none")
            diagnosticRow("QA Authorized At", formattedDate(diagnostics.runtimeSelectedSessionQAAuthAuthorizedAt))
            diagnosticRow("QA Expires", formattedDate(diagnostics.runtimeSelectedSessionQAAuthExpiresAt))
            diagnosticRow("QA Freshness", diagnostics.runtimeSelectedSessionQAAuthFreshness)
            diagnosticRow("QA Scope Match", diagnostics.runtimeSelectedSessionQAAuthScopeMatches ? "true" : "false")
            diagnosticRow("QA Clear Reason", compactValue(diagnostics.runtimeSelectedSessionQAAuthClearReason ?? "none"))
            diagnosticRow("Pipeline State", diagnostics.lastSelectedSessionValidationPipelineState)
            diagnosticRow("Pipeline Blocker", compactValue(diagnostics.lastSelectedSessionValidationPipelineBlocker ?? "none"))
            diagnosticRow("QA Controls", qaControlsPresentation.controlsMounted ? "available" : "blocked")
            if let blocker = qaControlsPresentation.blocker {
                diagnosticRow("QA Controls Blocker", blocker)
                diagnosticRow("QA Target Reason", compactValue(qaControlsPresentation.targetResolutionReason))
            }
        }

        Section("Canonical Read - Rollout Readiness") {
            diagnosticRow("Readiness State", rolloutReadiness.state.rawValue)
            diagnosticRow("Next Action", rolloutReadiness.nextRecommendedAction)
            diagnosticRow("Checklist", rolloutReadiness.checklistPassed ? "pass" : "needs review")
            diagnosticRow("Blockers", compactListSummary(rolloutReadiness.blockers))
            ForEach(rolloutReadiness.checklist) { item in
                diagnosticRow(item.label, item.passed ? "pass" : "fail")
            }
        }

        Section("Canonical Read - Read Diagnostics") {
            Text("Read-only local-vs-remote normalized row comparison. It does not switch canonical reads, hydrate data, restore files, download media, or change local or remote state.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            diagnosticRow("Result", diagnostics.lastCanonicalReadDiagnosticsResult)
            diagnosticRow("Checked", formattedDate(diagnostics.lastCanonicalReadDiagnosticsAt))
            diagnosticRow("Verified Org", diagnostics.lastCanonicalReadDiagnosticsVerifiedOrgID?.uuidString ?? "none")
            diagnosticRow("Property ID", diagnostics.lastCanonicalReadDiagnosticsPropertyID?.uuidString ?? "none")
            diagnosticRow("Session ID", diagnostics.lastCanonicalReadDiagnosticsSessionID?.uuidString ?? "none")
            diagnosticRow("Local Property", diagnostics.lastCanonicalReadDiagnosticsLocalPropertyFound ? "true" : "false")
            diagnosticRow("Local Session", diagnostics.lastCanonicalReadDiagnosticsLocalSessionFound ? "true" : "false")
            diagnosticRow("Remote Property", diagnostics.lastCanonicalReadDiagnosticsRemotePropertyFound ? "true" : "false")
            diagnosticRow("Remote Session", diagnostics.lastCanonicalReadDiagnosticsRemoteSessionFound ? "true" : "false")
            diagnosticRow("Count Parity", optionalBoolText(diagnostics.lastCanonicalReadDiagnosticsCountParity))
            diagnosticRow("Status Parity", optionalBoolText(diagnostics.lastCanonicalReadDiagnosticsStatusParity))
            diagnosticRow("Parent Org", optionalBoolText(diagnostics.lastCanonicalReadDiagnosticsParentOrgConsistent))
            diagnosticRow("Parent Property", optionalBoolText(diagnostics.lastCanonicalReadDiagnosticsParentPropertyConsistent))
            diagnosticRow("Local Shots", diagnostics.lastCanonicalReadDiagnosticsLocalShotCount.map(String.init) ?? "none")
            diagnosticRow("Remote Shots", diagnostics.lastCanonicalReadDiagnosticsRemoteShotCount.map(String.init) ?? "none")
            diagnosticRow("Local Issues/Obs", diagnostics.lastCanonicalReadDiagnosticsLocalIssueObservationCount.map(String.init) ?? "none")
            diagnosticRow("Remote Issues/Obs", diagnostics.lastCanonicalReadDiagnosticsRemoteIssueObservationCount.map(String.init) ?? "none")
            diagnosticRow("Local Guided", diagnostics.lastCanonicalReadDiagnosticsLocalGuidedCount.map(String.init) ?? "none")
            diagnosticRow("Local Known State", formattedDate(diagnostics.lastCanonicalReadDiagnosticsLocalKnownStateAt))
            diagnosticRow("Known State Source", diagnostics.lastCanonicalReadDiagnosticsLocalKnownStateSource ?? "none")
            diagnosticRow("Remote Freshness Seconds", diagnostics.lastCanonicalReadDiagnosticsRemoteFreshnessAgeSeconds.map { String(Int($0)) } ?? "unknown")
            diagnosticRow("Remote Revision", diagnostics.lastCanonicalReadDiagnosticsRemoteRevision.map(String.init) ?? "none")
            diagnosticRow("Recommendation", diagnostics.lastCanonicalReadDiagnosticsRecommendation)
            if let blockedReason = AppState.diagnosticsPreviewText(diagnostics.lastCanonicalReadDiagnosticsBlockedReason, maxLength: 160) {
                diagnosticRow("Blocked Reason", blockedReason)
            }
        }

        Section("Canonical Read - Parity / Repair") {
            diagnosticRow("Parity Gaps", compactListSummary(diagnostics.lastNormalizedParityGapTaxonomy))
            diagnosticRow("Completeness", diagnostics.lastNormalizedParityCompleteness)
            diagnosticRow("Shadow Coverage", diagnostics.lastRemoteShadowWriteCoverage)
            diagnosticRow("Missing Remote", diagnostics.lastMissingRemoteEntityClassification)
            diagnosticRow("Lineage Source", diagnostics.lastLineageDivergenceSource)
            diagnosticRow("Repair Tooling", diagnostics.lastParityRepairToolingRecommended ? "recommended" : "not required")
            diagnosticRow("Canonical Blocked", diagnostics.lastCanonicalReadsRemainBlocked ? "true" : "false")
            diagnosticRow("Repair Strategies", compactListSummary(diagnostics.lastParityRepairStrategies))
            diagnosticRow("Completeness Score", String(format: "%.2f", diagnostics.lastParityCompletenessScore))
            diagnosticRow("Shadow Score", String(format: "%.2f", diagnostics.lastShadowWriteCoverageScore))
            diagnosticRow("Lineage Confidence", diagnostics.lastLineageConfidence)
            diagnosticRow("Missing Child Count", "\(diagnostics.lastMissingChildCount)")
            diagnosticRow("Replay Eligibility", diagnostics.lastReplayEligibility)
            diagnosticRow("Repair Phase", diagnostics.lastParityRepairRolloutPhase)
            diagnosticRow("Backfill Eligible", diagnostics.lastNormalizedBackfillEligible ? "true" : "false")
            diagnosticRow("Backfill Blocked", diagnostics.lastNormalizedBackfillBlockedReason)
            diagnosticRow("Backfill Planned", "sessions \(diagnostics.lastNormalizedBackfillPlannedSessionUpserts), shots \(diagnostics.lastNormalizedBackfillPlannedShotUpserts), observations \(diagnostics.lastNormalizedBackfillPlannedObservationUpserts)")
            diagnosticRow("Backfill Executed", "\(diagnostics.lastNormalizedBackfillExecutedEntityCount)")
            diagnosticRow("Backfill Skipped", "\(diagnostics.lastNormalizedBackfillSkippedEntityCount)")
            diagnosticRow("Remote Newer Conflicts", "\(diagnostics.lastNormalizedBackfillRemoteNewerConflictCount)")
            diagnosticRow("Production Backfill", diagnostics.lastNormalizedBackfillProductionBlocked ? "blocked" : "not blocked")
        }

        Section("Canonical Read - Candidate") {
            diagnosticRow("Candidate Flag", diagnostics.lastCanonicalReadCandidateFlagEnabled ? "enabled" : "off")
            diagnosticRow("Candidate Allowed", diagnostics.lastCanonicalReadCandidateAllowed ? "true" : "false")
            diagnosticRow("Candidate Blocked", compactValue(diagnostics.lastCanonicalReadCandidateBlockedReason))
            diagnosticRow("Effective Source", diagnostics.lastCanonicalReadCandidateEffectiveSourceRecommendation)
            diagnosticRow("Local Fallback", diagnostics.lastCanonicalReadCandidateLocalFallbackAvailable ? "available" : "missing")
            diagnosticRow("Candidate Parity", String(format: "%.2f", diagnostics.lastCanonicalReadCandidateParityConfidence))
            diagnosticRow("Candidate Replay", String(format: "%.2f", diagnostics.lastCanonicalReadCandidateReplayConfidence))
            diagnosticRow("Candidate Media", String(format: "%.2f", diagnostics.lastCanonicalReadCandidateMediaRecoveryConfidence))
            diagnosticRow("Candidate Remote State", diagnostics.lastCanonicalReadCandidateRemoteStateReadable ? "readable" : "blocked")
            diagnosticRow("Candidate Scope", diagnostics.lastCanonicalReadCandidateProductionWideEnabled ? "production-wide" : "allowlisted/test-only")
            if !diagnostics.lastCanonicalReadCandidateWarnings.isEmpty {
                diagnosticRow("Candidate Warnings", compactListSummary(diagnostics.lastCanonicalReadCandidateWarnings))
            }
        }

        Section("Canonical Read - Overlay") {
            diagnosticRow("Overlay Built", diagnostics.lastCanonicalCandidateOverlayBuilt ? "true" : "false")
            diagnosticRow("Overlay Allowed", diagnostics.lastCanonicalCandidateOverlayAllowed ? "true" : "false")
            diagnosticRow("Overlay Blocked", compactValue(diagnostics.lastCanonicalCandidateOverlayBlockedReason))
            diagnosticRow("Overlay Source", diagnostics.lastCanonicalCandidateOverlaySource)
            diagnosticRow("Overlay Property", diagnostics.lastCanonicalCandidateOverlayPropertyID?.uuidString ?? "none")
            diagnosticRow("Overlay Session", diagnostics.lastCanonicalCandidateOverlaySessionID?.uuidString ?? "none")
            diagnosticRow("Overlay Shots", "\(diagnostics.lastCanonicalCandidateOverlayShotCount)")
            diagnosticRow("Overlay Issues", "\(diagnostics.lastCanonicalCandidateOverlayIssueObservationCount)")
            diagnosticRow("Overlay Fallback", diagnostics.lastCanonicalCandidateOverlayFallbackSource)
            diagnosticRow("Active Source", diagnostics.lastCanonicalCandidateOverlayActiveSource)
            diagnosticRow("Rollback/Fallback", diagnostics.lastCanonicalCandidateOverlayRollbackAvailable ? "available" : "missing")
            diagnosticRow("Overlay Production", diagnostics.lastCanonicalCandidateOverlayProductionBlocked ? "blocked" : "not blocked")
        }

        Section("Canonical Read - Comparison") {
            diagnosticRow("Comparison Result", diagnostics.lastCanonicalCandidateOverlayComparisonResult)
            diagnosticRow("Local Counts", "shots \(diagnostics.lastCanonicalCandidateOverlayComparisonLocalShotCount.map(String.init) ?? "none"), issues \(diagnostics.lastCanonicalCandidateOverlayComparisonLocalIssueObservationCount.map(String.init) ?? "none")")
            diagnosticRow("Candidate Counts", "shots \(diagnostics.lastCanonicalCandidateOverlayComparisonRemoteShotCount.map(String.init) ?? "none"), issues \(diagnostics.lastCanonicalCandidateOverlayComparisonRemoteIssueObservationCount.map(String.init) ?? "none")")
            diagnosticRow("Freshness", "local \(diagnostics.lastCanonicalCandidateOverlayComparisonLocalFreshness), remote \(diagnostics.lastCanonicalCandidateOverlayComparisonRemoteFreshness)")
            diagnosticRow("Why Trusted", compactValue(diagnostics.lastCanonicalCandidateOverlayComparisonTrustedReason))
            diagnosticRow("Why Blocked", compactValue(diagnostics.lastCanonicalCandidateOverlayComparisonBlockedReason))
        }

        Section("Canonical Read - Activation / Rollback") {
            diagnosticRow("Activation Allowed", diagnostics.lastCanonicalCandidateActivationAllowed ? "true" : "false")
            diagnosticRow("Activation Blocked", compactValue(diagnostics.lastCanonicalCandidateActivationBlockedReason))
            diagnosticRow("Activation Active Source", diagnostics.lastCanonicalCandidateActivationActiveSource)
            diagnosticRow("Activation Rollback Source", diagnostics.lastCanonicalCandidateActivationRollbackSource)
            diagnosticRow("Activation Scope", diagnostics.lastCanonicalCandidateActivationScope)
            diagnosticRow("Activation Property", diagnostics.lastCanonicalCandidateActivationPropertyID?.uuidString ?? "none")
            diagnosticRow("Activation Session", diagnostics.lastCanonicalCandidateActivationSessionID?.uuidString ?? "none")
            diagnosticRow("Activation Rollback", diagnostics.lastCanonicalCandidateActivationRollbackAvailable ? "available" : "missing")
            diagnosticRow("Last Activation", formattedDate(diagnostics.lastCanonicalCandidateActivationLastActivatedAt))
            diagnosticRow("Last Rollback", formattedDate(diagnostics.lastCanonicalCandidateActivationLastRolledBackAt))
            diagnosticRow("Production Activation", diagnostics.lastCanonicalCandidateActivationProductionBlocked ? "blocked" : "not blocked")
            if !diagnostics.lastCanonicalReadRolloutBlockers.isEmpty {
                diagnosticRow("Rollout Blockers", compactListSummary(diagnostics.lastCanonicalReadRolloutBlockers))
            }
        }

        Section("Controlled Activation Evaluation Actions") {
            NavigationLink {
                DebugSessionSnapshotUploadTextView(
                    snapshotText: AppState.canonicalReadRolloutReportText(
                        diagnostics,
                        operatorApproval: operatorApproval,
                        singleSessionActivationGatePolicy: AppState.loadProductionSingleSessionActivationGatePolicy()
                    ),
                    title: "Canonical Read Report",
                    footerText: "Copies the sanitized canonical-read rollout report as plain text. It keeps full canonical details out of the primary diagnostic rows and does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads."
                )
            } label: {
                Text("View Canonical Read Rollout Report")
                    .font(.system(size: 14, weight: .semibold))
            }
            Button(isCheckingCanonicalReadDiagnostics ? "Checking..." : "Check Canonical Read Diagnostics") {
                guard !isCheckingCanonicalReadDiagnostics else { return }
                isCheckingCanonicalReadDiagnostics = true
                Task {
                    _ = await appState.runCanonicalReadDiagnosticsForSelectedSession(
                        productionValidationEvidence: packageValidationReport
                    )
                    await MainActor.run {
                        isCheckingCanonicalReadDiagnostics = false
                    }
                }
            }
            .disabled(isCheckingCanonicalReadDiagnostics)
            .font(.system(size: 14, weight: .semibold))
            Button(isBuildingCanonicalCandidateOverlay ? "Building..." : "Build Canonical Candidate Overlay") {
                guard !isBuildingCanonicalCandidateOverlay else { return }
                isBuildingCanonicalCandidateOverlay = true
                Task {
                    _ = await appState.buildCanonicalCandidateOverlayForSelectedSession(
                        productionValidationEvidence: packageValidationReport
                    )
                    await MainActor.run {
                        isBuildingCanonicalCandidateOverlay = false
                    }
                }
            }
            .disabled(isBuildingCanonicalCandidateOverlay)
            .font(.system(size: 14, weight: .semibold))
            if qaControlsPresentation.controlsMounted {
                Button(isAuthorizingSelectedSessionQA ? "Authorizing..." : AppState.localHealthAuthorizeSelectedSessionQAActionTitle) {
                    guard !isAuthorizingSelectedSessionQA else { return }
                    isAuthorizingSelectedSessionQA = true
                    Task {
                        _ = await MainActor.run {
                            appState.authorizeSelectedSessionForQAValidation()
                        }
                        await MainActor.run {
                            isAuthorizingSelectedSessionQA = false
                        }
                    }
                }
                .disabled(isAuthorizingSelectedSessionQA)
                .font(.system(size: 14, weight: .semibold))
                Button(AppState.localHealthClearSelectedSessionQAActionTitle) {
                    _ = appState.clearSelectedSessionQAValidationAuthorization()
                }
                .disabled(!diagnostics.runtimeSelectedSessionQAAuthAuthorized)
                .font(.system(size: 14, weight: .semibold))
                Button(isRunningSelectedSessionValidationPipeline ? "Running..." : AppState.localHealthSelectedSessionValidationPipelineActionTitle) {
                    guard !isRunningSelectedSessionValidationPipeline else { return }
                    isRunningSelectedSessionValidationPipeline = true
                    Task {
                        let report = await appState.runSelectedSessionValidationPipeline()
                        await MainActor.run {
                            selectedSessionValidationPipelineReport = report
                            isRunningSelectedSessionValidationPipeline = false
                        }
                    }
                }
                .disabled(isRunningSelectedSessionValidationPipeline)
                .font(.system(size: 14, weight: .semibold))
                if let selectedSessionValidationPipelineReport {
                    diagnosticRow("Pipeline Result", selectedSessionValidationPipelineReport.state.rawValue)
                    diagnosticRow("Pipeline Final Blocker", compactValue(selectedSessionValidationPipelineReport.finalBlocker ?? "none"))
                    diagnosticRow("Pipeline Next Action", selectedSessionValidationPipelineReport.recommendedNextAction)
                    NavigationLink {
                        DebugSessionSnapshotUploadTextView(
                            snapshotText: selectedSessionValidationPipelineReport.reportText,
                            title: "Validation Pipeline",
                            footerText: "Copies the selected-session validation pipeline report as plain text. It is diagnostic-only and does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads."
                        )
                    } label: {
                        Text("View Copyable Validation Pipeline Report")
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            } else {
                diagnosticRow("QA Controls", "blocked")
                diagnosticRow("QA Controls Blocker", qaControlsPresentation.blocker ?? "selected_session_required")
                diagnosticRow("QA Target Reason", compactValue(qaControlsPresentation.targetResolutionReason))
                if let selectedPropertyID = qaControlsPresentation.selectedPropertyID {
                    diagnosticRow("QA Selected Property", selectedPropertyID.uuidString)
                }
            }
            Button(isReplayingFlaggedObservationShadowWrites ? "Replaying..." : AppState.localHealthFlaggedObservationReplayActionTitle) {
                guard !isReplayingFlaggedObservationShadowWrites else { return }
                isReplayingFlaggedObservationShadowWrites = true
                Task {
                    let result = await appState.replayFlaggedObservationShadowWritesForSelectedSession(
                        productionValidationEvidence: packageValidationReport
                    )
                    await MainActor.run {
                        flaggedObservationReplayActionResult = result
                        isReplayingFlaggedObservationShadowWrites = false
                    }
                }
            }
            .disabled(isReplayingFlaggedObservationShadowWrites)
            .font(.system(size: 14, weight: .semibold))
            if let flaggedObservationReplayActionResult {
                diagnosticRow("Replay Action", flaggedObservationReplayActionResult.allowed ? "allowed" : "blocked")
                diagnosticRow("Replay Blocked", compactValue(flaggedObservationReplayActionResult.blockedReason ?? "none"))
                diagnosticRow("Replay Scope", "property \(flaggedObservationReplayActionResult.propertyID?.uuidString ?? "none"), session \(flaggedObservationReplayActionResult.sessionID?.uuidString ?? "none")")
                if let replay = flaggedObservationReplayActionResult.replayResult {
                    diagnosticRow("Replay Result", replay.message)
                    diagnosticRow("Replay Executed", "\(replay.upsertedCount)")
                    diagnosticRow("Replay Skipped", "\(replay.skippedCount)")
                    diagnosticRow("Replay Remote Newer", "\(replay.remoteNewerConflictCount)")
                    diagnosticRow("Replay Failed", "\(replay.failedCount)")
                }
                diagnosticRow("Post-Replay Diagnostics", flaggedObservationReplayActionResult.diagnosticsAfterReplay == nil ? "not run" : "refreshed")
            }
            Button(isReplayingSelectedSessionLifecycleShadowWrite ? "Replaying..." : AppState.localHealthSelectedSessionLifecycleReplayActionTitle) {
                guard !isReplayingSelectedSessionLifecycleShadowWrite else { return }
                isReplayingSelectedSessionLifecycleShadowWrite = true
                Task {
                    let result = await appState.replaySelectedSessionLifecycleShadowWriteForSelectedSession(
                        productionValidationEvidence: packageValidationReport
                    )
                    await MainActor.run {
                        selectedSessionLifecycleReplayActionResult = result
                        isReplayingSelectedSessionLifecycleShadowWrite = false
                    }
                }
            }
            .disabled(isReplayingSelectedSessionLifecycleShadowWrite)
            .font(.system(size: 14, weight: .semibold))
            if let selectedSessionLifecycleReplayActionResult {
                diagnosticRow("Lifecycle Replay Action", selectedSessionLifecycleReplayActionResult.allowed ? "allowed" : "blocked")
                diagnosticRow("Lifecycle Replay Blocked", compactValue(selectedSessionLifecycleReplayActionResult.blockedReason ?? "none"))
                diagnosticRow("Lifecycle Replay Scope", "property \(selectedSessionLifecycleReplayActionResult.propertyID?.uuidString ?? "none"), session \(selectedSessionLifecycleReplayActionResult.sessionID?.uuidString ?? "none")")
                if let replay = selectedSessionLifecycleReplayActionResult.replayResult {
                    diagnosticRow("Lifecycle Planned", "\(replay.attemptedCount)")
                    diagnosticRow("Lifecycle Executed", "\(replay.upsertedCount)")
                    diagnosticRow("Lifecycle Skipped", "\(replay.skippedCount)")
                    diagnosticRow("Lifecycle Remote Newer", "\(replay.remoteNewerConflictCount)")
                    diagnosticRow("Lifecycle Failed", "\(replay.failedCount)")
                    diagnosticRow("Lifecycle Result", replay.message)
                }
                diagnosticRow("Lifecycle Post-Replay Diagnostics", selectedSessionLifecycleReplayActionResult.diagnosticsAfterReplay == nil ? "not run" : "refreshed")
            }
            Button("Record Fresh Operator Approval") {
                operatorApproval = appState.makeProductionSingleSessionOperatorApprovalForSelectedSession()
            }
            .font(.system(size: 14, weight: .semibold))
            Button("Clear Operator Approval") {
                operatorApproval = nil
            }
            .disabled(operatorApproval == nil)
            .font(.system(size: 14, weight: .semibold))
            Button(isActivatingCanonicalCandidate ? "Activating..." : "Activate Canonical Candidate For Session") {
                guard !isActivatingCanonicalCandidate else { return }
                isShowingCanonicalCandidateActivationConfirmation = true
            }
            .disabled(isActivatingCanonicalCandidate)
            .font(.system(size: 14, weight: .semibold))
            .alert("Activate Canonical Candidate?", isPresented: $isShowingCanonicalCandidateActivationConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Activate") {
                    guard !isActivatingCanonicalCandidate else { return }
                    isActivatingCanonicalCandidate = true
                    Task {
                        _ = await MainActor.run {
                            appState.activateCanonicalCandidateForSelectedSession(operatorApproval: operatorApproval)
                        }
                        await MainActor.run {
                            isActivatingCanonicalCandidate = false
                        }
                    }
                }
            } message: {
                Text("Selected session only. Active read source changes to the candidate overlay for this diagnostic scope, local fallback stays retained, export/seal/sync/media/iCloud behavior is unchanged, and production remains blocked.")
            }
            Button(isRollingBackCanonicalCandidate ? "Rolling Back..." : "Rollback To Local Source") {
                guard !isRollingBackCanonicalCandidate else { return }
                isRollingBackCanonicalCandidate = true
                Task {
                    _ = await MainActor.run {
                        appState.rollbackCanonicalCandidateToLocalSource()
                    }
                    await MainActor.run {
                        isRollingBackCanonicalCandidate = false
                    }
                }
            }
            .disabled(isRollingBackCanonicalCandidate)
            .font(.system(size: 14, weight: .semibold))
        }
        }
    }

    private func optionalBoolText(_ value: Bool?) -> String {
        value.map { $0 ? "true" : "false" } ?? "not checked"
    }

    private func compactListSummary(_ values: [String]) -> String {
        guard !values.isEmpty else { return "none" }
        let preview = values.prefix(2).joined(separator: ", ")
        guard values.count > 2 else { return preview }
        return "\(preview) +\(values.count - 2) more"
    }

    private func compactValue(_ value: String) -> String {
        AppState.diagnosticsPreviewText(value, maxLength: 80) ?? "none"
    }
}

private struct DebugSessionSnapshotUploadTextView: View {
    let snapshotText: String
    var title: String = "Snapshot Upload Report"
    var footerText: String = "Copies the sanitized shadow-write upload report as plain text. It does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads."
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text(footerText)
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct StageLazySessionSnapshotUploadTextView: View {
    var title: String = "Snapshot Upload Report"
    var footerText: String = "Copies the sanitized shadow-write upload report as plain text. It does not include raw session.json, local paths, signed URLs, auth material, storage object paths, or media payloads."
    let reportText: () -> String

    var body: some View {
        DebugSessionSnapshotUploadTextView(
            snapshotText: reportText(),
            title: title,
            footerText: footerText
        )
    }
}

private struct DebugExportSealPreflightSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized advisory preflight report as plain text only. It does not include local paths, signed URLs, media, or auth material.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Preflight Report")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugFutureEnforcementWarningsSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized future enforcement warnings report as plain text only. It does not include local paths, signed URLs, media, or auth material.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Future Warnings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugEnforcementPolicyMatrixSnapshotTextView: View {
    let snapshotText: String
    @State private var didCopySnapshot: Bool = false

    var body: some View {
        List {
            Section {
                Button(didCopySnapshot ? "Copied Plain Text" : "Copy Report") {
                    UIPasteboard.general.string = snapshotText
                    didCopySnapshot = true
                }
                .font(.system(size: 14, weight: .semibold))
            } footer: {
                Text("Copies the sanitized enforcement policy matrix as plain text only. It does not include local paths, signed URLs, media, or auth material.")
            }

            Section {
                Text(snapshotText)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Policy Matrix")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugOfflineQueueItemDetailView: View {
    @EnvironmentObject private var appState: AppState
    let item: DebugQueueDiagnosticSnapshotItem
    let onAcknowledged: () -> Void

    @State private var showAcknowledgeConfirmation = false
    @State private var acknowledgementMessage: String?

    var body: some View {
        List {
            Section("Queue Item") {
                diagnosticRow("Entity Type", item.entityType)
                diagnosticRow("Entity ID", item.entityID)
                diagnosticRow("Operation", item.operation)
                diagnosticRow("Status", item.status)
                diagnosticRow("Attempt Count", item.attemptCount)
                diagnosticRow("Last Attempt", item.lastAttempt)
                diagnosticRow("Next Attempt", item.nextAttempt)
                diagnosticRow("Age", item.age)
                diagnosticRow("Acknowledged", item.isAcknowledged ? "yes" : "no")
            }

            Section("Last Error") {
                if let error = item.lastErrorFull {
                    diagnosticBlock("Sanitized Error", error)
                } else {
                    Text("No last error recorded.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            if item.isAcknowledged {
                Section("Acknowledgement") {
                    diagnosticRow("Acknowledged At", item.acknowledgedAt)
                    diagnosticRow("Classification", item.acknowledgedClassification)
                    diagnosticRow("Source", item.acknowledgementSource)
                    diagnosticBlock("Reason", item.acknowledgedReason)
                    Text("This queue item is preserved for audit and skipped by offline replay.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Acknowledge Historical Queue Debt") {
                    Text("Only failed stale RLS property/session upserts can be acknowledged. This preserves the queue item and stops replay without changing local records or remote data.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button("Acknowledge Historical Queue Debt") {
                        showAcknowledgeConfirmation = true
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
            }

            if let acknowledgementMessage {
                Section {
                    Text(acknowledgementMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Queue Item")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Acknowledge Historical Queue Debt?",
            isPresented: $showAcknowledgeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Acknowledge Historical Queue Debt") {
                acknowledgeHistoricalQueueDebt()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The queue item, payload, last error, attempts, idempotency key, and local records will be preserved. Offline replay will skip only this acknowledged item.")
        }
    }

    private func acknowledgeHistoricalQueueDebt() {
        do {
            _ = try appState.acknowledgeHistoricalQueueDebt(
                queueItemID: item.id,
                reason: "Acknowledged as historical stale RLS queue debt from Local Health.",
                acknowledgementSource: "local_health"
            )
            acknowledgementMessage = "Acknowledged. This queue item is preserved for audit and will be skipped by offline replay."
            onAcknowledged()
        } catch {
            acknowledgementMessage = AppState.diagnosticsPreviewText(error.localizedDescription, maxLength: 240) ?? "Unable to acknowledge this queue item."
        }
    }
}

private struct DebugMediaDiagnosticItemDetailView: View {
    let item: DebugMediaDiagnosticSnapshotItem

    var body: some View {
        List {
            Section("Media Item") {
                diagnosticRow("Shot ID", item.shotID)
                diagnosticRow("Session ID", item.sessionID)
                diagnosticRow("Property ID", item.propertyID)
                diagnosticRow("Upload State", item.uploadState)
                diagnosticRow("Attempt Count", item.attemptCount)
                diagnosticRow("Local Filename", item.localFilename)
                diagnosticRow("Storage Path Exists", item.hasStoragePath)
            }

            Section("Last Upload Error") {
                if let error = item.lastUploadErrorFull {
                    diagnosticBlock("Sanitized Error", error)
                } else {
                    Text("No last upload error recorded.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Media Item")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct DebugMediaRecoveryCandidateDetailView: View {
    @EnvironmentObject private var appState: AppState
    let item: DebugMediaRecoverySnapshotItem
    @State private var showRetryConfirm: Bool = false
    @State private var isRetrying: Bool = false
    @State private var retryResultMessage: String?

    var body: some View {
        List {
            Section {
                Text("Selected-candidate recovery only. This screen never retries all candidates, deletes media, resets retry caps globally, or marks items ignored.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Draft or test sessions should be reviewed before retry.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if item.canRetry {
                    Button(isRetrying ? "Retrying..." : "Retry This Candidate") {
                        showRetryConfirm = true
                    }
                    .disabled(isRetrying)
                    .font(.system(size: 14, weight: .semibold))
                } else {
                    diagnosticRow("Retry Unavailable", item.retryUnavailableReason)
                }
                if let retryResultMessage {
                    diagnosticBlock("Last Retry Result", retryResultMessage)
                }
            }

            Section("Classification") {
                diagnosticRow("Classification", item.classification)
                diagnosticRow("Sources", item.sourceReasons)
                diagnosticRow("Active Org", item.activeOrganizationID)
                diagnosticRow("Reconciled Org", item.reconciledOrganizationID)
                diagnosticRow("Stale Local Org", item.staleLocalOrg)
            }

            Section("Property / Session") {
                diagnosticRow("Property Name", item.propertyName)
                diagnosticRow("Property ID", item.propertyID)
                diagnosticRow("Property Org ID", item.propertyOrgID)
                diagnosticRow("Session ID", item.sessionID)
                diagnosticRow("Session Status", item.sessionStatus)
                diagnosticRow("Session Started", item.sessionStartedAt)
                diagnosticRow("Session Sealed", item.sessionIsSealed)
                diagnosticRow("Session Org ID", item.sessionOrgID)
            }

            Section("Shot / Local File") {
                diagnosticRow("Shot ID", item.shotID)
                diagnosticRow("Flagged Shot", item.shotIsFlagged)
                diagnosticRow("Upload State", item.uploadState)
                diagnosticRow("Upload Attempts", item.uploadAttempts)
                diagnosticRow("File Exists", item.fileExists)
                diagnosticRow("Local Filename", item.localFilename)
                diagnosticRow("Importance Hint", item.importanceHint)
            }

            Section("Remote Preflight") {
                diagnosticRow("Preflight Available", item.remotePreflightAvailable)
                diagnosticRow("Remote Property", item.remotePropertyExists)
                diagnosticRow("Remote Session", item.remoteSessionExists)
                diagnosticRow("Remote Shot", item.remoteShotExists)
                diagnosticRow("Remote Storage Path", item.remoteStoragePathPresent)
            }

            Section("Last Upload Error") {
                if let error = item.lastUploadErrorFull {
                    diagnosticBlock("Sanitized Error", error)
                } else {
                    Text("No last upload error recorded.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Recovery Candidate")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Retry Media Candidate?", isPresented: $showRetryConfirm) {
            Button("Retry", role: .destructive) {
                runRetry()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This retries only this selected candidate after preflight. It does not retry all candidates, delete media, reset retry caps globally, or mark anything ignored.")
        }
    }

    private func runRetry() {
        guard !isRetrying,
              let propertyID = UUID(uuidString: item.propertyID),
              let sessionID = UUID(uuidString: item.sessionID),
              let shotID = UUID(uuidString: item.shotID) else {
            retryResultMessage = "Retry could not start because one or more IDs were invalid."
            return
        }
        isRetrying = true
        Task {
            let result = await appState.retryMediaRecoveryCandidate(
                propertyID: propertyID,
                sessionID: sessionID,
                shotID: shotID
            )
            await MainActor.run {
                retryResultMessage = "\(result.status.rawValue): \(result.message)"
                isRetrying = false
            }
        }
    }
}

private struct DebugDivergenceAuditItemDetailView: View {
    let item: DebugDivergenceAuditSnapshotItem

    var body: some View {
        List {
            Section("Finding") {
                diagnosticRow("Severity", item.severity)
                diagnosticRow("Category", item.category)
                diagnosticRow("Entity Type", item.entityType)
                diagnosticRow("Entity ID", item.entityID)
                diagnosticRow("Property ID", item.propertyID)
                diagnosticRow("Session ID", item.sessionID)
                diagnosticRow("Shot ID", item.shotID)
                diagnosticRow("Org ID", item.orgID)
            }

            Section("Reason") {
                diagnosticBlock("Audit Reason", item.reasonFull)
            }
        }
        .navigationTitle("Audit Finding")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@ViewBuilder
private func diagnosticRow(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
        Text(label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
        Spacer(minLength: 12)
        Text(value)
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
}

@ViewBuilder
private func diagnosticBlock(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
        Text(value)
            .font(.system(size: 13, weight: .regular, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

nonisolated private func formattedDate(_ date: Date?) -> String {
    guard let date else { return "none" }
    return date.formatted(date: .abbreviated, time: .standard)
}

nonisolated private func formattedAge(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "unknown" }
    let clamped = max(0, Int(seconds.rounded()))
    let days = clamped / 86_400
    let hours = (clamped % 86_400) / 3_600
    let minutes = (clamped % 3_600) / 60
    let remainingSeconds = clamped % 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(remainingSeconds)s" }
    return "\(remainingSeconds)s"
}

private struct FastRuntimeCameraPreviewRequest: Identifiable {
    let id = UUID()
    let context: ActiveCaptureContext
    let propertyName: String
    let result: AppState.FastRuntimePrototypeResult
    let buttonTappedAt: Date
    let contextReadyAt: Date
    let previewRequestedAt: Date
    let initialCapturedCount: Int
    let storageRoot: URL?
    let isDraftResume: Bool
    let initialLocationMode: CameraChromeLocationMode?
    let initialMetadataContext: AppState.FastRuntimeCaptureMetadataContext?
}

private extension CameraChromeLocationMode {
    init(fastRuntimeRawValue value: String?) {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "interior":
            self = .interior
        case "exterior":
            self = .exterior
        default:
            self = .exterior
        }
    }
}

private struct FastLaneDraftIssue: Identifiable {
    let id = UUID()
    let property: Property
    let message: String
}

private struct DebugFastRuntimePrototypeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPropertyID: UUID?
    @State private var selectedSessionType: SessionType = .fullDocumentation
    @State private var prepareTempStorage: Bool = true
    @State private var releaseClaim: Bool = true
    @State private var allowCurrentUserOccupiedContext: Bool = false
    @State private var isRunning: Bool = false
    @State private var isOpeningPrototypePreview: Bool = false
    @State private var isReleasingCurrentUserClaim: Bool = false
    @State private var result: AppState.FastRuntimePrototypeResult?
    @State private var releaseResult: AppState.FastRuntimePrototypeReleaseResult?
    @State private var previewCloseResult: AppState.FastRuntimePrototypeCloseResult?
    @State private var prototypeCameraRequest: FastRuntimeCameraPreviewRequest?

    private var availableProperties: [Property] {
        appState.properties
            .filter { $0.deletedAt == nil && !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Target") {
                    if availableProperties.isEmpty {
                        Text("No active properties loaded.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Property", selection: $selectedPropertyID) {
                            ForEach(availableProperties) { property in
                                Text(property.name)
                                    .tag(Optional(property.id))
                            }
                        }
                    }

                    Picker("Session Type", selection: $selectedSessionType) {
                        Text("Full").tag(SessionType.fullDocumentation)
                        Text("Punch").tag(SessionType.punchlistVisit)
                    }
                    .pickerStyle(.segmented)

                    Toggle("Create Temp Storage", isOn: $prepareTempStorage)
                    Toggle("Auto-release Claim", isOn: $releaseClaim)
                    Toggle("Allow Current-user Context", isOn: $allowCurrentUserOccupiedContext)
                }

                Section("Run") {
                    Button(isRunning ? "Running Prototype..." : "Run Fast Runtime Prototype") {
                        runPrototype()
                    }
                    .disabled(isRunning || isOpeningPrototypePreview || isReleasingCurrentUserClaim || selectedPropertyID == nil)

                    Button(isReleasingCurrentUserClaim ? "Releasing Claim..." : "Release My Current-user Claim") {
                        releaseCurrentUserClaim()
                    }
                    .disabled(isRunning || isOpeningPrototypePreview || isReleasingCurrentUserClaim || selectedPropertyID == nil)
                }

                if let releaseResult {
                    Section("Release Current-user Claim") {
                        diagnosticRow("Property", releaseResult.propertyName)
                        diagnosticRow("Probe Session", releaseResult.probeSessionID.uuidString)
                        diagnosticRow("Lock Session", releaseResult.lockSessionID?.uuidString ?? "none")
                        diagnosticRow("Entry State", releaseResult.entryState?.rawValue ?? "none")
                        diagnosticRow("Released", releaseResult.didRelease ? "true" : "false")
                        diagnosticBlock("Message", releaseResult.message)
                        if let reason = releaseResult.reason {
                            diagnosticBlock("Reason", reason)
                        }
                        diagnosticRow("RPC", millisecondsText(releaseResult.rpcMilliseconds))
                        diagnosticRow("Release", optionalMillisecondsText(releaseResult.releaseMilliseconds))
                        diagnosticRow("Total", millisecondsText(releaseResult.totalMilliseconds))
                    }
                }

                if let previewCloseResult {
                    Section("Prototype Preview Close") {
                        diagnosticRow("Property", previewCloseResult.propertyName)
                        diagnosticRow("Session", previewCloseResult.sessionID.uuidString)
                        diagnosticRow("Draft Persisted", previewCloseResult.draftPersisted ? "true" : "false")
                        diagnosticRow("Photo Count", "\(previewCloseResult.photoCount)")
                        diagnosticRow("Lock Action", previewCloseResult.lockAction)
                        diagnosticRow("Temp Discarded", previewCloseResult.tempDiscarded ? "true" : "false")
                        diagnosticRow("Draft Root", previewCloseResult.draftRootPath ?? "none")
                        diagnosticRow("Persist", optionalMillisecondsText(previewCloseResult.timings.persistMilliseconds))
                        diagnosticRow("Release", optionalMillisecondsText(previewCloseResult.timings.releaseMilliseconds))
                        diagnosticRow("Cleanup", optionalMillisecondsText(previewCloseResult.timings.cleanupMilliseconds))
                        diagnosticRow("Total", millisecondsText(previewCloseResult.timings.totalMilliseconds))
                        if let error = previewCloseResult.errorMessage {
                            diagnosticBlock("Error", error)
                        }
                    }
                }

                if let result {
                    if result.context != nil {
                        Section("Camera Preview") {
                            Button(isOpeningPrototypePreview ? "Opening Prototype Preview..." : "Open Prototype Camera Preview") {
                                openPrototypeCameraPreview()
                            }
                            .disabled(
                                isRunning ||
                                isOpeningPrototypePreview ||
                                selectedPropertyID == nil ||
                                result.contextSource != "unlocked_and_claimed"
                            )

                            if result.contextSource != "unlocked_and_claimed" {
                                diagnosticBlock(
                                    "Preview",
                                    "Prototype camera preview requires a clean unlocked_and_claimed context. Release your current-user claim or choose an idle property, then rerun."
                                )
                            }
                        }
                    }

                    Section("Result") {
                        diagnosticRow("Property", result.propertyName)
                        diagnosticRow("Property ID", result.propertyID.uuidString)
                        diagnosticRow("Target Session", result.timings.targetSessionID.uuidString)
                        diagnosticRow("Session Type", result.sessionType.rawValue)
                        diagnosticRow("Entry State", result.entryState?.rawValue ?? "none")
                        diagnosticRow("Requires Fallback", result.requiresFallback ? "true" : "false")
                        diagnosticRow("Context Created", result.context == nil ? "false" : "true")
                        diagnosticRow("Context Source", result.contextSource)
                        diagnosticRow("Temp Storage", result.tempStorageRoot?.path ?? "none")
                        diagnosticRow("Released Claim", result.didReleasePrototypeClaim ? "true" : "false")
                        if let releaseError = result.releaseErrorMessage {
                            diagnosticBlock("Release", releaseError)
                        }
                        if let reason = result.reason {
                            diagnosticBlock("Reason", reason)
                        }
                    }

                    Section("Timing") {
                        diagnosticRow("RPC", millisecondsText(result.timings.rpcMilliseconds))
                        diagnosticRow("Context", millisecondsText(result.timings.contextMilliseconds))
                        diagnosticRow("Temp Storage", optionalMillisecondsText(result.timings.tempStorageMilliseconds))
                        diagnosticRow("Release", optionalMillisecondsText(result.timings.releaseMilliseconds))
                        diagnosticRow("Total", millisecondsText(result.timings.totalMilliseconds))
                    }

                    if let context = result.context {
                        Section("ActiveCaptureContext") {
                            diagnosticRow("Session ID", context.sessionID.uuidString)
                            diagnosticRow("Property ID", context.propertyID.uuidString)
                            diagnosticRow("Org ID", context.orgID?.uuidString ?? "none")
                            diagnosticRow("Owner User", context.ownerUserID?.uuidString ?? "none")
                            diagnosticRow("Owner Email", context.ownerEmail ?? "none")
                            diagnosticRow("Owner Device", context.ownerDeviceID ?? "none")
                            diagnosticRow("Created", formattedDate(context.createdAt))
                            diagnosticRow("Status", context.status.rawValue)
                            diagnosticRow("Can Capture", context.canCapture ? "true" : "false")
                        }
                    }
                }
            }
            .navigationTitle("Fast Runtime Prototype")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                if selectedPropertyID == nil {
                    selectedPropertyID = availableProperties.first?.id
                }
            }
            .fullScreenCover(item: $prototypeCameraRequest) { request in
                DebugFastRuntimePrototypeCameraPreviewView(
                    context: request.context,
                    propertyName: request.propertyName,
                    prototypeResult: request.result,
                    buttonTappedAt: request.buttonTappedAt,
                    contextReadyAt: request.contextReadyAt,
                    previewRequestedAt: request.previewRequestedAt,
                    initialCapturedCount: request.initialCapturedCount,
                    storageRoot: request.storageRoot,
                    isDraftResume: request.isDraftResume,
                    initialLocationMode: request.initialLocationMode,
                    initialMetadataContext: request.initialMetadataContext,
                    isDebugMode: true,
                    onDismiss: { closeResult in
                        previewCloseResult = closeResult
                        prototypeCameraRequest = nil
                    }
                )
                .environmentObject(appState)
                .interactiveDismissDisabled(true)
            }
        }
    }

    private func runPrototype() {
        guard let selectedPropertyID, !isRunning else { return }
        isRunning = true
        result = nil
        releaseResult = nil
        previewCloseResult = nil
        Task {
            let prototypeResult = await appState.runFastRuntimePrototype(
                propertyID: selectedPropertyID,
                sessionType: selectedSessionType,
                prepareTempStorage: prepareTempStorage,
                releaseClaim: releaseClaim,
                allowCurrentUserOccupiedContext: allowCurrentUserOccupiedContext
            )
            await MainActor.run {
                result = prototypeResult
                isRunning = false
            }
        }
    }

    private func openPrototypeCameraPreview() {
        guard let selectedPropertyID, !isOpeningPrototypePreview else { return }
        isOpeningPrototypePreview = true
        result = nil
        releaseResult = nil
        previewCloseResult = nil
        let buttonTappedAt = Date()
        Task {
            let prototypeResult = await appState.runFastRuntimePrototype(
                propertyID: selectedPropertyID,
                sessionType: selectedSessionType,
                prepareTempStorage: prepareTempStorage,
                releaseClaim: false,
                allowCurrentUserOccupiedContext: false
            )
            let contextReadyAt = Date()
            await MainActor.run {
                result = prototypeResult
                guard let context = prototypeResult.context,
                      prototypeResult.contextSource == "unlocked_and_claimed" else {
                    isOpeningPrototypePreview = false
                    return
                }
                prototypeCameraRequest = FastRuntimeCameraPreviewRequest(
                    context: context,
                    propertyName: prototypeResult.propertyName,
                    result: prototypeResult,
                    buttonTappedAt: buttonTappedAt,
                    contextReadyAt: contextReadyAt,
                    previewRequestedAt: Date(),
                    initialCapturedCount: 0,
                    storageRoot: prototypeResult.tempStorageRoot,
                    isDraftResume: false,
                    initialLocationMode: .exterior,
                    initialMetadataContext: nil
                )
                isOpeningPrototypePreview = false
            }
        }
    }

    private func releaseCurrentUserClaim() {
        guard let selectedPropertyID, !isReleasingCurrentUserClaim else { return }
        isReleasingCurrentUserClaim = true
        result = nil
        releaseResult = nil
        previewCloseResult = nil
        Task {
            let release = await appState.releaseFastRuntimePrototypeCurrentUserClaim(
                propertyID: selectedPropertyID
            )
            await MainActor.run {
                releaseResult = release
                isReleasingCurrentUserClaim = false
            }
        }
    }

    private func millisecondsText(_ value: Double) -> String {
        String(format: "%.1f ms", value)
    }

    private func optionalMillisecondsText(_ value: Double?) -> String {
        guard let value else { return "not run" }
        return millisecondsText(value)
    }
}

private enum FastRuntimeProductionCompleteState: Equatable {
    case idle
    case validating
    case uploading
    case preparingReport
    case complete
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .validating, .uploading, .preparingReport:
            return true
        case .idle, .complete, .failed:
            return false
        }
    }

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

private struct DebugFastRuntimePrototypeCameraPreviewView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var camera = CameraManager.shared
    private let shutterHaptic = UIImpactFeedbackGenerator(style: .medium)

    let context: ActiveCaptureContext
    let propertyName: String
    let prototypeResult: AppState.FastRuntimePrototypeResult
    let buttonTappedAt: Date
    let contextReadyAt: Date
    let previewRequestedAt: Date
    let initialCapturedCount: Int
    let storageRoot: URL?
    let isDraftResume: Bool
    let initialLocationMode: CameraChromeLocationMode?
    let initialMetadataContext: AppState.FastRuntimeCaptureMetadataContext?
    let isDebugMode: Bool
    let onDismiss: (AppState.FastRuntimePrototypeCloseResult) -> Void

    @State private var previewRunningAt: Date?
    @State private var releaseStartedAt: Date?
    @State private var releaseFinishedAt: Date?
    @State private var isClosing: Bool = false
    @State private var isSavingFastCapture: Bool = false
    @State private var captureFlashVisible: Bool = false
    @State private var capturedCount: Int = 0
    @State private var captureErrorMessage: String?
    @State private var lastCapture: FastRuntimePreviewCaptureTiming?
    @State private var fastStorageRoot: URL?
    @State private var isTimingExpanded: Bool = false
    @State private var isRunningCompleteDryRun: Bool = false
    @State private var isRunningCompleteUpload: Bool = false
    @State private var isRunningReportPackageDryRun: Bool = false
    @State private var isRunningReportHandoff: Bool = false
    @State private var didCompleteUpload: Bool = false
    @State private var productionCompleteState: FastRuntimeProductionCompleteState = .idle
    @State private var completeDryRunResult: AppState.FastRuntimeCompleteDryRunResult?
    @State private var completeUploadResult: AppState.FastRuntimeCompleteUploadResult?
    @State private var reportPackageDryRunResult: AppState.FastRuntimeReportPackageDryRunResult?
    @State private var reportHandoffResult: AppState.FastRuntimeReportHandoffResult?
    @State private var chromeLocationMode: CameraChromeLocationMode = .exterior
    @StateObject private var fastDetailTypesModel = FastLaneDetailTypesModel()
    @StateObject private var locationManager = LocationManager()
    @State private var fastMetadataContext: AppState.FastRuntimeCaptureMetadataContext = AppState.FastRuntimeCaptureMetadataContext(
        locationMode: "Exterior",
        building: "B1",
        elevation: "North",
        detailType: "Overview",
        angleIndex: 4
    )
    @State private var isShowingFastMetadataPicker: Bool = false
    @State private var didApplyInitialLocationMode: Bool = false
    @State private var didLoadFastMetadataOptions: Bool = false
    @State private var fastBuildingOptions: [String] = FastLaneMetadataOptions.defaultBuildingOptions
    @State private var fastTradeOptions: [String] = FastLaneMetadataOptions.defaultTradeOptions
    @State private var lastValidDeviceOrientation: UIDeviceOrientation = .portrait
    @State private var glyphAngleDegrees: Double = 0
    @State private var didWarmFastMetadataLists: Bool = false
    private let glyphRotationAnimation = Animation.interactiveSpring(
        response: 0.48,
        dampingFraction: 0.90,
        blendDuration: 0.18
    )

    var body: some View {
        CameraChromeView(
            display: cameraChromeDisplay,
            zoomSteps: camera.zoomSteps,
            selectedZoomID: camera.selectedZoomId,
            actions: cameraChromeActions,
            previewContent: {
                CameraPreviewView(session: camera.session)
            },
            overlayContent: {
                fastLanePreviewOverlays
            }
        )
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            refreshCameraChromeGlyphRotation()
            loadFastLaneMetadataOptionsIfNeeded()
            warmFastLaneMetadataListsIfNeeded()
            if !didApplyInitialLocationMode {
                let initialContext = AppState.normalizedFastRuntimeMetadataContext(
                    initialMetadataContext,
                    fallbackLocationMode: initialLocationMode?.rawValue,
                    fallbackPosition: 4
                )
                applyFastLaneMetadataContext(initialContext)
                didApplyInitialLocationMode = true
            }
            fastStorageRoot = storageRoot ?? prototypeResult.tempStorageRoot
            if capturedCount < initialCapturedCount {
                capturedCount = initialCapturedCount
            }
            shutterHaptic.prepare()
            locationManager.start()
            camera.prepareForPreviewAsync()
            camera.ensurePreviewRunningAsync()
            if camera.isPreviewRunning, previewRunningAt == nil {
                previewRunningAt = Date()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            refreshCameraChromeGlyphRotation()
        }
        .onReceive(camera.$isPreviewRunning.removeDuplicates()) { isRunning in
            guard isRunning, previewRunningAt == nil else { return }
            previewRunningAt = Date()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            locationManager.stop()
        }
        .sheet(item: $completeDryRunResult) { result in
            FastRuntimeCompleteDryRunResultView(result: result)
        }
        .sheet(item: $completeUploadResult) { result in
            FastRuntimeCompleteUploadResultView(result: result)
        }
        .sheet(item: $reportPackageDryRunResult) { result in
            FastRuntimeReportPackageDryRunResultView(result: result)
        }
        .sheet(item: $reportHandoffResult) { result in
            FastRuntimeReportHandoffResultView(result: result)
        }
        .sheet(isPresented: $isShowingFastMetadataPicker) {
            FastLaneMetadataFilterSheet(
                profile: fastLaneCaptureProfile,
                context: fastMetadataContext,
                buildingOptions: $fastBuildingOptions,
                tradeOptions: $fastTradeOptions,
                detailTypesModel: fastDetailTypesModel,
                onCancel: {
                    isShowingFastMetadataPicker = false
                },
                onConfirm: { updatedContext in
                    applyFastLaneMetadataContext(updatedContext)
                    isShowingFastMetadataPicker = false
                }
            )
        }
    }

    private var cameraChromeDisplay: CameraChromeDisplayModel {
        let profile = fastLaneCaptureProfile
        let accent = fastLaneCaptureProfileAccentColor
        return CameraChromeDisplayModel(
            profileTitle: profile.title,
            profileSystemImage: profile == .residential ? "house.fill" : "building.2.fill",
            profileAccentColor: accent,
            isProfileLocked: true,
            propertyName: propertyName,
            cloudStatus: fastLaneChromeCloudStatus,
            showsPunchlistBadge: context.sessionType == .punchlistVisit,
            metadata: CameraChromeMetadataModel(
                building: fastMetadataContext.building,
                orientation: fastMetadataOrientationLabel(for: fastMetadataContext.elevation),
                showsOrientationDot: chromeLocationMode == .exterior,
                orientationDotColor: isFastLaneElevationHeadingAligned ? .green : .white,
                detailType: fastLaneShortShotTypeLabel(fastMetadataContext.detailType),
                angle: "A\(max(1, fastMetadataContext.angleIndex))",
                trade: fastMetadataContext.trade,
                isFilterAvailable: true
            ),
            previewStatusTitle: previewStatusTitle,
            previewStatusColor: previewStatusColor,
            isPreviewRunning: camera.isPreviewRunning,
            isShutterEnabled: canUseFastShutter,
            isHDVisible: camera.hdSupported,
            isHDEnabled: camera.effectiveHDEnabled,
            locationMode: chromeLocationMode,
            sideControls: fastLaneChromeSideControls,
            savedCount: capturedCount,
            thumbnail: nil,
            ellipsisEnabled: isDebugMode,
            deviceOrientation: lastValidDeviceOrientation,
            glyphRotationAngle: .degrees(glyphAngleDegrees)
        )
    }

    private func refreshCameraChromeGlyphRotation() {
        let orientation = UIDevice.current.orientation
        let newValue: UIDeviceOrientation? = {
            switch orientation {
            case .portrait, .portraitUpsideDown:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return orientation
            default:
                return nil
            }
        }()

        guard let newValue else { return }
        let target: Double
        switch newValue {
        case .landscapeLeft:
            target = 90
        case .landscapeRight:
            target = -90
        default:
            target = 0
        }
        guard newValue != lastValidDeviceOrientation || abs(glyphAngleDegrees - target) > 0.5 else {
            return
        }

        lastValidDeviceOrientation = newValue

        withAnimation(glyphRotationAnimation) {
            glyphAngleDegrees = target
        }
    }

    private var cameraChromeActions: CameraChromeActions {
        CameraChromeActions(
            onProfileTapped: {},
            onEndTapped: {
                closePreview()
            },
            onMetadataTapped: {
                isShowingFastMetadataPicker = true
            },
            onSideControlTapped: { _ in },
            onZoomTapped: { step in
                camera.setZoomStep(step)
            },
            onHDTapped: {
                guard camera.hdSupported, !camera.isCapturing, !isSavingFastCapture else { return }
                shutterHaptic.impactOccurred(intensity: 0.55)
                shutterHaptic.prepare()
                camera.manualHDEnabled.toggle()
            },
            onShutterTapped: {
                shutterHaptic.impactOccurred()
                shutterHaptic.prepare()
                beginFastLaneShutter()
            },
            onThumbnailTapped: {},
            onLocationModeChanged: { mode in
                applyFastLaneLocationMode(mode)
            },
            onEllipsisTapped: {
                guard isDebugMode else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    isTimingExpanded.toggle()
                }
            }
        )
    }

    private var fastLaneChromeCloudStatus: CameraChromeStatusModel? {
        if let freshness = appState.propertyOpenFreshness(for: context.propertyID) {
            return CameraChromeStatusModel(
                title: AppState.propertyOpenFreshnessDisplayLabel(for: freshness.status),
                systemImage: AppState.propertyOpenFreshnessSymbolName(for: freshness.status),
                color: fastLaneCloudStatusColor(for: freshness.status)
            )
        }
        return CameraChromeStatusModel(
            title: previewStatusTitle,
            systemImage: camera.isPreviewRunning ? "checkmark.circle.fill" : "camera.fill",
            color: previewStatusColor
        )
    }

    private func fastLaneCloudStatusColor(for status: AppState.PropertyOpenFreshnessStatus) -> Color {
        switch status {
        case .checkingCloudStatus, .usingLocalCache, .offline, .unknown:
            return .white.opacity(0.72)
        case .current:
            return .green.opacity(0.9)
        case .remoteUpdatesAvailable:
            return .blue.opacity(0.95)
        case .needsReview:
            return .orange.opacity(0.95)
        }
    }

    private var fastLaneCaptureProfile: CaptureProfile {
        appState.properties.first(where: { $0.id == context.propertyID })?.captureProfile ??
            appState.selectedProperty?.captureProfile ??
            .residential
    }

    private var fastLaneCaptureProfileAccentColor: Color {
        switch fastLaneCaptureProfile {
        case .residential:
            return Color(red: 0.95, green: 0.56, blue: 0.15)
        case .commercial:
            return Color(red: 0.12, green: 0.66, blue: 1.0)
        }
    }

    private var fastLaneChromeSideControls: [CameraChromeSideControl] {
        [
            CameraChromeSideControl(
                id: "resolution_required",
                systemImage: "flag.checkered",
                accessibilityLabel: "Resolution required"
            ),
            CameraChromeSideControl(
                id: "active_issues",
                systemImage: "flag.fill",
                accessibilityLabel: "Active issues"
            ),
            CameraChromeSideControl(
                id: "guided",
                systemImage: "safari",
                accessibilityLabel: "Guided",
                isVisible: context.sessionType != .punchlistVisit
            ),
            CameraChromeSideControl(
                id: "checklist",
                systemImage: "checkmark",
                accessibilityLabel: "Checklist",
                isVisible: context.sessionType != .punchlistVisit
            )
        ]
    }

    @ViewBuilder
    private var fastLanePreviewOverlays: some View {
        if captureFlashVisible {
            Color.white
                .opacity(0.32)
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(24)
        }

        if let captureErrorMessage {
            Text(captureErrorMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 18)
                .allowsHitTesting(false)
                .zIndex(25)
        }

        if isDebugMode && isTimingExpanded {
            timingPanel
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(18)
        }
    }

    private var headerPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(isClosing ? "Closing..." : "Close") {
                    closePreview()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Color.black.opacity(0.58))
                .clipShape(Capsule())
                .disabled(isClosing || isSavingFastCapture || camera.isCapturing)

                VStack(alignment: .leading, spacing: 2) {
                    Text(propertyName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(isDraftResume ? "\(sessionTypeLabel) Draft" : sessionTypeLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isDebugMode {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isTimingExpanded.toggle()
                        }
                    } label: {
                        Text(isTimingExpanded ? "Hide" : "Timing")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Color.black.opacity(0.58))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                statusBadge(previewStatusTitle, color: previewStatusColor)
                statusBadge("Saved \(capturedCount)", color: .white.opacity(0.82))
                if didCompleteUpload {
                    statusBadge("Uploaded", color: .green)
                }
                if isDebugMode, let total = lastCapture?.totalMilliseconds {
                    statusBadge("Last \(String(format: "%.0f", total)) ms", color: .white.opacity(0.82))
                }
                Spacer(minLength: 0)
            }

            if isDebugMode && isTimingExpanded {
                timingPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var previewStatusTitle: String {
        if isClosing { return "Closing" }
        return camera.isPreviewRunning ? "Ready" : "Starting"
    }

    private var previewStatusColor: Color {
        if isClosing { return .white.opacity(0.82) }
        return camera.isPreviewRunning ? .green : .yellow
    }

    private var shutterPanel: some View {
        VStack(spacing: 10) {
            if let captureErrorMessage {
                Text(captureErrorMessage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 18)
            }

            if capturedCount > 0 {
                if isDebugMode {
                    HStack(spacing: 10) {
                        Button(isRunningCompleteDryRun ? "Checking..." : "Complete Dry Run") {
                            runCompleteDryRun()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.94))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Color.black.opacity(0.58))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.20), lineWidth: 1)
                        )
                        .disabled(isRunningCompleteDryRun || isRunningCompleteUpload || isClosing || isSavingFastCapture || camera.isCapturing)

                        Button(didCompleteUpload ? "Uploaded" : (isRunningCompleteUpload ? "Uploading..." : "Fast Complete Upload (Experimental)")) {
                            runCompleteUpload()
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.96))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(Color.orange.opacity(0.72))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                        .disabled(didCompleteUpload || isRunningCompleteDryRun || isRunningCompleteUpload || isClosing || isSavingFastCapture || camera.isCapturing)
                    }
                } else {
                    productionCompletePanel
                }
            }

            if isDebugMode && didCompleteUpload {
                HStack(spacing: 10) {
                    Button(isRunningReportPackageDryRun ? "Checking Report..." : "Fast Report Package Dry Run") {
                        runReportPackageDryRun()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.96))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Color.green.opacity(0.68))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    )
                    .disabled(isRunningReportPackageDryRun || isRunningReportHandoff || isRunningCompleteDryRun || isRunningCompleteUpload || isClosing || isSavingFastCapture || camera.isCapturing)

                    Button(isRunningReportHandoff ? "Handing Off..." : "Fast Report Handoff (Experimental)") {
                        runReportHandoff()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.96))
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(Color.teal.opacity(0.72))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.24), lineWidth: 1)
                    )
                    .disabled(isRunningReportHandoff || isRunningReportPackageDryRun || isRunningCompleteDryRun || isRunningCompleteUpload || isClosing || isSavingFastCapture || camera.isCapturing)
                }
            }

            HStack(spacing: 18) {
                Text("Saved \(capturedCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .frame(width: 92, alignment: .leading)

                Button {
                    beginFastLaneShutter()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(isSavingFastCapture || camera.isCapturing ? 0.62 : 0.96))
                            .frame(width: 72, height: 72)
                        Circle()
                            .stroke(Color.black.opacity(0.78), lineWidth: 3)
                            .frame(width: 58, height: 58)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canUseFastShutter)
                .accessibilityLabel("Capture photo")

                Text(didCompleteUpload ? "Uploaded" : (isSavingFastCapture || camera.isCapturing ? "Saving" : (isDraftResume ? "Draft" : "Ready")))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(canUseFastShutter ? 0.88 : 0.55))
                    .frame(width: 92, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 28)
    }

    private var sessionTypeLabel: String {
        switch context.sessionType {
        case .fullDocumentation:
            return "Full Documentation"
        case .punchlistVisit:
            return "Punchlist"
        }
    }

    private func statusBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.black.opacity(0.52))
            .clipShape(Capsule())
    }

    private var timingPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            timingText("Tap -> RPC/context", contextReadyAt.timeIntervalSince(buttonTappedAt) * 1_000)
            timingText("Context -> preview request", previewRequestedAt.timeIntervalSince(contextReadyAt) * 1_000)
            timingText("Request -> preview running", previewRunningAt.map { $0.timeIntervalSince(previewRequestedAt) * 1_000 })
            timingText("Total tap -> preview running", previewRunningAt.map { $0.timeIntervalSince(buttonTappedAt) * 1_000 })
            Divider()
                .overlay(Color.white.opacity(0.22))
            timingText("Shutter -> haptic/visual", lastCapture?.hapticMilliseconds)
            timingText("Shutter -> image captured", lastCapture?.imageCapturedMilliseconds)
            timingText("Capture -> temp file", lastCapture?.fileWriteMilliseconds)
            timingText("Temp file -> metadata", lastCapture?.metadataMilliseconds)
            timingText("Total shutter -> saved", lastCapture?.totalMilliseconds)
            timingText("Close handling", releaseFinishedAt.flatMap { finished in
                releaseStartedAt.map { finished.timeIntervalSince($0) * 1_000 }
            })
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(.white.opacity(0.86))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func timingText(_ label: String, _ milliseconds: Double?) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Text(milliseconds.map { String(format: "%.1f ms", $0) } ?? "pending")
        }
    }

    private var canUseFastShutter: Bool {
        context.canCapture &&
            camera.isPreviewRunning &&
            !camera.isCapturing &&
            !isSavingFastCapture &&
            !isClosing &&
            !didCompleteUpload &&
            !productionCompleteState.isRunning
    }

    private var productionCompletePanel: some View {
        VStack(spacing: 8) {
            if case let .failed(message) = productionCompleteState {
                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            HStack(spacing: 10) {
                Button(productionCompleteButtonTitle) {
                    runProductionComplete()
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .frame(height: 42)
                .background(productionCompleteState.isComplete ? Color.green.opacity(0.74) : Color.blue.opacity(0.84))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.26), lineWidth: 1)
                )
                .disabled(!canRunProductionComplete)

                if productionCompleteState.isRunning {
                    ProgressView()
                        .tint(.white)
                }
            }

            if let status = productionCompleteStatusText {
                Text(status)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.82))
            }
        }
    }

    private var productionCompleteButtonTitle: String {
        switch productionCompleteState {
        case .idle, .failed:
            return "Complete"
        case .validating:
            return "Checking..."
        case .uploading:
            return "Uploading..."
        case .preparingReport:
            return "Preparing Report..."
        case .complete:
            return "Complete"
        }
    }

    private var productionCompleteStatusText: String? {
        switch productionCompleteState {
        case .idle:
            return nil
        case .validating:
            return "Checking saved photos"
        case .uploading:
            return "Uploading"
        case .preparingReport:
            return "Preparing report"
        case .complete:
            return "Complete"
        case .failed:
            return "Failed. Your draft is still saved."
        }
    }

    private var canRunProductionComplete: Bool {
        capturedCount > 0 &&
            !productionCompleteState.isRunning &&
            !productionCompleteState.isComplete &&
            !isClosing &&
            !isSavingFastCapture &&
            !camera.isCapturing
    }

    private func captureFastLanePhoto() {
        guard canUseFastShutter else { return }
        let shutterTappedAt = Date()
        captureErrorMessage = nil
        isSavingFastCapture = true
        captureFlashVisible = true
        shutterHaptic.impactOccurred()
        shutterHaptic.prepare()
        let hapticAt = Date()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            captureFlashVisible = false
        }

        DispatchQueue.main.async {
            camera.capturePhoto { data in
                let imageCapturedAt = Date()
                guard let data else {
                    DispatchQueue.main.async {
                        lastCapture = FastRuntimePreviewCaptureTiming(
                            shutterTappedAt: shutterTappedAt,
                            hapticAt: hapticAt,
                            imageCapturedAt: imageCapturedAt,
                            savedAt: nil,
                            saveResult: nil
                        )
                        captureErrorMessage = "Capture failed: no image data."
                        isSavingFastCapture = false
                    }
                    return
                }

                Task {
                    let saveResult = await appState.saveFastRuntimePrototypeCapture(
                        data: data,
                        context: context,
                        capturedAt: imageCapturedAt,
                        storageRootOverride: fastStorageRoot,
                        metadataContext: fastMetadataContext
                    )
                    await MainActor.run {
                        lastCapture = FastRuntimePreviewCaptureTiming(
                            shutterTappedAt: shutterTappedAt,
                            hapticAt: hapticAt,
                            imageCapturedAt: imageCapturedAt,
                            savedAt: Date(),
                            saveResult: saveResult
                        )
                        if saveResult.success {
                            capturedCount += 1
                            fastStorageRoot = saveResult.storageRoot ?? fastStorageRoot
                            if let savedContext = saveResult.shot?.metadataContext {
                                fastMetadataContext = savedContext.withAngleIndex(savedContext.angleIndex + 1)
                                chromeLocationMode = CameraChromeLocationMode(fastRuntimeRawValue: savedContext.locationMode)
                            }
                            captureErrorMessage = nil
                        } else {
                            captureErrorMessage = saveResult.errorMessage ?? "Capture save failed."
                        }
                        isSavingFastCapture = false
                    }
                }
            }
        }
    }

    private func beginFastLaneShutter() {
        captureFastLanePhoto()
    }

    private func runCompleteDryRun() {
        guard capturedCount > 0, !isRunningCompleteDryRun else { return }
        isRunningCompleteDryRun = true
        Task {
            let result = await appState.runFastRuntimeCompleteDryRun(
                context: context,
                storageRoot: fastStorageRoot ?? prototypeResult.tempStorageRoot,
                capturedPhotoCount: capturedCount
            )
            await MainActor.run {
                completeDryRunResult = result
                isRunningCompleteDryRun = false
            }
        }
    }

    private func runCompleteUpload() {
        guard capturedCount > 0, !isRunningCompleteUpload else { return }
        isRunningCompleteUpload = true
        Task {
            let result = await appState.runFastRuntimeCompleteUpload(
                context: context,
                storageRoot: fastStorageRoot ?? prototypeResult.tempStorageRoot,
                capturedPhotoCount: capturedCount
            )
            await MainActor.run {
                completeUploadResult = result
                if result.success {
                    didCompleteUpload = true
                }
                isRunningCompleteUpload = false
            }
        }
    }

    private func runReportPackageDryRun() {
        guard didCompleteUpload, !isRunningReportPackageDryRun else { return }
        isRunningReportPackageDryRun = true
        Task {
            let result = await appState.runFastRuntimeReportPackageDryRun(context: context)
            await MainActor.run {
                reportPackageDryRunResult = result
                isRunningReportPackageDryRun = false
            }
        }
    }

    private func runReportHandoff() {
        guard didCompleteUpload, !isRunningReportHandoff else { return }
        isRunningReportHandoff = true
        Task {
            let result = await appState.runFastRuntimeReportHandoff(
                propertyID: context.propertyID,
                sessionType: context.sessionType
            )
            await MainActor.run {
                reportHandoffResult = result
                isRunningReportHandoff = false
            }
        }
    }

    private func runProductionComplete() {
        guard canRunProductionComplete else { return }
        productionCompleteState = .validating
        captureErrorMessage = nil
        Task {
            let dryRun = await appState.runFastRuntimeCompleteDryRun(
                context: context,
                storageRoot: fastStorageRoot ?? prototypeResult.tempStorageRoot,
                capturedPhotoCount: capturedCount
            )
            guard dryRun.isValid else {
                let message = dryRun.missingFields.first.map { "Missing \($0)." } ??
                    dryRun.corruptMetadataMessage ??
                    dryRun.warnings.first ??
                    "Could not validate saved photos."
                await MainActor.run {
                    productionCompleteState = .failed(message)
                }
                return
            }

            await MainActor.run {
                productionCompleteState = .uploading
                appState.markFastRuntimeCompletionUploading(context: context)
                finishProductionComplete()
            }

            let upload = await appState.runFastRuntimeCompleteUpload(
                context: context,
                storageRoot: fastStorageRoot ?? prototypeResult.tempStorageRoot,
                capturedPhotoCount: capturedCount
            )
            guard upload.success else {
                await MainActor.run {
                    appState.markFastRuntimeCompletionFailed(
                        context: context,
                        message: upload.errorMessage ?? "Upload failed. Please try again."
                    )
                    if !isClosing {
                        productionCompleteState = .failed(upload.errorMessage ?? "Upload failed. Please try again.")
                    }
                }
                return
            }

            await MainActor.run {
                didCompleteUpload = true
                if !isClosing {
                    productionCompleteState = .preparingReport
                }
            }

            let handoff = await appState.runFastRuntimeReportHandoff(
                propertyID: context.propertyID,
                sessionType: context.sessionType
            )
            guard handoff.success else {
                await MainActor.run {
                    appState.markFastRuntimeCompletionFailed(
                        context: context,
                        message: handoff.errorMessage ?? "Report handoff failed. Please try again."
                    )
                    if !isClosing {
                        productionCompleteState = .failed(handoff.errorMessage ?? "Report handoff failed. Please try again.")
                    }
                }
                return
            }

            let didReleaseAfterHandoff = await appState.markFastRuntimeCompletionHandoffAccepted(
                context: context,
                snapshotID: handoff.snapshotID,
                snapshotPath: handoff.snapshotPath
            )
            await MainActor.run {
                guard didReleaseAfterHandoff else {
                    let message = "Report handoff was accepted, but the property did not release. Please retry from the saved draft."
                    appState.markFastRuntimeCompletionFailed(
                        context: context,
                        message: message
                    )
                    if !isClosing {
                        productionCompleteState = .failed(message)
                    }
                    return
                }
                if !isClosing {
                    productionCompleteState = .complete
                    finishProductionComplete()
                }
            }
        }
    }

    private func finishProductionComplete() {
        guard !isClosing else { return }
        isClosing = true
        releaseStartedAt = Date()
        camera.stopPreviewAsync()
        releaseFinishedAt = Date()
        onDismiss(AppState.FastRuntimePrototypeCloseResult(
            propertyID: context.propertyID,
            propertyName: propertyName,
            sessionID: context.sessionID,
            draftPersisted: false,
            photoCount: capturedCount,
            lockAction: "completed_upload_report_handoff",
            tempDiscarded: false,
            draftRootPath: fastStorageRoot?.path,
            errorMessage: nil,
            timings: AppState.FastRuntimePrototypeCloseTimings(
                persistMilliseconds: nil,
                releaseMilliseconds: nil,
                cleanupMilliseconds: nil,
                totalMilliseconds: releaseStartedAt.map { Date().timeIntervalSince($0) * 1_000 } ?? 0
            )
        ))
    }

    private func applyFastLaneLocationMode(_ mode: CameraChromeLocationMode) {
        let current = fastMetadataContext
        let nextElevation: String
        switch mode {
        case .interior:
            nextElevation = "Interior"
        case .exterior:
            nextElevation = Self.exteriorElevationOptions.contains(current.elevation) ? current.elevation : "North"
        }
        let details = fastDetailTypesModel.names(for: mode, profile: fastLaneCaptureProfile)
        let nextDetail = details.contains(current.detailType) ? current.detailType : (details.first ?? "Overview")
        applyFastLaneMetadataContext(AppState.FastRuntimeCaptureMetadataContext(
            locationMode: mode.rawValue,
            building: current.building,
            elevation: nextElevation,
            detailType: nextDetail,
            trade: current.trade,
            angleIndex: current.angleIndex
        ))
    }

    private func applyFastLaneMetadataContext(_ context: AppState.FastRuntimeCaptureMetadataContext) {
        let normalized = AppState.normalizedFastRuntimeMetadataContext(context, fallbackPosition: 4)
        let mode = CameraChromeLocationMode(fastRuntimeRawValue: normalized.locationMode)
        let elevation = mode == .interior
            ? "Interior"
            : (Self.exteriorElevationOptions.contains(normalized.elevation) ? normalized.elevation : "North")
        let details = fastDetailTypesModel.names(for: mode, profile: fastLaneCaptureProfile)
        let detail = details.contains(normalized.detailType) ? normalized.detailType : (details.first ?? "Overview")
        fastMetadataContext = AppState.FastRuntimeCaptureMetadataContext(
            locationMode: mode.rawValue,
            building: normalizedFastLaneBuilding(normalized.building),
            elevation: elevation,
            detailType: detail,
            trade: FastLaneMetadataOptions.canonicalTradeLabel(normalized.trade, preferredOptions: fastTradeOptions),
            angleIndex: normalized.angleIndex
        )
        chromeLocationMode = mode
    }

    private func fastMetadataOrientationLabel(for elevation: String) -> String {
        switch elevation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "interior":
            return "Interior"
        case "south":
            return "S"
        case "east":
            return "E"
        case "west":
            return "W"
        default:
            return "N"
        }
    }

    private var isFastLaneElevationHeadingAligned: Bool {
        guard chromeLocationMode == .exterior else { return false }
        guard let rawHeading = locationManager.headingDegrees else { return false }
        let currentHeading = normalizedFastLaneHeadingForAlignment(rawHeading)
        guard let ideal = idealFastLaneFacingHeading(for: CanonicalElevation.normalize(fastMetadataContext.elevation) ?? fastMetadataContext.elevation) else {
            return false
        }
        return angularFastLaneDifferenceDegrees(currentHeading, ideal) <= 45
    }

    private func normalizedFastLaneHeadingForAlignment(_ heading: Double) -> Double {
        let adjusted: Double
        switch lastValidDeviceOrientation {
        case .landscapeLeft:
            adjusted = heading + 90
        case .landscapeRight:
            adjusted = heading - 90
        case .portraitUpsideDown:
            adjusted = heading + 180
        default:
            adjusted = heading
        }
        let wrapped = adjusted.truncatingRemainder(dividingBy: 360)
        return wrapped >= 0 ? wrapped : wrapped + 360
    }

    private func idealFastLaneFacingHeading(for normalizedElevation: String) -> Double? {
        switch normalizedElevation {
        case "North":
            return 180
        case "South":
            return 0
        case "East":
            return 270
        case "West":
            return 90
        default:
            return nil
        }
    }

    private func angularFastLaneDifferenceDegrees(_ lhs: Double, _ rhs: Double) -> Double {
        let a = lhs.truncatingRemainder(dividingBy: 360)
        let b = rhs.truncatingRemainder(dividingBy: 360)
        let diff = abs(a - b)
        return min(diff, 360 - diff)
    }

    private func fastLaneShortShotTypeLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("General Elevation") == .orderedSame {
            return "General"
        }
        return trimmed.isEmpty ? "Shot" : trimmed
    }

    private func normalizedFastLaneBuilding(_ value: String) -> String {
        let code = FastLaneMetadataOptions.buildingCode(from: value)
        if fastBuildingOptions.contains(where: { FastLaneMetadataOptions.buildingCode(from: $0) == code }) {
            return code
        }
        return fastBuildingOptions.first.map(FastLaneMetadataOptions.buildingCode(from:)) ?? "B1"
    }

    private func loadFastLaneMetadataOptionsIfNeeded() {
        guard !didLoadFastMetadataOptions else { return }
        didLoadFastMetadataOptions = true
        fastBuildingOptions = FastLaneMetadataOptions.loadBuildingOptions()
        fastTradeOptions = FastLaneMetadataOptions.loadTradeOptions(selectedTrade: fastMetadataContext.trade)
    }

    private func warmFastLaneMetadataListsIfNeeded() {
        guard !didWarmFastMetadataLists else { return }
        didWarmFastMetadataLists = true
        _ = fastDetailTypesModel.names(for: .interior, profile: fastLaneCaptureProfile)
        _ = fastDetailTypesModel.names(for: .exterior, profile: fastLaneCaptureProfile)
        _ = FastLaneMetadataOptions.canonicalTradeOptions(fastTradeOptions, selectedTrade: fastMetadataContext.trade)
        _ = fastBuildingOptions.map(FastLaneMetadataOptions.buildingDisplayName(for:))
    }

    private static let exteriorElevationOptions = ["North", "South", "East", "West"]

    private func closePreview() {
        guard !isClosing else { return }
        isClosing = true
        releaseStartedAt = Date()
        camera.stopPreviewAsync()
        if didCompleteUpload {
            releaseFinishedAt = Date()
            onDismiss(AppState.FastRuntimePrototypeCloseResult(
                propertyID: context.propertyID,
                propertyName: propertyName,
                sessionID: context.sessionID,
                draftPersisted: false,
                photoCount: capturedCount,
                lockAction: "completed_upload",
                tempDiscarded: false,
                draftRootPath: fastStorageRoot?.path,
                errorMessage: nil,
                timings: AppState.FastRuntimePrototypeCloseTimings(
                    persistMilliseconds: nil,
                    releaseMilliseconds: nil,
                    cleanupMilliseconds: nil,
                    totalMilliseconds: releaseStartedAt.map { Date().timeIntervalSince($0) * 1_000 } ?? 0
                )
            ))
            return
        }
        Task {
            let closeResult = await appState.closeFastRuntimePrototypePreview(
                context: context,
                tempStorageRoot: fastStorageRoot ?? prototypeResult.tempStorageRoot,
                capturedPhotoCount: capturedCount,
                lastMetadataContext: fastMetadataContext
            )
            await MainActor.run {
                releaseFinishedAt = Date()
                onDismiss(closeResult)
            }
        }
    }
}

private enum FastLaneMetadataOptions {
    nonisolated static let buildingOptionsDefaultsKey = "scout.capture.building.options.v1"
    nonisolated static let tradeOptionsDefaultsKey = "scout.capture.trade.options.v1"
    nonisolated static let defaultBuildingOptions = ["B1", "B2", "B3", "B4", "B5", "Add"]
    nonisolated static let defaultTradeOptions = [
        "Masonry", "Roofing", "Siding", "Windows", "Doors", "Stucco", "Foundation",
        "Framing", "Electrical", "Plumbing", "HVAC", "Landscaping", "Interior Finish"
    ]

    nonisolated static func buildingCode(from option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let rawCode: String
        if let dashRange = trimmed.range(of: "-") {
            rawCode = String(trimmed[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            rawCode = trimmed
        }
        if rawCode.compare("add", options: .caseInsensitive) == .orderedSame {
            return "Add"
        }
        return rawCode.uppercased()
    }

    nonisolated static func buildingDisplayName(for option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" - ") { return trimmed }
        let code = buildingCode(from: trimmed)
        if code == "Add" { return "Add - Additional" }
        if code.hasPrefix("B") {
            let suffix = code.dropFirst()
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                return "\(code) - Building \(suffix)"
            }
        }
        return code
    }

    static func loadBuildingOptions() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: buildingOptionsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return defaultBuildingOptions
        }
        let cleaned = decoded.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? defaultBuildingOptions : cleaned
    }

    static func persistBuildingOptions(_ options: [String], selectedBuilding: inout String) {
        let cleaned = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let final = cleaned.isEmpty ? defaultBuildingOptions : cleaned
        let selectedCode = buildingCode(from: selectedBuilding)
        selectedBuilding = final.contains(where: { buildingCode(from: $0) == selectedCode })
            ? selectedCode
            : buildingCode(from: final[0])
        if let data = try? JSONEncoder().encode(final) {
            UserDefaults.standard.set(data, forKey: buildingOptionsDefaultsKey)
        }
    }

    nonisolated static func tradeKey(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    nonisolated static func canonicalTradeLabel(_ value: String?, preferredOptions: [String] = []) -> String {
        let trimmed = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let key = tradeKey(trimmed)
        guard !key.isEmpty else { return "" }
        if let builtIn = defaultTradeOptions.first(where: { tradeKey($0) == key }) { return builtIn }
        if let preferred = preferredOptions.first(where: { tradeKey($0) == key }) {
            return preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    nonisolated static func canonicalTradeOptions(_ values: [String], selectedTrade: String? = nil) -> [String] {
        var output: [String] = []
        var seen: Set<String> = []
        func append(_ raw: String?) {
            let canonical = canonicalTradeLabel(raw, preferredOptions: output)
            let key = tradeKey(canonical)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            output.append(canonical)
        }
        values.forEach { append($0) }
        append(selectedTrade)
        return output
    }

    static func loadTradeOptions(selectedTrade: String?) -> [String] {
        guard let data = UserDefaults.standard.data(forKey: tradeOptionsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return canonicalTradeOptions(defaultTradeOptions, selectedTrade: selectedTrade)
        }
        let cleaned = canonicalTradeOptions(decoded, selectedTrade: selectedTrade)
        return cleaned.isEmpty ? defaultTradeOptions : cleaned
    }

    static func persistTradeOptions(_ options: inout [String], selectedTrade: inout String) {
        let cleaned = canonicalTradeOptions(options, selectedTrade: selectedTrade)
        options = cleaned.isEmpty ? defaultTradeOptions : cleaned
        selectedTrade = canonicalTradeLabel(selectedTrade, preferredOptions: options)
        if !selectedTrade.isEmpty,
           options.contains(where: { tradeKey($0) == tradeKey(selectedTrade) }) == false {
            selectedTrade = ""
        }
        if let data = try? JSONEncoder().encode(options) {
            UserDefaults.standard.set(data, forKey: tradeOptionsDefaultsKey)
        }
    }
}

private final class FastLaneDetailTypesModel: ObservableObject {
    struct DetailTypeItem: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var name: String
    }

    @Published var residentialInteriorTypes: [DetailTypeItem] = []
    @Published var residentialExteriorTypes: [DetailTypeItem] = []
    @Published var commercialInteriorTypes: [DetailTypeItem] = []
    @Published var commercialExteriorTypes: [DetailTypeItem] = []
    @Published var selectedResidentialInterior: String = ""
    @Published var selectedResidentialExterior: String = ""
    @Published var selectedCommercialInterior: String = ""
    @Published var selectedCommercialExterior: String = ""

    private let residentialInteriorTypesKey = "scout.detailTypes.residential.interior.list.v1"
    private let residentialExteriorTypesKey = "scout.detailTypes.residential.exterior.list.v1"
    private let commercialInteriorTypesKey = "scout.detailTypes.commercial.interior.list.v1"
    private let commercialExteriorTypesKey = "scout.detailTypes.commercial.exterior.list.v1"
    private let selectedResidentialInteriorKey = "scout.detailTypes.residential.interior.selected.v1"
    private let selectedResidentialExteriorKey = "scout.detailTypes.residential.exterior.selected.v1"
    private let selectedCommercialInteriorKey = "scout.detailTypes.commercial.interior.selected.v1"
    private let selectedCommercialExteriorKey = "scout.detailTypes.commercial.exterior.selected.v1"
    private let legacyResidentialInteriorTypesKey = "scout.detailTypes.interior.list.v4"
    private let legacyResidentialExteriorTypesKey = "scout.detailTypes.exterior.list.v4"
    private let legacySelectedResidentialInteriorKey = "scout.detailTypes.interior.selected.v4"
    private let legacySelectedResidentialExteriorKey = "scout.detailTypes.exterior.selected.v4"
    private let legacyInteriorTypesKey = "scout.detailTypes.interior.list.v2"
    private let legacyExteriorTypesKey = "scout.detailTypes.exterior.list.v2"
    private let legacySelectedInteriorKey = "scout.detailTypes.interior.selected.v2"
    private let legacySelectedExteriorKey = "scout.detailTypes.exterior.selected.v2"
    private var pendingPersist: DispatchWorkItem?

    private let defaultResidentialInteriorTypes = [
        "Overview", "Entry / Foyer", "Living Room", "Kitchen", "Dining Area", "Primary Bedroom",
        "Bedroom 2", "Bedroom 3", "Bedroom 4", "Bedroom 5", "Bathroom", "Hallway",
        "Stairs", "Laundry", "Garage", "Mechanical / HVAC", "Storage"
    ]
    private let defaultResidentialExteriorTypes = [
        "Overview", "Elevation", "Entry / Porch", "Window", "Roofline", "Cladding / Siding",
        "Driveway / Garage", "Backyard / Patio", "Landscaping", "Fence / Gate", "Utility / HVAC",
        "Pool / Outdoor Amenities", "Sidewalk", "Exterior Stairs / Ramp", "Downspout", "Chimney", "Foundation"
    ]
    private let defaultCommercialInteriorTypes = [
        "Overview", "Lobby / Reception", "Corridor", "Stairs", "Elevator", "Office",
        "Conference Room", "Open Workspace", "Break Room / Kitchenette", "Restroom", "Storage",
        "Electrical Room", "Mechanical Room", "IT / Server Room", "Janitorial / Service Room",
        "Retail Floor", "Suite Entry", "Leasing / Amenity Area"
    ]
    private let defaultCommercialExteriorTypes = [
        "Overview", "Elevation", "Entry", "Storefront", "Loading Dock", "Parking Area",
        "Site Circulation", "Signage", "Window / Glazing", "Roofline", "Cladding / Facade",
        "Canopy / Awning", "Exterior Stairs / Ramp", "Trash / Service Area", "Fence / Gate",
        "Utility / HVAC", "Mechanical Equipment", "Landscape / Hardscape", "Downspout", "Foundation"
    ]

    init() {
        load()
        normalizeDefaultsIfNeeded()
    }

    func items(for mode: CameraChromeLocationMode, profile: CaptureProfile) -> [DetailTypeItem] {
        switch (profile, mode) {
        case (.residential, .interior): return residentialInteriorTypes
        case (.residential, .exterior): return residentialExteriorTypes
        case (.commercial, .interior): return commercialInteriorTypes
        case (.commercial, .exterior): return commercialExteriorTypes
        }
    }

    func names(for mode: CameraChromeLocationMode, profile: CaptureProfile) -> [String] {
        items(for: mode, profile: profile).map(\.name).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    func selected(for mode: CameraChromeLocationMode, profile: CaptureProfile) -> String {
        switch (profile, mode) {
        case (.residential, .interior): return selectedResidentialInterior
        case (.residential, .exterior): return selectedResidentialExterior
        case (.commercial, .interior): return selectedCommercialInterior
        case (.commercial, .exterior): return selectedCommercialExterior
        }
    }

    func setSelected(_ value: String, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        switch (profile, mode) {
        case (.residential, .interior): selectedResidentialInterior = value
        case (.residential, .exterior): selectedResidentialExterior = value
        case (.commercial, .interior): selectedCommercialInterior = value
        case (.commercial, .exterior): selectedCommercialExterior = value
        }
        persistSelected()
    }

    @discardableResult
    func insertBlankItem(for mode: CameraChromeLocationMode, profile: CaptureProfile) -> UUID {
        let newItem = DetailTypeItem(name: "")
        switch (profile, mode) {
        case (.residential, .interior): residentialInteriorTypes.append(newItem)
        case (.residential, .exterior): residentialExteriorTypes.append(newItem)
        case (.commercial, .interior): commercialInteriorTypes.append(newItem)
        case (.commercial, .exterior): commercialExteriorTypes.append(newItem)
        }
        persistAll()
        return newItem.id
    }

    func updateItem(_ value: String, id: UUID, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        let cleaned = value.trimmingCharacters(in: .newlines)
        switch (profile, mode) {
        case (.residential, .interior):
            guard let idx = residentialInteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            residentialInteriorTypes[idx].name = cleaned
        case (.residential, .exterior):
            guard let idx = residentialExteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            residentialExteriorTypes[idx].name = cleaned
        case (.commercial, .interior):
            guard let idx = commercialInteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            commercialInteriorTypes[idx].name = cleaned
        case (.commercial, .exterior):
            guard let idx = commercialExteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            commercialExteriorTypes[idx].name = cleaned
        }
        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func delete(at offsets: IndexSet, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        switch (profile, mode) {
        case (.residential, .interior):
            let deleting = offsets.compactMap { residentialInteriorTypes.indices.contains($0) ? residentialInteriorTypes[$0].name : nil }
            residentialInteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedResidentialInterior) { selectedResidentialInterior = residentialInteriorTypes.first?.name ?? "" }
        case (.residential, .exterior):
            let deleting = offsets.compactMap { residentialExteriorTypes.indices.contains($0) ? residentialExteriorTypes[$0].name : nil }
            residentialExteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedResidentialExterior) { selectedResidentialExterior = residentialExteriorTypes.first?.name ?? "" }
        case (.commercial, .interior):
            let deleting = offsets.compactMap { commercialInteriorTypes.indices.contains($0) ? commercialInteriorTypes[$0].name : nil }
            commercialInteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedCommercialInterior) { selectedCommercialInterior = commercialInteriorTypes.first?.name ?? "" }
        case (.commercial, .exterior):
            let deleting = offsets.compactMap { commercialExteriorTypes.indices.contains($0) ? commercialExteriorTypes[$0].name : nil }
            commercialExteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedCommercialExterior) { selectedCommercialExterior = commercialExteriorTypes.first?.name ?? "" }
        }
        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func move(from source: IndexSet, to destination: Int, for mode: CameraChromeLocationMode, profile: CaptureProfile) {
        switch (profile, mode) {
        case (.residential, .interior): residentialInteriorTypes.move(fromOffsets: source, toOffset: destination)
        case (.residential, .exterior): residentialExteriorTypes.move(fromOffsets: source, toOffset: destination)
        case (.commercial, .interior): commercialInteriorTypes.move(fromOffsets: source, toOffset: destination)
        case (.commercial, .exterior): commercialExteriorTypes.move(fromOffsets: source, toOffset: destination)
        }
        schedulePersist()
    }

    private func schedulePersist() {
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.normalizeDefaultsIfNeeded()
            self.persistAll()
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func load() {
        residentialInteriorTypes = loadItems(key: residentialInteriorTypesKey, legacyKeys: [legacyResidentialInteriorTypesKey, legacyInteriorTypesKey])
        residentialExteriorTypes = loadItems(key: residentialExteriorTypesKey, legacyKeys: [legacyResidentialExteriorTypesKey, legacyExteriorTypesKey])
        commercialInteriorTypes = loadItems(key: commercialInteriorTypesKey, legacyKeys: [])
        commercialExteriorTypes = loadItems(key: commercialExteriorTypesKey, legacyKeys: [])
        selectedResidentialInterior = UserDefaults.standard.string(forKey: selectedResidentialInteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedResidentialInteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedInteriorKey)
            ?? ""
        selectedResidentialExterior = UserDefaults.standard.string(forKey: selectedResidentialExteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedResidentialExteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedExteriorKey)
            ?? ""
        selectedCommercialInterior = UserDefaults.standard.string(forKey: selectedCommercialInteriorKey) ?? ""
        selectedCommercialExterior = UserDefaults.standard.string(forKey: selectedCommercialExteriorKey) ?? ""
    }

    private func persistAll() {
        saveItems(residentialInteriorTypes, key: residentialInteriorTypesKey)
        saveItems(residentialExteriorTypes, key: residentialExteriorTypesKey)
        saveItems(commercialInteriorTypes, key: commercialInteriorTypesKey)
        saveItems(commercialExteriorTypes, key: commercialExteriorTypesKey)
        persistSelected()
    }

    private func persistSelected() {
        UserDefaults.standard.set(selectedResidentialInterior, forKey: selectedResidentialInteriorKey)
        UserDefaults.standard.set(selectedResidentialExterior, forKey: selectedResidentialExteriorKey)
        UserDefaults.standard.set(selectedCommercialInterior, forKey: selectedCommercialInteriorKey)
        UserDefaults.standard.set(selectedCommercialExterior, forKey: selectedCommercialExteriorKey)
    }

    private func normalizeDefaultsIfNeeded() {
        if residentialInteriorTypes.isEmpty { residentialInteriorTypes = defaultResidentialInteriorTypes.map { DetailTypeItem(name: $0) } }
        if residentialExteriorTypes.isEmpty { residentialExteriorTypes = defaultResidentialExteriorTypes.map { DetailTypeItem(name: $0) } }
        if commercialInteriorTypes.isEmpty { commercialInteriorTypes = defaultCommercialInteriorTypes.map { DetailTypeItem(name: $0) } }
        if commercialExteriorTypes.isEmpty { commercialExteriorTypes = defaultCommercialExteriorTypes.map { DetailTypeItem(name: $0) } }
        if selectedResidentialInterior.isEmpty { selectedResidentialInterior = firstNonEmpty(from: residentialInteriorTypes) ?? "" }
        if selectedResidentialExterior.isEmpty { selectedResidentialExterior = firstNonEmpty(from: residentialExteriorTypes) ?? "" }
        if selectedCommercialInterior.isEmpty { selectedCommercialInterior = firstNonEmpty(from: commercialInteriorTypes) ?? "" }
        if selectedCommercialExterior.isEmpty { selectedCommercialExterior = firstNonEmpty(from: commercialExteriorTypes) ?? "" }
        if !residentialInteriorTypes.contains(where: { $0.name == selectedResidentialInterior }) { selectedResidentialInterior = firstNonEmpty(from: residentialInteriorTypes) ?? "" }
        if !residentialExteriorTypes.contains(where: { $0.name == selectedResidentialExterior }) { selectedResidentialExterior = firstNonEmpty(from: residentialExteriorTypes) ?? "" }
        if !commercialInteriorTypes.contains(where: { $0.name == selectedCommercialInterior }) { selectedCommercialInterior = firstNonEmpty(from: commercialInteriorTypes) ?? "" }
        if !commercialExteriorTypes.contains(where: { $0.name == selectedCommercialExterior }) { selectedCommercialExterior = firstNonEmpty(from: commercialExteriorTypes) ?? "" }
    }

    private func firstNonEmpty(from list: [DetailTypeItem]) -> String? {
        list.first(where: { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.name
    }

    private func loadItems(key: String, legacyKeys: [String]) -> [DetailTypeItem] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DetailTypeItem].self, from: data) {
            return decoded
        }
        for legacyKey in legacyKeys {
            if let legacyData = UserDefaults.standard.data(forKey: legacyKey),
               let decodedItems = try? JSONDecoder().decode([DetailTypeItem].self, from: legacyData) {
                return decodedItems
            }
            if let legacyData = UserDefaults.standard.data(forKey: legacyKey),
               let decodedStrings = try? JSONDecoder().decode([String].self, from: legacyData) {
                return decodedStrings.map { DetailTypeItem(name: $0) }
            }
        }
        return []
    }

    private func saveItems(_ items: [DetailTypeItem], key: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private struct FastLaneSheetControlTheme {
    let fill: Color
    let stroke: Color
    let label: Color

    static func forScheme(_ scheme: ColorScheme) -> FastLaneSheetControlTheme {
        if scheme == .light {
            return FastLaneSheetControlTheme(fill: Color.white.opacity(0.90), stroke: Color.black.opacity(0.14), label: Color.black.opacity(0.88))
        }
        return FastLaneSheetControlTheme(fill: Color.black.opacity(0.55), stroke: Color.white.opacity(0.28), label: Color.white)
    }
}

private enum FastLaneMetadataSelectionKind: Hashable {
    case building
    case elevation
    case detailType
    case trade
}

private enum FastLanePendingManageDestination {
    case buildings
    case interior
    case exterior
    case trades
}

private struct FastLaneMetadataSelectionContext: Identifiable, Hashable {
    let id = UUID()
    let kind: FastLaneMetadataSelectionKind
    let title: String
}

private struct FastLaneMetadataFilterSheet: View {
    let profile: CaptureProfile
    let context: AppState.FastRuntimeCaptureMetadataContext
    @Binding var buildingOptions: [String]
    @Binding var tradeOptions: [String]
    @ObservedObject var detailTypesModel: FastLaneDetailTypesModel
    let onCancel: () -> Void
    let onConfirm: (AppState.FastRuntimeCaptureMetadataContext) -> Void

    @State private var selectedBuilding: String
    @State private var selectedElevation: String
    @State private var selectedDetailType: String
    @State private var selectedTrade: String
    @State private var selectionContext: FastLaneMetadataSelectionContext?
    @State private var showManageBuildingsSheet = false
    @State private var showManageTradesSheet = false
    @State private var manageDetailMode: CameraChromeLocationMode?
    @Environment(\.colorScheme) private var colorScheme
    private var sheetTheme: FastLaneSheetControlTheme { .forScheme(colorScheme) }

    init(
        profile: CaptureProfile,
        context: AppState.FastRuntimeCaptureMetadataContext,
        buildingOptions: Binding<[String]>,
        tradeOptions: Binding<[String]>,
        detailTypesModel: FastLaneDetailTypesModel,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (AppState.FastRuntimeCaptureMetadataContext) -> Void
    ) {
        let normalized = AppState.normalizedFastRuntimeMetadataContext(context, fallbackPosition: 4)
        self.profile = profile
        self.context = normalized
        self._buildingOptions = buildingOptions
        self._tradeOptions = tradeOptions
        self.detailTypesModel = detailTypesModel
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        _selectedBuilding = State(initialValue: normalized.building)
        _selectedElevation = State(initialValue: normalized.elevation)
        _selectedDetailType = State(initialValue: normalized.detailType)
        _selectedTrade = State(initialValue: FastLaneMetadataOptions.canonicalTradeLabel(normalized.trade, preferredOptions: tradeOptions.wrappedValue))
    }

    private var selectedLocationMode: CameraChromeLocationMode {
        selectedElevation.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Interior") == .orderedSame
            ? .interior
            : .exterior
    }

    private var tradePickerOptions: [String] {
        FastLaneMetadataOptions.canonicalTradeOptions(tradeOptions, selectedTrade: selectedTrade)
    }

    private var buildingSelectionLabel: String {
        guard let option = buildingOptions.first(where: { FastLaneMetadataOptions.buildingCode(from: $0) == selectedBuilding }) else {
            return selectedBuilding.isEmpty ? "Select" : selectedBuilding
        }
        return FastLaneMetadataOptions.buildingDisplayName(for: option)
    }

    private var detailTypeSelectionLabel: String {
        let trimmed = selectedDetailType.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("General Elevation") == .orderedSame { return "General" }
        return trimmed.isEmpty ? "Select" : trimmed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Metadata") {
                    metadataSelectorRow(
                        title: "Building",
                        value: buildingSelectionLabel,
                        context: FastLaneMetadataSelectionContext(kind: .building, title: "Building"),
                        manageDestination: .buildings
                    )

                    if selectedLocationMode == .exterior {
                        metadataSelectorRow(
                            title: "Elevation",
                            value: selectedElevation,
                            context: FastLaneMetadataSelectionContext(kind: .elevation, title: "Elevation"),
                            titleColor: .white
                        )
                    }

                    metadataSelectorRow(
                        title: "Detail Type",
                        value: detailTypeSelectionLabel,
                        context: FastLaneMetadataSelectionContext(
                            kind: .detailType,
                            title: selectedLocationMode == .interior ? "Interior Detail Type" : "Exterior Detail Type"
                        ),
                        titleColor: .blue,
                        manageDestination: selectedLocationMode == .interior ? .interior : .exterior
                    )

                    metadataSelectorRow(
                        title: "Trade",
                        value: selectedTrade.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "None" : selectedTrade,
                        context: FastLaneMetadataSelectionContext(kind: .trade, title: "Trade"),
                        titleColor: .blue,
                        manageDestination: .trades
                    )
                }
            }
            .navigationDestination(item: $selectionContext) { context in
                FastLaneMetadataSelectionListView(
                    title: context.title,
                    options: selectionOptions(for: context.kind),
                    selectedValue: currentSelectionValue(for: context.kind),
                    onSelect: { value in applySelection(value, for: context.kind) }
                )
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 78, height: 42)
                    Spacer(minLength: 0)
                    Text("Filter")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        onConfirm(AppState.FastRuntimeCaptureMetadataContext(
                            locationMode: selectedLocationMode.rawValue,
                            building: selectedBuilding,
                            elevation: selectedLocationMode == .interior ? "Interior" : selectedElevation,
                            detailType: selectedDetailType,
                            trade: selectedTrade,
                            angleIndex: context.angleIndex
                        ))
                    } label: {
                        Text("Done")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(sheetTheme.label)
                            .frame(minHeight: 42)
                            .padding(.horizontal, 14)
                            .background(sheetTheme.fill)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(sheetTheme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .background(Color.clear)
            }
            .sheet(isPresented: $showManageBuildingsSheet, onDismiss: normalizeBuildingSelection) {
                FastLaneManageBuildingsSheet(
                    options: $buildingOptions,
                    selectedBuilding: $selectedBuilding,
                    onClose: { showManageBuildingsSheet = false }
                )
            }
            .sheet(item: $manageDetailMode, onDismiss: normalizeDetailSelection) { mode in
                FastLaneManageDetailTypesView(mode: mode, profile: profile, model: detailTypesModel)
            }
            .sheet(isPresented: $showManageTradesSheet, onDismiss: normalizeTradeOptions) {
                FastLaneManageTradesSheet(
                    options: $tradeOptions,
                    selectedTrade: $selectedTrade,
                    onClose: { showManageTradesSheet = false }
                )
            }
            .onAppear {
                normalizeBuildingSelection()
                normalizeDetailSelection()
                normalizeTradeOptions()
            }
            .onChange(of: selectedElevation) { _, _ in normalizeDetailSelection() }
            .onChange(of: buildingOptions) { _, _ in normalizeBuildingSelection() }
        }
    }

    @ViewBuilder
    private func metadataFieldLabel(
        _ title: String,
        titleColor: Color = .primary,
        manageDestination: FastLanePendingManageDestination? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundColor(titleColor)
            if let manageDestination {
                Button {
                    switch manageDestination {
                    case .buildings:
                        showManageBuildingsSheet = true
                    case .interior:
                        manageDetailMode = .interior
                    case .exterior:
                        manageDetailMode = .exterior
                    case .trades:
                        showManageTradesSheet = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.86))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
            }
        }
    }

    @ViewBuilder
    private func metadataSelectorRow(
        title: String,
        value: String,
        context: FastLaneMetadataSelectionContext,
        titleColor: Color = .primary,
        manageDestination: FastLanePendingManageDestination? = nil
    ) -> some View {
        HStack(spacing: 12) {
            metadataFieldLabel(title, titleColor: titleColor, manageDestination: manageDestination)
            Spacer(minLength: 0)
            Button {
                selectionContext = context
            } label: {
                HStack(spacing: 8) {
                    Text(value)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func selectionOptions(for kind: FastLaneMetadataSelectionKind) -> [(title: String, value: String)] {
        switch kind {
        case .building:
            return buildingOptions.map { option in
                (FastLaneMetadataOptions.buildingDisplayName(for: option), FastLaneMetadataOptions.buildingCode(from: option))
            }
        case .elevation:
            return Self.exteriorElevationOptions.map { ($0, $0) }
        case .detailType:
            return detailTypesModel.items(for: selectedLocationMode, profile: profile).compactMap { item in
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return (name.caseInsensitiveCompare("General Elevation") == .orderedSame ? "General" : name, name)
            }
        case .trade:
            return [("None", "")] + tradePickerOptions.map { ($0, $0) }
        }
    }

    private func currentSelectionValue(for kind: FastLaneMetadataSelectionKind) -> String {
        switch kind {
        case .building: return selectedBuilding
        case .elevation: return selectedElevation
        case .detailType: return selectedDetailType
        case .trade: return selectedTrade
        }
    }

    private func applySelection(_ value: String, for kind: FastLaneMetadataSelectionKind) {
        switch kind {
        case .building:
            selectedBuilding = value
        case .elevation:
            selectedElevation = value
        case .detailType:
            selectedDetailType = value
            detailTypesModel.setSelected(value, for: selectedLocationMode, profile: profile)
        case .trade:
            selectedTrade = FastLaneMetadataOptions.canonicalTradeLabel(value, preferredOptions: tradeOptions)
        }
    }

    private func normalizeBuildingSelection() {
        FastLaneMetadataOptions.persistBuildingOptions(buildingOptions, selectedBuilding: &selectedBuilding)
        let code = FastLaneMetadataOptions.buildingCode(from: selectedBuilding)
        selectedBuilding = buildingOptions.contains(where: { FastLaneMetadataOptions.buildingCode(from: $0) == code })
            ? code
            : (buildingOptions.first.map(FastLaneMetadataOptions.buildingCode(from:)) ?? "B1")
    }

    private func normalizeTradeOptions() {
        FastLaneMetadataOptions.persistTradeOptions(&tradeOptions, selectedTrade: &selectedTrade)
    }

    private func normalizeDetailSelection() {
        let options = detailTypesModel.names(for: selectedLocationMode, profile: profile)
        guard !options.contains(selectedDetailType) else { return }
        selectedDetailType = options.first ?? "Overview"
        detailTypesModel.setSelected(selectedDetailType, for: selectedLocationMode, profile: profile)
    }

    private static let exteriorElevationOptions = ["North", "South", "East", "West"]
}

private struct FastLaneMetadataSelectionListView: View {
    let title: String
    let options: [(title: String, value: String)]
    let selectedValue: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    private var theme: FastLaneSheetControlTheme { .forScheme(colorScheme) }

    var body: some View {
        List(options, id: \.value) { option in
            Button {
                dismiss()
                DispatchQueue.main.async { onSelect(option.value) }
            } label: {
                HStack(spacing: 10) {
                    Text(option.title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if selectedValue == option.value {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.insetGrouped)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(theme.label)
                        .frame(width: 44, height: 44)
                        .background(theme.fill)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.label)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .background(Color(uiColor: .systemGroupedBackground))
        }
    }
}

private struct FastLaneManageDetailTypesView: View {
    let mode: CameraChromeLocationMode
    let profile: CaptureProfile
    @ObservedObject var model: FastLaneDetailTypesModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @State private var editModeState: EditMode = .inactive
    @FocusState private var focusedRow: UUID?
    private var theme: FastLaneSheetControlTheme { .forScheme(colorScheme) }
    private var titleText: String { "\(profile.title) \(mode == .interior ? "Interior Detail Types" : "Exterior Detail Types")" }
    private var isEditing: Bool { editModeState == .active }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.items(for: mode, profile: profile)) { item in
                    rowView(item: item)
                }
                .onDelete { offsets in
                    withAnimation(.none) { model.delete(at: offsets, for: mode, profile: profile) }
                }
                .onMove { source, destination in
                    withAnimation(.none) { model.move(from: source, to: destination, for: mode, profile: profile) }
                }
            }
            .environment(\.editMode, $editModeState)
            .listStyle(.insetGrouped)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        toolbarCapsuleLabel {
                            Text("Done")
                                .font(.system(size: 17, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Text(titleText)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(theme.label)
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    HStack(spacing: 0) {
                        Button {
                            if editModeState != .active { editModeState = .active }
                            let newId = model.insertBlankItem(for: mode, profile: profile)
                            DispatchQueue.main.async { focusedRow = newId }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(theme.label)
                                .frame(width: 44, height: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            if editModeState == .active {
                                editModeState = .inactive
                                focusedRow = nil
                            } else {
                                editModeState = .active
                            }
                        } label: {
                            Group {
                                if editModeState == .active {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 17, weight: .medium))
                                } else {
                                    Text("Edit")
                                        .font(.system(size: 17, weight: .medium))
                                }
                            }
                            .foregroundColor(theme.label)
                            .frame(width: 72, height: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .background(Color.clear)
            }
        }
    }

    @ViewBuilder
    private func toolbarCapsuleLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .foregroundColor(theme.label)
            .frame(minHeight: 42)
            .padding(.horizontal, 14)
            .background(theme.fill)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private func rowView(item: FastLaneDetailTypesModel.DetailTypeItem) -> some View {
        if isEditing {
            TextField("Name", text: bindingForRow(id: item.id))
                .focused($focusedRow, equals: item.id)
                .submitLabel(.done)
                .onSubmit { focusedRow = nil }
        } else {
            HStack(spacing: 10) {
                Text(item.name.isEmpty ? " " : item.name)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
        }
    }

    private func bindingForRow(id: UUID) -> Binding<String> {
        Binding(
            get: { model.items(for: mode, profile: profile).first(where: { $0.id == id })?.name ?? "" },
            set: { newValue in
                withAnimation(.none) {
                    model.updateItem(newValue, id: id, for: mode, profile: profile)
                }
            }
        )
    }
}

private struct FastLaneManageTradesSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: FastLaneSheetControlTheme { .forScheme(colorScheme) }
    @State private var editModeState: EditMode = .inactive
    @FocusState private var focusedIndex: Int?
    @Binding var options: [String]
    @Binding var selectedTrade: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(options.indices), id: \.self) { index in
                    if editModeState == .active {
                        TextField("Trade", text: Binding(
                            get: { options.indices.contains(index) ? options[index] : "" },
                            set: { newValue in
                                guard options.indices.contains(index) else { return }
                                options[index] = newValue
                            }
                        ))
                        .focused($focusedIndex, equals: index)
                        .submitLabel(.done)
                    } else {
                        HStack(spacing: 10) {
                            Text(options[index])
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .onDelete { offsets in options.remove(atOffsets: offsets) }
                .onMove { source, destination in options.move(fromOffsets: source, toOffset: destination) }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editModeState)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                manageToolbar(title: "Trades")
            }
            .onDisappear {
                FastLaneMetadataOptions.persistTradeOptions(&options, selectedTrade: &selectedTrade)
            }
        }
    }

    private func manageToolbar(title: String) -> some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Text("Done")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(theme.label)
                    .frame(minHeight: 42)
                    .padding(.horizontal, 14)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(theme.label)
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 0) {
                Button {
                    if editModeState != .active { editModeState = .active }
                    options.append("New Trade")
                    focusedIndex = max(0, options.count - 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(theme.label)
                        .frame(width: 44, height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    if editModeState == .active {
                        editModeState = .inactive
                        focusedIndex = nil
                    } else {
                        editModeState = .active
                    }
                } label: {
                    Group {
                        if editModeState == .active {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17, weight: .medium))
                        } else {
                            Text("Edit")
                                .font(.system(size: 17, weight: .medium))
                        }
                    }
                    .foregroundColor(theme.label)
                    .frame(width: 72, height: 42)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(theme.fill)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

private struct FastLaneManageBuildingsSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    private var theme: FastLaneSheetControlTheme { .forScheme(colorScheme) }
    @State private var editModeState: EditMode = .inactive
    @FocusState private var focusedIndex: Int?
    @Binding var options: [String]
    @Binding var selectedBuilding: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(options.indices), id: \.self) { index in
                    if editModeState == .active {
                        TextField("Building", text: Binding(
                            get: { options.indices.contains(index) ? options[index] : "" },
                            set: { newValue in
                                guard options.indices.contains(index) else { return }
                                options[index] = newValue
                            }
                        ))
                        .focused($focusedIndex, equals: index)
                        .submitLabel(.done)
                    } else {
                        HStack(spacing: 10) {
                            Text(FastLaneMetadataOptions.buildingDisplayName(for: options[index]))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .onDelete { offsets in options.remove(atOffsets: offsets) }
                .onMove { source, destination in options.move(fromOffsets: source, toOffset: destination) }
            }
            .listStyle(.insetGrouped)
            .environment(\.editMode, $editModeState)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(spacing: 10) {
                    Button(action: onClose) {
                        Text("Done")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(theme.label)
                            .frame(minHeight: 42)
                            .padding(.horizontal, 14)
                            .background(theme.fill)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)

                    Text("Buildings")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(theme.label)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    HStack(spacing: 0) {
                        Button {
                            if editModeState != .active { editModeState = .active }
                            options.append("New Building")
                            focusedIndex = max(0, options.count - 1)
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(theme.label)
                                .frame(width: 44, height: 42)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            if editModeState == .active {
                                editModeState = .inactive
                                focusedIndex = nil
                            } else {
                                editModeState = .active
                            }
                        } label: {
                            Group {
                                if editModeState == .active {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 17, weight: .medium))
                                } else {
                                    Text("Edit")
                                        .font(.system(size: 17, weight: .medium))
                                }
                            }
                            .foregroundColor(theme.label)
                            .frame(width: 72, height: 42)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(theme.stroke, lineWidth: 1))
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 4)
            }
            .onDisappear {
                FastLaneMetadataOptions.persistBuildingOptions(options, selectedBuilding: &selectedBuilding)
            }
        }
    }
}

private struct FastRuntimePreviewCaptureTiming {
    let shutterTappedAt: Date
    let hapticAt: Date
    let imageCapturedAt: Date
    let savedAt: Date?
    let saveResult: AppState.FastRuntimePrototypeCaptureSaveResult?

    var hapticMilliseconds: Double {
        hapticAt.timeIntervalSince(shutterTappedAt) * 1_000
    }

    var imageCapturedMilliseconds: Double {
        imageCapturedAt.timeIntervalSince(shutterTappedAt) * 1_000
    }

    var fileWriteMilliseconds: Double? {
        saveResult?.timings.fileWriteMilliseconds
    }

    var metadataMilliseconds: Double? {
        saveResult?.timings.metadataMilliseconds
    }

    var totalMilliseconds: Double? {
        savedAt.map { $0.timeIntervalSince(shutterTappedAt) * 1_000 }
    }
}

private struct FastRuntimeCompleteDryRunResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: AppState.FastRuntimeCompleteDryRunResult

    var body: some View {
        NavigationStack {
            List {
                Section("Result") {
                    diagnosticRow("Valid", result.isValid ? "true" : "false")
                    diagnosticRow("Photo Count", "\(result.photoCount)")
                    diagnosticRow("Metadata Count", "\(result.metadataPhotoCount)")
                    diagnosticRow("Missing Files", "\(result.missingFilesCount)")
                    diagnosticRow("Session Type", result.sessionType.rawValue)
                    diagnosticRow("Metadata Source", result.metadataSource)
                    diagnosticRow("Total Bytes", "\(result.totalBytes)")
                }

                Section("Identity") {
                    diagnosticRow("Org ID", result.orgID?.uuidString ?? "missing")
                    diagnosticRow("Property ID", result.propertyID.uuidString)
                    diagnosticRow("Session ID", result.sessionID.uuidString)
                    diagnosticRow("Owner User", result.ownerUserID?.uuidString ?? "missing")
                    diagnosticRow("Owner Email", result.ownerEmail ?? "none")
                    diagnosticRow("Owner Device", result.ownerDeviceID ?? "missing")
                }

                if !result.missingFields.isEmpty {
                    Section("Missing Fields") {
                        diagnosticBlock("Fields", result.missingFields.joined(separator: "\n"))
                    }
                }

                if let corruptMetadataMessage = result.corruptMetadataMessage {
                    Section("Metadata Error") {
                        diagnosticBlock("Error", corruptMetadataMessage)
                    }
                }

                if !result.warnings.isEmpty {
                    Section("Warnings") {
                        diagnosticBlock("Warnings", result.warnings.joined(separator: "\n"))
                    }
                }

                Section("Would Create") {
                    diagnosticBlock("Dry Run Only", result.wouldCreate.joined(separator: "\n"))
                }

                Section("Would Upload") {
                    if result.wouldUpload.isEmpty {
                        Text("No upload candidates.")
                            .foregroundStyle(.secondary)
                    } else {
                        diagnosticBlock("Files", result.wouldUpload.joined(separator: "\n"))
                    }
                }

                Section("Shots") {
                    ForEach(result.shots) { shot in
                        VStack(alignment: .leading, spacing: 5) {
                            diagnosticRow("Shot", shot.id.uuidString)
                            diagnosticRow("Capture Kind", shot.captureKind)
                            diagnosticRow("File Exists", shot.fileExists ? "true" : "false")
                            diagnosticRow("Bytes", shot.byteSize.map(String.init) ?? "missing")
                            diagnosticBlock("Resolved Path", shot.resolvedLocalFilePath ?? "missing")
                            if shot.resolvedLocalFilePath != shot.metadataLocalFilePath {
                                diagnosticBlock("Metadata Path", shot.metadataLocalFilePath)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Safety") {
                    Text("Dry run only. No Supabase write, storage upload, report, email, Complete, or local draft deletion was performed.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FastRuntimeCompleteUploadResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: AppState.FastRuntimeCompleteUploadResult

    var body: some View {
        NavigationStack {
            List {
                Section("Result") {
                    diagnosticRow("Success", result.success ? "true" : "false")
                    diagnosticRow("Dry Run Valid", result.dryRun.isValid ? "true" : "false")
                    diagnosticRow("Uploaded Files", "\(result.uploadedFilesCount)")
                    diagnosticRow("Session Status", result.sessionStatus)
                    diagnosticRow("Property Status", result.propertyStatus)
                    diagnosticRow("Lock Released", result.lockReleased ? "true" : "false")
                    diagnosticRow("Draft Hidden", result.localDraftMarkedUploaded ? "true" : "false")
                    diagnosticRow("Total", String(format: "%.1f ms", result.totalMilliseconds))
                }

                if let errorMessage = result.errorMessage {
                    Section("Error") {
                        diagnosticBlock("Message", errorMessage)
                    }
                }

                Section("Rows") {
                    if result.createdRowsSummary.isEmpty {
                        Text("No rows written.")
                            .foregroundStyle(.secondary)
                    } else {
                        diagnosticBlock("Summary", result.createdRowsSummary.joined(separator: "\n"))
                    }
                    diagnosticBlock("Package", result.packageSummary)
                }

                if !result.diagnostics.isEmpty {
                    Section("Diagnostics") {
                        diagnosticBlock("Stages", result.diagnostics.joined(separator: "\n"))
                    }
                }

                Section("Identity") {
                    diagnosticRow("Org ID", result.dryRun.orgID?.uuidString ?? "missing")
                    diagnosticRow("Property ID", result.dryRun.propertyID.uuidString)
                    diagnosticRow("Session ID", result.dryRun.sessionID.uuidString)
                    diagnosticRow("Session Type", result.dryRun.sessionType.rawValue)
                }

                Section("Shots") {
                    if result.shots.isEmpty {
                        Text("No shot uploads completed.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(result.shots) { shot in
                            VStack(alignment: .leading, spacing: 5) {
                                diagnosticRow("Shot", shot.id.uuidString)
                                diagnosticRow("Uploaded", shot.uploaded ? "true" : "false")
                                diagnosticRow("Bucket", shot.storageBucket ?? "none")
                                diagnosticBlock("Storage Path", shot.storagePath ?? "none")
                                diagnosticRow("Bytes", shot.byteSize.map(String.init) ?? "missing")
                                diagnosticBlock("Checksum", shot.checksumSHA256 ?? "none")
                                diagnosticBlock("Local File", shot.localFilePath)
                                if let errorMessage = shot.errorMessage {
                                    diagnosticBlock("Error", errorMessage)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Safety") {
                    Text("Experimental fast-lane write. It uploaded originals and wrote session/shot/property status rows only. It did not create session snapshots, dispatch report workers, send email, delete local files, or touch legacy drafts.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FastRuntimeReportPackageDryRunResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: AppState.FastRuntimeReportPackageDryRunResult

    var body: some View {
        NavigationStack {
            List {
                Section("Result") {
                    diagnosticRow("Valid", result.isValid ? "true" : "false")
                    diagnosticRow("Session Type", result.sessionType.rawValue)
                    diagnosticRow("Session Status", result.sessionStatus ?? "missing")
                    diagnosticRow("Property Status", result.propertyStatus ?? "missing")
                    diagnosticRow("Shot Count", "\(result.shotCount)")
                    diagnosticRow("Storage Objects", "\(result.storageObjectCount)")
                    diagnosticRow("Report Mode", result.reportMode)
                    diagnosticRow("Email Wording", result.emailWordingType)
                    diagnosticRow("Total", String(format: "%.1f ms", result.totalMilliseconds))
                }

                Section("Identity") {
                    diagnosticRow("Org ID", result.orgID?.uuidString ?? "missing")
                    diagnosticRow("Property ID", result.propertyID.uuidString)
                    diagnosticRow("Session ID", result.sessionID?.uuidString ?? "missing")
                    diagnosticRow("Pending Export Session", result.propertyStatusPendingExportSessionID?.uuidString ?? "missing")
                }

                Section("Snapshot Candidate") {
                    diagnosticRow("Snapshot ID", result.snapshotID?.uuidString ?? "missing")
                    diagnosticRow("Bucket", result.snapshotStorageBucket ?? "missing")
                    diagnosticBlock("Path", result.snapshotStoragePath ?? "missing")
                    diagnosticRow("Payload Bytes", result.snapshotPayloadBytes.map(String.init) ?? "missing")
                    diagnosticBlock("Raw JSON SHA", result.rawSessionJSONSHA256 ?? "missing")
                    diagnosticBlock("Payload SHA", result.snapshotPayloadSHA256 ?? "missing")
                }

                Section("Package Candidate") {
                    diagnosticRow("Package ID", result.reportPackageID?.uuidString ?? "missing")
                    diagnosticBlock("Idempotency Key", result.reportPackageIdempotencyKey ?? "missing")
                    if result.fileCandidates.isEmpty {
                        Text("No package file candidates.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(result.fileCandidates) { file in
                            VStack(alignment: .leading, spacing: 5) {
                                diagnosticRow("Report Type", file.reportType)
                                diagnosticRow("Bucket", file.storageBucket)
                                diagnosticRow("Filename", file.filename)
                                diagnosticBlock("Path", file.storagePath)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Would Create") {
                    if result.wouldCreate.isEmpty {
                        Text("No create candidates.")
                            .foregroundStyle(.secondary)
                    } else {
                        diagnosticBlock("Dry Run Only", result.wouldCreate.joined(separator: "\n"))
                    }
                }

                if !result.sideEffectCounts.isEmpty {
                    Section("Existing Side Effects") {
                        ForEach(result.sideEffectCounts.keys.sorted(), id: \.self) { key in
                            diagnosticRow(key, "\(result.sideEffectCounts[key] ?? 0)")
                        }
                    }
                }

                if !result.missingFields.isEmpty {
                    Section("Missing Fields") {
                        diagnosticBlock("Fields", result.missingFields.joined(separator: "\n"))
                    }
                }

                if !result.errors.isEmpty {
                    Section("Errors") {
                        diagnosticBlock("Errors", result.errors.joined(separator: "\n"))
                    }
                }

                if !result.warnings.isEmpty {
                    Section("Warnings") {
                        diagnosticBlock("Warnings", result.warnings.joined(separator: "\n"))
                    }
                }

                Section("Shots") {
                    if result.shots.isEmpty {
                        Text("No shots.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(result.shots) { shot in
                            VStack(alignment: .leading, spacing: 5) {
                                diagnosticRow("Shot", shot.id.uuidString)
                                diagnosticRow("Capture Kind", shot.captureKind ?? "missing")
                                diagnosticRow("Upload State", shot.uploadState)
                                diagnosticRow("Object Exists", shot.storageObjectExists ? "true" : "false")
                                diagnosticRow("Shot Bytes", shot.shotByteSize.map(String.init) ?? "missing")
                                diagnosticRow("Storage Bytes", shot.storageByteSize.map(String.init) ?? "missing")
                                diagnosticRow("Bucket", shot.storageBucket ?? "missing")
                                diagnosticBlock("Path", shot.storagePath ?? "missing")
                                diagnosticBlock("Checksum", shot.checksumSHA256 ?? "missing")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Safety") {
                    Text("Dry run only. No session snapshot row, report package, package file, storage upload, worker dispatch, email, property status update, or local deletion was performed.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct FastRuntimeReportHandoffResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: AppState.FastRuntimeReportHandoffResult

    var body: some View {
        NavigationStack {
            List {
                Section("Result") {
                    diagnosticRow("Success", result.success ? "true" : "false")
                    diagnosticRow("Function Status", result.functionStatus)
                    diagnosticRow("Session Type", result.sessionType.rawValue)
                    diagnosticRow("Report Mode", result.reportMode)
                    diagnosticRow("Shot Count", result.shotCount.map(String.init) ?? "missing")
                    diagnosticRow("Reused Snapshot", result.reused.map { $0 ? "true" : "false" } ?? "unknown")
                    diagnosticRow("Dispatch Expected", result.dispatchExpected.map { $0 ? "true" : "false" } ?? "unknown")
                    diagnosticRow("Dispatch Status", result.dispatchStatus ?? "unknown")
                    diagnosticRow("Total", String(format: "%.1f ms", result.totalMilliseconds))
                    if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
                        diagnosticBlock("Error", errorMessage)
                    }
                }

                Section("Snapshot") {
                    diagnosticRow("Snapshot ID", result.snapshotID?.uuidString ?? "missing")
                    diagnosticRow("Bucket", result.snapshotBucket ?? "missing")
                    diagnosticBlock("Path", result.snapshotPath ?? "missing")
                    diagnosticBlock("Payload SHA", result.snapshotPayloadSHA256 ?? "missing")
                    diagnosticBlock("Raw JSON SHA", result.rawSessionJSONSHA256 ?? "missing")
                }

                Section("Identity") {
                    diagnosticRow("Org ID", result.dryRun.orgID?.uuidString ?? "missing")
                    diagnosticRow("Property ID", result.dryRun.propertyID.uuidString)
                    diagnosticRow("Session ID", result.sessionID?.uuidString ?? result.dryRun.sessionID?.uuidString ?? "missing")
                    diagnosticBlock("Idempotency Key", result.idempotencyKey ?? "missing")
                }

                Section("Dry Run Gate") {
                    diagnosticRow("Valid", result.dryRun.isValid ? "true" : "false")
                    diagnosticRow("Session Status", result.dryRun.sessionStatus ?? "missing")
                    diagnosticRow("Property Status", result.dryRun.propertyStatus ?? "missing")
                    diagnosticRow("Storage Objects", "\(result.dryRun.storageObjectCount)")
                    if !result.dryRun.errors.isEmpty {
                        diagnosticBlock("Dry Run Errors", result.dryRun.errors.joined(separator: "\n"))
                    }
                    if !result.dryRun.missingFields.isEmpty {
                        diagnosticBlock("Missing Fields", result.dryRun.missingFields.joined(separator: "\n"))
                    }
                    if !result.dryRun.warnings.isEmpty {
                        diagnosticBlock("Warnings", result.dryRun.warnings.joined(separator: "\n"))
                    }
                }

                Section("Safety") {
                    Text("Debug-only handoff. The app ran the report dry run first, then called the authenticated fast-lane-report-handoff Edge Function. It did not use a service-role key, delete local files, hide pending export, or touch legacy sessions.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DebugToolsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let onShowMigrationExport: () -> Void
    let onShowMigrationImport: () -> Void

    private let localStore = LocalStore()
    @State private var showNuclearConfirm: Bool = false
    @State private var showClearCacheConfirm: Bool = false
    @State private var isRunningMigrationPreflight: Bool = false
    @State private var isRunningMigrationStep2A: Bool = false
    @State private var isRunningMigrationStep2BSlice1: Bool = false
    @State private var isRunningMigrationStep2BSlice2A: Bool = false
    @State private var isRunningMigrationStep2BSlice2BReadiness: Bool = false
    @State private var isRunningMigrationStep2BSlice2BFinalize: Bool = false
    @State private var isRunningCaptureProfileMaintenanceBackfill: Bool = false
    @State private var migrationPreflightStatusMessage: String? = nil
    @State private var migrationStep2AStatusMessage: String? = nil
    @State private var migrationStep2BSlice1StatusMessage: String? = nil
    @State private var migrationStep2BSlice2AStatusMessage: String? = nil
    @State private var migrationStep2BSlice2BReadinessStatusMessage: String? = nil
    @State private var migrationStep2BSlice2BFinalizeStatusMessage: String? = nil
    @State private var captureProfileMaintenanceBackfillStatusMessage: String? = nil
    @State private var isRunningForegroundPropertyRefresh: Bool = false
    @State private var foregroundPropertyRefreshStatusMessage: String? = nil
    @State private var migrationPreflightErrorMessage: String? = nil
    @State private var showMigrationPreflightError: Bool = false
    @State private var preflightReportText: String = ""
    @State private var showPreflightReportSheet: Bool = false
    @State private var showLocalOrgRepairSheet: Bool = false
    @State private var showLocalDiagnosticsSheet: Bool = false
    @State private var showFastRuntimePrototypeSheet: Bool = false
    @State private var selectedFastLaneLauncherPropertyID: UUID? = nil
    @State private var isStartingFastLaneSession: Bool = false
    @State private var fastLaneLauncherResult: AppState.FastRuntimePrototypeResult? = nil
    @State private var fastLaneLauncherPreviewRequest: FastRuntimeCameraPreviewRequest? = nil
    @State private var fastLaneLauncherCloseResult: AppState.FastRuntimePrototypeCloseResult? = nil
    @State private var isRunningFastLaneReportDryRun: Bool = false
    @State private var fastLaneReportDryRunResult: AppState.FastRuntimeReportPackageDryRunResult? = nil
    @State private var isRunningFastLaneReportHandoff: Bool = false
    @State private var fastLaneReportHandoffResult: AppState.FastRuntimeReportHandoffResult? = nil
    @State private var isMarkingFastLanePendingExportDelivered: Bool = false
    @State private var fastLanePendingExportCleanupResult: AppState.FastRuntimePendingExportCleanupResult? = nil
    @State private var isClearingFastRuntimeDrafts: Bool = false
    @State private var fastRuntimeCleanupResult: AppState.FastRuntimePrototypeCleanupResult? = nil
    @State private var showCaptureProfileMaintenanceBackfillConfirm: Bool = false

    private var fastLaneLauncherProperties: [Property] {
        appState.properties
            .filter { $0.deletedAt == nil && !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var buttonFill: Color {
        colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.55)
    }

    private var buttonStroke: Color {
        colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
    }

    private var buttonLabel: Color {
        colorScheme == .light ? Color.black.opacity(0.88) : .white
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Color.clear
                        .frame(width: 76, height: 36)

                    Spacer(minLength: 0)
                    Text("Debug Tools")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(buttonLabel)
                    Spacer(minLength: 0)

                    Button("Done") {
                        dismiss()
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(buttonLabel)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(buttonFill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(buttonStroke, lineWidth: 1)
                    )
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
                .background(Color(uiColor: .systemBackground))

                ScrollView {
                    VStack(spacing: 14) {
                        HStack(spacing: 10) {
                            customCapsuleButton(
                                title: "Archive Export",
                                isEnabled: true,
                                fill: Color.orange.opacity(0.92),
                                stroke: Color.orange.opacity(0.96),
                                label: .white
                            ) {
                                dismiss()
                                onShowMigrationExport()
                            }

                            customCapsuleButton(
                                title: "Archive Import",
                                isEnabled: true,
                                fill: Color.green.opacity(0.88),
                                stroke: Color.green.opacity(0.94),
                                label: .white
                            ) {
                                dismiss()
                                onShowMigrationImport()
                            }
                        }

                        debugActionCard(
                            title: "Local Health / Diagnostics",
                            detail: "Shows in-memory Phase B diagnostics counters for local inspection only. Does NOT read or mutate Supabase, queues, files, exports, or app data.",
                            role: .normal,
                            buttonTitle: "Open Diagnostics"
                        ) {
                            showLocalDiagnosticsSheet = true
                        }

                        debugActionCard(
                            title: "Fast Runtime Prototype",
                            detail: "Runs the lightweight Supabase entry claim with a new in-memory ActiveCaptureContext and temp-only folders. Does NOT set currentSession, call startSession, open camera, create drafts, export, or upload.",
                            role: .normal,
                            buttonTitle: "Open Prototype"
                        ) {
                            showFastRuntimePrototypeSheet = true
                        }

                        fastLaneLauncherCard

                        fastLaneReportPackageDryRunCard

                        debugActionCard(
                            title: "Clear Fast-Lane Drafts",
                            detail: "Deletes only the fast-lane prototype draft index/root and temp prototype folders, then releases any safely identified current-user fast-lane claims. Does NOT touch legacy drafts, sessions, uploads, exports, or normal app data.",
                            role: .destructive,
                            buttonTitle: isClearingFastRuntimeDrafts ? "Clearing..." : "Clear Fast-Lane Drafts"
                        ) {
                            clearFastRuntimeDrafts()
                        }
                        .disabled(isClearingFastRuntimeDrafts)

                        if let fastRuntimeCleanupResult {
                            fastRuntimeCleanupResultBlock(fastRuntimeCleanupResult)
                        }

                        debugActionCard(
                            title: "Nuclear Reset (Local Only)",
                            detail: "Wipes all local app data: properties, sessions, guided, observations, references, and indexes. Does NOT modify iCloud Drive library data.",
                            role: .destructive
                        ) {
                            showNuclearConfirm = true
                        }

                        debugActionCard(
                            title: "Clear Local Index / UI Cache (Local Only)",
                            detail: "Clears in-memory image/UI caches and reloads thumbnails from local SCOUT files. Does NOT delete Originals, Stamped, session.json, or iCloud Drive data.",
                            role: .normal
                        ) {
                            showClearCacheConfirm = true
                        }

                        debugActionCard(
                            title: "Run Legacy Migration Preflight",
                            detail: "Manually runs Step 1 preflight only. Enumerates local legacy candidates, checks current-org eligibility, runs read-only B1 checks, records conservative B2 warnings, and writes the ledger/report. Does NOT mutate Supabase, upload media, or change local records.",
                            role: .normal,
                            buttonTitle: isRunningMigrationPreflight ? "Running Preflight..." : "Run Preflight"
                        ) {
                            guard !isRunningMigrationPreflight else { return }
                            isRunningMigrationPreflight = true
                            migrationPreflightStatusMessage = nil
                            migrationPreflightErrorMessage = nil
                            showMigrationPreflightError = false

                            Task {
                                do {
                                    let result = try await appState.runLegacyMigrationPreflight()
                                    await MainActor.run {
                                        isRunningMigrationPreflight = false
                                        migrationPreflightStatusMessage =
                                            "Preflight complete. Ledger: \(result.ledgerURL.lastPathComponent), Report: \(result.reportURL.lastPathComponent)"
                                    }
                                } catch {
                                    await MainActor.run {
                                        isRunningMigrationPreflight = false
                                        migrationPreflightErrorMessage = error.localizedDescription
                                        showMigrationPreflightError = true
                                    }
                                }
                            }
                        }

                        debugActionCard(
                            title: "Run Legacy Migration Step 2A",
                            detail: "Runs Step 2A mutation. Upserts eligible properties and sessions to Supabase, verifies results, and updates the migration ledger. Does NOT process shots or media.",
                            role: .normal,
                            buttonTitle: isRunningMigrationStep2A ? "Running Step 2A..." : "Run Step 2A"
                        ) {
                            guard !isRunningMigrationStep2A else { return }
                            isRunningMigrationStep2A = true
                            migrationStep2AStatusMessage = nil
                            migrationPreflightErrorMessage = nil
                            showMigrationPreflightError = false

                            Task {
                                do {
                                    let result = try await appState.runLegacyMigrationStep2A()
                                    await MainActor.run {
                                        isRunningMigrationStep2A = false
                                        migrationStep2AStatusMessage =
                                            "Step 2A complete. Verified properties: \(result.verifiedPropertyCount), sessions: \(result.verifiedSessionCount)"
                                    }
                                } catch {
                                    await MainActor.run {
                                        isRunningMigrationStep2A = false
                                        migrationPreflightErrorMessage = error.localizedDescription
                                        showMigrationPreflightError = true
                                    }
                                }
                            }
                        }

                        debugActionCard(
                            title: "Run Legacy Migration Step 2B Slice 1",
                            detail: "Runs Step 2B Slice 1 only. Creates or verifies eligible shot rows in Supabase and updates the migration ledger. Does NOT upload media or finalize storage metadata.",
                            role: .normal,
                            buttonTitle: isRunningMigrationStep2BSlice1 ? "Running Step 2B Slice 1..." : "Run Step 2B Slice 1"
                        ) {
                            guard !isRunningMigrationStep2BSlice1 else { return }
                            isRunningMigrationStep2BSlice1 = true
                            migrationStep2BSlice1StatusMessage = nil
                            migrationPreflightErrorMessage = nil
                            showMigrationPreflightError = false

                            Task {
                                do {
                                    let result = try await appState.runLegacyMigrationStep2BSlice1()
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice1 = false
                                        migrationStep2BSlice1StatusMessage =
                                            "Step 2B Slice 1 complete. Verified shots: \(result.verifiedShotCount)"
                                    }
                                } catch {
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice1 = false
                                        migrationPreflightErrorMessage = error.localizedDescription
                                        showMigrationPreflightError = true
                                    }
                                }
                            }
                        }

                        debugActionCard(
                            title: "Run Legacy Migration Step 2B Slice 2A",
                            detail: "Runs Step 2B Slice 2A only. Validates eligible media entries, recomputes checksum, compares against preflight checksum, derives deterministic storage path, uploads original media to Supabase Storage, and updates the migration ledger. Does NOT finalize shot storage metadata yet.",
                            role: .normal,
                            buttonTitle: isRunningMigrationStep2BSlice2A ? "Running Step 2B Slice 2A..." : "Run Step 2B Slice 2A"
                        ) {
                            guard !isRunningMigrationStep2BSlice2A else { return }
                            isRunningMigrationStep2BSlice2A = true
                            migrationStep2BSlice2AStatusMessage = nil
                            migrationPreflightErrorMessage = nil
                            showMigrationPreflightError = false

                            Task {
                                do {
                                    let result = try await appState.runLegacyMigrationStep2BSlice2A()
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice2A = false
                                        migrationStep2BSlice2AStatusMessage =
                                            "Step 2B Slice 2A complete. Uploaded media entries: \(result.uploadedMediaCount)"
                                    }
                                } catch {
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice2A = false
                                        migrationPreflightErrorMessage = error.localizedDescription
                                        showMigrationPreflightError = true
                                    }
                                }
                            }
                        }

                        debugActionCard(
                            title: "Run Legacy Migration Step 2B Slice 2B Readiness",
                            detail: "Runs Step 2B Slice 2B Readiness only. Performs finalize candidate gating and pre-finalize remote read-back to classify media entries as already verified, ready for finalize, or failed. Does NOT perform finalize write.",
                            role: .normal,
                            buttonTitle: isRunningMigrationStep2BSlice2BReadiness ? "Running Step 2B Slice 2B Readiness..." : "Run Step 2B Slice 2B Readiness"
                        ) {
                            guard !isRunningMigrationStep2BSlice2BReadiness else { return }
                            isRunningMigrationStep2BSlice2BReadiness = true
                            migrationStep2BSlice2BReadinessStatusMessage = nil
                            migrationPreflightErrorMessage = nil
                            showMigrationPreflightError = false

                            Task {
                                do {
                                    let result = try await appState.runLegacyMigrationStep2BSlice2BReadiness()
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice2BReadiness = false
                                        migrationStep2BSlice2BReadinessStatusMessage =
                                            "Step 2B Slice 2B Readiness complete. Verified media: \(result.verifiedMediaCount), ready for finalize: \(result.readyForFinalizeCount)"
                                    }
                                } catch {
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice2BReadiness = false
                                        migrationPreflightErrorMessage = error.localizedDescription
                                        showMigrationPreflightError = true
                                    }
                                }
                            }
                        }

                        debugActionCard(
                            title: "Run Legacy Migration Step 2B Slice 2B Finalize",
                            detail: "Runs Step 2B Slice 2B Finalize. Writes storage metadata to Supabase for ready media entries, performs strict read-back verification, and marks entries verified.",
                            role: .normal,
                            buttonTitle: isRunningMigrationStep2BSlice2BFinalize ? "Running Step 2B Slice 2B Finalize..." : "Run Step 2B Slice 2B Finalize"
                        ) {
                            guard !isRunningMigrationStep2BSlice2BFinalize else { return }
                            isRunningMigrationStep2BSlice2BFinalize = true
                            migrationStep2BSlice2BFinalizeStatusMessage = nil
                            migrationPreflightErrorMessage = nil
                            showMigrationPreflightError = false

                            Task {
                                do {
                                    let result = try await appState.runLegacyMigrationStep2BSlice2BFinalize()
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice2BFinalize = false
                                        migrationStep2BSlice2BFinalizeStatusMessage =
                                            "Step 2B Slice 2B Finalize complete. Verified media entries: \(result.verifiedMediaCount)"
                                    }
                                } catch {
                                    await MainActor.run {
                                        isRunningMigrationStep2BSlice2BFinalize = false
                                        migrationPreflightErrorMessage = error.localizedDescription
                                        showMigrationPreflightError = true
                                    }
                                }
                            }
                        }

                        debugActionCard(
                            title: "Open Last Preflight Report",
                            detail: "Loads the current summary-report.txt written by Step 1 preflight and displays it in-app. Does NOT rerun preflight or change any data.",
                            role: .normal,
                            buttonTitle: "Open Last Preflight Report"
                        ) {
                            let reportURL = localStore
                                .legacyMigrationPreflightDirectoryURL()
                                .appendingPathComponent("summary-report.txt", isDirectory: false)

                            guard FileManager.default.fileExists(atPath: reportURL.path) else {
                                migrationPreflightErrorMessage = "Preflight report not found at: \(reportURL.path)"
                                showMigrationPreflightError = true
                                return
                            }

                            do {
                                preflightReportText = try String(contentsOf: reportURL, encoding: .utf8)
                                showPreflightReportSheet = true
                            } catch {
                                migrationPreflightErrorMessage = "Unable to open preflight report: \(error.localizedDescription)"
                                showMigrationPreflightError = true
                            }
                        }

                        debugActionCard(
                            title: "Repair Local Property Org",
                            detail: "Lists only local properties whose orgId does not match the current active organization and lets you manually select specific properties to reassign locally. Does NOT touch Supabase or upload anything.",
                            role: .normal,
                            buttonTitle: "Open Org Repair"
                        ) {
                            showLocalOrgRepairSheet = true
                        }

                        debugActionCard(
                            title: "Backfill Capture Profiles",
                            detail: "Owner/manager maintenance action. Scans local active-org properties and sessions, fills only missing Supabase capture_profile values, and ensures missing remote session rows when a local session snapshot exists. Does NOT overwrite non-null Supabase values.",
                            role: .normal,
                            buttonTitle: isRunningCaptureProfileMaintenanceBackfill ? "Running Backfill..." : "Run Backfill"
                        ) {
                            guard !isRunningCaptureProfileMaintenanceBackfill else { return }
                            guard appState.canRecoverDeletedPropertiesInActiveOrganization else {
                                migrationPreflightErrorMessage = "Only organization owners and managers can run capture profile backfill."
                                showMigrationPreflightError = true
                                return
                            }
                            showCaptureProfileMaintenanceBackfillConfirm = true
                        }

                        debugActionCard(
                            title: "Run Foreground Property Refresh",
                            detail: "Manually runs AppState.refreshProperties() so the new foreground remote property-list path can be tested directly without changing the normal hub startup flow.",
                            role: .normal,
                            buttonTitle: isRunningForegroundPropertyRefresh ? "Running Foreground Property Refresh..." : "Run Foreground Property Refresh"
                        ) {
                            guard !isRunningForegroundPropertyRefresh else { return }
                            isRunningForegroundPropertyRefresh = true
                            foregroundPropertyRefreshStatusMessage = nil
                            Task { @MainActor in
                                appState.refreshProperties()
                                isRunningForegroundPropertyRefresh = false
                                foregroundPropertyRefreshStatusMessage = "Foreground property refresh triggered."
                            }
                        }

                        if let migrationPreflightStatusMessage {
                            Text(migrationPreflightStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let migrationStep2AStatusMessage {
                            Text(migrationStep2AStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let migrationStep2BSlice1StatusMessage {
                            Text(migrationStep2BSlice1StatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let migrationStep2BSlice2AStatusMessage {
                            Text(migrationStep2BSlice2AStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let migrationStep2BSlice2BReadinessStatusMessage {
                            Text(migrationStep2BSlice2BReadinessStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let migrationStep2BSlice2BFinalizeStatusMessage {
                            Text(migrationStep2BSlice2BFinalizeStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let captureProfileMaintenanceBackfillStatusMessage {
                            Text(captureProfileMaintenanceBackfillStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let foregroundPropertyRefreshStatusMessage {
                            Text(foregroundPropertyRefreshStatusMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        debugActionCard(
                            title: "Print Metadata Schema",
                            detail: "Prints SessionMetadata and ShotMetadata field names to the Xcode console.",
                            role: .normal,
                            buttonTitle: "Print Metadata Schema"
                        ) {
                            localStore.printSessionSchema()
                        }

                        debugActionCard(
                            title: "Verify session.json source",
                            detail: "Prints on-disk session.json path, existence, size, schemaVersion, shot count, and shotKey/originalRelativePath presence.",
                            role: .normal,
                            buttonTitle: "Verify session.json source"
                        ) {
                            verifySessionJSONSource()
                        }

                        debugActionCard(
                            title: "Verify export session.json source",
                            detail: "Prints export session.json source path and key presence checks used by export.",
                            role: .normal,
                            buttonTitle: "Verify export source"
                        ) {
                            verifyExportSessionJSONSource()
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onAppear {
            if selectedFastLaneLauncherPropertyID == nil {
                selectedFastLaneLauncherPropertyID = fastLaneLauncherProperties.first?.id
            }
        }
        .alert("Nuclear Reset (Local Only)?", isPresented: $showNuclearConfirm) {
            Button("Reset", role: .destructive) {
                appState.nuclearResetLocalOnly()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently erase all local app data and cannot be recovered. iCloud Drive library data will not be touched.")
        }
        .alert("Clear Local Index / UI Cache?", isPresented: $showClearCacheConfirm) {
            Button("Clear") {
                appState.clearLocalCacheOnly()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears local UI/image cache only and reloads from local SCOUT storage. It does not delete Originals, Stamped, session.json, or iCloud Drive data.")
        }
        .alert("Backfill Capture Profiles?", isPresented: $showCaptureProfileMaintenanceBackfillConfirm) {
            Button("Run Backfill") {
                guard !isRunningCaptureProfileMaintenanceBackfill else { return }
                isRunningCaptureProfileMaintenanceBackfill = true
                captureProfileMaintenanceBackfillStatusMessage = nil
                Task {
                    let result = await appState.runCaptureProfileMaintenanceBackfill()
                    await MainActor.run {
                        isRunningCaptureProfileMaintenanceBackfill = false
                        captureProfileMaintenanceBackfillStatusMessage =
                            "Capture profile backfill complete. Scanned properties: \(result.propertiesScanned)/\(result.localPropertiesFound), sessions: \(result.sessionsScanned), remote checks: \(result.remotePropertiesChecked) properties / \(result.remoteSessionsChecked) sessions. Remote active properties: \(result.remoteActivePropertyCount), stale org reconciled: \(result.staleOrgReconciledCount), true org mismatches: \(result.trueOrgMismatchCount). Filled: \(result.propertyProfilesFilled) properties, \(result.sessionProfilesFilled) sessions. Ensured sessions: \(result.sessionsEnsured). Skipped: \(result.skipped), failed: \(result.failed). \(captureProfileBackfillSummaryHint(for: result))"
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This fills only missing Supabase capture_profile values for the active organization. Existing non-null Supabase values are preserved.")
        }
        .alert("Migration Preflight Failed", isPresented: $showMigrationPreflightError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(migrationPreflightErrorMessage ?? "Unable to run legacy migration preflight.")
        }
        .sheet(isPresented: $showPreflightReportSheet) {
            NavigationStack {
                ScrollView {
                    Text(preflightReportText)
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .navigationTitle("Preflight Report")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showPreflightReportSheet = false
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showLocalOrgRepairSheet) {
            DebugLocalOrgRepairView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showLocalDiagnosticsSheet) {
            DebugLocalDiagnosticsView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showFastRuntimePrototypeSheet) {
            DebugFastRuntimePrototypeView()
                .environmentObject(appState)
        }
        .sheet(item: $fastLaneReportDryRunResult) { result in
            FastRuntimeReportPackageDryRunResultView(result: result)
        }
        .sheet(item: $fastLaneReportHandoffResult) { result in
            FastRuntimeReportHandoffResultView(result: result)
        }
        .fullScreenCover(item: $fastLaneLauncherPreviewRequest) { request in
            DebugFastRuntimePrototypeCameraPreviewView(
                context: request.context,
                propertyName: request.propertyName,
                prototypeResult: request.result,
                buttonTappedAt: request.buttonTappedAt,
                contextReadyAt: request.contextReadyAt,
                previewRequestedAt: request.previewRequestedAt,
                    initialCapturedCount: request.initialCapturedCount,
                    storageRoot: request.storageRoot,
                    isDraftResume: request.isDraftResume,
                    initialLocationMode: request.initialLocationMode,
                    initialMetadataContext: request.initialMetadataContext,
                    isDebugMode: true,
                onDismiss: { closeResult in
                    fastLaneLauncherCloseResult = closeResult
                    fastLaneLauncherPreviewRequest = nil
                }
            )
            .environmentObject(appState)
            .interactiveDismissDisabled(true)
        }
    }

    private var fastLaneReportPackageDryRunCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fast Report Package Dry Run")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text("Debug-only read from completed fast-lane pending-export rows. Builds in-memory session snapshot, report package, file, and worker/email candidates. It does not insert snapshots, create packages, dispatch workers, email, upload, or change property state.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            if fastLaneLauncherProperties.isEmpty {
                Text("No active properties loaded.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                Picker("Property", selection: $selectedFastLaneLauncherPropertyID) {
                    ForEach(fastLaneLauncherProperties) { property in
                        Text(property.name)
                            .tag(Optional(property.id))
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 10) {
                customCapsuleButton(
                    title: isRunningFastLaneReportDryRun ? "Checking..." : "Report Dry Run Full",
                    isEnabled: !isRunningFastLaneReportDryRun && !isRunningFastLaneReportHandoff && !isMarkingFastLanePendingExportDelivered && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.green.opacity(0.78),
                    stroke: Color.green.opacity(0.90),
                    label: .white
                ) {
                    runFastLaneReportPackageDryRun(sessionType: .fullDocumentation)
                }

                customCapsuleButton(
                    title: isRunningFastLaneReportDryRun ? "Checking..." : "Report Dry Run Punch",
                    isEnabled: !isRunningFastLaneReportDryRun && !isRunningFastLaneReportHandoff && !isMarkingFastLanePendingExportDelivered && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.indigo.opacity(0.78),
                    stroke: Color.indigo.opacity(0.90),
                    label: .white
                ) {
                    runFastLaneReportPackageDryRun(sessionType: .punchlistVisit)
                }
            }

            HStack(spacing: 10) {
                customCapsuleButton(
                    title: isRunningFastLaneReportHandoff ? "Handing Off..." : "Fast Report Handoff Full",
                    isEnabled: !isRunningFastLaneReportDryRun && !isRunningFastLaneReportHandoff && !isMarkingFastLanePendingExportDelivered && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.teal.opacity(0.80),
                    stroke: Color.teal.opacity(0.92),
                    label: .white
                ) {
                    runFastLaneReportHandoff(sessionType: .fullDocumentation)
                }

                customCapsuleButton(
                    title: isRunningFastLaneReportHandoff ? "Handing Off..." : "Fast Report Handoff Punch",
                    isEnabled: !isRunningFastLaneReportDryRun && !isRunningFastLaneReportHandoff && !isMarkingFastLanePendingExportDelivered && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.cyan.opacity(0.78),
                    stroke: Color.cyan.opacity(0.90),
                    label: .white
                ) {
                    runFastLaneReportHandoff(sessionType: .punchlistVisit)
                }
            }

            Text("Debug cleanup below marks a completed fast-lane pending-export test row delivered/exported after a valid dry run and readable report/package side effects. It does not delete sessions, shots, storage, reports, packages, or email records.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                customCapsuleButton(
                    title: isMarkingFastLanePendingExportDelivered ? "Marking..." : "Mark Delivered Full",
                    isEnabled: !isRunningFastLaneReportDryRun && !isRunningFastLaneReportHandoff && !isMarkingFastLanePendingExportDelivered && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.orange.opacity(0.78),
                    stroke: Color.orange.opacity(0.90),
                    label: .white
                ) {
                    markFastLanePendingExportDelivered(sessionType: .fullDocumentation)
                }

                customCapsuleButton(
                    title: isMarkingFastLanePendingExportDelivered ? "Marking..." : "Mark Delivered Punch",
                    isEnabled: !isRunningFastLaneReportDryRun && !isRunningFastLaneReportHandoff && !isMarkingFastLanePendingExportDelivered && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.orange.opacity(0.68),
                    stroke: Color.orange.opacity(0.84),
                    label: .white
                ) {
                    markFastLanePendingExportDelivered(sessionType: .punchlistVisit)
                }
            }

            if let result = fastLaneReportDryRunResult {
                fastLaneReportPackageDryRunResultBlock(result)
            }

            if let result = fastLaneReportHandoffResult {
                fastLaneReportHandoffResultBlock(result)
            }

            if let result = fastLanePendingExportCleanupResult {
                fastLanePendingExportCleanupResultBlock(result)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var fastLaneLauncherCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start Fast-Lane Session")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text("Debug-only launcher for clean fast-lane upload testing. Uses the lightweight RPC gate and opens the fast preview directly only on unlocked_and_claimed. It does not call openProperty, startSession, currentSession, or legacy camera routing.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)

            if fastLaneLauncherProperties.isEmpty {
                Text("No active properties loaded.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                Picker("Property", selection: $selectedFastLaneLauncherPropertyID) {
                    ForEach(fastLaneLauncherProperties) { property in
                        Text(property.name)
                            .tag(Optional(property.id))
                    }
                }
                .pickerStyle(.menu)
            }

            HStack(spacing: 10) {
                customCapsuleButton(
                    title: isStartingFastLaneSession ? "Starting..." : "Start Fast-Lane Full",
                    isEnabled: !isStartingFastLaneSession && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.blue.opacity(0.86),
                    stroke: Color.blue.opacity(0.92),
                    label: .white
                ) {
                    startFastLaneLauncher(sessionType: .fullDocumentation)
                }

                customCapsuleButton(
                    title: isStartingFastLaneSession ? "Starting..." : "Start Fast-Lane Punch",
                    isEnabled: !isStartingFastLaneSession && selectedFastLaneLauncherPropertyID != nil,
                    fill: Color.purple.opacity(0.78),
                    stroke: Color.purple.opacity(0.90),
                    label: .white
                ) {
                    startFastLaneLauncher(sessionType: .punchlistVisit)
                }
            }

            customCapsuleButton(
                title: isClearingFastRuntimeDrafts ? "Clearing..." : "Release/Clear Fast-Lane State",
                isEnabled: !isClearingFastRuntimeDrafts,
                fill: Color.red.opacity(0.86),
                stroke: Color.red.opacity(0.90),
                label: .white
            ) {
                clearFastRuntimeDrafts()
            }

            if let fastLaneLauncherResult {
                fastLaneLauncherResultBlock(fastLaneLauncherResult)
            }

            if let fastLaneLauncherCloseResult {
                fastLaneLauncherCloseResultBlock(fastLaneLauncherCloseResult)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func runFastLaneReportPackageDryRun(sessionType: SessionType) {
        guard !isRunningFastLaneReportDryRun,
              let propertyID = selectedFastLaneLauncherPropertyID else {
            return
        }
        isRunningFastLaneReportDryRun = true
        fastLaneReportDryRunResult = nil
        fastLanePendingExportCleanupResult = nil
        Task {
            let result = await appState.runFastRuntimeReportPackageDryRun(
                propertyID: propertyID,
                sessionType: sessionType
            )
            await MainActor.run {
                fastLaneReportDryRunResult = result
                isRunningFastLaneReportDryRun = false
            }
        }
    }

    private func runFastLaneReportHandoff(sessionType: SessionType) {
        guard !isRunningFastLaneReportHandoff,
              let propertyID = selectedFastLaneLauncherPropertyID else {
            return
        }
        isRunningFastLaneReportHandoff = true
        fastLaneReportDryRunResult = nil
        fastLaneReportHandoffResult = nil
        fastLanePendingExportCleanupResult = nil
        Task {
            let result = await appState.runFastRuntimeReportHandoff(
                propertyID: propertyID,
                sessionType: sessionType
            )
            await MainActor.run {
                fastLaneReportDryRunResult = result.dryRun
                fastLaneReportHandoffResult = result
                isRunningFastLaneReportHandoff = false
            }
        }
    }

    private func markFastLanePendingExportDelivered(sessionType: SessionType) {
        guard !isMarkingFastLanePendingExportDelivered,
              let propertyID = selectedFastLaneLauncherPropertyID else {
            return
        }
        isMarkingFastLanePendingExportDelivered = true
        fastLaneReportDryRunResult = nil
        fastLanePendingExportCleanupResult = nil
        Task {
            let result = await appState.runFastRuntimeDebugMarkPendingExportDelivered(
                propertyID: propertyID,
                sessionType: sessionType
            )
            await MainActor.run {
                fastLaneReportDryRunResult = result.dryRun
                fastLanePendingExportCleanupResult = result
                isMarkingFastLanePendingExportDelivered = false
            }
        }
    }

    private func startFastLaneLauncher(sessionType: SessionType) {
        guard !isStartingFastLaneSession,
              let propertyID = selectedFastLaneLauncherPropertyID,
              let property = fastLaneLauncherProperties.first(where: { $0.id == propertyID }) else {
            return
        }
        isStartingFastLaneSession = true
        fastLaneLauncherResult = nil
        fastLaneLauncherCloseResult = nil
        let buttonTappedAt = Date()
        Task {
            let result = await appState.runFastRuntimePrototype(
                propertyID: propertyID,
                sessionType: sessionType,
                prepareTempStorage: true,
                releaseClaim: false,
                allowCurrentUserOccupiedContext: false
            )
            let contextReadyAt = Date()
            await MainActor.run {
                fastLaneLauncherResult = result
                isStartingFastLaneSession = false
                guard result.entryState == .unlockedAndClaimed,
                      result.requiresFallback == false,
                      result.contextSource == "unlocked_and_claimed",
                      let context = result.context,
                      context.propertyID == propertyID,
                      context.sessionID == result.timings.targetSessionID,
                      context.sessionType == sessionType,
                      context.canCapture else {
                    return
                }
                fastLaneLauncherPreviewRequest = FastRuntimeCameraPreviewRequest(
                    context: context,
                    propertyName: property.name,
                    result: result,
                    buttonTappedAt: buttonTappedAt,
                    contextReadyAt: contextReadyAt,
                    previewRequestedAt: Date(),
                    initialCapturedCount: 0,
                    storageRoot: result.tempStorageRoot,
                    isDraftResume: false,
                    initialLocationMode: .exterior,
                    initialMetadataContext: nil
                )
            }
        }
    }

    private func clearFastRuntimeDrafts() {
        guard !isClearingFastRuntimeDrafts else { return }
        isClearingFastRuntimeDrafts = true
        fastRuntimeCleanupResult = nil
        Task {
            let result = await appState.clearFastRuntimePrototypeState()
            await MainActor.run {
                fastRuntimeCleanupResult = result
                isClearingFastRuntimeDrafts = false
            }
        }
    }

    private func fastLaneReportPackageDryRunResultBlock(
        _ result: AppState.FastRuntimeReportPackageDryRunResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Report Package Dry Run")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(buttonLabel)
            Text([
                "valid=\(result.isValid)",
                "session_type=\(result.sessionType.rawValue)",
                "session=\(result.sessionID?.uuidString ?? "missing")",
                "shots=\(result.shotCount)",
                "storage=\(result.storageObjectCount)",
                "report_mode=\(result.reportMode)",
                "total=\(String(format: "%.1f", result.totalMilliseconds))ms"
            ].joined(separator: "\n"))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(buttonLabel.opacity(0.80))
            .textSelection(.enabled)

            if !result.errors.isEmpty {
                Text(result.errors.joined(separator: "\n"))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(buttonFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(buttonStroke, lineWidth: 1)
        )
    }

    private func fastLaneReportHandoffResultBlock(
        _ result: AppState.FastRuntimeReportHandoffResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fast Report Handoff")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(buttonLabel)
            Text([
                "success=\(result.success)",
                "status=\(result.functionStatus)",
                "session_type=\(result.sessionType.rawValue)",
                "session=\(result.sessionID?.uuidString ?? "missing")",
                "snapshot=\(result.snapshotID?.uuidString ?? "missing")",
                "dispatch=\(result.dispatchStatus ?? "unknown")",
                "total=\(String(format: "%.1f", result.totalMilliseconds))ms"
            ].joined(separator: "\n"))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(buttonLabel.opacity(0.80))
            .textSelection(.enabled)

            if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(buttonFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(buttonStroke, lineWidth: 1)
        )
    }

    private func fastLanePendingExportCleanupResultBlock(
        _ result: AppState.FastRuntimePendingExportCleanupResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(result.success ? "Pending Export Cleanup Complete" : "Pending Export Cleanup Failed")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(result.success ? .green : .orange)
            Text([
                "success=\(result.success)",
                "session_type=\(result.dryRun.sessionType.rawValue)",
                "session=\(result.sessionID?.uuidString ?? "missing")",
                "property_status=\(result.propertyStatus ?? "missing")",
                "total=\(String(format: "%.1f", result.totalMilliseconds))ms"
            ].joined(separator: "\n"))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(buttonLabel.opacity(0.80))
            .textSelection(.enabled)

            if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(buttonFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(buttonStroke, lineWidth: 1)
        )
    }

    private func fastLaneLauncherResultBlock(
        _ result: AppState.FastRuntimePrototypeResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fast-Lane Launcher Result")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(buttonLabel)
            Text([
                "property=\(result.propertyName)",
                "session_type=\(result.sessionType.rawValue)",
                "entry_state=\(result.entryState?.rawValue ?? "none")",
                "fallback=\(result.requiresFallback)",
                "context=\(result.context == nil ? "none" : result.contextSource)",
                "total=\(String(format: "%.1f", result.timings.totalMilliseconds))ms"
            ].joined(separator: "\n"))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(buttonLabel.opacity(0.80))
            .textSelection(.enabled)

            if let reason = result.reason {
                Text(reason)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(buttonLabel.opacity(0.70))
                    .textSelection(.enabled)
            }

            if result.entryState != .unlockedAndClaimed || result.requiresFallback || result.context == nil {
                Text("Fast-lane preview did not open. Use Release/Clear Fast-Lane State above if this is a stale current-user claim, then retry. No legacy path was opened.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(buttonFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(buttonStroke, lineWidth: 1)
        )
    }

    private func fastLaneLauncherCloseResultBlock(
        _ result: AppState.FastRuntimePrototypeCloseResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fast-Lane Close Result")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(buttonLabel)
            Text([
                "property=\(result.propertyName)",
                "session=\(result.sessionID.uuidString)",
                "draft=\(result.draftPersisted)",
                "photos=\(result.photoCount)",
                "lock=\(result.lockAction)",
                "total=\(String(format: "%.1f", result.timings.totalMilliseconds))ms"
            ].joined(separator: "\n"))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(buttonLabel.opacity(0.80))
            .textSelection(.enabled)
            if let error = result.errorMessage {
                Text(error)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundColor(buttonLabel.opacity(0.70))
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(buttonFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(buttonStroke, lineWidth: 1)
        )
    }

    private func fastRuntimeCleanupResultBlock(
        _ result: AppState.FastRuntimePrototypeCleanupResult
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Fast-Lane Cleanup Result")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(buttonLabel)
            Text(result.summary)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(buttonLabel.opacity(0.80))
                .textSelection(.enabled)
            if !result.claimReleaseMessages.isEmpty {
                Text(result.claimReleaseMessages.joined(separator: "\n"))
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(buttonLabel.opacity(0.70))
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(buttonFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(buttonStroke, lineWidth: 1)
        )
    }

    private func captureProfileBackfillSummaryHint(
        for result: AppState.CaptureProfileMaintenanceBackfillResult
    ) -> String {
        if result.localPropertiesFound == 0 {
            return "No local properties were found."
        }
        if result.propertiesScanned == 0 {
            return "No properties were eligible after org/deleted/archive/access filters."
        }
        if result.sessionsScanned == 0 {
            return "No local sessions were found for eligible properties."
        }
        if result.propertyProfilesFilled == 0 &&
            result.sessionProfilesFilled == 0 &&
            result.failed == 0 {
            return "Nothing needed backfill or local profile values were unknown."
        }
        return ""
    }

    private enum DebugRole {
        case normal
        case destructive
    }

    @ViewBuilder
    private func debugActionCard(
        title: String,
        detail: String,
        role: DebugRole,
        buttonTitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let fill = role == .destructive ? Color.red.opacity(0.86) : buttonFill
        let stroke = role == .destructive ? Color.red.opacity(0.90) : buttonStroke
        let label = role == .destructive ? Color.white : buttonLabel
        let resolvedButtonTitle = buttonTitle ?? (role == .destructive ? "Run Nuclear Reset" : "Clear Cache")

        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            customCapsuleButton(
                title: resolvedButtonTitle,
                isEnabled: true,
                fill: fill,
                stroke: stroke,
                label: label,
                action: action
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func customCapsuleButton(
        title: String,
        isEnabled: Bool,
        fill: Color? = nil,
        stroke: Color? = nil,
        label: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let resolvedFill = fill ?? buttonFill
        let resolvedStroke = stroke ?? buttonStroke
        let resolvedLabel = label ?? buttonLabel

        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(isEnabled ? resolvedLabel : resolvedLabel.opacity(0.45))
                .frame(minHeight: 38)
                .padding(.horizontal, 12)
                .background(resolvedFill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(resolvedStroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private func verifySessionJSONSource() {
        guard let propertyID = appState.selectedPropertyID,
              let sessionID = appState.currentSession?.id else {
            print("Verify session.json source: missing selected property or current session.")
            return
        }

        let url = localStore.sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let sizeBytes: Int = {
            guard exists,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.intValue
        }()

        print("Expected session.json path: \(url.path)")
        print("File exists: \(exists ? "YES" : "NO")")
        print("File size bytes: \(sizeBytes)")

        guard exists, let data = try? Data(contentsOf: url) else {
            print("Unable to read session.json data.")
            return
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        print("Raw contains \"\\\"shotKey\\\"\": \(raw.contains("\"shotKey\"") ? "YES" : "NO")")
        print("Raw contains \"\\\"originalRelativePath\\\"\": \(raw.contains("\"originalRelativePath\"") ? "YES" : "NO")")

        do {
            let metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            print("schemaVersion: \(metadata.schemaVersion)")
            print("shots count: \(metadata.shots.count)")
            if let first = metadata.shots.first {
                print("first shot shotKey: \(first.shotKey)")
                print("first shot originalRelativePath: \(first.originalRelativePath)")
            }
        } catch {
            print("Decode failed: \(error)")
        }
    }

    private func verifyExportSessionJSONSource() {
        guard let propertyID = appState.selectedPropertyID,
              let sessionID = appState.currentSession?.id else {
            print("Verify export session.json source: missing selected property or current session.")
            return
        }

        let url = localStore.sessionJSONURL(propertyID: propertyID, sessionID: sessionID)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let sizeBytes: Int = {
            guard exists,
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.intValue
        }()
        print("Export session.json path source: \(url.path)")
        print("Export source exists: \(exists ? "YES" : "NO")")
        print("Export source size bytes: \(sizeBytes)")

        guard exists, let data = try? Data(contentsOf: url) else {
            print("Export source read failed.")
            return
        }

        let raw = String(data: data, encoding: .utf8) ?? ""
        print("Export raw contains \"shotKey\": \(raw.contains("\"shotKey\"") ? "YES" : "NO")")
        print("Export raw contains \"originalRelativePath\": \(raw.contains("\"originalRelativePath\"") ? "YES" : "NO")")

        do {
            let metadata = try localStore.loadSessionMetadata(propertyID: propertyID, sessionID: sessionID)
            if let first = metadata.shots.first {
                print("Export first shot shotKey: \(first.shotKey)")
                print("Export first shot originalRelativePath: \(first.originalRelativePath)")
            } else {
                print("Export first shot: none")
            }
        } catch {
            print("Export source decode failed: \(error)")
        }
    }
}

struct PropertySessionView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let propertyID: UUID
    let resumeDraft: Bool
    let initialSessionType: SessionType?
    let onPendingExportRecovered: (Property, Session) -> Void

    @State private var didSetup: Bool = false
    @State private var showCameraContent: Bool = false
    @State private var showOpenCameraTimeout: Bool = false
    @State private var didStartOpenFlow: Bool = false
    @State private var openFlowToken: Int = 0
    @State private var hasSessionReadyForProperty: Bool = false
    @State private var isCheckingSessionBeforeOpen: Bool = true
    @State private var isCheckingSessionCoordination: Bool = false
    @State private var isAwaitingInitialSessionTypeSelection: Bool = false
    @State private var sessionEntryBlock: AppState.SessionEntryCoordinationBlock? = nil
    @State private var didSchedulePostOpenReferenceReconcile: Bool = false
    @State private var isVerifyingSessionAfterPresentation: Bool = false
    @State private var didUseLightweightFastEntry: Bool = false

    private let camera = CameraManager.shared
    private let timeoutSeconds: Double = 4.0

    var body: some View {
        ZStack {
            if showCameraContent {
                ContentView(onExitToHub: {
                    exitCaptureScreen()
                })
                .transition(.opacity)
                if isVerifyingSessionAfterPresentation {
                    sessionVerificationOverlay
                        .transition(.opacity)
                }
            } else {
                openingCameraInterstitial
                    .transition(.opacity)
            }
        }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $isAwaitingInitialSessionTypeSelection) {
                InitialSessionTypeChoiceSheet(
                    onChoose: { sessionType in
                        isAwaitingInitialSessionTypeSelection = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            guard appState.persistCurrentSessionType(sessionType) != nil else { return }
                            beginOpenFlow(forceRetry: true)
                        }
                    },
                    onBack: {
                        isAwaitingInitialSessionTypeSelection = false
                        exitCaptureScreen()
                    }
                )
                .interactiveDismissDisabled(true)
                .presentationDetents([.height(330)])
            }
            .onReceive(camera.$isPreviewRunning.removeDuplicates()) { isRunning in
                if isRunning && didStartOpenFlow && hasSessionReadyForProperty {
                    completeOpenFlow()
                }
            }
            .onAppear {
                guard !didSetup else { return }
                didSetup = true
                appState.selectProperty(id: propertyID)
                Task { @MainActor in
                    await runPropertyEntryFlow()
                }
            }
            .onChange(of: appState.currentSession?.id) { _, _ in
                refreshSessionReadiness()
                if sessionEntryBlock == nil && camera.isPreviewRunning && didStartOpenFlow && hasSessionReadyForProperty {
                    completeOpenFlow()
                }
            }
            .onChange(of: appState.activeSessionAccessRevocationRequest?.id) { _, newValue in
                guard let newValue,
                      let request = appState.activeSessionAccessRevocationRequest,
                      request.id == newValue,
                      request.propertyID == propertyID else {
                    return
                }
                appState.finalizeActiveSessionAccessRevocationIfNeeded(
                    requestID: request.id,
                    propertyID: request.propertyID
                )
                exitCaptureScreen()
        }
    }

    @MainActor
    private func runPropertyEntryFlow() async {
        let targetSessionID = appState.preferredPropertyEntrySessionID(for: propertyID)
        let lightweightStatus = await appState.evaluateLightweightPropertyEntryStatus(
            propertyID: propertyID,
            targetSessionID: targetSessionID
        )

        guard let lightweightStatus,
              !lightweightStatus.requiresFallback,
              lightweightStatus.entryState != .unknownRequiresFallback else {
            await runLegacyCheckingSession(reason: "lightweight_rpc_fallback")
            return
        }

        switch lightweightStatus.entryState {
        case .unlockedAndClaimed:
            let session = appState.startSession(
                sessionType: initialSessionType ?? .fullDocumentation,
                skipPropertyStatusPreflight: true,
                preferredNewSessionID: targetSessionID
            )
            guard session?.id == targetSessionID else {
                await runLegacyCheckingSession(reason: "lightweight_session_mismatch")
                return
            }
            finishAllowedFastEntry(deferInitialSessionTypePersistence: true)

        case .lockedByCurrentUser:
            let desiredSessionID = lightweightStatus.lockSessionID ?? targetSessionID
            let loadedSession: Session?
            if appState.currentSession?.propertyID == propertyID,
               appState.currentSession?.id == desiredSessionID,
               appState.currentSession?.status == .draft {
                loadedSession = appState.currentSession
            } else {
                loadedSession = appState.loadDraftSession(
                    for: propertyID,
                    skipPropertyStatusPreflight: true
                )
            }
            if loadedSession?.id != desiredSessionID {
                guard appState.canRebuildMissingLocalShellFromLightweightCurrentUserLock(
                    lightweightStatus,
                    propertyID: propertyID
                ) else {
                    await runLegacyCheckingSession(reason: "lightweight_current_user_lock_missing_local_draft")
                    return
                }
                let rebuiltSession = appState.rebuildLightweightCurrentUserSessionShell(
                    propertyID: propertyID,
                    sessionID: desiredSessionID,
                    sessionType: initialSessionType ?? .fullDocumentation
                )
                guard rebuiltSession?.id == desiredSessionID else {
                    await runLegacyCheckingSession(reason: "lightweight_current_user_lock_rebuild_failed")
                    return
                }
            }
            finishAllowedFastEntry(deferInitialSessionTypePersistence: true)

        case .lockedByOtherUser, .pendingExport:
            guard let block = appState.sessionEntryBlock(for: lightweightStatus) else {
                await runLegacyCheckingSession(reason: "lightweight_block_mapping_missing")
                return
            }
            isCheckingSessionBeforeOpen = false
            sessionEntryBlock = block

        case .staleClaimable:
            _ = appState.startSession(
                skipPropertyStatusPreflight: true,
                preferredNewSessionID: targetSessionID
            )
            refreshSessionReadiness()
            guard appState.currentSession?.id == targetSessionID,
                  let block = appState.sessionEntryBlock(for: lightweightStatus) else {
                await runLegacyCheckingSession(reason: "lightweight_stale_claimable_session_missing")
                return
            }
            isCheckingSessionBeforeOpen = false
            sessionEntryBlock = block

        case .unknownRequiresFallback:
            await runLegacyCheckingSession(reason: "lightweight_unknown_requires_fallback")
        }
    }

    @MainActor
    private func runLegacyCheckingSession(reason _: String) async {
        let propertyStatusPreflight = await appState.evaluateFreshPropertyStatusEntryPreflight(
            propertyID: propertyID,
            context: "property_session_view"
        )
        if let block = propertyStatusPreflight.decision?.block {
            isCheckingSessionBeforeOpen = false
            sessionEntryBlock = block
            return
        }
        let skipCachedPropertyStatusPreflight = propertyStatusPreflight.skipCachedPropertyStatusPreflight
        if resumeDraft {
            if appState.currentSession?.propertyID != propertyID || appState.currentSession?.status != .draft {
                _ = appState.loadDraftSession(
                    for: propertyID,
                    skipPropertyStatusPreflight: skipCachedPropertyStatusPreflight
                )
            }
        } else {
            _ = appState.startSession(
                skipPropertyStatusPreflight: skipCachedPropertyStatusPreflight
            )
        }
        refreshSessionReadiness()
        isCheckingSessionBeforeOpen = false
        if appState.canFastPresentCurrentMaterialDraftResume(propertyID: propertyID) {
            beginOpenFlow(forceRetry: true)
            beginSessionCoordinationFlow(openAfterAllowed: false)
        } else {
            beginSessionCoordinationFlow()
        }
    }

    @MainActor
    private func finishAllowedFastEntry(deferInitialSessionTypePersistence: Bool = false) {
        didUseLightweightFastEntry = deferInitialSessionTypePersistence
        refreshSessionReadiness()
        isCheckingSessionBeforeOpen = false
        if appState.canFastPresentCurrentMaterialDraftResume(propertyID: propertyID) {
            beginOpenFlow(forceRetry: true)
        } else {
            continueAfterSessionCoordinationAllowed()
        }
    }

    @ViewBuilder
    private var sessionVerificationOverlay: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                Text("Checking Session")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .background(Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private var openingCameraInterstitial: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 14) {
                if showOpenCameraTimeout {
                    Text("Unable to open camera")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text("Please try again or go back.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.86))

                    HStack(spacing: 10) {
                        Button {
                            beginOpenFlow(forceRetry: true)
                        } label: {
                            Text("Retry")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            exitCaptureScreen()
                        } label: {
                            Text("Back")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                } else if let sessionEntryBlock {
                    Text("Session Locked")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text(lockMessage(for: sessionEntryBlock))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.86))
                        .multilineTextAlignment(.center)

                    HStack(spacing: 10) {
                        Button {
                            claimBlockedSession()
                        } label: {
                            Text(isCheckingSessionCoordination ? "Claiming..." : "Claim Session")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.blue)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isCheckingSessionCoordination)

                        Button {
                            Task {
                                await appState.releaseCurrentSessionCoordinationLockIfOwned()
                                await MainActor.run {
                                    exitCaptureScreen()
                                }
                            }
                        } label: {
                            Text("Back")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(isCheckingSessionCoordination)
                    }
                } else {
                    Text(isCheckingSessionBeforeOpen || isCheckingSessionCoordination ? "Checking Session" : isAwaitingInitialSessionTypeSelection ? "Choose Session Type" : "Opening Camera")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    if isAwaitingInitialSessionTypeSelection {
                        Text("Select how to capture this visit.")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.86))
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 360)
            .background(Color.black.opacity(0.80))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 20)
        }
    }

    private func beginOpenFlow(forceRetry: Bool = false) {
        if !forceRetry, didStartOpenFlow { return }
        isCheckingSessionBeforeOpen = false
        didStartOpenFlow = true
        showOpenCameraTimeout = false
        openFlowToken += 1
        let token = openFlowToken

        camera.prepareForPreviewAsync()
        camera.ensurePreviewRunningAsync()

        refreshSessionReadiness()
        if hasSessionReadyForProperty {
            completeOpenFlow()
        }

        // Do not hard-gate view transition on preview startup; preview can finish after ContentView appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard token == openFlowToken else { return }
            refreshSessionReadiness()
            if hasSessionReadyForProperty {
                completeOpenFlow()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            guard token == openFlowToken else { return }
            guard !showCameraContent else { return }
            guard !camera.isPreviewRunning else {
                refreshSessionReadiness()
                if hasSessionReadyForProperty {
                    completeOpenFlow()
                }
                return
            }
            showOpenCameraTimeout = true
        }
    }

    private func completeOpenFlow() {
        guard !showCameraContent, sessionEntryBlock == nil else { return }
        appState.markCurrentSessionCameraEntryBegan()
        withAnimation(.easeInOut(duration: 0.14)) {
            showCameraContent = true
        }
        if let session = appState.currentSession,
           appState.hasMaterialDraftCaptures(session) {
            schedulePostOpenReferenceReconcile()
        }
        appState.ensureCurrentSessionMetadataInBackground()
    }

    private func continueAfterSessionCoordinationAllowed() {
        if appState.currentSessionRequiresInitialSessionTypeSelection(propertyID: propertyID) {
            if let initialSessionType {
                if didUseLightweightFastEntry {
                    guard appState.applyCurrentSessionTypeForFastEntry(initialSessionType) != nil else { return }
                    appState.persistCurrentSessionTypeAfterFastEntry(initialSessionType)
                } else {
                    guard appState.persistCurrentSessionType(initialSessionType) != nil else { return }
                }
                beginOpenFlow(forceRetry: true)
                return
            }
            isAwaitingInitialSessionTypeSelection = true
            return
        }
        beginOpenFlow(forceRetry: true)
    }

    private func schedulePostOpenReferenceReconcile() {
        guard !didSchedulePostOpenReferenceReconcile else { return }
        didSchedulePostOpenReferenceReconcile = true
        let startedAt = Date()
        let sessionID = appState.currentSession?.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard showCameraContent,
                  appState.selectedPropertyID == propertyID,
                  appState.currentSession?.id == sessionID else {
                return
            }
            await appState.reconcileRemoteSessionContentForPropertyOpen(propertyID: propertyID)
            print(
                "[PropertyOpenPerf] propertyID=\(propertyID.uuidString) " +
                "postOpenReferenceReconcileElapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
            )
        }
    }

    private func refreshSessionReadiness() {
        let session = appState.currentSession
        hasSessionReadyForProperty = session?.propertyID == propertyID && session?.status == .draft
    }

    private func beginSessionCoordinationFlow(
        forceClaim: Bool = false,
        openAfterAllowed: Bool = true
    ) {
        print(
            "[SessionCoordinationUI] event=begin " +
            "propertyID=\(propertyID.uuidString) " +
            "forceClaim=\(forceClaim) " +
            "currentSessionID=\(appState.currentSession?.id.uuidString ?? "nil") " +
            "currentSessionStatus=\(appState.currentSession?.status.rawValue ?? "nil")"
        )
        guard let sessionID = appState.currentSession?.id else {
            if sessionEntryBlock?.blockContext == "pending_export" {
                isCheckingSessionCoordination = false
                return
            }
            if openAfterAllowed {
                beginOpenFlow(forceRetry: true)
            }
            return
        }
        isCheckingSessionCoordination = openAfterAllowed
        isVerifyingSessionAfterPresentation = false
        sessionEntryBlock = nil
        Task {
            let status = await appState.evaluateSessionEntryCoordination(
                propertyID: propertyID,
                sessionID: sessionID,
                forceClaim: forceClaim
            )
            switch status {
            case .allowed:
                print("[SessionCoordinationUI] event=result result=allowed")
            case .blocked(let block):
                let lockedAt = block.lockedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
                print(
                    "[SessionCoordinationUI] event=result result=blocked " +
                    "ownerDescription=\(block.ownerDescription) " +
                    "lockedAt=\(lockedAt)"
                )
            }
            await MainActor.run {
                isCheckingSessionCoordination = false
                isVerifyingSessionAfterPresentation = false
                switch status {
                case .allowed:
                    sessionEntryBlock = nil
                    if openAfterAllowed {
                        continueAfterSessionCoordinationAllowed()
                    }
                case .blocked(let block):
                    isAwaitingInitialSessionTypeSelection = false
                    openFlowToken += 1
                    didStartOpenFlow = false
                    camera.stopPreviewAsync()
                    if showCameraContent {
                        withAnimation(.easeInOut(duration: 0.14)) {
                            showCameraContent = false
                        }
                    }
                    sessionEntryBlock = block
                    appState.locallyLockedPropertyIDs.insert(propertyID)
                }
            }
        }
    }

    private func claimBlockedSession() {
        if sessionEntryBlock?.blockContext == "pending_export",
           let recovery = appState.recoverLocalPendingExportForPropertyOpen(propertyID: propertyID) {
            sessionEntryBlock = nil
            isCheckingSessionCoordination = false
            onPendingExportRecovered(recovery.property, recovery.session)
            exitCaptureScreen()
            return
        }
        beginSessionCoordinationFlow(forceClaim: true)
    }

    private func exitCaptureScreen() {
        camera.stopPreviewAsync()
        dismiss()
    }

    private func lockMessage(for block: AppState.SessionEntryCoordinationBlock) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return AppState.sessionEntryBlockMessage(for: block) { lockedAt in
            formatter.string(from: lockedAt)
        }
    }

    private struct InitialSessionTypeChoiceSheet: View {
        let onChoose: (SessionType) -> Void
        let onBack: () -> Void
        @State private var selectedSessionTypeBeingOpened: SessionType? = nil

        var body: some View {
            VStack(spacing: 16) {
                Text("Session Type")
                    .font(.system(size: 22, weight: .bold))

                VStack(spacing: 10) {
                    choiceButton(
                        title: "Full Documentation",
                        subtitle: "Guided photos + flags + resolution required",
                        systemImage: "camera.metering.matrix",
                        sessionType: .fullDocumentation
                    )
                    choiceButton(
                        title: "Punchlist Visit",
                        subtitle: "Active/RR items only, no guided requirements",
                        systemImage: "checklist",
                        sessionType: .punchlistVisit
                    )
                }

                Button("Back", action: onBack)
                    .font(.system(size: 16, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
                    .disabled(selectedSessionTypeBeingOpened != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }

        private func choiceButton(
            title: String,
            subtitle: String,
            systemImage: String,
            sessionType: SessionType
        ) -> some View {
            let isSelected = selectedSessionTypeBeingOpened == sessionType

            return Button(action: {
                guard selectedSessionTypeBeingOpened == nil else { return }
                selectedSessionTypeBeingOpened = sessionType
                DispatchQueue.main.async {
                    onChoose(sessionType)
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                        Text(subtitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 72)
            }
            .buttonStyle(SessionTypeChoiceButtonStyle(isSelected: isSelected))
            .disabled(selectedSessionTypeBeingOpened != nil && !isSelected)
            .accessibilityValue(isSelected ? "Selected" : "")
        }
    }

    private struct SessionTypeChoiceButtonStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            let isHighlighted = isSelected || configuration.isPressed

            configuration.label
                .background(isHighlighted ? Color.accentColor : Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
