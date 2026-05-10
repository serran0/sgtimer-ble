import SwiftUI

@main
struct SGTimerBLEApp: App {
    @StateObject private var server = AppServer()
    @Environment(\.scenePhase) private var scenePhase

    // Tracks whether the app has ever gone to the background in this process
    // lifetime. False = cold start; True = warm return from background.
    @State private var hasEnteredBackground = false
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(server)
                if showSplash {
                    SplashView(isPresented: $showSplash)
                        .environmentObject(server)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(.easeOut(duration: 0.4), value: showSplash)
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                UIApplication.shared.isIdleTimerDisabled = true
                server.handleForeground(isColdStart: !hasEnteredBackground)
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                hasEnteredBackground = true
            default:
                break
            }
        }
    }
}
