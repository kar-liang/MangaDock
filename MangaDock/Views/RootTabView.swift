import SwiftUI

/// Bottom tab bar: 书架 / 记录 / 设置.
/// On iOS 26 the system renders the tab bar (and every toolbar) in Liquid Glass
/// automatically — no custom chrome needed for the bar itself.
struct RootTabView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        TabView {
            Tab("书架", systemImage: "books.vertical.fill") {
                HomeView()
            }
            Tab("记录", systemImage: "clock.fill") {
                HistoryView()
            }
            Tab("设置", systemImage: "gearshape.fill") {
                NavigationStack {
                    ServerSettingsView(initialSetup: false)
                }
            }
        }
    }
}

/// Liquid Glass on iOS 26, frosted material before that.
extension View {
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = 20) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular,
                             in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}
