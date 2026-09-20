//
//  CameraPanelViews.swift
//  ScoutCapture
//

import SwiftUI
import UIKit

// Extracted production camera panel views. Keep behavior in sync with ContentView call sites.

private let isCameraPanelVerboseConsoleLoggingEnabled = false

@inline(__always)
private func verboseLog(_ message: @autoclosure () -> String) {
    guard isCameraPanelVerboseConsoleLoggingEnabled else { return }
    print(message())
}

struct ChecklistReclassifySheet: View {
    private enum DirectionChoice: String, CaseIterable, Identifiable {
        case interior = "Interior"
        case north = "North"
        case south = "South"
        case east = "East"
        case west = "West"

        var id: String { rawValue }

        var elevationValue: String { rawValue }

        var locationMode: ContentView.LocationMode {
            self == .interior ? .interior : .exterior
        }

        static func fromElevation(_ elevation: String?) -> DirectionChoice {
            let normalized = (CanonicalElevation.normalize(elevation) ?? elevation ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            switch normalized {
            case "South": return .south
            case "East": return .east
            case "West": return .west
            case "Interior": return .interior
            default: return .north
            }
        }
    }

    let title: String
    let initialBuilding: String?
    let initialElevation: String?
    let initialDetailType: String?
    let captureProfile: CaptureProfile
    @Binding var buildingOptions: [String]
    @ObservedObject var detailTypesModel: DetailTypesModel
    let buildingCodeForOption: (String) -> String
    let buildingDisplayNameForOption: (String) -> String
    let onCancel: () -> Void
    let onConfirm: (String, String, String) -> Void

    @State private var selectedBuilding: String = ""
    @State private var selectedDirection: DirectionChoice = .north
    @State private var selectedDetailType: String = ""
    @State private var showManageBuildingsSheet: Bool = false
    @State private var manageDetailMode: ContentView.LocationMode? = nil
    @State private var activePicker: PickerKind? = nil

    private enum PickerKind: Identifiable {
        case building
        case elevation
        case detail

        var id: Int {
            switch self {
            case .building: return 1
            case .elevation: return 2
            case .detail: return 3
            }
        }
    }

    private var availableDetailTypes: [DetailTypesModel.DetailTypeItem] {
        detailTypesModel.types(for: selectedDirection.locationMode, profile: captureProfile)
    }

