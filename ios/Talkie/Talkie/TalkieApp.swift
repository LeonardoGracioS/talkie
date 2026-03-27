import SwiftUI

@main
struct TalkieApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            WebAppView()
                .ignoresSafeArea(.all)
                .statusBarHidden(false)
                .preferredColorScheme(appState.colorScheme)
                .onAppear { AppState.applyAppearance(appState.appearanceMode) }
                .sheet(isPresented: $appState.showSettings, onDismiss: {
                    SettingsViewModel.shared.onDismiss?()
                }) {
                    SettingsView()
                        .preferredColorScheme(appState.colorScheme)
                }
        }
    }
}
