import SwiftUI

/// 品牌启动页：应用图标 + 名称。
/// 在启动探测 / 同步期间替代裸 `ProgressView`，避免纯白转圈。
/// 背景用 systemBackground 自动适配深浅色。
struct LaunchSplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image("SplashLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 8)

            Text("漫画坞")
                .font(.title.weight(.bold))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    LaunchSplashView()
}
