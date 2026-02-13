//
//  CameraPreview.swift
//  ScoutCapture
//

import SwiftUI
import AVFoundation
import Combine

// MARK: - Preview View

struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    var onTapDevicePoint: ((CGPoint) -> Void)? = nil
    var onTapNormalizedPoint: ((CGPoint) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspect

        v.onTap = { devicePoint, normalizedPoint in
            onTapDevicePoint?(devicePoint)
            onTapNormalizedPoint?(normalizedPoint)
        }

        return v
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.videoPreviewLayer.session = session
        // Keep preview behavior consistent across updates
        uiView.videoPreviewLayer.videoGravity = .resizeAspect
        uiView.setNeedsLayout()
    }
}

final class PreviewUIView: UIView {

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    var onTap: ((CGPoint, CGPoint) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Ensure the preview layer always matches the view bounds
        videoPreviewLayer.frame = bounds
    }

    @objc private func handleTap(_ gr: UITapGestureRecognizer) {
        let viewPoint = gr.location(in: self)

        let devicePoint = videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: viewPoint)

        let nx = max(0, min(1, viewPoint.x / max(1, bounds.width)))
        let ny = max(0, min(1, viewPoint.y / max(1, bounds.height)))
        let normalized = CGPoint(x: nx, y: ny)

        onTap?(devicePoint, normalized)
    }
}

// MARK: - Zoom Step

struct ZoomStep: Identifiable, Equatable {
    let id: String
    let factor: CGFloat
    let label: String
}

// MARK: - Camera Manager

final class CameraManager: NSObject, ObservableObject {

    let session = AVCaptureSession()

    @Published var isCapturing: Bool = false
    @Published private(set) var zoomSteps: [ZoomStep] = []
    @Published private(set) var selectedZoomId: String = "1"

    // Lens debug label for toast in ContentView
    @Published var lensDebugText: String = ""

    // Fires on every zoom press (after a small delay for accurate labeling)
    @Published var lensDebugPulse: Int = 0

    enum FlashSetting: Int, CaseIterable {
        case off
        case auto
        case on
    }

    @Published var flashSetting: FlashSetting = .off

    private var videoDevice: AVCaptureDevice?
    private let photoOutput = AVCapturePhotoOutput()
    private var inFlightCapture: PhotoCaptureDelegate?

    private var currentPosition: AVCaptureDevice.Position = .back

    // Debug delay work item so we do not mislabel during smooth ramp
    private var debugWorkItem: DispatchWorkItem?

    override init() {
        super.init()
        configureSession()
    }

    // MARK: Flash

    func cycleFlash() {
        let supported = supportedFlashSettings()
        guard !supported.isEmpty else {
            flashSetting = .off
            return
        }

        if let idx = supported.firstIndex(of: flashSetting) {
            flashSetting = supported[(idx + 1) % supported.count]
        } else {
            flashSetting = supported[0]
        }
    }

    // MARK: Camera swap

    func toggleCamera() {
        currentPosition = (currentPosition == .back) ? .front : .back
        reconfigureForCurrentPosition()
    }

    // MARK: Focus

    func focus(atDevicePoint devicePoint: CGPoint) {
        guard let device = videoDevice else { return }

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }

            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: Capture

    func capturePhoto(completion: @escaping (Data?) -> Void) {

        guard !isCapturing else { return }
        guard session.isRunning else { completion(nil); return }

        isCapturing = true

        // Make the captured photo match how the user is physically holding the phone.
        // The UI can be portrait locked, but the photo orientation should follow device orientation.
        if let conn = photoOutput.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = captureVideoOrientation()
        }

        let settings = AVCapturePhotoSettings()

        let supported = photoOutput.supportedFlashModes
        let desired = avFlashMode(for: flashSetting)
        settings.flashMode = supported.contains(desired) ? desired : .off

