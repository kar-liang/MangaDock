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
        Group {
            if store.isConfigured {
                HomeView()
            } else {
                NavigationStack {
                    ServerSettingsView(initialSetup: true)
                }
            }
        }
    }
}
