import SwiftUI

struct SplashView: View {
    @EnvironmentObject var server: AppServer
    @Binding var isPresented: Bool

    private let phrases = ["Load and Make Ready", "Are you Ready?", "Standby"]
    @State private var phraseIndex = 0
    @State private var phraseOpacity: Double = 0

    private let orangeGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.655, blue: 0.2),   // #FFA733
            Color(red: 1.0, green: 0.361, blue: 0.0)    // #FF5C00
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Text("SG TIMER SERVER")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(3)
                    .foregroundStyle(orangeGradient)

                Text(phrases[phraseIndex])
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(orangeGradient)
                    .opacity(phraseOpacity)

                Spacer()

                Text("by Timur")
                    .font(.system(size: 12, weight: .light))
                    .foregroundColor(Color(white: 0.5))
                    .padding(.bottom, 48)
            }
        }
        .task { await cyclePhrases() }
    }

    private func cyclePhrases() async {
        var cyclesDone = 0
        while !Task.isCancelled {
            withAnimation(.easeIn(duration: 0.15))  { phraseOpacity = 1 }
            try? await Task.sleep(nanoseconds: 850_000_000)
            withAnimation(.easeOut(duration: 0.15)) { phraseOpacity = 0 }
            try? await Task.sleep(nanoseconds: 200_000_000)

            phraseIndex = (phraseIndex + 1) % phrases.count
            if phraseIndex == 0 { cyclesDone += 1 }

            if cyclesDone >= 1 && server.isRunning {
                isPresented = false
                return
            }
        }
    }
}
