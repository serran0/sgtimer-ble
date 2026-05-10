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
                adminURL = URL(string: "http://127.0.0.1:8080/admin.html?inapp=1")
            }
        }
    }

    // MARK: - Preview overlay

    private var previewOverlay: some View {
        ZStack(alignment: .bottom) {
            // The exact same page remote clients see — camera bg + timer overlay
            AppWebView(url: URL(string: "http://127.0.0.1:8080/?preview=1")!, opaque: true)
                .ignoresSafeArea()

            // Close button (top-right)
            VStack {
                HStack {
                    Spacer()
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

    // MARK: - Banner

    private var banner: some View {
        HStack(spacing: 12) {
            // IP address on the left
            if server.isRunning {
                Text("http://\(server.localIP):8080")
                    .font(.caption.monospaced())
                    .foregroundColor(.green)
            } else {
                Text("Starting…")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Spacer()

            // Preview button on the right
            if server.isRunning {
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
