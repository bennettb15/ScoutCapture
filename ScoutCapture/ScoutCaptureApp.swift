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
                    skipStartupLoading: true,
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
                        appState.refreshBackupStatus()
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
    // Allow warm-launch hub fetch to complete more often before leaving splash.
    private let warmLaunchTimeoutSeconds: TimeInterval = 1.9

    private var isAppReady: Bool {
        skipStartupLoading || (sessionHubReady && minimumLaunchDelayMet)
    }

    var body: some View {
        Group {
            if !isAppReady {
                LoadingView(
                    progress: launchProgress,
                    showsProgressBar: false,
                    showsLogo: true
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
            } else {
                SessionHubView()
            }
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
                    print("[Launch] warm launch timed out; continuing app launch")
                    sessionHubReady = true
                    advanceLaunchProgress(to: 0.88)
                    resumeOnce()
                }

                appState.warmLaunchReadiness {
                    sessionHubReady = true
                    advanceLaunchProgress(to: 0.88)
                    resumeOnce()
                }
            }

            _ = await minDelay
            advanceLaunchProgress(to: 0.96)
            AddPropertyWarmup.prewarm()
            OptionalDetailNoteWarmup.prewarm()
            advanceLaunchProgress(to: 1.0)
            try? await Task.sleep(nanoseconds: 60_000_000)
            minimumLaunchDelayMet = true
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
}

