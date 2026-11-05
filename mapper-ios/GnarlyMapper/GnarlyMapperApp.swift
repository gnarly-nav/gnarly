import SwiftUI

@main
struct GnarlyMapperApp: App {
    @StateObject private var authSession = CognitoSession.shared

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(authSession)
        }
    }
}
