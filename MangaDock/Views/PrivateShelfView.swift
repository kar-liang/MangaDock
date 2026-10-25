import SwiftUI

/// FaceID/passcode-gated list of hidden comics.
struct PrivateShelfView: View {
    @ObservedObject private var privacy = PrivacyStore.shared

    @State private var failed = false

    var body: some View {
        Group {
            if privacy.unlocked {
                ScrollView {
                    if privacy.entries.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "lock.open")
                                .font(.system(size: 40, weight: .light))
                                .foregroundColor(.secondary)
                            Text("隐私空间是空的。\n长按书架上的漫画选「隐藏进隐私空间」放进来。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        LazyVGrid(columns: LibraryGrid.columns, spacing: 16) {
                            ForEach(privacy.entries) { entry in
                                if let item = entry.item, let target = readerTarget(for: item) {
                                    NavigationLink(value: target) {
                                        CoverTile(item: item)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button("恢复到书架") { privacy.restore(entry) }
                                        Button("删除", role: .destructive) { privacy.remove(entry) }
                                    }
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                .navigationTitle("隐私空间")
                // No .libraryNavigation() here: the parent already registered the
                // NavTarget destinations; a duplicate registration broke pushes.
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundColor(.secondary)
                    Text(failed ? "验证失败，点下面重试" : "需要验证身份才能查看")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button("解锁") {
                        Task { await authenticate() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task {
            // `.task` re-runs every time this view re-appears (e.g. popping back
            // from the reader). The unlock flag lives on the singleton, so once
            // authenticated this session stays unlocked.
            guard !privacy.unlocked else { return }
            await authenticate()
        }
    }

    /// Same rule as the shelf: a folder opens its chapter list, a single file
    /// goes straight to the reader.
    private func readerTarget(for item: WebDAVItem) -> NavTarget? {
        if item.isDirectory { return .series(item) }
        if item.isArchive || item.isPDF { return .comic(item) }
        return nil
    }

    private func authenticate() async {
        if await PrivacyStore.authenticate() {
            // PrivacyStore.authenticate() sets the singleton's unlocked flag;
            // the @ObservedObject update re-renders this view automatically.
        } else {
            failed = true
        }
    }
}
