import Foundation
import Swifter
import UIKit

class AppServer: ObservableObject {
    // MARK: - Sub-components
    let ble      = BLEManager()
    let camera   = CameraStreamer()
    let audio    = AudioStreamer()
    let sessions = SessionsStore()
    let recorder = Recorder()

    // MARK: - Published state
    @Published var isRunning = false
    @Published var localIP: String = "–"
    @Published var cameraFPS: Double = 30
    @Published var avSyncDelayMs: Int = 300
    @Published var avDelayMs: Int = 0
    @Published var overlayDelayMs: Int = 200
    @Published var availableLenses: [LensOption] = []
    @Published var currentLensId: String = "wide"
    @Published var titleText: String = "SG Timer"
    @Published var connectedDeviceName: String? = nil
    @Published var connectedDeviceAddress: String? = nil
    @Published var isScanning: Bool = false
    @Published var scannedDevices: [BLEDeviceInfo] = []
    @Published var consoleLines: [String] = []
    @Published var isRecording: Bool = false

    // MARK: - Internal
    private var hasStarted = false          // guards against double startServer() calls
    private let http = HttpServer()
    private var wsClients = [WebSocketSession]()
    private let wsLock = NSLock()
    private var avClients = [WebSocketSession]()
    private let avLock = NSLock()
    private let avWriteQueue = DispatchQueue(label: "av.write", qos: .userInteractive)
    private var audioBatch = [[UInt8]]()
    private let audioBatchLock = NSLock()
    private let audioBatchSize = 4   // ~92 ms per WS message
    private let stateLock = NSLock()
    private var serverGeneration: Int = Int(Date().timeIntervalSince1970)

    private var timerState = TimerState()
    private var lastTimerState: [String: Any]? = nil

    // MARK: - Init

    init() {
        loadSettings()
        ble.onEvent = { [weak self] event in self?.handleBLEEvent(event) }
        availableLenses = CameraStreamer.availableLenses()
        setupRoutes()
    }

    // MARK: - Lifecycle

    func startServer(port: UInt16 = 8080) {
        // SGTimerBLEApp.handleForeground() and ContentView.onAppear both call this;
        // guard prevents the second call from reconfiguring the camera session while
        // startRunning() is still in flight on its background queue (race → no frames).
        guard !hasStarted else { return }
        hasStarted = true

        let lenses = CameraStreamer.availableLenses()
        let savedDeviceType = lenses.first(where: { $0.id == currentLensId })?.deviceType ?? .builtInWideAngleCamera
        try? camera.start(initialLens: savedDeviceType)
        try? audio.start()

        // Wire recorder: raw video and PCM audio
        camera.onRawSampleBuffer = { [weak self] sb in self?.recorder.appendVideo(sb) }
        audio.onRawPCMBuffer     = { [weak self] buf, time in
            self?.recorder.appendAudio(buf, time: time)
        }
        if let fmt = audio.captureFormat { recorder.configureAudio(from: fmt) }

        // Wire A/V callbacks for the /avstream WebSocket mux
        camera.onFrame = { [weak self] jpeg in
            guard let self else { return }
            var msg = [UInt8](); msg.reserveCapacity(jpeg.count + 1)
            msg.append(0x01); msg.append(contentsOf: jpeg)
            self.broadcastAV(msg)
        }
        audio.onFrame = { [weak self] adts in
            guard let self else { return }
            self.audioBatchLock.lock()
            self.audioBatch.append(Array(adts))
            let ready = self.audioBatch.count >= self.audioBatchSize
            let batch = ready ? self.audioBatch : []
            if ready { self.audioBatch = [] }
            self.audioBatchLock.unlock()
            guard !batch.isEmpty else { return }
            let total = batch.reduce(0) { $0 + $1.count }
            var msg = [UInt8](); msg.reserveCapacity(total + 1)
            msg.append(0x02)
            for f in batch { msg.append(contentsOf: f) }
            self.broadcastAV(msg)
        }

        do {
            try http.start(port, forceIPv4: true)
            DispatchQueue.main.async {
                self.isRunning = true
                self.localIP = getLocalIPAddress() ?? "unknown"
            }
        } catch {
            print("HTTP server failed to start: \(error)")
        }
    }

    func stopServer() {
        hasStarted = false
        camera.onFrame = nil
        audio.onFrame  = nil
        http.stop()
        camera.stop()
        audio.stop()
        DispatchQueue.main.async { self.isRunning = false }
    }

