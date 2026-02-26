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
import Photos

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
    @State private var sessionHubReady: Bool = false
    @State private var cameraPreviewReady: Bool = false
    @State private var minimumLaunchDelayMet: Bool = false
    @State private var didStartWarmup: Bool = false

    private var isAppReady: Bool {
        sessionHubReady && cameraPreviewReady && minimumLaunchDelayMet
    }

    var body: some View {
        Group {
            if !isAppReady {
                LoadingView()
            } else {
                SessionHubView()
            }
        }
        .onReceive(CameraManager.shared.$isReadyForPreview.removeDuplicates()) { ready in
            if ready {
                cameraPreviewReady = true
            }
        }
        .task {
            guard !didStartWarmup else { return }
            didStartWarmup = true

            async let minDelay: Void = {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    minimumLaunchDelayMet = true
                }
            }()

            CameraManager.prewarm()
            if CameraManager.shared.isReadyForPreview {
                cameraPreviewReady = true
            }

            await withCheckedContinuation { continuation in
                appState.warmLaunchReadiness {
                    sessionHubReady = true
                    continuation.resume()
                }
            }

            _ = await minDelay
            AddPropertyWarmup.prewarm()
            OptionalDetailNoteWarmup.prewarm()
        }
    }
}

struct SessionHubView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    private let localStore = LocalStore()
    @State private var path: [HubRoute] = []
    @State private var showAddProperty: Bool = false
    @State private var pressedPropertyID: UUID? = nil
    @State private var isEditMode: Bool = false
    @State private var showArchivedProperties: Bool = false
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
    @State private var isSearchExpanded: Bool = false
    @State private var searchQuery: String = ""
    @FocusState private var isSearchFieldFocused: Bool
    @State private var propertyListFilter: PropertyListFilter = .all
    @State private var showCalendarComingSoonPopup: Bool = false
#if DEBUG
    @State private var showDebugTools: Bool = false
#endif

    private let selectionHaptic = UIImpactFeedbackGenerator(style: .light)

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
        var stampedComplete: Bool = false
        var zipReady: Bool = false
    }

    private enum ExportChecklistStep {
        case originals
        case sessionData
        case stamped
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
        appState.properties.filter { !$0.isArchived }
    }

    private var archivedProperties: [Property] {
        appState.properties.filter { $0.isArchived }
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

    private var isCompactSearchMode: Bool {
        (isSearchExpanded && isSearchFieldFocused) || !normalizedSearchQuery.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                let showArchivedSection = isEditMode && showArchivedProperties
                let hasNoMatches = filteredActiveProperties.isEmpty && (!showArchivedSection || filteredArchivedProperties.isEmpty)
                let hasNoPropertiesAtAll = activeProperties.isEmpty && (!showArchivedSection || archivedProperties.isEmpty)
                if hasNoPropertiesAtAll {
                    ContentUnavailableView(
                        "No Properties",
                        systemImage: "house",
                        description: Text("Add a property to start a session.")
                    )
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
                    .listStyle(.plain)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                countersHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                debugToolsBottomBar
            }
            .navigationDestination(for: HubRoute.self) { route in
                switch route {
                case let .propertySession(propertyID, resumeDraft):
                    PropertySessionView(propertyID: propertyID, resumeDraft: resumeDraft)
                        .environmentObject(appState)
                }
            }
            .fullScreenCover(isPresented: $showAddProperty) {
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
                        if didExport {
                            _ = appState.markSessionExported(propertyID: file.propertyID, sessionID: file.sessionID)
                            if !appState.propertyHasBaseline(file.propertyID) {
                                _ = appState.setPropertyBaselineSession(propertyID: file.propertyID, sessionID: file.sessionID)
                            }
                        }
                        pendingExportFile = nil
                        isPreparingPendingExport = false
                        appState.refreshProperties()
                    }
                )
            }
#if DEBUG
            .fullScreenCover(isPresented: $showDebugTools) {
                DebugToolsView()
                    .environmentObject(appState)
            }
