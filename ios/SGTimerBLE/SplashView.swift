import SwiftUI

struct SplashView: View {
    @EnvironmentObject var server: AppServer
    @Binding var isPresented: Bool

    private let phrases = ["Load and Make Ready", "Are you Ready?", "Standby"]
    @State private var phraseIndex = 0
    @State private var phraseOpacity: Double = 0

    var body: some View {
        ZStack {
            Color(white: 0.88)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Text("SG TIMER SERVER")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(3)
                    .foregroundColor(Color(white: 0.28))
                    .shadow(color: .white.opacity(0.9), radius: 0, x: -1, y: -1)
                    .shadow(color: .black.opacity(0.22), radius: 1, x: 1, y: 1)

                Text(phrases[phraseIndex])
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color(white: 0.42))
                    .opacity(phraseOpacity)

                Spacer()

                Text("by Timur")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(Color(white: 0.52))
                    .padding(.bottom, 48)
            }
        }
        .task { await cyclePhrases() }
    }

    // Cycles through all phrases (≈1 s each). Dismisses only after at least
    // one full cycle AND the server is ready — whichever comes last.
    private func cyclePhrases() async {
        var cyclesDone = 0
        while !Task.isCancelled {
            withAnimation(.easeIn(duration: 0.15))  { phraseOpacity = 1 }
            try? await Task.sleep(nanoseconds: 850_000_000)   // hold ~0.85 s
            withAnimation(.easeOut(duration: 0.15)) { phraseOpacity = 0 }
            try? await Task.sleep(nanoseconds: 200_000_000)   // gap before next

            phraseIndex = (phraseIndex + 1) % phrases.count
            if phraseIndex == 0 { cyclesDone += 1 }

            if cyclesDone >= 1 && server.isRunning {
                isPresented = false
                return
            }
        }
    }
}
