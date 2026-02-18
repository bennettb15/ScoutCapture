//
//  ContentView.swift
//  ScoutCapture
//

import SwiftUI
import Photos
import CoreLocation
import CoreMotion
import Combine
import UIKit
import AVKit


// MARK: - UIScreen compatibility helper (avoids iOS 26 UIScreen warnings)

extension UIScreen {
    static var currentScale: CGFloat {
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return scene.screen.scale
        }
        return 3.0
    }
}

// MARK: - UIKit label button (native text rendering + reliable hit testing)

private struct UIKitCircleTextButton: UIViewRepresentable {

    let title: String
    let isActive: Bool
    let size: CGFloat
    let action: () -> Void

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addTarget(context.coordinator, action: #selector(Coordinator.tapped), for: .touchUpInside)
        button.backgroundColor = .clear
        button.clipsToBounds = true
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.action = action
        button.setTitle(title, for: .normal)

        let fg = isActive ? UIColor.black : UIColor(white: 1.0, alpha: 0.92)
        button.setTitleColor(fg, for: .normal)

        button.layer.cornerRadius = size / 2.0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func tapped() { action() }
    }
}

// MARK: - Camera-style glass circle (darker, liquid-glass rim)

private struct CameraGlassCircle: ViewModifier {

    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: size, height: size)
            .background(
                ZStack {
                    // Dark base so it never reads as gray
                    Circle().fill(Color.black.opacity(0.68))

                    // Light material just for "glass" feel
                    Circle().fill(.ultraThinMaterial).opacity(0.45)

                    // Edge darkening like Camera app
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.black.opacity(0.00),
                                    Color.black.opacity(0.65)
                                ],
                                center: .center,
                                startRadius: size * 0.25,
                                endRadius: size * 0.90
                            )
                        )

                    // Top highlight
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.20),
                                    Color.white.opacity(0.06),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .blendMode(.screen)

                    // Outer liquid-glass rim
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )

                    // Inner faint rim
                    Circle()
                        .inset(by: 1)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)

                    // Subtle inner shadow depth
                    Circle()
                        .inset(by: 0.5)
                        .stroke(Color.black.opacity(0.75), lineWidth: 1)
                        .blur(radius: 1.2)
                        .opacity(0.7)
                        .blendMode(.overlay)
                }
            )
            .shadow(color: Color.black.opacity(0.65), radius: 18, x: 0, y: 12)
    }
}

private extension View {
    func cameraGlassCircle(size: CGFloat = 44) -> some View {
        modifier(CameraGlassCircle(size: size))
    }
}

// MARK: - Physical shutter buttons (Camera Control + volume buttons)

private struct CameraCaptureButtons: ViewModifier {

    let onPressBegan: (() -> Void)?
    let onCapture: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 17.2, *) {
            content
                // Treat any physical shutter source the same.
                // Haptic on .began, capture on .ended.
                .onCameraCaptureEvent(
                    isEnabled: true,
                    primaryAction: { event in
                        switch event.phase {
                        case .began:
                            onPressBegan?()
                        case .ended:
                            onCapture()
                        default:
                            break
                        }
                    },
                    secondaryAction: { event in
                        switch event.phase {
                        case .began:
                            onPressBegan?()
                        case .ended:
                            onCapture()
                        default:
                            break
                        }
                    }
                )
        } else {
            content
        }
    }
}

private extension View {
    func cameraCaptureButtons(
        onPressBegan: (() -> Void)? = nil,
        onCapture: @escaping () -> Void
    ) -> some View {
        modifier(CameraCaptureButtons(onPressBegan: onPressBegan, onCapture: onCapture))
    }
}

// MARK: - Asset Image Cache

final class AssetImageCache: ObservableObject {

    private let manager = PHCachingImageManager()
    private let cache = NSCache<NSString, UIImage>()

    func requestThumbnail(for asset: PHAsset, pixelSize: CGFloat, completion: @escaping (UIImage?) -> Void) {

        let key = "\(asset.localIdentifier)-\(Int(pixelSize))" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        let target = CGSize(width: pixelSize, height: pixelSize)

        manager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            if let image {
                self?.cache.setObject(image, forKey: key)
            }
            completion(image)
        }
    }

    func requestFull(for asset: PHAsset, completion: @escaping (UIImage?) -> Void) {

        let key = "\(asset.localIdentifier)-full" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        let target = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)

        manager.requestImage(
            for: asset,
            targetSize: target,
            contentMode: .aspectFit,
            options: options
        ) { [weak self] image, _ in
            if let image {
                self?.cache.setObject(image, forKey: key)
            }
            completion(image)
        }
    }
}

// MARK: - Report Library Model (album per job + in app list)

final class ReportLibraryModel: ObservableObject {

    @Published private(set) var assets: [PHAsset] = []
    @Published private(set) var albumTitle: String = ""
    @Published private(set) var albumLocalId: String = ""

    private let activeAlbumIdKey = "scout.activeReport.albumLocalId.v1"
    private let activeAlbumTitleKey = "scout.activeReport.albumTitle.v1"

    init() {
        albumTitle = UserDefaults.standard.string(forKey: activeAlbumTitleKey) ?? ""
        albumLocalId = UserDefaults.standard.string(forKey: activeAlbumIdKey) ?? ""
    }

    func setActiveReportTitle(_ title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)

        if t != albumTitle {
            albumTitle = t
            albumLocalId = ""
            UserDefaults.standard.set(t, forKey: activeAlbumTitleKey)
            UserDefaults.standard.set("", forKey: activeAlbumIdKey)
        } else {
            albumTitle = t
            UserDefaults.standard.set(t, forKey: activeAlbumTitleKey)
        }
    }

    func reloadAssets() {
        guard !albumLocalId.isEmpty else {
            assets = []
            return
        }

        let fetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumLocalId], options: nil)
        guard let album = fetch.firstObject else {
            assets = []
            return
        }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let result = PHAsset.fetchAssets(in: album, options: opts)
        var out: [PHAsset] = []
        out.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            out.append(asset)
        }

        DispatchQueue.main.async {
            self.assets = out
        }
    }

    private func requestPhotosAuth(completion: @escaping (Bool) -> Void) {
        if #available(iOS 14, *) {
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                completion(status == .authorized || status == .limited)
            }
        } else {
            PHPhotoLibrary.requestAuthorization { status in
                completion(status == .authorized)
            }
        }
    }

    func ensureAlbumExists(completion: @escaping (Bool) -> Void) {

        guard !albumTitle.isEmpty else {
            completion(false)
            return
        }

        requestPhotosAuth { authorized in
            guard authorized else {
                completion(false)
                return
            }

            if !self.albumLocalId.isEmpty {
                let verify = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [self.albumLocalId], options: nil)
                if verify.firstObject != nil {
                    completion(true)
                    return
                } else {
                    DispatchQueue.main.async {
                        self.albumLocalId = ""
                        UserDefaults.standard.set("", forKey: self.activeAlbumIdKey)
                    }
                }
            }

            let titleFetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            var found: PHAssetCollection? = nil
            titleFetch.enumerateObjects { c, _, stop in
                if c.localizedTitle == self.albumTitle {
                    found = c
                    stop.pointee = true
                }
            }

            if let found {
                DispatchQueue.main.async {
                    self.albumLocalId = found.localIdentifier
                    UserDefaults.standard.set(found.localIdentifier, forKey: self.activeAlbumIdKey)
                }
                completion(true)
                return
            }

            var createdLocalId = ""

            PHPhotoLibrary.shared().performChanges({
                let create = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: self.albumTitle)
                createdLocalId = create.placeholderForCreatedAssetCollection.localIdentifier
            }, completionHandler: { success, _ in
                if success, !createdLocalId.isEmpty {
                    DispatchQueue.main.async {
                        self.albumLocalId = createdLocalId
                        UserDefaults.standard.set(createdLocalId, forKey: self.activeAlbumIdKey)
                    }
                    completion(true)
                } else {
                    completion(false)
                }
            })
        }
    }

    func savePhotoDataToAlbum(data: Data, location: CLLocation?, completion: @escaping (Bool) -> Void) {

        ensureAlbumExists { ok in
            guard ok, !self.albumLocalId.isEmpty else {
                completion(false)
                return
            }

            let fetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [self.albumLocalId], options: nil)
            guard let album = fetch.firstObject else {
                completion(false)
                return
            }

            var createdAssetId: String = ""

            PHPhotoLibrary.shared().performChanges({

                let assetRequest = PHAssetCreationRequest.forAsset()
                assetRequest.location = location
                assetRequest.addResource(with: .photo, data: data, options: nil)

                if let placeholder = assetRequest.placeholderForCreatedAsset {
                    createdAssetId = placeholder.localIdentifier
                    if let change = PHAssetCollectionChangeRequest(for: album) {
                        change.addAssets([placeholder] as NSArray)
                    }
                }

            }, completionHandler: { success, _ in
                if success {
                    DispatchQueue.main.async {
                        self.reloadAssets()
                    }
                }
                completion(success && !createdAssetId.isEmpty)
            })
        }
    }
}


 
// MARK: - Glass UI Helpers (single style language)

private struct GlassPill: ViewModifier {

    let height: CGFloat
    let horizontalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(.ultraThinMaterial, in: Capsule())
            // softer glass edge (less “solid ring”)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            // subtle internal highlight to feel more native
            .overlay(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
            )
            // lighter shadow so the border doesn’t read as harsh
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 5)
    }
}


private struct GlassCircle: ViewModifier {

    let size: CGFloat

    func body(content: Content) -> some View {
        content
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            // softer glass edge (match GlassPill)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            // subtle internal highlight (match GlassPill)
            .overlay(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10),
                                Color.white.opacity(0.02),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
            )
            // lighter shadow so it reads as glass, not a hard button
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 5)
    }
}


private extension View {
    func glassPill(height: CGFloat = 40, horizontalPadding: CGFloat = 16) -> some View {
        modifier(GlassPill(height: height, horizontalPadding: horizontalPadding))
    }

    func glassCircle(size: CGFloat = 40) -> some View {
        modifier(GlassCircle(size: size))
    }
}

// MARK: - Press feedback (native camera feel)

private struct PressScaleEffect: ViewModifier {
    let pressed: Bool
    let scale: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.80), value: pressed)
    }
}

private extension View {
    func pressScaleEffect(_ pressed: Bool, scale: CGFloat = 0.95) -> some View {
        modifier(PressScaleEffect(pressed: pressed, scale: scale))
    }
}

// MARK: - Album preview circle button

private struct RecentAlbumPreviewCircleButton: View {

    let lastAsset: PHAsset?
    let size: CGFloat
    let action: () -> Void

    @ObservedObject var cache: AssetImageCache

    @State private var thumb: UIImage? = nil
    @State private var lastId: String = ""

    // Tap preview animation
    @State private var pop: Bool = false

    var body: some View {
        Button(action: {
            action()
        }) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: size, height: size)

                if let thumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                }
            }
            .scaleEffect(pop ? 1.08 : 1.0)
        }
        .buttonStyle(.plain)
        .onAppear { loadThumbIfNeeded() }
        .onChange(of: lastAsset?.localIdentifier ?? "") { _, _ in
            loadThumbIfNeeded()
        }
        .onChange(of: thumb != nil) { _, newValue in
            guard newValue else { return }
            popOnce()
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.70), value: pop)
    }

    private func popOnce() {
        pop = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            pop = false
        }
    }

    private func loadThumbIfNeeded() {
        guard let asset = lastAsset else {
            thumb = nil
            lastId = ""
            return
        }

        if asset.localIdentifier == lastId, thumb != nil { return }
        lastId = asset.localIdentifier

        let scale = UIScreen.currentScale
        let px = max(260, size * scale * 3.0)

        cache.requestThumbnail(for: asset, pixelSize: px) { img in
            DispatchQueue.main.async { self.thumb = img }
        }
    }
}

// MARK: - Fullscreen Library (grid + contextual top bar)

// MARK: - Fullscreen viewer with swipe + filmstrip

private struct ReportPhotoViewer: View {