    private var canConfirm: Bool {
        !selectedBuilding.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !selectedDetailType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    selectorRow(
                        title: "Building",
                        value: buildingLabel(for: selectedBuilding)
                    ) {
                        activePicker = .building
                    }

                    selectorRow(
                        title: "Elevation",
                        value: selectedDirection.rawValue
                    ) {
                        activePicker = .elevation
                    }

                    selectorRow(
                        title: "Detail",
                        value: selectedDetailType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Select" : selectedDetailType
                    ) {
                        activePicker = .detail
                    }
                } footer: {
                    Text("Angle is Auto. If the destination slot is occupied, the next available angle is assigned automatically.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Confirm") {
                        onConfirm(
                            selectedBuilding,
                            selectedDirection.elevationValue,
                            selectedDetailType
                        )
                    }
                    .disabled(!canConfirm)
                }
            }
            .onAppear {
                let trimmedBuilding = initialBuilding?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallbackBuilding = buildingOptions.first.map(buildingCodeForOption) ?? "B1"
                selectedBuilding = trimmedBuilding.isEmpty ? fallbackBuilding : trimmedBuilding
                selectedDirection = DirectionChoice.fromElevation(initialElevation)
                selectedDetailType = initialDetailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                normalizeDetailTypeSelection()
            }
            .onChange(of: selectedDirection) { _, _ in
                normalizeDetailTypeSelection()
            }
            .onChange(of: buildingOptions) { _, _ in
                let selectedCode = selectedBuilding.trimmingCharacters(in: .whitespacesAndNewlines)
                if !buildingOptions.contains(where: { buildingCodeForOption($0) == selectedCode }),
                   let fallback = buildingOptions.first {
                    selectedBuilding = buildingCodeForOption(fallback)
                }
            }
            .sheet(isPresented: $showManageBuildingsSheet) {
                ContentView.ManageBuildingsSheet(
                    options: $buildingOptions,
                    selectedBuilding: $selectedBuilding,
                    buildingCodeForOption: buildingCodeForOption,
                    buildingFullLabelForOption: buildingDisplayNameForOption,
                    onClose: {
                        showManageBuildingsSheet = false
                    }
                )
            }
            .sheet(item: $manageDetailMode) { mode in
                ContentView.ManageDetailTypesView(mode: mode, profile: captureProfile, model: detailTypesModel)
            }
            .overlay {
                pickerOverlay
            }
        }
    }

    private func selectorRow(
        title: String,
        value: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .medium))

            Spacer(minLength: 0)

            Button(action: action) {
                HStack(spacing: 8) {
                    Text(value)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var pickerOverlay: some View {
        if let activePicker {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.activePicker = nil
                    }

                pickerContent(for: activePicker)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: 360)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func pickerContent(for picker: PickerKind) -> some View {
        VStack(spacing: 0) {
            pickerHeader(title: pickerTitle(for: picker))

            switch picker {
            case .building:
                VStack(spacing: 0) {
                    ForEach(buildingOptions, id: \.self) { option in
                        let optionCode = buildingCodeForOption(option)
                        pickerRow(
                            title: buildingDisplayNameForOption(option),
                            isSelected: selectedBuilding == optionCode
                        ) {
                            selectedBuilding = optionCode
                            activePicker = nil
                        }

                        if option != buildingOptions.last {
                            pickerDivider()
                        }
                    }
                    pickerDivider()
                    pickerRow(title: "Manage...", isSelected: false) {
                        activePicker = nil
                        showManageBuildingsSheet = true
                    }
                }
                .padding(.vertical, 6)

            case .elevation:
                VStack(spacing: 0) {
                    ForEach(DirectionChoice.allCases) { option in
                        pickerRow(title: option.rawValue, isSelected: selectedDirection == option) {
                            selectedDirection = option
                            activePicker = nil
                        }
                        if option.id != DirectionChoice.allCases.last?.id {
                            pickerDivider()
                        }
                    }
                }
                .padding(.vertical, 6)

            case .detail:
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(availableDetailTypes) { item in
                            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !name.isEmpty {
                                pickerRow(title: name, isSelected: selectedDetailType == name) {
                                    selectedDetailType = name
                                    activePicker = nil
                                }
                                if item.id != availableDetailTypes.last?.id {
                                    pickerDivider()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 320)

                pickerDivider()
                pickerRow(title: "Manage...", isSelected: false) {
                    activePicker = nil
                    manageDetailMode = selectedDirection.locationMode
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
    }

    private func pickerTitle(for picker: PickerKind) -> String {
        switch picker {
        case .building: return "Building"
        case .elevation: return "Elevation"
        case .detail: return "Detail"
        }
    }

    private func pickerHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
            Spacer()
            Button("Done") {
                activePicker = nil
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white.opacity(0.92))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.20))
    }

    private func pickerRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func pickerDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func buildingLabel(for code: String) -> String {
        guard let option = buildingOptions.first(where: { buildingCodeForOption($0) == code }) else {
            return code
        }
        return buildingDisplayNameForOption(option)
    }

    private func normalizeDetailTypeSelection() {
        let available = availableDetailTypes
            .map(\.name)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if available.contains(selectedDetailType) { return }
        selectedDetailType = available.first ?? ""
    }
}


struct GuidedChecklistOverlay: View {
    let guidedShots: [GuidedShot]
    let retiredGuidedShots: [GuidedShot]
    let resolvedThumbnailPathByID: [UUID: String]
    let referencePathByID: [UUID: String]
    let currentSessionID: UUID?
    let currentSessionStartedAt: Date?
    let currentSessionEndedAt: Date?
    let currentSessionShotIDs: Set<UUID>
    let canChangeShotLifecycle: Bool
    let isBaselineSession: Bool
    let allowReferenceFallback: Bool
    let captureProfile: CaptureProfile
    @Binding var buildingOptions: [String]
    @ObservedObject var detailTypesModel: DetailTypesModel
    let buildingCodeForOption: (String) -> String
    let buildingDisplayNameForOption: (String) -> String
    let refreshToken: UUID
    @ObservedObject var cache: AssetImageCache
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ContentView.SheetControlTheme { .forScheme(colorScheme) }
    let onClose: () -> Void
    let onSelectGuided: (GuidedShot) -> Void
    let onSkip: (GuidedShot, SkipReason, String?) -> Void
    let onUndoSkip: (GuidedShot) -> Void
    let onRetake: (GuidedShot) -> Void
    let onRetire: (GuidedShot, String) -> Void
    let onRestoreRetired: (GuidedShot) -> Void
    let onReclassify: (GuidedShot, String, String, String) -> Void

    @State private var skipTarget: GuidedShot? = nil
    @State private var showSkipReasonDialog: Bool = false
    @State private var showSkipOtherSheet: Bool = false
    @State private var skipOtherText: String = ""
    @State private var guidedViewerState: GuidedViewerState? = nil
    @State private var retiredGuidedViewerState: GuidedViewerState? = nil
    @State private var retireTarget: GuidedShot? = nil
    @State private var showRestoreRetiredList: Bool = false
    @State private var restoreRetiredTarget: GuidedShot? = nil
    @State private var reclassifyTarget: GuidedShot? = nil
    @State private var inlineToastText: String? = nil
    @State private var inlineToastToken: Int = 0
    @State private var lastValidOrientation: UIDeviceOrientation = .portrait

    private struct GuidedViewerState: Identifiable {
        let id = UUID()
        let title: String
        let detailId: String
        let assets: [ReportAsset]
        let startIndex: Int
        let viewerToken: Int
    }

    private var isLandscape: Bool {
        lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight
    }

    private var rotationDegrees: Double {
        switch lastValidOrientation {
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return -90
        default:
            return 0
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let contentW = isLandscape ? h : w
            let contentH = isLandscape ? w : h

            NavigationStack {
                ZStack {
                    Color(uiColor: .secondarySystemGroupedBackground)
                        .ignoresSafeArea()

                    List {
                        Section {
                            ForEach(guidedShots) { item in
                                GuidedChecklistRow(
                                    guidedShot: item,
                                    resolvedThumbnailPath: resolvedThumbnailPathByID[item.id],
                                    referencePath: referencePathByID[item.id],
                                    currentSessionID: currentSessionID,
                                    isBaselineSession: isBaselineSession,
                                    allowReferenceFallback: allowReferenceFallback,
                                    isCapturedInCurrentSession: isCapturedInCurrentSession(item),
                                    canRetire: canChangeShotLifecycle,
                                    onTapRow: {
                                        onSelectGuided(item)
                                    },
                                    refreshToken: refreshToken,
                                    cache: cache,
                                    onTapSkip: {
                                        skipTarget = item
                                        showSkipReasonDialog = true
                                    },
                                    onTapRetake: {
                                        onRetake(item)
                                    },
                                    onTapUndoSkip: {
                                        onUndoSkip(item)
                                    },
                                    onTapViewReferenceImage: {
                                        showGuidedReferencePreview(for: item)
                                    },
                                    onTapViewCapturedImage: {
                                        showGuidedCapturedPreview(for: item)
                                    },
                                    onTapRetire: {
                                        retireTarget = item
                                    },
                                    onTapReclassify: {
                                        reclassifyTarget = item
                                    }
                                )
                            }
                        }

                    }
                    .listStyle(.insetGrouped)
                    .scrollIndicators(.hidden)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ZStack {
                        Text("Guided Checklist")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(theme.label)
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)

                        HStack(spacing: 10) {
                            if !retiredGuidedShots.isEmpty {
                                Button {
                                    showRestoreRetiredList = true
                                } label: {
                                    Text("Restore")
                                        .font(.system(size: 17, weight: .medium))
                                        .foregroundColor(theme.label)
                                        .frame(width: 88, height: 42)
                                        .background(theme.fill)
                                        .clipShape(Capsule())
                                        .overlay(
                                            Capsule()
                                                .stroke(theme.stroke, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }

                            Spacer(minLength: 0)

                            Button(action: onClose) {
                                Text("Done")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 72, height: 42)
                                    .background(theme.fill)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(theme.stroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                .sheet(isPresented: $showSkipOtherSheet, onDismiss: {
                    skipOtherText = ""
                    skipTarget = nil
                }) {
                    NavigationStack {
                        VStack(spacing: 14) {
                            Text("Enter skip reason")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)

                            TextField("Reason", text: $skipOtherText, axis: .vertical)
                                .font(.system(size: 16, weight: .regular))
                                .lineLimit(3...6)
                                .padding(12)
                                .background(Color(UIColor.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12))

                            Spacer(minLength: 0)
                        }
                        .padding(16)
                        .navigationTitle("Other")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cancel") {
                                    showSkipOtherSheet = false
                                }
                            }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Save") {
                                    submitSkip(.other, otherNote: skipOtherText)
                                    showSkipOtherSheet = false
                                }
                                .disabled(skipOtherText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                        }
                    }
                    .presentationDetents([.height(280)])
                }
                .sheet(item: $retireTarget) { target in
                    GuidedRetireReasonSheet(
                        guidedShot: target,
                        onCancel: {
                            retireTarget = nil
                        },
                        onConfirm: { reason in
                            onRetire(target, reason)
                            retireTarget = nil
                        }
                    )
                }
                .sheet(isPresented: $showRestoreRetiredList) {
                    NavigationStack {
                        List(retiredGuidedShots) { item in
                            RetiredGuidedChecklistRow(
                                guidedShot: item,
                                resolvedThumbnailPath: resolvedThumbnailPathByID[item.id],
                                referencePath: referencePathByID[item.id],
                                canRestore: canChangeShotLifecycle,
                                refreshToken: refreshToken,
                                cache: cache,
                                onTapRestore: {
                                    restoreRetiredTarget = item
                                },
                                onTapViewCapturedImage: {
                                    showRetiredGuidedCapturedPreview(for: item)
                                }
                            )
                        }
                        .listStyle(.insetGrouped)
                        .navigationTitle("Retired Guided")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") {
                                    showRestoreRetiredList = false
                                }
                            }
                        }
                    }
                    .alert(
                        "Restore Guided Checkpoint?",
                        isPresented: Binding(
                            get: { restoreRetiredTarget != nil },
                            set: { if !$0 { restoreRetiredTarget = nil } }
                        )
                    ) {
                        Button("Cancel", role: .cancel) {
                            restoreRetiredTarget = nil
                        }
                        Button("Restore", role: .destructive) {
                            if let item = restoreRetiredTarget {
                                restoreRetiredTarget = nil
                                showRestoreRetiredList = false
                                onRestoreRetired(item)
                            }
                        }
                    } message: {
                        Text("This returns the checkpoint and its preserved photo to the active guided workflow.")
                    }
                    .fullScreenCover(item: $retiredGuidedViewerState) { state in
                        ReportPhotoViewer(
                            title: state.title,
                            assets: state.assets,
                            startIndex: state.startIndex,
                            detailIdOverride: state.detailId,
                            cache: cache,
                            viewerToken: state.viewerToken
                        )
                    }
                }
                .sheet(item: $reclassifyTarget) { target in
                    ChecklistReclassifySheet(
                        title: "Reclassify",
                        initialBuilding: target.building,
                        initialElevation: target.targetElevation,
                        initialDetailType: target.detailType,
                        captureProfile: captureProfile,
                        buildingOptions: $buildingOptions,
                        detailTypesModel: detailTypesModel,
                        buildingCodeForOption: buildingCodeForOption,
                        buildingDisplayNameForOption: buildingDisplayNameForOption,
                        onCancel: {
                            reclassifyTarget = nil
                        },
                        onConfirm: { building, elevation, detailType in
                            onReclassify(target, building, elevation, detailType)
                            reclassifyTarget = nil
                        }
                    )
                }
                .fullScreenCover(item: $guidedViewerState) { state in
                    ReportPhotoViewer(
                        title: state.title,
                        assets: state.assets,
                        startIndex: state.startIndex,
                        detailIdOverride: state.detailId,
                        cache: cache,
                        viewerToken: state.viewerToken
                    )
                }
                .overlay(alignment: .top) {
                    if let inlineToastText {
                        Text(inlineToastText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.72))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        )
                            .padding(.top, 64)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if showSkipReasonDialog {
                        Color.black.opacity(0.42)
                            .ignoresSafeArea()
                            .onTapGesture {
                                showSkipReasonDialog = false
                                skipTarget = nil
                            }
                        skipReasonDialogCard()
                            .padding(.horizontal, 18)
                    }
                }
            }
            .frame(width: contentW, height: contentH, alignment: .center)
            .rotationEffect(.degrees(rotationDegrees))
            .position(x: w * 0.5, y: h * 0.5)
            .statusBarHidden(isLandscape)
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshOrientation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                refreshOrientation()
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
    }

    private func submitSkip(_ reason: SkipReason, otherNote: String? = nil) {
        guard let item = skipTarget else { return }
        onSkip(item, reason, otherNote)
        showSkipReasonDialog = false
        skipTarget = nil
        skipOtherText = ""
    }

    private func skipReasonDialogCard() -> some View {
        VStack(spacing: 0) {
            Text("Skip Reason")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.blue)
                .padding(.top, 14)
                .padding(.bottom, 8)

            dialogDivider()
            dialogButton("Inaccessible") { submitSkip(.inaccessible) }
            dialogDivider()
            dialogButton("Obstructed") { submitSkip(.obstructed) }
            dialogDivider()
            dialogButton("Active construction") { submitSkip(.activeConstruction) }
            dialogDivider()
            dialogButton("Safety concern") { submitSkip(.safetyConcern) }
            dialogDivider()
            dialogButton("Other") {
                showSkipReasonDialog = false
                showSkipOtherSheet = true
            }
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .frame(maxWidth: 360)
    }

    private func dialogButton(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(destructive ? .red : .primary)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dialogDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
    }

    private func showImagePreview(localIdentifier: String?, title: String, detailId: String) {
        let trimmed = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }

        guard let asset = ContentView.reportAsset(from: trimmed) else { return }
        guidedViewerState = GuidedViewerState(
            title: title,
            detailId: detailId,
            assets: [asset],
            startIndex: 0,
            viewerToken: trimmed.hashValue
        )
    }

    private func showRetiredImagePreview(localIdentifier: String?, title: String, detailId: String) {
        let trimmed = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }

        guard let asset = ContentView.reportAsset(from: trimmed) ?? ContentView.reportAsset(fromPath: trimmed) else { return }
        retiredGuidedViewerState = GuidedViewerState(
            title: title,
            detailId: detailId,
            assets: [asset],
            startIndex: 0,
            viewerToken: trimmed.hashValue
        )
    }

    private func showGuidedReferencePreview(for guidedShot: GuidedShot) {
        guard let source = referencePathByID[guidedShot.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !source.isEmpty else {
            showInlineToast("No reference available")
            return
        }
        showImagePreview(
            localIdentifier: source,
            title: "Reference Image",
            detailId: guidedDisplayLabel(for: guidedShot)
        )
    }

    private func showGuidedCapturedPreview(for guidedShot: GuidedShot) {
        guard isCapturedInCurrentSession(guidedShot) else {
            showInlineToast("No captured image yet.")
            return
        }
        showImagePreview(
            localIdentifier: guidedShot.shot?.imageLocalIdentifier,
            title: "Captured Image",
            detailId: guidedDisplayLabel(for: guidedShot)
        )
    }

    private func showRetiredGuidedCapturedPreview(for guidedShot: GuidedShot) {
        let path = guidedShot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            showInlineToast("No captured image yet.")
            return
        }
        showRetiredImagePreview(
            localIdentifier: path,
            title: "Retired Image",
            detailId: guidedDisplayLabel(for: guidedShot)
        )
    }

    private func showInlineToast(_ text: String) {
        inlineToastText = text
        inlineToastToken += 1
        let token = inlineToastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard token == inlineToastToken else { return }
            inlineToastText = nil
        }
    }

    private func guidedDisplayLabel(for guidedShot: GuidedShot) -> String {
        let concise = ContentView.conciseContextLabel(
            building: guidedShot.building,
            elevation: guidedShot.targetElevation,
            detailType: guidedShot.detailType
        )
        if !concise.isEmpty { return concise }
        return guidedShot.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCapturedInCurrentSession(_ guidedShot: GuidedShot) -> Bool {
        guard let shot = guidedShot.shot else { return false }
        guard currentSessionShotIDs.contains(shot.id) else { return false }
        guard let startedAt = currentSessionStartedAt else { return false }
        if shot.capturedAt < startedAt {
            return false
        }
        if let endedAt = currentSessionEndedAt, shot.capturedAt > endedAt {
            return false
        }
        let path = shot.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, ContentView.reportAsset(from: path) != nil else {
            return false
        }
        return true
    }

    private func refreshOrientation() {
        let o = UIDevice.current.orientation
        let newValue: UIDeviceOrientation? = {
            switch o {
            case .portrait:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return o
            default:
                return nil
            }
        }()

        guard let newValue else { return }
        guard newValue != lastValidOrientation else { return }
        lastValidOrientation = newValue
    }

    private enum GuidedRetireReasonPreset: String, CaseIterable, Identifiable {
        case duplicate = "duplicate"
        case obstructedUnusable = "obstructed/unusable"
        case privacySensitive = "privacy/sensitive"
        case notRelevant = "not relevant"
        case accidentalCapture = "accidental capture"
        case other = "other"

        var id: String { rawValue }
        var title: String { rawValue }
    }

    private struct GuidedRetireReasonSheet: View {
        let guidedShot: GuidedShot
        let onCancel: () -> Void
        let onConfirm: (String) -> Void

        @State private var selectedReason: GuidedRetireReasonPreset = .notRelevant
        @State private var otherNote: String = ""

        private var normalizedOtherNote: String? {
            let trimmed = otherNote.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        private var retirementReason: String? {
            if selectedReason == .other {
                guard let normalizedOtherNote else { return nil }
                return "other: \(normalizedOtherNote)"
            }
            return selectedReason.rawValue
        }

        private var hasLinkedPhoto: Bool {
            guidedShot.shot != nil
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section {
                        Picker("Reason", selection: $selectedReason) {
                            ForEach(GuidedRetireReasonPreset.allCases) { reason in
                                Text(reason.title).tag(reason)
                            }
                        }
                        .pickerStyle(.inline)

                        if selectedReason == .other {
                            TextField("Required note", text: $otherNote, axis: .vertical)
                                .lineLimit(2...4)
                        }
                    } header: {
                        Text("Retirement Reason")
                    }

                    Section {
                        Text(hasLinkedPhoto
                             ? "This hides the guided checkpoint and linked photo from normal capture flow. The original file and SCOUT JSON are preserved."
                             : "This hides the guided checkpoint from normal capture flow. No photo is required to retire a checkpoint.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Retire Guided")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Retire", role: .destructive) {
                            if let retirementReason {
                                onConfirm(retirementReason)
                            }
                        }
                        .disabled(retirementReason == nil)
                    }
                }
            }
        }
    }
}

