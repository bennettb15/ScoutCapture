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
import AVFoundation

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
    @Published private(set) var activeIssueCount: Int = 0

    private let activeAlbumIdKey = "scout.activeReport.albumLocalId.v1"
    private let activeAlbumTitleKey = "scout.activeReport.albumTitle.v1"
    private let activeIssueCountsKey = "scout.activeReport.activeIssueCountsByTitle.v1"
    private var pendingRetrySaves: [(data: Data, location: CLLocation?, completion: (Bool, String?) -> Void)] = []
    private var didBecomeActiveObserver: NSObjectProtocol?
    private static let reportAlbumRegex = try? NSRegularExpression(
        pattern: #"^([A-Za-z0-9]+)(?:-(\d{4}))?-(\d{3,5})$"#,
        options: []
    )

    init() {
        albumTitle = UserDefaults.standard.string(forKey: activeAlbumTitleKey) ?? ""
        albumLocalId = UserDefaults.standard.string(forKey: activeAlbumIdKey) ?? ""
        activeIssueCount = loadActiveIssueCount(for: albumTitle)

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
            activeIssueCount = loadActiveIssueCount(for: t)
            UserDefaults.standard.set(t, forKey: activeAlbumTitleKey)
            UserDefaults.standard.set("", forKey: activeAlbumIdKey)
        } else {
            albumTitle = t
            activeIssueCount = loadActiveIssueCount(for: t)
            UserDefaults.standard.set(t, forKey: activeAlbumTitleKey)
        }
    }

    func incrementActiveIssueCount() {
        let title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let updated = max(0, activeIssueCount + 1)
        activeIssueCount = updated
        storeActiveIssueCount(updated, for: title)
    }

    func setActiveIssueCount(_ count: Int) {
        let title = albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            activeIssueCount = max(0, count)
            return
        }
        let normalized = max(0, count)
        activeIssueCount = normalized
        storeActiveIssueCount(normalized, for: title)
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

    func savePhotoDataToAlbum(data: Data, location: CLLocation?, completion: @escaping (Bool, String?) -> Void) {
        savePhotoDataToAlbum(data: data, location: location, retryIfInterrupted: true, completion: completion)
    }

    private func savePhotoDataToAlbum(data: Data, location: CLLocation?, retryIfInterrupted: Bool, completion: @escaping (Bool, String?) -> Void) {
        ensureAlbumExists { ok, albumId in
            guard ok, !albumId.isEmpty else {
                DispatchQueue.main.async { completion(false, nil) }
                return
            }

            let fetch = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil)
            guard let album = fetch.firstObject else {
                DispatchQueue.main.async { completion(false, nil) }
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
                    completion(didSave, didSave ? createdAssetId : nil)
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

    private func loadActiveIssueCount(for reportTitle: String) -> Int {
        let key = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return 0 }
        let all = readIssueCountsByTitle()
        return max(0, all[key] ?? 0)
    }

    private func storeActiveIssueCount(_ count: Int, for reportTitle: String) {
        let key = reportTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var all = readIssueCountsByTitle()
        all[key] = max(0, count)
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: activeIssueCountsKey)
    }

    private func readIssueCountsByTitle() -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: activeIssueCountsKey),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return decoded
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
    let detailIdOverride: String?
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

    init(
        title: String,
        assets: [PHAsset],
        startIndex: Int,
        detailIdOverride: String? = nil,
        cache: AssetImageCache,
        viewerToken: Int
    ) {
        self.title = title
        self.assets = assets
        self.startIndex = startIndex
        self.detailIdOverride = detailIdOverride
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
        let detailIdText = detail ?? detailIdOverride ?? "Photo \(index + 1) of \(max(assets.count, 1))"

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
    @EnvironmentObject private var appState: AppState
    private let localStore = LocalStore()
    let onExitToHub: (() -> Void)?
    
    private let shutterHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let quickButtonHaptic = UIImpactFeedbackGenerator(style: .light)
    private let hdButtonHaptic = UIImpactFeedbackGenerator(style: .soft)
    private let successHaptic = UINotificationFeedbackGenerator()
    
    @StateObject private var camera: CameraManager
    @StateObject private var levelModel = LevelMotionModel()
    @StateObject private var detailTypesModel = DetailTypesModel()
    @StateObject private var locationManager = LocationManager()
    
    @StateObject private var reportLibrary = ReportLibraryModel()
    @StateObject private var imageCache = AssetImageCache()
    
    @State private var elevation: String = "North"
    
    @State private var detailNote: String = ""
    @State private var showSavedToast: Bool = false
    @State private var showNotSavedToast: Bool = false
    @State private var showNoFlaggedIssuesToast: Bool = false
    @State private var showResolutionModeToast: Bool = false
    @State private var showFlaggedActionToast: Bool = false
    @State private var flaggedActionToastText: String = ""
    @State private var flaggedActionToastToken: Int = 0
    @State private var isArmedIssueDetailNoteReadOnly: Bool = false
    
    @State private var focusPoint: CGPoint? = nil
    @State private var showFocusRing: Bool = false
    
    @State private var showDetailTypeSheet: Bool = false
    @State var locationMode: LocationMode = .exterior
    
    @State private var showQuickMenu: Bool = false
    @State private var manageContext: ManageContext? = nil
    @State private var showManageBuildingsSheet: Bool = false
    @State private var buildingOptions: [String] = ["B1", "B2", "B3", "B4", "B5", "Add"]
    @State private var selectedBuilding: String = "B1"
    @State private var showActiveIssuesSheet: Bool = false
    @State private var activeObservations: [Observation] = []
    @State private var carryoverIssueBadgeCount: Int = 0
    @State private var showGuidedChecklist: Bool = false
    @State private var guidedShots: [GuidedShot] = []
    @State private var armedGuidedShotID: UUID? = nil
    @State private var armedGuidedRetakeShotID: UUID? = nil
    @State private var guidedReferenceAssetLocalID: String? = nil
    @State private var guidedReferenceThumbnail: UIImage? = nil
    @State private var showGuidedAlignmentOverlay: Bool = false
    @State private var referenceOverlayOpacity: Double = 0.45
    @State private var armedUpdateObservationID: UUID? = nil
    @State private var armedIssueNoteText: String = ""
    @State private var armedIssuePreviousManualHD: Bool? = nil
    @State private var armedIssueRevisedObservationText: String? = nil
    @State private var showArmedReferenceMenu: Bool = false
    @State private var armedReferenceViewerState: ArmedReferenceViewerState? = nil
    @State private var flaggedActionTargetObservation: Observation? = nil
    @State private var pendingFlaggedDecisionShot: Shot? = nil
    @State private var pendingFlaggedDecisionPhotoRef: String? = nil
    @State private var showFlaggedActionPrimaryChoice: Bool = false
    @State private var showFlaggedUpdateCommentChoice: Bool = false
    @State private var showFlaggedUpdatedObservationInput: Bool = false
    @State private var draftUpdatedObservation: String = ""
    @State private var resolutionTargetObservation: Observation? = nil
    @State private var resolutionCapturedShot: Shot? = nil
    @State private var resolutionCapturedPhotoRef: String? = nil
    @State private var resolutionCapturedImage: UIImage? = nil
    
    // Custom centered overlays for rotated dropdowns (used in landscape-with-portrait-lock UI)
    @State private var showLandscapeBuildingMenu: Bool = false
    @State private var showLandscapeElevationMenu: Bool = false
    @State private var showLandscapeDetailMenu: Bool = false
    
    @State private var lensToastText: String = ""
    @State private var showLensToast: Bool = false
    @State private var lensToastToken: Int = 0
    
    @State private var showGrid: Bool = false
    @State private var showLevel: Bool = false

    private let buildingOptionsDefaultsKey = "scout.capture.building.options.v1"

    init(cameraManager: CameraManager = .shared, onExitToHub: (() -> Void)? = nil) {
        _camera = StateObject(wrappedValue: cameraManager)
        self.onExitToHub = onExitToHub
    }
    
    @State private var showHDEnabledToast: Bool = false
    @State private var hdEnabledToastText: String = "HD Enabled"
    @State private var hdEnabledToastToken: Int = 0
    
    // MARK: - Debug overlay
    
    @State private var debugEnabled: Bool = UserDefaults.standard.bool(forKey: "scout.debug.enabled.v1")
    
    private func setDebugEnabled(_ enabled: Bool) {
        debugEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "scout.debug.enabled.v1")
    }
    
    @State private var showDetailOverlay: Bool = false
    @State private var draftDetailNote: String = ""
    
    @State private var showLibraryFullscreen: Bool = false
    @State private var showSessionActionsSheet: Bool = false
    @State private var sessionActionsSummary: SessionActionsSummary? = nil
    @State private var isPreparingSessionExport: Bool = false
    @State private var sessionExportChecklist = ExportChecklistState()
    @State private var sessionExportFile: SessionExportFile? = nil
    @State private var showSessionExportErrorPopup: Bool = false
    @State private var sessionExportErrorMessage: String? = nil
    @State private var didTriggerExitToHubForMissingSession: Bool = false

    private var headerPropertyName: String {
        let trimmed = appState.selectedProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "No Property Selected" : trimmed
    }

    private var hasValidCurrentSession: Bool {
        guard let session = appState.currentSession else { return false }
        guard let selectedPropertyID = appState.selectedPropertyID else { return false }
        return session.propertyID == selectedPropertyID
    }

    private var shouldShowStartingCameraOverlay: Bool {
        guard hasValidCurrentSession else { return false }
        let auth = AVCaptureDevice.authorizationStatus(for: .video)
        guard auth == .authorized else { return false }
        return camera.isStartingPreview || !camera.isPreviewRunning
    }

    private var hasGuidedBaselineForSelectedProperty: Bool {
        guard let propertyID = appState.selectedPropertyID else { return false }
        return appState.propertyHasBaseline(propertyID)
    }

    private var guidedRemainingForCompass: Int {
        guard hasGuidedBaselineForSelectedProperty else { return 0 }
        return guidedShots.filter { !isGuidedShotHandledInCurrentSession($0) }.count
    }

    private var shouldShowGuidedCompassBadge: Bool {
        guidedRemainingForCompass > 0
    }

    private struct ArmedReferenceViewerState: Identifiable {
        let id = UUID()
        let title: String
        let detailId: String
        let localIdentifier: String
    }

    private var flaggedActionTargetObservationTextForPopup: String? {
        guard let observation = flaggedActionTargetObservation else { return nil }
        let note = observation.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !note.isEmpty { return note }
        let statement = observation.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        return statement.isEmpty ? nil : statement
    }

    private static func shortElevationLabel(_ value: String?) -> String {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.contains("north") { return "N" }
        if lower.contains("south") { return "S" }
        if lower.contains("east") { return "E" }
        if lower.contains("west") { return "W" }
        return raw
    }

    private static func conciseContextLabel(building: String?, elevation: String?, detailType: String?) -> String {
        let buildingPart = (building ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let elevationPart = shortElevationLabel(elevation)
        let detailPart = (detailType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return [buildingPart, elevationPart, detailPart]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedContextFilename(_ filename: String) -> String {
        var output = filename
        let replacements: [(String, String)] = [
            ("North Elevation", "N"),
            ("South Elevation", "S"),
            ("East Elevation", "E"),
            ("West Elevation", "W"),
            ("North", "N"),
            ("South", "S"),
            ("East", "E"),
            ("West", "W")
        ]
        for (source, target) in replacements {
            output = output.replacingOccurrences(of: source, with: target, options: .caseInsensitive)
        }
        output = output.replacingOccurrences(of: "Elevation", with: "", options: .caseInsensitive)
        output = output.replacingOccurrences(of: "__", with: "_")
        output = output.replacingOccurrences(of: "  ", with: " ")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct SessionActionsSummary {
        let guidedRemainingCount: Int
        let flaggedRemainingCount: Int
        let hasBaseline: Bool
        let currentSessionCaptureCount: Int

        var isCompletionEligible: Bool {
            hasBaseline && guidedRemainingCount == 0 && flaggedRemainingCount == 0
        }

        var isExportEnabled: Bool {
            if hasBaseline {
                return isCompletionEligible
            }
            return currentSessionCaptureCount > 0
        }

        var isExportLaterEnabled: Bool {
            hasBaseline && isCompletionEligible
        }
    }

    private struct SessionExportFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ExportChecklistState {
        var originalsComplete: Bool = false
        var sessionDataComplete: Bool = false
        var stampedComplete: Bool = false
        var zipReady: Bool = false
    }
    
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

    private var isCaptureTargetArmed: Bool {
        armedGuidedShotID != nil || armedUpdateObservationID != nil
    }

    private func buildingSelectorOverlay() -> some View {
        Button {
            showLandscapeElevationMenu = false
            showLandscapeDetailMenu = false
            showLandscapeBuildingMenu.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selectedBuilding)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                ZStack {
                    Color.black.opacity(0.55)
                    Color.white.opacity(0.08)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCaptureTargetArmed)
    }

    private func elevationPillLabel() -> String {
        if locationMode == .interior { return "Interior" }
        return CanonicalElevation.normalize(elevation) ?? elevation
    }

    private func buildingCode(from option: String) -> String {
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

    private func buildingDisplayName(for option: String) -> String {
        let trimmed = option.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(" - ") {
            return trimmed
        }

        let code = buildingCode(from: trimmed)
        if code == "Add" {
            return "Add - Additional"
        }
        if code.hasPrefix("B") {
            let suffix = code.dropFirst()
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                return "\(code) - Building \(suffix)"
            }
        }
        return code
    }

    private func loadBuildingOptions() {
        guard let data = UserDefaults.standard.data(forKey: buildingOptionsDefaultsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        let cleaned = decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            buildingOptions = cleaned
            let selectedCode = buildingCode(from: selectedBuilding)
            if buildingOptions.contains(where: { buildingCode(from: $0) == selectedCode }) == false {
                selectedBuilding = buildingCode(from: cleaned[0])
            } else {
                selectedBuilding = selectedCode
            }
        }
    }

    private func persistBuildingOptions() {
        let cleaned = buildingOptions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let final = cleaned.isEmpty ? ["B1", "B2", "B3", "B4", "B5", "Add"] : cleaned
        buildingOptions = final
        let selectedCode = buildingCode(from: selectedBuilding)
        if buildingOptions.contains(where: { buildingCode(from: $0) == selectedCode }) == false {
            selectedBuilding = buildingCode(from: final[0])
        } else {
            selectedBuilding = selectedCode
        }
        if let data = try? JSONEncoder().encode(final) {
            UserDefaults.standard.set(data, forKey: buildingOptionsDefaultsKey)
        }
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
            case .north: return "North"
            case .south: return "South"
            case .east:  return "East"
            case .west:  return "West"
            }
        }
        
        static func fromElevation(_ elevation: String) -> Direction {
            switch CanonicalElevation.normalize(elevation) ?? elevation {
            case "South": return .south
            case "East":  return .east
            case "West":  return .west
            default:      return .north
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

                camera.prepareForPreviewAsync()
                camera.ensurePreviewRunningAsync()

                locationManager.start()
                if armedUpdateObservationID == nil && pendingFlaggedDecisionShot == nil {
                    restoreArmedIssueHDIfNeeded()
                }

                reportLibrary.warmUpAlbumIfAuthorized()
                loadBuildingOptions()
                refreshActiveIssues()
                refreshGuidedShots()
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
            .onChange(of: appState.selectedPropertyID) { _, _ in
                resetSelectionForSwitch()
                refreshActiveIssues()
                refreshGuidedShots()
            }
            .onChange(of: appState.currentSession?.id) { _, _ in
                ensureCameraSessionPrecondition()
                if hasValidCurrentSession {
                    camera.ensurePreviewRunningAsync()
                }
                resetSelectionForSwitch()
                refreshActiveIssues()
            }
            .onChange(of: appState.currentSession?.status) { _, _ in
                ensureCameraSessionPrecondition()
                if hasValidCurrentSession {
                    camera.ensurePreviewRunningAsync()
                }
                resetSelectionForSwitch()
                refreshActiveIssues()
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
            .onAppear {
                ensureCameraSessionPrecondition()
                if hasValidCurrentSession {
                    camera.ensurePreviewRunningAsync()
                }
            }

            if showSessionActionsSheet, let summary = sessionActionsSummary {
                SessionActionsSheet(
                    summary: summary,
                    isPreparingExport: isPreparingSessionExport,
                    onResume: {
                        showSessionActionsSheet = false
                    },
                    onSaveDraftAndExit: {
                        handleSaveDraftAndExit(summary: summary)
                    },
                    onExportNow: {
                        startExportNowFlow()
                    },
                    onExportLater: {
                        handleExportLaterAndExit(summary: summary)
                    }
                )
                .zIndex(500)
            }

            if isPreparingSessionExport {
                SessionExportChecklistOverlay(checklist: sessionExportChecklist)
                    .zIndex(700)
            }

            if showSessionExportErrorPopup {
                ExportErrorOverlay(
                    title: "Export Failed",
                    message: sessionExportErrorMessage ?? "Unable to build export ZIP.",
                    retryTitle: "Retry",
                    cancelTitle: "Cancel",
                    onRetry: {
                        showSessionExportErrorPopup = false
                        startExportNowFlow()
                    },
                    onCancel: {
                        showSessionExportErrorPopup = false
                    }
                )
                .zIndex(710)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // 3-dot quick menu
        .sheet(isPresented: $showQuickMenu) {
            QuickMenuSheet(
                glyphRotationAngle: bottomGlyphRotationAngle,
                flashSetting: camera.flashSetting,
                isFrontCamera: isFrontCameraUI,
                selectedBuildingLabel: selectedBuilding,
                isGridOn: $showGrid,
                isLevelOn: $showLevel,
                onBuildingList: {
                    showQuickMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        showLandscapeElevationMenu = false
                        showLandscapeDetailMenu = false
                        showLandscapeBuildingMenu = true
                    }
                },
                onInteriorList: {
                    showQuickMenu = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        manageContext = ManageContext(mode: .interior)
                    }
                },
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
            }
        }
        .sheet(isPresented: $showManageBuildingsSheet, onDismiss: {
            persistBuildingOptions()
        }) {
            ManageBuildingsSheet(
                options: $buildingOptions,
                selectedBuilding: $selectedBuilding,
                buildingCodeForOption: buildingCode(from:),
                buildingFullLabelForOption: buildingDisplayName(for:),
                onClose: {
                    showManageBuildingsSheet = false
                }
            )
        }
        // Album fullscreen
        .fullScreenCover(isPresented: $showLibraryFullscreen) {
            ReportLibraryFullscreen(reportLibrary: reportLibrary, cache: imageCache)
        }
        // Manage (from dropdown or quick menu)
        .sheet(item: $manageContext) { ctx in
            ManageDetailTypesView(mode: ctx.mode, model: detailTypesModel)
        }
        .fullScreenCover(isPresented: $showActiveIssuesSheet) {
            ActiveIssuesSheet(
                observations: activeObservations,
                currentSessionID: appState.currentSession?.id,
                cache: imageCache,
                onRefresh: {
                    refreshActiveIssues()
                },
                onSelectIssue: { observation in
                    beginFlaggedIssueInteraction(observation)
                },
                onRetakeIssue: { observation in
                    beginFlaggedIssueInteraction(observation)
                }
            )
        }
        .fullScreenCover(isPresented: $showGuidedChecklist) {
            GuidedChecklistOverlay(
                guidedShots: guidedShots,
                currentSessionID: appState.currentSession?.id,
                currentSessionStartedAt: appState.currentSession?.startedAt,
                currentSessionEndedAt: appState.currentSession?.endedAt,
                cache: imageCache,
                onClose: {
                    showGuidedChecklist = false
                },
                onRefresh: {
                    refreshGuidedShots()
                },
                onSelectPending: { guidedShot in
                    armGuidedShot(guidedShot)
                },
                onSkip: { guidedShot, reason, otherNote in
                    markGuidedShotSkipped(guidedShot, reason: reason, otherNote: otherNote)
                },
                onUndoSkip: { guidedShot in
                    undoGuidedShotSkip(guidedShot)
                },
                onRetake: { guidedShot in
                    armGuidedRetake(guidedShot)
                }
            )
        }
        .sheet(item: $sessionExportFile) { file in
            SessionDocumentExportPicker(
                fileURL: file.url,
                onComplete: { didExport in
                    if didExport {
                        finalizeBaselineIfNeededAfterSuccessfulExport()
                        appState.markCurrentSessionExported()
                    }
                    sessionExportFile = nil
                    appState.refreshProperties()
                    onExitToHub?()
                }
            )
        }
        .fullScreenCover(item: $armedReferenceViewerState) { state in
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [state.localIdentifier], options: nil)
            let assets = fetch.firstObject.map { [$0] } ?? []
            ReportPhotoViewer(
                title: state.title,
                assets: assets,
                startIndex: 0,
                detailIdOverride: state.detailId,
                cache: imageCache,
                viewerToken: state.localIdentifier.hashValue
            )
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
                bottomMaskView(bottomBarH: bottomBarH, containerWidth: w)
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
            let gap: CGFloat = 8

            VStack(spacing: 10) {
                VStack(spacing: 2) {
                    Text(headerPropertyName)
                        .font(.system(size: 30, weight: .medium))
                        .tracking(0.4)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .overlay(alignment: .trailing) {
                            Button {
                                presentSessionActionsSheet()
                            } label: {
                                Group {
                                    if isLandscapeUI {
                                        VStack(spacing: 0) {
                                            Text("End")
                                            Text("Session")
                                        }
                                        .font(.system(size: 14, weight: .semibold))
                                        .multilineTextAlignment(.center)
                                    } else {
                                        Text("End Session")
                                            .font(.system(size: 16, weight: .semibold))
                                    }
                                }
                                .foregroundColor(.red.opacity(0.95))
                                .shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1)
                                .rotationEffect(isLandscapeUI ? bottomGlyphRotationAngle : .zero)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, rowPadding)
                        }
                }

                if !(lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight) {
                    HStack(spacing: gap) {
                        Button {
                            showLandscapeElevationMenu = false
                            showLandscapeDetailMenu = false
                            showLandscapeBuildingMenu.toggle()
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedBuilding)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.90))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: controlH, alignment: .center)
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
                        .disabled(isCaptureTargetArmed)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            showLandscapeBuildingMenu = false
                            if locationMode == .interior {
                                return
                            }
                            showLandscapeDetailMenu = false
                            showLandscapeElevationMenu.toggle()
                        } label: {
                            let elevationLabel = elevationPillLabel()

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
                            .frame(height: controlH, alignment: .center)
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
                        .disabled(locationMode == .interior || isCaptureTargetArmed)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            showLandscapeBuildingMenu = false
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
                            .frame(maxWidth: .infinity, minHeight: controlH, maxHeight: controlH, alignment: .center)
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
                        .disabled(isCaptureTargetArmed)
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
        .frame(height: topBarH + (isLandscapeUI ? 0 : 6))
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

            if shouldShowStartingCameraOverlay {
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

            if showLevel {
                LevelOverlay(
                    rollDegrees: levelModel.rollDegrees,
                    isLevel: levelModel.isLevel
                )
                .rotationEffect(bottomGlyphRotationAngle)
                .allowsHitTesting(false)
                .zIndex(6)
            }

            topLeftPreviewPlaceholders()
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: lastValidDeviceOrientation == .landscapeRight ? .topTrailing : .topLeading
                )
                .padding(.top, 14)
                .padding(.leading, lastValidDeviceOrientation == .landscapeRight ? 0 : 14)
                .padding(.trailing, lastValidDeviceOrientation == .landscapeRight ? 14 : 0)
                .zIndex(12)

            if showGuidedAlignmentOverlay && isCaptureTargetArmed {
                if let reference = guidedReferenceThumbnail {
                    Image(uiImage: reference)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: previewH)
                        .clipped()
                        .opacity(referenceOverlayOpacity)
                        .allowsHitTesting(false)
                        .zIndex(10)
                } else {
                    Text("No reference available")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.62))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.18), lineWidth: 1)
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .rotationEffect(bottomGlyphRotationAngle)
                        .allowsHitTesting(false)
                        .zIndex(11)
                }
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

            if hasDetailNote &&
                armedUpdateObservationID == nil &&
                !showFlaggedActionPrimaryChoice &&
                !showFlaggedUpdateCommentChoice &&
                !showFlaggedUpdatedObservationInput {
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

            if showGuidedAlignmentOverlay && isCaptureTargetArmed && guidedReferenceThumbnail != nil {
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.lefthalf.filled")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                        Slider(value: $referenceOverlayOpacity, in: 0.1...0.9)
                            .tint(.blue)
                        Image(systemName: "circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.88))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.horizontal, 26)
                .padding(.bottom, 74)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(21)
            }

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

            if showNoFlaggedIssuesToast {
                Text("No active flagged issues")
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

            if showFlaggedActionToast {
                Text(flaggedActionToastText)
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

            if armedUpdateObservationID != nil &&
                !showFlaggedActionPrimaryChoice &&
                !showFlaggedUpdateCommentChoice &&
                !showFlaggedUpdatedObservationInput {
                let isLandscape = (lastValidDeviceOrientation == .landscapeLeft || lastValidDeviceOrientation == .landscapeRight)
                if isLandscape {
                    toastPill(text: armedIssueNoteText.isEmpty ? "Flagged issue armed" : armedIssueNoteText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 96)
                        .padding(.horizontal, 18)
                        .rotationEffect(bottomGlyphRotationAngle)
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                        .allowsHitTesting(false)
                        .zIndex(26)
                } else {
                    toastPill(text: armedIssueNoteText.isEmpty ? "Flagged issue armed" : armedIssueNoteText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, baseToastTop)
                        .padding(.horizontal, 18)
                        .allowsHitTesting(false)
                        .zIndex(26)
                }
            }

            if showResolutionModeToast {
                Text("Resolution mode active. Capture a resolution photo.")
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

            if showFlaggedActionPrimaryChoice {
                Color.black.opacity(0.62)
                    .frame(width: w, height: previewH)
                    .zIndex(96)

                VStack(spacing: 12) {
                    Text("Flagged Capture")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Apply this capture as an update or resolve this issue?")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)

                    VStack(spacing: 10) {
                        Button("Update") {
                            selectFlaggedPrimaryUpdate()
                        }
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        Button("Resolve") {
                            selectFlaggedPrimaryResolve()
                        }
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(97)
            }

            if showFlaggedUpdateCommentChoice {
                Color.black.opacity(0.62)
                    .frame(width: w, height: previewH)
                    .zIndex(96)

                VStack(spacing: 12) {
                    Text("Update Observation")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Choose how to handle the observation text for this update.")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)

                    if let original = flaggedActionTargetObservationTextForPopup {
                        Text(original)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    VStack(spacing: 10) {
                        Button("Leave Observation Unchanged") {
                            selectFlaggedUpdateLeaveUnchanged()
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        Button("Revise Observation") {
                            selectFlaggedUpdateRevise()
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(97)
            }

            if showFlaggedUpdatedObservationInput {
                Color.black.opacity(0.62)
                    .frame(width: w, height: previewH)
                    .zIndex(96)

                VStack(spacing: 12) {
                    Text("Updated Observation")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Describe visible condition only. No measurements or structural conclusions.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.88))
                        .multilineTextAlignment(.center)

                    if let original = flaggedActionTargetObservationTextForPopup {
                        Text(original)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.94))
                            .lineLimit(3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    TextField("Updated Observation", text: $draftUpdatedObservation, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .foregroundColor(.primary)

                    VStack(spacing: 10) {
                        Button("Save and Capture") {
                            commitFlaggedUpdatedObservationAndArm()
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(draftUpdatedObservation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.blue.opacity(0.35) : Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .disabled(draftUpdatedObservation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Back") {
                            showFlaggedUpdatedObservationInput = false
                            showFlaggedUpdateCommentChoice = true
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color.white.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.76))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(97)
            }

            if showArmedReferenceMenu && isCaptureTargetArmed {
                armedReferenceActionOverlay()
                    .frame(width: w, height: previewH)
                    .zIndex(98)
            }

            if let freezeFrame = resolutionCapturedImage {
                Color.black.opacity(0.82)
                    .frame(width: w, height: previewH)
                    .zIndex(100)

                Image(uiImage: freezeFrame)
                    .resizable()
                    .scaledToFit()
                    .frame(width: w, height: previewH)
                    .clipped()
                    .zIndex(101)

                VStack(spacing: 12) {
                    Text("Confirm Resolution Photo")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)

                    HStack(spacing: 10) {
                        Button("Retake") {
                            resetResolutionCapturePreview()
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        Button("Confirm") {
                            confirmResolution()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
                .rotationEffect(bottomGlyphRotationAngle)
                .zIndex(102)
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

    private func bottomMaskView(bottomBarH: CGFloat, containerWidth: CGFloat) -> some View {
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
                        let hdOffsetX: CGFloat = -94
                        let leftEdgeX: CGFloat = -(containerWidth * 0.5)
                        let cancelOffsetX: CGFloat = (leftEdgeX + hdOffsetX) * 0.5

                        ZStack {
                            if isCaptureTargetArmed {
                                Button {
                                    fireQuickButtonHaptic()
                                    resetSelectionForSwitch()
                                } label: {
                                    ZStack {
                                        Circle()
                                            .fill(Color.red.opacity(0.95))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: "xmark")
                                            .font(.system(size: 16, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .buttonStyle(.plain)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: cancelOffsetX, y: -12)
                            }

                            hdQuickButton(size: 44)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: hdOffsetX, y: -12)

                            detailNoteQuickButton(size: 44)
                                .rotationEffect(bottomGlyphRotationAngle)
                                .offset(x: 94, y: -12)

                            if isCaptureTargetArmed {
                                ZStack(alignment: .topTrailing) {
                                    guidedReferenceCard(size: 88)
                                        .rotationEffect(bottomGlyphRotationAngle)

                                    Button {
                                        fireQuickButtonHaptic()
                                        showArmedReferenceMenu = true
                                    } label: {
                                        Image(systemName: "ellipsis.circle.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.90))
                                            .background(
                                                Circle()
                                                    .fill(Color.black.opacity(0.45))
                                                    .frame(width: 18, height: 18)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 6, y: -6)
                                }
                                .offset(x: 170, y: -12)
                            }
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
        
        let elevationLabel = elevationPillLabel()
        let detailLabel = currentDetailType.isEmpty ? "Select" : currentDetailType
        
        VStack(alignment: .leading, spacing: 10) {
            
            // Elevation dropdown (compact) - custom (opens centered overlay)
            Button {
                showLandscapeBuildingMenu = false
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
            .disabled(locationMode == .interior || isCaptureTargetArmed)
            
            // Detail type dropdown (compact) - custom (opens centered overlay)
            Button {
                showLandscapeBuildingMenu = false
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
            .disabled(isCaptureTargetArmed)
        }
        .transaction { tx in
            tx.animation = nil
        }
    }
    
    // MARK: - Centered custom overlays for landscape dropdowns
    
    @ViewBuilder
    private func centeredLandscapeMenuOverlay() -> some View {
        let isShowing = showLandscapeBuildingMenu || showLandscapeElevationMenu || showLandscapeDetailMenu
        
        ZStack {
            if isShowing {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissLandscapeMenus()
                    }
                
                VStack(spacing: 12) {
                    if showLandscapeBuildingMenu {
                        centeredBuildingMenuContent()
                    }

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
        showLandscapeBuildingMenu = false
        showLandscapeElevationMenu = false
        showLandscapeDetailMenu = false
    }

    @ViewBuilder
    private func centeredBuildingMenuContent() -> some View {
        VStack(spacing: 0) {
            centeredMenuHeader(title: "Building")

            VStack(spacing: 0) {
                ForEach(buildingOptions, id: \.self) { option in
                    let optionCode = buildingCode(from: option)
                    centeredMenuRow(title: buildingDisplayName(for: option), isSelected: selectedBuilding == optionCode) {
                        selectedBuilding = optionCode
                        dismissLandscapeMenus()
                    }

                    if option != buildingOptions.last {
                        centeredMenuDivider()
                    }
                }

                centeredMenuDivider()
                centeredMenuRow(title: "Manage...", isSelected: false) {
                    dismissLandscapeMenus()
                    showManageBuildingsSheet = true
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
    
    @ViewBuilder
    private func centeredElevationMenuContent() -> some View {
        // Only relevant for exterior; if interior somehow triggers this, show nothing
        if locationMode == .interior {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                centeredMenuHeader(title: "Elevation")
                
                VStack(spacing: 0) {
                    centeredMenuRow(title: "North", isSelected: elevation == "North") {
                        elevation = "North"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "South", isSelected: elevation == "South") {
                        elevation = "South"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "East", isSelected: elevation == "East") {
                        elevation = "East"
                        dismissLandscapeMenus()
                    }
                    centeredMenuDivider()
                    centeredMenuRow(title: "West", isSelected: elevation == "West") {
                        elevation = "West"
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
                        .foregroundColor(.white)
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
                            ? (isOn ? Color.blue : Color.white.opacity(0.14))
                            : Color.white.opacity(0.08)
                        )
                        .frame(width: size, height: size)
                    
                    // Subtle glow ring when ON
                    Circle()
                        .stroke(
                            isEnabled && isOn ? Color.white.opacity(0.70) : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: size + 6, height: size + 6)
                        .opacity(isOn ? 1.0 : 0.0)
                    
                    Text("HD")
                        .font(.system(size: proportionalCircleTextSize(for: size), weight: .medium))
                        .foregroundColor(
                            isEnabled
                            ? (isOn ? .white : .white.opacity(0.92))
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
                        .fill(hasDetailNote ? Color.blue : Color.white.opacity(0.14))
                        .frame(width: size, height: size)
                    
                    Circle()
                        .stroke(
                            hasDetailNote ? Color.white.opacity(0.70) : Color.clear,
                            lineWidth: 2
                        )
                        .frame(width: size + 6, height: size + 6)
                        .opacity(hasDetailNote ? 1.0 : 0.0)
                    
                    Image(systemName: "note.text")
                        .font(.system(size: proportionalCircleGlyphSize(for: size), weight: .medium))
                        .foregroundColor(hasDetailNote ? .white : .white.opacity(0.92))
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
                guard !isArmedIssueDetailNoteReadOnly else { return }
                draftDetailNote = detailNote
                showDetailOverlay = true
            }
        )
    }

    private func guidedReferenceCard(size: CGFloat = 88) -> some View {
        Button(action: {
            fireQuickButtonHaptic()
            showGuidedAlignmentOverlay.toggle()
        }) {
            Group {
                if let guidedReferenceThumbnail {
                    Image(uiImage: guidedReferenceThumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "photo")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func armedReferenceActionOverlay() -> some View {
        let items = [
            SharedActionMenuItem(
                title: "Retake",
                isEnabled: true,
                action: {
                    showArmedReferenceMenu = false
                    performArmedReferenceRetake()
                }
            ),
            SharedActionMenuItem(
                title: "View Reference Image",
                isEnabled: armedReferenceImageLocalIdentifier(isCaptured: false) != nil,
                action: {
                    showArmedReferenceMenu = false
                    showArmedReferenceImage(isCaptured: false)
                }
            ),
            SharedActionMenuItem(
                title: "View Captured Image",
                isEnabled: armedReferenceImageLocalIdentifier(isCaptured: true) != nil,
                action: {
                    showArmedReferenceMenu = false
                    showArmedReferenceImage(isCaptured: true)
                }
            )
        ]

        SharedActionMenuOverlay(
            rotation: bottomGlyphRotationAngle,
            items: items,
            onDismiss: { showArmedReferenceMenu = false }
        )
    }

    private func armedReferenceImageLocalIdentifier(isCaptured: Bool) -> String? {
        if let guidedID = armedGuidedShotID,
           let guided = guidedShots.first(where: { $0.id == guidedID }) {
            let raw = isCaptured
                ? guided.shot?.imageLocalIdentifier
                : guided.referenceImageLocalIdentifier
            let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if isCaptured {
                guard isShotCapturedInCurrentSession(guided.shot) else { return nil }
                return trimmed.isEmpty ? nil : trimmed
            }
            return trimmed.isEmpty ? nil : trimmed
        }

        guard let flaggedID = armedUpdateObservationID,
              let propertyID = appState.selectedPropertyID,
              let observations = try? localStore.fetchObservations(propertyID: propertyID),
              let observation = observations.first(where: { $0.id == flaggedID }) else {
            return nil
        }

        let sorted = observation.shots.sorted { $0.capturedAt < $1.capturedAt }
        let raw = isCaptured
            ? capturedImageLocalIdentifierForCurrentSession(observation)
            : sorted.first?.imageLocalIdentifier
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func armedReferenceDetailLabel() -> String {
        if let guidedID = armedGuidedShotID,
           let guided = guidedShots.first(where: { $0.id == guidedID }) {
            return Self.conciseContextLabel(
                building: guided.building,
                elevation: guided.targetElevation,
                detailType: guided.detailType
            )
        }
        if let flaggedID = armedUpdateObservationID,
           let propertyID = appState.selectedPropertyID,
           let observations = try? localStore.fetchObservations(propertyID: propertyID),
           let observation = observations.first(where: { $0.id == flaggedID }) {
            return Self.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            )
        }
        return ""
    }

    private func showArmedReferenceImage(isCaptured: Bool) {
        guard let localID = armedReferenceImageLocalIdentifier(isCaptured: isCaptured) else { return }
        armedReferenceViewerState = ArmedReferenceViewerState(
            title: isCaptured ? "Captured Image" : "Reference Image",
            detailId: armedReferenceDetailLabel(),
            localIdentifier: localID
        )
    }

    @discardableResult
    private func showIssueImagePreview(_ observation: Observation, isCaptured: Bool) -> Bool {
        let localID: String? = {
            if isCaptured {
                return capturedImageLocalIdentifierForCurrentSession(observation)
            }
            let sorted = observation.shots.sorted { $0.capturedAt < $1.capturedAt }
            return sorted.first?.imageLocalIdentifier
        }()
        let trimmed = (localID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        armedReferenceViewerState = ArmedReferenceViewerState(
            title: isCaptured ? "Captured Image" : "Reference Image",
            detailId: Self.conciseContextLabel(
                building: observation.building,
                elevation: observation.targetElevation,
                detailType: observation.detailType
            ),
            localIdentifier: trimmed
        )
        return true
    }

    private func performArmedReferenceRetake() {
        if let guidedID = armedGuidedShotID,
           let guided = guidedShots.first(where: { $0.id == guidedID }) {
            armGuidedRetake(guided)
            return
        }
        // Flagged captures are already armed for replacement; no extra mode switch needed.
    }

    private func topLeftPreviewPlaceholders() -> some View {
        VStack(spacing: 2) {
            activeIssuesFlagButton()

            guidedCompassButton {
                fireQuickButtonHaptic()
                refreshGuidedShots()
                showGuidedChecklist = true
            }
        }
    }

    private func activeIssuesFlagButton() -> some View {
        let hitArea: CGFloat = 44
        let symbolSize: CGFloat = 22
        let count = carryoverIssueBadgeCount
        let hasIssues = count > 0

        return Button(action: {
            fireQuickButtonHaptic()
            refreshActiveIssues()
            if !activeObservations.isEmpty {
                showActiveIssuesSheet = true
            } else {
                showNoFlaggedIssuesToast = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    showNoFlaggedIssuesToast = false
                }
            }
        }) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "flag.fill")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundColor(hasIssues ? .red : .white)
                    .rotationEffect(bottomGlyphRotationAngle)

                if hasIssues {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: hitArea, height: hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitArea, height: hitArea)
    }

    private func placeholderQuickButton(
        systemName: String,
        action: @escaping () -> Void
    ) -> some View {
        let hitArea: CGFloat = 44
        let symbolSize: CGFloat = 22
        return Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .rotationEffect(bottomGlyphRotationAngle)
            .frame(width: hitArea, height: hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitArea, height: hitArea)
    }

    private func guidedCompassButton(action: @escaping () -> Void) -> some View {
        let hitArea: CGFloat = 44
        let symbolSize: CGFloat = 22
        let compassColor: Color = shouldShowGuidedCompassBadge ? .blue : .white

        return Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "safari")
                    .font(.system(size: symbolSize, weight: .medium))
                    .foregroundStyle(compassColor)

                if shouldShowGuidedCompassBadge {
                    Text("\(guidedRemainingForCompass)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: 6, y: -6)
                }
            }
            .rotationEffect(bottomGlyphRotationAngle)
            .frame(width: hitArea, height: hitArea)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: hitArea, height: hitArea)
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

            // Keep native look with a blue active segment.
            control.selectedSegmentTintColor = UIColor.systemBlue

            let normalAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white.withAlphaComponent(0.92),
                .font: UIFont.systemFont(ofSize: 19, weight: .medium)
            ]

            let selectedAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: UIColor.white,
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
                        .foregroundColor(selected ? .white : Color.white.opacity(0.92))
                        .rotationEffect(bottomGlyphRotationAngle)
                        .frame(width: itemW, height: itemW)
                        .background(
                            Group {
                                if selected {
                                    // Active zoom uses blue fill with white text.
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
        let noteAtCapture = detailNote.trimmingCharacters(in: .whitespacesAndNewlines)
        camera.capturePhoto { data in
            guard let data else { return }
            
            reportLibrary.savePhotoDataToAlbum(data: data, location: locationManager.lastLocation) { success, photoRef in
                DispatchQueue.main.async {
                    if success {
                        let captureShotID = armedGuidedRetakeShotID ?? UUID()
                        let shot = Shot(
                            id: captureShotID,
                            capturedAt: Date(),
                            imageLocalIdentifier: photoRef,
                            note: noteAtCapture.isEmpty ? nil : noteAtCapture
                        )
                        let referenceImagePath = writeGuidedReferenceImage(data: data, guidedShotID: captureShotID)
                        let didApplyGuidedShot = applyArmedGuidedShotIfNeeded(with: shot, referenceImagePath: referenceImagePath)
                        let didApplyIssueUpdate = applyArmedIssueCaptureIfNeeded(with: shot)
                        let didQueueResolution = queueResolutionCaptureIfNeeded(with: shot, data: data)
                        if !didApplyGuidedShot && !didApplyIssueUpdate && !didQueueResolution {
                            if noteAtCapture.isEmpty {
                                createGuidedAngleFromCaptureIfNeeded(with: shot, referenceImagePath: referenceImagePath)
                            } else {
                                createObservationFromCapturedDetailNote(noteAtCapture, shot: shot)
                            }
                        }
                        refreshSessionActionsSummaryIfVisible()
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

    private func createObservationFromCapturedDetailNote(_ noteText: String, shot: Shot) {
        guard !noteText.isEmpty else { return }
        guard let propertyID = appState.selectedPropertyID else { return }

        let observation = Observation(
            propertyID: propertyID,
            sessionID: appState.currentSession?.id,
            statement: noteText,
            status: .active,
            linkedShotID: shot.id,
            building: selectedBuilding,
            targetElevation: elevation,
            detailType: currentDetailType,
            note: noteText,
            shots: [shot]
        )

        do {
            _ = try localStore.createObservation(observation)
            refreshActiveIssues()
            detailNote = ""
            isArmedIssueDetailNoteReadOnly = false
            if camera.manualHDEnabled {
                camera.manualHDEnabled = false
            }
        } catch {
            // Keep capture UX resilient if local observation persistence fails.
        }
    }

    private func refreshGuidedShots() {
        guard let propertyID = appState.selectedPropertyID else {
            guidedShots = []
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            showGuidedAlignmentOverlay = false
            showArmedReferenceMenu = false
            return
        }

        do {
            guidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)

            if let armedID = armedGuidedShotID, guidedShots.contains(where: { $0.id == armedID }) == false {
                armedGuidedShotID = nil
                armedGuidedRetakeShotID = nil
                showArmedReferenceMenu = false
            }
        } catch {
            guidedShots = []
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            showGuidedAlignmentOverlay = false
            showArmedReferenceMenu = false
        }
    }

    private func armGuidedShot(_ guidedShot: GuidedShot) {
        guard !isShotCapturedInCurrentSession(guidedShot.shot) else { return }
        resetSelectionForSwitch()
        if let building = guidedShot.building, !building.isEmpty {
            selectedBuilding = buildingCode(from: building)
        }
        if let targetElevation = guidedShot.targetElevation, !targetElevation.isEmpty {
            elevation = targetElevation
        } else if let inferredElevation = inferElevation(from: guidedShot.title) {
            elevation = inferredElevation
        }
        let detail = guidedShot.detailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty {
            detailTypesModel.setSelected(detail, for: locationMode)
        }
        loadGuidedReferenceThumbnail(referencePath: guidedShot.referenceImagePath, localIdentifier: guidedShot.referenceImageLocalIdentifier)
        showGuidedAlignmentOverlay = false
        armedGuidedRetakeShotID = nil
        armedGuidedShotID = guidedShot.id
        showGuidedChecklist = false
    }

    private func armGuidedRetake(_ guidedShot: GuidedShot) {
        guard isShotCapturedInCurrentSession(guidedShot.shot), let existingShot = guidedShot.shot else { return }
        resetSelectionForSwitch()
        if let building = guidedShot.building, !building.isEmpty {
            selectedBuilding = buildingCode(from: building)
        }
        if let targetElevation = guidedShot.targetElevation, !targetElevation.isEmpty {
            elevation = targetElevation
        } else if let inferredElevation = inferElevation(from: guidedShot.title) {
            elevation = inferredElevation
        }
        let detail = guidedShot.detailType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !detail.isEmpty {
            detailTypesModel.setSelected(detail, for: locationMode)
        }
        loadGuidedReferenceThumbnail(referencePath: guidedShot.referenceImagePath, localIdentifier: guidedShot.referenceImageLocalIdentifier)
        showGuidedAlignmentOverlay = false
        armedGuidedRetakeShotID = existingShot.id
        armedGuidedShotID = guidedShot.id
        showGuidedChecklist = false
    }

    private func markGuidedShotSkipped(_ guidedShot: GuidedShot, reason: SkipReason, otherNote: String?) {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard !isShotCapturedInCurrentSession(guidedShot.shot) else { return }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == guidedShot.id }) else { return }

            allGuidedShots[idx].skipReason = reason
            allGuidedShots[idx].skipReasonNote = reason == .other ? otherNote?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            allGuidedShots[idx].skipSessionID = appState.currentSession?.id
            allGuidedShots[idx].isCompleted = false
            allGuidedShots[idx].shot = nil

            try localStore.saveGuidedShots(allGuidedShots, propertyID: propertyID)
            guidedShots = allGuidedShots
            refreshSessionActionsSummaryIfVisible()

            if armedGuidedShotID == guidedShot.id {
                armedGuidedShotID = nil
                armedGuidedRetakeShotID = nil
                guidedReferenceAssetLocalID = nil
                guidedReferenceThumbnail = nil
                showGuidedAlignmentOverlay = false
            }
        } catch {
            print("Failed to mark guided shot skipped: \(error)")
        }
    }

    private func undoGuidedShotSkip(_ guidedShot: GuidedShot) {
        guard let propertyID = appState.selectedPropertyID else { return }
        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == guidedShot.id }) else { return }
            allGuidedShots[idx].skipReason = nil
            allGuidedShots[idx].skipReasonNote = nil
            allGuidedShots[idx].skipSessionID = nil
            try localStore.saveGuidedShots(allGuidedShots, propertyID: propertyID)
            guidedShots = allGuidedShots
            refreshSessionActionsSummaryIfVisible()
        } catch {
            print("Failed to undo guided skip: \(error)")
        }
    }

    private func applyArmedGuidedShotIfNeeded(with shot: Shot, referenceImagePath: String?) -> Bool {
        guard let armedID = armedGuidedShotID else { return false }
        guard let propertyID = appState.selectedPropertyID else {
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            return false
        }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            guard let idx = allGuidedShots.firstIndex(where: { $0.id == armedID }) else {
                armedGuidedShotID = nil
                armedGuidedRetakeShotID = nil
                return false
            }

            let isRetake = armedGuidedRetakeShotID != nil
            if isRetake {
                guard allGuidedShots[idx].shot?.id == armedGuidedRetakeShotID else {
                    armedGuidedShotID = nil
                    armedGuidedRetakeShotID = nil
                    return false
                }
            } else if isShotCapturedInCurrentSession(allGuidedShots[idx].shot) {
                armedGuidedShotID = nil
                armedGuidedRetakeShotID = nil
                return false
            }

            allGuidedShots[idx].shot = shot
            allGuidedShots[idx].isCompleted = true
            allGuidedShots[idx].skipReason = nil
            allGuidedShots[idx].skipReasonNote = nil
            allGuidedShots[idx].skipSessionID = nil
            if allGuidedShots[idx].angleIndex == nil || allGuidedShots[idx].angleIndex == 0 {
                let inferredAngle = max(1, allGuidedShots.filter {
                    normalizeGuidedPart($0.building) == normalizeGuidedPart(allGuidedShots[idx].building) &&
                    normalizeGuidedPart($0.targetElevation) == normalizeGuidedPart(allGuidedShots[idx].targetElevation) &&
                    normalizeGuidedPart($0.detailType) == normalizeGuidedPart(allGuidedShots[idx].detailType)
                }.count)
                allGuidedShots[idx].angleIndex = inferredAngle
            }
            try localStore.saveGuidedShots(allGuidedShots, propertyID: propertyID)
            guidedShots = allGuidedShots
            refreshSessionActionsSummaryIfVisible()

            if isRetake {
                refreshLinkedIssuePhotos(for: shot, propertyID: propertyID)
            }

            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            showGuidedAlignmentOverlay = false
            return true
        } catch {
            armedGuidedShotID = nil
            armedGuidedRetakeShotID = nil
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            showGuidedAlignmentOverlay = false
            return false
        }
    }

    private func createGuidedAngleFromCaptureIfNeeded(with shot: Shot, referenceImagePath: String?) {
        guard let propertyID = appState.selectedPropertyID else { return }

        let building = selectedBuilding.trimmingCharacters(in: .whitespacesAndNewlines)
        let elevationValue = elevation.trimmingCharacters(in: .whitespacesAndNewlines)
        let detailTypeValue = currentDetailType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !building.isEmpty, !elevationValue.isEmpty, !detailTypeValue.isEmpty else { return }

        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)

            let matching = allGuidedShots.filter {
                normalizeGuidedPart($0.building) == normalizeGuidedPart(building) &&
                normalizeGuidedPart($0.targetElevation) == normalizeGuidedPart(elevationValue) &&
                normalizeGuidedPart($0.detailType) == normalizeGuidedPart(detailTypeValue)
            }

            let nextAngle = (matching.map { max(1, $0.angleIndex ?? 1) }.max() ?? 0) + 1
            let contextTitle = guidedContextLabel(building: building, elevation: elevationValue, detailType: detailTypeValue)

            let guided = GuidedShot(
                title: contextTitle,
                building: building,
                targetElevation: elevationValue,
                detailType: detailTypeValue,
                angleIndex: nextAngle,
                referenceImageLocalIdentifier: nil,
                referenceImagePath: nil,
                shot: shot,
                isCompleted: true
            )
            allGuidedShots.append(guided)
            try localStore.saveGuidedShots(allGuidedShots, propertyID: propertyID)
            guidedShots = allGuidedShots
        } catch {
            // Keep capture resilient if guided persistence fails.
        }
    }

    private func guidedContextLabel(building: String, elevation: String, detailType: String) -> String {
        Self.conciseContextLabel(
            building: building,
            elevation: elevation,
            detailType: detailType
        )
    }

    private func normalizeGuidedPart(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private func writeGuidedReferenceImage(data: Data, guidedShotID: UUID) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        guard let jpeg = image.jpegData(compressionQuality: 0.60) else { return nil }

        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let base = appSupport.appendingPathComponent("ScoutCapture", isDirectory: true)
        let referencesDir = base.appendingPathComponent("guided-references", isDirectory: true)
        let fileURL = referencesDir.appendingPathComponent("\(guidedShotID.uuidString).jpg")

        do {
            if !fileManager.fileExists(atPath: referencesDir.path) {
                try fileManager.createDirectory(at: referencesDir, withIntermediateDirectories: true)
            }
            try jpeg.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }

    private func refreshLinkedIssuePhotos(for shot: Shot, propertyID: UUID) {
        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            var didUpdate = false
            for existing in observations {
                let hasLinkedShot = existing.linkedShotID == shot.id
                let hasShotInHistory = existing.shots.contains(where: { $0.id == shot.id })
                guard hasLinkedShot || hasShotInHistory else { continue }

                var updated = existing
                var replaced = false
                for index in updated.shots.indices {
                    if updated.shots[index].id == shot.id {
                        updated.shots[index] = shot
                        replaced = true
                    }
                }
                if hasLinkedShot && !replaced {
                    updated.shots.append(shot)
                }

                _ = try localStore.updateObservation(updated)
                didUpdate = true
            }
            if didUpdate {
                refreshActiveIssues()
            }
        } catch {
            // Keep retake workflow resilient if issue-photo sync fails.
        }
    }

    private func inferElevation(from title: String) -> String? {
        let lower = title.lowercased()
        if lower.contains(" n ") || lower.hasSuffix(" n") || lower.hasPrefix("n ") { return "North" }
        if lower.contains(" s ") || lower.hasSuffix(" s") || lower.hasPrefix("s ") { return "South" }
        if lower.contains(" e ") || lower.hasSuffix(" e") || lower.hasPrefix("e ") { return "East" }
        if lower.contains(" w ") || lower.hasSuffix(" w") || lower.hasPrefix("w ") { return "West" }
        if lower.contains("front") { return "North" }
        if lower.contains("rear") || lower.contains("back") { return "South" }
        if lower.contains("left") { return "West" }
        if lower.contains("right") { return "East" }
        return nil
    }

    private func loadGuidedReferenceThumbnail(referencePath: String?, localIdentifier: String?) {
        let path = referencePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty, let image = UIImage(contentsOfFile: path) {
            guidedReferenceAssetLocalID = path
            guidedReferenceThumbnail = image
            return
        }

        let id = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            guidedReferenceAssetLocalID = nil
            guidedReferenceThumbnail = nil
            return
        }
        guidedReferenceAssetLocalID = id
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
        guard let asset = fetch.firstObject else {
            guidedReferenceThumbnail = nil
            return
        }
        let px = max(180, 88 * UIScreen.currentScale * 2.0)
        imageCache.requestThumbnail(for: asset, pixelSize: px) { image in
            DispatchQueue.main.async {
                guard guidedReferenceAssetLocalID == id else { return }
                guidedReferenceThumbnail = image
            }
        }
    }
    
    private func ensureCameraSessionPrecondition() {
        guard hasValidCurrentSession else {
            guard !didTriggerExitToHubForMissingSession else { return }
            didTriggerExitToHubForMissingSession = true
            DispatchQueue.main.async {
                onExitToHub?()
            }
            return
        }
        didTriggerExitToHubForMissingSession = false
    }

    private func presentSessionActionsSheet() {
        guard let propertyID = appState.selectedPropertyID else { return }
        let observations = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
        let guided = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []

        let flaggedRemaining = carryoverFlaggedRemainingCount(observations: observations)
        let guidedRemaining = guided.filter { !isGuidedShotHandledInCurrentSession($0) }.count
        let hasBaseline = appState.propertyHasBaseline(propertyID)
        let currentSessionCaptureCount = currentSessionPhotoCount(propertyID: propertyID)

        sessionActionsSummary = SessionActionsSummary(
            guidedRemainingCount: guidedRemaining,
            flaggedRemainingCount: flaggedRemaining,
            hasBaseline: hasBaseline,
            currentSessionCaptureCount: currentSessionCaptureCount
        )
        showSessionActionsSheet = true
    }

    private func carryoverFlaggedRemainingCount(observations: [Observation]) -> Int {
        guard let session = appState.currentSession else { return 0 }
        let sessionID = session.id
        return observations.filter { observation in
            observation.status == .active &&
            observation.createdAt < session.startedAt &&
            observation.updatedInSessionID != sessionID
        }.count
    }

    private func currentSessionPhotoCount(propertyID: UUID) -> Int {
        let observations = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
        let guided = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []

        var shotIDs = Set<UUID>()
        for shot in observations.flatMap(\.shots) where isShotCapturedInCurrentSession(shot) {
            shotIDs.insert(shot.id)
        }
        for shot in guided.compactMap(\.shot) where isShotCapturedInCurrentSession(shot) {
            shotIDs.insert(shot.id)
        }
        return shotIDs.count
    }

    private func isGuidedShotSkippedInCurrentSession(_ guidedShot: GuidedShot) -> Bool {
        guard let sessionID = appState.currentSession?.id else { return false }
        return guidedShot.skipReason != nil && guidedShot.skipSessionID == sessionID
    }

    private func isGuidedShotHandledInCurrentSession(_ guidedShot: GuidedShot) -> Bool {
        isShotCapturedInCurrentSession(guidedShot.shot) || isGuidedShotSkippedInCurrentSession(guidedShot)
    }

    private func capturedImageLocalIdentifierForCurrentSession(_ observation: Observation) -> String? {
        guard let currentSessionID = appState.currentSession?.id else { return nil }
        let hasCurrentSessionCapture = observation.updatedInSessionID == currentSessionID || observation.resolvedInSessionID == currentSessionID
        guard hasCurrentSessionCapture else { return nil }
        guard let linkedID = observation.linkedShotID else { return nil }
        let localID = observation.shots.first(where: { $0.id == linkedID })?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return localID.isEmpty ? nil : localID
    }

    private func refreshSessionActionsSummaryIfVisible() {
        guard showSessionActionsSheet else { return }
        presentSessionActionsSheet()
    }

    private func isShotCapturedInCurrentSession(_ shot: Shot?) -> Bool {
        guard let shot else { return false }
        guard let session = appState.currentSession else { return false }
        if shot.capturedAt < session.startedAt {
            return false
        }
        if let endedAt = session.endedAt, shot.capturedAt > endedAt {
            return false
        }
        return true
    }

    private func startExportNowFlow() {
        guard !isPreparingSessionExport else { return }
        if let summary = sessionActionsSummary, !summary.isExportEnabled {
            return
        }
        showSessionExportErrorPopup = false
        sessionExportErrorMessage = nil
        isPreparingSessionExport = true
        sessionExportChecklist = ExportChecklistState()
        prepareSessionExportReferences()
        appState.completeCurrentSession(markExported: false)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try buildSessionExportArchive(progress: { step in
                    DispatchQueue.main.async {
                        switch step {
                        case .originals:
                            sessionExportChecklist.originalsComplete = true
                        case .sessionData:
                            sessionExportChecklist.sessionDataComplete = true
                        case .stamped:
                            sessionExportChecklist.stampedComplete = true
                        case .zipReady:
                            sessionExportChecklist.zipReady = true
                        }
                    }
                })
                DispatchQueue.main.async {
                    isPreparingSessionExport = false
                    showSessionActionsSheet = false
                    sessionExportFile = SessionExportFile(url: url)
                }
            } catch {
                DispatchQueue.main.async {
                    isPreparingSessionExport = false
                    showSessionActionsSheet = false
                    sessionExportErrorMessage = error.localizedDescription
                    showSessionExportErrorPopup = true
                }
            }
        }
    }

    private func handleSaveDraftAndExit(summary: SessionActionsSummary) {
        _ = summary
        resetSelectionForSwitch()
        camera.updateDetailNoteActive(false)
        appState.saveDraftCurrentSession()
        appState.refreshProperties()
        showSessionActionsSheet = false
        onExitToHub?()
    }

    private func handleExportLaterAndExit(summary: SessionActionsSummary) {
        guard summary.isExportLaterEnabled else { return }
        appState.completeCurrentSession(markExported: false)
        appState.refreshProperties()
        showSessionActionsSheet = false
        onExitToHub?()
    }

    private func finalizeBaselineIfNeededAfterSuccessfulExport() {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard let sessionID = appState.currentSession?.id else { return }
        guard !appState.propertyHasBaseline(propertyID) else { return }

        ensureGuidedReferencePaths(propertyID: propertyID)
        _ = appState.setPropertyBaselineSession(propertyID: propertyID, sessionID: sessionID)
    }

    private func ensureGuidedReferencePaths(propertyID: UUID) {
        do {
            var allGuidedShots = try localStore.fetchGuidedShots(propertyID: propertyID)
            var didChange = false

            for index in allGuidedShots.indices {
                let existingPath = allGuidedShots[index].referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !existingPath.isEmpty { continue }

                let localID = (allGuidedShots[index].referenceImageLocalIdentifier ??
                               allGuidedShots[index].shot?.imageLocalIdentifier)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !localID.isEmpty else { continue }
                guard let imageData = originalImageData(for: localID) else { continue }
                guard let path = writeGuidedReferenceImage(data: imageData, guidedShotID: allGuidedShots[index].id) else { continue }

                allGuidedShots[index].referenceImagePath = path
                if allGuidedShots[index].referenceImageLocalIdentifier == nil {
                    allGuidedShots[index].referenceImageLocalIdentifier = localID
                }
                didChange = true
            }

            if didChange {
                try localStore.saveGuidedShots(allGuidedShots, propertyID: propertyID)
                if appState.selectedPropertyID == propertyID {
                    guidedShots = allGuidedShots
                }
            }
        } catch {
            // Keep export flow resilient if reference backfill fails.
        }
    }

    private func originalImageData(for localIdentifier: String) -> Data? {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = fetch.firstObject else { return nil }

        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        var outData: Data? = nil
        PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            outData = data
        }
        return outData
    }

    private func prepareSessionExportReferences() {
        _ = reportLibrary.assets.count
        guard let propertyID = appState.selectedPropertyID else { return }
        _ = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
        _ = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
    }

    private enum ExportChecklistStep {
        case originals
        case sessionData
        case stamped
        case zipReady
    }

    private func buildSessionExportArchive(progress: ((ExportChecklistStep) -> Void)? = nil) throws -> URL {
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

        let fileManager = FileManager.default
        let assets = reportLibrary.assets
        let property = appState.selectedProperty
        let propertyID = property?.id
        let observations = propertyID.flatMap { try? localStore.fetchObservations(propertyID: $0) } ?? []
        let guided = propertyID.flatMap { try? localStore.fetchGuidedShots(propertyID: $0) } ?? []

        let entries = assets.enumerated().map { index, asset in
            SessionExportAssetEntry(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                originalFilename: sessionExportFilename(for: asset, index: index + 1)
            )
        }

        let payload = SessionExportPayload(
            exportedAt: Date(),
            albumTitle: reportLibrary.albumTitle,
            albumLocalId: reportLibrary.albumLocalId,
            property: property,
            session: appState.currentSession,
            activeIssueCount: reportLibrary.activeIssueCount,
            assets: entries,
            observations: observations,
            guidedShots: guided
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sessionData = try encoder.encode(payload)

        var zipEntries: [(path: String, data: Data)] = []
        zipEntries.append(("Originals/", Data()))
        zipEntries.append(("Stamped/", Data()))

        var originalEntries: [(String, Data)] = []
        var stampedEntries: [(String, Data)] = []
        for (index, asset) in assets.enumerated() {
            guard let data = requestSessionExportImageData(for: asset) else { continue }
            let filename = sessionExportFilename(for: asset, index: index + 1)
            originalEntries.append(("Originals/\(filename)", data))
            stampedEntries.append(("Stamped/\(filename)", data))
        }
        zipEntries.append(contentsOf: originalEntries)
        progress?(.originals)

        zipEntries.append(("session.json", sessionData))
        progress?(.sessionData)

        zipEntries.append(contentsOf: stampedEntries)
        progress?(.stamped)

        let zipData = buildSessionExportZipData(entries: zipEntries)
        let url = fileManager.temporaryDirectory.appendingPathComponent(sessionExportZipFilename())
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try zipData.write(to: url, options: .atomic)
        progress?(.zipReady)
        return url
    }

    private func requestSessionExportImageData(for asset: PHAsset) -> Data? {
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .none
        options.isNetworkAccessAllowed = true

        var output: Data? = nil
        manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
            output = data
        }
        return output
    }

    private func sessionExportFilename(for asset: PHAsset, index: Int) -> String {
        let fallback = "photo-\(index).jpg"
        guard let resource = PHAssetResource.assetResources(for: asset).first else {
            return fallback
        }
        let original = resource.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = original.isEmpty ? fallback : Self.normalizedContextFilename(original)
        let sanitized = base.replacingOccurrences(of: "/", with: "-")
        return String(format: "%04d-%@", index, sanitized)
    }

    private func sessionExportZipFilename() -> String {
        let trimmedAlbum = reportLibrary.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeAlbum = trimmedAlbum.isEmpty
            ? "ScoutCapture-Export"
            : trimmedAlbum.replacingOccurrences(of: "/", with: "-")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        return "\(safeAlbum)-\(timestamp).zip"
    }

    private func buildSessionExportZipData(entries: [(path: String, data: Data)]) -> Data {
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
            let crc = sessionExportCRC32(entry.data)
            let size = UInt32(entry.data.count)
            let localHeaderOffset = UInt32(zip.count)

            appendUInt32LEForSessionExport(0x04034B50, to: &zip)
            appendUInt16LEForSessionExport(20, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt32LEForSessionExport(crc, to: &zip)
            appendUInt32LEForSessionExport(size, to: &zip)
            appendUInt32LEForSessionExport(size, to: &zip)
            appendUInt16LEForSessionExport(UInt16(pathData.count), to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
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
            appendUInt32LEForSessionExport(0x02014B50, to: &zip)
            appendUInt16LEForSessionExport(20, to: &zip)
            appendUInt16LEForSessionExport(20, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt32LEForSessionExport(record.crc32, to: &zip)
            appendUInt32LEForSessionExport(record.size, to: &zip)
            appendUInt32LEForSessionExport(record.size, to: &zip)
            appendUInt16LEForSessionExport(UInt16(record.pathData.count), to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt16LEForSessionExport(0, to: &zip)
            appendUInt32LEForSessionExport(0, to: &zip)
            appendUInt32LEForSessionExport(record.localHeaderOffset, to: &zip)
            zip.append(record.pathData)
        }

        let centralDirectorySize = UInt32(zip.count) - centralDirectoryOffset
        let count = UInt16(centralRecords.count)

        appendUInt32LEForSessionExport(0x06054B50, to: &zip)
        appendUInt16LEForSessionExport(0, to: &zip)
        appendUInt16LEForSessionExport(0, to: &zip)
        appendUInt16LEForSessionExport(count, to: &zip)
        appendUInt16LEForSessionExport(count, to: &zip)
        appendUInt32LEForSessionExport(centralDirectorySize, to: &zip)
        appendUInt32LEForSessionExport(centralDirectoryOffset, to: &zip)
        appendUInt16LEForSessionExport(0, to: &zip)

        return zip
    }

    private func sessionExportCRC32(_ data: Data) -> UInt32 {
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

    private func appendUInt16LEForSessionExport(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func appendUInt32LEForSessionExport(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func applyArmedIssueCaptureIfNeeded(with shot: Shot) -> Bool {
        guard let armedID = armedUpdateObservationID else { return false }
        guard let propertyID = appState.selectedPropertyID else {
            cancelArmedIssueCapture()
            return false
        }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == armedID }) else {
                cancelArmedIssueCapture()
                return false
            }
            flaggedActionTargetObservation = existing
            pendingFlaggedDecisionShot = shot
            pendingFlaggedDecisionPhotoRef = shot.imageLocalIdentifier
            showFlaggedActionPrimaryChoice = true
            showFlaggedUpdateCommentChoice = false
            showFlaggedUpdatedObservationInput = false
            draftUpdatedObservation = ""
            return true
        } catch {
            cancelArmedIssueCapture()
            return false
        }
    }

    private func clearPendingFlaggedDecision() {
        flaggedActionTargetObservation = nil
        pendingFlaggedDecisionShot = nil
        pendingFlaggedDecisionPhotoRef = nil
        showFlaggedActionPrimaryChoice = false
        showFlaggedUpdateCommentChoice = false
        showFlaggedUpdatedObservationInput = false
        draftUpdatedObservation = ""
        showArmedReferenceMenu = false
    }

    private func clearArmedIssueState() {
        armedUpdateObservationID = nil
        armedIssueNoteText = ""
        armedIssueRevisedObservationText = nil
        guidedReferenceAssetLocalID = nil
        guidedReferenceThumbnail = nil
        showGuidedAlignmentOverlay = false
    }

    private func resetSelectionForSwitch() {
        flaggedActionToastToken += 1
        showFlaggedActionToast = false
        showResolutionModeToast = false
        showArmedReferenceMenu = false
        armedReferenceViewerState = nil
        resetResolutionCapturePreview()
        resolutionTargetObservation = nil
        clearPendingFlaggedDecision()
        clearArmedIssueState()
        armedGuidedShotID = nil
        armedGuidedRetakeShotID = nil
        isArmedIssueDetailNoteReadOnly = false
        detailNote = ""
        restoreArmedIssueHDIfNeeded()
    }

    private func restoreArmedIssueHDIfNeeded() {
        guard let previous = armedIssuePreviousManualHD else { return }
        camera.manualHDEnabled = previous
        armedIssuePreviousManualHD = nil
    }

    private func cancelArmedIssueCapture() {
        clearPendingFlaggedDecision()
        clearArmedIssueState()
        isArmedIssueDetailNoteReadOnly = false
        detailNote = ""
        restoreArmedIssueHDIfNeeded()
    }

    private func finalizeArmedIssueCaptureAfterDecision() {
        clearPendingFlaggedDecision()
        clearArmedIssueState()
        isArmedIssueDetailNoteReadOnly = false
        detailNote = ""
        if let previous = armedIssuePreviousManualHD {
            camera.manualHDEnabled = previous
        } else {
            camera.manualHDEnabled = false
        }
        armedIssuePreviousManualHD = nil
    }

    private func beginFlaggedIssueInteraction(_ observation: Observation) {
        resetSelectionForSwitch()
        armIssueUpdate(observation, revisedObservationText: nil)
    }

    private func selectFlaggedPrimaryResolve() {
        applyPendingFlaggedResolve()
    }

    private func selectFlaggedPrimaryUpdate() {
        showFlaggedActionPrimaryChoice = false
        showFlaggedUpdateCommentChoice = true
    }

    private func selectFlaggedUpdateLeaveUnchanged() {
        applyPendingFlaggedUpdate(revisedObservationText: nil)
    }

    private func selectFlaggedUpdateRevise() {
        showFlaggedUpdateCommentChoice = false
        showFlaggedUpdatedObservationInput = true
        draftUpdatedObservation = ""
    }

    private func commitFlaggedUpdatedObservationAndArm() {
        let revised = draftUpdatedObservation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revised.isEmpty else { return }

        if containsMeasurementIndicator(in: revised) {
            showFlaggedActionToastNow("Reminder: SCOUT records visual observations only.")
        }

        applyPendingFlaggedUpdate(revisedObservationText: revised)
    }

    private func applyPendingFlaggedResolve() {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard let targetID = flaggedActionTargetObservation?.id else { return }
        guard let shot = pendingFlaggedDecisionShot else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == targetID }) else {
                finalizeArmedIssueCaptureAfterDecision()
                return
            }

            var updated = existing
            updated.status = .resolved
            updated.linkedShotID = shot.id
            updated.shots.append(shot)
            updated.resolutionPhotoRef = pendingFlaggedDecisionPhotoRef ?? shot.imageLocalIdentifier
            updated.resolutionStatement = "Condition no longer visibly present at time of documentation."
            updated.updatedInSessionID = appState.currentSession?.id
            updated.resolvedInSessionID = appState.currentSession?.id

            _ = try localStore.updateObservation(updated)
            showFlaggedActionToastNow("Issue resolved")
            finalizeArmedIssueCaptureAfterDecision()
            refreshActiveIssues()
        } catch {
            finalizeArmedIssueCaptureAfterDecision()
        }
    }

    private func applyPendingFlaggedUpdate(revisedObservationText: String?) {
        guard let propertyID = appState.selectedPropertyID else { return }
        guard let targetID = flaggedActionTargetObservation?.id else { return }
        guard let shot = pendingFlaggedDecisionShot else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == targetID }) else {
                finalizeArmedIssueCaptureAfterDecision()
                return
            }

            var updated = existing
            updated.linkedShotID = shot.id
            updated.shots.append(shot)
            updated.updatedInSessionID = appState.currentSession?.id
            if updated.building?.isEmpty ?? true {
                updated.building = selectedBuilding
            }
            if updated.targetElevation?.isEmpty ?? true {
                updated.targetElevation = elevation
            }
            if updated.detailType?.isEmpty ?? true {
                updated.detailType = currentDetailType
            }

            let revisedText = revisedObservationText?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let revisedText, !revisedText.isEmpty {
                updated.updateHistory.append(
                    ObservationUpdateEntry(
                        kind: .revisedObservation,
                        text: revisedText,
                        shotID: shot.id
                    )
                )
            } else {
                updated.updateHistory.append(
                    ObservationUpdateEntry(
                        kind: .followUpCapture,
                        text: nil,
                        shotID: shot.id
                    )
                )
            }

            _ = try localStore.updateObservation(updated)
            let note = (updated.note ?? updated.statement).trimmingCharacters(in: .whitespacesAndNewlines)
            if note.isEmpty {
                showFlaggedActionToastNow("Update captured")
            } else {
                let preview = String(note.prefix(36))
                showFlaggedActionToastNow("Update captured: \(preview)")
            }
            finalizeArmedIssueCaptureAfterDecision()
            refreshActiveIssues()
        } catch {
            finalizeArmedIssueCaptureAfterDecision()
        }
    }

    private func containsMeasurementIndicator(in text: String) -> Bool {
        let pattern = #"(?i)\b\d+(?:\.\d+)?\s?(ft|in|mm|cm|m|inch|inches|feet)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func showFlaggedActionToastNow(_ text: String) {
        flaggedActionToastToken += 1
        let token = flaggedActionToastToken
        flaggedActionToastText = text
        showFlaggedActionToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard token == flaggedActionToastToken else { return }
            showFlaggedActionToast = false
        }
    }

    private func queueResolutionCaptureIfNeeded(with shot: Shot, data: Data) -> Bool {
        guard resolutionTargetObservation != nil else { return false }
        resolutionCapturedShot = shot
        resolutionCapturedPhotoRef = shot.imageLocalIdentifier
        resolutionCapturedImage = UIImage(data: data)
        return true
    }

    private func refreshActiveIssues() {
        guard let propertyID = appState.selectedPropertyID else {
            activeObservations = []
            carryoverIssueBadgeCount = 0
            reportLibrary.setActiveIssueCount(0)
            return
        }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            let currentSessionID = appState.currentSession?.id
            let currentSessionStart = appState.currentSession?.startedAt

            let active = observations.filter { $0.status == .active }
            let resolvedThisSession = observations.filter { observation in
                observation.status == .resolved && observation.resolvedInSessionID == currentSessionID
            }

            activeObservations = (active + resolvedThisSession)
                .sorted { $0.updatedAt > $1.updatedAt }

            if let currentSessionID, let currentSessionStart {
                carryoverIssueBadgeCount = observations.filter { observation in
                    observation.status == .active &&
                    observation.createdAt < currentSessionStart &&
                    observation.updatedInSessionID != currentSessionID
                }.count
            } else {
                carryoverIssueBadgeCount = 0
            }

            reportLibrary.setActiveIssueCount(active.count)
        } catch {
            activeObservations = []
            carryoverIssueBadgeCount = 0
            reportLibrary.setActiveIssueCount(0)
        }
    }

    private func armIssueUpdate(_ observation: Observation, revisedObservationText: String?) {
        showActiveIssuesSheet = false
        resolutionTargetObservation = nil
        resetResolutionCapturePreview()
        armedIssueRevisedObservationText = revisedObservationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if armedIssuePreviousManualHD == nil {
            armedIssuePreviousManualHD = camera.manualHDEnabled
        }
        if camera.hdSupported && !camera.manualHDEnabled {
            camera.manualHDEnabled = true
            showHDToast("HD Enabled for Detail Capture")
        }
        let note = observation.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let statement = observation.statement.trimmingCharacters(in: .whitespacesAndNewlines)
        armedIssueNoteText = !note.isEmpty ? note : statement
        detailNote = armedIssueNoteText
        isArmedIssueDetailNoteReadOnly = true
        let sortedShots = observation.shots.sorted { $0.capturedAt < $1.capturedAt }
        let referenceLocalID = sortedShots.first?.imageLocalIdentifier
        loadGuidedReferenceThumbnail(referencePath: nil, localIdentifier: referenceLocalID)
        showGuidedAlignmentOverlay = false
        if let building = observation.building?.trimmingCharacters(in: .whitespacesAndNewlines), !building.isEmpty {
            selectedBuilding = buildingCode(from: building)
        }
        if let targetElevation = observation.targetElevation?.trimmingCharacters(in: .whitespacesAndNewlines), !targetElevation.isEmpty {
            elevation = targetElevation
        }
        if let detail = observation.detailType?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            detailTypesModel.setSelected(detail, for: locationMode)
        }
        armedUpdateObservationID = observation.id
    }

    private func armIssueUpdate(_ observation: Observation) {
        armIssueUpdate(observation, revisedObservationText: nil)
    }

    private func enterResolutionMode(_ observation: Observation) {
        showActiveIssuesSheet = false
        armedUpdateObservationID = nil
        resolutionTargetObservation = observation
        resetResolutionCapturePreview()
        showResolutionModeToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            showResolutionModeToast = false
        }
    }

    private func resetResolutionCapturePreview() {
        resolutionCapturedShot = nil
        resolutionCapturedPhotoRef = nil
        resolutionCapturedImage = nil
    }

    private func confirmResolution() {
        guard let target = resolutionTargetObservation else { return }
        guard let shot = resolutionCapturedShot else { return }
        guard let propertyID = appState.selectedPropertyID else { return }

        do {
            let observations = try localStore.fetchObservations(propertyID: propertyID)
            guard let existing = observations.first(where: { $0.id == target.id }) else { return }

            var updated = existing
            updated.status = .resolved
            updated.linkedShotID = shot.id
            updated.shots.append(shot)
            updated.resolutionPhotoRef = resolutionCapturedPhotoRef
            updated.resolutionStatement = "Condition no longer visibly present at time of documentation."
            updated.updatedInSessionID = appState.currentSession?.id
            updated.resolvedInSessionID = appState.currentSession?.id
            _ = try localStore.updateObservation(updated)

            resolutionTargetObservation = nil
            resetResolutionCapturePreview()
            showFlaggedActionToastNow("Issue resolved")
            refreshActiveIssues()
        } catch {
            // Keep UI responsive if persistence fails.
        }
    }
    
    
    
    
    
    private struct SessionActionsSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        let summary: SessionActionsSummary
        let isPreparingExport: Bool
        let onResume: () -> Void
        let onSaveDraftAndExit: () -> Void
        let onExportNow: () -> Void
        let onExportLater: () -> Void

        private var neutralFill: Color {
            colorScheme == .light ? Color.white.opacity(0.90) : Color.black.opacity(0.65)
        }

        private var neutralStroke: Color {
            colorScheme == .light ? Color.black.opacity(0.14) : Color.white.opacity(0.28)
        }

        private var neutralLabel: Color {
            colorScheme == .light ? Color.black.opacity(0.88) : .white
        }

        var body: some View {
            GeometryReader { geo in
                let constrainedHeight = geo.size.height < 620

                ZStack {
                    Color.black.opacity(0.52)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack {
                        Spacer(minLength: 0)

                        VStack(spacing: 14) {
                            Text("Session Actions")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)

                            VStack(spacing: 8) {
                                summaryRow(title: "Guided Remaining", value: summary.guidedRemainingCount)
                                summaryRow(title: "Flagged Remaining", value: summary.flaggedRemainingCount)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
                            )

                            if constrainedHeight {
                                ScrollView(.vertical, showsIndicators: true) {
                                    actionButtonsStack
                                }
                                .frame(maxHeight: geo.size.height * 0.38)
                            } else {
                                actionButtonsStack
                            }
                        }
                        .padding(18)
                        .frame(width: min(max(310, geo.size.width * 0.84), 470))
                        .background(Color.black.opacity(0.82))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.20), lineWidth: 1)
                        )

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                }
            }
        }

        @ViewBuilder
        private func summaryRow(title: String, value: Int) -> some View {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white.opacity(0.92))
                Spacer(minLength: 0)
                Text("\(value)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
        }

        @ViewBuilder
        private var actionButtonsStack: some View {
            VStack(spacing: 10) {
                actionButton(
                    title: "Resume",
                    role: .primary,
                    isEnabled: !isPreparingExport,
                    action: onResume
                )
                actionButton(
                    title: isPreparingExport ? "Preparing Export..." : "Export",
                    role: .secondary,
                    isEnabled: !isPreparingExport && summary.isExportEnabled,
                    action: onExportNow
                )
                actionButton(
                    title: "Export Later",
                    role: .tertiary,
                    isEnabled: !isPreparingExport && summary.isExportLaterEnabled,
                    action: onExportLater
                )
                actionButton(
                    title: "Save Draft and Exit",
                    role: .secondary,
                    isEnabled: !isPreparingExport,
                    action: onSaveDraftAndExit
                )

                if !summary.isExportEnabled || !summary.isExportLaterEnabled {
                    Text(disabledHintText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                }
            }
        }

        private var disabledHintText: String {
            if !summary.hasBaseline && summary.currentSessionCaptureCount == 0 {
                return "Export is disabled until at least one photo is captured. Export Later remains disabled until baseline exists."
            }
            if !summary.hasBaseline {
                return "Export Later is disabled until baseline exists."
            }
            return "Export and Export Later are disabled until all guided and flagged items are complete."
        }

        private enum ActionRole {
            case primary
            case secondary
            case tertiary
        }

        @ViewBuilder
        private func actionButton(
            title: String,
            role: ActionRole,
            isEnabled: Bool,
            action: @escaping () -> Void
        ) -> some View {
            let fill: Color = {
                switch role {
                case .primary:
                    return .blue
                case .secondary:
                    return neutralFill
                case .tertiary:
                    return Color.white.opacity(0.06)
                }
            }()
            let stroke: Color = {
                switch role {
                case .primary:
                    return .blue.opacity(0.85)
                case .secondary:
                    return neutralStroke
                case .tertiary:
                    return Color.white.opacity(0.20)
                }
            }()
            let label: Color = {
                switch role {
                case .primary:
                    return .white
                case .secondary:
                    return neutralLabel
                case .tertiary:
                    return .white.opacity(0.94)
                }
            }()

            Button(action: action) {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isEnabled ? label : label.opacity(0.45))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(fill)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .stroke(stroke, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
        }
    }

    private struct ExportProgressOverlay: View {
        let title: String

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack(spacing: 14) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)

                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.15)
                    }
                    .padding(20)
                    .frame(width: min(max(290, geo.size.width * 0.80), 430))
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                }
            }
        }
    }

    private struct SessionExportChecklistOverlay: View {
        let checklist: ExportChecklistState

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack(spacing: 14) {
                        Text("Preparing Export")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)

                        VStack(spacing: 10) {
                            checklistRow(title: "Originals", isComplete: checklist.originalsComplete)
                            checklistRow(title: "Session Data", isComplete: checklist.sessionDataComplete)
                            checklistRow(title: "Stamped", isComplete: checklist.stampedComplete)
                            checklistRow(title: "ZIP Ready", isComplete: checklist.zipReady)
                        }
                    }
                    .padding(20)
                    .frame(width: min(max(290, geo.size.width * 0.80), 430))
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                }
            }
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
    }

    private struct ExportErrorOverlay: View {
        let title: String
        let message: String
        let retryTitle: String
        let cancelTitle: String
        let onRetry: () -> Void
        let onCancel: () -> Void

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.55)
                        .ignoresSafeArea()
                        .onTapGesture { }

                    VStack(spacing: 14) {
                        Text(title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)

                        Text(message)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.90))
                            .multilineTextAlignment(.center)

                        HStack(spacing: 10) {
                            Button(action: onRetry) {
                                Text(retryTitle)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.blue.opacity(0.85), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Button(action: onCancel) {
                                Text(cancelTitle)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundColor(.white.opacity(0.95))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.white.opacity(0.08))
                                    .clipShape(Capsule())
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                    .frame(width: min(max(300, geo.size.width * 0.84), 460))
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.20), lineWidth: 1)
                    )
                }
            }
        }
    }

    private struct SessionDocumentExportPicker: UIViewControllerRepresentable {
        let fileURL: URL
        let onComplete: (Bool) -> Void

        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
            picker.delegate = context.coordinator
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

    // MARK: - Report Library Fullscreen (Grid)
    
    private struct ReportLibraryFullscreen: View {
        
        @ObservedObject var reportLibrary: ReportLibraryModel
        @ObservedObject var cache: AssetImageCache
        @EnvironmentObject private var appState: AppState
        private let localStore = LocalStore()
        
        @Environment(\.dismiss) private var dismiss
        @State private var orientationResetToken: Int = 0
        // Physical device orientation (UI is portrait locked, we rotate the content ourselves)
        @State private var lastValidOrientation: UIDeviceOrientation = .portrait
        
        private var isLandscape: Bool {
            lastValidOrientation == .landscapeLeft || lastValidOrientation == .landscapeRight
        }

        private var headerPropertyName: String {
            let trimmed = appState.selectedProperty?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "No Property Selected" : trimmed
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
        
        private struct ExportFile: Identifiable {
            let id = UUID()
            let url: URL
        }
        
        private struct ExportAssetEntry: Codable {
            let localIdentifier: String
            let creationDate: Date?
            let pixelWidth: Int
            let pixelHeight: Int
            let originalFilename: String
        }
        
        private struct ExportSessionPayload: Codable {
            let exportedAt: Date
            let albumTitle: String
            let albumLocalId: String
            let property: Property?
            let session: Session?
            let activeIssueCount: Int
            let assets: [ExportAssetEntry]
            let observations: [Observation]
            let guidedShots: [GuidedShot]
        }

        private enum ExportError: LocalizedError {
            case zipCreationFailed

            var errorDescription: String? {
                switch self {
                case .zipCreationFailed:
                    return "Unable to create export ZIP."
                }
            }
        }

        private enum DeleteScope {
            case albumOnly
            case library
        }

        private enum DragSelectionMode {
            case add
            case remove
        }

        private struct ThumbnailFramePreferenceKey: PreferenceKey {
            static var defaultValue: [String: CGRect] = [:]

            static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
                value.merge(nextValue(), uniquingKeysWith: { _, new in new })
            }
        }
        
        @State private var viewerState: ViewerState? = nil
        @State private var isSelectionMode: Bool = false
        @State private var selectedAssetIds: Set<String> = []
        @State private var isDeletingSelection: Bool = false
        @State private var showDeleteDialog: Bool = false
        @State private var isPreparingShare: Bool = false
        @State private var showShareSheet: Bool = false
        @State private var shareItems: [Any] = []
        @State private var isPreparingExport: Bool = false
        @State private var exportFile: ExportFile? = nil
        @State private var exportErrorMessage: String? = nil
        @State private var showExportError: Bool = false
        @State private var showHeaderOverflowMenu: Bool = false
        @State private var thumbnailFrames: [String: CGRect] = [:]
        @State private var isDragSelecting: Bool = false
        @State private var dragSelectionMode: DragSelectionMode? = nil
        @State private var dragAnchorAssetIndex: Int? = nil
        @State private var dragBaselineSelection: Set<String> = []
        @State private var dragCurrentAssetIndex: Int? = nil
        @State private var dragAutoScrollDirection: Int = 0
        @State private var dragAutoScrollWorkItem: DispatchWorkItem? = nil
        
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
                        ScrollViewReader { scrollProxy in
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
                                            .id(asset.localIdentifier)
                                            .background(
                                                GeometryReader { proxy in
                                                    Color.clear.preference(
                                                        key: ThumbnailFramePreferenceKey.self,
                                                        value: [asset.localIdentifier: proxy.frame(in: .named("libraryGridSelectionSpace"))]
                                                    )
                                                }
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
                            .scrollDisabled(isSelectionMode && isDragSelecting)
                            .coordinateSpace(name: "libraryGridSelectionSpace")
                            .onPreferenceChange(ThumbnailFramePreferenceKey.self) { frames in
                                thumbnailFrames = frames
                            }
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 8, coordinateSpace: .named("libraryGridSelectionSpace"))
                                    .onChanged { value in
                                        handleSelectionDragChanged(
                                            at: value.location,
                                            contentHeight: contentH,
                                            columnsCount: columnsCount,
                                            scrollProxy: scrollProxy
                                        )
                                    }
                                    .onEnded { _ in
                                        handleSelectionDragEnded()
                                    }
                            )
                        }
                        // In landscape, remove safe areas so the grid goes edge to edge.
                        .ignoresSafeArea(isLandscape ? .all : [])
                        
                        // Header overlay (Photos style): stays visible, content can scroll behind it.
                        headerOverlay()
                            .zIndex(50)
                        
                        if showHeaderOverflowMenu {
                            headerOverflowActionOverlay()
                                .zIndex(80)
                        }
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
                    handleSelectionDragEnded()
                    selectedAssetIds.removeAll()
                    isSelectionMode = false
                    showHeaderOverflowMenu = false
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
            .sheet(item: $exportFile) { file in
                DocumentExportPicker(
                    fileURL: file.url,
                    onComplete: { didExport in
                        if didExport {
                            appState.markCurrentSessionExported()
                        }
                    }
                )
            }
            .overlay {
                if isPreparingExport {
                    ExportProgressOverlay(title: "Preparing Export")
                        .zIndex(920)
                }
                if showExportError {
                    ExportErrorOverlay(
                        title: "Export Failed",
                        message: exportErrorMessage ?? "Unable to export report ZIP.",
                        retryTitle: "Retry",
                        cancelTitle: "Cancel",
                        onRetry: {
                            showExportError = false
                            beginExport()
                        },
                        onCancel: {
                            showExportError = false
                        }
                    )
                    .zIndex(930)
                }
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
                    
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Button {
                                dismiss()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.28), lineWidth: 1)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            VStack(alignment: .leading, spacing: 2) {
                            Text(headerPropertyName)
                                .font(.system(size: 38, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.4)
                                .allowsTightening(true)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                        }
                        }
                        
                        Spacer(minLength: 0)

                        Button {
                            withAnimation(.easeOut(duration: 0.18)) {
                                if isSelectionMode {
                                    isSelectionMode = false
                                    selectedAssetIds.removeAll()
                                } else {
                                    isSelectionMode = true
                                }
                            }
                        } label: {
                            Text(isSelectionMode ? "Cancel" : "Select")
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

                        Button {
                            showHeaderOverflowMenu = true
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 42, height: 42)
                                .background(Color.black.opacity(0.55))
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
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
        private func headerOverflowActionOverlay() -> some View {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        showHeaderOverflowMenu = false
                    }

                VStack(spacing: 0) {
                    HStack {
                        Text("Actions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                        Spacer(minLength: 0)
                        Button("Done") {
                            showHeaderOverflowMenu = false
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.20))

                    VStack(spacing: 0) {
                        actionMenuRow(title: "Export") {
                            beginExport()
                            showHeaderOverflowMenu = false
                        }
                        .opacity(isPreparingExport ? 0.45 : 1.0)
                        .allowsHitTesting(!isPreparingExport)
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
                .padding(.horizontal, 20)
                .frame(maxWidth: 360)
            }
            .zIndex(999)
        }

        private func actionMenuRow(title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }

        private func actionMenuDivider() -> some View {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 12)
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

                        Text(selectedAssetIds.isEmpty ? "Select Items" : "\(selectedAssetIds.count) Selected")
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

        private func assetID(at location: CGPoint) -> String? {
            thumbnailFrames.first(where: { $0.value.contains(location) })?.key
        }

        private func handleSelectionDragChanged(
            at location: CGPoint,
            contentHeight: CGFloat,
            columnsCount: Int,
            scrollProxy: ScrollViewProxy
        ) {
            guard isSelectionMode else { return }
            guard let localId = assetID(at: location) else { return }
            guard let index = reportLibrary.assets.firstIndex(where: { $0.localIdentifier == localId }) else { return }

            if !isDragSelecting {
                isDragSelecting = true
                dragSelectionMode = selectedAssetIds.contains(localId) ? .remove : .add
                dragAnchorAssetIndex = index
                dragBaselineSelection = selectedAssetIds
            }

            dragCurrentAssetIndex = index
            applyDragRangeSelection(currentIndex: index)

            let edgeThreshold: CGFloat = 72
            let direction: Int
            if location.y <= edgeThreshold {
                direction = -1
            } else if location.y >= (contentHeight - edgeThreshold) {
                direction = 1
            } else {
                direction = 0
            }

            updateAutoScroll(
                direction: direction,
                columnsCount: columnsCount,
                scrollProxy: scrollProxy
            )
        }

        private func applyDragRangeSelection(currentIndex: Int) {
            guard let anchorIndex = dragAnchorAssetIndex else { return }
            guard let mode = dragSelectionMode else { return }

            let lower = min(anchorIndex, currentIndex)
            let upper = max(anchorIndex, currentIndex)
            let rangedIDs = Set(reportLibrary.assets[lower...upper].map(\.localIdentifier))

            switch mode {
            case .add:
                selectedAssetIds = dragBaselineSelection.union(rangedIDs)
            case .remove:
                selectedAssetIds = dragBaselineSelection.subtracting(rangedIDs)
            }
        }

        private func updateAutoScroll(
            direction: Int,
            columnsCount: Int,
            scrollProxy: ScrollViewProxy
        ) {
            guard direction != dragAutoScrollDirection else { return }
            dragAutoScrollDirection = direction
            dragAutoScrollWorkItem?.cancel()
            dragAutoScrollWorkItem = nil

            guard direction != 0 else { return }
            scheduleAutoScrollTick(columnsCount: columnsCount, scrollProxy: scrollProxy)
        }

        private func scheduleAutoScrollTick(columnsCount: Int, scrollProxy: ScrollViewProxy) {
            let work = DispatchWorkItem {
                guard isDragSelecting else { return }
                guard dragAutoScrollDirection != 0 else { return }
                guard !reportLibrary.assets.isEmpty else { return }

                let step = max(1, columnsCount)
                let currentIndex = dragCurrentAssetIndex ?? 0
                let maxIndex = reportLibrary.assets.count - 1
                let nextIndex = min(
                    max(0, currentIndex + (dragAutoScrollDirection * step)),
                    maxIndex
                )

                guard nextIndex != currentIndex else {
                    scheduleAutoScrollTick(columnsCount: columnsCount, scrollProxy: scrollProxy)
                    return
                }

                let nextId = reportLibrary.assets[nextIndex].localIdentifier
                dragCurrentAssetIndex = nextIndex
                applyDragRangeSelection(currentIndex: nextIndex)

                withAnimation(.linear(duration: 0.12)) {
                    scrollProxy.scrollTo(
                        nextId,
                        anchor: dragAutoScrollDirection > 0 ? .bottom : .top
                    )
                }

                scheduleAutoScrollTick(columnsCount: columnsCount, scrollProxy: scrollProxy)
            }

            dragAutoScrollWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        }

        private func handleSelectionDragEnded() {
            isDragSelecting = false
            dragSelectionMode = nil
            dragAnchorAssetIndex = nil
            dragBaselineSelection.removeAll()
            dragCurrentAssetIndex = nil
            dragAutoScrollDirection = 0
            dragAutoScrollWorkItem?.cancel()
            dragAutoScrollWorkItem = nil
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
        
        private func beginExport() {
            guard !isPreparingExport else { return }
            showExportError = false
            exportErrorMessage = nil
            isPreparingExport = true
            
            let assets = reportLibrary.assets
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let zipURL = try buildExportArchive(for: assets)
                    DispatchQueue.main.async {
                        isPreparingExport = false
                        exportFile = ExportFile(url: zipURL)
                    }
                } catch {
                    DispatchQueue.main.async {
                        isPreparingExport = false
                        exportErrorMessage = error.localizedDescription
                        showExportError = true
                    }
                }
            }
        }
        
        private func buildExportArchive(for assets: [PHAsset]) throws -> URL {
            let fileManager = FileManager.default
            let payload = makeExportSessionPayload(from: assets)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let sessionData = try encoder.encode(payload)
            
            var entries: [(path: String, data: Data)] = []
            entries.append(("Originals/", Data()))
            entries.append(("Stamped/", Data()))
            entries.append(("session.json", sessionData))
            
            for (index, asset) in assets.enumerated() {
                guard let imageData = requestOriginalImageData(for: asset) else { continue }
                let filename = makeArchiveFilename(for: asset, index: index + 1)
                entries.append(("Originals/\(filename)", imageData))
                entries.append(("Stamped/\(filename)", imageData))
            }
            
            let zipData = buildZipData(entries: entries)
            let zipURL = fileManager.temporaryDirectory.appendingPathComponent(exportZipFilename())
            if fileManager.fileExists(atPath: zipURL.path) {
                try fileManager.removeItem(at: zipURL)
            }
            try zipData.write(to: zipURL, options: .atomic)
            
            if !fileManager.fileExists(atPath: zipURL.path) {
                throw ExportError.zipCreationFailed
            }
            return zipURL
        }
        
        private func makeExportSessionPayload(from assets: [PHAsset]) -> ExportSessionPayload {
            let entries = assets.enumerated().map { index, asset in
                ExportAssetEntry(
                    localIdentifier: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight,
                    originalFilename: makeArchiveFilename(for: asset, index: index + 1)
                )
            }
            
            let property = appState.selectedProperty
            let observations: [Observation]
            let guidedShots: [GuidedShot]
            if let propertyID = property?.id {
                observations = (try? localStore.fetchObservations(propertyID: propertyID)) ?? []
                guidedShots = (try? localStore.fetchGuidedShots(propertyID: propertyID)) ?? []
            } else {
                observations = []
                guidedShots = []
            }
            
            return ExportSessionPayload(
                exportedAt: Date(),
                albumTitle: reportLibrary.albumTitle,
                albumLocalId: reportLibrary.albumLocalId,
                property: property,
                session: appState.currentSession,
                activeIssueCount: reportLibrary.activeIssueCount,
                assets: entries,
                observations: observations,
                guidedShots: guidedShots
            )
        }
        
        private func requestOriginalImageData(for asset: PHAsset) -> Data? {
            let manager = PHImageManager.default()
            let options = PHImageRequestOptions()
            options.isSynchronous = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .none
            options.isNetworkAccessAllowed = true
            
            var outData: Data? = nil
            manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                outData = data
            }
            return outData
        }
        
        private func makeArchiveFilename(for asset: PHAsset, index: Int) -> String {
            let fallback = "photo-\(index).jpg"
            guard let resource = PHAssetResource.assetResources(for: asset).first else {
                return fallback
            }
            let original = resource.originalFilename.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = original.isEmpty ? fallback : ContentView.normalizedContextFilename(original)
            let sanitized = base.replacingOccurrences(of: "/", with: "-")
            return String(format: "%04d-%@", index, sanitized)
        }
        
        private func exportZipFilename() -> String {
            let trimmedAlbum = reportLibrary.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let safeAlbum = trimmedAlbum.isEmpty
                ? "ScoutCapture-Export"
                : trimmedAlbum.replacingOccurrences(of: "/", with: "-")
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())
            return "\(safeAlbum)-\(timestamp).zip"
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
                    if (crc & 1) == 1 {
                        crc = (crc >> 1) ^ 0xEDB8_8320
                    } else {
                        crc >>= 1
                    }
                }
            }
            return crc ^ 0xFFFF_FFFF
        }
        
        private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { rawBuffer in
                data.append(contentsOf: rawBuffer)
            }
        }
        
        private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { rawBuffer in
                data.append(contentsOf: rawBuffer)
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
                        if isSelected {
                            Color.black.opacity(0.28)
                                .frame(width: side, height: side)
                        }

                        Circle()
                            .fill(isSelected ? Color.blue : Color.black.opacity(0.30))
                            .frame(width: 22, height: 22)
                            .overlay(
                                Circle()
                                    .stroke(Color.white, lineWidth: 1.6)
                            )
                            .overlay(
                                Image(systemName: isSelected ? "checkmark" : "")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.white)
                            )
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
        
        private struct DocumentExportPicker: UIViewControllerRepresentable {
            let fileURL: URL
            let onComplete: (Bool) -> Void

            func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
                let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
                picker.delegate = context.coordinator
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

    private struct SharedActionMenuItem: Identifiable {
        let id = UUID()
        let title: String
        var isEnabled: Bool = true
        let action: () -> Void
    }

    private struct SharedActionMenuOverlay: View {
        let rotation: Angle
        let items: [SharedActionMenuItem]
        let onDismiss: () -> Void

        var body: some View {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onDismiss()
                    }

                VStack(spacing: 0) {
                    HStack {
                        Text("Actions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                        Spacer(minLength: 0)
                        Button("Done") {
                            onDismiss()
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.20))

                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button(action: item.action) {
                                HStack(spacing: 10) {
                                    Text(item.title)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.white.opacity(0.95))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.78)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .disabled(!item.isEnabled)
                            .opacity(item.isEnabled ? 1.0 : 0.45)

                            if index != items.count - 1 {
                                Rectangle()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(height: 1)
                                    .padding(.horizontal, 12)
                            }
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
                .padding(.horizontal, 20)
                .frame(maxWidth: 360)
                .rotationEffect(rotation)
            }
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

    private struct GuidedChecklistOverlay: View {
        let guidedShots: [GuidedShot]
        let currentSessionID: UUID?
        let currentSessionStartedAt: Date?
        let currentSessionEndedAt: Date?
        @ObservedObject var cache: AssetImageCache
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        let onClose: () -> Void
        let onRefresh: () -> Void
        let onSelectPending: (GuidedShot) -> Void
        let onSkip: (GuidedShot, SkipReason, String?) -> Void
        let onUndoSkip: (GuidedShot) -> Void
        let onRetake: (GuidedShot) -> Void

        @State private var skipTarget: GuidedShot? = nil
        @State private var showSkipReasonDialog: Bool = false
        @State private var showSkipOtherSheet: Bool = false
        @State private var skipOtherText: String = ""
        @State private var retakeTarget: GuidedShot? = nil
        @State private var showRetakeConfirmation: Bool = false
        @State private var guidedViewerState: GuidedViewerState? = nil
        @State private var overflowTargetShot: GuidedShot? = nil
        @State private var overflowTargetStatus: GuidedChecklistRow.RowStatus = .pending
        @State private var inlineToastText: String? = nil
        @State private var inlineToastToken: Int = 0
        @State private var lastValidOrientation: UIDeviceOrientation = .portrait

        private struct GuidedViewerState: Identifiable {
            let id = UUID()
            let title: String
            let detailId: String
            let assets: [PHAsset]
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

                        List(guidedShots) { item in
                            GuidedChecklistRow(
                                guidedShot: item,
                                currentSessionID: currentSessionID,
                                isCapturedInCurrentSession: isCapturedInCurrentSession(item),
                                cache: cache,
                                onTapPending: {
                                    onSelectPending(item)
                                },
                                onTapSkip: {
                                    skipTarget = item
                                    showSkipReasonDialog = true
                                },
                                onTapRetake: {
                                    retakeTarget = item
                                    showRetakeConfirmation = true
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
                                onTapPendingOverflow: {
                                    overflowTargetShot = item
                                    overflowTargetStatus = .pending
                                },
                                onTapCapturedOverflow: {
                                    overflowTargetShot = item
                                    overflowTargetStatus = .captured
                                },
                                onTapSkippedOverflow: {
                                    overflowTargetShot = item
                                    overflowTargetStatus = .skipped
                                }
                            )
                        }
                        .listStyle(.insetGrouped)
                        .scrollIndicators(.hidden)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                    }
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 10) {
                            Button(action: onRefresh) {
                                Image(systemName: "arrow.clockwise")
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

                            Spacer(minLength: 0)

                            Text("Guided Checklist")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(theme.label)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)

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
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    }
                    .confirmationDialog("Skip reason", isPresented: $showSkipReasonDialog, titleVisibility: .visible) {
                        Button("Inaccessible") {
                            submitSkip(.inaccessible)
                        }
                        Button("Obstructed") {
                            submitSkip(.obstructed)
                        }
                        Button("Active construction") {
                            submitSkip(.activeConstruction)
                        }
                        Button("Safety concern") {
                            submitSkip(.safetyConcern)
                        }
                        Button("Other") {
                            showSkipOtherSheet = true
                        }
                        Button("Cancel", role: .cancel) {
                            skipTarget = nil
                        }
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
                    .confirmationDialog("Retake this guided shot?", isPresented: $showRetakeConfirmation, titleVisibility: .visible) {
                        Button("Retake") {
                            guard let item = retakeTarget else { return }
                            onRetake(item)
                            retakeTarget = nil
                        }
                        Button("Cancel", role: .cancel) {
                            retakeTarget = nil
                        }
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
                    .overlay {
                        if let target = overflowTargetShot {
                            guidedOverflowActionOverlay(for: target, status: overflowTargetStatus)
                        }
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
            }
        }

        private func submitSkip(_ reason: SkipReason, otherNote: String? = nil) {
            guard let item = skipTarget else { return }
            onSkip(item, reason, otherNote)
            skipTarget = nil
            skipOtherText = ""
        }

        private func showImagePreview(localIdentifier: String?, title: String, detailId: String) {
            let trimmed = localIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return }

            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [trimmed], options: nil)
            guard let asset = fetch.firstObject else { return }
            guidedViewerState = GuidedViewerState(
                title: title,
                detailId: detailId,
                assets: [asset],
                startIndex: 0,
                viewerToken: trimmed.hashValue
            )
        }

        private func showGuidedReferencePreview(for guidedShot: GuidedShot) {
            let localIdentifier = guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if localIdentifier.isEmpty {
                showInlineToast("No reference available")
                return
            }
            showImagePreview(
                localIdentifier: localIdentifier,
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
            guard let startedAt = currentSessionStartedAt else { return false }
            if shot.capturedAt < startedAt {
                return false
            }
            if let endedAt = currentSessionEndedAt, shot.capturedAt > endedAt {
                return false
            }
            return true
        }

        @ViewBuilder
        private func guidedOverflowActionOverlay(for guidedShot: GuidedShot, status: GuidedChecklistRow.RowStatus) -> some View {
            ZStack {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        overflowTargetShot = nil
                    }

                VStack(spacing: 0) {
                    HStack {
                        Text("Actions")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                        Spacer(minLength: 0)
                        Button("Done") {
                            overflowTargetShot = nil
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.20))

                    VStack(spacing: 0) {
                        if status == .pending {
                            actionMenuRow(title: "Skip") {
                                overflowTargetShot = nil
                                skipTarget = guidedShot
                                showSkipReasonDialog = true
                            }
                        } else if status == .skipped {
                            actionMenuRow(title: "Undo Skip") {
                                overflowTargetShot = nil
                                onUndoSkip(guidedShot)
                            }
                            actionMenuDivider()
                            let hasReference = (guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                            actionMenuRow(title: "View Reference Image") {
                                overflowTargetShot = nil
                                if hasReference {
                                    showGuidedReferencePreview(for: guidedShot)
                                } else {
                                    showInlineToast("No reference available")
                                }
                            }
                            .opacity(hasReference ? 1.0 : 0.45)
                            .allowsHitTesting(hasReference)
                        } else if status == .captured {
                            actionMenuRow(title: "Retake") {
                                overflowTargetShot = nil
                                retakeTarget = guidedShot
                                showRetakeConfirmation = true
                            }
                            actionMenuDivider()

                            let hasReference = (guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                            actionMenuRow(title: "View Reference Image") {
                                overflowTargetShot = nil
                                if hasReference {
                                    showGuidedReferencePreview(for: guidedShot)
                                } else {
                                    showInlineToast("No reference available")
                                }
                            }
                            .opacity(hasReference ? 1.0 : 0.45)
                            .allowsHitTesting(hasReference)

                            actionMenuDivider()

                            let hasCaptured = isCapturedInCurrentSession(guidedShot)
                            actionMenuRow(title: "View Captured Image") {
                                overflowTargetShot = nil
                                if hasCaptured {
                                    showGuidedCapturedPreview(for: guidedShot)
                                } else {
                                    showInlineToast("No captured image yet.")
                                }
                            }
                            .opacity(hasCaptured ? 1.0 : 0.45)
                            .allowsHitTesting(hasCaptured)
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
                .padding(.horizontal, 20)
                .frame(maxWidth: 360)
            }
            .zIndex(999)
        }

        private func actionMenuRow(title: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        }

        private func actionMenuDivider() -> some View {
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
                .padding(.horizontal, 12)
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

    private struct GuidedChecklistRow: View {
        enum RowStatus {
            case pending
            case captured
            case skipped
        }

        let guidedShot: GuidedShot
        let currentSessionID: UUID?
        let isCapturedInCurrentSession: Bool
        @ObservedObject var cache: AssetImageCache
        let onTapPending: () -> Void
        let onTapSkip: () -> Void
        let onTapRetake: () -> Void
        let onTapUndoSkip: () -> Void
        let onTapViewReferenceImage: () -> Void
        let onTapViewCapturedImage: () -> Void
        let onTapPendingOverflow: () -> Void
        let onTapCapturedOverflow: () -> Void
        let onTapSkippedOverflow: () -> Void

        @State private var thumbnail: UIImage? = nil
        @State private var loadedID: String = ""

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

        var body: some View {
            rowContent
            .onTapGesture {
                guard status != .captured else { return }
                onTapPending()
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
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
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
                Button {
                    onTapPendingOverflow()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            case .skipped:
                Button {
                    onTapSkippedOverflow()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            case .captured:
                Button {
                    onTapCapturedOverflow()
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
        }

        private func loadThumbnailIfNeeded() {
            let capturedID = isCapturedInCurrentSession
                ? (guidedShot.shot?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                : ""
            let referencePath = guidedShot.referenceImagePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let referenceID = guidedShot.referenceImageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // Checklist progress thumbnail priority:
            // current-session captured -> reference -> placeholder
            if !capturedID.isEmpty {
                let sourceID = "captured:\(capturedID)"
                guard sourceID != loadedID || thumbnail == nil else { return }
                loadedID = sourceID

                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [capturedID], options: nil)
                guard let asset = fetch.firstObject else {
                    thumbnail = nil
                    return
                }

                let px = max(120, 56 * UIScreen.currentScale * 2.0)
                cache.requestThumbnail(for: asset, pixelSize: px) { image in
                    DispatchQueue.main.async {
                        self.thumbnail = image
                    }
                }
                return
            }

            if !referencePath.isEmpty {
                let sourceID = "referencePath:\(referencePath)"
                guard sourceID != loadedID || thumbnail == nil else { return }
                loadedID = sourceID
                thumbnail = UIImage(contentsOfFile: referencePath)
                if thumbnail != nil { return }
            }

            if !referenceID.isEmpty {
                let sourceID = "referenceID:\(referenceID)"
                guard sourceID != loadedID || thumbnail == nil else { return }
                loadedID = sourceID

                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [referenceID], options: nil)
                guard let asset = fetch.firstObject else {
                    thumbnail = nil
                    return
                }

                let px = max(120, 56 * UIScreen.currentScale * 2.0)
                cache.requestThumbnail(for: asset, pixelSize: px) { image in
                    DispatchQueue.main.async {
                        self.thumbnail = image
                    }
                }
                return
            }

            loadedID = ""
            thumbnail = nil
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
    }

    private struct ActiveIssuesSheet: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        let observations: [Observation]
        let currentSessionID: UUID?
        let cache: AssetImageCache
        let onRefresh: () -> Void
        let onSelectIssue: (Observation) -> Void
        let onRetakeIssue: (Observation) -> Void
        @State private var lastValidOrientation: UIDeviceOrientation = .portrait
        @State private var overflowTargetObservation: Observation? = nil
        @State private var flaggedViewerState: FlaggedViewerState? = nil
        @State private var inlineToastText: String? = nil
        @State private var inlineToastToken: Int = 0

        private var theme: SheetControlTheme { .forScheme(colorScheme) }

        private struct FlaggedViewerState: Identifiable {
            let id = UUID()
            let title: String
            let detailId: String
            let asset: PHAsset
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
                    Group {
                        if observations.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "flag.slash")
                                    .font(.system(size: 28, weight: .medium))
                                    .foregroundColor(.secondary)
                                Text("No active issues")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List(observations) { observation in
                                FlaggedIssueRow(
                                    observation: observation,
                                    currentSessionID: currentSessionID,
                                    cache: cache,
                                    onTapOverflow: {
                                        overflowTargetObservation = observation
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard observation.status == .active else { return }
                                    onSelectIssue(observation)
                                    dismiss()
                                }
                            }
                            .listStyle(.insetGrouped)
                            .scrollIndicators(.hidden)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                        }
                    }
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground)
                            .ignoresSafeArea()
                    )
                    .toolbar(.hidden, for: .navigationBar)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        HStack(spacing: 10) {
                            Button(action: onRefresh) {
                                Image(systemName: "arrow.clockwise")
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

                            Spacer(minLength: 0)

                            Text("Active Issues")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(theme.label)
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Button(action: { dismiss() }) {
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
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    }
                    .overlay {
                        if let target = overflowTargetObservation {
                            let hasReference = referenceImageLocalID(for: target) != nil
                            let hasCaptured = capturedImageLocalID(for: target) != nil
                            let canRetake = target.status == .active
                            SharedActionMenuOverlay(
                                rotation: .degrees(0),
                                items: [
                                    SharedActionMenuItem(
                                        title: "Retake",
                                        isEnabled: canRetake,
                                        action: {
                                            overflowTargetObservation = nil
                                            onRetakeIssue(target)
                                            dismiss()
                                        }
                                    ),
                                    SharedActionMenuItem(
                                        title: "View Reference Image",
                                        isEnabled: hasReference,
                                        action: {
                                            overflowTargetObservation = nil
                                            showIssueImagePreview(target, isCaptured: false)
                                        }
                                    ),
                                    SharedActionMenuItem(
                                        title: "View Captured Image",
                                        isEnabled: hasCaptured,
                                        action: {
                                            overflowTargetObservation = nil
                                            if hasCaptured {
                                                showIssueImagePreview(target, isCaptured: true)
                                            } else {
                                                showInlineToast("No captured image yet.")
                                            }
                                        }
                                    )
                                ],
                                onDismiss: {
                                    overflowTargetObservation = nil
                                }
                            )
                        }
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
            }
            .fullScreenCover(item: $flaggedViewerState) { state in
                ReportPhotoViewer(
                    title: state.title,
                    assets: [state.asset],
                    startIndex: 0,
                    detailIdOverride: state.detailId,
                    cache: cache,
                    viewerToken: state.viewerToken
                )
            }
        }

        private func referenceImageLocalID(for observation: Observation) -> String? {
            let sorted = observation.shots.sorted { $0.capturedAt < $1.capturedAt }
            let id = sorted.first?.imageLocalIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return id.isEmpty ? nil : id
        }

        private func capturedImageLocalID(for observation: Observation) -> String? {
            guard let currentSessionID else { return nil }
            let hasCurrentSessionCapture = observation.updatedInSessionID == currentSessionID || observation.resolvedInSessionID == currentSessionID
            guard hasCurrentSessionCapture else { return nil }
            let id = observation.linkedShotID
                .flatMap { linkedID in
                    observation.shots.first(where: { $0.id == linkedID })?.imageLocalIdentifier
                }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return id.isEmpty ? nil : id
        }

        private func showIssueImagePreview(_ observation: Observation, isCaptured: Bool) {
            let localID = (isCaptured ? capturedImageLocalID(for: observation) : referenceImageLocalID(for: observation)) ?? ""
            let trimmed = localID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                showInlineToast(isCaptured ? "No captured image yet." : "No reference available")
                return
            }

            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [trimmed], options: nil)
            guard let asset = fetch.firstObject else {
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
                viewerToken: trimmed.hashValue
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

        private struct FlaggedIssueRow: View {
            let observation: Observation
            let currentSessionID: UUID?
            let cache: AssetImageCache
            let onTapOverflow: () -> Void

            @State private var thumbnail: UIImage? = nil
            @State private var loadedID: String = ""

            private var contextLabel: String {
                let composed = ContentView.conciseContextLabel(
                    building: observation.building,
                    elevation: observation.targetElevation,
                    detailType: observation.detailType
                )
                return composed.isEmpty ? "Flagged Issue" : composed
            }

            private var noteText: String {
                let note = observation.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !note.isEmpty { return note }
                let statement = observation.statement.trimmingCharacters(in: .whitespacesAndNewlines)
                return statement.isEmpty ? "No note" : statement
            }

            private var chronologicalUpdates: [ObservationUpdateEntry] {
                observation.updateHistory.sorted { $0.createdAt < $1.createdAt }
            }

            private var statusLabel: String {
                if observation.resolvedInSessionID == currentSessionID {
                    return "Resolved"
                }
                if observation.updatedInSessionID == currentSessionID {
                    return "Active · Update Captured"
                }
                return "Active"
            }

            private var statusColor: Color {
                if observation.resolvedInSessionID == currentSessionID {
                    return .green
                }
                if observation.updatedInSessionID == currentSessionID {
                    return .green
                }
                return .orange
            }

            var body: some View {
                HStack(spacing: 12) {
                    thumbnailView

                    VStack(alignment: .leading, spacing: 4) {
                        Text(contextLabel)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(observation.status == .resolved ? .secondary : .primary)
                            .lineLimit(1)

                        Text(noteText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.86))
                            .lineLimit(2)

                        Text(statusLabel)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(statusColor)

                        if !chronologicalUpdates.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(chronologicalUpdates) { entry in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text(historyTimestamp(for: entry.createdAt))
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundColor(.white.opacity(0.60))
                                        Text(historyLabel(for: entry))
                                            .font(.system(size: 11, weight: .regular))
                                            .foregroundColor(.white.opacity(0.84))
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        onTapOverflow()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white.opacity(0.82))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
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
            }

            private func historyTimestamp(for date: Date) -> String {
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d h:mm a"
                return formatter.string(from: date)
            }

            private func historyLabel(for entry: ObservationUpdateEntry) -> String {
                switch entry.kind {
                case .followUpCapture:
                    return "Follow-up captured"
                case .revisedObservation:
                    let text = entry.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return text.isEmpty ? "Observation revised" : text
                }
            }

            private var thumbnailView: some View {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
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
            }

            private func loadThumbnailIfNeeded() {
                let currentCapturedID: String = {
                    guard let currentSessionID else { return "" }
                    let hasCurrentSessionCapture = observation.updatedInSessionID == currentSessionID || observation.resolvedInSessionID == currentSessionID
                    guard hasCurrentSessionCapture else { return "" }
                    return observation.linkedShotID
                        .flatMap { id in
                            observation.shots.first(where: { $0.id == id })?.imageLocalIdentifier
                        }?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }()

                let referenceID = observation.shots
                    .sorted { $0.capturedAt < $1.capturedAt }
                    .first?
                    .imageLocalIdentifier?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                // Active issues tile thumbnail priority:
                // current-session captured -> reference -> placeholder
                let chosenID = !currentCapturedID.isEmpty ? currentCapturedID : referenceID
                guard !chosenID.isEmpty else {
                    thumbnail = nil
                    loadedID = ""
                    return
                }
                guard chosenID != loadedID || thumbnail == nil else { return }
                loadedID = chosenID

                let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [chosenID], options: nil)
                guard let asset = fetch.firstObject else {
                    thumbnail = nil
                    return
                }
                let px = max(120, 56 * UIScreen.currentScale * 2.0)
                cache.requestThumbnail(for: asset, pixelSize: px) { image in
                    DispatchQueue.main.async {
                        self.thumbnail = image
                    }
                }
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
        let selectedBuildingLabel: String
        
        @Binding var isGridOn: Bool
        @Binding var isLevelOn: Bool

        let onBuildingList: () -> Void
        let onInteriorList: () -> Void
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
                let rawTopBtnW = (contentW - (spacing * 2)) / 3.0
                let topBtnW: CGFloat = rawTopBtnW.isFinite ? max(0, rawTopBtnW) : 0
                
                let bottomInset: CGFloat = (btnW / 2.0) + (spacing / 2.0)
                
                NavigationStack {
                    ZStack {
                        Color.clear
                            .ignoresSafeArea()
                        
                        VStack(spacing: 18) {
                            
                            HStack(spacing: spacing) {
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "building.2",
                                    title: "BUILDINGS",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onBuildingList
                                )
                                .frame(width: topBtnW)

                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "list.bullet",
                                    title: "INTERIOR",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onInteriorList
                                )
                                    .frame(width: topBtnW)
                                
                                QuickMenuButton(
                                    glyphRotationAngle: glyphRotationAngle,
                                    icon: "list.bullet",
                                    title: "EXTERIOR",
                                    isSelected: false,
                                    selectedStyle: false,
                                    theme: theme,
                                    action: onExteriorList
                                )
                                .frame(width: topBtnW)
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
                            
                            HStack(spacing: 0) {
                                Spacer(minLength: 0)
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
                                Spacer(minLength: 0)
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

    private struct ManageBuildingsSheet: View {
        @Environment(\.colorScheme) private var colorScheme
        private var theme: SheetControlTheme { .forScheme(colorScheme) }
        @Environment(\.editMode) private var editMode

        @Binding var options: [String]
        @Binding var selectedBuilding: String
        let buildingCodeForOption: (String) -> String
        let buildingFullLabelForOption: (String) -> String
        let onClose: () -> Void
        @State private var editModeState: EditMode = .inactive
        @FocusState private var focusedIndex: Int?

        var body: some View {
            NavigationStack {
                List {
                    ForEach(Array(options.indices), id: \.self) { index in
                        if editModeState == .active {
                            TextField("Building", text: Binding(
                                get: {
                                    guard options.indices.contains(index) else { return "" }
                                    return options[index]
                                },
                                set: { newValue in
                                    guard options.indices.contains(index) else { return }
                                    options[index] = newValue
                                }
                            ))
                            .focused($focusedIndex, equals: index)
                            .submitLabel(.done)
                        } else {
                            let option = options[index]
                            Button {
                                selectedBuilding = buildingCodeForOption(option)
                                onClose()
                            } label: {
                                HStack(spacing: 10) {
                                    Text(buildingFullLabelForOption(option))
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)

                                    Spacer(minLength: 0)

                                    if selectedBuilding == buildingCodeForOption(option) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onDelete { offsets in
                        options.remove(atOffsets: offsets)
                    }
                    .onMove { source, destination in
                        options.move(fromOffsets: source, toOffset: destination)
                    }
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
                                .overlay(
                                    Capsule()
                                        .stroke(theme.stroke, lineWidth: 1)
                                )
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
                        .overlay(
                            Capsule()
                                .stroke(theme.stroke, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                }
                .onDisappear {
                    let cleaned = options
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    options = cleaned.isEmpty ? ["B1", "B2", "B3", "B4", "B5", "Add"] : cleaned
                    let selectedCode = buildingCodeForOption(selectedBuilding)
                    if options.contains(where: { buildingCodeForOption($0) == selectedCode }) == false {
                        selectedBuilding = buildingCodeForOption(options[0])
                    } else {
                        selectedBuilding = selectedCode
                    }
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
                            return .blue
                        }
                        return selectedStyle ? theme.label.opacity(0.92) : theme.label
                    }()
                    
                    let ring: Color = isSelected ? Color.blue.opacity(0.72) : theme.stroke.opacity(0.70)
                    let titleColor: Color = isSelected ? Color.blue.opacity(0.96) : theme.label.opacity(0.88)
                    
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
