import AVFoundation
import UIKit
import CoreImage

struct LensOption: Identifiable {
    let id: String          // "ultra", "wide", "tele"
    let label: String       // "0.5×", "1×", "3×"
    let deviceType: AVCaptureDevice.DeviceType
}

class CameraStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "camera.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MJPEG push subscription — mirrors AudioStreamer.Subscriber
    final class MjpegSubscriber {
        private var latest: Data? = nil
        private let lock = NSLock()
        private let sem  = DispatchSemaphore(value: 0)

        fileprivate func push(_ frame: Data) {
            lock.lock()
            let wasNil = (latest == nil)
            latest = frame          // drop older unread frame; always keep newest
            lock.unlock()
            if wasNil { sem.signal() }
        }

        func next(timeout: TimeInterval = 0.5) -> Data? {
            guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock(); defer { lock.unlock() }
            let f = latest; latest = nil; return f
        }
    }

    private var mjpegSubs = [UUID: MjpegSubscriber]()
    private let mjpegSubLock = NSLock()

    func subscribeMjpeg() -> (UUID, MjpegSubscriber) {
        let id = UUID(); let sub = MjpegSubscriber()
        mjpegSubLock.lock(); mjpegSubs[id] = sub; mjpegSubLock.unlock()
        return (id, sub)
    }

    func unsubscribeMjpeg(_ id: UUID) {
        mjpegSubLock.lock(); mjpegSubs.removeValue(forKey: id); mjpegSubLock.unlock()
    }

    private var _currentFrame: Data?
    private let frameLock = NSLock()

    var onFrame: ((Data) -> Void)?
    var onRawSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onBitrateUpdate: ((Double) -> Void)?   // kbps
    var streamMaxDimension: CGFloat = 1280
    var streamJpegQuality: CGFloat = 0.65

    // Encode queue: ALL heavy work (CIImage → CGImage → JPEG) runs here, never on the capture queue.
    // Rate limiter sets the target interval; encodeInFlight prevents queue buildup when encoding
    // is slower than the target (graceful degradation under thermal load, no jitter).
    private let encodeQueue = DispatchQueue(label: "camera.encode", qos: .userInitiated)
    private var encodeInFlight = false
    private let encodeInFlightLock = NSLock()

    private var bitrateAccBytes: Int = 0
    private var bitrateWindowStart: Date = Date()
    private(set) var currentDeviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
    private(set) var activePreset: AVCaptureSession.Preset = .hd1280x720

    var currentOutputSize: CGSize {
        let (lw, lh): (CGFloat, CGFloat)
        switch activePreset {
        case .hd4K3840x2160: (lw, lh) = (3840, 2160)
        case .hd1920x1080:   (lw, lh) = (1920, 1080)
        default:             (lw, lh) = (1280, 720)
        }
        if let conn = videoOutput.connection(with: .video) {
            switch conn.videoOrientation {
            case .portrait, .portraitUpsideDown: return CGSize(width: lh, height: lw)
            default: break
            }
        }
        return CGSize(width: lw, height: lh)
    }

    // MARK: - Lens enumeration

    static func availableLenses() -> [LensOption] {
        let candidates: [(AVCaptureDevice.DeviceType, String, String)] = [
            (.builtInUltraWideCamera, "ultra", "0.5×"),
            (.builtInWideAngleCamera, "wide",  "1×"),
            (.builtInTelephotoCamera, "tele",  "3×"),
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: candidates.map { $0.0 },
            mediaType: .video,
            position: .back
        )
        let available = Set(session.devices.map { $0.deviceType })
        return candidates.compactMap { (dt, id, label) in
            available.contains(dt) ? LensOption(id: id, label: label, deviceType: dt) : nil
        }
    }

    // MARK: - Lifecycle

    func start(initialLens: AVCaptureDevice.DeviceType = .builtInWideAngleCamera) throws {
        try switchLens(to: initialLens)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        // Remove before adding so a repeated start() call doesn't stack duplicate observers
        NotificationCenter.default.removeObserver(self,
            name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    func setFPS(_ fps: Double) {
        guard let device = captureSession.inputs
            .compactMap({ ($0 as? AVCaptureDeviceInput)?.device })
            .first(where: { $0.hasMediaType(.video) }) else { return }
        let t = CMTime(value: 1, timescale: CMTimeScale(fps))
        try? device.lockForConfiguration()
        device.activeVideoMinFrameDuration = t
        device.activeVideoMaxFrameDuration = t
        device.unlockForConfiguration()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self,
            name: UIDevice.orientationDidChangeNotification, object: nil)
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        captureSession.stopRunning()
    }

    // MARK: - Orientation tracking

    @objc private func deviceOrientationChanged() {
        if let conn = videoOutput.connection(with: .video) {
            applyVideoOrientation(to: conn)
        }
    }

    private func applyVideoOrientation(to connection: AVCaptureConnection) {
        guard connection.isVideoOrientationSupported else { return }
        switch UIDevice.current.orientation {
        case .portrait:            connection.videoOrientation = .portrait
        case .portraitUpsideDown:  connection.videoOrientation = .portraitUpsideDown
        case .landscapeLeft:       connection.videoOrientation = .landscapeRight
        case .landscapeRight:      connection.videoOrientation = .landscapeLeft
        default: break
        }
    }

    // MARK: - Lens switching

    func switchLens(to deviceType: AVCaptureDevice.DeviceType) throws {
        guard let device = AVCaptureDevice.default(deviceType, for: .video, position: .back),
              let newInput = try? AVCaptureDeviceInput(device: device) else {
            throw NSError(domain: "CameraStreamer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Lens not available"])
        }

        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }

        if captureSession.canAddInput(newInput) {
            captureSession.addInput(newInput)
        }

        // Pick the highest supported preset: 4K → 1080p → 720p
        let preset: AVCaptureSession.Preset
        if captureSession.canSetSessionPreset(.hd4K3840x2160) {
            preset = .hd4K3840x2160
        } else if captureSession.canSetSessionPreset(.hd1920x1080) {
            preset = .hd1920x1080
        } else {
            preset = .hd1280x720
        }
        captureSession.sessionPreset = preset
        activePreset = preset

        // Lock FPS to 30 — prevents auto-slowdown in low light
        try? device.lockForConfiguration()
        let t30 = CMTime(value: 1, timescale: 30)
        device.activeVideoMinFrameDuration = t30
        device.activeVideoMaxFrameDuration = t30
        device.unlockForConfiguration()

        if !captureSession.outputs.contains(videoOutput) {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }
        }

        captureSession.commitConfiguration()
        currentDeviceType = deviceType

        if let conn = videoOutput.connection(with: .video) {
            applyVideoOrientation(to: conn)
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .standard
            }
        }

        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.startRunning()
            }
        }
    }

    // MARK: - Frame access

    func currentFrame() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return _currentFrame
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Recorder always gets every frame at full rate.
        onRawSampleBuffer?(sampleBuffer)

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Drop frame if previous encode is still running. This is the only
        // backpressure needed — no timestamp rate limiter. A timestamp limiter
        // at exactly 1/fps causes 50% frame drops when the camera delivers
        // frames ~1% early (33.0 ms vs 33.33 ms threshold → every other frame
        // dropped → 15 fps on a 30 fps camera).
        encodeInFlightLock.lock()
        guard !encodeInFlight else { encodeInFlightLock.unlock(); return }
        encodeInFlight = true
        encodeInFlightLock.unlock()

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let quality = streamJpegQuality
        let maxDim = streamMaxDimension

        encodeQueue.async { [weak self] in
            defer {
                self?.encodeInFlightLock.lock()
                self?.encodeInFlight = false
                self?.encodeInFlightLock.unlock()
            }
            guard let self else { return }

            // ALL heavy work (CGImage render → JPEG) runs here, never on
            // the capture queue. The capture queue stays instant so AVFoundation
            // delivers frames on time and alwaysDiscardsLateVideoFrames never
            // has to intervene with irregular drop patterns.
            let extent = ciImage.extent
            let streamScale = min(1.0, maxDim / max(extent.width, extent.height))
            let scaled = streamScale < 1.0
                ? ciImage.transformed(by: CGAffineTransform(scaleX: streamScale, y: streamScale))
                : ciImage
            guard let cgImage = self.ciContext.createCGImage(scaled, from: scaled.extent),
                  let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: quality)
            else { return }

            self.frameLock.lock()
            self._currentFrame = jpegData
            self.frameLock.unlock()

            self.onFrame?(jpegData)

            self.mjpegSubLock.lock()
            let subs = Array(self.mjpegSubs.values)
            self.mjpegSubLock.unlock()
            subs.forEach { $0.push(jpegData) }

            self.bitrateAccBytes += jpegData.count
            let elapsed = Date().timeIntervalSince(self.bitrateWindowStart)
            if elapsed >= 1.0 {
                let kbps = Double(self.bitrateAccBytes * 8) / elapsed / 1000.0
                self.bitrateAccBytes = 0
                self.bitrateWindowStart = Date()
                self.onBitrateUpdate?(kbps)
            }
        }
    }
}
