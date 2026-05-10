import SwiftUI

struct SplashView: View {
    private let phrases = ["Load and Make Ready", "Are you Ready?", "Standby"]
    @State private var phraseIndex = 0
    @State private var phraseOpacity: Double = 0

    var body: some View {
        ZStack {
            Color(white: 0.88)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                // Embossed title: dark gray text with light highlight above-left
                // and dark shadow below-right gives a raised / stamped look
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

    // Each phrase: 0.15s fade-in, ~0.7s hold, 0.15s fade-out ≈ 1s visible
    private func cyclePhrases() async {
        while !Task.isCancelled {
            withAnimation(.easeIn(duration: 0.15)) { phraseOpacity = 1 }
            try? await Task.sleep(nanoseconds: 850_000_000)
            withAnimation(.easeOut(duration: 0.15)) { phraseOpacity = 0 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            phraseIndex = (phraseIndex + 1) % phrases.count
        }
    }
}
