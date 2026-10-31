import SwiftUI

@main
struct BiliScopeApp: App {
    @StateObject private var controller = ProxyController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(controller)
                .preferredColorScheme(.dark)
        }
    }
}
