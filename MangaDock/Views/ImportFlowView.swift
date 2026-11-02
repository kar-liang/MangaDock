import SwiftUI

/// 底栏 ➕ 打开的导入向导。
///
/// 两步：先选服务器类型，再填地址账号。两套配置分开存 ——
/// 配了 Komga 不会把 WebDAV 的地址冲掉，反之也一样。
struct ImportFlowView: View {
    /// 保存成功时回调（让外层跳到「文件」页，立刻看到库）
    var onSaved: () -> Void = {}

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private enum Step: Hashable {
        case chooser
        case form(ServerKind)
    }

    @State private var step: Step = .chooser

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .chooser:
                    chooser
                case .form(let kind):
                    ServerFormView(kind: kind) {
                        onSaved()
                        dismiss()
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if case .form = step {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            step = .chooser
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .presentationDetents(step == .chooser ? [.medium] : [.large])
        .presentationDragIndicator(.visible)
    }

    private var navigationTitle: String {
        switch step {
        case .chooser: return "选择导入方式"
        case .form(let kind): return "添加 \(kind.title)"
        }
    }

    // MARK: - 选择类型

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("连接服务器后，将以独立分栏显示")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 10) {
                    Text("服务器")
                        .font(.subheadline.weight(.semibold))
                        .padding(.leading, 4)

                    HStack(spacing: 12) {
                        ForEach(ServerKind.allCases) { kind in
                            Button {
                                step = .form(kind)
                            } label: {
                                kindCard(kind)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text("每个类型单独保存一套地址和账号，互不覆盖。配好之后可以在「设置 → 服务器」里随时切换当前使用的那一套。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func kindCard(_ kind: ServerKind) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 54, height: 54)
                Image(systemName: kind.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Text(kind.title)
                .font(.footnote.weight(.medium))
            Text(store.hasProfile(kind) ? "已配置" : kind.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - 表单

/// 填地址 / 账号 / 密码，测通再存。
/// WebDAV 和 Komga 字段完全一样，只差占位符和提示文案。
struct ServerFormView: View {
    let kind: ServerKind
    var onSaved: () -> Void = {}

    @EnvironmentObject private var store: AppStore

    @State private var displayName = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var testing = false
    @State private var message: String?
    @State private var isError = false
    @State private var loaded = false

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            if kind == .webdav {
                Section {
                    Label {
                        Text("连接局域网服务器时，请在系统设置里给本 App 打开「本地网络」权限，否则会一直连不上。")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                TextField("例如：家里 NAS", text: $displayName)
            } header: {
                Text("显示名称（选填）")
            }

            Section {
                TextField(addressPlaceholder, text: $address,
                          axis: kind == .webdav ? .vertical : .horizontal)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .lineLimit(kind == .webdav ? 2...4 : 1...1)
            } header: {
                Text("服务器地址")
            } footer: {
                Text(addressHint)
            }

            Section {
                TextField("用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            } header: {
                Text("身份认证（选填）")
            }

            Section {
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        Spacer()
                        Text(testing ? "正在连接…" : "连接并保存")
                            .fontWeight(.semibold)
                        if testing {
                            ProgressView().padding(.leading, 4)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(canSubmit ? Color.accentColor : Color(.systemGray3),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                .listRowBackground(Color.clear)

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(isError ? .red : .green)
                }
            }
        }
        .onAppear(perform: loadExisting)
    }

    private var canSubmit: Bool { !testing && !trimmedAddress.isEmpty }

    private var addressPlaceholder: String {
        switch kind {
        case .webdav: return "http(s)://example.com:5005/dav/Comics"
        case .komga: return "https://komga.example.com"
        }
    }

    private var addressHint: String {
        switch kind {
        case .webdav:
            return "要写到漫画所在的目录。每行一个地址，启动时自动用能连上的那个（局域网 IP + 公网域名都填）。"
        case .komga:
            return "填 Komga 首页地址，不要带 /api 之类的路径。"
        }
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        let profile = store.savedProfile(kind)
        displayName = profile.displayName
        address = profile.urls
        username = profile.username
        if store.serverKind == kind {
            password = store.password
        } else {
            password = Keychain.load(account: kind.rawValue) ?? ""
        }
    }

    private func connect() async {
        let lines = address
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            message = "先把服务器地址填上"
            isError = true
            return
        }

        testing = true
        message = nil

        let outcome = await ServerProbe.test(kind: kind,
                                             address: address,
                                             username: username,
                                             password: password)
        testing = false
        message = outcome.summary
        isError = !outcome.isOK

        guard outcome.isOK else { return }

        // 只存连得上的地址，免得以后每次启动都白等一轮超时
        store.activate(kind: kind,
                       displayName: displayName,
                       serverURL: outcome.reachable.joined(separator: "\n"),
                       username: username,
                       password: password)
        onSaved()
    }
}
