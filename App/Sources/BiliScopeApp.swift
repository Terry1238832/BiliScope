import SwiftUI

@main
struct BiliScopeApp: App {
    @StateObject private var controller = ProxyController()
    @StateObject private var vpn = VPNController()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(controller)
                .environmentObject(vpn)
        }
    }
}