        if #available(iOS 16.0, *) {
            settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        }

        let delegate = PhotoCaptureDelegate { [weak self] data in
            DispatchQueue.main.async {
                self?.isCapturing = false
                self?.inFlightCapture = nil
                completion(data)
            }
        }

        inFlightCapture = delegate
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    // MARK: Zoom

    func setZoomStep(_ step: ZoomStep) {
        setNativeZoom(uiZoom: step.factor, selectedId: step.id)
    }

    func isZoomSelected(_ step: ZoomStep) -> Bool {
        step.id == selectedZoomId
    }

    private func setNativeZoom(uiZoom: CGFloat, selectedId: String) {
        guard let device = videoDevice else { return }

        let minZ = CGFloat(device.minAvailableVideoZoomFactor)
        let maxZ = CGFloat(device.maxAvailableVideoZoomFactor)

        // BACK camera: UI 0.5 can exist
        // FRONT camera: UI starts at 1.0
        let uiBase: CGFloat = (currentPosition == .back) ? 0.5 : 1.0
        let uiToDeviceScale: CGFloat = (minZ <= uiBase + 0.01) ? 1.0 : (minZ / uiBase)

        let deviceZoom = uiZoom * uiToDeviceScale
        let target = max(minZ, min(deviceZoom, maxZ))

        do {
            try device.lockForConfiguration()
            device.ramp(toVideoZoomFactor: target, withRate: 8.0)
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.selectedZoomId = selectedId
            }
        } catch {}

        // Update lens text immediately for internal state
        DispatchQueue.main.async {
            self.refreshLensDebug()
        }

        // Fire toast slightly later so the system has time to settle on the final lens
        scheduleLensDebugPulse(after: 0.28)
    }

    // Critical: used ONLY during camera swap to guarantee the preview matches the selected button immediately.
    // Normal zoom presses still use ramp.
    private func setNativeZoomImmediate(uiZoom: CGFloat, selectedId: String) {
        guard let device = videoDevice else { return }

        let minZ = CGFloat(device.minAvailableVideoZoomFactor)
        let maxZ = CGFloat(device.maxAvailableVideoZoomFactor)

        // Same exact mapping as setNativeZoom (do not change)
        let uiBase: CGFloat = (currentPosition == .back) ? 0.5 : 1.0
        let uiToDeviceScale: CGFloat = (minZ <= uiBase + 0.01) ? 1.0 : (minZ / uiBase)

        let deviceZoom = uiZoom * uiToDeviceScale
        let target = max(minZ, min(deviceZoom, maxZ))

        do {
            try device.lockForConfiguration()
            device.cancelVideoZoomRamp()
            device.videoZoomFactor = target
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.selectedZoomId = selectedId
                self.refreshLensDebug()
            }
        } catch {}
    }

    private func scheduleLensDebugPulse(after seconds: Double) {
        debugWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshLensDebug()
            self.lensDebugPulse += 1
        }
        debugWorkItem = item

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: Session setup

    private func configureSession() {

        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        currentPosition = .back

        guard let device = pickBestCameraDevice(for: currentPosition) else { return }
        videoDevice = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {}

        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        rebuildZoomSteps(for: device, position: currentPosition)
        refreshLensDebug()

        if let one = zoomSteps.first(where: { $0.id == "1" }) {
            setNativeZoom(uiZoom: one.factor, selectedId: one.id)
        } else if let first = zoomSteps.first {
            setNativeZoom(uiZoom: first.factor, selectedId: first.id)
        }

        DispatchQueue.main.async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func reconfigureForCurrentPosition() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            if let di = input as? AVCaptureDeviceInput {
                session.removeInput(di)
            }
        }

        guard let device = pickBestCameraDevice(for: currentPosition) else { return }
        videoDevice = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {}

        rebuildZoomSteps(for: device, position: currentPosition)
        refreshLensDebug()

        // Force the preview to match the default selected button immediately on swap.
        // This prevents "1x" showing while the preview is still at 0.5 ultrawide.
        if let one = zoomSteps.first(where: { $0.id == "1" }) {
            setNativeZoomImmediate(uiZoom: one.factor, selectedId: one.id)
        } else if let first = zoomSteps.first {
            setNativeZoomImmediate(uiZoom: first.factor, selectedId: first.id)
        }
    }

    private func pickBestCameraDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .back {
            if let triple = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) { return triple }
            if let dual = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) { return dual }
            if let dualWide = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) { return dualWide }
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        } else {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
    }

    private func rebuildZoomSteps(for device: AVCaptureDevice, position: AVCaptureDevice.Position) {

        // BACK: 0.5, 1, 2, 4, 8
        // FRONT: 1, 2
        let desired: [CGFloat] = (position == .back) ? [0.5, 1, 2, 4, 8] : [1, 2]

        let minZ = CGFloat(device.minAvailableVideoZoomFactor)
        let maxZ = CGFloat(device.maxAvailableVideoZoomFactor)

        let uiBase: CGFloat = (position == .back) ? 0.5 : 1.0
        let uiToDeviceScale: CGFloat = (minZ <= uiBase + 0.01) ? 1.0 : (minZ / uiBase)

        let filtered = desired.filter { ui in
            let dz = ui * uiToDeviceScale
            return dz >= minZ - 0.001 && dz <= maxZ + 0.001
        }

        zoomSteps = filtered.map { z in
            let id: String
            if z == 0.5 { id = "0.5" }
            else if z == 1 { id = "1" }
            else { id = String(Int(z)) }

            let label: String
            if z == 0.5 { label = "0.5" }
            else if z == 1 { label = "1" }
            else { label = String(Int(z)) }

            return ZoomStep(id: id, factor: z, label: label)
        }

        if zoomSteps.isEmpty {
            zoomSteps = [ZoomStep(id: "1", factor: 1.0, label: "1")]
        }
    }

    private func refreshLensDebug() {
        guard let device = videoDevice else { return }

        if #available(iOS 15.0, *) {
            if let active = device.activePrimaryConstituent {
                lensDebugText = lensName(for: active, position: currentPosition)
                return
            }
        }

        lensDebugText = lensName(for: device, position: currentPosition)
    }

    private func lensName(for device: AVCaptureDevice, position: AVCaptureDevice.Position) -> String {
        if position == .front {
            return "Front"
        }

        switch device.deviceType {
        case .builtInUltraWideCamera:
            return "Ultra Wide"
        case .builtInWideAngleCamera:
            return "Wide"
        case .builtInTelephotoCamera:
            return "Telephoto"
        default:
            return "Wide"
        }
    }

    // MARK: Flash support

    private func supportedFlashSettings() -> [FlashSetting] {
        let modes = photoOutput.supportedFlashModes
        var out: [FlashSetting] = []
        if modes.contains(.off) { out.append(.off) }
        if modes.contains(.auto) { out.append(.auto) }
        if modes.contains(.on) { out.append(.on) }
        return out
    }

    private func avFlashMode(for setting: FlashSetting) -> AVCaptureDevice.FlashMode {
        switch setting {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }

    private func captureVideoOrientation() -> AVCaptureVideoOrientation {
        // Note: landscape mapping is intentionally flipped.
        // When the device is rotated left, the camera connection needs the opposite landscape value.
        switch UIDevice.current.orientation {
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        case .portraitUpsideDown:
            return .portraitUpsideDown
        default:
            return .portrait
        }
    }
}

// MARK: - Photo Delegate

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let onFinish: (Data?) -> Void

    init(onFinish: @escaping (Data?) -> Void) {
        self.onFinish = onFinish
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil else {
            onFinish(nil)
            return
        }
        onFinish(photo.fileDataRepresentation())
    }
}
