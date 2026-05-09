import Foundation
import Swifter

class AppServer: ObservableObject {
    // MARK: - Sub-components
    let ble      = BLEManager()
    let camera   = CameraStreamer()
    let audio    = AudioStreamer()
    let sessions = SessionsStore()

    // MARK: - Published state
    @Published var isRunning = false
    @Published var localIP: String = "–"

    // MARK: - Internal
    private let http = HttpServer()
    private var wsClients = [WebSocketSession]()
    private let wsLock = NSLock()
    private let stateLock = NSLock()

    private var timerState = TimerState()
    private var lastTimerState: [String: Any]? = nil
    private var title = "SG Timer"

    // MARK: - Init

    init() {
        ble.onEvent = { [weak self] event in self?.handleBLEEvent(event) }
        setupRoutes()
    }

    // MARK: - Lifecycle

    func startServer(port: UInt16 = 8080) {
        try? camera.start()
        try? audio.start()
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
        http.stop()
        camera.stop()
        audio.stop()
        DispatchQueue.main.async { self.isRunning = false }
    }

    // MARK: - WebSocket hub

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

        // Send current title
        if let t = jsonString(["type": "TITLE_UPDATE", "title": title]) {
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

    // MARK: - BLE event dispatch

    private func handleBLEEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

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

        broadcast(event)
    }

    // MARK: - Route setup

    private func setupRoutes() {

        // ── WebSocket ──────────────────────────────────────────
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
                    Thread.sleep(forTimeInterval: 1.0 / 25.0)
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
            return self.json(["title": self.title])
        }

        // ── POST /set_title ────────────────────────────────────
        http.POST["/set_title"] = { [weak self] req in
            guard let self,
                  let body = jsonDict(req.body),
                  let t = body["title"] as? String, !t.isEmpty else {
                return .badRequest(.text("Missing title"))
            }
            self.title = t
            self.broadcast(["type": "TITLE_UPDATE", "title": t])
            return self.json(["status": "ok", "title": t])
        }

        // ── POST /clear_sessions ───────────────────────────────
        http.POST["/clear_sessions"] = { [weak self] _ in
            guard let self else { return .internalServerError }
            stateLock.lock(); lastTimerState = nil; stateLock.unlock()
            let (moved, ts) = self.sessions.clearSessions()
            return self.json([
                "status": "ok",
                "archived": moved,
                "archive_dir": "data/archive/\(ts)"
            ])
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
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let target = rel.isEmpty ? "index.html" : rel

        guard let base = Bundle.main.url(forResource: "static", withExtension: nil) else {
            return .notFound
        }
        let fileURL = base.appendingPathComponent(target)
        guard let data = try? Data(contentsOf: fileURL) else { return .notFound }
        return .ok(.data(data, contentType: mimeType(target)))
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
