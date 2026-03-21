import SwiftUI

@main
struct TalkieApp: App {
    var body: some Scene {
        WindowGroup {
            WebAppView()
                .ignoresSafeArea(.all)
                .preferredColorScheme(.light)
                .statusBarHidden(false)
        }
    }
}
