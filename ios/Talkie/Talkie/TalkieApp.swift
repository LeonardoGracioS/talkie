import SwiftUI

@main
struct TalkieApp: App {
    @StateObject private var micState = MicState.shared

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                WebAppView()
                    .ignoresSafeArea(.all)

                // Native mic status indicator
                MicStatusBar(isListening: micState.isListening)
            }
            .preferredColorScheme(.light)
            .statusBarHidden(false)
        }
    }
}

struct MicStatusBar: View {
    let isListening: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isListening ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)
                .scaleEffect(isListening && pulse ? 1.3 : 1.0)
                .animation(
                    isListening
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: pulse
                )

            Text(isListening ? "Écoute active" : "Micro en pause")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isListening ? .primary : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        )
        .padding(.top, 52) // Below status bar + some spacing
        .onChange(of: isListening) { _ in
            pulse = isListening
        }
        .onAppear {
            pulse = isListening
        }
        .allowsHitTesting(false) // Don't block taps on the WebView below
    }
}
