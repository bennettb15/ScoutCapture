import SwiftUI

enum CameraChromeLocationMode: String, CaseIterable, Identifiable {
    case interior = "Interior"
    case exterior = "Exterior"

    var id: String { rawValue }
}

struct CameraChromeStatusModel: Equatable {
    var title: String
    var systemImage: String?
    var color: Color
}

struct CameraChromeMetadataModel: Equatable {
    var building: String
    var orientation: String
    var showsOrientationDot: Bool
    var orientationDotColor: Color
    var detailType: String
    var angle: String
    var trade: String?
    var isFilterAvailable: Bool
}

struct CameraChromeSideControl: Identifiable, Equatable {
    let id: String
    var systemImage: String
    var color: Color
    var badgeText: String?
    var accessibilityLabel: String
    var isVisible: Bool
    var isEnabled: Bool

    init(
        id: String,
        systemImage: String,
        color: Color = .white,
        badgeText: String? = nil,
        accessibilityLabel: String,
        isVisible: Bool = true,
        isEnabled: Bool = false
    ) {
        self.id = id
        self.systemImage = systemImage
        self.color = color
        self.badgeText = badgeText
        self.accessibilityLabel = accessibilityLabel
        self.isVisible = isVisible
        self.isEnabled = isEnabled
    }
}

struct CameraChromeDisplayModel {
    var profileTitle: String
    var profileSystemImage: String
    var profileAccentColor: Color
    var isProfileLocked: Bool
    var propertyName: String
    var cloudStatus: CameraChromeStatusModel?
    var showsPunchlistBadge: Bool
    var metadata: CameraChromeMetadataModel
    var previewStatusTitle: String
    var previewStatusColor: Color
    var isPreviewRunning: Bool
    var isShutterEnabled: Bool
    var isHDVisible: Bool
    var isHDEnabled: Bool
    var locationMode: CameraChromeLocationMode
    var sideControls: [CameraChromeSideControl]
    var savedCount: Int
    var thumbnail: UIImage?
    var ellipsisEnabled: Bool
    var deviceOrientation: UIDeviceOrientation = .portrait
    var glyphRotationAngle: Angle = .zero
}

struct CameraChromeActions {
    var onProfileTapped: () -> Void = {}
    var onEndTapped: () -> Void = {}
    var onMetadataTapped: () -> Void = {}
    var onSideControlTapped: (CameraChromeSideControl.ID) -> Void = { _ in }
    var onZoomTapped: (ZoomStep) -> Void = { _ in }
    var onHDTapped: () -> Void = {}
    var onShutterTapped: () -> Void = {}
    var onThumbnailTapped: () -> Void = {}
    var onLocationModeChanged: (CameraChromeLocationMode) -> Void = { _ in }
    var onEllipsisTapped: () -> Void = {}
}

struct CameraChromeView<PreviewContent: View, OverlayContent: View>: View {
    let display: CameraChromeDisplayModel
    let zoomSteps: [ZoomStep]
    let selectedZoomID: String
    let actions: CameraChromeActions
    @ViewBuilder var previewContent: () -> PreviewContent
    @ViewBuilder var overlayContent: () -> OverlayContent

    private var usesLandscapeChrome: Bool {
        display.deviceOrientation == .landscapeLeft || display.deviceOrientation == .landscapeRight
    }

    private var isLandscapeUI: Bool {
        usesLandscapeChrome
    }

    private var glyphRotationDegrees: Double {
        display.glyphRotationAngle.degrees
    }

