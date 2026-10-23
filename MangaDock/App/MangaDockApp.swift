import SwiftUI

@main
struct MangaDockApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.isConfigured {
            RootTabView()
        } else {
            NavigationStack {
                ServerSettingsView(initialSetup: true)
            }
        }
    }
}
