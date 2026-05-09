# SGTimer BLE – iOS App

An iPhone/iPad server app that replaces the Python server.  
The device acts as the BLE-to-WebSocket bridge **and** streams its camera as a live background for the display page.

---

## Architecture

```
iPhone/iPad (iOS App)
│
├── Embedded HTTP server (Swifter, port 8080)
│   ├── /              → display page (index.html) – camera as background
│   ├── /admin.html    → admin panel (shown natively in-app)
│   ├── /ws            → WebSocket hub (real-time BLE events)
│   ├── /camera        → MJPEG live camera stream (25 fps)
│   ├── /devices       → BLE scan (4 s)
│   ├── /connect       → connect to SG Timer device
│   ├── /disconnect    → disconnect
│   ├── /status        → connection status
│   ├── /get_title     → get competition title
│   ├── /set_title     → set competition title
│   ├── /sessions      → list recorded sessions
│   ├── /download/:id  → download session CSV
│   └── /clear_sessions → archive sessions
│
├── CoreBluetooth – connects to SG Timer devices
│   Service:  7520ffff-14d2-4cda-8b6b-697c554c9311
│   Events:   75200001-14d2-4cda-8b6b-697c554c9311
│   API ver:  7520fffe-14d2-4cda-8b6b-697c554c9311
│
└── AVFoundation – MJPEG camera stream for web clients
```

Clients on the same Wi-Fi open `http://<device-ip>:8080` to see the live
timer display with the device's camera feed as background.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| Xcode | 15+ | App Store |
| XcodeGen | 2.x | `brew install xcodegen` |
| Swift | 5.9+ | bundled with Xcode |

---

## Setup

### 1 – Generate the Xcode project

```bash
cd ios/
xcodegen generate
```

This creates `SGTimerBLE.xcodeproj` from `project.yml`.

### 2 – Open in Xcode

```bash
open SGTimerBLE.xcodeproj
```

### 3 – Sign the app

1. In Xcode select the **SGTimerBLE** target → **Signing & Capabilities**.
2. Set your **Team** (Apple Developer account).
3. Xcode fills in the bundle ID automatically.

### 4 – Build & Run

Connect your iPhone or iPad via USB, select it as the run destination,
then press **⌘R**.

> The app requires a **real device** – BLE and camera are not available in
> the iOS Simulator.

---

## First-launch permissions

The OS will prompt for three permissions the first time the app runs:

| Permission | Purpose |
|-----------|---------|
| Bluetooth | Scan and connect to SG Timer devices |
| Camera | Stream video as background for display clients |
| Local Network | Advertise the HTTP server on your Wi-Fi |

Grant all three.

---

## Testing

### A – Admin panel (in-app)

The app opens directly on the admin page:

1. Tap **🔍 Scan** – waits 4 s, then populates the device dropdown.
2. Select an **SG-SST-x** device and tap **🔗 Connect**.
3. The console logs `✅ Device connected: …`.
4. Fire shots with the SG Timer – log entries appear in real time.
5. Set a **Main Title** and tap **Set Title**.

### B – Display page from another device

1. Note the URL shown in the banner (e.g. `http://192.168.1.42:8080`).
2. On any device on the same Wi-Fi, open that URL in a browser.
3. You should see:
   - The live camera feed from the iPhone/iPad as background.
   - Timer stats (first shot, best split, total time, shots list).
   - Status indicator turning green when a BLE device is connected.

### C – Camera stream directly

Open `http://<device-ip>:8080/camera` in a browser tab.
You should see the live MJPEG feed from the device.

### D – Sessions

After a session completes, the admin panel **Past Sessions** list updates.
Tap any session to expand shot details.  
Click **⬇ Download CSV** to save the raw timing data.

### E – Multiple simultaneous clients

Open the display URL in several browser tabs / devices at once.
All clients receive the same WebSocket events and share the same camera feed.

---

## Project structure

```
ios/
├── project.yml               XcodeGen specification
├── SGTimerBLE/
│   ├── SGTimerBLEApp.swift   App entry point
│   ├── ContentView.swift     Native UI (banner + WKWebView admin)
│   ├── AppServer.swift       HTTP/WebSocket server, event coordinator
│   ├── BLEManager.swift      CoreBluetooth scanner/connector
│   ├── CameraStreamer.swift  AVFoundation → MJPEG frame provider
│   ├── SessionsStore.swift   CSV session storage (~/Documents/data/)
│   ├── TimerState.swift      In-memory session state model
│   ├── NetworkUtils.swift    Local IP address helper
│   └── Resources/
│       └── Info.plist        Permissions & app metadata
└── static/                   Web UI (bundled into the app)
    ├── index.html            Display page – camera background added
    ├── admin.html
    ├── css/
    ├── js/
    └── img/
```

---

## Notes

- **BLE addressing**: iOS CoreBluetooth uses per-device UUIDs rather than
  MAC addresses (Apple privacy policy). The admin UI shows UUID strings
  instead of `AA:BB:CC:…` – behaviour is otherwise identical.

- **Session storage**: CSV files are written to the app's
  `~/Documents/data/` folder. They survive app restarts.
  "Clear Sessions" archives them to `~/Documents/data/archive/`.

- **Port**: The server runs on port **8080** (same default as the Python
  server). To change it, edit `startServer(port:)` in `AppServer.swift`.

- **Camera orientation**: the MJPEG stream uses the back camera in
  landscape. If the device is held in portrait the image rotates with it.
