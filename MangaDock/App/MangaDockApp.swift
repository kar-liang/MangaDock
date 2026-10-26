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
    @AppStorage("mangadock.appearance") private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage("mangadock.theme") private var themeRaw = AppTheme.system.rawValue

    private var scheme: ColorScheme? {
        switch AppearanceMode(rawValue: appearanceRaw) ?? .system {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var body: some View {
        Group {
            if store.isConfigured {
                RootTabView()
            } else {
                NavigationStack {
                    ServerSettingsView(initialSetup: true)
                }
            }
        }
        .preferredColorScheme(scheme)
        .tint(AppTheme(rawValue: themeRaw)?.tint)
        .task {
            await store.pullSync()
        }
    }
}
