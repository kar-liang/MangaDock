import SwiftUI

/// 添加 / 编辑一台服务器。
///
/// 字段按老大给的参考图排：名称、备注 → 服务器地址（主机 / 路径 / 端口 / https）
/// → 登录信息（用户 / 密码）。
///
/// 和旧版的区别：以前是一个多行「地址」文本框，得自己把
/// `http://192.168.1.10:5005/dav/Comics` 拼完整。现在拆成主机 / 路径 / 端口
/// 三段，https 一个开关，拼装和解析都在这里做。
///
/// **备用地址没有删掉**：App 启动时会并行探测所有地址、挑能连上的那个
/// （家里局域网 + 外面公网两套 IP 的核心功能）。所以地址区末尾保留
/// 「添加备用地址」，默认收起，只有需要多条时才展开。
struct AddServerView: View {
    let kind: ServerKind
    /// 传了就是编辑这台，不传就是新增。
    var editing: AppStore.AccountRef? = nil
    /// 保存成功后回调，带上账号 id，外层可以直接跳进那个服务器。
    var onSaved: (String) -> Void = { _ in }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var note = ""
    @State private var host = ""
    @State private var path = ""
    @State private var port = ""
    @State private var useHTTPS = false
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var extraAddresses: [String] = []
    @State private var testing = false
    @State private var message: String?
    @State private var isError = false
    @State private var loaded = false

    private var isEditing: Bool { editing != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("名称") {
                        TextField("Name (可选)", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    row("备注") {
                        TextField("Note (可选)", text: $note)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    row("主机") {
                        TextField(kind == .komga ? "komga.example.com" : "192.168.1.10",
                                  text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    row("路径") {
                        TextField(kind == .komga ? "Path (可选)" : "/dav/Comics",
                                  text: $path)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                    row("端口") {
                        TextField("Port (可选)", text: $port)
                            .keyboardType(.numberPad)
                    }
                    Toggle("https", isOn: $useHTTPS)

                    ForEach(extraAddresses.indices, id: \.self) { index in
                        row("备用") {
                            TextField("http(s)://其它地址", text: Binding(
                                get: { extraAddresses[index] },
                                set: { extraAddresses[index] = $0 }
                            ))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        }
                    }
                    .onDelete { offsets in
                        extraAddresses.remove(atOffsets: offsets)
                    }

                    Button {
                        extraAddresses.append("")
                    } label: {
                        Label("添加备用地址", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                } header: {
                    Text("服务器地址")
                } footer: {
                    Text(addressFooter)
                }

                Section {
                    row("用户") {
                        TextField("Username (可选)", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    row("密码") {
                        HStack(spacing: 8) {
                            Group {
                                if showPassword {
                                    TextField("Password (可选)", text: $password)
                                } else {
                                    SecureField("Password (可选)", text: $password)
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
                        }
                    }
                } header: {
                    Text("登录信息")
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            Spacer()
                            Text(testing ? "正在连接…" : "连接并保存")
                                .fontWeight(.semibold)
                            if testing { ProgressView() }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(!canSubmit)

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑 \(kind.title)" : kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        Text("保存").fontWeight(.semibold)
                    }
                    .disabled(!canSubmit)
                }
            }
            .onAppear(perform: loadExisting)
            .interactiveDismissDisabled(testing)
        }
    }

    // MARK: - 行

    private func row<Content: View>(_ label: String,
                                    @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 52, alignment: .leading)
            content()
                .multilineTextAlignment(.leading)
        }
    }

    private var addressFooter: String {
        switch kind {
        case .webdav:
            return "要指到漫画所在的目录。多条地址会在启动时自动挑能连上的那条（家里 IP + 公网域名可以都填）。"
        case .komga:
            return "填 Komga 首页地址，不要带 /api。反向代理挂在子路径下时把子路径写进「路径」。"
        }
    }

    // MARK: - 地址拼装

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 「主机」里自己带了端口（192.168.1.10:5005）时以它为准，别和端口框拼两次。
    private var hostHasPort: Bool { trimmedHost.contains(":") }

    private var builtAddress: String {
        guard !trimmedHost.isEmpty else { return "" }
        var s = (useHTTPS ? "https://" : "http://") + trimmedHost
        let p = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.isEmpty && !hostHasPort { s += ":" + p }
        var pathTrimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pathTrimmed.isEmpty {
            if !pathTrimmed.hasPrefix("/") { pathTrimmed = "/" + pathTrimmed }
            s += pathTrimmed
        }
        return s
    }

    /// 主地址 + 备用地址，一行一个。
    private var allAddresses: String {
        var lines = [builtAddress]
        lines.append(contentsOf: extraAddresses
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var canSubmit: Bool { !testing && !builtAddress.isEmpty }

    // MARK: - 载入 / 保存

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        guard let editing else { return }
        let profile = editing.profile
        name = profile.displayName
        note = profile.note
        username = profile.username
        password = Keychain.load(account: profile.id) ?? ""

        let lines = profile.lines
        if let first = lines.first {
            let parts = Self.split(first)
            useHTTPS = parts.secure
            host = parts.host
            port = parts.port
            path = parts.path
        }
        extraAddresses = Array(lines.dropFirst())
    }

    /// 把一条完整地址拆成表单的四段。旧存档里可能是「IP:端口/路径」这种没 scheme 的写法。
    static func split(_ raw: String) -> (secure: Bool, host: String, port: String, path: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = text.contains("://") ? text : "http://" + text
        guard let comps = URLComponents(string: withScheme) else {
            return (false, text, "", "")
        }
        return (comps.scheme?.lowercased() == "https",
                comps.host ?? text,
                comps.port.map(String.init) ?? "",
                comps.path)
    }

    private func submit() async {
        let addresses = allAddresses
        guard !addresses.isEmpty else {
            message = "先把主机填上"
            isError = true
            return
        }
        testing = true
        message = nil

        let outcome = await ServerProbe.test(kind: kind,
                                             address: addresses,
                                             username: username,
                                             password: password)
        testing = false
        message = outcome.summary
        isError = !outcome.isOK
        guard outcome.isOK else { return }

        // 只存连得上的地址，免得以后每次启动都白等一轮超时
        let reachable = outcome.reachable.joined(separator: "\n")
        if let editing {
            store.updateAccount(id: editing.id,
                                kind: kind,
                                displayName: name,
                                note: note,
                                urls: reachable,
                                username: username,
                                password: password)
            onSaved(editing.id)
        } else {
            store.activate(kind: kind,
                           displayName: name,
                           note: note,
                           serverURL: reachable,
                           username: username,
                           password: password)
            if let newID = store.activeAccountID(kind) { onSaved(newID) }
        }
        dismiss()
    }
}