    let title: String
    let assets: [PHAsset]
    let startIndex: Int
    @ObservedObject var cache: AssetImageCache
    let viewerToken: Int

    @Environment(\.dismiss) private var dismiss

    // Physical device orientation (UI is portrait locked, we rotate the content ourselves)
    @State private var lastValidOrientation: UIDeviceOrientation = .portrait

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

    private func refreshOrientation() {
        let o = UIDevice.current.orientation

        // IMPORTANT:
        // In a portrait-locked app, iOS can report `.portrait` while the phone is physically upside down.
        // If we accept upside-down as portrait, the viewer will snap back to portrait while you are inverted.
        // Photos-like behavior: stay in the last landscape until you return to a true upright portrait.
        if o == .portraitUpsideDown {
            return
        }

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

        // Only force a rebuild when switching between portrait and landscape.
        // Rotating between landscapeLeft and landscapeRight should not reset zoom.
        let wasLandscape = (lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight)
        let willBeLandscape = (newValue == .landscapeLeft || newValue == .landscapeRight)

        lastValidOrientation = newValue

        if wasLandscape != willBeLandscape {
            orientationResetToken &+= 1
        }
    }

    @State private var index: Int
    @State private var barVisible: Bool = true
    @State private var barsManuallyHidden: Bool = false


    private func setBarsVisible(_ visible: Bool, animated: Bool) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                barVisible = visible
            }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) {
                barVisible = visible
            }
        }
    }

    // True while the user is actively swiping the main photo (TabView paging).
    // Used to prevent the filmstrip scrub logic from fighting the page swipe.
    @State private var isPagingDrag: Bool = false

    // Forces the zoom container to re-fit on device rotation
    @State private var orientationResetToken: Int = 0

    // Per-page zoom reset tokens.
    // When you swipe away from a page, we increment that page's token so returning to it is back at fit.
    @State private var pageResetTokens: [Int: Int] = [:]

    init(title: String, assets: [PHAsset], startIndex: Int, cache: AssetImageCache, viewerToken: Int) {
        self.title = title
        self.assets = assets
        self.startIndex = startIndex
        self.cache = cache
        self.viewerToken = viewerToken
        _index = State(initialValue: min(max(0, startIndex), max(0, assets.count - 1)))
    }
       
   
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // When we rotate content inside a portrait locked app, swap the content frame.
            let contentW = isLandscape ? h : w
            let contentH = isLandscape ? w : h

            ZStack {
                Color.black.ignoresSafeArea()

                ZStack {
                    ZStack {
                        TabView(selection: $index) {
                            ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                                FullImage(
                                    asset: asset,
                                    assetId: asset.localIdentifier,
                                    cache: cache,
                                    resetToken: (orientationResetToken * 10_000) + (pageResetTokens[idx, default: 0]),
                                    onHideBars: {
                                        // Only auto-hide if user did NOT manually hide bars.
                                        if barVisible && !barsManuallyHidden {
                                            setBarsVisible(false, animated: false)
                                        }
                                    },
                                    onShowBars: {
                                        // Only auto-show if bars were hidden by zoom behavior, not manual tap.
                                        if !barVisible && !barsManuallyHidden {
                                            setBarsVisible(true, animated: false)
                                        }
                                    }
                                )
                                    .tag(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        withAnimation(.easeOut(duration: 0.18)) {
                                            barVisible.toggle()
                                        }

                                        // Manual override flag
                                        if barVisible {
                                            barsManuallyHidden = false
                                        } else {
                                            barsManuallyHidden = true
                                        }
                                    }
                            }
                        }
                        .id("\(viewerToken)-\(orientationResetToken)")
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .ignoresSafeArea()
                        .animation(nil, value: barVisible)
                        
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { _ in
                                    // While swiping pages, suspend filmstrip-driven selection updates.
                                    if !isPagingDrag { isPagingDrag = true }
                                }
                                .onEnded { _ in
                                    // Let the page settle before re-enabling filmstrip scrub updates.
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                        isPagingDrag = false
                                    }
                                }
                        )

                        .overlay(alignment: .bottom) {
                            if barVisible, assets.count > 1 {
                                filmStrip()
                                    .padding(.bottom, 18)
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }

                    // Header overlay should NOT be a full-screen hit-testing layer.
                    // Keep it pinned to the top with its intrinsic height so swipes on the photo still page.
                    .overlay(alignment: .top) {
                        if barVisible {
                            headerOverlay()
                        }
                    }
                }
                .frame(width: contentW, height: contentH, alignment: .center)
                .rotationEffect(.degrees(rotationDegrees))
                .position(x: w * 0.5, y: h * 0.5)
            }
            .statusBarHidden(isLandscape)
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshOrientation()

                let v = min(max(0, startIndex), max(0, assets.count - 1))
                index = v
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                refreshOrientation()
            }
            
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
        }
        .onChange(of: index) { oldValue, newValue in
            // When leaving a page, reset its zoom so returning to it is back at fit.
            if oldValue != newValue {
                pageResetTokens[oldValue, default: 0] &+= 1
            }
        }
        .onChange(of: startIndex) { _, newValue in
            let v = min(max(0, newValue), max(0, assets.count - 1))
            index = v
        }
    }

    private func filmStrip() -> some View {
        FilmStrip(
            assets: assets,
            selectedIndex: $index,
            isPagingDrag: $isPagingDrag,
            cache: cache
        )
        .padding(.horizontal, 14)
    }

    private struct HeaderMeta {
        let elevation: String
        let detailId: String
        let detailNote: String?
    }

    private func headerMeta(for asset: PHAsset, index: Int) -> HeaderMeta {
        // If you do not have metadata yet, we try to parse from filename.
        // You can standardize later and only adjust parsing here.
        let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? ""

        // Expected optional tokens anywhere in filename (case insensitive):
        // "elev=Front" or "elev-Front" or "elev_Front"
        // "detail=DT-01" or "detail-DT-01" or "detail_DT-01"
        // "note=Something here" or "note-Something here" or "note_Something here"
        func extractToken(_ key: String) -> String? {
            let lower = filename.lowercased()
            guard let r = lower.range(of: key.lowercased()) else { return nil }

            // Start right after the key
            var i = filename.index(r.upperBound, offsetBy: 0)

            // Allow separators after key
            if i < filename.endIndex {
                let c = filename[i]
                if c == "=" || c == "-" || c == "_" || c == " " {
                    i = filename.index(after: i)
                }
            }

            // Read until we hit a delimiter
            var j = i
            while j < filename.endIndex {
                let c = filename[j]
                if c == "_" || c == "-" || c == "." {
                    break
                }
                j = filename.index(after: j)
            }

            let raw = String(filename[i..<j]).trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? nil : raw
        }

        let elev = extractToken("elev") ?? extractToken("elevation")
        let detail = extractToken("detail") ?? extractToken("detailid") ?? extractToken("id")
        let note = extractToken("note")

        let elevationText = elev ?? title
        let detailIdText = detail ?? "Photo \(index + 1) of \(max(assets.count, 1))"

        return HeaderMeta(
            elevation: elevationText,
            detailId: detailIdText,
            detailNote: note
        )
    }

    @ViewBuilder
    private func headerOverlay() -> some View {
        let safeIndex = min(max(0, index), max(0, assets.count - 1))
        let meta = assets.isEmpty ? HeaderMeta(elevation: title, detailId: "", detailNote: nil)
                                : headerMeta(for: assets[safeIndex], index: safeIndex)

        ZStack(alignment: .top) {
            // Background gradient should never intercept gestures.
            LinearGradient(
                colors: [
                    Color.black.opacity(0.92),
                    Color.black.opacity(0.70),
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.elevation)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if !meta.detailId.isEmpty {
                        Text(meta.detailId)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }

                    if let note = meta.detailNote, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 13, weight: .regular))
                            .italic()
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }

                Spacer(minLength: 0)

                Button {
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.28), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        // Critical: do NOT make this a full-screen view.
        // Keeping it to its intrinsic height prevents it from competing with TabView paging.
        .frame(height: 96, alignment: .top)
    }

    private struct FilmStrip: View {

        let assets: [PHAsset]
        @Binding var selectedIndex: Int
        @Binding var isPagingDrag: Bool
        @ObservedObject var cache: AssetImageCache

        private let thumbSide: CGFloat = 36
        private let spacing: CGFloat = 2

        // Selected styling
        // Slightly larger when settled to match Photos feel.
        private let selectedScale: CGFloat = 1.28
        private let selectedExtraSidePadding: CGFloat = 10

        // While the user is dragging the strip, do NOT fight them with scrollTo.
        @State private var isUserDragging: Bool = false

        // Viewport width for proper end padding so the first/last thumb can reach center.
        @State private var viewportWidth: CGFloat = 0

        // Momentum haptics window (keeps ticking during deceleration)
        @State private var momentumHapticsUntil: Date = .distantPast
        @State private var lastHapticIndex: Int = -1
        // Avoid “random” haptics caused by layout/appearance updates (eg. bars reappearing on zoom-out).
        // We only tick haptics after the user has actually interacted with the filmstrip.
        @State private var hasUserInteractedWithStrip: Bool = false

        // Debounced "settle" so we do NOT kill momentum.
        // We only snap-to-center after scrolling activity has stopped.
        @State private var settleWorkItem: DispatchWorkItem? = nil

        // Haptic on each index change while the user is interacting with the strip.
        private let haptic = UIImpactFeedbackGenerator(style: .light)

        private struct ItemMidXKey: PreferenceKey {
            static var defaultValue: [Int: CGFloat] = [:]
            static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
                value.merge(nextValue(), uniquingKeysWith: { $1 })
            }
        }

        var body: some View {
            ScrollViewReader { proxy in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.45))

                    GeometryReader { outerGeo in
                        let w = outerGeo.size.width
                        let maxThumbWidth = (thumbSide * selectedScale) + (selectedExtraSidePadding * 2)
                        let sidePad = max(0, (w - maxThumbWidth) * 0.5)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: spacing) {
                                ForEach(Array(assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                                    let selected = (idx == selectedIndex)

                                    FilmThumb(
                                        asset: asset,
                                        isSelected: selected,
                                        cache: cache,
                                        side: thumbSide
                                    )
                                    .scaleEffect(selected ? selectedScale : 1.0)
                                    .padding(.horizontal, selected ? selectedExtraSidePadding : 0)
                                    .animation(.easeOut(duration: 0.10), value: selectedIndex)
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        // Tap should jump immediately and center.
                                        isUserDragging = false
                                        momentumHapticsUntil = .distantPast
                                        selectedIndex = idx

                                        haptic.impactOccurred()
                                        haptic.prepare()
                                        lastHapticIndex = idx

                                        withAnimation(.easeOut(duration: 0.12)) {
                                            proxy.scrollTo(idx, anchor: .center)
                                        }
                                    }
                                    // Measure each thumb’s midX in the *visible viewport* coordinate space.
                                    .background(
                                        GeometryReader { itemGeo in
                                            Color.clear
                                                .preference(
                                                    key: ItemMidXKey.self,
                                                    value: [idx: itemGeo.frame(in: .named("filmstripViewport")).midX]
                                                )
                                        }
                                    )
                                }
                            }
                            // Critical: real padding so end items can reach the center.
                            .padding(.horizontal, sidePad)
                            .padding(.vertical, 6)
                        }
                        .scrollIndicators(.hidden)
                        .coordinateSpace(name: "filmstripViewport")
                        .onAppear {
                            viewportWidth = w

                            // Prime haptics and state. Doing a second prepare on the next run loop
                            // prevents the “first open has no haptics” behavior.
                            lastHapticIndex = selectedIndex
                            hasUserInteractedWithStrip = false
                            isUserDragging = false
                            momentumHapticsUntil = .distantPast

                            haptic.prepare()
                            DispatchQueue.main.async {
                                haptic.prepare()
                                proxy.scrollTo(selectedIndex, anchor: .center)
                            }
                        }
                        .onChange(of: w) { _, newW in
                            viewportWidth = newW
                        }
                        // Track user drag so programmatic centering does not fight their finger.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { _ in
                                    // If the user is paging the main photo, do not let the filmstrip logic fight it.
                                    if isPagingDrag { return }

                                    if !isUserDragging {
                                        isUserDragging = true
                                        hasUserInteractedWithStrip = true

                                        // Re-prime haptics at the exact moment the user begins interacting.
                                        haptic.prepare()
                                    }

                                    // While finger is down, keep the momentum window alive.
                                    momentumHapticsUntil = Date().addingTimeInterval(0.90)

                                    // Cancel any pending settle snap while user is actively moving.
                                    settleWorkItem?.cancel()
                                    settleWorkItem = nil
                                }
                                .onEnded { _ in
                                    if isPagingDrag { return }

                                    // Finger lifted. Do NOT snap here. Let the scroll view decelerate naturally.
                                    isUserDragging = false
                                    momentumHapticsUntil = Date().addingTimeInterval(0.90)
                                },
                            including: .all
                        )
                        // This is the core behavior:
                        // As the strip scrolls (drag or momentum), pick the thumb closest to center.
                        .onPreferenceChange(ItemMidXKey.self) { midXs in
                            if isPagingDrag { return }
                            guard viewportWidth > 1 else { return }
                            guard !midXs.isEmpty else { return }

                            // Critical fix for the neighbor-page "blip":
                            // Only allow midX-driven selection changes when the user has actually interacted
                            // with the strip (dragging) or we're in momentum deceleration from that interaction.
                            // Layout / overlay transitions can fire preference updates; those must NOT change pages.
                            let allowSelectionUpdates = hasUserInteractedWithStrip && (isUserDragging || (Date() < momentumHapticsUntil))
                            if !allowSelectionUpdates {
                                return
                            }

                            let centerX = viewportWidth * 0.5

                            var bestIdx: Int = selectedIndex
                            var bestDist: CGFloat = .greatestFiniteMagnitude

                            for (idx, midX) in midXs {
                                let d = abs(midX - centerX)
                                if d < bestDist {
                                    bestDist = d
                                    bestIdx = idx
                                }
                            }

                            if bestIdx != selectedIndex {
                                selectedIndex = bestIdx

                                // Haptic per photo change while dragging AND during momentum deceleration.
                                if bestIdx != lastHapticIndex {
                                    haptic.impactOccurred()
                                    haptic.prepare()
                                    lastHapticIndex = bestIdx
                                }
                            }

                            // Debounced settle: do not fight momentum.
                            // When scrolling activity stops (no more midX updates), snap once to center.
                            settleWorkItem?.cancel()
                            let work = DispatchWorkItem {
                                // Only settle when finger is up.
                                guard !isUserDragging else { return }
                                withAnimation(.easeOut(duration: 0.14)) {
                                    proxy.scrollTo(selectedIndex, anchor: .center)
                                }
                            }
                            settleWorkItem = work
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                        }
                    }
                    .frame(height: thumbSide + 12)
                }
                .frame(height: thumbSide + 12)
                // If selection changes from outside (page swipe or tap), keep strip centered.
                // Do not fight active dragging or deceleration.
                .onChange(of: selectedIndex) { _, newValue in
                    // If selection changes from outside (page swipe or tap), keep strip centered.
                    // Do not fight active dragging, momentum, or page swipes.
                    if isPagingDrag { return }
                    if isUserDragging { return }
                    if Date() < momentumHapticsUntil { return }

                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }

        private struct FilmThumb: View {

            let asset: PHAsset
            let isSelected: Bool
            @ObservedObject var cache: AssetImageCache
            let side: CGFloat

            @State private var img: UIImage? = nil

            var body: some View {
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: side, height: side)

                    if let img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 2))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isSelected ? Color.white.opacity(0.95) : Color.white.opacity(0.10), lineWidth: isSelected ? 2 : 1)
                )
                .onAppear {
                    if img != nil { return }
                    let scale = UIScreen.currentScale
                    let px: CGFloat = max(220, side * 6) * scale
                    cache.requestThumbnail(for: asset, pixelSize: px) { im in
                        DispatchQueue.main.async { self.img = im }
                    }
                }
            }
        }
    }