#endif
            .onAppear {
                if appState.properties.isEmpty {
                    appState.refreshProperties()
                }
                selectionHaptic.prepare()
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
                    _ = appState.deleteProperty(id: property.id)
                    propertyToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    propertyToDelete = nil
                }
            } message: {
                Text("This will permanently delete all sessions, guided shots, issues, and references for this property. This cannot be undone and will not be recoverable.")
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
    private func propertyRow(_ property: Property) -> some View {
        let isPressed = pressedPropertyID == property.id
        let draft = appState.draftSession(for: property.id)
        let hasPendingExport = appState
            .sessions(for: property.id)
            .contains(where: { $0.status == .completed && $0.exportedAt == nil })
        let clientLine = propertyClientLine(property)
        let addressLine = propertyAddressLine(property)
        let hasMapsButton = mapsAddressQuery(for: property) != nil
        let hasPhoneActions = hasValidPhoneNumber(property)
        let hasStatusRow = draft != nil || hasPendingExport || isEditMode

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(property.name)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

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
                    HStack(spacing: 8) {
                        if draft != nil {
                            chipLabel("Draft", tint: .orange)
                        }

                        if hasPendingExport {
                            chipLabel("Pending Export", tint: .blue)
                        }
                    }
                }

                if isEditMode {
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        Menu {
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
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 26, height: 26)
                                .background(Color.white.opacity(0.16))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: (addressLine != nil ? (clientLine != nil ? 58 : 40) : 24), alignment: .top)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isPressed ? Color.primary.opacity(colorScheme == .light ? 0.08 : 0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isPressed ? Color.primary.opacity(0.18) : .clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: isPressed)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isEditMode else { return }
            handlePropertyTap(property)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !isEditMode {
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
        }
    }

    private func propertyClientLine(_ property: Property) -> String? {
        appState.hubMeta(for: property.id)?.clientLine
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
    private func chipLabel(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
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
            ZStack {
                HStack {
                    if !isEditMode {
                        Button {
                            showCalendarComingSoonPopup = true
                        } label: {
                            Image(systemName: "calendar")
                                .font(.system(size: 18, weight: .semibold))
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

                    if isEditMode {
#if DEBUG
                        customCapsuleToolbarButton(
                            title: "Debug",
                            isEnabled: true,
                            fill: .red.opacity(0.92),
                            stroke: .red.opacity(0.95),
                            label: .white
                        ) {
                            showDebugTools = true
                        }
#endif
                    }

                    Spacer(minLength: 0)
                    customCapsuleToolbarButton(
                        title: isEditMode ? "Done" : "Edit",
                        isEnabled: true,
                        fill: isEditMode ? .blue : nil,
                        stroke: isEditMode ? .blue.opacity(0.9) : nil,
                        label: isEditMode ? .white : nil
                    ) {
                        isEditMode.toggle()
                        if !isEditMode {
                            showArchivedProperties = false
                        }
                    }
                }
            }

            if !isCompactSearchMode {
                Image(colorScheme == .light ? "ScoutLogoNavy" : "ScoutLogoWhite")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 46)
                    .accessibilityHidden(true)
                
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

            propertiesSearchRow
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
            Text("Properties")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)

            Spacer(minLength: 0)

            if isSearchExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)

                    TextField("Search name or address", text: $searchQuery)
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
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)

                addCircleButton
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
        appState.sessions(for: property.id).contains(where: { $0.status == .completed && $0.exportedAt == nil })
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
    private var debugToolsBottomBar: some View {
        if isEditMode {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer(minLength: 0)
                    customCapsuleToolbarButton(
                        title: showArchivedProperties ? "Hide Archived" : "Show Archived",
                        isEnabled: true
                    ) {
                        showArchivedProperties.toggle()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(uiColor: .systemBackground))
            }
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

    @ViewBuilder
    private var pendingExportPromptOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("Export Now?")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)

                Text("This session is pending export. Export now to continue.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                    .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    customCapsuleToolbarButton(title: "Cancel", isEnabled: true) {
                        dismissPendingExportPrompt()
                    }
                    customCapsuleToolbarButton(
                        title: "Export Now",
                        isEnabled: true,
                        fill: .blue,
                        stroke: .blue.opacity(0.9),
                        label: .white
                    ) {
                        guard let property = pendingExportPromptProperty, let session = pendingExportPromptSession else { return }
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
        if let meta = appState.hubMeta(for: property.id) {
            return meta.normalizedNameToken.contains(query) ||
                meta.normalizedClientToken.contains(query) ||
                meta.normalizedAddressToken.contains(query)
        }
        let name = property.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let client = property.clientName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let address = property.address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return name.contains(query) || client.contains(query) || address.contains(query)
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
                    checklistRow(title: "Stamped", isComplete: pendingExportChecklist.stampedComplete)
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
        appState.selectProperty(id: property.id)
        if appState.draftSession(for: property.id) != nil {
            _ = appState.loadDraftSession(for: property.id)
            path.append(.propertySession(propertyID: property.id, resumeDraft: true))
        } else {
            _ = appState.startSession()
            path.append(.propertySession(propertyID: property.id, resumeDraft: false))
        }
    }

    private func handlePropertyTap(_ property: Property) {
        selectionHaptic.impactOccurred()
        pressedPropertyID = property.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let pending = appState.latestPendingExportSession(for: property.id) {
                pendingExportPromptProperty = property
                pendingExportPromptSession = pending
            } else {
                openProperty(property)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if pressedPropertyID == property.id {
                pressedPropertyID = nil
            }
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
                            case .stamped:
                                pendingExportChecklist.stampedComplete = true
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
        struct SessionExportAssetEntry: Codable {
            let localIdentifier: String
            let creationDate: Date?
            let pixelWidth: Int
            let pixelHeight: Int
            let originalFilename: String
        }

        struct SessionExportPayload: Codable {
            let exportedAt: Date
            let albumTitle: String
            let albumLocalId: String
            let property: Property?
            let session: Session?
            let activeIssueCount: Int
            let assets: [SessionExportAssetEntry]
            let observations: [Observation]
            let guidedShots: [GuidedShot]
        }

        let observations = (try? localStore.fetchObservations(propertyID: property.id)) ?? []
        let guidedShots = (try? localStore.fetchGuidedShots(propertyID: property.id)) ?? []

        let start = session.startedAt
        let end = session.endedAt ?? Date.distantFuture
        let sessionObservations = observations.filter { obs in
            if obs.sessionID == session.id { return true }
            return obs.sessionID == nil && obs.createdAt >= start && obs.createdAt <= end
        }

        let shotIDs = Set(sessionObservations.flatMap { obs in
            var ids = obs.shots.map(\.id)
            if let linked = obs.linkedShotID {
                ids.append(linked)
            }
            return ids
        })

        let sessionGuidedShots = guidedShots.filter { guided in
            if let shotID = guided.shot?.id, shotIDs.contains(shotID) {
                return true
            }
            if let capturedAt = guided.shot?.capturedAt, capturedAt >= start && capturedAt <= end {
                return true
            }
            return false
        }

        var orderedIDs: [String] = []
        var seen = Set<String>()
        func appendLocalID(_ value: String?) {
            let id = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            orderedIDs.append(id)
        }

        for observation in sessionObservations {
            for shot in observation.shots {
                appendLocalID(shot.imageLocalIdentifier)
            }
        }
        for guided in sessionGuidedShots {
            appendLocalID(guided.shot?.imageLocalIdentifier)
        }

        var assetEntries: [SessionExportAssetEntry] = []
        var zipEntries: [(path: String, data: Data)] = []
        zipEntries.append(("Originals/", Data()))
        zipEntries.append(("Stamped/", Data()))
        var originalEntries: [(String, Data)] = []
        var stampedEntries: [(String, Data)] = []

        for (index, localID) in orderedIDs.enumerated() {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: nil).firstObject else { continue }
            guard let data = requestImageData(for: asset) else { continue }
            let filename = exportFilename(for: asset, index: index + 1)
            assetEntries.append(
                SessionExportAssetEntry(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    originalFilename: filename
                )
            )
            originalEntries.append(("Originals/\(filename)", data))
            stampedEntries.append(("Stamped/\(filename)", data))
        }
        zipEntries.append(contentsOf: originalEntries)
        progress?(.originals)

        let payload = SessionExportPayload(
            exportedAt: Date(),
            albumTitle: property.name,
            albumLocalId: "",
            property: property,
            session: session,
            activeIssueCount: sessionObservations.filter { $0.status == .active }.count,
            assets: assetEntries,
            observations: sessionObservations,
            guidedShots: sessionGuidedShots
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sessionData = try encoder.encode(payload)
        zipEntries.append(("session.json", sessionData))
        progress?(.sessionData)

        zipEntries.append(contentsOf: stampedEntries)
        progress?(.stamped)

        let zipData = buildZipData(entries: zipEntries)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(exportZipFilename(for: property, session: session))
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try zipData.write(to: url, options: .atomic)
        progress?(.zipReady)
        return url
    }

    private func requestImageData(for asset: PHAsset) -> Data? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        var output: Data?
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            output = data
        }
        return output
    }

    private func exportFilename(for asset: PHAsset, index: Int) -> String {
        let fallback = "photo-\(index).jpg"
        guard let resource = PHAssetResource.assetResources(for: asset).first else { return fallback }
        let original = resource.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func buildZipData(entries: [(path: String, data: Data)]) -> Data {
        struct CentralRecord {
            let pathData: Data
            let crc32: UInt32
            let size: UInt32
            let localHeaderOffset: UInt32
        }

        var zip = Data()
        var centralRecords: [CentralRecord] = []
        centralRecords.reserveCapacity(entries.count)

        for entry in entries {
            let pathData = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(zip.count)

            appendUInt32LE(0x04034B50, to: &zip)
            appendUInt16LE(20, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
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
                    localHeaderOffset: localHeaderOffset
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
            appendUInt16LE(0, to: &zip)
            appendUInt16LE(0, to: &zip)
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
    
    @State private var clientName: String = ""
    @State private var clientPhone: String = ""
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

    private enum Field: Int, CaseIterable {
        case clientName
        case propertyName
        case streetAddress
        case city
        case state
        case zipCode
    }
    
    private var canSave: Bool {
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

            Form {
                Section("Client") {
                    TextField("Client name", text: $clientName)
                        .focused($focusedField, equals: .clientName)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .propertyName
                        }

                    TextField("Phone (optional)", text: $clientPhone)
                        .keyboardType(.phonePad)
                        .onChange(of: clientPhone) { _, newValue in
                            let filtered = newValue.filter(\.isNumber)
                            let limited = String(filtered.prefix(15))
                            if limited != clientPhone {
                                clientPhone = limited
                            }
                        }
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
                    TextField("State", text: $state)
                        .focused($focusedField, equals: .state)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = .zipCode
                        }
                        .textInputAutocapitalization(.characters)
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
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            applyInitialClientFocusIfNeeded()
        }
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
        guard canSave else {
            focusFirstInvalidField()
            return
        }

        let created = appState.createProperty(
            clientName: clientName,
            propertyName: propertyName,
            address: addressForStorage,
            clientPhone: clientPhone
        )
        if let created {
            appState.selectProperty(id: created.id)
            dismiss()
        }
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

    @State private var propertyName: String = ""
    @State private var clientName: String = ""
    @State private var streetAddress: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    @State private var phoneInput: String = ""
    @State private var showPendingExportRenameConfirm: Bool = false

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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Cancel", isEnabled: true) {
                    dismiss()
                }

                Spacer(minLength: 0)

                Text("Edit Contact")
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
                Section("Client") {
                    TextField("Client name", text: $clientName)
                        .textInputAutocapitalization(.words)

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
        .alert("Rename Pending Export Property?", isPresented: $showPendingExportRenameConfirm) {
            Button("Continue") {
                persistChanges()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This property has pending exports. Export filenames will use the updated property name.")
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
            propertyName: propertyName,
            clientName: clientName,
            address: composedAddress,
            clientPhone: digits
        )
        dismiss()
    }

    private func shouldConfirmPendingExportRename() -> Bool {
        let trimmedOriginal = property.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUpdated = propertyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUpdated.isEmpty, trimmedUpdated != trimmedOriginal else { return false }
        return appState.sessions(for: property.id).contains(where: { $0.status == .completed && $0.exportedAt == nil })
    }

    private func loadFromProperty() {
        propertyName = property.name
        clientName = property.clientName ?? ""
        let parsed = parseAddress(property.address)
        streetAddress = parsed.street
        city = parsed.city
        state = parsed.state
        zipCode = parsed.zip
        phoneInput = formatPhoneDisplay((property.clientPhone ?? "").filter(\.isNumber))
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
                            if session.status == .completed && session.exportedAt == nil {
                                Text("Pending Export")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                        }

                        Spacer(minLength: 0)

                        customCapsuleButton(
                            title: "Delete",
                            isEnabled: true,
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
            Text("This completed session is pending export. Deleting it will permanently remove its local export state. Tap Continue to review deletion confirmation.")
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
    }

    private var deleteConfirmationTitle: String {
        guard let target = deleteTarget else { return "Delete Session?" }
        if target.status == .draft {
            return "Delete Draft Session?"
        }
        return "Delete Completed Session?"
    }

    private var deleteConfirmationMessage: String {
        guard let target = deleteTarget else { return "This cannot be undone." }
        if target.status == .draft {
            return "This will permanently delete this draft session and its local records. This cannot be undone or recovered."
        }
        if target.exportedAt == nil {
            return "This session is pending export. Deleting it will permanently remove this session, its local records, and pending export state. This cannot be undone or recovered."
        }
        return "This will permanently delete this completed session and its local records. This cannot be undone or recovered."
    }

    private func reloadSessions() {
        sessions = appState.sessions(for: property.id).sorted { $0.startedAt > $1.startedAt }
    }

    private func handleDeleteTap(_ session: Session) {
        deleteTarget = session
        if session.status == .completed && session.exportedAt == nil {
            showPendingExportWarning = true
            return
        }
        showDeleteConfirm = true
    }

    private func confirmDelete() {
        guard let target = deleteTarget else { return }
        _ = appState.deleteSession(propertyID: property.id, sessionID: target.id)
        deleteTarget = nil
        appState.refreshProperties()
        reloadSessions()
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
}

#if DEBUG
private struct DebugToolsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showNuclearConfirm: Bool = false
    @State private var showClearCacheConfirm: Bool = false

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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                customCapsuleButton(title: "Done", isEnabled: true) {
                    dismiss()
                }
                Spacer(minLength: 0)
                Text("Debug Tools")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(buttonLabel)
                Spacer(minLength: 0)
                Color.clear.frame(width: 72, height: 42)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(uiColor: .systemBackground))

            ScrollView {
                VStack(spacing: 14) {
                    debugActionCard(
                        title: "Nuclear Reset (Local Only)",
                        detail: "Wipes all local app data: properties, sessions, guided, observations, references, and indexes. Does NOT modify iCloud Drive library data.",
                        role: .destructive
                    ) {
                        showNuclearConfirm = true
                    }

                    debugActionCard(
                        title: "Clear Local Index / UI Cache (Local Only)",
                        detail: "Resets local derived UI/index state and reloads from local store. Does NOT modify iCloud Drive library data.",
                        role: .normal
                    ) {
                        showClearCacheConfirm = true
                    }
                }
                .padding(14)
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
                appState.resetLocalSessionUIIndex()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This clears local cache/index state only and reloads local records. iCloud Drive library data will not be touched.")
        }
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
        action: @escaping () -> Void
    ) -> some View {
        let fill = role == .destructive ? Color.red.opacity(0.86) : buttonFill
        let stroke = role == .destructive ? Color.red.opacity(0.90) : buttonStroke
        let label = role == .destructive ? Color.white : buttonLabel

        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
            Text(detail)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            customCapsuleButton(
                title: role == .destructive ? "Run Nuclear Reset" : "Clear Cache",
                isEnabled: true,
                fill: fill,
                stroke: stroke,
                label: label,
                action: action
            )
        }
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
}
#endif

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
                if isRunning {
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
                beginOpenFlow()
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
                } else {
                    Text("Opening camera...")
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

        if camera.isPreviewRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                guard token == openFlowToken else { return }
                completeOpenFlow()
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            guard token == openFlowToken else { return }
            guard !camera.isPreviewRunning else {
                completeOpenFlow()
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
    }
}