struct GuidedReassignSheet: View {
    let source: GuidedShot
    let candidates: [GuidedShot]
    let onCancel: () -> Void
    let onSelect: (UUID) -> Void

    private func label(for guidedShot: GuidedShot) -> String {
        let concise = ContentView.conciseContextLabel(
            building: guidedShot.building,
            elevation: guidedShot.targetElevation,
            detailType: guidedShot.detailType
        )
        return concise.isEmpty ? guidedShot.title : concise
    }

    var body: some View {
        NavigationStack {
            List(candidates) { candidate in
                Button {
                    onSelect(candidate.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(label(for: candidate))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                        Text("Angle \(max(1, candidate.angleIndex ?? 1))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Reassign To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Move photo association from")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(label(for: source))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)
                .background(Color(uiColor: .systemBackground))
            }
        }
    }
}

struct RetiredGuidedChecklistRow: View {
    let guidedShot: GuidedShot
    let resolvedThumbnailPath: String?
    let referencePath: String?
    let canRestore: Bool
    let refreshToken: UUID
    @ObservedObject var cache: AssetImageCache
    let onTapRestore: () -> Void
    let onTapViewCapturedImage: () -> Void

    @State private var thumbnail: UIImage? = nil
    @State private var loadedID: String = ""
    @State private var isThumbnailLoading: Bool = false

    private var title: String {
        let composed = ContentView.conciseContextLabel(
            building: guidedShot.building,
            elevation: guidedShot.targetElevation,
            detailType: guidedShot.detailType
        )
        if !composed.isEmpty { return composed }
        let fallback = guidedShot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Guided Shot" : fallback
    }