private struct FullImage: View {

    let asset: PHAsset
    let assetId: String
    @ObservedObject var cache: AssetImageCache
    let resetToken: Int
    let onHideBars: () -> Void
    let onShowBars: () -> Void

    @State private var full: UIImage? = nil
    @State private var thumb: UIImage? = nil

    // A stable key that changes whenever we need a hard reset, even if UIImage instances are reused.
    private var zoomKey: String { "\(assetId)-\(resetToken)" }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let full {
                ZoomableScrollImage(
                    image: full,
                    imageKey: zoomKey,
                    onHideBars: onHideBars,
                    onShowBars: onShowBars
                )
                .id(zoomKey)
                .ignoresSafeArea()
            } else if let thumb {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
            } else {
                // No spinner: avoid the “scroll wheel” flash during first fast scrub.
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            loadImagesIfNeeded()
        }
        .onChange(of: assetId) { _, _ in
            // Ensure we reset state if SwiftUI reuses the view.
            full = nil
            thumb = nil
            loadImagesIfNeeded()
        }
    }

    private func loadImagesIfNeeded() {
        // Kick a quick thumbnail first so scrubbing feels instant.
        if thumb == nil {
            let scale = UIScreen.currentScale
            let px: CGFloat = 420 * scale
            cache.requestThumbnail(for: asset, pixelSize: px) { im in
                DispatchQueue.main.async { self.thumb = im }
            }
        }

        if full != nil { return }
        cache.requestFull(for: asset) { im in
            DispatchQueue.main.async { self.full = im }
        }
    }
}

        private struct ZoomableScrollImage: UIViewRepresentable {

        let image: UIImage
        let imageKey: String
        let onHideBars: () -> Void
        let onShowBars: () -> Void

        func makeUIView(context: Context) -> PhotoZoomContainerView {
            let v = PhotoZoomContainerView()
            v.onHideBars = onHideBars
            v.onShowBars = onShowBars
            v.setImage(image, key: imageKey)
            return v
        }

        func updateUIView(_ uiView: PhotoZoomContainerView, context: Context) {
            uiView.onHideBars = onHideBars
            uiView.onShowBars = onShowBars
            uiView.setImage(image, key: imageKey)
        }

        final class PhotoZoomScrollView: UIScrollView, UIGestureRecognizerDelegate {

            /// Return true to allow the scroll view pan gesture to begin.
            /// We use this to let the parent TabView own horizontal paging when the image is at-fit.
            var shouldAllowPan: (() -> Bool)? = nil

            override init(frame: CGRect) {
                super.init(frame: frame)
                // Apple requirement: UIScrollViewPanGestureRecognizer delegate must be the scroll view.
                panGestureRecognizer.delegate = self
            }

            required init?(coder: NSCoder) {
                super.init(coder: coder)
                // Apple requirement: UIScrollViewPanGestureRecognizer delegate must be the scroll view.
                panGestureRecognizer.delegate = self
            }

            override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
                if gestureRecognizer === panGestureRecognizer {
                    return shouldAllowPan?() ?? true
                }
                return true
            }
        }

        final class PhotoZoomContainerView: UIView, UIScrollViewDelegate {

            var onHideBars: (() -> Void)? = nil
            var onShowBars: (() -> Void)? = nil
            

            private let scrollView = PhotoZoomScrollView()
            private let imageView = UIImageView()
            private var currentImageKey: String? = nil
            private var needsInitialFit: Bool = true
            private var lastBoundsSize: CGSize = .zero

            private var barsAreHidden: Bool = false
            // True while the user is actively pinching (UIScrollView zoom gesture).
            private var isUserZooming: Bool = false
            // True while we are performing a programmatic zoom animation (double tap).
            // While this is true, we must NOT flip the paging/gesture handshake mid-animation,
            // or certain images (commonly those whose fitScale == 1.0) will “snap” at the end.
            private var isProgrammaticZooming: Bool = false

            // While zooming out to fit, suppress recent TabView/page swipes from affecting layout.
            // This prevents the adjacent page from flashing during the zoom-out animation.
            private var isZoomingOutToFit: Bool = false
            private var zoomOutBeganAt: CFTimeInterval = 0
            private let zoomOutBlockSeconds: CFTimeInterval = 0.22

            // Stable haptic gating: avoid any incidental feedback during zoom-out settle.
            private var pendingShowBarsAfterZoomOut: Bool = false

            // When we restore bars (header + filmstrip), SwiftUI can trigger a layout transaction
            // that briefly lets the TabView show an adjacent page snapshot. Suppress handshake churn
            // during that restore window.
            private var isRestoringBars: Bool = false
            private var restoreBarsBeganAt: CFTimeInterval = 0
            private let restoreBarsBlockSeconds: CFTimeInterval = 0.18

           

            override init(frame: CGRect) {
                super.init(frame: frame)
                commonInit()
            }

            required init?(coder: NSCoder) {
                super.init(coder: coder)
                commonInit()
            }

            private func commonInit() {
                backgroundColor = .black

                scrollView.backgroundColor = .black
                scrollView.showsHorizontalScrollIndicator = false
                scrollView.showsVerticalScrollIndicator = false
                scrollView.bouncesZoom = true
                scrollView.decelerationRate = .fast
                scrollView.delegate = self
                scrollView.alwaysBounceVertical = false
                scrollView.alwaysBounceHorizontal = false

                imageView.contentMode = .scaleAspectFit
                imageView.backgroundColor = .clear
                imageView.isUserInteractionEnabled = true

                addSubview(scrollView)
                scrollView.addSubview(imageView)

                let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
                doubleTap.numberOfTapsRequired = 2
                scrollView.addGestureRecognizer(doubleTap)
            }
            private func updatePagingHandshake() {
                let now = CACurrentMediaTime()

                // During programmatic zoom-out and immediately after bar restoration, do NOT let TabView
                // see a 1-finger horizontal gesture. We temporarily let the scroll view "own" the pan
                // (even at-fit) so TabView cannot peek the neighbor page for a frame.
                var blockPaging = false

                if isZoomingOutToFit {
                    let elapsed = now - zoomOutBeganAt
                    if elapsed < zoomOutBlockSeconds {
                        blockPaging = true
                    } else {
                        isZoomingOutToFit = false
                    }
                }

                if isRestoringBars {
                    let elapsed = now - restoreBarsBeganAt
                    if elapsed < restoreBarsBlockSeconds {
                        blockPaging = true
                    } else {
                        isRestoringBars = false
                    }
                }

                let tol: CGFloat = 0.03
                let atFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) <= tol

                // Always keep the scroll view enabled for pinch + double tap.
                scrollView.panGestureRecognizer.isEnabled = true
                scrollView.isScrollEnabled = true

                // Gesture ownership:
                // - Normal state at-fit: require 2 fingers so a 1-finger swipe pages the TabView.
                // - While blockPaging at-fit: require only 1 finger so the scroll view captures the gesture
                //   and TabView cannot page/peek during zoom-out or bar restore transactions.
                if atFit {
                    scrollView.panGestureRecognizer.minimumNumberOfTouches = blockPaging ? 1 : 2
                } else {
                    scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
                }

                // Bars behavior:
                if atFit {
                    if barsAreHidden {
                        if blockPaging || isProgrammaticZooming || isUserZooming {
                            pendingShowBarsAfterZoomOut = true
                        } else {
                            barsAreHidden = false
                            onShowBars?()
                        }
                    }
                } else {
                    if !barsAreHidden {
                        barsAreHidden = true
                        onHideBars?()
                    }
                }

                // Delegate gate:
                // - Normal at-fit: do not allow 1-finger panning inside the scroll view.
                // - While blockPaging: DO allow it so the scroll view can "eat" the gesture and prevent
                //   TabView from showing the adjacent page.
                let allowAtFitPanDuringBlock = blockPaging
                scrollView.shouldAllowPan = { [weak self] in
                    guard let self else { return true }
                    let tol: CGFloat = 0.03
                    let atFit = abs(self.scrollView.zoomScale - self.scrollView.minimumZoomScale) <= tol
                    if atFit {
                        return allowAtFitPanDuringBlock
                    }
                    return true
                }
            }

            func setImage(_ image: UIImage, key: String) {
                if currentImageKey != key {
                    currentImageKey = key

                    // Hard reset state for a new asset.
                    // IMPORTANT: do NOT set zoomScale to minimumZoomScale here because minimumZoomScale
                    // is not valid until we have bounds and compute fitScale in layoutSubviews.
                    needsInitialFit = true
                    barsAreHidden = false
                    isProgrammaticZooming = false
                    lastBoundsSize = .zero

                    imageView.image = image

                    // Reset to a neutral zoom immediately; layoutSubviews will apply the true fitScale.
                    scrollView.setZoomScale(1.0, animated: false)
                    scrollView.contentOffset = .zero

                    setNeedsLayout()
                } else {
                    // Same key: allow opportunistic -> HQ image swap without resetting zoom.
                    imageView.image = image
                }
            }

            override func layoutSubviews() {
                super.layoutSubviews()

                scrollView.frame = bounds

                let boundsSize = scrollView.bounds.size
                guard boundsSize.width > 1, boundsSize.height > 1 else { return }

                if boundsSize != lastBoundsSize {
                    lastBoundsSize = boundsSize
                    needsInitialFit = true
                }

                guard let img = imageView.image else { return }

                let imageSize = img.size

                // Base (unzoomed) image view size.
                // Do NOT force scrollView.contentSize here.
                // UIScrollView manages contentSize for zooming based on the zoomed view.
                imageView.frame = CGRect(origin: .zero, size: imageSize)

                let scaleW = boundsSize.width / max(imageSize.width, 1)
                let scaleH = boundsSize.height / max(imageSize.height, 1)
                let fitScaleUncapped = min(scaleW, scaleH)
                let fitScale = min(fitScaleUncapped, 1.0)

                scrollView.minimumZoomScale = fitScale
                scrollView.maximumZoomScale = max(fitScale * 6.0, 3.0)

                if needsInitialFit {
                    needsInitialFit = false

                    // Apply true fit now that minimumZoomScale is valid.
                    scrollView.setZoomScale(fitScale, animated: false)
                    scrollView.contentOffset = .zero

                    updatePagingHandshake()
                } else {
                    // Clamp into the new range if needed (eg after rotation).
                    if scrollView.zoomScale < scrollView.minimumZoomScale {
                        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false)
                    }
                    if scrollView.zoomScale > scrollView.maximumZoomScale {
                        scrollView.setZoomScale(scrollView.maximumZoomScale, animated: false)
                    }
                }

                centerImage()
            }

            func viewForZooming(in scrollView: UIScrollView) -> UIView? {
                imageView
            }
            
            func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
                isUserZooming = true
            }
            
            func scrollViewDidZoom(_ scrollView: UIScrollView) {
                centerImage()

                let tol: CGFloat = 0.03
                let atFit = abs(scrollView.zoomScale - scrollView.minimumZoomScale) <= tol

                // Hide bars as soon as we leave fit (pinch or programmatic).
                if !atFit {
                    if !barsAreHidden {
                        barsAreHidden = true
                        onHideBars?()
                    }
                    return
                }

                // We are at fit. Do NOT show bars during the zoom gesture or animation.
                // Defer bar restore until zoom ends to prevent TabView neighbor-page peeks.
                if barsAreHidden {
                    if isProgrammaticZooming || isUserZooming {
                        pendingShowBarsAfterZoomOut = true
                    } else {
                        barsAreHidden = false
                        onShowBars?()
                    }
                }
            }

            func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
                // Pinch session ended.
                isUserZooming = false

                // Programmatic zoom animation has finished; it is now safe to update the paging handshake.
                if isProgrammaticZooming {
                    isProgrammaticZooming = false

                    // If we were zooming out to fit, keep suppression briefly to avoid neighbor-page peek.
                    if isZoomingOutToFit {
                        zoomOutBeganAt = CACurrentMediaTime()
                    }
                }

                // If we deferred bar restoration (double tap or pinch back to fit), restore now.
                if pendingShowBarsAfterZoomOut {
                    pendingShowBarsAfterZoomOut = false
                    barsAreHidden = false

                    // Mark a short restore window to prevent TabView neighbor-page peeks
                    // during the SwiftUI overlay transition.
                    isRestoringBars = true
                    restoreBarsBeganAt = CACurrentMediaTime()

                    // Restore bars on the next run loop tick to avoid participating in the zoom transaction.
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.onShowBars?()
                    }
                }

                // Only update the paging handshake after the zoom transaction and any bar restore tick.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updatePagingHandshake()
                }
            }


            private func centerImage() {
                let boundsSize = scrollView.bounds.size
                let contentSize = imageView.frame.size

                let offsetX = max(0, (boundsSize.width - contentSize.width) * 0.5)
                let offsetY = max(0, (boundsSize.height - contentSize.height) * 0.5)

                imageView.center = CGPoint(
                    x: contentSize.width * 0.5 + offsetX,
                    y: contentSize.height * 0.5 + offsetY
                )
            }

            @objc private func handleDoubleTap(_ gr: UITapGestureRecognizer) {
                let minScale = scrollView.minimumZoomScale
                let maxScale = scrollView.maximumZoomScale

                let isAtMin = abs(scrollView.zoomScale - minScale) < 0.01

                if isAtMin {
                    // Zoom in around the tapped point.
                    let targetScale = min(minScale * 2.5, maxScale)

                    if !barsAreHidden {
                        barsAreHidden = true
                        onHideBars?()
                    }

                    let point = gr.location(in: imageView)

                    let w = scrollView.bounds.size.width / targetScale
                    let h = scrollView.bounds.size.height / targetScale
                    let x = point.x - (w * 0.5)
                    let y = point.y - (h * 0.5)

                    // Mark that we are starting a programmatic zoom animation.
                    isProgrammaticZooming = true
                    scrollView.zoom(to: CGRect(x: x, y: y, width: w, height: h), animated: true)
                } else {
                    // Mark that we are starting a programmatic zoom animation.
                    isProgrammaticZooming = true

                    // We are zooming out to fit. Suppress gesture-handshake churn briefly so TabView
                    // never peeks the adjacent page (the "second-to-last flashes" symptom).
                    isZoomingOutToFit = true
                    zoomOutBeganAt = CACurrentMediaTime()
                    pendingShowBarsAfterZoomOut = true

                    // Zooming out: use setZoomScale so it animates smoothly even when minScale == 1.0
                    scrollView.setZoomScale(minScale, animated: true)
                }
            }
        }
    }
}

