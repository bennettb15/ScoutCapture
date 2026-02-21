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

private func proportionalCircleGlyphSize(for diameter: CGFloat) -> CGFloat {
    min(30, max(18, (diameter * 0.5).rounded()))
}

private func proportionalCircleTextSize(for diameter: CGFloat) -> CGFloat {
    min(24, max(14, (diameter * 0.42).rounded()))
}


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
        button.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .medium)
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
    private var pendingRetrySaves: [(data: Data, location: CLLocation?, completion: (Bool) -> Void)] = []
    private var didBecomeActiveObserver: NSObjectProtocol?
    private static let reportAlbumRegex = try? NSRegularExpression(
        pattern: #"^([A-Za-z0-9]+)(?:-(\d{4}))?-(\d{3,5})$"#,
        options: []
    )

    init() {
        albumTitle = UserDefaults.standard.string(forKey: activeAlbumTitleKey) ?? ""
        albumLocalId = UserDefaults.standard.string(forKey: activeAlbumIdKey) ?? ""

        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingRetrySaves()
        }
    }

    deinit {
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
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

    func fetchMatchingReportAlbums(completion: @escaping ([String]) -> Void) {
        requestPhotosAuth { authorized in
            guard authorized else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            var parsed: [ParsedReportAlbum] = []
            albums.enumerateObjects { collection, _, _ in
                guard let title = collection.localizedTitle else { return }
                guard let report = Self.parseReportAlbumTitle(title) else { return }
                parsed.append(report)
            }

            let sortedTitles = parsed
                .sorted { lhs, rhs in
                    if lhs.yearSortValue != rhs.yearSortValue {
                        return lhs.yearSortValue > rhs.yearSortValue
                    }
                    if lhs.sequence != rhs.sequence {
                        return lhs.sequence > rhs.sequence
                    }
                    if lhs.prefix != rhs.prefix {
                        return lhs.prefix < rhs.prefix
                    }
                    return lhs.title < rhs.title
                }
                .map(\.title)

            DispatchQueue.main.async {
                completion(sortedTitles)
            }
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
            let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            switch current {
            case .authorized, .limited:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    completion(status == .authorized || status == .limited)
                }
            @unknown default:
                completion(false)
            }
        } else {
            let current = PHPhotoLibrary.authorizationStatus()
            switch current {
            case .authorized:
                completion(true)
            case .limited:
                completion(true)
            case .denied, .restricted:
                completion(false)
            case .notDetermined:
                PHPhotoLibrary.requestAuthorization { status in
                    completion(status == .authorized)
                }
            @unknown default:
                completion(false)
            }
        }
    }

    func warmUpAlbumIfAuthorized() {
        if #available(iOS 14, *) {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard status == .authorized || status == .limited else { return }
        } else {
            let status = PHPhotoLibrary.authorizationStatus()
            guard status == .authorized else { return }
        }

        ensureAlbumExists { ok, _ in
            guard ok else { return }
            DispatchQueue.main.async {
                self.reloadAssets()
            }
        }
    }

    private func updateAlbumLocalId(_ newId: String) {
        if Thread.isMainThread {
            albumLocalId = newId
            UserDefaults.standard.set(newId, forKey: activeAlbumIdKey)
        } else {
            DispatchQueue.main.sync {
                albumLocalId = newId
                UserDefaults.standard.set(newId, forKey: activeAlbumIdKey)
            }
        }
    }

    func ensureAlbumExists(completion: @escaping (Bool, String) -> Void) {

        guard !albumTitle.isEmpty else {
            completion(false, "")
            return
        }

        requestPhotosAuth { authorized in
            guard authorized else {
                completion(false, "")
                return
            }

            if !self.albumLocalId.isEmpty {
                let verify = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [self.albumLocalId], options: nil)
                if verify.firstObject != nil {
                    completion(true, self.albumLocalId)
                    return
                } else {
                    self.updateAlbumLocalId("")
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
                self.updateAlbumLocalId(found.localIdentifier)
                completion(true, found.localIdentifier)
                return
            }

            var createdLocalId = ""

            PHPhotoLibrary.shared().performChanges({
                let create = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: self.albumTitle)
                createdLocalId = create.placeholderForCreatedAssetCollection.localIdentifier
            }, completionHandler: { success, _ in
                if success, !createdLocalId.isEmpty {
                    self.updateAlbumLocalId(createdLocalId)
                    completion(true, createdLocalId)
                } else {
                    completion(false, "")
                }
            })
        }
    }

    func savePhotoDataToAlbum(data: Data, location: CLLocation?, completion: @escaping (Bool) -> Void) {
        savePhotoDataToAlbum(data: data, location: location, retryIfInterrupted: true, completion: completion)
    }

    private func savePhotoDataToAlbum(data: Data, location: CLLocation?, retryIfInterrupted: Bool, completion: @escaping (Bool) -> Void) {
        ensureAlbumExists { ok, albumId in
            guard ok, !albumId.isEmpty else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let fetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
            guard let album = fetch.firstObject else {
                DispatchQueue.main.async { completion(false) }
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

            }, completionHandler: { success, error in
                if success {
                    DispatchQueue.main.async {
                        self.reloadAssets()
                    }
                }

                let didSave = success && !createdAssetId.isEmpty
                if !didSave, retryIfInterrupted, UIApplication.shared.applicationState != .active {
                    DispatchQueue.main.async {
                        self.pendingRetrySaves.append((data: data, location: location, completion: completion))
                    }
                    return
                }

                DispatchQueue.main.async {
                    completion(didSave)
                }
            })
        }
    }

    private func flushPendingRetrySaves() {
        guard !pendingRetrySaves.isEmpty else { return }
        let queued = pendingRetrySaves
        pendingRetrySaves.removeAll()
        for item in queued {
            savePhotoDataToAlbum(data: item.data, location: item.location, retryIfInterrupted: false, completion: item.completion)
        }
    }

    func deleteAssetsFromAlbum(localIdentifiers: [String], completion: @escaping (Bool) -> Void) {
        let ids = Array(Set(localIdentifiers))
        guard !ids.isEmpty else {
            completion(true)
            return
        }

        ensureAlbumExists { ok, albumId in
            guard ok, !albumId.isEmpty else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let albumFetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
            guard let album = albumFetch.firstObject else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let assetsToRemove = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            guard assetsToRemove.count > 0 else {
                DispatchQueue.main.async {
                    self.reloadAssets()
                    completion(true)
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                if let change = PHAssetCollectionChangeRequest(for: album) {
                    change.removeAssets(assetsToRemove)
                }
            }, completionHandler: { success, _ in
                if success {
                    DispatchQueue.main.async {
                        self.reloadAssets()
                    }
                }
                DispatchQueue.main.async {
                    completion(success)
                }
            })
        }
    }

    func deleteAssetsFromLibrary(localIdentifiers: [String], completion: @escaping (Bool) -> Void) {
        let ids = Array(Set(localIdentifiers))
        guard !ids.isEmpty else {
            completion(true)
            return
        }

        requestPhotosAuth { authorized in
            guard authorized else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let assetsToDelete = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            guard assetsToDelete.count > 0 else {
                DispatchQueue.main.async {
                    self.reloadAssets()
                    completion(true)
                }
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(assetsToDelete)
            }, completionHandler: { success, _ in
                if success {
                    DispatchQueue.main.async {
                        self.reloadAssets()
                    }
                }
                DispatchQueue.main.async {
                    completion(success)
                }
            })
        }
    }

    private struct ParsedReportAlbum {
        let title: String
        let prefix: String
        let year: Int?
        let sequence: Int

        var yearSortValue: Int {
            year ?? -1
        }
    }

    private static func parseReportAlbumTitle(_ rawTitle: String) -> ParsedReportAlbum? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let regex = reportAlbumRegex else { return nil }

        let ns = title as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: title, options: [], range: fullRange) else { return nil }
        guard match.numberOfRanges == 4 else { return nil }

        let prefix = ns.substring(with: match.range(at: 1))

        let year: Int? = {
            let range = match.range(at: 2)
            guard range.location != NSNotFound else { return nil }
            return Int(ns.substring(with: range))
        }()

        let sequenceRange = match.range(at: 3)
        guard sequenceRange.location != NSNotFound else { return nil }
        guard let sequence = Int(ns.substring(with: sequenceRange)) else { return nil }

        return ParsedReportAlbum(title: title, prefix: prefix, year: year, sequence: sequence)
    }
}


 
// MARK: - Glass UI Helpers (single style language)

private struct GlassPill: ViewModifier {

