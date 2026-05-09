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
    @State private var adminURL: URL? = nil
    @State private var showPreview = false
    @State private var fps: Int = 30

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.08).ignoresSafeArea()

            // ── Normal layout ──────────────────────────────────
            VStack(spacing: 0) {
                banner.zIndex(1)

                if let url = adminURL {
                    AppWebView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView().tint(.white)
                        Text(server.isRunning ? "Loading admin…" : "Starting server…")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                    }
                    Spacer()
                }
            }

            // ── Preview overlay ────────────────────────────────
            if showPreview {
                previewOverlay
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                    .zIndex(99)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { server.startServer() }
        .onChange(of: server.isRunning) { running in
            if running, adminURL == nil {
                adminURL = URL(string: "http://127.0.0.1:8080/admin.html")
            }
        }
    }

    // MARK: - Preview overlay

    private var previewOverlay: some View {
        ZStack(alignment: .topTrailing) {
            // The exact same page remote clients see — camera bg + timer overlay
            AppWebView(url: URL(string: "http://127.0.0.1:8080/")!, opaque: true)
                .ignoresSafeArea()

            // Close button
            Button {
                withAnimation { showPreview = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.6))
                    .clipShape(Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
            }
            .padding(.top, 56)   // clear status bar
            .padding(.trailing, 16)
        }
    }

    // MARK: - Banner

    private var banner: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SGTimer BLE Server")
                    .font(.headline)
                    .foregroundColor(.white)
                if server.isRunning {
                    Text("http://\(server.localIP):8080")
                        .font(.caption.monospaced())
                        .foregroundColor(.green)
                } else {
                    Text("Starting…")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            if server.isRunning {
                // FPS picker
                Picker("FPS", selection: $fps) {
                    Text("15 fps").tag(15)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 110)
                .onChange(of: fps) { newFPS in
                    server.cameraFPS = Double(newFPS)
                }

                // Preview button
                Button {
                    withAnimation { showPreview = true }
                } label: {
                    Label("Preview", systemImage: "play.rectangle")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.75))
                        .clipShape(Capsule())
                }
            }

            // Status dot
            Circle()
                .fill(server.isRunning ? Color.green : Color.orange)
                .frame(width: 10, height: 10)
                .shadow(color: server.isRunning ? .green : .orange, radius: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.12))
        .overlay(
            Rectangle()
                .frame(height: 0.5)
                .foregroundColor(Color.white.opacity(0.15)),
            alignment: .bottom
        )
    }
}
