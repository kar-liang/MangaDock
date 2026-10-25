import SwiftUI

/// FaceID/passcode-gated grid of hidden comics.
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
                                if let item = entry.item {
                                    tile(entry: entry, item: item)
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

    /// One cover cell.
    ///
    /// The restore/delete actions are reachable two ways on purpose:
    ///  * a visible "···" button in the corner — discoverable, works even when
    ///    the long press gesture is competing with the NavigationLink;
    ///  * the long-press menu below the cover, via `CoverBox.extraMenu`. That
    ///    must go THROUGH CoverBox (one merged menu) — attaching an outer
    ///    `.contextMenu` around the tile is silently dropped because SwiftUI
    ///    keeps only one context menu per view hierarchy branch.
    private func tile(entry: ShelfEntry, item: WebDAVItem) -> some View {
        let extra = [
            CoverMenuItem(title: "恢复到书架",
                          systemImage: "arrow.uturn.backward") {
                privacy.restore(entry)
            },
            CoverMenuItem(title: "删除",
                          systemImage: "trash",
                          destructive: true) {
                privacy.remove(entry)
            }
        ]

        return Group {
            if let target = readerTarget(for: item) {
                NavigationLink(value: target) {
                    CoverTile(item: item, extraMenu: extra)
                }
                .buttonStyle(.plain)
            } else {
                // Unsupported type (e.g. a stray file): still show it so it can
                // be restored or deleted instead of being a silent dead end.
                CoverTile(item: item, extraMenu: extra)
            }
        }
        .overlay(alignment: .topTrailing) {
            actionButton(entry: entry)
        }
    }

    private func actionButton(entry: ShelfEntry) -> some View {
        Menu {
            Button {
                privacy.restore(entry)
            } label: {
                Label("恢复到书架", systemImage: "arrow.uturn.backward")
            }

            Button(role: .destructive) {
                privacy.remove(entry)
            } label: {
                Label("删除", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.45), in: Circle())
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5)
                )
        }
        .padding(6)
        .accessibilityLabel("更多操作")
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
