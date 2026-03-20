import SwiftUI

@main
struct EchoApp: App {
    var body: some Scene {
        WindowGroup {
            WebAppView()
                .ignoresSafeArea(.all)
                .preferredColorScheme(.light)
                .statusBarHidden(false)
        }
    }
}
