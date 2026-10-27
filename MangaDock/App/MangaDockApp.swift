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
    /// 多地址探测是否完成（单地址几乎无感，多地址会短暂探测）。
    @State private var probed = false

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
                if probed {
                    RootTabView()
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NavigationStack {
                    ServerSettingsView(initialSetup: true)
                }
            }
        }
        .preferredColorScheme(scheme)
        .tint(AppTheme(rawValue: themeRaw)?.tint)
        .task {
            await store.probeServers()
            probed = true
            await store.pullSync()
        }
    }
}