    func handleForeground() {
        guard isRunning else {
            startServer()
            return
        }
        // New generation so browsers detect the restart and reload
        serverGeneration = Int(Date().timeIntervalSince1970)
        broadcast(["type": "RELOAD"])
        // Reconnect to last known device if not currently connected
        if connectedDeviceName == nil,
           let addr = UserDefaults.standard.string(forKey: "lastDeviceAddr"),
           let name = UserDefaults.standard.string(forKey: "lastDeviceName") {
            ble.connect(address: addr, name: name)
        }
    }

    // MARK: - Settings persistence

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "cameraFPS") != nil {
            cameraFPS = defaults.double(forKey: "cameraFPS")
        }
        if defaults.object(forKey: "avSyncDelayMs") != nil {
            avSyncDelayMs = defaults.integer(forKey: "avSyncDelayMs")
        }
        if let lens = defaults.string(forKey: "currentLensId") {
            currentLensId = lens
        }
        if defaults.object(forKey: "avDelayMs") != nil {
            avDelayMs = defaults.integer(forKey: "avDelayMs")
        }
        if defaults.object(forKey: "overlayDelayMs") != nil {
            overlayDelayMs = defaults.integer(forKey: "overlayDelayMs")
        }
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(cameraFPS, forKey: "cameraFPS")
        defaults.set(avSyncDelayMs, forKey: "avSyncDelayMs")
        defaults.set(currentLensId, forKey: "currentLensId")
        defaults.set(avDelayMs, forKey: "avDelayMs")
        defaults.set(overlayDelayMs, forKey: "overlayDelayMs")
    }

    // MARK: - Native UI actions (called from ContentView)

    func scan() {
        DispatchQueue.main.async { self.isScanning = true; self.scannedDevices = [] }
        ble.scan(duration: 4.0) { [weak self] devices in
            DispatchQueue.main.async { self?.scannedDevices = devices; self?.isScanning = false }
        }
    }

    func connectDevice(_ device: BLEDeviceInfo) {
        ble.connect(address: device.address, name: device.name)
    }

    func disconnectDevice() {
        guard let addr = connectedDeviceAddress else { return }
        ble.disconnect(address: addr)
    }

    func setTitle(_ t: String) {
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        titleText = trimmed
        broadcast(["type": "TITLE_UPDATE", "title": trimmed])
    }

    func updateFPS(_ fps: Int) {
        cameraFPS = Double(fps)
        broadcast(settingsDict())
    }

    func updateSyncDelay(_ ms: Int) {
        avSyncDelayMs = ms
        broadcast(settingsDict())
    }

    func updateAvDelay(_ ms: Int) {
        avDelayMs = ms
        broadcast(settingsDict())
    }

    func updateOverlayDelay(_ ms: Int) {
        overlayDelayMs = ms
        broadcast(settingsDict())
    }

    func saveSettingsAndReload() {
        saveSettings()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.broadcast(["type": "RELOAD"])
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        do {
            let videoSize = camera.currentOutputSize
            try recorder.start(videoSize: videoSize)
            isRecording = true
            appendConsole("⏺ Recording started")
            refreshOverlay()
        } catch {
            appendConsole("❌ Record error: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recorder.stop { [weak self] success in
            DispatchQueue.main.async {
                self?.appendConsole(success ? "📹 Clip saved to Photos" : "❌ Save to Photos failed")
            }
        }
    }

    // Render current timer state onto a CIImage and push to recorder.
    // Always applied immediately (0 ms) — recording A/V is already in sync.
    private func scheduleOverlayRefresh() {
        guard isRecording else { return }
        DispatchQueue.main.async { [weak self] in
            self?.refreshOverlay()
        }
    }

    private func refreshOverlay() {
        guard isRecording else { return }

        stateLock.lock()
        let shots      = Array(timerState.shots.suffix(8))
        let status     = timerState.status
        let firstShot  = timerState.firstShot
        let bestSplit  = timerState.bestSplit
        let totalTime  = timerState.totalTime
        let totalShots = timerState.shots.count
        stateLock.unlock()

        let videoSize = camera.currentOutputSize

        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1.0       // render at 1:1 pixel — matches video frame dimensions exactly
        let renderer = UIGraphicsImageRenderer(size: videoSize, format: fmt)
        let img = renderer.image { ctx in
            let g = ctx.cgContext
            let pad: CGFloat = 20
            let W = videoSize.width
            let H = videoSize.height

            func bg(_ rect: CGRect, alpha: CGFloat = 0.55) {
                g.setFillColor(UIColor.black.withAlphaComponent(alpha).cgColor)
                UIBezierPath(roundedRect: rect, cornerRadius: 8).fill()
            }

            // Status — top right
            let statusColor: UIColor = status == "LIVE"    ? .systemGreen
                                     : status == "STANDBY" ? .systemOrange : .systemRed
            let sFont = UIFont.boldSystemFont(ofSize: 20)
            let sAttr: [NSAttributedString.Key: Any] = [.font: sFont, .foregroundColor: statusColor]
            let sSz   = (status as NSString).size(withAttributes: sAttr)
            let sOrigin = CGPoint(x: W - sSz.width - pad - 12, y: pad + 4)
            bg(CGRect(x: sOrigin.x - 10, y: sOrigin.y - 6, width: sSz.width + 20, height: sSz.height + 10))
            (status as NSString).draw(at: sOrigin, withAttributes: sAttr)

            // Stats — top left (only when shots exist)
            if totalShots > 0 {
                let mFont = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium)
                let mAttr: [NSAttributedString.Key: Any] = [.font: mFont, .foregroundColor: UIColor.white]
                let lines = [
                    "First:  \(String(format: "%.2f", firstShot)) s",
                    "Best:   \(String(format: "%.2f", bestSplit)) s",
                    "Total:  \(String(format: "%.2f", totalTime)) s",
                    "Shots:  \(totalShots)"
                ]
                let lh: CGFloat = 24
                let bh = CGFloat(lines.count) * lh + 16
                bg(CGRect(x: pad - 8, y: pad - 6, width: 200, height: bh))
                for (i, line) in lines.enumerated() {
                    (line as NSString).draw(at: CGPoint(x: pad, y: pad + CGFloat(i) * lh),
                                            withAttributes: mAttr)
                }
            }

            // Shot list — bottom right
            if !shots.isEmpty {
                let shFont = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
                let lh: CGFloat = 28
                let bw: CGFloat = 230
                let bh = CGFloat(shots.count) * lh + 16
                let bx = W - bw - pad
                let by = H - bh - pad
                bg(CGRect(x: bx - 8, y: by - 8, width: bw + 16, height: bh))
                for (i, shot) in shots.reversed().enumerated() {
                    let label = "#\(shot.num) — \(String(format: "%.2f", shot.time)) s"
                    let attr: [NSAttributedString.Key: Any] = [.font: shFont, .foregroundColor: UIColor.white]
                    (label as NSString).draw(at: CGPoint(x: bx, y: by + CGFloat(i) * lh),
                                             withAttributes: attr)
                }
            }
        }
        recorder.overlayImage = CIImage(image: img)
    }

    // MARK: - Lens switching

    func setLens(id: String) {
        let lenses = CameraStreamer.availableLenses()
        guard let lens = lenses.first(where: { $0.id == id }) else { return }
        try? camera.switchLens(to: lens.deviceType)
        DispatchQueue.main.async { self.currentLensId = id }
        saveSettings()
        broadcast(["type": "LENS_CHANGED", "lensId": id])
    }

    // MARK: - A/V WebSocket hub

    private func broadcastAV(_ bytes: [UInt8]) {
        avWriteQueue.async { [weak self] in
            guard let self else { return }
            self.avLock.lock(); let clients = self.avClients; self.avLock.unlock()
            for c in clients { c.writeBinary(bytes) }
        }
    }

    // MARK: - Timer WebSocket hub

    private func addClient(_ s: WebSocketSession) {
        wsLock.lock(); wsClients.append(s); wsLock.unlock()
    }

    private func removeClient(_ s: WebSocketSession) {
        wsLock.lock(); wsClients.removeAll { $0 === s }; wsLock.unlock()
    }

    private func broadcast(_ dict: [String: Any]) {
        guard let text = jsonString(dict) else { return }
        wsLock.lock(); let clients = wsClients; wsLock.unlock()
        for c in clients { c.writeText(text) }
    }

    private func onConnect(_ session: WebSocketSession) {
        addClient(session)

        // Send server generation so browsers can detect restarts
        if let t = jsonString(["type": "SERVER_HELLO", "serverGen": serverGeneration]) {
            session.writeText(t)
        }

        // Send current title
        if let t = jsonString(["type": "TITLE_UPDATE", "title": titleText]) {
            session.writeText(t)
        }

        // Send current settings
        if let t = jsonString(settingsDict()) {
            session.writeText(t)
        }

        // Send session sync
        stateLock.lock()
        let state: [String: Any]? = timerState.sessId != nil
            ? timerState.toDictionary()
            : lastTimerState
        stateLock.unlock()

        if let state, let t = jsonString(["type": "SESSION_SYNC", "state": state]) {
            session.writeText(t)
        }
    }

    private func settingsDict() -> [String: Any] {
        [
            "type": "SETTINGS_UPDATE",
            "fps": Int(cameraFPS),
            "avSyncDelayMs": avSyncDelayMs,
            "avDelayMs": avDelayMs,
            "overlayDelayMs": overlayDelayMs,
            "currentLensId": currentLensId
        ]
    }

    // MARK: - Console

    private func appendConsole(_ line: String) {
        DispatchQueue.main.async {
            self.consoleLines.append(line)
            if self.consoleLines.count > 50 { self.consoleLines.removeFirst() }
        }
    }

    // MARK: - BLE event dispatch

    private func handleBLEEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        // Update native iOS UI for connection events and console
        switch type {
        case "DEVICE_CONNECTED":
            let name = event["name"] as? String ?? "Unknown"
            let addr = event["addr"] as? String ?? ""
            UserDefaults.standard.set(addr, forKey: "lastDeviceAddr")
            UserDefaults.standard.set(name, forKey: "lastDeviceName")
            DispatchQueue.main.async {
                self.connectedDeviceName = name
                self.connectedDeviceAddress = addr
                self.scannedDevices = []
            }
            appendConsole("✅ Connected: \(name)")
        case "DEVICE_DISCONNECTED":
            let name = event["name"] as? String ?? "Unknown"
            DispatchQueue.main.async {
                self.connectedDeviceName = nil
                self.connectedDeviceAddress = nil
            }
            appendConsole("⚠️ Disconnected: \(name)")
        case "SESSION_STARTED":
            appendConsole("🏁 Session started")
        case "SESSION_STOPPED":
            appendConsole("⏹ Session stopped")
        case "SESSION_SUSPENDED":
            appendConsole("⏸ Standby")
        case "SESSION_RESUMED":
            appendConsole("▶ Resumed")
        case "SHOT_DETECTED":
            let num  = event["num"]  as? Int    ?? 0
            let time = event["time"] as? Double ?? 0
            let split = event["split"] as? Double
            var line = "#\(num) — \(String(format: "%.2f", time))s"
            if let s = split { line += " [split: \(String(format: "%.2f", s))s]" }
            appendConsole(line)
        case "WATCHDOG":
            let status = event["status"] as? String ?? ""
            let name   = event["name"]   as? String ?? ""
            appendConsole("🔄 Watchdog \(status): \(name)")
        default:
            break
        }

        stateLock.lock()
        switch type {
        case "SESSION_STARTED":
            let id = event["sess_id"] as? Int ?? Int(Date().timeIntervalSince1970)
            timerState.reset()
            timerState.sessId  = id
            timerState.active  = true
            timerState.status  = "LIVE"
            sessions.createSession(sessId: String(id))

        case "SHOT_DETECTED":
            let num    = event["num"]   as? Int    ?? (timerState.shots.count + 1)
            let time   = event["time"]  as? Double ?? 0
            let split  = event["split"] as? Double
            let tsMs   = Int((time * 1000).rounded())

            timerState.shots.append(Shot(num: num, time: time))
            timerState.totalTime = time
            if timerState.shots.count == 1 { timerState.firstShot = time }
            if let s = split, timerState.bestSplit == 0 || s < timerState.bestSplit {
                timerState.bestSplit = s
            }
            if let id = timerState.sessId {
                sessions.appendShot(sessId: String(id), shotNum: num,
                                    shotTime: time, split: split, tsDevice: tsMs)
            }

        case "SESSION_STOPPED":
            timerState.active  = false
            timerState.status  = "STOPPED"
            lastTimerState     = timerState.toDictionary()

        case "SESSION_SUSPENDED":
            timerState.status = "STANDBY"

        case "SESSION_RESUMED":
            timerState.status = "LIVE"

        default:
            break
        }
        stateLock.unlock()

        switch type {
        case "SESSION_STARTED", "SHOT_DETECTED", "SESSION_STOPPED", "SESSION_SUSPENDED", "SESSION_RESUMED":
            scheduleOverlayRefresh()
        default:
            break
        }

        broadcast(event)
    }

    // MARK: - Route setup

    private func setupRoutes() {

        // ── A/V mux WebSocket (binary: 0x01=JPEG video, 0x02=AAC audio) ──
        http["/avstream"] = websocket(
            text:         { _, _ in },
            connected:    { [weak self] s in
                self?.avLock.lock(); self?.avClients.append(s); self?.avLock.unlock()
            },
            disconnected: { [weak self] s in
                self?.avLock.lock(); self?.avClients.removeAll { $0 === s }; self?.avLock.unlock()
            }
        )

        // ── Timer event WebSocket ───────────────────────────────
        http["/ws"] = websocket(
            text:         { _, _ in },
            connected:    { [weak self] s in self?.onConnect(s) },
            disconnected: { [weak self] s in self?.removeClient(s) }
        )

        // ── MJPEG camera stream ────────────────────────────────
        http.GET["/camera"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let headers: [String: String] = [
                "Content-Type":  "multipart/x-mixed-replace; boundary=frame",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Connection":    "keep-alive"
            ]
            return .raw(200, "OK", headers) { [weak self] writer in
                while let self {
                    if let frame = self.camera.currentFrame() {
                        let hdr = "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n"
                        do {
                            try writer.write(Array(hdr.utf8))
                            try writer.write(frame)
                            try writer.write(Array("\r\n".utf8))
                        } catch {
                            break
                        }
                    }
                    Thread.sleep(forTimeInterval: 1.0 / self.cameraFPS)
                }
            }
        }

        // ── AAC/ADTS audio stream ──────────────────────────────
        http.GET["/audio"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let (subId, sub) = self.audio.subscribe()
            return .raw(200, "OK", [
                "Content-Type":  "audio/aac",
                "Cache-Control": "no-cache, no-store, must-revalidate",
                "Connection":    "keep-alive"
            ]) { [weak self] writer in
                defer { self?.audio.unsubscribe(subId) }
                while true {
                    guard let frame = sub.next(timeout: 0.5) else { continue }
                    do {
                        try writer.write(frame)
                    } catch {
                        break // client disconnected
                    }
                }
            }
        }

        // ── GET /devices (BLE scan) ────────────────────────────
        http.GET["/devices"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let sem = DispatchSemaphore(value: 0)
            var result: [[String: Any]] = []
            self.ble.scan(duration: 4.0) { devices in
                result = devices.map { $0.toDictionary() }
                sem.signal()
            }
            sem.wait()
            return self.json(["devices": result])
        }

        // ── POST /connect ──────────────────────────────────────
        http.POST["/connect"] = { [weak self] req in
            guard let self,
                  let body = jsonDict(req.body),
                  let addr = body["address"] as? String else {
                return .badRequest(.text("Missing address"))
            }
            let name = body["name"] as? String ?? addr
            self.ble.connect(address: addr, name: name)
            return self.json(["status": "connecting", "address": addr, "name": name])
        }

        // ── POST /disconnect ───────────────────────────────────
        http.POST["/disconnect"] = { [weak self] req in
            guard let self,
                  let body = jsonDict(req.body),
                  let addr = body["address"] as? String else {
                return .badRequest(.text("Missing address"))
            }
            self.ble.disconnect(address: addr)
            return self.json(["status": "disconnected", "address": addr])
        }

        // ── GET /status ────────────────────────────────────────
        http.GET["/status"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.json(self.ble.statusDict)
        }

        // ── GET /get_title ─────────────────────────────────────
        http.GET["/get_title"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.json(["title": self.titleText])
        }

        // ── POST /set_title ────────────────────────────────────
        http.POST["/set_title"] = { [weak self] req in
            guard let self,
                  let body = jsonDict(req.body),
                  let t = body["title"] as? String, !t.isEmpty else {
                return .badRequest(.text("Missing title"))
            }
            DispatchQueue.main.async { self.titleText = t }
            self.broadcast(["type": "TITLE_UPDATE", "title": t])
            return self.json(["status": "ok", "title": t])
        }

        // ── GET /get_settings ──────────────────────────────────
        http.GET["/get_settings"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            return self.json([
                "fps": Int(self.cameraFPS),
                "avSyncDelayMs": self.avSyncDelayMs,
                "avDelayMs": self.avDelayMs,
                "overlayDelayMs": self.overlayDelayMs,
                "currentLensId": self.currentLensId
            ])
        }

        // ── POST /save_settings ────────────────────────────────
        http.POST["/save_settings"] = { [weak self] req in
            guard let self, let body = jsonDict(req.body) else {
                return .badRequest(.text("Invalid body"))
            }
            if let fps = body["fps"] as? Int, fps == 15 || fps == 30 {
                DispatchQueue.main.async { self.cameraFPS = Double(fps) }
            }
            if let delay = body["avSyncDelayMs"] as? Int, delay >= 0 {
                DispatchQueue.main.async { self.avSyncDelayMs = delay }
            }
            if let avDelay = body["avDelayMs"] as? Int, avDelay >= 0 {
                DispatchQueue.main.async { self.avDelayMs = avDelay }
            }
            if let overlay = body["overlayDelayMs"] as? Int, overlay >= 0 {
                DispatchQueue.main.async { self.overlayDelayMs = overlay }
            }
            self.saveSettings()
            self.broadcast(self.settingsDict())
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.broadcast(["type": "RELOAD"])
            }
            return self.json(["status": "ok"])
        }

        // ── POST /restart_server ───────────────────────────────
        http.POST["/restart_server"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            self.broadcast(["type": "RELOAD"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.stopServer()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.startServer()
                }
            }
            return self.json(["status": "restarting"])
        }

        // ── GET /get_lenses ────────────────────────────────────
        http.GET["/get_lenses"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            let lenses = CameraStreamer.availableLenses().map { ["id": $0.id, "label": $0.label] }
            return self.json(["lenses": lenses, "current": self.currentLensId])
        }

        // ── POST /set_lens ─────────────────────────────────────
        http.POST["/set_lens"] = { [weak self] req in
            guard let self,
                  let body = jsonDict(req.body),
                  let id = body["id"] as? String else {
                return .badRequest(.text("Missing id"))
            }
            self.setLens(id: id)
            return self.json(["status": "ok", "lensId": id])
        }

        // ── POST /clear_sessions ───────────────────────────────
        http.POST["/clear_sessions"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            self.stateLock.lock(); self.lastTimerState = nil; self.stateLock.unlock()
            let deleted = self.sessions.clearSessions()
            return self.json(["status": "ok", "deleted": deleted])
        }

        // ── GET /sessions ──────────────────────────────────────
        http.GET["/sessions"] = { [weak self] req in
            guard let self else { return .internalServerError }
            let params = Dictionary(req.queryParams.map { ($0.0, $0.1) }, uniquingKeysWith: { $1 })
            let offset = Int(params["offset"] ?? "0") ?? 0
            let limit  = Int(params["limit"]  ?? "20") ?? 20
            let list   = self.sessions.listSessions(offset: offset, limit: limit)
            return self.json(["sessions": list, "offset": offset, "limit": limit])
        }

        // ── GET /download/:sess_id ─────────────────────────────
        http.GET["/download/:sess_id"] = { [weak self] req in
            guard let self,
                  let id  = req.params[":sess_id"],
                  let csv = self.sessions.csvData(sessId: id) else { return .notFound }
            return .raw(200, "OK", [
                "Content-Type": "text/csv",
                "Content-Disposition": "attachment; filename=\"\(id).csv\""
            ]) { writer in try writer.write(csv) }
        }

        // ── Static file fallback ───────────────────────────────
        http.notFoundHandler = { [weak self] req in
            self?.serveStatic(path: req.path) ?? .notFound
        }
    }

    // MARK: - Static files

    private func serveStatic(path: String) -> HttpResponse {
        let rel    = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let target = rel.isEmpty ? "index.html" : rel
        let bundle = Bundle.main.bundleURL

        // 1. Ideal: static/ folder reference preserved directory structure
        let withDir = bundle.appendingPathComponent("static/\(target)")
        if let data = try? Data(contentsOf: withDir) {
            return .ok(.data(data, contentType: mimeType(target)))
        }

        // 2. Xcode copied files flat into bundle root — strip any subdirectory
        let filename = (target as NSString).lastPathComponent
        let flat = bundle.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: flat) {
            return .ok(.data(data, contentType: mimeType(target)))
        }

        return .notFound
    }

    private func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html":        return "text/html; charset=utf-8"
        case "css":         return "text/css"
        case "js":          return "application/javascript"
        case "json":        return "application/json"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "ico":         return "image/x-icon"
        case "svg":         return "image/svg+xml"
        default:            return "application/octet-stream"
        }
    }

    // MARK: - JSON helpers

    private func json(_ dict: [String: Any]) -> HttpResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return .internalServerError
        }
        return .ok(.data(data, contentType: "application/json"))
    }

    private func jsonString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// Free helper – parse JSON body from [UInt8]
private func jsonDict(_ body: [UInt8]) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
}