    private var glyphRotationAnimation: Animation {
        Animation.interactiveSpring(
            response: 0.48,
            dampingFraction: 0.90,
            blendDuration: 0.18
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { geo in
                layoutContent(in: geo)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func layoutContent(in geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height
        let topInset: CGFloat = 30
        let topContentLift: CGFloat = isLandscapeUI ? -14 : -14
        let topBarH: CGFloat = topInset + (usesLandscapeChrome ? 62 : 68)
        let bottomBarH: CGFloat = 178
        let previewH: CGFloat = max(1, h - topBarH - bottomBarH)

        return AnyView(
            VStack(spacing: 0) {
                topHeaderView(w: w, topInset: topInset, topContentLift: topContentLift, topBarH: topBarH)
                previewAreaView(w: w, previewH: previewH)
                bottomMaskView(bottomBarH: bottomBarH, containerWidth: w)
            }
            .frame(width: w, height: h, alignment: .top)
            .clipped()
        )
    }

    private func topHeaderView(w _: CGFloat, topInset: CGFloat, topContentLift: CGFloat, topBarH: CGFloat) -> some View {
        ZStack {
            Color.black

            let rowPadding: CGFloat = 16
            let titleFontSize: CGFloat = usesLandscapeChrome ? 36 : 33
            let titleSideInset: CGFloat = usesLandscapeChrome ? 78 : 70

            VStack(spacing: usesLandscapeChrome ? 0 : 10) {
                VStack(spacing: 2) {
                    ZStack {
                        VStack(spacing: usesLandscapeChrome ? -1 : 1) {
                            Text(display.profileTitle)
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.5)
                                .foregroundColor(display.profileAccentColor.opacity(0.92))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)

                            Text(display.propertyName)
                                .font(.system(size: titleFontSize, weight: .semibold))
                                .tracking(0.4)
                                .foregroundColor(.white.opacity(0.66))
                                .lineLimit(1)
                                .minimumScaleFactor(0.54)
                                .truncationMode(.tail)

                            HStack(spacing: 6) {
                                if let status = display.cloudStatus {
                                    cloudStatusHeader(status)
                                }
                                if display.showsPunchlistBadge {
                                    punchlistVisitHeaderBadge
                                }
                            }
                            .frame(height: 14)
                        }
                        .padding(.horizontal, titleSideInset)
                        .frame(maxWidth: .infinity, alignment: .center)

                        HStack(spacing: 0) {
                            profileToggleControl()
                                .padding(.leading, rowPadding)
                            Spacer(minLength: 0)
                            endSessionControl()
                                .padding(.trailing, rowPadding)
                        }
                    }
                    .frame(height: usesLandscapeChrome ? 52 : nil)
                }

                if !usesLandscapeChrome {
                    metadataHUDStrip(isLandscapeStyle: false)
                        .padding(.horizontal, rowPadding)
                        .offset(y: 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, usesLandscapeChrome ? 0 : topInset)
            .padding(.bottom, 0)
            .padding(.horizontal, 10)
            .offset(y: usesLandscapeChrome ? -8 : topContentLift)
        }
        .frame(height: topBarH + 6)
    }

    private func cloudStatusHeader(_ status: CameraChromeStatusModel) -> some View {
        HStack(spacing: 4) {
            if let systemImage = status.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(status.title)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(status.color)
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .accessibilityLabel("Cloud status \(status.title)")
    }

    private var punchlistVisitHeaderBadge: some View {
        Text("Punchlist")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white.opacity(0.9))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(Color.red.opacity(0.82))
            )
            .accessibilityLabel("Punchlist")
    }

    private func metadataHUDStrip(isLandscapeStyle: Bool) -> some View {
        let accentColor: Color = isLandscapeStyle
            ? display.profileAccentColor.opacity(0.96)
            : display.profileAccentColor

        let metadataText = HStack(spacing: 0) {
            Text(display.metadata.building)
                .shadow(
                    color: .black.opacity(isLandscapeStyle ? 0.78 : 0.0),
                    radius: isLandscapeStyle ? 1.4 : 0.0,
                    x: 0,
                    y: 0
                )
            separatorToken()
            orientationToken
            separatorToken()
            Text(display.metadata.detailType)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(accentColor)
                .shadow(
                    color: .black.opacity(isLandscapeStyle ? 0.78 : 0.45),
                    radius: isLandscapeStyle ? 1.4 : 0.8,
                    x: 0,
                    y: 0
                )
            separatorToken()
            Text(display.metadata.angle)
                .foregroundColor(.white.opacity(0.86))
                .shadow(
                    color: .black.opacity(isLandscapeStyle ? 0.78 : 0.0),
                    radius: isLandscapeStyle ? 1.4 : 0.0,
                    x: 0,
                    y: 0
                )
            if let trade = display.metadata.trade, !trade.isEmpty {
                separatorToken()
                Text(trade)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(accentColor)
                    .shadow(
                        color: .black.opacity(isLandscapeStyle ? 0.78 : 0.45),
                        radius: isLandscapeStyle ? 1.4 : 0.8,
                        x: 0,
                        y: 0
                    )
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .minimumScaleFactor(0.76)
        .layoutPriority(1)

        let filterCircleSize: CGFloat = 18
        let filterGlyphSize: CGFloat = 10
        let filterGlyph = Image(systemName: "line.3.horizontal.decrease")
            .font(.system(size: filterGlyphSize, weight: .semibold))
            .foregroundColor(.white.opacity(display.metadata.isFilterAvailable ? 0.82 : 0.45))
            .frame(width: filterCircleSize, height: filterCircleSize, alignment: .center)
            .background(
                Circle()
                    .fill(Color.white.opacity(display.metadata.isFilterAvailable ? 0.14 : 0.07))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard display.metadata.isFilterAvailable else { return }
                actions.onMetadataTapped()
            }

        let tappableContent = HStack(spacing: 0) {
            HStack(spacing: isLandscapeStyle ? 5 : 6) {
                Color.clear
                    .frame(width: filterCircleSize, height: filterCircleSize)
                metadataText
                    .padding(.trailing, isLandscapeStyle ? 4 : 6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard display.metadata.isFilterAvailable else { return }
                        actions.onMetadataTapped()
                    }
                filterGlyph
            }
            .padding(.horizontal, isLandscapeStyle ? 6 : 8)
        }
        .opacity(display.metadata.isFilterAvailable ? 1.0 : 0.42)

        return HStack(spacing: 0) {
            tappableContent
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.system(size: 15, weight: .bold))
        .foregroundColor(.white.opacity(0.97))
        .padding(.horizontal, isLandscapeStyle ? 10 : 0)
        .padding(.vertical, isLandscapeStyle ? 6 : 0)
        .background {
            if isLandscapeStyle {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.20))
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func separatorToken() -> some View {
        Text(" | ")
            .foregroundColor(.white.opacity(0.78))
            .shadow(
                color: .black.opacity(usesLandscapeChrome ? 0.78 : 0.0),
                radius: usesLandscapeChrome ? 1.4 : 0.0,
                x: 0,
                y: 0
            )
    }

    private var orientationToken: some View {
        HStack(spacing: 3) {
            Text(display.metadata.orientation)
                .shadow(
                    color: .black.opacity(usesLandscapeChrome ? 0.78 : 0.0),
                    radius: usesLandscapeChrome ? 1.4 : 0.0,
                    x: 0,
                    y: 0
                )
            if display.metadata.showsOrientationDot {
                Circle()
                    .fill(display.metadata.orientationDotColor)
                    .frame(width: 9, height: 9)
            }
        }
    }

    private func endSessionControl() -> some View {
        Button(action: actions.onEndTapped) {
            Text("End")
                .font(.system(size: 17, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundColor(.red.opacity(0.72))
                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                .rotationEffect(usesLandscapeChrome ? display.glyphRotationAngle : .zero)
                .animation(glyphRotationAnimation, value: glyphRotationDegrees)
                .offset(y: 1.5)
        }
        .buttonStyle(.plain)
    }

    private func profileToggleControl() -> some View {
        Button(action: actions.onProfileTapped) {
            HStack(spacing: 3) {
                Image(systemName: display.profileSystemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(display.profileAccentColor)
                if display.isProfileLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .offset(y: -6)
                }
            }
            .frame(width: 34, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(display.isProfileLocked ? 0.76 : 1.0)
        .rotationEffect(usesLandscapeChrome ? display.glyphRotationAngle : .zero)
        .animation(glyphRotationAnimation, value: glyphRotationDegrees)
        .accessibilityLabel(display.profileTitle)
    }

    private func previewAreaView(w: CGFloat, previewH: CGFloat) -> some View {
        ZStack {
            previewContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .frame(width: w, height: previewH)
                .background(Color.black)
                .clipped()
                .compositingGroup()
                .transaction { transaction in
                    transaction.animation = nil
                }

            if usesLandscapeChrome {
                landscapeHeaderOverlay(w: w, previewH: previewH)
                    .zIndex(82)
            }

            if !display.isPreviewRunning {
                VStack(spacing: 10) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                    Text("Starting camera...")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.70))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .transition(.opacity)
                .zIndex(40)
            }

            topLeftPreviewPlaceholders()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: display.deviceOrientation == .landscapeRight ? .topTrailing : .topLeading
                )
                .padding(.top, 28)
                .padding(.leading, display.deviceOrientation == .landscapeRight ? 0 : 22)
                .padding(.trailing, display.deviceOrientation == .landscapeRight ? 22 : 0)
                .zIndex(12)

            zoomRowNativeCentered(inWidth: w)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
                .zIndex(20)

            overlayContent()
        }
        .clipped()
        .frame(height: previewH)
    }

    @ViewBuilder
    private func landscapeHeaderOverlay(w: CGFloat, previewH: CGFloat) -> some View {
        let isLandscapeLeft = display.deviceOrientation == .landscapeLeft
        let rotation = Angle.degrees(isLandscapeLeft ? 90 : -90)
        let sideInset: CGFloat = 22
        let xOffset: CGFloat = isLandscapeLeft ? (w * 0.5 - sideInset) : -(w * 0.5 - sideInset)
        let maxHudLength: CGFloat = max(220, previewH - 180)
        let yOffset: CGFloat = 0

        Color.clear
            .frame(width: w, height: previewH)
            .overlay(alignment: .center) {
                metadataHUDStrip(isLandscapeStyle: true)
                    .frame(maxWidth: maxHudLength)
                    .rotationEffect(rotation)
                    .animation(glyphRotationAnimation, value: glyphRotationDegrees)
                    .offset(x: xOffset, y: yOffset)
                    .compositingGroup()
            }
    }

    private func topLeftPreviewPlaceholders() -> some View {
        VStack(spacing: 2) {
            ForEach(display.sideControls.filter(\.isVisible)) { control in
                previewGlyphButton(control)
            }
        }
    }

    private func previewGlyphButton(_ control: CameraChromeSideControl) -> some View {
        let hitArea: CGFloat = 44
        let symbolSize: CGFloat = 22

        return Button {
            guard control.isEnabled else { return }
            actions.onSideControlTapped(control.id)
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: control.systemImage)
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundColor(control.color)

                if let badge = control.badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .rotationEffect(display.glyphRotationAngle)
            .animation(glyphRotationAnimation, value: glyphRotationDegrees)
            .frame(width: hitArea, height: hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitArea, height: hitArea)
        .disabled(!control.isEnabled)
        .accessibilityLabel(control.accessibilityLabel)
    }

    private func zoomRowNativeCentered(inWidth w: CGFloat) -> some View {
        let itemW: CGFloat = 36
        let spacing: CGFloat = 10
        let steps = zoomSteps.isEmpty ? [ZoomStep(id: "1", factor: 1.0, label: "1")] : zoomSteps
        let resolvedSelectionID = steps.contains(where: { $0.id == selectedZoomID }) ? selectedZoomID : (steps.first?.id ?? "1")
        let selectedIndex = steps.firstIndex(where: { $0.id == resolvedSelectionID }) ?? 0
        let totalW = CGFloat(steps.count) * itemW + CGFloat(max(0, steps.count - 1)) * spacing
        let leading = (w - totalW) / 2.0
        let selectedCenterX = leading + CGFloat(selectedIndex) * (itemW + spacing) + (itemW / 2.0)
        let offsetX = (w / 2.0) - selectedCenterX

        return HStack(spacing: spacing) {
            ForEach(steps) { step in
                let selected = step.id == resolvedSelectionID
                let base = step.label == "1" ? "1" : step.label
                let label = selected ? "\(base)x" : base

                Button {
                    actions.onZoomTapped(step)
                } label: {
                    Text(label)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? .white : Color.white.opacity(0.92))
                        .shadow(
                            color: selected ? .clear : Color.black.opacity(0.9),
                            radius: selected ? 0 : 2.2,
                            x: 0,
                            y: selected ? 0 : 2
                        )
                        .frame(width: itemW, height: itemW)
                        .background(
                            Group {
                                if selected {
                                    Circle()
                                        .fill(Color.blue)
                                        .overlay(
                                            Circle().fill(Color.white.opacity(0.10)).blendMode(.overlay)
                                        )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .offset(x: offsetX)
        .frame(width: w, alignment: .center)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func bottomMaskView(bottomBarH: CGFloat, containerWidth: CGFloat) -> some View {
        ZStack {
            Color.black

            VStack(spacing: 12) {
                HStack {
                    Spacer(minLength: 0)

                    Button(action: actions.onShutterTapped) {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 74, height: 74)
                                .shadow(radius: 2)
                                .overlay(
                                    Circle().stroke(Color.black.opacity(0.18), lineWidth: 1)
                                )

                            Circle()
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                .frame(width: 92, height: 92)

                            Circle()
                                .fill(Color.black.opacity(0.08))
                                .frame(width: 74, height: 74)
                        }
                    }
                    .disabled(!display.isShutterEnabled)
                    .buttonStyle(.plain)
                    .offset(y: -13)
                    .overlay(alignment: .center) {
                        ZStack {
                            if display.isHDVisible {
                                hdQuickButton(size: 44)
                                    .rotationEffect(display.glyphRotationAngle)
                                    .animation(glyphRotationAnimation, value: glyphRotationDegrees)
                                    .offset(x: -94, y: -12)
                            }

                            detailNoteQuickButton(size: 44)
                                .rotationEffect(display.glyphRotationAngle)
                                .animation(glyphRotationAnimation, value: glyphRotationDegrees)
                                .offset(x: 94, y: -12)
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(alignment: .center) {
                    thumbnailCircle(size: 44)
                        .frame(width: 44, height: 44)
                        .rotationEffect(display.glyphRotationAngle)
                        .animation(glyphRotationAnimation, value: glyphRotationDegrees)

                    Spacer(minLength: 0)

                    locationModeSlider()
                        .frame(height: 44)

                    Spacer(minLength: 0)

                    ellipsisCircle(size: 44)
                        .frame(width: 44, height: 44)
                        .rotationEffect(display.glyphRotationAngle)
                        .animation(glyphRotationAnimation, value: glyphRotationDegrees)
                }
                .padding(.horizontal, 22)
            }
            .frame(maxWidth: .infinity)
            .frame(height: bottomBarH, alignment: .bottom)
            .padding(.bottom, 12)
        }
        .frame(height: bottomBarH)
    }

    private func hdQuickButton(size: CGFloat) -> some View {
        Button(action: actions.onHDTapped) {
            ZStack {
                Circle()
                    .fill(display.isHDEnabled ? Color.blue : Color.white.opacity(0.14))
                    .frame(width: size, height: size)

                Circle()
                    .stroke(display.isHDEnabled ? Color.white.opacity(0.70) : Color.clear, lineWidth: 2)
                    .frame(width: size + 6, height: size + 6)
                    .opacity(display.isHDEnabled ? 1.0 : 0.0)

                Text("HD")
                    .font(.system(size: proportionalCircleTextSize(for: size), weight: .medium))
                    .foregroundColor(display.isHDEnabled ? .white : .white.opacity(0.92))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
    }

    private func detailNoteQuickButton(size: CGFloat) -> some View {
        Button {} label: {
            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: size, height: size)
                .overlay(
                    CameraChromeFlaggedReasonGlyph(
                        size: size,
                        foregroundColor: .white.opacity(0.92),
                        markColor: .black.opacity(0.86)
                    )
                )
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .disabled(true)
    }

    private func thumbnailCircle(size: CGFloat) -> some View {
        Button(action: actions.onThumbnailTapped) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.14))
                if let thumbnail = display.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .clipShape(Circle())
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
                if display.savedCount > 0 {
                    Text("\(display.savedCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: size * 0.32, y: -size * 0.32)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
    }

    private func locationModeSlider() -> some View {
        CameraChromeLocationModeSegmentedControl(
            selection: Binding(
                get: { display.locationMode },
                set: { actions.onLocationModeChanged($0) }
            )
        )
        .frame(width: 190)
        .frame(height: 44)
    }

    private func ellipsisCircle(size: CGFloat) -> some View {
        Button(action: actions.onEllipsisTapped) {
            Circle()
                .fill(Color.white.opacity(0.14))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "ellipsis")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(.white.opacity(display.ellipsisEnabled ? 0.92 : 0.45))
                )
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .disabled(!display.ellipsisEnabled)
    }
}

private struct CameraChromeLocationModeSegmentedControl: UIViewRepresentable {
    @Binding var selection: CameraChromeLocationMode

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = FixedHeightSegmentedControl(items: CameraChromeLocationMode.allCases.map(\.rawValue))
        control.forcedHeight = 44
        control.selectedSegmentIndex = index(for: selection)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.selectedSegmentTintColor = UIColor.systemBlue
        control.setTitleTextAttributes([
            .foregroundColor: UIColor.white.withAlphaComponent(0.92),
            .font: UIFont.systemFont(ofSize: 19, weight: .medium)
        ], for: .normal)
        control.setTitleTextAttributes([
            .foregroundColor: UIColor.white,
            .font: UIFont.systemFont(ofSize: 19, weight: .medium)
        ], for: .selected)
        return control
    }

    func updateUIView(_ uiView: UISegmentedControl, context _: Context) {
        let selectedIndex = index(for: selection)
        if uiView.selectedSegmentIndex != selectedIndex {
            uiView.selectedSegmentIndex = selectedIndex
        }
    }

    private func index(for mode: CameraChromeLocationMode) -> Int {
        switch mode {
        case .interior:
            return 0
        case .exterior:
            return 1
        }
    }

    private final class FixedHeightSegmentedControl: UISegmentedControl {
        var forcedHeight: CGFloat = 44

        override var intrinsicContentSize: CGSize {
            let size = super.intrinsicContentSize
            return CGSize(width: size.width, height: forcedHeight)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            invalidateIntrinsicContentSize()
        }
    }

    final class Coordinator: NSObject {
        var parent: CameraChromeLocationModeSegmentedControl

        init(parent: CameraChromeLocationModeSegmentedControl) {
            self.parent = parent
        }

        @objc func changed(_ sender: UISegmentedControl) {
            parent.selection = sender.selectedSegmentIndex == 0 ? .interior : .exterior
        }
    }
}

private struct CameraChromeFlaggedReasonGlyph: View {
    let size: CGFloat
    let foregroundColor: Color
    let markColor: Color

    var body: some View {
        ZStack {
            Image(systemName: "flag.fill")
                .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                .foregroundColor(foregroundColor)

            Image(systemName: "exclamationmark")
                .font(.system(size: max(8, size * 0.23), weight: .black))
                .foregroundColor(markColor)
                .offset(x: size * 0.04, y: -size * 0.07)
        }
        .frame(width: size, height: size)
    }
}

private func proportionalCircleTextSize(for size: CGFloat) -> CGFloat {
    min(24, max(14, (size * 0.42).rounded()))
}

private func proportionalCircleGlyphSize(for size: CGFloat) -> CGFloat {
    min(30, max(18, (size * 0.5).rounded()))
}
