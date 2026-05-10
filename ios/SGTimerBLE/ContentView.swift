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
                timerDeviceSection
                streamTitleSection
                cameraStreamSection
                saveRestartSection
            }
            .navigationTitle("SG Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
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

            Picker("Frame Rate", selection: Binding(
                get: { Int(server.cameraFPS) },
                set: { server.updateFPS($0) }
            )) {
                Text("15 fps").tag(15)
                Text("30 fps").tag(30)
            }

            Stepper(
                "A/V Sync: \(server.avSyncDelayMs) ms",
                value: Binding(
                    get: { server.avSyncDelayMs },
                    set: { server.updateSyncDelay($0) }
                ),
                in: 0...2000,
                step: 10
            )
        }
    }

    private var saveRestartSection: some View {
        Section {
            Button(role: .destructive) {
                server.saveAndRestart()
            } label: {
                HStack {
                    Spacer()
                    Text("Save & Restart Server")
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

            // Lens selector (bottom)
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
                .padding(.bottom, 32)
            }
        }
    }
}
