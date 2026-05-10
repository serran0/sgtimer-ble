import SwiftUI

@main
struct SGTimerBLEApp: App {
    @StateObject private var server = AppServer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(server)
                if !server.isRunning {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.4), value: server.isRunning)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                server.handleForeground()
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
            default:
                break
            }
        }
    }
}
