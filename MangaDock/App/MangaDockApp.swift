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
    @ObservedObject private var coverStore = CoverStore.shared
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
                    LaunchSplashView()
                }
            } else {
                NavigationStack {
                    ServerSettingsView(initialSetup: true)
                }
            }
        }
        // 封面加载中：加载圈 overlay 挂在书架上，封面加载完才消失。
        // 否则探测+同步结束加载圈就没了，封面还是灰块，中间无反馈。
        .overlay {
            if store.isConfigured && probed && coverStore.pendingLoads > 0 {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.25))
            }
        }
        .preferredColorScheme(scheme)
        .tint(AppTheme(rawValue: themeRaw)?.tint)
        .task {
            await store.probeServers()
            // 只等探测，不等同步 —— 同步走网络，外网慢的时候会把启动页
            // 拖成几秒的黑屏。书架本身有本地缓存，先用旧的完全没问题。
            probed = true
            await store.pullSync()
        }
    }
}