    private var retiredAtLabel: String? {
        guard let retiredAt = guidedShot.retiredAt else { return nil }
        return retiredAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var thumbnailPath: String? {
        let shotPath = guidedShot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !shotPath.isEmpty { return shotPath }

        let resolved = resolvedThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty { return resolved }

        let reference = referencePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reference.isEmpty ? nil : reference
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(retiredAtLabel.map { "Retired \($0)" } ?? "Retired")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if guidedShot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Button(action: onTapViewCapturedImage) {
                    Image(systemName: "photo")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }

            if canRestore {
                Button(action: onTapRestore) {
                    Text("Restore")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.green.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
        .onAppear {
            loadThumbnailIfNeeded()
        }
        .onChange(of: thumbnailPath ?? "") { _, _ in
            loadedID = ""
            thumbnail = nil
            loadThumbnailIfNeeded()
        }
        .onChange(of: refreshToken) { _, _ in
            loadedID = ""
            thumbnail = nil
            loadThumbnailIfNeeded()
        }
    }

    private var thumbnailView: some View {
        Group {
            if let image = thumbnail ?? cachedThumbnailForCurrentSource(pixelSize: max(120, 48 * UIScreen.currentScale * 2.0)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isThumbnailLoading {
                ZStack {
                    Color.orange.opacity(0.10)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.75)
                }
            } else {
                ZStack {
                    Color.orange.opacity(0.10)
                    Image(systemName: "archivebox")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private func loadThumbnailIfNeeded() {
        let source = thumbnailPath ?? ""
        guard source != loadedID || (thumbnail == nil && !isThumbnailLoading) else { return }
        loadedID = source

        guard !source.isEmpty, let asset = ContentView.reportAsset(from: source) ?? ContentView.reportAsset(fromPath: source) else {
            thumbnail = nil
            isThumbnailLoading = false
            return
        }

        let px = max(120, 48 * UIScreen.currentScale * 2.0)
        if let cached = cache.cachedThumbnail(for: asset, pixelSize: px) {
            thumbnail = cached
            isThumbnailLoading = false
            return
        }

        isThumbnailLoading = true
        cache.requestThumbnail(for: asset, pixelSize: px) { image in
            DispatchQueue.main.async {
                self.thumbnail = image
                self.isThumbnailLoading = false
            }
        }
    }

    private func cachedThumbnailForCurrentSource(pixelSize: CGFloat) -> UIImage? {
        let source = thumbnailPath ?? ""
        guard !source.isEmpty,
              let asset = ContentView.reportAsset(from: source) ?? ContentView.reportAsset(fromPath: source) else {
            return nil
        }
        return cache.cachedThumbnail(for: asset, pixelSize: pixelSize)
    }
}

struct GuidedChecklistRow: View {
    enum RowStatus {
        case pending
        case captured
        case skipped
    }

    let guidedShot: GuidedShot
    let resolvedThumbnailPath: String?
    let referencePath: String?
    let currentSessionID: UUID?
    let isBaselineSession: Bool
    let allowReferenceFallback: Bool
    let isCapturedInCurrentSession: Bool
    let canRetire: Bool
    let onTapRow: () -> Void
    let refreshToken: UUID
    @ObservedObject var cache: AssetImageCache
    let onTapSkip: () -> Void
    let onTapRetake: () -> Void
    let onTapUndoSkip: () -> Void
    let onTapViewReferenceImage: () -> Void
    let onTapViewCapturedImage: () -> Void
    let onTapRetire: () -> Void
    let onTapReclassify: () -> Void

    @State private var thumbnail: UIImage? = nil
    @State private var loadedID: String = ""
    @State private var isThumbnailLoading: Bool = false

    private var status: RowStatus {
        if isSkippedInCurrentSession { return .skipped }
        if isCapturedInCurrentSession { return .captured }
        return .pending
    }

    private var isSkippedInCurrentSession: Bool {
        guard let sessionID = currentSessionID else { return false }
        return guidedShot.skipReason != nil && guidedShot.skipSessionID == sessionID
    }

    private var statusLabel: String {
        switch status {
        case .pending: return "Pending"
        case .captured: return "Captured"
        case .skipped:
            return guidedShot.skipReason.map(skipReasonTitle(for:)) ?? "Skipped"
        }
    }

    private var statusColor: Color {
        switch status {
        case .pending: return .orange
        case .captured: return .green
        case .skipped: return .gray
        }
    }

    private var fullContextLabel: String {
        let composed = ContentView.conciseContextLabel(
            building: guidedShot.building,
            elevation: guidedShot.targetElevation,
            detailType: guidedShot.detailType
        )
        if !composed.isEmpty { return composed }
        let fallback = guidedShot.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Guided Shot" : fallback
    }

    private var angleLabel: String {
        "Angle \(max(1, guidedShot.angleIndex ?? 1))"
    }

    private var hasReferenceImage: Bool {
        let resolvedReferencePath = referencePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !resolvedReferencePath.isEmpty
    }

    private var thumbnailPath: String? {
        let shotPath = guidedShot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isCapturedInCurrentSession, !shotPath.isEmpty {
            return shotPath
        }

        let resolved = resolvedThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty {
            return resolved
        }

        let reference = referencePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return reference.isEmpty ? nil : reference
    }

    var body: some View {
        rowContent
        .onTapGesture {
            guard status == .pending else { return }
            onTapRow()
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if canRetire {
                Button {
                    onTapRetire()
                } label: {
                    Label("Retire", systemImage: "archivebox")
                }
                .tint(.red)
            }

            Button {
                onTapReclassify()
            } label: {
                Label("Reclassify", systemImage: "arrow.triangle.2.circlepath")
            }
            .tint(.mint)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if status == .captured {
                Button {
                    onTapRetake()
                } label: {
                    Label("Retake", systemImage: "camera.rotate")
                }
                .tint(.orange)

                if !isBaselineSession && hasReferenceImage {
                    Button {
                        onTapViewReferenceImage()
                    } label: {
                        Label("View Reference", systemImage: "photo.on.rectangle")
                    }
                    .tint(.indigo)
                }

                Button {
                    onTapViewCapturedImage()
                } label: {
                    Label("View Captured", systemImage: "photo")
                }
                .tint(.blue)
            } else if !isBaselineSession && hasReferenceImage {
                Button {
                    onTapViewReferenceImage()
                } label: {
                    Label("View Reference", systemImage: "photo.on.rectangle")
                }
                .tint(.indigo)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .listRowBackground(Color.clear)
        .onAppear {
            loadThumbnailIfNeeded()
        }
        .onChange(of: guidedShot.shot?.imageLocalIdentifier ?? "") { _, _ in
            loadThumbnailIfNeeded()
        }
        .onChange(of: guidedShot.referenceImageLocalIdentifier ?? "") { _, _ in
            loadThumbnailIfNeeded()
        }
        .onChange(of: guidedShot.referenceImagePath ?? "") { _, _ in
            loadThumbnailIfNeeded()
        }
        .onChange(of: resolvedThumbnailPath ?? "") { _, _ in
            loadThumbnailIfNeeded()
        }
        .onChange(of: currentSessionID) { _, _ in
            loadedID = ""
            thumbnail = nil
            loadThumbnailIfNeeded()
        }
        .onChange(of: isCapturedInCurrentSession) { _, _ in
            loadThumbnailIfNeeded()
        }
        .onChange(of: refreshToken) { _, _ in
            loadedID = ""
            thumbnail = nil
            loadThumbnailIfNeeded()
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            thumbnailView
            textView
            Spacer(minLength: 0)
            trailingActions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var thumbnailView: some View {
        Group {
            if let image = thumbnail ?? cachedThumbnailForCurrentSource(pixelSize: max(120, 56 * UIScreen.currentScale * 2.0)) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isThumbnailLoading {
                ZStack {
                    Color.white.opacity(0.08)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.9))
                        .scaleEffect(0.8)
                }
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "photo")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if status == .captured {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
                    .padding(4)
            }
        }
    }

    private var textView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(fullContextLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(1)

            Text(angleLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.86))

            Text(statusLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor)

            if status == .skipped {
                Button {
                    onTapUndoSkip()
                } label: {
                    Text("Undo Skip")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var trailingActions: some View {
        switch status {
        case .pending:
            if !isBaselineSession {
                Button(action: onTapSkip) {
                    Text("Skip")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
        case .skipped:
            EmptyView()
        case .captured:
            EmptyView()
        }
    }

    private func loadThumbnailIfNeeded() {
        let sessionIDText = currentSessionID?.uuidString ?? "NONE"
        let chosenPath = thumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceID = "chosen:\(sessionIDText):\(chosenPath)"
        guard sourceID != loadedID || (thumbnail == nil && !isThumbnailLoading) else { return }
        loadedID = sourceID

        guard !chosenPath.isEmpty else {
            thumbnail = nil
            isThumbnailLoading = false
            return
        }

        if let asset = ContentView.reportAsset(fromPath: chosenPath) {
            let px = max(120, 56 * UIScreen.currentScale * 2.0)
            if let cached = cache.cachedThumbnail(for: asset, pixelSize: px) {
                thumbnail = cached
                isThumbnailLoading = false
                return
            }

            isThumbnailLoading = true
            cache.requestThumbnail(for: asset, pixelSize: px) { image in
                DispatchQueue.main.async {
                    self.thumbnail = image
                    self.isThumbnailLoading = false
                    if image == nil {
                        verboseLog("[GuidedThumbLoad] sessionID=\(sessionIDText) guidedID=\(guidedShot.id.uuidString) outcome=decodeNil path=\(chosenPath)")
                    }
                }
            }
            return
        }

        isThumbnailLoading = true
        DispatchQueue.global(qos: .utility).async {
            ContentView.requestUbiquitousDownloadIfNeeded(path: chosenPath)
            let maxAttempts = 75
            for attempt in 0..<maxAttempts {
                if FileManager.default.fileExists(atPath: chosenPath) { break }
                if attempt % 5 == 0 {
                    ContentView.requestUbiquitousDownloadIfNeeded(path: chosenPath)
                }
                Thread.sleep(forTimeInterval: 0.20)
            }
            DispatchQueue.main.async {
                guard self.loadedID == sourceID else { return }
                guard let asset = ContentView.reportAsset(fromPath: chosenPath) else {
                    self.thumbnail = nil
                    self.isThumbnailLoading = false
                    verboseLog("[GuidedThumbLoad] sessionID=\(sessionIDText) guidedID=\(guidedShot.id.uuidString) outcome=fileUnavailable path=\(chosenPath)")
                    return
                }
                let px = max(120, 56 * UIScreen.currentScale * 2.0)
                cache.requestThumbnail(for: asset, pixelSize: px) { image in
                    DispatchQueue.main.async {
                        self.thumbnail = image
                        self.isThumbnailLoading = false
                        if image == nil {
                            verboseLog("[GuidedThumbLoad] sessionID=\(sessionIDText) guidedID=\(guidedShot.id.uuidString) outcome=postDownloadDecodeNil path=\(chosenPath)")
                        }
                    }
                }
            }
        }
    }

    private func skipReasonTitle(for reason: SkipReason) -> String {
        switch reason {
        case .inaccessible: return "Skipped - Inaccessible"
        case .obstructed: return "Skipped - Obstructed"
        case .activeConstruction: return "Skipped - Active construction"
        case .safetyConcern: return "Skipped - Safety concern"
        case .other: return "Skipped - Other"
        case .notVisible: return "Skipped - Not visible"
        case .unsafe: return "Skipped - Unsafe"
        case .blocked: return "Skipped - Blocked"
        case .notApplicable: return "Skipped - Not applicable"
        }
    }

    private func cachedThumbnailForCurrentSource(pixelSize: CGFloat) -> UIImage? {
        let chosenPath = thumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !chosenPath.isEmpty,
              let asset = ContentView.reportAsset(from: chosenPath) ?? ContentView.reportAsset(fromPath: chosenPath) else {
            return nil
        }
        return cache.cachedThumbnail(for: asset, pixelSize: pixelSize)
    }
}

struct ActiveIssuesSheet: View {
    enum Mode {
        case activeIssues
        case resolutionRequired

        var title: String {
            switch self {
            case .activeIssues:
                return "Active Issues"
            case .resolutionRequired:
                return "Resolution Required"
            }
        }

        var emptyIcon: String {
            switch self {
            case .activeIssues:
                return "flag.slash"
            case .resolutionRequired:
                return "flag.checkered"
            }
        }

        var emptyText: String {
            switch self {
            case .activeIssues:
                return "No active issues"
            case .resolutionRequired:
                return "No resolution required"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let mode: Mode
    let observations: [Observation]
    let isHydrating: Bool
    let currentSessionID: UUID?
    let sessionShotIDs: Set<UUID>
    let resolvedThumbnailPathByID: [UUID: String]
    let referencePathByID: [UUID: String]
    let angleIndexByIssueID: [UUID: Int]
    let allowReferenceFallback: Bool
    let captureProfile: CaptureProfile
    let tradeOptions: [String]
    @Binding var buildingOptions: [String]
    @ObservedObject var detailTypesModel: DetailTypesModel
    let buildingCodeForOption: (String) -> String
    let buildingDisplayNameForOption: (String) -> String
    let cache: AssetImageCache
    let onClose: () -> Void
    let onSelectIssue: (Observation) -> Void
    let onRetakeIssue: (Observation) -> Void
    let onReclassifyIssue: (Observation, String, String, String) -> Void
    var onReopenIssue: ((Observation) -> Void)? = nil
    let loadPortalNotes: ([Observation], [UUID: Int]) async -> [UUID: [PortalPunchlistNote]]
    @State private var lastValidOrientation: UIDeviceOrientation = .portrait
    @State private var reclassifyTargetObservation: Observation? = nil
    @State private var historyTargetObservation: Observation? = nil
    @State private var portalNotesTargetObservation: Observation? = nil
    @State private var reopenConfirmationTargetObservation: Observation? = nil
    @State private var portalNoteCountByIssueID: [UUID: Int] = [:]
    @State private var flaggedViewerState: FlaggedViewerState? = nil
    @State private var inlineToastText: String? = nil
    @State private var inlineToastToken: Int = 0

    private var theme: ContentView.SheetControlTheme { .forScheme(colorScheme) }

    private struct FlaggedViewerState: Identifiable {
        let id = UUID()
        let title: String
        let detailId: String
        let asset: ReportAsset
        let viewerToken: Int
        let metadataPropertyID: UUID?
        let metadataSessionID: UUID?
    }

    private var isLandscape: Bool {
        lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight
    }

    private var rotationDegrees: Double {
        switch lastValidOrientation {
        case .landscapeLeft:
            return 90
        case .landscapeRight:
            return -90
        default:
            return 0
        }
    }

    private var issueIDSignature: String {
        observations
            .map { $0.id.uuidString }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let contentW = isLandscape ? h : w
            let contentH = isLandscape ? w : h

            NavigationStack {
                ZStack {
                    Color(uiColor: .secondarySystemGroupedBackground)
                        .ignoresSafeArea()

                    if observations.isEmpty && isHydrating {
                        VStack(spacing: 10) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.secondary)
                            Text("Loading")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if observations.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: mode.emptyIcon)
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(.secondary)
                            Text(mode.emptyText)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(observations) { observation in
                            FlaggedIssueRow(
                                observation: observation,
                                currentSessionID: currentSessionID,
                                resolvedThumbnailPath: resolvedThumbnailPathByID[observation.id],
                                angleIndex: angleIndexByIssueID[observation.id],
                                tradeOptions: tradeOptions,
                                mode: mode,
                                cache: cache,
                                portalNoteCount: portalNoteCountByIssueID[observation.id, default: 0],
                                hasReferenceImage: referenceImageLocalID(for: observation) != nil,
                                hasCapturedImage: capturedImageLocalID(for: observation) != nil,
                                canRetake: canRetakeObservation(observation),
                                onTapRow: {
                                    closeImmediately()
                                    DispatchQueue.main.async {
                                        onSelectIssue(observation)
                                    }
                                },
                                onTapRetake: {
                                    closeImmediately()
                                    DispatchQueue.main.async {
                                        onRetakeIssue(observation)
                                    }
                                },
                                onTapViewReferenceImage: {
                                    showIssueImagePreview(observation, isCaptured: false)
                                },
                                onTapViewCapturedImage: {
                                    showIssueImagePreview(observation, isCaptured: true)
                                },
                                onTapReclassify: {
                                    reclassifyTargetObservation = observation
                                },
                                onTapReopen: {
                                    reopenConfirmationTargetObservation = observation
                                },
                                onTapHistory: {
                                    historyTargetObservation = observation
                                },
                                onTapPortalNotes: {
                                    portalNotesTargetObservation = observation
                                }
                            )
                        }
                        .listStyle(.insetGrouped)
                        .scrollIndicators(.hidden)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                    }
                }
                .overlay(alignment: .top) {
                    if isHydrating && !observations.isEmpty {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.secondary)
                            .scaleEffect(0.82)
                            .padding(8)
                            .background(.thinMaterial)
                            .clipShape(Circle())
                            .padding(.top, 66)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ZStack {
                        Text(mode.title)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(theme.label)
                            .minimumScaleFactor(0.75)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .center)

                        HStack(spacing: 10) {
                            Spacer(minLength: 0)

                            Button(action: closeImmediately) {
                                Text("Done")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 72, height: 42)
                                    .background(theme.fill)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(theme.stroke, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                .sheet(item: $reclassifyTargetObservation) { target in
                    ChecklistReclassifySheet(
                        title: "Reclassify",
                        initialBuilding: target.building,
                        initialElevation: target.targetElevation,
                        initialDetailType: target.detailType,
                        captureProfile: captureProfile,
                        buildingOptions: $buildingOptions,
                        detailTypesModel: detailTypesModel,
                        buildingCodeForOption: buildingCodeForOption,
                        buildingDisplayNameForOption: buildingDisplayNameForOption,
                        onCancel: {
                            reclassifyTargetObservation = nil
                        },
                        onConfirm: { building, elevation, detailType in
                            onReclassifyIssue(target, building, elevation, detailType)
                            reclassifyTargetObservation = nil
                        }
                    )
                }
                .sheet(item: $historyTargetObservation) { target in
                    FlaggedHistorySheet(observation: target, tradeOptions: tradeOptions)
                }
                .sheet(item: $portalNotesTargetObservation) { target in
                    PortalIssueNotesSheet(
                        observation: target,
                        resolvedThumbnailPath: resolvedThumbnailPathByID[target.id],
                        angleIndex: angleIndexByIssueID[target.id],
                        cache: cache,
                        loadPortalNotes: loadPortalNotes
                    )
                }
                .alert("Reopen Issue?", isPresented: reopenConfirmationBinding) {
                    Button("Cancel", role: .cancel) {
                        reopenConfirmationTargetObservation = nil
                    }
                    Button("Reopen") {
                        guard let target = reopenConfirmationTargetObservation else { return }
                        reopenConfirmationTargetObservation = nil
                        closeImmediately()
                        DispatchQueue.main.async {
                            onReopenIssue?(target)
                        }
                    }
                } message: {
                    Text("This will move the item back to Active Issues.")
                }
                .overlay(alignment: .top) {
                    if let inlineToastText {
                        Text(inlineToastText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.black.opacity(0.72))
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
                            )
                            .padding(.top, 64)
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: contentW, height: contentH, alignment: .center)
            .rotationEffect(.degrees(rotationDegrees))
            .position(x: w * 0.5, y: h * 0.5)
            .statusBarHidden(isLandscape)
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshOrientation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                refreshOrientation()
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            .task(id: issueIDSignature) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                await refreshPortalNoteCounts()
            }
        }
        .fullScreenCover(item: $flaggedViewerState) { state in
            ReportPhotoViewer(
                title: state.title,
                assets: [state.asset],
                startIndex: 0,
                detailIdOverride: state.detailId,
                metadataPropertyID: state.metadataPropertyID,
                metadataSessionID: state.metadataSessionID,
                cache: cache,
                viewerToken: state.viewerToken
            )
        }
    }

    private var reopenConfirmationBinding: Binding<Bool> {
        Binding(
            get: { reopenConfirmationTargetObservation != nil },
            set: { isPresented in
                if !isPresented {
                    reopenConfirmationTargetObservation = nil
                }
            }
        )
    }

    private func referenceImageLocalID(for observation: Observation) -> String? {
        guard allowReferenceFallback else { return nil }
        let id = referencePathByID[observation.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    private func capturedImageLocalID(for observation: Observation) -> String? {
        guard let linkedID = observation.linkedShotID else { return nil }
        guard LocalConflictRules.issueLinkedShotIsCurrentSessionCapture(
            linkedShotID: linkedID,
            updatedInSessionID: observation.updatedInSessionID,
            resolvedInSessionID: observation.resolvedInSessionID,
            currentSessionID: currentSessionID,
            currentSessionShotIDs: sessionShotIDs
        ) else {
            return nil
        }
        let id = observation.shots.first(where: { $0.id == linkedID })?.imageLocalIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    private func canRetakeObservation(_ observation: Observation) -> Bool {
        guard let currentSessionID else { return false }
        let hasCurrentSessionCapture = observation.updatedInSessionID == currentSessionID || observation.resolvedInSessionID == currentSessionID
        guard hasCurrentSessionCapture else { return false }
        guard let linkedID = observation.linkedShotID else { return false }
        return sessionShotIDs.contains(linkedID)
    }

    private func showIssueImagePreview(_ observation: Observation, isCaptured: Bool) {
        let localID = (isCaptured ? capturedImageLocalID(for: observation) : referenceImageLocalID(for: observation)) ?? ""
        let trimmed = localID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showInlineToast(isCaptured ? "No captured image yet." : "No reference available")
            return
        }

        guard let asset = ContentView.reportAsset(from: trimmed) else {
            showInlineToast(isCaptured ? "No captured image yet." : "No reference available")
            return
        }

        flaggedViewerState = FlaggedViewerState(
            title: isCaptured ? "Captured Image" : "Reference Image",
            detailId: ContentView.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            ),
            asset: asset,
            viewerToken: trimmed.hashValue,
            metadataPropertyID: observation.propertyID,
            metadataSessionID: metadataSessionID(for: observation, isCaptured: isCaptured)
        )
    }

    private func metadataSessionID(for observation: Observation, isCaptured: Bool) -> UUID? {
        if isCaptured {
            return observation.updatedInSessionID
                ?? observation.resolvedInSessionID
                ?? currentSessionID
                ?? observation.sessionID
        }
        return observation.sessionID
            ?? observation.updatedInSessionID
            ?? currentSessionID
    }

    private func refreshPortalNoteCounts() async {
        let issueIDs = Set(observations.map(\.id))
        guard !issueIDs.isEmpty else {
            portalNoteCountByIssueID = [:]
            return
        }
        let notesByIssueID = await loadPortalNotes(observations, angleIndexByIssueID)
        guard !Task.isCancelled else { return }
        portalNoteCountByIssueID = notesByIssueID.reduce(into: [UUID: Int]()) { partial, item in
            let count = item.value.count
            if count > 0 {
                partial[item.key] = count
            }
        }
    }

    private func showInlineToast(_ text: String) {
        inlineToastText = text
        inlineToastToken += 1
        let token = inlineToastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard token == inlineToastToken else { return }
            inlineToastText = nil
        }
    }

    private func closeImmediately() {
        dismiss()
        DispatchQueue.main.async {
            onClose()
        }
    }

    private struct FlaggedReassignSheet: View {
        let source: Observation
        let candidates: [Observation]
        let onCancel: () -> Void
        let onSelect: (UUID) -> Void

        private func label(for observation: Observation) -> String {
            let concise = ContentView.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            )
            return concise.isEmpty ? (ContentView.observationCurrentReasonText(observation) ?? observation.statement) : concise
        }

        var body: some View {
            NavigationStack {
                List(candidates) { candidate in
                    Button {
                        onSelect(candidate.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(label(for: candidate))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.primary)
                            Text(ContentView.observationCurrentReasonText(candidate) ?? candidate.statement)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
                .navigationTitle("Reassign To")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel", action: onCancel)
                    }
                }
            }
        }
    }

    private struct FlaggedHistorySheet: View {
        @Environment(\.dismiss) private var dismiss
        let observation: Observation
        let tradeOptions: [String]

        private var rawEvents: [ObservationHistoryEvent] {
            observation.historyEvents.sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
        }

        private var normalizedPriority: String {
            ContentView.normalizedPriority(observation.priority)
        }

        private var normalizedTrade: String {
            ContentView.canonicalTradeLabel(observation.trade, preferredOptions: tradeOptions)
        }

        private var events: [ContentView.FlaggedHistoryDisplayEvent] {
            var displayEvents: [ContentView.FlaggedHistoryDisplayEvent] = []
            let captures = rawEvents.filter { $0.kind == .captured || $0.kind == .retake }
            let reasonsByShotID = Dictionary(
                uniqueKeysWithValues: rawEvents.compactMap { event -> (UUID, ObservationHistoryEvent)? in
                    guard event.kind == .reasonUpdated, let shotID = event.shotID else { return nil }
                    return (shotID, event)
                }
            )
            let createdEvent = rawEvents.first(where: { $0.kind == .created })
            if let createdEvent {
                displayEvents.append(
                    ContentView.FlaggedHistoryDisplayEvent(
                        id: createdEvent.id.uuidString,
                        title: "Created",
                        timestamp: createdEvent.timestamp,
                        previousReason: nil,
                        currentReason: createdEvent.afterValue
                    )
                )
            }

            for capture in captures {
                if let createdEvent,
                   capture.timestamp == createdEvent.timestamp,
                   capture.shotID == createdEvent.shotID {
                    continue
                }
                let reasonEvent = capture.shotID.flatMap { reasonsByShotID[$0] }
                displayEvents.append(
                    ContentView.FlaggedHistoryDisplayEvent(
                        id: capture.id.uuidString,
                        title: "Follow-Up Captured",
                        timestamp: capture.timestamp,
                        previousReason: reasonEvent?.beforeValue,
                        currentReason: reasonEvent?.afterValue
                    )
                )
            }

            return displayEvents.sorted { $0.timestamp > $1.timestamp }
        }

        var body: some View {
            NavigationStack {
                List {
                    if !normalizedPriority.isEmpty || !normalizedTrade.isEmpty {
                        Section("Details") {
                            HStack(spacing: 12) {
                                if !normalizedPriority.isEmpty {
                                    Label(normalizedPriority, systemImage: "exclamationmark.circle.fill")
                                }
                                if !normalizedTrade.isEmpty {
                                    Label(normalizedTrade, systemImage: "wrench.adjustable")
                                }
                            }
                            .font(.system(size: 14, weight: .medium))
                        }
                    }

                    if let currentReason = ContentView.observationCurrentReasonText(observation) {
                        Section("Current Reason") {
                            Text(currentReason)
                                .font(.system(size: 14, weight: .medium))
                        }
                    }

                    Section("History") {
                        if events.isEmpty {
                            Text("No history yet")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(events) { event in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(event.title)
                                            .font(.system(size: 15, weight: .semibold))
                                        Spacer(minLength: 0)
                                        Text(ContentView.formatObservationHistoryTimestamp(event.timestamp))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.secondary)
                                    }

                                    if let previousReason = event.previousReason {
                                        Text("Previous Reason: \(previousReason)")
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundColor(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    if let currentReason = event.currentReason {
                                        Text("Current Reason: \(currentReason)")
                                            .font(.system(size: 13, weight: .regular))
                                            .foregroundColor(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .navigationTitle("Issue History")
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

    private struct PortalIssueNotesSheet: View {
        @Environment(\.dismiss) private var dismiss
        let observation: Observation
        let resolvedThumbnailPath: String?
        let angleIndex: Int?
        let cache: AssetImageCache
        let loadPortalNotes: ([Observation], [UUID: Int]) async -> [UUID: [PortalPunchlistNote]]

        @State private var notes: [PortalPunchlistNote]? = nil

        private var title: String {
            let composed = ContentView.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            )
            return composed.isEmpty ? "Portal Notes" : composed
        }

        var body: some View {
            NavigationStack {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        PortalIssuePhotoPreview(
                            imagePath: resolvedThumbnailPath,
                            cache: cache
                        )
                        .frame(height: geo.size.height * 0.48)
                        .frame(maxWidth: .infinity)
                        .background(Color.black)

                        notesContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
            .task(id: observation.id) {
                let angleMap = angleIndex.map { [observation.id: $0] } ?? [:]
                let loaded = await loadPortalNotes([observation], angleMap)
                guard !Task.isCancelled else { return }
                notes = loaded[observation.id] ?? []
            }
        }

        @ViewBuilder
        private var notesContent: some View {
            if let notes {
                if notes.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "note.text")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("No portal notes")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(notes) { note in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Label(
                                            note.isCompletionNote ? "Completion Note" : "Portal Note",
                                            systemImage: note.isCompletionNote ? "checkmark.seal" : "note.text"
                                        )
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.secondary)

                                        Spacer(minLength: 0)

                                        if let createdAt = note.createdAt {
                                            Text(ContentView.formatObservationHistoryTimestamp(createdAt))
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Text(note.note)
                                        .font(.system(size: 15, weight: .regular))
                                        .foregroundColor(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                            }
                        }
                        .padding(14)
                    }
                    .scrollIndicators(.visible)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading notes")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private struct PortalIssuePhotoPreview: View {
        let imagePath: String?
        let cache: AssetImageCache
        @State private var image: UIImage? = nil
        @State private var loadedPath: String = ""
        @State private var isLoading: Bool = false

        var body: some View {
            ZStack {
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white.opacity(0.9))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 28, weight: .medium))
                        Text("No photo preview")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.58))
                }
            }
            .onAppear { loadImageIfNeeded() }
            .onChange(of: imagePath ?? "") { _, _ in
                loadedPath = ""
                image = nil
                loadImageIfNeeded()
            }
        }

        private func loadImageIfNeeded() {
            let path = imagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty else {
                image = nil
                loadedPath = ""
                isLoading = false
                return
            }
            guard path != loadedPath || (image == nil && !isLoading) else { return }
            loadedPath = path

            guard let asset = ContentView.reportAsset(from: path) else {
                isLoading = false
                return
            }
            isLoading = true
            cache.requestFull(for: asset) { loadedImage in
                DispatchQueue.main.async {
                    guard self.loadedPath == path else { return }
                    self.image = loadedImage
                    self.isLoading = false
                }
            }
        }
    }

    private struct FlaggedIssueRow: View {
        let observation: Observation
        let currentSessionID: UUID?
        let resolvedThumbnailPath: String?
        let angleIndex: Int?
        let tradeOptions: [String]
        let mode: ActiveIssuesSheet.Mode
        let cache: AssetImageCache
        let portalNoteCount: Int
        let hasReferenceImage: Bool
        let hasCapturedImage: Bool
        let canRetake: Bool
        let onTapRow: () -> Void
        let onTapRetake: () -> Void
        let onTapViewReferenceImage: () -> Void
        let onTapViewCapturedImage: () -> Void
        let onTapReclassify: () -> Void
        let onTapReopen: () -> Void
        let onTapHistory: () -> Void
        let onTapPortalNotes: () -> Void

        @State private var thumbnail: UIImage? = nil
        @State private var loadedID: String = ""
        @State private var isThumbnailLoading: Bool = false

        private var contextLabel: String {
            let composed = ContentView.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            )
            return composed.isEmpty ? "Flagged Issue" : composed
        }

        private var statusLabel: String {
            let angleSuffix: String = {
                guard let angleIndex else { return "" }
                return " - Angle \(max(1, angleIndex))"
            }()
            let currentSessionEvents = observation.historyEvents.filter { $0.sessionID == currentSessionID }
            let hasCurrentSessionCaptureEvent = currentSessionEvents.contains {
                $0.kind == .captured || $0.kind == .retake
            }
            let hasCurrentSessionReclassifyEvent = currentSessionEvents.contains { $0.kind == .reclassified }
            if observation.status == .resolutionRequired {
                return "Resolution Required\(angleSuffix)"
            }
            if observation.status == .pendingReview {
                return "Pending Review\(angleSuffix)"
            }
            if observation.resolvedInSessionID == currentSessionID {
                return "Resolved\(angleSuffix)"
            }
            if observation.updatedInSessionID == currentSessionID {
                if hasCurrentSessionCaptureEvent && observation.sessionID == currentSessionID {
                    return "Active - Captured\(angleSuffix)"
                }
                if hasCurrentSessionCaptureEvent {
                    return "Active - Update Captured\(angleSuffix)"
                }
                if hasCurrentSessionReclassifyEvent {
                    return "Active - Reclassified\(angleSuffix)"
                }
                return "Active - Updated\(angleSuffix)"
            }
            return "Active\(angleSuffix)"
        }

        private var statusColor: Color {
            if observation.status == .resolutionRequired {
                return .green
            }
            if observation.status == .pendingReview {
                return .blue
            }
            if observation.resolvedInSessionID == currentSessionID {
                return .green
            }
            let currentSessionEvents = observation.historyEvents.filter { $0.sessionID == currentSessionID }
            let hasCurrentSessionCaptureEvent = currentSessionEvents.contains {
                $0.kind == .captured || $0.kind == .retake
            }
            if observation.updatedInSessionID == currentSessionID && hasCurrentSessionCaptureEvent {
                return .green
            }
            return .orange
        }

        private var reasonText: String {
            ContentView.observationCurrentReasonText(observation) ?? "No reason"
        }

        private var normalizedPriority: String {
            ContentView.normalizedPriority(observation.priority)
        }

        private var normalizedTrade: String {
            ContentView.canonicalTradeLabel(observation.trade, preferredOptions: tradeOptions)
        }

        var body: some View {
            HStack(spacing: 12) {
                thumbnailView

                VStack(alignment: .leading, spacing: 4) {
                    Text(contextLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(observation.status == .resolved ? .secondary : .primary)
                        .lineLimit(1)

                    Text(statusLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(statusColor)

                    if !normalizedPriority.isEmpty || !normalizedTrade.isEmpty {
                        HStack(spacing: 8) {
                            if !normalizedPriority.isEmpty {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(ContentView.priorityColor(normalizedPriority))
                                        .frame(width: 8, height: 8)
                                    Text(normalizedPriority)
                                }
                            }
                            if !normalizedTrade.isEmpty {
                                HStack(spacing: 5) {
                                    Image(systemName: "wrench.adjustable")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(normalizedTrade)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    }

                    Text("\(Text("Reason: ").font(.system(size: 12, weight: .semibold)))\(Text(reasonText).font(.system(size: 12, weight: .regular)))")
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if mode == .resolutionRequired {
                    VStack(spacing: 6) {
                        if portalNoteCount > 0 {
                            portalNotesButton
                        }
                        reopenButton
                    }
                } else if portalNoteCount > 0 {
                    portalNotesButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .opacity(observation.status == .resolved ? 0.70 : 1.0)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .listRowBackground(Color.clear)
            .onTapGesture {
                guard observation.status == .active || observation.status == .resolutionRequired else { return }
                guard mode == .resolutionRequired || !canRetake else { return }
                onTapRow()
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button {
                    onTapHistory()
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tint(.blue)

                Button {
                    onTapReclassify()
                } label: {
                    Label("Reclassify", systemImage: "arrow.triangle.2.circlepath")
                }
                .tint(.mint)

                if mode == .resolutionRequired {
                    Button {
                        onTapReopen()
                    } label: {
                        Label("Reopen as Active", systemImage: "arrow.uturn.backward")
                    }
                    .tint(.orange)
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if mode == .resolutionRequired {
                    Button {
                        onTapRow()
                    } label: {
                        Label("Capture Resolution Photo", systemImage: "camera")
                    }
                    .tint(.green)
                } else if canRetake {
                    Button {
                        onTapRetake()
                    } label: {
                        Label("Retake", systemImage: "camera.rotate")
                    }
                    .tint(.orange)

                    if hasReferenceImage {
                        Button {
                            onTapViewReferenceImage()
                        } label: {
                            Label("View Reference", systemImage: "photo.on.rectangle")
                        }
                        .tint(.indigo)
                    }

                    Button {
                        onTapViewCapturedImage()
                    } label: {
                        Label("View Captured", systemImage: "photo")
                    }
                    .tint(.blue)
                } else if hasReferenceImage {
                    Button {
                        onTapViewReferenceImage()
                    } label: {
                        Label("View Reference", systemImage: "photo.on.rectangle")
                    }
                    .tint(.indigo)
                }
            }
            .onAppear { loadThumbnailIfNeeded() }
            .onChange(of: observation.linkedShotID) { _, _ in
                loadThumbnailIfNeeded()
            }
            .onChange(of: observation.updatedInSessionID) { _, _ in
                loadThumbnailIfNeeded()
            }
            .onChange(of: observation.resolvedInSessionID) { _, _ in
                loadThumbnailIfNeeded()
            }
            .onChange(of: observation.shots.count) { _, _ in
                loadThumbnailIfNeeded()
            }
            .onChange(of: resolvedThumbnailPath ?? "") { _, _ in
                loadedID = ""
                thumbnail = nil
                loadThumbnailIfNeeded()
            }
        }

        private var reopenButton: some View {
            Button(action: onTapReopen) {
                Text("Reopen")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Color.orange.opacity(0.13))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }

        private var portalNotesButton: some View {
            Button(action: onTapPortalNotes) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "note.text")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .frame(width: 38, height: 38)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Circle())
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )

                    Text(portalNoteCount > 99 ? "99+" : "\(portalNoteCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(minWidth: 17, minHeight: 17)
                        .padding(.horizontal, portalNoteCount > 9 ? 3 : 0)
                        .background(Color.orange)
                        .clipShape(Capsule())
                        .offset(x: 5, y: -5)
                }
                .frame(width: 46, height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Portal notes")
            .accessibilityValue("\(portalNoteCount)")
        }

        private var thumbnailView: some View {
            Group {
                if let image = thumbnail ?? cachedThumbnailForCurrentSource(pixelSize: max(120, 56 * UIScreen.currentScale * 2.0)) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isThumbnailLoading {
                    ZStack {
                        Color.white.opacity(0.08)
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white.opacity(0.9))
                            .scaleEffect(0.8)
                    }
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "photo")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if hasCapturedImage {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 1)
                        .padding(4)
                }
            }
        }

        private func loadThumbnailIfNeeded() {
            let shotKey = ShotMetadata.makeShotKey(
                building: observation.building ?? "",
                elevation: observation.targetElevation ?? "",
                detailType: observation.detailType ?? "",
                angleIndex: 1
            )
            let linkedIDText = observation.linkedShotID?.uuidString ?? "NONE"
            verboseLog("[FlagRow] rowID=\(observation.id.uuidString) issueID=\(observation.id.uuidString) shotID=\(linkedIDText) shotKey=\(shotKey)")
            let chosenID = resolvedThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !chosenID.isEmpty else {
                thumbnail = nil
                loadedID = ""
                isThumbnailLoading = false
                return
            }
            guard chosenID != loadedID || (thumbnail == nil && !isThumbnailLoading) else { return }
            loadedID = chosenID

            if let asset = ContentView.reportAsset(from: chosenID) {
                let px = max(120, 56 * UIScreen.currentScale * 2.0)
                if let cached = cache.cachedThumbnail(for: asset, pixelSize: px) {
                    thumbnail = cached
                    isThumbnailLoading = false
                    return
                }

                isThumbnailLoading = true
                cache.requestThumbnail(for: asset, pixelSize: px) { image in
                    DispatchQueue.main.async {
                        self.thumbnail = image
                        self.isThumbnailLoading = false
                    }
                }
                return
            }

            isThumbnailLoading = true
            DispatchQueue.global(qos: .utility).async {
                ContentView.requestUbiquitousDownloadIfNeeded(path: chosenID)
                let maxAttempts = 75
                for attempt in 0..<maxAttempts {
                    if FileManager.default.fileExists(atPath: chosenID) { break }
                    if attempt % 5 == 0 {
                        ContentView.requestUbiquitousDownloadIfNeeded(path: chosenID)
                    }
                    Thread.sleep(forTimeInterval: 0.20)
                }
                DispatchQueue.main.async {
                    guard self.loadedID == chosenID else { return }
                    guard let asset = ContentView.reportAsset(from: chosenID) else {
                        self.thumbnail = nil
                        self.isThumbnailLoading = false
                        return
                    }
                    let px = max(120, 56 * UIScreen.currentScale * 2.0)
                    if let cached = cache.cachedThumbnail(for: asset, pixelSize: px) {
                        self.thumbnail = cached
                        self.isThumbnailLoading = false
                        return
                    }

                    cache.requestThumbnail(for: asset, pixelSize: px) { image in
                        DispatchQueue.main.async {
                            self.thumbnail = image
                            self.isThumbnailLoading = false
                        }
                    }
                }
            }
        }

        private func cachedThumbnailForCurrentSource(pixelSize: CGFloat) -> UIImage? {
            let chosenID = resolvedThumbnailPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !chosenID.isEmpty,
                  let asset = ContentView.reportAsset(from: chosenID) else {
                return nil
            }
            return cache.cachedThumbnail(for: asset, pixelSize: pixelSize)
        }
    }

    private func refreshOrientation() {
        let o = UIDevice.current.orientation
        let newValue: UIDeviceOrientation? = {
            switch o {
            case .portrait:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return o
            default:
                return nil
            }
        }()

        guard let newValue else { return }
        guard newValue != lastValidOrientation else { return }
        lastValidOrientation = newValue
    }
}
