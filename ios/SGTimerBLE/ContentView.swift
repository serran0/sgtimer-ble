import SwiftUI
import WebKit

// MARK: - WKWebView wrapper

struct AppWebView: UIViewRepresentable {
    let url: URL
    var opaque: Bool = true

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = opaque
        wv.backgroundColor = opaque ? UIColor(white: 0.08, alpha: 1) : .clear
        wv.scrollView.backgroundColor = opaque ? UIColor(white: 0.08, alpha: 1) : .clear
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject var server: AppServer
    @State private var showPreview = false
    @State private var titleDraft: String = ""

    var body: some View {
        NavigationStack {
            Form {
                serverInfoSection
                timerDeviceSection
                streamTitleSection
                cameraStreamSection
                saveSettingsSection
            }
            .navigationTitle("SG Timer Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if server.isRunning {
                        Button {
                            showPreview = true
                        } label: {
                            Label("Preview", systemImage: "play.rectangle")
                        }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showPreview) {
            previewOverlay
        }
        .onAppear {
            server.startServer()
            titleDraft = server.titleText
        }
        .onChange(of: server.titleText) { newTitle in
            titleDraft = newTitle
        }
    }

    // MARK: - Form sections

    private var serverInfoSection: some View {
        Section {
            HStack {
                Image(systemName: "wifi")
                    .foregroundStyle(.secondary)
                Spacer()
                if server.isRunning {
                    Text("http://\(server.localIP):8080")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                } else {
                    Text("Starting…")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var timerDeviceSection: some View {
        Section("Timer Device") {
            if server.isScanning {
                HStack {
                    ProgressView()
                    Text("Scanning…").foregroundStyle(.secondary)
                }
            } else if let name = server.connectedDeviceName {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).fontWeight(.medium)
                        if let addr = server.connectedDeviceAddress {
                            Text(addr).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Disconnect", role: .destructive) {
                        server.disconnectDevice()
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                if !server.scannedDevices.isEmpty {
                    ForEach(server.scannedDevices, id: \.address) { device in
                        Button {
                            server.connectDevice(device)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).foregroundStyle(.primary)
                                Text(device.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                }
                Button("Scan for Devices") {
                    server.scan()
                }
            }

            // 2-line event console
            if !server.consoleLines.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(server.consoleLines.suffix(2), id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
        }
    }

    private var streamTitleSection: some View {
        Section("Stream Title") {
            HStack {
                TextField("Title", text: $titleDraft)
                    .submitLabel(.done)
                    .onSubmit { applyTitle() }
                Button("Set") { applyTitle() }
                    .buttonStyle(.borderless)
                    .disabled(titleDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var cameraStreamSection: some View {
        Section("Camera & Stream") {
            if server.availableLenses.count > 1 {
                Picker("Lens", selection: Binding(
                    get: { server.currentLensId },
                    set: { server.setLens(id: $0) }
                )) {
                    ForEach(server.availableLenses) { lens in
                        Text(lens.label).tag(lens.id)
                    }
                }
            }

            Picker("Stream Resolution", selection: Binding(
                get: { server.streamResolution },
                set: { server.updateStreamResolution($0) }
            )) {
                Text("720p").tag("720p")
                Text("1080p").tag("1080p")
                Text("1440p").tag("1440p")
                Text("4K").tag("4k")
            }

            Picker("Recording Quality", selection: Binding(
                get: { server.videoQuality },
                set: { server.updateVideoQuality($0) }
            )) {
                Text("Low").tag("low")
                Text("Normal").tag("normal")
                Text("High").tag("high")
            }

            Picker("Frame Rate", selection: Binding(
                get: { Int(server.cameraFPS) },
                set: { server.updateFPS($0) }
            )) {
                Text("15 fps").tag(15)
                Text("30 fps").tag(30)
            }

            Stepper(
                "Audio Buffer: \(server.avSyncDelayMs) ms",
                value: Binding(
                    get: { server.avSyncDelayMs },
                    set: { server.updateSyncDelay($0) }
                ),
                in: 0...1000,
                step: 10
            )

            Stepper(
                "A/V Delay: \(server.avDelayMs) ms",
                value: Binding(
                    get: { server.avDelayMs },
                    set: { server.updateAvDelay($0) }
                ),
                in: 0...2000,
                step: 10
            )

            Stepper(
                "Overlay Delay: \(server.overlayDelayMs) ms",
                value: Binding(
                    get: { server.overlayDelayMs },
                    set: { server.updateOverlayDelay($0) }
                ),
                in: 0...2000,
                step: 10
            )
        }
    }

    private var saveSettingsSection: some View {
        Section(footer: Group {
            VStack(alignment: .leading, spacing: 4) {
                if server.isRunning {
                    Text("Admin: http://\(server.localIP):8080/admin.html")
                        .font(.caption)
                }
                Text("SG Timer Server v0.70")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }) {
            Button {
                server.saveSettingsAndReload()
            } label: {
                HStack {
                    Spacer()
                    Text("Save Settings")
                    Spacer()
                }
            }
        }
    }

    // MARK: - Helpers

    private func applyTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        server.setTitle(trimmed)
    }

    // MARK: - Preview overlay

    private var previewOverlay: some View {
        ZStack(alignment: .bottom) {
            AppWebView(url: URL(string: "http://127.0.0.1:8080/?preview=1")!, opaque: true)
                .ignoresSafeArea()

            // Close button (top-right)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        showPreview = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.black.opacity(0.6))
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.top, 56)
                    .padding(.trailing, 16)
                }
                Spacer()
            }

            // Bottom controls: lens selector + record button
            VStack(spacing: 10) {
                if server.availableLenses.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(server.availableLenses) { lens in
                            Button(lens.label) {
                                server.setLens(id: lens.id)
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(server.currentLensId == lens.id ? .black : .white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(server.currentLensId == lens.id
                                        ? Color.white
                                        : Color.black.opacity(0.5))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1))
                        }
                    }
                }

                Button {
                    if server.isRecording { server.stopRecording() }
                    else { server.startRecording() }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(server.isRecording ? Color.red : Color.white)
                            .frame(width: 10, height: 10)
                        Text(server.isRecording ? "Stop" : "Record")
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(server.isRecording ? .white : .black)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(server.isRecording ? Color.red.opacity(0.7) : Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.4), lineWidth: 1))
            }
            .padding(.bottom, 32)
        }
    }
}