    let height: CGFloat
    let horizontalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.system(size: 17, weight: .medium))
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
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
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
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if !meta.detailId.isEmpty {
                        Text(meta.detailId)
                            .font(.system(size: 15, weight: .medium))
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
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                        .frame(minHeight: 42)
                        .padding(.horizontal, 14)
                        .background(Color.black.opacity(0.55))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule()
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
    private let quickButtonHaptic = UIImpactFeedbackGenerator(style: .light)
    private let hdButtonHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let successHaptic = UINotificationFeedbackGenerator()
    
    @StateObject private var camera = CameraManager()
    @StateObject private var levelModel = LevelMotionModel()
    @StateObject private var detailTypesModel = DetailTypesModel()
    @StateObject private var locationManager = LocationManager()
    
    @StateObject private var reportLibrary = ReportLibraryModel()
    @StateObject private var imageCache = AssetImageCache()
    
    @State private var recordId: String = "SC-2026-001"
    @State private var reportPrefix: String = "SC"
    @State private var reportIncludeYear: Bool = true
    @State private var reportYear: Int = Calendar.current.component(.year, from: Date())
    @State private var reportSequence: Int = 1
    @State private var reportPrefixLocked: Bool = true
    @State private var reportYearLocked: Bool = true
    @State private var reportSequenceLocked: Bool = false
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
    @State private var pendingOpenReportMenuFromQuickMenu: Bool = false
    @State private var showReportMenu: Bool = false
    @State private var pendingOpenReportSwitcherFromReportMenu: Bool = false
    @State private var pendingOpenReportEditorFromReportMenu: ReportEditorMode? = nil
    @State private var pendingReopenReportMenuFromChildSheet: Bool = false
    @State private var showReportSwitcher: Bool = false
    @State private var showReportEditor: Bool = false
    @State private var reportEditorMode: ReportEditorMode = .editCurrent
    @State private var availableReportAlbums: [String] = []
    @State private var loadingReportAlbums: Bool = false
    @State private var pendingReportSwitchTitle: String? = nil
    @State private var showReportSwitchConfirmation: Bool = false
    
    // Custom centered overlays for rotated dropdowns (used in landscape-with-portrait-lock UI)
    @State private var showLandscapeElevationMenu: Bool = false
    @State private var showLandscapeDetailMenu: Bool = false
    
    @State private var lensToastText: String = ""
    @State private var showLensToast: Bool = false
    @State private var lensToastToken: Int = 0
    
    @State private var showGrid: Bool = false
    @State private var showLevel: Bool = false
    
    @State private var showHDEnabledToast: Bool = false
    @State private var hdEnabledToastText: String = "HD Enabled"
    @State private var hdEnabledToastToken: Int = 0
    @Environment(\.scenePhase) private var scenePhase
    
    // MARK: - Debug overlay
    
    @State private var debugEnabled: Bool = UserDefaults.standard.bool(forKey: "scout.debug.enabled.v1")
    
    private func setDebugEnabled(_ enabled: Bool) {
        debugEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "scout.debug.enabled.v1")
    }
    
    @State private var showDetailOverlay: Bool = false
    @State private var draftDetailNote: String = ""
    
    @State private var showLibraryFullscreen: Bool = false
    
    // MARK: - Physical device rotation for glyphs (UI is locked to portrait)
    
    @State private var lastValidDeviceOrientation: UIDeviceOrientation = .portrait
    @State private var glyphAngleDegrees: Double = 0
    
    // Polling helps rotation start a touch sooner than UIDevice.orientationDidChangeNotification.
    // This is still discrete (0 / +90 / -90) and does NOT introduce continuous motion.
    @State private var isPollingDeviceOrientation: Bool = false
    
    // During certain UI actions (like swapping cameras), device orientation can briefly flicker.
    // This prevents multiple rotation animations.
    
    @State private var isSwappingCamera: Bool = false
    @State private var suppressRotationUpdatesUntil: Date? = nil
    
    // UI-side truth for which camera is active (used for the toast label)
    @State private var isFrontCameraUI: Bool = false
    
    // Simple toast shown above the Quick Menu sheet during camera swap
    @State private var showCameraSwapToast: Bool = false
    @State private var cameraSwapToastText: String = ""
    @State private var cameraSwapToastToken: Int = 0
    @State private var showCameraSwapBlackout: Bool = false
    @State private var displayedZoomSteps: [ZoomStep] = []
    @State private var zoomStepsWorkItem: DispatchWorkItem? = nil
    private let cameraSwapOverlayDuration: Double = 0.72
    
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
    
    private var isLandscapeUI: Bool {
        lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight
    }
    
    private func debugOverlayInline() -> some View {
        Group {
            if !debugEnabled {
                EmptyView()
            } else {
                let actualDigits = camera.debugMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let targetClean = camera.debugTargetMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let actualText = actualDigits.isEmpty ? "--" : "\(actualDigits)MP"
                
                let targetCore = targetClean.hasPrefix("T") ? targetClean : ("T" + targetClean)
                let targetText = (targetClean.isEmpty || targetClean == "T--") ? "T--" : "\(targetCore)MP"
                
                HStack(spacing: 6) {
                    Text(actualText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.yellow)
                    
                    Text(targetText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.yellow.opacity(0.80))
                }
            }
        }
    }
    
    private func debugOverlayStacked() -> some View {
        Group {
            if !debugEnabled {
                EmptyView()
            } else {
                let actualDigits = camera.debugMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let targetClean = camera.debugTargetMegapixelLabel
                    .replacingOccurrences(of: "MP", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let actualText = actualDigits.isEmpty ? "--" : "\(actualDigits)MP"
                
                let targetCore = targetClean.hasPrefix("T") ? targetClean : ("T" + targetClean)
                let targetText = (targetClean.isEmpty || targetClean == "T--") ? "T--" : "\(targetCore)MP"
                
                VStack(spacing: 2) {
                    Text(actualText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.yellow)
                    
                    Text(targetText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.yellow.opacity(0.80))
                }
            }
        }
    }
    
    private func refreshBottomGlyphRotation() {
        if isSwappingCamera {
            return
        }
        if let until = suppressRotationUpdatesUntil, Date() < until {
            return
        }
        
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
    
    // Helper to instantly sync the glyph rotation to the current device orientation, without animation.
    private func syncGlyphRotationWithoutAnimation() {
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
        
        let target: Double
        switch newValue {
        case .landscapeLeft:
            target = 90
        case .landscapeRight:
            target = -90
        default:
            target = 0
        }
        
        // Snap without animation.
        var tx = Transaction()
        tx.animation = nil
        withTransaction(tx) {
            lastValidDeviceOrientation = newValue
            glyphAngleDegrees = target
        }
    }
    
    
    private func swapCameraWithRotationFreeze() {
        // Prevent double taps
        if isSwappingCamera {
            return
        }
        
        // Freeze orientation updates long enough for the session reconfigure to settle
        isSwappingCamera = true
        suppressRotationUpdatesUntil = Date().addingTimeInterval(2.2)
        
        // Pause polling to prevent repeated refreshes
        isPollingDeviceOrientation = false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            camera.toggleCamera()
            isFrontCameraUI.toggle()
        }
        CATransaction.commit()
        
        // Fixed-duration blackout + toast so behavior is consistent in both directions.
        cameraSwapToastToken += 1
        let toastToken = cameraSwapToastToken
        
        cameraSwapToastText = isFrontCameraUI ? "Front Camera" : "Rear Camera"
        showCameraSwapToast = true
        showCameraSwapBlackout = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + cameraSwapOverlayDuration) {
            guard toastToken == cameraSwapToastToken else { return }
            showCameraSwapToast = false
            showCameraSwapBlackout = false
        }
        
        // After the swap settles, snap to the current stable device orientation WITHOUT animation,
        // then re-enable rotation updates.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            let o = UIDevice.current.orientation
            let stable: UIDeviceOrientation? = {
                switch o {
                case .portrait, .portraitUpsideDown:
                    return .portrait
                case .landscapeLeft, .landscapeRight:
                    return o
                default:
                    return nil
                }
            }()
            
            let newValue = stable ?? lastValidDeviceOrientation
            
            // Snap rotation state without animation.
            var tx = Transaction()
            tx.animation = nil
            withTransaction(tx) {
                lastValidDeviceOrientation = newValue
                
                let target: Double
                switch newValue {
                case .landscapeLeft:
                    target = 90
                case .landscapeRight:
                    target = -90
                default:
                    target = 0
                }
                glyphAngleDegrees = target
            }
            
            // Resume polling
            isPollingDeviceOrientation = true
            
            // Clear suppression shortly after we resume
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                suppressRotationUpdatesUntil = nil
                isSwappingCamera = false
            }
        }
    }
    
    enum LocationMode: String, CaseIterable, Identifiable {
        case interior = "Interior"
        case exterior = "Exterior"
        var id: String { rawValue }
    }
    
    fileprivate enum Direction: String, CaseIterable, Identifiable {
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

    private enum ReportEditorMode {
        case editCurrent
        case newReport
    }

    private struct ParsedReportId {
        let prefix: String
        let year: Int?
        let sequence: Int
    }

    private func parseReportId(_ value: String) -> ParsedReportId? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let regex = try? NSRegularExpression(pattern: #"^([A-Za-z0-9]+)(?:-(\d{4}))?-(\d{3,5})$"#, options: [])
        guard let regex else { return nil }
        let ns = title as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        guard let match = regex.firstMatch(in: title, options: [], range: fullRange) else { return nil }
        guard match.numberOfRanges == 4 else { return nil }

        let prefix = ns.substring(with: match.range(at: 1))
        let year: Int? = {
            let r = match.range(at: 2)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }()
        let sequenceRange = match.range(at: 3)
        guard sequenceRange.location != NSNotFound else { return nil }
        guard let sequence = Int(ns.substring(with: sequenceRange)) else { return nil }
        return ParsedReportId(prefix: prefix, year: year, sequence: sequence)
    }

    private func normalizePrefix(_ value: String) -> String {
        let filtered = value
            .uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return filtered.isEmpty ? "SC" : String(filtered.prefix(8))
    }

    private func normalizeYear(_ value: Int) -> Int {
        min(9999, max(2000, value))
    }

    private func normalizeSequence(_ value: Int) -> Int {
        min(99999, max(0, value))
    }

    private func formatSequenceForId(_ sequence: Int) -> String {
        let n = normalizeSequence(sequence)
        if n < 100 {
            return String(format: "%03d", n)
        }
        return String(n)
    }

    private func composeReportId(prefix: String, includeYear: Bool, year: Int, sequence: Int) -> String {
        let cleanPrefix = normalizePrefix(prefix)
        let cleanYear = normalizeYear(year)
        let seq = formatSequenceForId(sequence)
        if includeYear {
            return "\(cleanPrefix)-\(cleanYear)-\(seq)"
        }
        return "\(cleanPrefix)-\(seq)"
    }

    private func syncReportComponentsFromRecordId() {
        guard let parsed = parseReportId(recordId) else { return }
        reportPrefix = normalizePrefix(parsed.prefix)
        reportIncludeYear = (parsed.year != nil)
        if let parsedYear = parsed.year {
            reportYear = normalizeYear(parsedYear)
        }
        reportSequence = normalizeSequence(parsed.sequence)
    }

    private func openReportMenuFromQuickMenu() {
        pendingOpenReportMenuFromQuickMenu = true
        showQuickMenu = false
    }

    private func openReportSwitcher() {
        pendingOpenReportSwitcherFromReportMenu = true
        showReportMenu = false
    }

    private func openEditCurrentReport() {
        pendingOpenReportEditorFromReportMenu = .editCurrent
        showReportMenu = false
    }

    private func openNewReport() {
        pendingOpenReportEditorFromReportMenu = .newReport
        showReportMenu = false
    }

    private func loadReportAlbumsForSwitching() {
        loadingReportAlbums = true
        reportLibrary.fetchMatchingReportAlbums { titles in
            availableReportAlbums = titles
            loadingReportAlbums = false
        }
    }

    private func requestReportSwitch(to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recordId else { return }
        pendingReportSwitchTitle = trimmed
        showReportSwitchConfirmation = true
    }

    private func confirmReportSwitch() {
        guard let pending = pendingReportSwitchTitle else { return }
        recordId = pending
        showReportSwitcher = false
        pendingReportSwitchTitle = nil
        syncReportComponentsFromRecordId()
    }

    private func openReportEditor(mode: ReportEditorMode) {
        reportEditorMode = mode
        switch mode {
        case .editCurrent:
            syncReportComponentsFromRecordId()
        case .newReport:
            syncReportComponentsFromRecordId()
            reportSequence = normalizeSequence(reportSequence + 1)
            reportSequenceLocked = false
        }
        showReportEditor = true
    }

    private func applyReportEditorSave(prefix: String, includeYear: Bool, year: Int, sequence: Int) {
        reportPrefix = normalizePrefix(prefix)
        reportIncludeYear = includeYear
        reportYear = normalizeYear(year)
        reportSequence = normalizeSequence(sequence)
        recordId = composeReportId(
            prefix: reportPrefix,
            includeYear: reportIncludeYear,
            year: reportYear,
            sequence: reportSequence
        )
        showReportEditor = false
    }

    private func showHDToast(_ text: String, duration: Double = 2.0) {
        hdEnabledToastToken += 1
        let token = hdEnabledToastToken
        hdEnabledToastText = text
        showHDEnabledToast = true

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard token == hdEnabledToastToken else { return }
            showHDEnabledToast = false
        }
    }

    private func backToReportMenuFromChildSheet() {
        pendingReopenReportMenuFromChildSheet = true
        showReportSwitcher = false
        showReportEditor = false
    }

    private func autoRollReportYearIfNeeded() {
        guard let parsed = parseReportId(recordId), parsed.year != nil else { return }
        let currentYear = Calendar.current.component(.year, from: Date())
        guard parsed.year != currentYear else { return }

        recordId = composeReportId(
            prefix: parsed.prefix,
            includeYear: true,
            year: currentYear,
            sequence: parsed.sequence
        )
    }
    
    private var hasDetailNote: Bool {
        !detailNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var currentDetailType: String {
        detailTypesModel.selected(for: locationMode)
    }

    // MARK: - SwiftUI View conformance
    var body: some View {
        contentBody
    }

    @ViewBuilder
    private var contentBody: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            GeometryReader { geo in
                layoutContent(in: geo)
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
                .presentationBackground(.clear)
            }
            .overlay {
                centeredLandscapeMenuOverlay()
            }
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
                refreshBottomGlyphRotation()

                locationManager.start()

                syncReportComponentsFromRecordId()
                autoRollReportYearIfNeeded()
                reportLibrary.setActiveReportTitle(recordId)
                reportLibrary.warmUpAlbumIfAuthorized()
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
                syncReportComponentsFromRecordId()
                reportLibrary.setActiveReportTitle(newValue)
                reportLibrary.warmUpAlbumIfAuthorized()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    autoRollReportYearIfNeeded()
                }
            }
            .onChange(of: detailNote) { _, _ in
                let wasOn = camera.effectiveHDEnabled
                let wasManual = camera.manualHDEnabled

                camera.updateDetailNoteActive(hasDetailNote)

                // If the note just became active and HD was previously off, show toast
                if hasDetailNote && camera.hdSupported && !wasOn && !wasManual {
                    showHDToast("HD Enabled for Detail Capture")
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // 3-dot quick menu
        .sheet(isPresented: $showQuickMenu) {
            QuickMenuSheet(
                glyphRotationAngle: bottomGlyphRotationAngle,
                flashSetting: camera.flashSetting,
                isFrontCamera: isFrontCameraUI,
                isGridOn: $showGrid,
                isLevelOn: $showLevel,
                debugEnabled: debugEnabled,
                onToggleDebug: { newValue in
                    setDebugEnabled(newValue)
                },
                onInteriorList: {
                    showQuickMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        manageContext = ManageContext(mode: .interior)
                    }
                },
                onReport: { openReportMenuFromQuickMenu() },
                onExteriorList: {
                    showQuickMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        manageContext = ManageContext(mode: .exterior)
                    }
                },
                onFlash: { camera.cycleFlash() },
                onCameraSwap: { swapCameraWithRotationFreeze() }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .onDisappear {
                showQuickMenu = false
                if pendingOpenReportMenuFromQuickMenu {
                    pendingOpenReportMenuFromQuickMenu = false
                    DispatchQueue.main.async {
                        showReportMenu = true
                    }
                }
            }
        }
        .sheet(isPresented: $showReportMenu) {
            ReportMenuSheet(
                activeReportTitle: recordId,
                onSwitchReport: { openReportSwitcher() },
                onNewReport: { openNewReport() },
                onEditCurrent: { openEditCurrentReport() }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .onDisappear {
                showReportMenu = false
                if pendingOpenReportSwitcherFromReportMenu {
                    pendingOpenReportSwitcherFromReportMenu = false
                    DispatchQueue.main.async {
                        showReportSwitcher = true
                        loadReportAlbumsForSwitching()
                    }
                }
                if let pendingMode = pendingOpenReportEditorFromReportMenu {
                    pendingOpenReportEditorFromReportMenu = nil
                    DispatchQueue.main.async {
                        openReportEditor(mode: pendingMode)
                    }
                }
            }
        }
        .sheet(isPresented: $showReportSwitcher) {
            ReportSwitcherSheet(
                activeReportTitle: recordId,
                reports: availableReportAlbums,
                isLoading: loadingReportAlbums,
                onRefresh: { loadReportAlbumsForSwitching() },
                onBack: { backToReportMenuFromChildSheet() },
                onSelectReport: { title in
                    requestReportSwitch(to: title)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .onDisappear {
                showReportSwitcher = false
                if pendingReopenReportMenuFromChildSheet {
                    pendingReopenReportMenuFromChildSheet = false
                    DispatchQueue.main.async {
                        showReportMenu = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Switch Report?",
            isPresented: $showReportSwitchConfirmation,
            titleVisibility: .visible
        ) {
            Button("Switch") {
                confirmReportSwitch()
            }
            Button("Cancel", role: .cancel) {
                pendingReportSwitchTitle = nil
            }
        } message: {
            if let pendingReportSwitchTitle {
                Text("Active report will change to \(pendingReportSwitchTitle).")
            }
        }
        .sheet(isPresented: $showReportEditor) {
            ReportIdEditorSheet(
                mode: reportEditorMode,
                prefix: reportPrefix,
                includeYear: reportIncludeYear,
                year: reportYear,
                sequence: reportSequence,
                prefixLocked: reportPrefixLocked,
                yearLocked: reportYearLocked,
                sequenceLocked: reportSequenceLocked,
                onCancel: { backToReportMenuFromChildSheet() },
                onSave: { prefix, includeYear, year, sequence, prefixLocked, yearLocked, sequenceLocked in
                    reportPrefixLocked = prefixLocked
                    reportYearLocked = yearLocked
                    reportSequenceLocked = sequenceLocked
                    applyReportEditorSave(prefix: prefix, includeYear: includeYear, year: year, sequence: sequence)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .onDisappear {
                showReportEditor = false
                if pendingReopenReportMenuFromChildSheet {
                    pendingReopenReportMenuFromChildSheet = false
                    DispatchQueue.main.async {
                        showReportMenu = true
                    }
                }
            }
        }
        // Album fullscreen
        .fullScreenCover(isPresented: $showLibraryFullscreen) {
            ReportLibraryFullscreen(reportLibrary: reportLibrary, cache: imageCache)
        }
        // Manage (from dropdown or quick menu)
        .sheet(item: $manageContext) { ctx in
            ManageDetailTypesView(mode: ctx.mode, model: detailTypesModel)
        }
    }

    @ViewBuilder
    private func layoutContent(in geo: GeometryProxy) -> some View {
        let w = geo.size.width
        let h = geo.size.height

        // Top mask: fixed inset so layout is stable.
        let topInset: CGFloat = 30

        // Fine tune ONLY the internal content position.
        let topContentLift: CGFloat = -22

        // Compact header height.
        let topBarH: CGFloat = topInset + 56

        // Bottom mask should extend fully to the physical bottom of screen.
        let bottomBarH: CGFloat = 178

        let previewH: CGFloat = max(1, h - topBarH - bottomBarH)
        let baseToastTop: CGFloat = 10

        // Type erasure boundary so the compiler does not attempt to build one massive generic type.
        AnyView(
            VStack(spacing: 0) {
                topHeaderView(w: w, topInset: topInset, topContentLift: topContentLift, topBarH: topBarH)
                previewAreaView(w: w, previewH: previewH, baseToastTop: baseToastTop)
                bottomMaskView(bottomBarH: bottomBarH)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .clipped()
        )
    }

    private func topHeaderView(w: CGFloat, topInset: CGFloat, topContentLift: CGFloat, topBarH: CGFloat) -> some View {
        ZStack {
            Color.black

            let rowPadding: CGFloat = 16
            let controlH: CGFloat = 44
            let gap: CGFloat = 10
            let controlW: CGFloat = (w - (rowPadding * 2) - gap) / 2.0

            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text(recordId)
                        .font(.system(size: 30, weight: .medium))
                        .tracking(0.4)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .overlay(alignment: .leading) {
                            Group {
                                if isLandscapeUI {
                                    debugOverlayStacked()
                                } else {
                                    debugOverlayInline()
                                }
                            }
                            .fixedSize()
                            .rotationEffect(bottomGlyphRotationAngle)
                            .padding(.leading, 14)
                            .padding(.top, isLandscapeUI ? 6 : 0)
                            .offset(y: isLandscapeUI ? 0 : 2)
                            .allowsHitTesting(false)
                        }
                }

                if !(lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight) {
                    HStack(spacing: gap) {
                        Button {
                            if locationMode == .interior {
                                return
                            }
                            showLandscapeDetailMenu = false
                            showLandscapeElevationMenu.toggle()
                        } label: {
                            let elevationLabel = (locationMode == .interior) ? "Interior" : elevation

                            HStack(spacing: 8) {
                                Text(elevationLabel)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
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

                        Button {
                            showLandscapeElevationMenu = false
                            showLandscapeDetailMenu.toggle()
                        } label: {
                            HStack(spacing: 8) {
                                Text(currentDetailType.isEmpty ? "Select" : currentDetailType)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.78)

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
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
            .padding(.top, topInset)
            .padding(.bottom, 0)
            .padding(.horizontal, 10)
            .offset(y: topContentLift)
        }
        .frame(height: topBarH)
    }

    private func previewAreaView(w: CGFloat, previewH: CGFloat, baseToastTop: CGFloat) -> some View {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(width: w, height: previewH)
            .background(Color.black)
            .clipped()
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
                .rotationEffect(bottomGlyphRotationAngle)
                .allowsHitTesting(false)
                .zIndex(6)
            }

            if showCameraSwapBlackout {
                Color.black
                    .frame(width: w, height: previewH)
                    .allowsHitTesting(false)
                    .zIndex(85)
            }

            if showCameraSwapToast {
                Text(cameraSwapToastText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, max(14, previewH * 0.18))
                    .zIndex(86)
            }

            if (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight) {
                let isLandscapeLeft = (lastValidDeviceOrientation == .landscapeLeft)
                let rotationDegrees: Double = isLandscapeLeft ? 90 : -90
                let alignment: Alignment = isLandscapeLeft ? .topTrailing : .topLeading
                let anchor: UnitPoint = isLandscapeLeft ? .topTrailing : .topLeading

                Color.clear
                    .frame(width: w, height: previewH)
                    .overlay(alignment: alignment) {
                        let xNudge: CGFloat = isLandscapeLeft ? -10 : 10
                        let yNudge: CGFloat = 200

                        landscapeDropdownStack()
                            .rotationEffect(.degrees(rotationDegrees), anchor: anchor)
                            .offset(x: xNudge, y: yNudge)
                            .compositingGroup()
                    }
                    .zIndex(80)
            }

            if showHDEnabledToast {
                Text(hdEnabledToastText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(26)
            }

            if hasDetailNote {
                let isLandscape = (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight)

                if isLandscape {
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
                .padding(.bottom, 18)
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, isLandscapeUI ? 44 : 0)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(25)
            }

            if showNotSavedToast {
                Text("Photos access needed")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(.top, isLandscapeUI ? 44 : 0)
                    .rotationEffect(bottomGlyphRotationAngle)
                    .allowsHitTesting(false)
                    .zIndex(25)
            }
        }
        .clipped()
        .frame(height: previewH)
        .onAppear {
            shutterHaptic.prepare()
            quickButtonHaptic.prepare()
            hdButtonHaptic.prepare()
        }
        .onChange(of: showLevel) { _, newValue in
            if newValue { levelModel.start() } else { levelModel.stop() }
        }
    }

    private func bottomMaskView(bottomBarH: CGFloat) -> some View {
        ZStack {
            Color.black

            VStack(spacing: 12) {
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
                    .overlay(alignment: .center) {
                        ZStack {
                            hdQuickButton(size: 44)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: -94, y: -12)

                            detailNoteQuickButton(size: 44)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: 94, y: -12)
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(alignment: .center) {
                    RecentAlbumPreviewCircleButton(
                        lastAsset: reportLibrary.assets.last,
                        size: 44,
                        action: {
                            fireQuickButtonHaptic()
                            showLibraryFullscreen = true
                        },
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
    }
}

    

extension ContentView {
    
    // MARK: - Top right ellipsis circle
    
    private struct PopEllipsisButton: View {
        let size: CGFloat
        let onHaptic: () -> Void
        let onTap: () -> Void
        
        @State private var isPressed: Bool = false
        @State private var isPopping: Bool = false
        
        private func triggerPop() {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.08)) {
                isPopping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.08)) {
                    isPopping = false
                }
            }
        }
        
        var body: some View {
            Button(action: {
                onHaptic()
                triggerPop()
                onTap()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: size, height: size)
                    
                    Image(systemName: "ellipsis")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .scaleEffect(isPopping ? 1.12 : 1.0)
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
    }
    
    private func topRightEllipsisCircle(size: CGFloat = 44) -> some View {
        PopEllipsisButton(
            size: size,
            onHaptic: {
                fireQuickButtonHaptic()
            },
            onTap: {
                showQuickMenu = true
            }
        )
        .zIndex(50)
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    
                    Spacer(minLength: 0)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
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
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    
                    Spacer(minLength: 0)
                    
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .medium))
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
        
        ZStack {
            if isShowing {
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
                .rotationEffect(bottomGlyphRotationAngle)
                .padding(.horizontal, 18)
                .frame(maxWidth: 360)
            }
        }
        .allowsHitTesting(isShowing)
        .zIndex(500)
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
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.92))
            Spacer()
            Button("Done") {
                dismissLandscapeMenus()
            }
            .font(.system(size: 14, weight: .medium))
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.95))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                
                Spacer(minLength: 0)
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .medium))
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
            .font(.system(size: 14, weight: .medium))
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
    private struct HDQuickButton: View {
        let size: CGFloat
        let hasDetailNote: Bool
        let isEnabled: Bool
        let isOn: Bool
        let onToggle: () -> Void
        let onForcedTap: () -> Void
        let onHaptic: () -> Void
        
        @State private var isPressed: Bool = false
        @State private var isPopping: Bool = false
        
        private func triggerPop() {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.08)) {
                isPopping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.08)) {
                    isPopping = false
                }
            }
        }
        
        var body: some View {
            Button(action: {
                guard isEnabled else { return }
                onHaptic()
                
                // If detail note exists, HD cannot be turned off.
                // Still provide pop feedback.
                if hasDetailNote {
                    triggerPop()
                    onForcedTap()
                    return
                }
                
                triggerPop()
                onToggle()
            }) {
                ZStack {
                    Circle()
                        .fill(
                            isEnabled
                            ? Color.white.opacity(isOn ? 0.22 : 0.14)
                            : Color.white.opacity(0.08)
                        )
                        .frame(width: size, height: size)
                    
                    // Subtle glow ring when ON
                    Circle()
                        .stroke(
                            isEnabled && isOn ? Color.yellow.opacity(0.55) : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: size + 6, height: size + 6)
                        .opacity(isOn ? 1.0 : 0.0)
                    
                    Text("HD")
                        .font(.system(size: proportionalCircleTextSize(for: size), weight: .medium))
                        .foregroundColor(
                            isEnabled
                            ? (isOn ? .yellow : .white.opacity(0.92))
                            : .white.opacity(0.35)
                        )
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .scaleEffect(isPopping ? 1.12 : 1.0)
                .pressScaleEffect(isPressed)
            }
            .buttonStyle(.plain)
            .frame(width: size, height: size)
            .disabled(!isEnabled)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
        }
    }
    
    private func hdQuickButton(size: CGFloat = 44) -> some View {
        HDQuickButton(
            size: size,
            hasDetailNote: hasDetailNote,
            isEnabled: camera.hdSupported,
            isOn: camera.effectiveHDEnabled,
            onToggle: {
                let wasOn = camera.effectiveHDEnabled
                camera.manualHDEnabled.toggle()
                let isOnNow = camera.effectiveHDEnabled
                if !wasOn && isOnNow {
                    showHDToast("HD Enabled for Detail Capture")
                }
            },
            onForcedTap: {
                showHDToast("HD Enabled for Detail Capture")
            },
            onHaptic: {
                fireHDButtonHaptic()
            }
        )
    }
    private struct PopDetailNoteButton: View {
        let size: CGFloat
        let hasDetailNote: Bool
        let onHaptic: () -> Void
        let onTap: () -> Void
        
        @State private var isPressed: Bool = false
        @State private var isPopping: Bool = false
        
        private func triggerPop() {
            withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.62, blendDuration: 0.08)) {
                isPopping = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.08)) {
                    isPopping = false
                }
            }
        }
        
        var body: some View {
            Button(action: {
                onHaptic()
                triggerPop()
                onTap()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(hasDetailNote ? 0.20 : 0.14))
                        .frame(width: size, height: size)
                    
                    Circle()
                        .stroke(
                            hasDetailNote ? Color.yellow.opacity(0.55) : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: size + 6, height: size + 6)
                        .opacity(hasDetailNote ? 1.0 : 0.0)
                    
                    Image(systemName: "note.text")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(hasDetailNote ? .yellow : .white.opacity(0.92))
                }
                .frame(width: size, height: size)
                .contentShape(Circle())
                .scaleEffect(isPopping ? 1.12 : 1.0)
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
    }
    
    private func detailNoteQuickButton(size: CGFloat = 44) -> some View {
        PopDetailNoteButton(
            size: size,
            hasDetailNote: hasDetailNote,
            onHaptic: {
                fireQuickButtonHaptic()
            },
            onTap: {
                draftDetailNote = detailNote
                showDetailOverlay = true
            }
        )
    }
    
    private func locationModeSlider() -> some View {
        LocationModeNativeSegmentedControl(selection: $locationMode)
        .frame(width: 190)
        .frame(height: 44) // force exact match with 44pt note button height
    }

    private struct LocationModeNativeSegmentedControl: UIViewRepresentable {
        @Binding var selection: LocationMode

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeUIView(context: Context) -> UISegmentedControl {
            let control = FixedHeightSegmentedControl(items: ["Interior", "Exterior"])
            control.forcedHeight = 44
            control.selectedSegmentIndex = index(for: selection)
            control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)

            // Keep native look; only force selected segment away from bright white in light mode.
            control.selectedSegmentTintColor = UIColor(white: 0.28, alpha: 1.0)

            let normalAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .font: UIFont.systemFont(ofSize: 19, weight: .medium)
            ]

            let selectedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.systemYellow,
                .font: UIFont.systemFont(ofSize: 19, weight: .medium)
            ]

            control.setTitleTextAttributes(normalAttrs, for: .normal)
            control.setTitleTextAttributes(selectedAttrs, for: .selected)
            return control
        }

        func updateUIView(_ uiView: UISegmentedControl, context: Context) {
            let idx = index(for: selection)
            if uiView.selectedSegmentIndex != idx {
                uiView.selectedSegmentIndex = idx
            }
        }

        private func index(for mode: LocationMode) -> Int {
            switch mode {
            case .interior: return 0
            case .exterior: return 1
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
            var parent: LocationModeNativeSegmentedControl

            init(parent: LocationModeNativeSegmentedControl) {
                self.parent = parent
            }

            @objc func changed(_ sender: UISegmentedControl) {
                parent.selection = (sender.selectedSegmentIndex == 0) ? .interior : .exterior
            }
        }
    }
    
    private func zoomRowNativeCentered(inWidth w: CGFloat) -> some View {
        let itemW: CGFloat = 36
        let spacing: CGFloat = 10
        
        let steps = displayedZoomSteps.isEmpty ? camera.zoomSteps : displayedZoomSteps
        let count = steps.count
        
        let selectedIndex: Int = {
            if let i = steps.firstIndex(where: { camera.isZoomSelected($0) }) { return i }
            return 0
        }()
        
        let totalW = CGFloat(count) * itemW + CGFloat(max(0, count - 1)) * spacing
        let leading = (w - totalW) / 2.0
        let selectedCenterX = leading + CGFloat(selectedIndex) * (itemW + spacing) + (itemW / 2.0)
        let offsetX = (w / 2.0) - selectedCenterX
        
        // Key used to animate reflow when the available zoom steps change (for example HD toggles).
        let stepsKey = steps.map { String(describing: $0.id) }.joined(separator: ",")
        
        let buttonTransition: AnyTransition = .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
        
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
                // Animate insert/remove (example: 2x and 8x disappear in HD)
                .transition(buttonTransition)
            }
        }
        // Keep selected zoom centered.
        .offset(x: offsetX)
        // Animate horizontal reflow and selection changes.
        .animation(zoomReflowAnimation, value: stepsKey)
        .animation(zoomReflowAnimation, value: camera.selectedZoomId)
        .frame(width: w, alignment: .center)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onAppear {
            syncDisplayedZoomSteps(immediate: true)
        }
        .onChange(of: camera.zoomSteps) { _, _ in
            syncDisplayedZoomSteps(immediate: false)
        }
    }

    private var zoomReflowAnimation: Animation {
        Animation.interactiveSpring(
            response: 0.34,
            dampingFraction: 0.88,
            blendDuration: 0.12
        )
    }

    private func syncDisplayedZoomSteps(immediate: Bool) {
        let target = camera.zoomSteps
        zoomStepsWorkItem?.cancel()
        zoomStepsWorkItem = nil

        guard !target.isEmpty else {
            displayedZoomSteps = []
            return
        }

        if immediate || displayedZoomSteps.isEmpty {
            displayedZoomSteps = target
            return
        }

        let current = displayedZoomSteps
        let currentIds = Set(current.map(\.id))
        let targetIds = Set(target.map(\.id))
        if currentIds == targetIds {
            withAnimation(zoomReflowAnimation) {
                displayedZoomSteps = target
            }
            return
        }

        // Phase 1: when the list shrinks, remove non-native/cropped steps first.
        if target.count < current.count {
            let nativeSet = Set(camera.nativeBackZoomStepIds)
            let removable = current.filter { step in
                !targetIds.contains(step.id) && !nativeSet.contains(step.id)
            }

            if !removable.isEmpty {
                let removableIds = Set(removable.map(\.id))
                withAnimation(zoomReflowAnimation) {
                    displayedZoomSteps = current.filter { !removableIds.contains($0.id) }
                }

                let work = DispatchWorkItem {
                    withAnimation(zoomReflowAnimation) {
                        displayedZoomSteps = target
                    }
                }
                zoomStepsWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
                return
            }
        }

        withAnimation(zoomReflowAnimation) {
            displayedZoomSteps = target
        }
    }
    
    private func directionSlider() -> some View {
        let selection = Binding<ContentView.Direction>(
            get: { ContentView.Direction.fromElevation(elevation) },
            set: { elevation = $0.elevationValue }
        )
        
        return DirectionSegmentedControl(selection: selection)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
    }
    
    private struct DirectionSegmentedControl: UIViewRepresentable {
        
        @Binding var selection: ContentView.Direction
        
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
                .font: UIFont.systemFont(ofSize: 17, weight: .medium)
            ]
            
            let selectedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.systemBlue,
                .font: UIFont.systemFont(ofSize: 17, weight: .medium)
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
        
        private func index(for dir: ContentView.Direction) -> Int {
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
                case 0: parent.selection = ContentView.Direction.north
                case 1: parent.selection = ContentView.Direction.south
                case 2: parent.selection = ContentView.Direction.east
                case 3: parent.selection = ContentView.Direction.west
                default: parent.selection = ContentView.Direction.north
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
                        .font(.system(size: proportionalCircleGlyphSize(for: 52), weight: .medium))
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
    
    private func fireQuickButtonHaptic() {
        quickButtonHaptic.impactOccurred()
        quickButtonHaptic.prepare()
    }
    
    private func fireHDButtonHaptic() {
        quickButtonHaptic.impactOccurred()
        quickButtonHaptic.prepare()
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

        private enum DeleteScope {
            case albumOnly
            case library
        }
        
        @State private var viewerState: ViewerState? = nil
        @State private var isSelectionMode: Bool = false
        @State private var selectedAssetIds: Set<String> = []
        @State private var isDeletingSelection: Bool = false
        @State private var showDeleteDialog: Bool = false
        @State private var isPreparingShare: Bool = false
        @State private var showShareSheet: Bool = false
        @State private var shareItems: [Any] = []
        
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
                let headerH: CGFloat = 80
                
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
                                    LibraryThumb(
                                        asset: asset,
                                        cache: cache,
                                        side: side,
                                        isSelectionMode: isSelectionMode,
                                        isSelected: selectedAssetIds.contains(asset.localIdentifier)
                                    )
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if isSelectionMode {
                                                toggleAssetSelection(asset.localIdentifier)
                                            } else {
                                                viewerState = ViewerState(startIndex: idx)
                                            }
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
                    .overlay(alignment: .bottom) {
                        bottomSelectionActions(bottomInset: isLandscape ? 30 : 32)
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
                    selectedAssetIds.removeAll()
                    isSelectionMode = false
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
            .confirmationDialog(
                "Delete Selected Photos",
                isPresented: $showDeleteDialog,
                titleVisibility: .visible
            ) {
                Button("Remove from Album", role: .destructive) {
                    deleteSelectedAssets(scope: .albumOnly)
                }
                Button("Delete from Photos", role: .destructive) {
                    deleteSelectedAssets(scope: .library)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You selected \(selectedAssetIds.count) photo\(selectedAssetIds.count == 1 ? "" : "s"). \"Remove from Album\" keeps photos in Photos. \"Delete from Photos\" permanently deletes them from your library.")
            }
            .sheet(isPresented: $showShareSheet, onDismiss: {
                shareItems = []
            }) {
                ActivityShareSheet(activityItems: shareItems)
            }
        }
        
        @ViewBuilder
        private func headerOverlay() -> some View {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reportLibrary.albumTitle)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if isSelectionMode {
                                Text("\(selectedAssetIds.count) selected")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.82))
                            }
                        }
                        
                        Spacer(minLength: 0)

                        if isSelectionMode {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    isSelectionMode = false
                                    selectedAssetIds.removeAll()
                                }
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(minHeight: 42)
                                    .padding(.horizontal, 14)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    isSelectionMode = true
                                }
                            } label: {
                                Text("Select")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(minHeight: 42)
                                    .padding(.horizontal, 14)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Button {
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundColor(.white)
                                .frame(minHeight: 42)
                                .padding(.horizontal, 14)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, isLandscape ? 8 : 6)
                    .padding(.bottom, 8)
                }
                .frame(height: 96)
                
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(true)
        }

        @ViewBuilder
        private func bottomSelectionActions(bottomInset: CGFloat) -> some View {
            if isSelectionMode {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.00), location: 0.00),
                            .init(color: Color.black.opacity(0.22), location: 0.45),
                            .init(color: Color.black.opacity(0.52), location: 0.78),
                            .init(color: Color.black.opacity(0.72), location: 1.00)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: isLandscape ? 130 : 185)
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)

                    HStack {
                        circularActionButton(
                            systemName: "square.and.arrow.up",
                            isEnabled: !selectedAssetIds.isEmpty && !isPreparingShare && !isDeletingSelection,
                            tint: .white,
                            action: {
                                shareSelectedAssets()
                            }
                        )

                        Spacer(minLength: 0)

                        Text("Select Items")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)

                        Spacer(minLength: 0)

                        circularActionButton(
                            systemName: "trash",
                            isEnabled: !selectedAssetIds.isEmpty && !isDeletingSelection,
                            tint: .red,
                            action: {
                                showDeleteDialog = true
                            }
                        )
                    }
                    .padding(.horizontal, isLandscape ? 26 : 32)
                    .padding(.bottom, bottomInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(edges: .bottom)
                .transition(.opacity)
                .zIndex(60)
            }
        }

        @ViewBuilder
        private func circularActionButton(
            systemName: String,
            isEnabled: Bool,
            tint: Color,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.58))
                        .frame(width: 50, height: 50)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.26), lineWidth: 1)
                        )

                    if isPreparingShare && systemName == "square.and.arrow.up" {
                        ProgressView()
                            .tint(.white.opacity(0.92))
                    } else {
                        Image(systemName: systemName)
                            .font(.system(size: proportionalCircleGlyphSize(for: 50) + 1, weight: .medium))
                            .foregroundColor(isEnabled ? tint : Color.white.opacity(0.40))
                            .frame(width: 22, height: 22, alignment: .center)
                            .offset(
                                x: systemName == "square.and.arrow.up" ? 0.5 : 0,
                                y: systemName == "square.and.arrow.up" ? -2.0 : 0
                            )
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }

        private func selectedAssetsInDisplayOrder() -> [PHAsset] {
            reportLibrary.assets.filter { selectedAssetIds.contains($0.localIdentifier) }
        }

        private func shareSelectedAssets() {
            let selectedAssets = selectedAssetsInDisplayOrder()
            guard !selectedAssets.isEmpty else { return }
            isPreparingShare = true

            DispatchQueue.global(qos: .userInitiated).async {
                let manager = PHImageManager.default()
                let opts = PHImageRequestOptions()
                opts.isSynchronous = true
                opts.deliveryMode = .highQualityFormat
                opts.resizeMode = .none
                opts.isNetworkAccessAllowed = true

                var images: [UIImage] = []
                images.reserveCapacity(selectedAssets.count)

                for asset in selectedAssets {
                    var outImage: UIImage? = nil
                    manager.requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, _ in
                        if let data, let image = UIImage(data: data) {
                            outImage = image
                        }
                    }
                    if let outImage {
                        images.append(outImage)
                    }
                }

                DispatchQueue.main.async {
                    isPreparingShare = false
                    guard !images.isEmpty else { return }
                    shareItems = images
                    showShareSheet = true
                }
            }
        }

        private func toggleAssetSelection(_ localId: String) {
            if selectedAssetIds.contains(localId) {
                selectedAssetIds.remove(localId)
            } else {
                selectedAssetIds.insert(localId)
            }
        }

        private func deleteSelectedAssets(scope: DeleteScope) {
            let ids = Array(selectedAssetIds)
            guard !ids.isEmpty else { return }
            isDeletingSelection = true
            let completion: (Bool) -> Void = { success in
                isDeletingSelection = false
                if success {
                    selectedAssetIds.removeAll()
                    isSelectionMode = false
                }
            }
            switch scope {
            case .albumOnly:
                reportLibrary.deleteAssetsFromAlbum(localIdentifiers: ids, completion: completion)
            case .library:
                reportLibrary.deleteAssetsFromLibrary(localIdentifiers: ids, completion: completion)
            }
        }
        
        private struct LibraryThumb: View {
            
            let asset: PHAsset
            @ObservedObject var cache: AssetImageCache
            let side: CGFloat
            let isSelectionMode: Bool
            let isSelected: Bool
            
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

                    if isSelectionMode {
                        RoundedRectangle(cornerRadius: 0)
                            .stroke(isSelected ? Color.yellow : Color.white.opacity(0.45), lineWidth: isSelected ? 3 : 1)
                            .frame(width: side, height: side)

                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(isSelected ? .yellow : .white.opacity(0.90))
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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

        private struct ActivityShareSheet: UIViewControllerRepresentable {
            let activityItems: [Any]

            func makeUIViewController(context: Context) -> UIActivityViewController {
                UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
            }

            func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
        }
    }
    
    
    
    // MARK: - Detail Note Modal (rotates + landscape keyboard)
    
    
    
    
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
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        isFocused = false
                        onCancel()
                    }
                
                VStack(spacing: 12) {
                    Text("\(elevation)  \(detailType)")
                        .font(.system(size: 13, weight: .medium))
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
                                    .font(.system(size: 18, weight: .medium))
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
                                .font(.system(size: 15, weight: .medium))
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
                                .font(.system(size: 15, weight: .medium))
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
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.45), radius: 16, x: 0, y: 10)
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

    private struct SheetControlTheme {
        let fill: Color
        let stroke: Color
        let label: Color

        static func forScheme(_ scheme: ColorScheme) -> SheetControlTheme {
            if scheme == .light {
                return SheetControlTheme(
                    fill: Color.white.opacity(0.90),
                    stroke: Color.black.opacity(0.14),
                    label: Color.black.opacity(0.88)
                )
            }
            return SheetControlTheme(
                fill: Color.black.opacity(0.55),
                stroke: Color.white.opacity(0.28),
                label: Color.white
            )
        }
    }

    private struct ManageDetailTypesView: View {
        
        let mode: ContentView.LocationMode
        @ObservedObject var model: DetailTypesModel
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        
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
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
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
                                let newId = model.insertBlankItem(for: mode)
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
                        .overlay(
                            Capsule()
                                .stroke(theme.stroke, lineWidth: 1)
                        )
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
                .padding(.vertical, 0)
                .background(theme.fill)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(theme.stroke, lineWidth: 1)
                )
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
    
    // MARK: - Report Sheets

    private struct ReportMenuSheet: View {
        let activeReportTitle: String
        let onSwitchReport: () -> Void
        let onNewReport: () -> Void
        let onEditCurrent: () -> Void

        var body: some View {
            NavigationStack {
                VStack(spacing: 18) {
                    VStack(spacing: 6) {
                        Text("Active Report")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(activeReportTitle)
                            .font(.system(size: 28, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 18)

                    reportActionRow(
                        icon: "arrow.left.arrow.right",
                        title: "Switch Report",
                        action: onSwitchReport
                    )

                    reportActionRow(
                        icon: "plus.circle",
                        title: "New Report",
                        action: onNewReport
                    )

                    reportActionRow(
                        icon: "pencil",
                        title: "Edit Current Report",
                        action: onEditCurrent
                    )

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .navigationTitle("Report")
                .navigationBarTitleDisplayMode(.inline)
            }
        }

        @ViewBuilder
        private func reportActionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .medium))
                    Text(title)
                        .font(.system(size: 18, weight: .medium))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 54)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private struct ReportSwitcherSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        @Environment(\.dismiss) private var dismiss
        let activeReportTitle: String
        let reports: [String]
        let isLoading: Bool
        let onRefresh: () -> Void
        let onBack: () -> Void
        let onSelectReport: (String) -> Void

        var body: some View {
            NavigationStack {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        iconCapsuleButton(systemName: "chevron.left", action: onBack)

                        Spacer(minLength: 0)

                        HStack(spacing: 0) {
                            Button(action: onRefresh) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundColor(theme.label)
                                    .frame(width: 44, height: 42)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                dismiss()
                            } label: {
                                Text("Done")
                                    .font(.system(size: 18, weight: .medium))
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
                        .overlay(
                            Capsule()
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                    Text("Switch Report")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .padding(.bottom, 8)

                    Group {
                        if isLoading {
                            VStack(spacing: 12) {
                                ProgressView()
                                Text("Loading reports...")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if reports.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "tray")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text("No matching report albums found.")
                                    .font(.system(size: 16, weight: .medium))
                                Text("Only albums matching your report ID format are shown.")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 18)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(reports, id: \.self) { title in
                                Button {
                                    onSelectReport(title)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(title)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(.primary)

                                        Spacer(minLength: 0)

                                        if title == activeReportTitle {
                                            Text("Active")
                                                .font(.system(size: 12, weight: .medium))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.green.opacity(0.16))
                                                .foregroundColor(.green)
                                                .clipShape(Capsule())
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .disabled(title == activeReportTitle)
                            }
                            .listStyle(.insetGrouped)
                        }
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
            }
        }

        @ViewBuilder
        private func iconCapsuleButton(systemName: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(theme.label)
                    .frame(width: 44, height: 42)
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

    private struct ReportIdEditorSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        let mode: ReportEditorMode
        let onCancel: () -> Void
        let onSave: (String, Bool, Int, Int, Bool, Bool, Bool) -> Void

        @State private var prefix: String
        @State private var includeYear: Bool
        @State private var yearText: String
        @State private var sequenceText: String
        @State private var prefixLocked: Bool
        @State private var yearLocked: Bool
        @State private var sequenceLocked: Bool

        init(
            mode: ReportEditorMode,
            prefix: String,
            includeYear: Bool,
            year: Int,
            sequence: Int,
            prefixLocked: Bool,
            yearLocked: Bool,
            sequenceLocked: Bool,
            onCancel: @escaping () -> Void,
            onSave: @escaping (String, Bool, Int, Int, Bool, Bool, Bool) -> Void
        ) {
            self.mode = mode
            self.onCancel = onCancel
            self.onSave = onSave
            _prefix = State(initialValue: prefix)
            _includeYear = State(initialValue: includeYear)
            _yearText = State(initialValue: String(year))
            _sequenceText = State(initialValue: String(sequence))
            _prefixLocked = State(initialValue: prefixLocked)
            _yearLocked = State(initialValue: yearLocked)
            _sequenceLocked = State(initialValue: sequenceLocked)
        }

        private var saveTitle: String {
            switch mode {
            case .editCurrent:
                return "Save"
            case .newReport:
                return "Create"
            }
        }

        private var normalizedPrefix: String {
            let filtered = prefix.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            return filtered.isEmpty ? "SC" : String(filtered.prefix(8))
        }

        private var normalizedYear: Int {
            let parsed = Int(yearText) ?? Calendar.current.component(.year, from: Date())
            return min(9999, max(2000, parsed))
        }

        private var normalizedSequence: Int {
            let parsed = Int(sequenceText) ?? 0
            return min(99999, max(0, parsed))
        }

        private var normalizedSequenceString: String {
            if normalizedSequence < 100 {
                return String(format: "%03d", normalizedSequence)
            }
            return String(normalizedSequence)
        }

        private var previewId: String {
            if includeYear {
                return "\(normalizedPrefix)-\(normalizedYear)-\(normalizedSequenceString)"
            }
            return "\(normalizedPrefix)-\(normalizedSequenceString)"
        }

        var body: some View {
            NavigationStack {
                VStack(spacing: 16) {
                    HStack(spacing: 10) {
                        iconCapsuleButton(systemName: "chevron.left") {
                            onCancel()
                        }

                        Spacer(minLength: 0)

                        textCapsuleButton(title: saveTitle) {
                            onSave(
                                normalizedPrefix,
                                includeYear,
                                normalizedYear,
                                normalizedSequence,
                                prefixLocked,
                                yearLocked,
                                sequenceLocked
                            )
                        }
                    }
                    .padding(.top, 12)

                    VStack(spacing: 4) {
                        Text("Preview")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text(previewId)
                            .font(.system(size: 30, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.70)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)

                    VStack(spacing: 12) {
                        editorRow(
                            label: "Prefix",
                            value: $prefix,
                            keyboard: .asciiCapable,
                            isLocked: $prefixLocked
                        )

                        HStack(spacing: 10) {
                            Text("Year")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 120, alignment: .leading)

                            Toggle("", isOn: $includeYear)
                                .labelsHidden()
                                .disabled(yearLocked)

                            if includeYear {
                                TextField("", text: $yearText)
                                    .keyboardType(.numberPad)
                                    .font(.system(size: 16, weight: .medium))
                                    .disabled(yearLocked)
                                    .padding(.horizontal, 10)
                                    .frame(height: 40)
                                    .background(Color(UIColor.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                Text("Off")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 2)
                            }

                            lockButton(isLocked: $yearLocked)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        editorRow(
                            label: "Report Number",
                            value: $sequenceText,
                            keyboard: .numberPad,
                            isLocked: $sequenceLocked
                        )
                    }

                    Text("Number supports 0 to 99999. Values under 100 display with 3 digits.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .toolbar(.hidden, for: .navigationBar)
            }
            .onChange(of: prefix) { _, newValue in
                let filtered = newValue.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
                if filtered != newValue {
                    prefix = filtered
                }
            }
            .onChange(of: yearText) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    yearText = filtered
                }
                if yearText.count > 4 {
                    yearText = String(yearText.prefix(4))
                }
            }
            .onChange(of: sequenceText) { _, newValue in
                let filtered = newValue.filter(\.isNumber)
                if filtered != newValue {
                    sequenceText = filtered
                }
                if sequenceText.count > 5 {
                    sequenceText = String(sequenceText.prefix(5))
                }
            }
        }

        @ViewBuilder
        private func iconCapsuleButton(systemName: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(theme.label)
                    .frame(width: 44, height: 42)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(theme.stroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder
        private func textCapsuleButton(title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(theme.label)
                    .frame(minHeight: 42)
                    .padding(.horizontal, 14)
                    .background(theme.fill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(theme.stroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }

        @ViewBuilder
        private func editorRow(
            label: String,
            value: Binding<String>,
            keyboard: UIKeyboardType,
            isLocked: Binding<Bool>
        ) -> some View {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 120, alignment: .leading)

                TextField("", text: value)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .keyboardType(keyboard)
                    .font(.system(size: 16, weight: .medium))
                    .disabled(isLocked.wrappedValue)
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                lockButton(isLocked: isLocked)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }

        @ViewBuilder
        private func lockButton(isLocked: Binding<Bool>) -> some View {
            Button {
                isLocked.wrappedValue.toggle()
            } label: {
                Image(systemName: isLocked.wrappedValue ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: proportionalCircleGlyphSize(for: 36), weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(isLocked.wrappedValue ? Color.orange.opacity(0.9) : Color.blue.opacity(0.9))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Quick Menu Sheet
    
    private struct QuickMenuSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        
        let glyphRotationAngle: Angle
        let flashSetting: CameraManager.FlashSetting
        
        // Current active camera (provided by ContentView)
        let isFrontCamera: Bool
        
        @Binding var isGridOn: Bool
        @Binding var isLevelOn: Bool
        
        let debugEnabled: Bool
        let onToggleDebug: (Bool) -> Void
        let onInteriorList: () -> Void
        let onReport: () -> Void
        let onExteriorList: () -> Void
        let onFlash: () -> Void
        
        // Pass the target camera: true = front, false = rear
        let onCameraSwap: () -> Void
        
        var body: some View {
            GeometryReader { geo in
                let spacing: CGFloat = 12
                
                // During sheet presentation / rotation, GeometryReader can briefly report 0 or non-finite sizes.
                // Clamp everything so we never pass a negative or non-finite width into `.frame(width:)`.
                let rawContentW = geo.size.width - 36
                let contentW: CGFloat = rawContentW.isFinite ? max(0, rawContentW) : 0
                
                let rawBtnW = (contentW - (spacing * 2)) / 3.0
                let btnW: CGFloat = rawBtnW.isFinite ? max(0, rawBtnW) : 0
                
                let bottomInset: CGFloat = (btnW / 2.0) + (spacing / 2.0)
                
                NavigationStack {
                    ZStack {
                        Color.clear
                            .ignoresSafeArea()
                        
                        VStack(spacing: 18) {
                            
                            HStack(spacing: spacing) {
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "number.square",
                                    title: "REPORT",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onReport
                                )
                                    .frame(width: btnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "list.bullet",
                                    title: "INTERIOR",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onInteriorList
                                )
                                    .frame(width: btnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "list.bullet",
                                    title: "EXTERIOR",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onExteriorList
                                )
                                    .frame(width: btnW)
                            }

                            Rectangle()
                                .fill(theme.stroke.opacity(0.55))
                                .frame(height: 1)
                                .padding(.horizontal, 10)
                                .padding(.top, 2)
                                .padding(.bottom, 8)
                            
                            HStack(spacing: spacing) {
                                let flashIcon: String = {
                                    switch flashSetting {
                                    case .off: return "bolt.slash"
                                    case .auto: return "bolt.badge.a"
                                    case .on: return "bolt"
                                    }
                                }()
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: flashIcon,
                                    title: "FLASH",
                                    isSelected: flashSetting != .off,
                                    selectedStyle: true,
                                    theme: theme,
                                    action: onFlash
                                )
                                    .frame(width: btnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "square.grid.3x3",
                                    title: "GRID",
                                    isSelected: isGridOn,
                                    selectedStyle: true,
                                    theme: theme
                                ) {
                                    isGridOn.toggle()
                                }
                                .frame(width: btnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "level",
                                    title: "LEVEL",
                                    isSelected: isLevelOn,
                                    selectedStyle: true,
                                    theme: theme
                                ) {
                                    isLevelOn.toggle()
                                }
                                .frame(width: btnW)
                            }
                            .padding(.horizontal, bottomInset)
                            
                            HStack(spacing: spacing) {
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "ladybug",
                                    title: "DEBUG",
                                    isSelected: debugEnabled,
                                    selectedStyle: true,
                                    theme: theme
                                ) {
                                    onToggleDebug(!debugEnabled)
                                }
                                .frame(width: btnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "camera.rotate",
                                    title: "CAMERA",
                                    isSelected: isFrontCamera,
                                    selectedStyle: true,
                                    theme: theme,
                                    action: onCameraSwap
                                )
                                    .frame(width: btnW)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                            
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
        let theme: SheetControlTheme
        let action: () -> Void
        
        var body: some View {
            Button(action: action) {
                VStack(spacing: 10) {
                    let bg: Color = {
                        if isSelected {
                            return theme.fill.opacity(0.96)
                        }
                        return selectedStyle ? theme.fill.opacity(0.82) : theme.fill
                    }()
                    
                    let fg: Color = {
                        if isSelected {
                            return .yellow
                        }
                        return selectedStyle ? theme.label.opacity(0.92) : theme.label
                    }()
                    
                    let ring: Color = isSelected ? Color.yellow.opacity(0.65) : theme.stroke.opacity(0.70)
                    let titleColor: Color = isSelected ? Color.yellow.opacity(0.94) : theme.label.opacity(0.88)
                    
                    VStack(spacing: 10) {
                        Circle()
                            .fill(bg)
                            .frame(width: 74, height: 74)
                            .overlay(
                                Circle()
                                    .stroke(ring, lineWidth: 1)
                            )
                            .overlay(
                                Image(systemName: icon)
                                    .font(.system(size: proportionalCircleGlyphSize(for: 74), weight: .medium))
                                    .foregroundColor(fg)
                            )
                        
                        Text(title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(titleColor)
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
}
//Testing batch upload
