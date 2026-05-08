import SwiftUI

@main
struct SGTimerBLEApp: App {
    @StateObject private var server = AppServer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(server)
        }
    }
}