struct SessionHubView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
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

    private let selectionHaptic = UIImpactFeedbackGenerator(style: .light)
    private let hiddenDebugTapWindow: TimeInterval = 1.5
    private let startupPlaceholderHoldSeconds: TimeInterval = 8.0

    private enum HubRoute: Hashable {
        case propertySession(propertyID: UUID, resumeDraft: Bool)
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
                            if !filteredActiveProperties.isEmpty {
                                Section {
                                    ForEach(filteredActiveProperties) { property in
                                        propertyRow(property)
                                    }
                                }
                            }

                            if showArchivedSection && !filteredArchivedProperties.isEmpty {
                                Section("Archived") {
                                    ForEach(filteredArchivedProperties) { property in
                                        propertyRow(property)
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
                        .refreshable {
                            await appState.refreshPropertiesAwaitingForegroundRefresh()
                        }
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
                case let .propertySession(propertyID, resumeDraft):
                    PropertySessionView(propertyID: propertyID, resumeDraft: resumeDraft)
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
            .onAppear {
                isOpeningProperty = false
                pressedPropertyID = nil
                if appState.properties.isEmpty {
                    beginStartupPlaceholderHoldWindow()
                } else {
                    placeholderHoldUntil = nil
                }
                appState.triggerBackupForLifecycleEvent()
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
                if case let .propertySession(propertyID, _) = oldPath.last,
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
    private func propertyRow(_ property: Property) -> some View {
        let isPressed = pressedPropertyID == property.id
        let sessionsForProperty = appState.sessions(for: property.id).sorted { $0.startedAt > $1.startedAt }
        let draft = appState.draftSession(for: property.id)
        let pendingSession = sessionsForProperty.first(where: { appState.isPendingDelivery($0) })
        let hasPendingExport = pendingSession != nil
        let latestReExportSession = reExportCandidateSession(for: property.id)
        let hasReExportGlyph = latestReExportSession != nil
        let clientLine = propertyClientLine(property)
        let addressLine = propertyAddressLine(property)
        let hasMapsButton = mapsAddressQuery(for: property) != nil
        let hasPhoneActions = hasValidPhoneNumber(property)
        let hasStatusRow = draft != nil || hasPendingExport || hasReExportGlyph
        let isOccupiedByOther = appState.isPropertyOccupiedByOther(propertyID: property.id)
        let canonicalLockSession = appState.canonicalLockSession(for: property.id)
        let draftLockSession = appState.draftSession(for: property.id)
        let isLockedByOther: Bool = {
            guard let session = draftLockSession else { return false }
            return appState.isSessionLockedByOther(sessionID: session.id)
        }()
        let locallyLocked = appState.locallyLockedPropertyIDs.contains(property.id)
        let showLock = isOccupiedByOther || isLockedByOther || locallyLocked
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
                            if draft != nil {
                                chipLabel("Draft", tint: .orange)
                            }

                            if hasPendingExport {
                                chipLabel("Pending Export", tint: .blue)
                            }
                        }

                    }
                }

            }
            .frame(minHeight: (addressLine != nil ? (clientLine != nil ? 58 : 40) : 24), alignment: .top)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isPressed ? Color.blue.opacity(colorScheme == .light ? 0.22 : 0.30) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isPressed ? Color.blue.opacity(colorScheme == .light ? 0.55 : 0.70) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handlePropertyTap(property, latestSession: sessionsForProperty.first, pendingSession: pendingSession)
        }
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
            if hasReExportGlyph, let reExportSession = latestReExportSession {
                Button {
                    print("[ReExportInvoke] propertyID=\(property.id.uuidString) sessionID=\(reExportSession.id.uuidString) source=leadingSwipe")
                    beginPendingExport(for: property, session: reExportSession)
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

    private var countersHeader: some View {
        VStack(spacing: 12) {
            if isSearchExpanded {
                propertiesSearchRow
            }

            if !isSearchExpanded {
                ZStack {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            showCloudBackupSheet = true
                        } label: {
                            cloudStatusIcon
                                .frame(width: 42, height: 42)
                                .background(buttonFill)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(buttonStroke, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
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
        appState.draftSession(for: property.id) != nil
    }

    private func propertyHasPendingExport(_ property: Property) -> Bool {
        appState.sessions(for: property.id).contains(where: { appState.isPendingDelivery($0) })
    }

    private func reExportCandidateSession(for propertyID: UUID) -> Session? {
        appState.sessions(for: propertyID)
            .filter { appState.isReExportEligible($0) }
            .sorted { lhs, rhs in
                let l = lhs.firstDeliveredAt ?? .distantPast
                let r = rhs.firstDeliveredAt ?? .distantPast
                return l > r
            }
            .first
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
        path.append(.propertySession(propertyID: property.id, resumeDraft: false))
    }

    private func handlePropertyTap(
        _ property: Property,
        latestSession: Session?,
        pendingSession: Session?
    ) {
        guard !isOpeningProperty else { return }
        isOpeningProperty = true
        propertyTapToken += 1
        let tapToken = propertyTapToken
        selectionHaptic.impactOccurred()
        pressedPropertyID = property.id

        let pending = pendingSession != nil
        let latestID = latestSession?.id.uuidString ?? "NONE"
        let isBaseline = latestSession.map { property.baselineSessionID == $0.id } ?? false
        let sealed = latestSession?.isSealed ?? false
        let firstDelivered = latestSession?.firstDeliveredAt.map { "\($0)" } ?? "nil"
        let action = pending ? "promptDeliver" : "openCamera"
        verboseLog("[PropertyTap] propertyID=\(property.id.uuidString) latestSessionID=\(latestID) isBaseline=\(isBaseline) sealed=\(sealed) firstDeliveredAt=\(firstDelivered) pending=\(pending) action=\(action)")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard tapToken == propertyTapToken else { return }
            openProperty(property)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard tapToken == propertyTapToken else { return }
            if pressedPropertyID == property.id { pressedPropertyID = nil }
        }
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
        return appState.sessions(for: property.id).contains(where: { appState.isPendingDelivery($0) })
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
                            Text(session.status == .draft ? "Draft Session" : "Completed Session")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.primary)
                            Text("Started \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            if appState.isPendingDelivery(session) {
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
        sessions = appState.sessions(for: property.id).sorted { $0.startedAt > $1.startedAt }
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
    let totalFindings: String
    let categoryCounts: [(AppState.DivergenceAuditCategory, Int)]
    let items: [DebugDivergenceAuditSnapshotItem]
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
        totalFindings = String(summary.items.count)
        let counts = summary.countsByCategory
        categoryCounts = AppState.DivergenceAuditCategory.allCases
            .map { ($0, counts[$0] ?? 0) }
            .filter { $0.1 > 0 }
        items = summary.items.map(DebugDivergenceAuditSnapshotItem.init)
        snapshotText = AppState.divergenceAuditSnapshotText(summary)
    }

    var corePropertyStatus: String {
        remoteOnlyPropertyCount == "0" && localOnlyPropertyCount == "0" ? "OK" : "Needs Review"
    }

    var coreSessionStatus: String {
        remoteOnlySessionCount == "0" && localOnlySessionCount == "0" ? "OK" : "Needs Review"
    }

    var legacyReviewCount: Int {
        items.filter { $0.filterMatches(.needsReview) }.count
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
            return category == AppState.DivergenceAuditCategory.captureProfile.rawValue
        case .parentMissing:
            return category == AppState.DivergenceAuditCategory.missingParent.rawValue
        case .orgReconciliation:
            return category == AppState.DivergenceAuditCategory.staleOrgMismatch.rawValue
        }
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

private struct DebugLocalDiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm: Bool = false
    @State private var isRunningDivergenceAudit: Bool = false
    @State private var failedQueueItems: [DebugQueueDiagnosticSnapshotItem] = []
    @State private var retryCappedMediaItems: [DebugMediaDiagnosticSnapshotItem] = []
    @State private var pendingMediaItems: [DebugMediaDiagnosticSnapshotItem] = []
    @State private var divergenceAuditSnapshot: DebugDivergenceAuditSnapshot?

    private var diagnostics: AppState.LocalDiagnosticsState {
        appState.localDiagnostics
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Local diagnostic state only. Clearing this screen resets counters and last-error memory; it does not clear queues, files, Supabase rows, exports, reports, or app data.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Section("Offline Replay Last Run") {
                    diagnosticRow("Discovered", diagnostics.offlineReplay.discoveredCount)
                    diagnosticRow("Attempted", diagnostics.offlineReplay.attemptedCount)
                    diagnosticRow("Succeeded", diagnostics.offlineReplay.succeededCount)
                    diagnosticRow("Failed", diagnostics.offlineReplay.failedCount)
                    diagnosticRow("Skipped Backoff", diagnostics.offlineReplay.skippedBackoffCount)
                    diagnosticRow("Normalized In-Flight", diagnostics.offlineReplay.normalizedInFlightCount)
                    diagnosticRow("Last Run", formattedDate(diagnostics.offlineReplay.lastRunAt))
                }

                Section("Offline Queue") {
                    diagnosticRow("Total", diagnostics.offlineQueue.totalQueued)
                    diagnosticRow("Pending", diagnostics.offlineQueue.pendingCount)
                    diagnosticRow("Failed", diagnostics.offlineQueue.failedCount)
                    diagnosticRow("Oldest Failure Age", formattedAge(diagnostics.offlineQueue.oldestFailureAgeSeconds))
                    diagnosticRow("Refreshed", formattedDate(diagnostics.offlineQueue.refreshedAt))
                    NavigationLink {
                        DebugOfflineQueueItemsView(items: failedQueueItems)
                    } label: {
                        diagnosticNavigationLabel("Failed Queue Items", count: failedQueueItems.count)
                    }
                }

                Section("Media") {
                    diagnosticRow("Last Backfill Discovered", diagnostics.media.lastBackfillDiscoveredCount)
                    diagnosticRow("Last Backfill Attempted", diagnostics.media.lastBackfillAttemptedCount)
                    diagnosticRow("Skipped Retry Cap", diagnostics.media.lastBackfillSkippedRetryCapCount)
                    diagnosticRow("Upload Successes", diagnostics.media.uploadSuccessCount)
                    diagnosticRow("Upload Failures", diagnostics.media.uploadFailureCount)
                    diagnosticRow("Pending Local Media", optionalCount(diagnostics.media.pendingLocalMediaCount))
                    diagnosticRow("Last Backfill", formattedDate(diagnostics.media.lastBackfillAt))
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

                Section("Shadow Writes") {
                    shadowWriteRow("Property", diagnostics.shadowWrites.property)
                    shadowWriteRow("Session", diagnostics.shadowWrites.session)
                    shadowWriteRow("Shot Metadata", diagnostics.shadowWrites.shotMetadata)
                    shadowWriteRow("Capture Profile", diagnostics.shadowWrites.captureProfile)
                }

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
                        diagnosticRow("Failed", summary.failed)
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

                if let snapshot = divergenceAuditSnapshot {
                    Section("Core Sync Health") {
                        diagnosticRow("Property Match Status", snapshot.corePropertyStatus)
                        diagnosticRow("Matched Properties", snapshot.matchedPropertyCount)
                        diagnosticRow("Local-Only Properties", snapshot.localOnlyPropertyCount)
                        diagnosticRow("Remote-Only Properties", snapshot.remoteOnlyPropertyCount)
                        Text(snapshot.corePropertyStatus == "OK" ? "No property presence divergence detected." : "Property presence needs review.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)

                        diagnosticRow("Session Match Status", snapshot.coreSessionStatus)
                        diagnosticRow("Matched Sessions", snapshot.matchedSessionCount)
                        diagnosticRow("Local-Only Sessions", snapshot.localOnlySessionCount)
                        diagnosticRow("Remote-Only Sessions", snapshot.remoteOnlySessionCount)
                        Text(snapshot.coreSessionStatus == "OK" ? "No session presence divergence detected." : "Session presence needs review.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Section("Legacy / Needs Review") {
                        diagnosticRow("Matched Shots", snapshot.matchedShotCount)
                        diagnosticRow("Local-Only Shots", snapshot.localOnlyShotCount)
                        Text("Local-only shots may be legacy captures or uploads that have not reached remote storage yet.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        diagnosticRow("Remote-Only Shots", snapshot.remoteOnlyShotCount)
                        diagnosticRow("Stale Org Reconciled Properties", snapshot.staleOrgReconciledPropertyCount)
                        diagnosticRow("Stale Org Reconciled Shots", snapshot.staleOrgReconciledShotCount)
                        Text("Stale org reconciled means remote active-org ownership proved the local historical org metadata safe for this audit. It is not treated as an active sync failure.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        diagnosticRow("Findings", snapshot.totalFindings)
                        ForEach(snapshot.categoryCounts, id: \.0) { category, count in
                            diagnosticRow(label(for: category), count)
                        }
                        NavigationLink {
                            DebugDivergenceAuditItemsView(items: snapshot.items)
                        } label: {
                            diagnosticNavigationLabel("Audit Findings", count: snapshot.items.count)
                        }
                    }
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
        .alert("Clear Local Diagnostics?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                appState.clearLocalDiagnostics()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only local diagnostic counters and the last sanitized error will be reset. Queues, files, Supabase data, exports, and app records are not changed.")
        }
    }

    private func refreshDiagnosticDetailSnapshots() {
        failedQueueItems = appState.diagnosticsFailedQueueItems().map(DebugQueueDiagnosticSnapshotItem.init)
        retryCappedMediaItems = appState.diagnosticsRetryCappedMediaItems().map(DebugMediaDiagnosticSnapshotItem.init)
        pendingMediaItems = appState.diagnosticsPendingMediaItems().map(DebugMediaDiagnosticSnapshotItem.init)
    }

    private func runDivergenceAudit() {
        guard !isRunningDivergenceAudit else { return }
        isRunningDivergenceAudit = true
        Task {
            let summary = await appState.runDivergenceAudit()
            await MainActor.run {
                divergenceAuditSnapshot = DebugDivergenceAuditSnapshot(summary)
                isRunningDivergenceAudit = false
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

    private func optionalCount(_ value: Int?) -> String {
        value.map(String.init) ?? "not scanned"
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
        case .captureProfile:
            return "Capture profile"
        case .missingParent:
            return "Parent/missing"
        default:
            return category.rawValue
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(date: .abbreviated, time: .standard)
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

private struct DebugOfflineQueueItemsView: View {
    let items: [DebugQueueDiagnosticSnapshotItem]

    var body: some View {
        List {
            Section {
                Text("Read-only local queue diagnostics. No queue items can be deleted, reset, or retried from this screen.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Section {
                    Text("No failed offline queue items.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Failed Items") {
                    ForEach(items) { item in
                        NavigationLink {
                            DebugOfflineQueueItemDetailView(item: item)
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
        .navigationTitle("Failed Queue")
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

private struct DebugDivergenceAuditItemsView: View {
    let items: [DebugDivergenceAuditSnapshotItem]
    @State private var filter: DebugDivergenceAuditFilter = .all

    private var filteredItems: [DebugDivergenceAuditSnapshotItem] {
        items.filter { $0.filterMatches(filter) }
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

            if filteredItems.isEmpty {
                Section {
                    Text("No findings for this filter.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Findings") {
                    ForEach(filteredItems) { item in
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
            }
        }
        .navigationTitle("Divergence Audit")
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

private struct DebugOfflineQueueItemDetailView: View {
    let item: DebugQueueDiagnosticSnapshotItem

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
        }
        .navigationTitle("Queue Item")
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var showCaptureProfileMaintenanceBackfillConfirm: Bool = false

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

    @State private var didSetup: Bool = false
    @State private var showCameraContent: Bool = false
    @State private var showOpenCameraTimeout: Bool = false
    @State private var didStartOpenFlow: Bool = false
    @State private var openFlowToken: Int = 0
    @State private var hasSessionReadyForProperty: Bool = false
    @State private var isCheckingSessionCoordination: Bool = false
    @State private var sessionEntryBlock: AppState.SessionEntryCoordinationBlock? = nil

    private let camera = CameraManager.shared
    private let timeoutSeconds: Double = 4.0

    var body: some View {
        ZStack {
            if showCameraContent {
                ContentView(onExitToHub: {
                    dismiss()
                })
                .transition(.opacity)
            } else {
                openingCameraInterstitial
                    .transition(.opacity)
            }
        }
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .onReceive(camera.$isPreviewRunning.removeDuplicates()) { isRunning in
                if isRunning && didStartOpenFlow && hasSessionReadyForProperty {
                    completeOpenFlow()
                }
            }
            .onAppear {
                guard !didSetup else { return }
                didSetup = true
                appState.selectProperty(id: propertyID)
                if resumeDraft {
                    if appState.currentSession?.propertyID != propertyID || appState.currentSession?.status != .draft {
                        _ = appState.loadDraftSession(for: propertyID)
                    }
                } else {
                    _ = appState.startSession()
                }
                refreshSessionReadiness()
                beginSessionCoordinationFlow()
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
                dismiss()
            }
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
                            dismiss()
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
                                dismiss()
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
                    Text(isCheckingSessionCoordination ? "Checking session..." : "Opening camera...")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
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
        didStartOpenFlow = true
        showOpenCameraTimeout = false
        openFlowToken += 1
        let token = openFlowToken

        camera.prepareForPreviewAsync()
        camera.ensurePreviewRunningAsync()

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
        guard !showCameraContent else { return }
        withAnimation(.easeInOut(duration: 0.14)) {
            showCameraContent = true
        }
        appState.ensureCurrentSessionMetadataInBackground()
    }

    private func refreshSessionReadiness() {
        let session = appState.currentSession
        hasSessionReadyForProperty = session?.propertyID == propertyID && session?.status == .draft
    }

    private func beginSessionCoordinationFlow(forceClaim: Bool = false) {
        print(
            "[SessionCoordinationUI] event=begin " +
            "propertyID=\(propertyID.uuidString) " +
            "forceClaim=\(forceClaim) " +
            "currentSessionID=\(appState.currentSession?.id.uuidString ?? "nil") " +
            "currentSessionStatus=\(appState.currentSession?.status.rawValue ?? "nil")"
        )
        guard let sessionID = appState.currentSession?.id else {
            beginOpenFlow(forceRetry: true)
            return
        }
        isCheckingSessionCoordination = true
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
            switch status {
            case .allowed:
                sessionEntryBlock = nil
                beginOpenFlow(forceRetry: true)
            case .blocked(let block):
                sessionEntryBlock = block
                appState.locallyLockedPropertyIDs.insert(propertyID)
            }
        }
    }
}

    private func claimBlockedSession() {
        beginSessionCoordinationFlow(forceClaim: true)
    }

    private func lockMessage(for block: AppState.SessionEntryCoordinationBlock) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let lockedAt = block.lockedAt {
            return "Locked by \(block.ownerDescription) since \(formatter.string(from: lockedAt))."
        }
        return "Locked by \(block.ownerDescription)."
    }
}
