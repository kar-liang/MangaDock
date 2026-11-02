import SwiftUI
import UIKit

@main
struct MangaDockApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { _, phase in
            // 进后台就算这一轮正常收尾。崩溃 / 被系统回收时走不到这里，
            // 标记会留到下次启动，用来判断「上次是不是异常退出」。
            if phase == .background {
                DiagLog.markSessionClean()
            }
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            diag("mem", "收到内存警告 · mem=\(DiagLog.memoryFootprint())")
        }
        .task {
            DiagLog.markSessionStart()
            await store.probeServers()
            // 只等探测，不等同步 —— 同步走网络，外网慢的时候会把启动页
            // 拖成几秒的黑屏。书架本身有本地缓存，先用旧的完全没问题。
            probed = true
            await store.pullSync()
        }
    }
}
