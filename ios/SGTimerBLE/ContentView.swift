import SwiftUI
import WebKit

// MARK: - WKWebView wrapper

struct AdminWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.isOpaque = true
        wv.backgroundColor = UIColor(white: 0.08, alpha: 1)
        wv.scrollView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject var server: AppServer
    @State private var adminURL: URL? = nil

    var body: some View {
        ZStack(alignment: .top) {
            Color(white: 0.08).ignoresSafeArea()

            VStack(spacing: 0) {
                banner
                    .zIndex(1)

                if let url = adminURL {
                    AdminWebView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    Spacer()
                    VStack(spacing: 16) {
                        ProgressView()
                            .tint(.white)
                        Text(server.isRunning ? "Loading admin…" : "Starting server…")
                            .foregroundColor(.gray)
                            .font(.subheadline)
                    }
                    Spacer()
                }
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
