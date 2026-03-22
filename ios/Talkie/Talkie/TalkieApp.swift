import SwiftUI

@main
struct TalkieApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            WebAppView()
                .ignoresSafeArea(.all)
                .statusBarHidden(false)
                .sheet(isPresented: $appState.showSettings, onDismiss: {
                    SettingsViewModel.shared.onDismiss?()
                }) {
                    SettingsView()
                }
        }
    }
}
