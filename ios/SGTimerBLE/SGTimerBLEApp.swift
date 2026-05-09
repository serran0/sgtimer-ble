import SwiftUI

@main
struct SGTimerBLEApp: App {
    @StateObject private var server = AppServer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
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