// MARK: - Detail Types Model (persisted per mode)

private final class DetailTypesModel: ObservableObject {

    struct DetailTypeItem: Identifiable, Codable, Equatable {
        var id: UUID = UUID()
        var name: String
    }

    @Published var interiorTypes: [DetailTypeItem] = []
    @Published var exteriorTypes: [DetailTypeItem] = []

    @Published var selectedInterior: String = ""
    @Published var selectedExterior: String = ""

    private let interiorTypesKey = "scout.detailTypes.interior.list.v3"
    private let exteriorTypesKey = "scout.detailTypes.exterior.list.v3"
    private let selectedInteriorKey = "scout.detailTypes.interior.selected.v3"
    private let selectedExteriorKey = "scout.detailTypes.exterior.selected.v3"

    private let legacyInteriorTypesKey = "scout.detailTypes.interior.list.v2"
    private let legacyExteriorTypesKey = "scout.detailTypes.exterior.list.v2"
    private let legacySelectedInteriorKey = "scout.detailTypes.interior.selected.v2"
    private let legacySelectedExteriorKey = "scout.detailTypes.exterior.selected.v2"

    private var pendingPersistInterior: DispatchWorkItem?
    private var pendingPersistExterior: DispatchWorkItem?
    private let persistDebounceSeconds: Double = 0.22

    init() {
        load()
        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func types(for mode: ContentView.LocationMode) -> [DetailTypeItem] {
        mode == .interior ? interiorTypes : exteriorTypes
    }

    func selected(for mode: ContentView.LocationMode) -> String {
        mode == .interior ? selectedInterior : selectedExterior
    }

    func setSelected(_ value: String, for mode: ContentView.LocationMode) {
        if mode == .interior { selectedInterior = value } else { selectedExterior = value }
        persistSelected()
    }

    @discardableResult
    func insertBlankItem(for mode: ContentView.LocationMode) -> UUID {
        let newItem = DetailTypeItem(name: "")
        if mode == .interior {
            interiorTypes.append(newItem)
            persistAll()
            return newItem.id
        } else {
            exteriorTypes.append(newItem)
            persistAll()
            return newItem.id
        }
    }

    func updateItem(_ value: String, id: UUID, for mode: ContentView.LocationMode) {
        let cleaned = value.trimmingCharacters(in: .newlines)

        if mode == .interior {
            guard let idx = interiorTypes.firstIndex(where: { $0.id == id }) else { return }
            interiorTypes[idx].name = cleaned
        } else {
            guard let idx = exteriorTypes.firstIndex(where: { $0.id == id }) else { return }
            exteriorTypes[idx].name = cleaned
        }

        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func delete(at offsets: IndexSet, for mode: ContentView.LocationMode) {
        if mode == .interior {
            let deleting = offsets.compactMap { interiorTypes.indices.contains($0) ? interiorTypes[$0].name : nil }
            interiorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedInterior) { selectedInterior = interiorTypes.first?.name ?? "" }
        } else {
            let deleting = offsets.compactMap { exteriorTypes.indices.contains($0) ? exteriorTypes[$0].name : nil }
            exteriorTypes.remove(atOffsets: offsets)
            if deleting.contains(selectedExterior) { selectedExterior = exteriorTypes.first?.name ?? "" }
        }
        normalizeDefaultsIfNeeded()
        persistAll()
    }

    func move(from source: IndexSet, to destination: Int, for mode: ContentView.LocationMode) {
        if mode == .interior {
            interiorTypes.move(fromOffsets: source, toOffset: destination)
            schedulePersist(for: .interior)
        } else {
            exteriorTypes.move(fromOffsets: source, toOffset: destination)
            schedulePersist(for: .exterior)
        }
    }

    private func schedulePersist(for mode: ContentView.LocationMode) {
        if mode == .interior {
            pendingPersistInterior?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.normalizeDefaultsIfNeeded()
                self.persistAll()
            }
            pendingPersistInterior = work
            DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
        } else {
            pendingPersistExterior?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.normalizeDefaultsIfNeeded()
                self.persistAll()
            }
            pendingPersistExterior = work
            DispatchQueue.main.asyncAfter(deadline: .now() + persistDebounceSeconds, execute: work)
        }
    }

    private func load() {
        interiorTypes = loadItems(key: interiorTypesKey, legacyStringKey: legacyInteriorTypesKey)
        exteriorTypes = loadItems(key: exteriorTypesKey, legacyStringKey: legacyExteriorTypesKey)

        selectedInterior = UserDefaults.standard.string(forKey: selectedInteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedInteriorKey)
            ?? ""

        selectedExterior = UserDefaults.standard.string(forKey: selectedExteriorKey)
            ?? UserDefaults.standard.string(forKey: legacySelectedExteriorKey)
            ?? ""
    }

    private func persistAll() {
        saveItems(interiorTypes, key: interiorTypesKey)
        saveItems(exteriorTypes, key: exteriorTypesKey)
        persistSelected()
    }

    private func persistSelected() {
        UserDefaults.standard.set(selectedInterior, forKey: selectedInteriorKey)
        UserDefaults.standard.set(selectedExterior, forKey: selectedExteriorKey)
    }

    private func normalizeDefaultsIfNeeded() {
        let defaultInteriorTypes: [String] = [
            "Main Lobby",
            "Office Space",
            "Common Areas",
            "Restrooms",
            "Mechanical or Utility Rooms"
        ]

        let defaultExteriorTypes: [String] = [
            "General Elevation",
            "Window Detail",
            "Cladding Transition",
            "Entry Detail",
            "Roofline Detail"
        ]

        if interiorTypes.isEmpty { interiorTypes = defaultInteriorTypes.map { DetailTypeItem(name: $0) } }
        if exteriorTypes.isEmpty { exteriorTypes = defaultExteriorTypes.map { DetailTypeItem(name: $0) } }

        if selectedInterior.isEmpty { selectedInterior = firstNonEmpty(from: interiorTypes) ?? (interiorTypes.first?.name ?? "") }
        if selectedExterior.isEmpty { selectedExterior = firstNonEmpty(from: exteriorTypes) ?? (exteriorTypes.first?.name ?? "") }

        if !interiorTypes.contains(where: { $0.name == selectedInterior }) { selectedInterior = firstNonEmpty(from: interiorTypes) ?? (interiorTypes.first?.name ?? "") }
        if !exteriorTypes.contains(where: { $0.name == selectedExterior }) { selectedExterior = firstNonEmpty(from: exteriorTypes) ?? (exteriorTypes.first?.name ?? "") }
    }

    private func firstNonEmpty(from list: [DetailTypeItem]) -> String? {
        list.first(where: { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.name
    }

    private func loadItems(key: String, legacyStringKey: String) -> [DetailTypeItem] {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([DetailTypeItem].self, from: data) {
            return decoded
        }

        if let legacyData = UserDefaults.standard.data(forKey: legacyStringKey),
           let decodedStrings = try? JSONDecoder().decode([String].self, from: legacyData) {
            return decodedStrings.map { DetailTypeItem(name: $0) }
        }

        return []
    }

    private func saveItems(_ items: [DetailTypeItem], key: String) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - ContentView

struct ContentView: View {

    private let shutterHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let successHaptic = UINotificationFeedbackGenerator()

    @StateObject private var camera = CameraManager()
    @StateObject private var levelModel = LevelMotionModel()
    @StateObject private var detailTypesModel = DetailTypesModel()
    @StateObject private var locationManager = LocationManager()

    @StateObject private var reportLibrary = ReportLibraryModel()
    @StateObject private var imageCache = AssetImageCache()

    @State private var recordId: String = "SC-2026-001"
    @State private var elevation: String = "North Elevation"

    @State private var detailNote: String = ""
    @State private var showSavedToast: Bool = false
    @State private var showNotSavedToast: Bool = false

    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusRing: Bool = false

    @State private var showDetailTypeSheet: Bool = false
    @State var locationMode: LocationMode = .exterior

    @State private var showQuickMenu: Bool = false
    @State private var manageContext: ManageContext? = nil

    // Custom centered overlays for rotated dropdowns (used in landscape-with-portrait-lock UI)
    @State private var showLandscapeElevationMenu: Bool = false
    @State private var showLandscapeDetailMenu: Bool = false

    @State private var lensToastText: String = ""
    @State private var showLensToast: Bool = false
    @State private var lensToastToken: Int = 0

    @State private var showGrid: Bool = false
    @State private var showLevel: Bool = false

    @State private var showDetailOverlay: Bool = false
    @State private var draftDetailNote: String = ""

    @State private var showLibraryFullscreen: Bool = false
    
    // MARK: - Physical device rotation for glyphs (UI is locked to portrait)

    @State private var lastValidDeviceOrientation: UIDeviceOrientation = .portrait
    @State private var glyphAngleDegrees: Double = 0

    // Polling helps rotation start a touch sooner than UIDevice.orientationDidChangeNotification.
    // This is still discrete (0 / +90 / -90) and does NOT introduce continuous motion.
    @State private var isPollingDeviceOrientation: Bool = false
    private let deviceOrientationPoll = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()

    // Discrete rotation like the native Camera app: animate to 0, +90, or -90 and stop.
    // Slightly slower than before.
    private let glyphRotationAnimation = Animation.interactiveSpring(
        response: 0.48,
        dampingFraction: 0.90,
        blendDuration: 0.18
    )

    private var bottomGlyphRotationAngle: Angle {
        .degrees(glyphAngleDegrees)
    }

    private func refreshBottomGlyphRotation() {
        let o = UIDevice.current.orientation

        // Ignore transitional or invalid states.
        let newValue: UIDeviceOrientation? = {
            switch o {
            case .portrait, .portraitUpsideDown:
                return .portrait
            case .landscapeLeft, .landscapeRight:
                return o
            default:
                return nil
            }
        }()

        guard let newValue else { return }
        guard newValue != lastValidDeviceOrientation else { return }

        lastValidDeviceOrientation = newValue

        // Your spec:
        // Phone rotated to the left -> rotate glyphs 90 degrees to the right (clockwise)
        // Phone rotated to the right -> rotate glyphs 90 degrees to the left (counterclockwise)
        let target: Double
        switch newValue {
        case .landscapeLeft:
            target = 90
        case .landscapeRight:
            target = -90
        default:
            target = 0
        }

        withAnimation(glyphRotationAnimation) {
            glyphAngleDegrees = target
        }
    }

    enum LocationMode: String, CaseIterable, Identifiable {
        case interior = "Interior"
        case exterior = "Exterior"
        var id: String { rawValue }
    }

    private enum Direction: String, CaseIterable, Identifiable {
        case north = "North"
        case south = "South"
        case east  = "East"
        case west  = "West"

        var id: String { rawValue }

        var elevationValue: String {
            switch self {
            case .north: return "North Elevation"
            case .south: return "South Elevation"
            case .east:  return "East Elevation"
            case .west:  return "West Elevation"
            }
        }

        static func fromElevation(_ elevation: String) -> Direction {
            switch elevation {
            case "South Elevation": return .south
            case "East Elevation":  return .east
            case "West Elevation":  return .west
            default:                 return .north
            }
        }
    }

    private struct ManageContext: Identifiable {
        let id = UUID()
        let mode: LocationMode
    }

    private var hasDetailNote: Bool {
        !detailNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var currentDetailType: String {
        detailTypesModel.selected(for: locationMode)
    }

    var body: some View {
        
        ZStack {

            Color.black
                .ignoresSafeArea()

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                // Top mask: use a fixed inset (do not bind to safe area) so layout is stable and tight.
                // You can tweak this number to nudge the whole top mask down/up.
                let topInset: CGFloat = 30

                // Fine-tune ONLY the internal content position without changing the mask inset.
                // Negative moves the Report ID + dropdowns up.
                let topContentLift: CGFloat = -22
                
                // Compact header height (fixed inset + content)
                let topBarH: CGFloat = topInset + 56

                let _: CGFloat = max(geo.safeAreaInsets.bottom, 0)

                // Bottom mask should extend fully to the physical bottom of screen.
                // Do NOT include safeBottom in the height or it will push content upward.
                let bottomBarH: CGFloat = 178

                let previewH: CGFloat = max(1, h - topBarH - bottomBarH)

                let baseToastTop: CGFloat = 10
                let _: CGFloat = 10 // toastGap (unused)
                let _: CGFloat = 44 // assumedToastHeight (unused)

                VStack(spacing: 0) {

                    // Top header (compact, consistent, and not oversized)
                    ZStack {
                        Color.black

                        let rowPadding: CGFloat = 16
                        let controlH: CGFloat = 44
                        let gap: CGFloat = 10
                        let controlW: CGFloat = (w - (rowPadding * 2) - gap) / 2.0

                        VStack(spacing: 10) {

                            // Report ID is the focal point
                            Text(recordId)
                                .font(.system(size: 30, weight: .bold))
                                .tracking(0.4)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .frame(maxWidth: .infinity, alignment: .center)

                            if !(lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight) {
                                // Two controls side-by-side using custom centered overlay toggles (same as landscape)
                                HStack(spacing: gap) {

                                    // Elevation dropdown (custom centered overlay)
                                    Button {
                                        // Only allow elevation picking in exterior mode
                                        if locationMode == .interior {
                                            return
                                        }
                                        showLandscapeDetailMenu = false
                                        showLandscapeElevationMenu.toggle()
                                    } label: {
                                        let elevationLabel = (locationMode == .interior) ? "Interior" : elevation

                                        HStack(spacing: 8) {
                                            Text(elevationLabel)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.95))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.78)

                                            Spacer(minLength: 0)

                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.90))
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(width: controlW, height: controlH, alignment: .center)
                                        .background(
                                            ZStack {
                                                Color.black.opacity(0.55)
                                                Color.white.opacity(0.08)
                                            }
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(locationMode == .interior)

                                    // Detail type dropdown (custom centered overlay)
                                    Button {
                                        showLandscapeElevationMenu = false
                                        showLandscapeDetailMenu.toggle()
                                    } label: {
                                        HStack(spacing: 8) {
                                            Text(currentDetailType.isEmpty ? "Select" : currentDetailType)
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.95))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.78)

                                            Spacer(minLength: 0)

                                            Image(systemName: "chevron.down")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(.white.opacity(0.90))
                                        }
                                        .padding(.horizontal, 14)
                                        .frame(width: controlW, height: controlH, alignment: .center)
                                        .background(
                                            ZStack {
                                                Color.black.opacity(0.55)
                                                Color.white.opacity(0.08)
                                            }
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 18))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 18)
                                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, rowPadding)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Push content below the status bar without making controls huge
                        .padding(.top, topInset)
                        .padding(.bottom, 0)
                        .padding(.horizontal, 10)
                        .offset(y: topContentLift)
                    }
                    .frame(height: topBarH)
                    
                    // PREVIEW
                    ZStack {
                        CameraPreviewView(
                            session: camera.session,
                            onTapDevicePoint: { devicePoint in
                                camera.focus(atDevicePoint: devicePoint)
                            },
                            onTapNormalizedPoint: { normalizedPoint in
                                let x = normalizedPoint.x * w
                                let y = normalizedPoint.y * previewH
                                focusPoint = CGPoint(x: x, y: y)
                                showFocusRing = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                                    showFocusRing = false
                                }
                            }
                        )
                        .cameraCaptureButtons(
                            onPressBegan: {
                                shutterHaptic.impactOccurred()
                                shutterHaptic.prepare()
                            },
                            onCapture: {
                                capture()
                            }
                        )
                        // Always occupy the full preview rect and stay centered
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .frame(width: w, height: previewH)
                        .background(Color.black)
                        .clipped()
                        // Helps hide any 1px camera-layer seam by ensuring the container is pixel-aligned
                        .compositingGroup()
                        
                        .transaction { tx in
                            tx.animation = nil
                        }
                        
                        if showGrid {
                            GridOverlay()
                                .stroke(Color.white.opacity(0.22), lineWidth: 1)
                                .allowsHitTesting(false)
                                .zIndex(5)
                        }
                        
                        if showLevel {
                            LevelOverlay(
                                rollDegrees: levelModel.rollDegrees,
                                isLevel: levelModel.isLevel
                            )
                            // Keep the level aligned to the physical device orientation
                            // while the UI remains portrait-locked.
                            .rotationEffect(bottomGlyphRotationAngle)
                            .allowsHitTesting(false)
                            .zIndex(6)
                        }
                        
                        if (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight) {
                            let isLandscapeLeft = (lastValidDeviceOrientation == .landscapeLeft)

                            // When the physical device rotates:
                            // - landscapeLeft: controls should read upright, rotated +90
                            // - landscapeRight: controls should read upright, rotated -90
                            let rotationDegrees: Double = isLandscapeLeft ? 90 : -90

                            // Mirror placement so the dropdowns stay in the top-right of the *preview*
                            // for both orientations.
                            let alignment: Alignment = isLandscapeLeft ? .topTrailing : .topLeading
                            let anchor: UnitPoint = isLandscapeLeft ? .topTrailing : .topLeading

                            // Anchor to the preview rectangle explicitly so it cannot drift into the header mask.
                            Color.clear
                                .frame(width: w, height: previewH)
                                .overlay(alignment: alignment) {
                                    // Nudge inward from the preview edge in each orientation.
                                    let xNudge: CGFloat = isLandscapeLeft ? -10 : 10
                                    let yNudge: CGFloat = 200

                                    landscapeDropdownStack()
                                        // Rotate correctly for the current landscape direction.
                                        .rotationEffect(.degrees(rotationDegrees), anchor: anchor)
                                        .offset(x: xNudge, y: yNudge)
                                        // Prevent flicker during Menu open/close
                                        .compositingGroup()
                                }
                                .zIndex(80)
                        }
                        // Lens debug toast (temporarily disabled)
                        // if showLensToast, !lensToastText.isEmpty {
                        //     toastPill(text: lensToastText)
                        //         .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        //         .rotationEffect(bottomGlyphRotationAngle)
                        //         .allowsHitTesting(false)
                        //         .zIndex(60)
                        // }
                        
                        if hasDetailNote {
                            let isLandscape = (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight)

                            if isLandscape {
                                // In landscape, keep the note on the bottom edge of the preview.
                                // Remove rotation animation for this toast only.
                                toastPill(text: detailNote)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .padding(.bottom, 96)
                                    .padding(.horizontal, 18)
                                    .rotationEffect(bottomGlyphRotationAngle)
                                    .transaction { transaction in
                                        transaction.animation = nil
                                    }
                                    .allowsHitTesting(false)
                                    .zIndex(55)
                            } else {
                                // Portrait behavior stays the same
                                toastPill(text: detailNote)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                                    .padding(.top, baseToastTop)
                                    .padding(.horizontal, 18)
                                    .allowsHitTesting(false)
                                    .zIndex(55)
                            }
                        }
                        
                        zoomRowNativeCentered(inWidth: w)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 18) // move closer to the lower mask
                            .zIndex(20)
                        
                        if showFocusRing, let fp = focusPoint {
                            Circle()
                                .stroke(Color.white, lineWidth: 3)
                                .frame(width: 74, height: 74)
                                .position(fp)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                                .zIndex(30)
                        }
                        
                        if showSavedToast {
                            Text("Saved to Photos")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                                // Center of the preview area
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                // Rotate like the native camera UI glyphs
                                .rotationEffect(bottomGlyphRotationAngle)
                                .allowsHitTesting(false)
                                .zIndex(25)
                        }

                        if showNotSavedToast {
                            Text("Photos access needed")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Color.black.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                                // Center of the preview area
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                // Rotate like the native camera UI glyphs
                                .rotationEffect(bottomGlyphRotationAngle)
                                .allowsHitTesting(false)
                                .zIndex(25)
                        }
                    }
                    .clipped()
                    .frame(height: previewH)
                    // .onChange(of: camera.lensDebugPulse) { _, _ in
                    //     showLensToastNow(camera.lensDebugText)
                    // }
                    .onAppear {
                        // showLensToastNow(camera.lensDebugText)
                        shutterHaptic.prepare()
                    }
                    .onChange(of: showLevel) { _, newValue in
                        if newValue { levelModel.start() } else { levelModel.stop() }
                    }
                    
                    // BOTTOM MASK
                    ZStack {
                        Color.black

                        // Native-style bottom layout: shutter row, then mode slider row under it.
                        VStack(spacing: 12) {

                            // Shutter centered
                            HStack {
                                Spacer(minLength: 0)

                                Button(action: {
                                    shutterHaptic.impactOccurred()
                                    shutterHaptic.prepare()
                                    capture()
                                }) {
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
                                .disabled(camera.isCapturing)
                                .buttonStyle(.plain)
                                .offset(y: -13)
                                // Quick-access Detail Note aligned to shutter center (moves ONLY this control)
                                .overlay(alignment: .center) {
                                    detailNoteQuickButton(size: 44)
                                        // 35pt gap from shutter edge: 74/2 + 35 + 44/2 = 94
                                        // Compensate for shutter vertical offset so the button is vertically centered
                                        .rotationEffect(bottomGlyphRotationAngle)
                                        .offset(x: 94, y: -12)
                                }

                                Spacer(minLength: 0)
                            }

                            // Album • Interior/Exterior pill • Menu  (edge buttons, center pill)
                            HStack(alignment: .center) {

                                RecentAlbumPreviewCircleButton(
                                    lastAsset: reportLibrary.assets.last,
                                    size: 44,
                                    action: { showLibraryFullscreen = true },
                                    cache: imageCache
                                )
                                .frame(width: 44, height: 44)
                                .rotationEffect(bottomGlyphRotationAngle)

                                
                                Spacer(minLength: 0)

                                locationModeSlider()
                                    .frame(height: 44)

                                Spacer(minLength: 0)

                                topRightEllipsisCircle()
                                    .frame(width: 44, height: 44)
                                    .rotationEffect(bottomGlyphRotationAngle)
                            }
                            .padding(.horizontal, 22)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: bottomBarH, alignment: .bottom)
                        .padding(.bottom, 12)
                       
                    }
                    .frame(height: bottomBarH)
                    
                    // Detail type dropdown sheet
                    .sheet(isPresented: $showDetailTypeSheet) {
                        NavigationStack {
                            List {
                                let list = detailTypesModel.types(for: locationMode)
                                ForEach(list) { item in
                                    Button(action: {
                                        detailTypesModel.setSelected(item.name, for: locationMode)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                                            showDetailTypeSheet = false
                                        }
                                    }) {
                                        HStack {
                                            Text(item.name)
                                                .font(.system(size: 16, weight: detailTypesModel.selected(for: locationMode) == item.name ? .semibold : .regular))
                                                .foregroundColor(.primary)
                                            Spacer()
                                            if detailTypesModel.selected(for: locationMode) == item.name {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundColor(.accentColor)
                                            }
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .listStyle(.insetGrouped)
                            .navigationTitle(locationMode == .interior ? "Interior Detail Type" : "Exterior Detail Type")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { showDetailTypeSheet = false }
                                }
                            }
                        }
                    }
                    
                    // Quick menu
                    .sheet(isPresented: $showQuickMenu) {
                        QuickMenuSheet(
                            glyphRotationAngle: bottomGlyphRotationAngle,
                            flashSetting: camera.flashSetting,
                            isGridOn: $showGrid,
                            isLevelOn: $showLevel,
                            onInteriorList: {
                                showQuickMenu = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    manageContext = ManageContext(mode: .interior)
                                }
                            },
                            onStamp: { },
                            onExteriorList: {
                                showQuickMenu = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    manageContext = ManageContext(mode: .exterior)
                                }
                            },
                            onFlash: { camera.cycleFlash() },
                            onCameraSwap: { camera.toggleCamera() }
                        )
                        .presentationDetents([.medium])
                        .presentationDragIndicator(.hidden)
                    }
                    
                    // Manage list sheet
                    .sheet(item: $manageContext) { ctx in
                        ManageDetailTypesView(
                            mode: ctx.mode,
                            model: detailTypesModel
                        )
                    }
                    
                    // Fullscreen library
                    .fullScreenCover(isPresented: $showLibraryFullscreen) {
                        ReportLibraryFullscreen(reportLibrary: reportLibrary, cache: imageCache)
                            .ignoresSafeArea()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .clipped()
                
            }
            .fullScreenCover(isPresented: $showDetailOverlay) {
                DetailNoteModal(
                    elevation: elevation,
                    detailType: currentDetailType,
                    existingNote: detailNote,
                    onCancel: {
                        showDetailOverlay = false
                    },
                    onSave: { newValue in
                        detailNote = newValue
                        showDetailOverlay = false
                    }
                )
                // Make the cover itself opaque so the camera preview does not show through.
                .presentationBackground(Color(uiColor: .systemGroupedBackground))
            }
            .overlay {
                centeredLandscapeMenuOverlay()
            }
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshBottomGlyphRotation()

                locationManager.start()

                reportLibrary.setActiveReportTitle(recordId)
                reportLibrary.ensureAlbumExists { _ in
                    DispatchQueue.main.async { reportLibrary.reloadAssets() }
                }
                isPollingDeviceOrientation = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                refreshBottomGlyphRotation()
            }
            .onReceive(deviceOrientationPoll) { _ in
                guard isPollingDeviceOrientation else { return }
                refreshBottomGlyphRotation()
            }
            .onDisappear {
                isPollingDeviceOrientation = false
                locationManager.stop()
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            
            
            .onChange(of: recordId) { _, newValue in
                reportLibrary.setActiveReportTitle(newValue)
                reportLibrary.ensureAlbumExists { _ in
                    DispatchQueue.main.async { reportLibrary.reloadAssets() }
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
    

    
     
    
    
    // MARK: - Top right ellipsis circle

    private func topRightEllipsisCircle(size: CGFloat = 44) -> some View {
        @State var isPressed: Bool = false

        return Button(action: {
            showQuickMenu = true
        }) {
            ZStack {
                // Match darker segmented pill tone (same style as detail note quick button)
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: size, height: size)

                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .pressScaleEffect(isPressed)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .zIndex(50)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    // MARK: - Lens toast control

    private func showLensToastNow(_ text: String) {
        lensToastToken += 1
        let token = lensToastToken

        lensToastText = text
        showLensToast = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard token == lensToastToken else { return }
            showLensToast = false
        }
    }

    // MARK: - UI pieces

    @ViewBuilder
    private func landscapeDropdownStack() -> some View {
        let controlH: CGFloat = 36
        let controlW: CGFloat = 190

        let elevationLabel = (locationMode == .interior) ? "Interior" : elevation
        let detailLabel = currentDetailType.isEmpty ? "Select" : currentDetailType

        VStack(alignment: .leading, spacing: 10) {

            // Elevation dropdown (compact) - custom (opens centered overlay)
            Button {
                // Only allow elevation picking in exterior mode
                if locationMode == .interior {
                    return
                }
                showLandscapeDetailMenu = false
                showLandscapeElevationMenu.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(elevationLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                }
                .padding(.horizontal, 12)
                .frame(width: controlW, height: controlH, alignment: .center)
                .background(
                    ZStack {
                        Color.black.opacity(0.65)
                        Color.white.opacity(0.08)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(locationMode == .interior)

            // Detail type dropdown (compact) - custom (opens centered overlay)
            Button {
                showLandscapeElevationMenu = false
                showLandscapeDetailMenu.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text(detailLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.90))
                }
                .padding(.horizontal, 12)
                .frame(width: controlW, height: controlH, alignment: .center)
                .background(
                    ZStack {
                        Color.black.opacity(0.65)
                        Color.white.opacity(0.08)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .transaction { tx in
            tx.animation = nil
        }
    }

    // MARK: - Centered custom overlays for landscape dropdowns

    @ViewBuilder
    private func centeredLandscapeMenuOverlay() -> some View {
        let isShowing = showLandscapeElevationMenu || showLandscapeDetailMenu
        if !isShowing { EmptyView() }
        else {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissLandscapeMenus()
                    }

                VStack(spacing: 12) {
                    if showLandscapeElevationMenu {
                        centeredElevationMenuContent()
                    }

                    if showLandscapeDetailMenu {
                        centeredDetailMenuContent()
                    }
                }
                // Keep the menu readable relative to the physical device, like native camera glyphs
                .rotationEffect(bottomGlyphRotationAngle)
                .padding(.horizontal, 18)
                .frame(maxWidth: 360)
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.18), value: isShowing)
            .zIndex(500)
        }
    }

    private func dismissLandscapeMenus() {
        showLandscapeElevationMenu = false
        showLandscapeDetailMenu = false
    }

    @ViewBuilder
    private func centeredElevationMenuContent() -> some View {
        // Only relevant for exterior; if interior somehow triggers this, show nothing
        if locationMode == .interior {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                centeredMenuHeader(title: "Elevation")

                VStack(spacing: 0) {
                    centeredMenuRow(title: "North Elevation", isSelected: elevation == "North Elevation") {
                        elevation = "North Elevation"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "South Elevation", isSelected: elevation == "South Elevation") {
                        elevation = "South Elevation"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "East Elevation", isSelected: elevation == "East Elevation") {
                        elevation = "East Elevation"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "West Elevation", isSelected: elevation == "West Elevation") {
                        elevation = "West Elevation"
                        dismissLandscapeMenus()
                    }
                }
                .padding(.vertical, 6)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
        }
    }

    @ViewBuilder
    private func centeredDetailMenuContent() -> some View {
        let list = detailTypesModel.types(for: locationMode)

        VStack(spacing: 0) {
            centeredMenuHeader(title: locationMode == .interior ? "Interior Detail Type" : "Exterior Detail Type")

            // Scroll the selectable rows when the list gets long.
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(list) { item in
                        let name = item.name.isEmpty ? " " : item.name
                        let isSelected = (detailTypesModel.selected(for: locationMode) == item.name)

                        centeredMenuRow(title: name, isSelected: isSelected) {
                            detailTypesModel.setSelected(item.name, for: locationMode)
                            dismissLandscapeMenus()
                        }

                        if item.id != list.last?.id {
                            centeredMenuDivider()
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            // Keep the popup from growing off-screen.
            .frame(maxHeight: 320)

            centeredMenuDivider()

            centeredMenuRow(title: "Manage…", isSelected: false) {
                dismissLandscapeMenus()
                manageContext = ManageContext(mode: locationMode)
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

    private func centeredMenuHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.92))
            Spacer()
            Button("Done") {
                dismissLandscapeMenus()
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white.opacity(0.92))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.20))
    }

    private func centeredMenuRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.yellow)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func centeredMenuDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    private func toastPill(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
    }

    private func detailNoteQuickButton(size: CGFloat = 44) -> some View {
        @State var isPressed: Bool = false

        return Button(action: {
            draftDetailNote = detailNote
            showDetailOverlay = true
        }) {
            ZStack {
                // Match the darker segmented pill tone (no border)
                Circle()
                    .fill(Color.white.opacity(hasDetailNote ? 0.20 : 0.14))
                    .frame(width: size, height: size)

                Image(systemName: "note.text")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(hasDetailNote ? .yellow : .white.opacity(0.92))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .pressScaleEffect(isPressed)
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private func locationModeSlider() -> some View {
        Picker("", selection: $locationMode) {
            Text("Interior").tag(LocationMode.interior)
            Text("Exterior").tag(LocationMode.exterior)
        }
        .pickerStyle(.segmented)
        .controlSize(.large) // makes native iOS pill height match larger control sizing
        // Native segmented style with yellow selected text
        .onAppear {
            let normalAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
            ]

            let selectedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.systemYellow,
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
            ]

            UISegmentedControl.appearance().setTitleTextAttributes(normalAttrs, for: .normal)
            UISegmentedControl.appearance().setTitleTextAttributes(selectedAttrs, for: .selected)
        }
        .frame(width: 190)
        .frame(height: 44) // force exact match with 44pt note button height
    }

    private func zoomRowNativeCentered(inWidth w: CGFloat) -> some View {
        let itemW: CGFloat = 36
        let spacing: CGFloat = 10

        let steps = camera.zoomSteps
        let count = steps.count

        let selectedIndex: Int = {
            if let i = steps.firstIndex(where: { camera.isZoomSelected($0) }) { return i }
            return 0
        }()

        let totalW = CGFloat(count) * itemW + CGFloat(max(0, count - 1)) * spacing
        let leading = (w - totalW) / 2.0
        let selectedCenterX = leading + CGFloat(selectedIndex) * (itemW + spacing) + (itemW / 2.0)
        let offsetX = (w / 2.0) - selectedCenterX

        return HStack(spacing: spacing) {
            ForEach(steps) { step in
                let selected = camera.isZoomSelected(step)
                let base = (step.label == "1") ? "1" : step.label
                let label = selected ? "\(base)x" : base

                Button(action: { camera.setZoomStep(step) }) {
                    Text(label)
                        .font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .foregroundColor(selected ? Color.yellow : Color.white.opacity(0.92))
                        .rotationEffect(bottomGlyphRotationAngle)
                        .frame(width: itemW, height: itemW)
                        .background(
                            Group {
                                if selected {
                                    // Match native iOS: slightly lighter translucent circle for active zoom
                                    Circle()
                                        .fill(Color(white: 0.22))
                                        .overlay(
                                            Circle().fill(Color.white.opacity(0.06)).blendMode(.overlay)
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
        .id(camera.selectedZoomId)
        .frame(width: w, alignment: .center)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func directionSlider() -> some View {
        let selection = Binding<Direction>(
            get: { Direction.fromElevation(elevation) },
            set: { elevation = $0.elevationValue }
        )

        return DirectionSegmentedControl(selection: selection)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
    }

    private struct DirectionSegmentedControl: UIViewRepresentable {

        @Binding var selection: Direction

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UISegmentedControl {
            let control = TallSegmentedControl(items: [
                "NORTH",
                "SOUTH",
                "EAST",
                "WEST"
            ])

            // Match selection
            control.selectedSegmentIndex = index(for: selection)
            control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)

            // Even distribution like native pills
            control.apportionsSegmentWidthsByContent = false

            // Use native UIKit appearance (no custom background or border styling)

            // Typography + Photos-style selected blue
            let normalAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.88),
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
            ]

            let selectedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.systemBlue,
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
            ]

            control.setTitleTextAttributes(normalAttrs, for: .normal)
            control.setTitleTextAttributes(selectedAttrs, for: .selected)

            // Make it taller (Music-style) without custom drawing
            control.forcedHeight = 56

            return control
        }

        func updateUIView(_ uiView: UISegmentedControl, context: Context) {
            let idx = index(for: selection)
            if uiView.selectedSegmentIndex != idx {
                uiView.selectedSegmentIndex = idx
            }
        }

        private final class TallSegmentedControl: UISegmentedControl {
            var forcedHeight: CGFloat = 56

            override var intrinsicContentSize: CGSize {
                let size = super.intrinsicContentSize
                return CGSize(width: size.width, height: forcedHeight)
            }

            override func layoutSubviews() {
                super.layoutSubviews()
                // Ensure the control re-evaluates size after layout changes
                invalidateIntrinsicContentSize()
            }
        }

        private func index(for dir: Direction) -> Int {
            switch dir {
            case .north: return 0
            case .south: return 1
            case .east:  return 2
            case .west:  return 3
            }
        }

        final class Coordinator: NSObject {
            var parent: DirectionSegmentedControl

            init(parent: DirectionSegmentedControl) {
                self.parent = parent
            }

            @objc func changed(_ sender: UISegmentedControl) {
                switch sender.selectedSegmentIndex {
                case 0: parent.selection = .north
                case 1: parent.selection = .south
                case 2: parent.selection = .east
                case 3: parent.selection = .west
                default: parent.selection = .north
                }
            }
        }
    }


    private func rightButtonsCluster() -> some View {
        let r: CGFloat = 24
        let gap: CGFloat = 14
        let xOffset: CGFloat = (r + gap)

        func circleIconButton(systemName: String, selected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(selected ? Color.white : Color.white.opacity(0.18))
                        .frame(width: 52, height: 52)

                    Image(systemName: systemName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(selected ? .black : .white)
                }
                .contentShape(Circle())
                .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)
        }

        let lastAsset = reportLibrary.assets.last

        return ZStack {
            circleIconButton(systemName: "note.text", selected: hasDetailNote) {
                draftDetailNote = detailNote
                showDetailOverlay = true
            }
            .offset(x: -xOffset, y: 0)

            RecentAlbumPreviewCircleButton(
                lastAsset: lastAsset,
                size: 52,
                action: { showLibraryFullscreen = true },
                cache: imageCache
            )
            .offset(x: xOffset, y: 0)
        }
    }

    private func capture() {
        camera.capturePhoto { data in
            guard let data else { return }

            reportLibrary.savePhotoDataToAlbum(data: data, location: locationManager.lastLocation) { success in
                DispatchQueue.main.async {
                    if success {
                        successHaptic.notificationOccurred(.success)
                        showSavedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            showSavedToast = false
                        }
                    } else {
                        showNotSavedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                            showNotSavedToast = false
                        }
                    }
                }
            }
        }
    }
}



// MARK: - Report Library Fullscreen (Grid)

private struct ReportLibraryFullscreen: View {

    @ObservedObject var reportLibrary: ReportLibraryModel
    @ObservedObject var cache: AssetImageCache

    @Environment(\.dismiss) private var dismiss
    @State private var orientationResetToken: Int = 0
    // Physical device orientation (UI is portrait locked, we rotate the content ourselves)
    @State private var lastValidOrientation: UIDeviceOrientation = .portrait

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

    private func refreshOrientation() {
        let o = UIDevice.current.orientation

        // Accept only portrait (upright) and the two landscapes.
        // Explicitly ignore portraitUpsideDown so the UI does not snap back to portrait when the phone is inverted.
        // Also ignore transitional/invalid states (faceUp, faceDown, unknown).
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

        // Rebuild zoom view so it re-fits instead of keeping an old zoom scale
        orientationResetToken &+= 1
    }

    private struct ViewerState: Identifiable {
        let id = UUID()
        let startIndex: Int
    }

    @State private var viewerState: ViewerState? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            // When we rotate content inside a portrait locked app, swap the content frame.
            let contentW = isLandscape ? h : w
            let contentH = isLandscape ? w : h

            // Grid config
            let columnsCount: Int = isLandscape ? 5 : 3

            // Portrait should be tight (nearly touching), like landscape
            let spacing: CGFloat = isLandscape ? 2 : 2

            // Reduce portrait side padding so it reads closer to edge to edge
            let horizontalPadding: CGFloat = isLandscape ? 0 : 2

            let totalSpacing = CGFloat(max(0, columnsCount - 1)) * spacing
            let side = (contentW - (horizontalPadding * 2) - totalSpacing) / CGFloat(columnsCount)
            let headerH: CGFloat = isLandscape ? 96 : 112

            ZStack {
                Color.black.ignoresSafeArea()

                // Rotated content container
                ZStack {
                    // Grid
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(side), spacing: spacing, alignment: .center), count: columnsCount),
                            alignment: .center,
                            spacing: spacing
                        ) {
                            ForEach(Array(reportLibrary.assets.enumerated()), id: \.element.localIdentifier) { idx, asset in
                                LibraryThumb(asset: asset, cache: cache, side: side)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewerState = ViewerState(startIndex: idx)
                                    }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                        .padding(.top, headerH)
                        .padding(.bottom, isLandscape ? 0 : 8)
                    }
                    // In landscape, remove safe areas so the grid goes edge to edge.
                    .ignoresSafeArea(isLandscape ? .all : [])

                    // Header overlay (Photos style): stays visible, content can scroll behind it.
                    headerOverlay()
                        .zIndex(50)
                }
                .frame(width: contentW, height: contentH, alignment: .center)
                .rotationEffect(.degrees(rotationDegrees))
                .position(x: w * 0.5, y: h * 0.5)
            }
            // Hide the status bar only in landscape.
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
        .fullScreenCover(item: $viewerState) { state in
            ReportPhotoViewer(
                title: reportLibrary.albumTitle,
                assets: reportLibrary.assets,
                startIndex: state.startIndex,
                cache: cache,
                viewerToken: state.startIndex
            )
        }
    }

    @ViewBuilder
    private func headerOverlay() -> some View {
        VStack(spacing: 0) {
            ZStack {
                // Opaque gradient that keeps header readable while allowing photos behind it.
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.92),
                        Color.black.opacity(0.70),
                        Color.black.opacity(0.35),
                        Color.black.opacity(0.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

                HStack {
                    Text(reportLibrary.albumTitle)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Spacer(minLength: 0)

                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, isLandscape ? 10 : 50)
                .padding(.bottom, 10)
            }
            .frame(height: isLandscape ? 96 : 112)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
    }

    private struct LibraryThumb: View {

        let asset: PHAsset
        @ObservedObject var cache: AssetImageCache
        let side: CGFloat

        @State private var img: UIImage? = nil

        var body: some View {
            ZStack {
                Color.black

                if let img {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    Color.white.opacity(0.06)
                        .frame(width: side, height: side)
                }
            }
            .frame(width: side, height: side)
            .clipped()
            .onAppear {
                if img != nil { return }
                let scale = UIScreen.currentScale
                let px = max(300, side * 3) * scale
                cache.requestThumbnail(for: asset, pixelSize: px) { im in
                    DispatchQueue.main.async {
                        self.img = im
                    }
                }
            }
        }
    }
}



// MARK: - Detail Note Modal (rotates + landscape keyboard)

import Photos


private struct DetailNoteModal: View {

    let elevation: String
    let detailType: String
    let existingNote: String

    let onCancel: () -> Void
    let onSave: (String) -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        elevation: String,
        detailType: String,
        existingNote: String,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String) -> Void
    ) {
        self.elevation = elevation
        self.detailType = detailType
        self.existingNote = existingNote
        self.onCancel = onCancel
        self.onSave = onSave
        _draft = State(initialValue: existingNote)
    }

    private var hasExistingNote: Bool {
        !existingNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ZStack {
            // Opaque background (match grouped list background). Camera preview should not show through.
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isFocused = false
                    onCancel()
                }

            VStack(spacing: 12) {
                Text("\(elevation)  \(detailType)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                ZStack(alignment: .trailing) {
                    TextField("Enter detail note", text: $draft)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .padding(.trailing, draft.isEmpty ? 12 : 34)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.primary)
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(trimmed)
                        }

                    if !draft.isEmpty {
                        Button { draft = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.secondary)
                                .padding(.trailing, 10)
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 10) {
                    Button(action: {
                        isFocused = false
                        onCancel()
                    }) {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white.opacity(0.90))
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .contentShape(Rectangle())

                    Button(action: {
                        isFocused = false
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed)
                    }) {
                        Text(hasExistingNote ? "Update" : "Save")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.white.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.black.opacity(0.10), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
            }
            .padding(16)
            // Match the same adaptive grouped background used by the Interior/Exterior managed lists
            .background(Color.black.opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .offset(y: 0)
        }
        .onAppear {
            // Focus immediately
            isFocused = true
        }
        // Keep the popup centered. Do not let SwiftUI move the layout to avoid the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

// MARK: - Manage Detail Types View

private struct ManageDetailTypesView: View {

    let mode: ContentView.LocationMode
    @ObservedObject var model: DetailTypesModel

    @Environment(\.dismiss) private var dismiss
    @State private var editModeState: EditMode = .inactive
    @FocusState private var focusedRow: UUID?

    private var titleText: String {
        mode == .interior ? "Interior Detail Types" : "Exterior Detail Types"
    }

    private var isEditing: Bool { editModeState == .active }

    var body: some View {
        NavigationStack {
            List {
                let items = model.types(for: mode)

                ForEach(items) { item in
                    rowView(item: item)
                }
                .onDelete { offsets in
                    withAnimation(.none) { model.delete(at: offsets, for: mode) }
                }
                .onMove { source, destination in
                    withAnimation(.none) { model.move(from: source, to: destination, for: mode) } // fixed label for iOS 26
                }
            }
            .environment(\.editMode, $editModeState)
            .listStyle(.insetGrouped)
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if editModeState != .active { editModeState = .active }
                        let newId = model.insertBlankItem(for: mode)
                        DispatchQueue.main.async { focusedRow = newId }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if editModeState == .active {
                            editModeState = .inactive
                            focusedRow = nil
                        } else {
                            editModeState = .active
                        }
                    } label: {
                        if editModeState == .active {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18, weight: .semibold))
                        } else {
                            Text("Edit")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(item: DetailTypesModel.DetailTypeItem) -> some View {
        if isEditing {
            TextField("Name", text: bindingForRow(id: item.id))
                .focused($focusedRow, equals: item.id)
                .submitLabel(.done)
                .onSubmit { focusedRow = nil }
        } else {
            Text(item.name.isEmpty ? " " : item.name)
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.primary)
        }
    }

    private func bindingForRow(id: UUID) -> Binding<String> {
        Binding(
            get: {
                let items = model.types(for: mode)
                return items.first(where: { $0.id == id })?.name ?? ""
            },
            set: { newValue in
                withAnimation(.none) {
                    model.updateItem(newValue, id: id, for: mode)
                }
            }
        )
    }
}

// MARK: - Quick Menu Sheet

private struct QuickMenuSheet: View {

    let glyphRotationAngle: Angle
    let flashSetting: CameraManager.FlashSetting

    @Binding var isGridOn: Bool
    @Binding var isLevelOn: Bool

    let onInteriorList: () -> Void
    let onStamp: () -> Void
    let onExteriorList: () -> Void
    let onFlash: () -> Void
    let onCameraSwap: () -> Void

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 12
            let contentW = geo.size.width - 36
            let btnW = (contentW - (spacing * 2)) / 3.0
            let bottomInset = (btnW / 2.0) + (spacing / 2.0)

            NavigationStack {
                ZStack {
                    Color(white: 0.10).ignoresSafeArea()

                    VStack(spacing: 18) {

                        HStack(spacing: spacing) {
                            QuickMenuButton(glyphRotationAngle: glyphRotationAngle, icon: "seal", title: "STAMP", isSelected: false, selectedStyle: false, action: onStamp)
                                .frame(width: btnW)

                            QuickMenuButton(glyphRotationAngle: glyphRotationAngle, icon: "list.bullet", title: "INTERIOR", isSelected: false, selectedStyle: false, action: onInteriorList)
                                .frame(width: btnW)

                            QuickMenuButton(glyphRotationAngle: glyphRotationAngle, icon: "list.bullet", title: "EXTERIOR", isSelected: false, selectedStyle: false, action: onExteriorList)
                                .frame(width: btnW)
                        }

                        HStack(spacing: spacing) {
                            let flashIcon: String = {
                                switch flashSetting {
                                case .off: return "bolt.slash"
                                case .auto: return "bolt.badge.a"
                                case .on: return "bolt"
                                }
                            }()

                            QuickMenuButton(glyphRotationAngle: glyphRotationAngle, icon: flashIcon, title: "FLASH", isSelected: flashSetting == .on, selectedStyle: true, action: onFlash)
                                .frame(width: btnW)

                            QuickMenuButton(glyphRotationAngle: glyphRotationAngle, icon: "square.grid.3x3", title: "GRID", isSelected: isGridOn, selectedStyle: true) {
                                isGridOn.toggle()
                            }
                            .frame(width: btnW)

                            QuickMenuButton(glyphRotationAngle: glyphRotationAngle, icon: "level", title: "LEVEL", isSelected: isLevelOn, selectedStyle: true) {
                                isLevelOn.toggle()
                            }
                            .frame(width: btnW)
                        }
                        .padding(.horizontal, bottomInset)

                        HStack {
                            Spacer()
                            QuickMenuButton(glyphRotationAngle: glyphRotationAngle, icon: "camera.rotate", title: "CAMERA", isSelected: false, selectedStyle: false, action: onCameraSwap)
                                .frame(width: btnW)
                            Spacer()
                        }
                        .padding(.horizontal, bottomInset)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 18)
                    .padding(.horizontal, 18)
                }
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

private struct QuickMenuButton: View {

    let glyphRotationAngle: Angle
    let icon: String
    let title: String
    let isSelected: Bool
    let selectedStyle: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {

                let bg: Color = {
                    guard selectedStyle else { return Color.white.opacity(0.14) }
                    return isSelected ? Color.white : Color.white.opacity(0.14)
                }()

                let fg: Color = {
                    guard selectedStyle else { return Color.white.opacity(0.92) }
                    return isSelected ? Color.black : Color.white.opacity(0.92)
                }()

                VStack(spacing: 10) {
                    Circle()
                        .fill(bg)
                        .frame(width: 74, height: 74)
                        .overlay(
                            Image(systemName: icon)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(fg)
                        )

                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.90))
                }
                .rotationEffect(glyphRotationAngle)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Grid Overlay

private struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()

        let x1 = rect.minX + rect.width / 3
        let x2 = rect.minX + 2 * rect.width / 3
        let y1 = rect.minY + rect.height / 3
        let y2 = rect.minY + 2 * rect.height / 3

        p.move(to: CGPoint(x: x1, y: rect.minY))
        p.addLine(to: CGPoint(x: x1, y: rect.maxY))

        p.move(to: CGPoint(x: x2, y: rect.minY))
        p.addLine(to: CGPoint(x: x2, y: rect.maxY))

        p.move(to: CGPoint(x: rect.minX, y: y1))
        p.addLine(to: CGPoint(x: rect.maxX, y: y1))

        p.move(to: CGPoint(x: rect.minX, y: y2))
        p.addLine(to: CGPoint(x: rect.maxX, y: y2))

        return p
    }
}

// MARK: - Level Overlay

private struct LevelOverlay: View {

    let rollDegrees: Double
    let isLevel: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let size: CGFloat = min(w, h) * 0.46

            Rectangle()
                .fill(isLevel ? Color.green : Color.white)
                .frame(width: size * 0.72, height: 3)
                .rotationEffect(.degrees(rollDegrees))
                .shadow(color: Color.black.opacity(0.25), radius: 2, x: 0, y: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Level / Horizon model (stable in portrait-locked UI)

final class LevelMotionModel: ObservableObject {

    @Published var rollDegrees: Double = 0
    @Published var isLevel: Bool = false

    private let motion = CMMotionManager()

    // Filtering + hysteresis
    private var filteredDegrees: Double = 0
    private let alpha: Double = 0.18
    private let levelOnThreshold: Double = 1.0
    private let levelOffThreshold: Double = 1.4

    private(set) var isRunning: Bool = false

    func start() {
        guard !isRunning else { return }
        guard motion.isDeviceMotionAvailable else { return }

        isRunning = true
        motion.deviceMotionUpdateInterval = 1.0 / 60.0

        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] m, _ in
            guard let self else { return }
            guard let m else { return }

            let gx = m.gravity.x
            let gy = m.gravity.y

            // Decide portrait vs landscape from gravity (NOT UIDevice.orientation)
            let usePortraitAxis = abs(gy) >= abs(gx)

            var angleRad: Double

            if usePortraitAxis {
                angleRad = m.attitude.roll
                if gy < 0 { angleRad = -angleRad }
            } else {
                angleRad = m.attitude.pitch
                if gx > 0 { angleRad = -angleRad }
            }

            var deg = angleRad * 180.0 / .pi

            if deg > 90 { deg = 90 }
            if deg < -90 { deg = -90 }

            // Low-pass smoothing
            self.filteredDegrees += self.alpha * (deg - self.filteredDegrees)
            self.rollDegrees = self.filteredDegrees

            // Hysteresis for green state
            let absDeg = abs(self.filteredDegrees)
            if self.isLevel {
                if absDeg > self.levelOffThreshold {
                    self.isLevel = false
                }
            } else {
                if absDeg < self.levelOnThreshold {
                    self.isLevel = true
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        motion.stopDeviceMotionUpdates()
        filteredDegrees = 0
        rollDegrees = 0
        isLevel = false
    }
}
// MARK: - Glyph Rotation Motion Model

private final class GlyphRotationMotionModel: ObservableObject {

    @Published var angleDegrees: Double = 0

    private let manager = CMMotionManager()

    // Low pass smoothing to match Apple camera feel
    private var filtered: Double = 0
    private let alpha: Double = 0.18

    func start() {
        guard manager.isDeviceMotionAvailable else { return }

        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self else { return }
            guard let m = motion else { return }

            let g = m.gravity

            // Map gravity to a continuous angle in portrait coordinate space.
            // Portrait upright yields 0.
            // Rotate device left yields about +90 for glyphs.
            // Rotate device right yields about -90 for glyphs.
            let rawRad = atan2(g.x, -g.y)
            let rawDeg = rawRad * 180.0 / Double.pi

            // Invert so glyphs rotate opposite the physical roll.
            var target = -rawDeg

            // Keep it in a stable range so it does not flip.
            if target > 90 { target = 90 }
            if target < -90 { target = -90 }

            filtered = (alpha * target) + ((1.0 - alpha) * filtered)
            angleDegrees = filtered
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

//Testing batch upload
