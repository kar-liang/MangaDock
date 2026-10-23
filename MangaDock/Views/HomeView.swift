import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore

    @State private var items: [WebDAVItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if !store.recent.isEmpty {
                    Section("继续阅读") {
                        ForEach(Array(store.recent.prefix(5))) { entry in
                            if let item = entry.item {
                                NavigationLink(value: NavTarget.comic(item)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "book.fill")
                                            .foregroundColor(.orange)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.name).lineLimit(1)
                                            Text(entry.progressText)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.uturn.forward")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let snapshot = Array(store.recent.prefix(5))
                            for offset in offsets where offset < snapshot.count {
                                store.removeRecent(snapshot[offset])
                            }
                        }
                    }
                }

                Section {
                    if isLoading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在读取目录…").foregroundColor(.secondary)
                        }
                    } else if let errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await load() }
                        }
                    } else if items.isEmpty {
                        Text("这个目录是空的")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                } header: {
                    Text(store.baseTitle)
                } footer: {
                    if !isLoading && errorMessage == nil {
                        Text(store.serverURL)
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("漫画坞")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .navigationDestination(for: NavTarget.self) { target in
                switch target {
                case .folder(let item):
                    BrowserView(folder: item)
                case .comic(let item):
                    ReaderView(item: item)
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    ServerSettingsView(initialSetup: false)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: WebDAVItem) -> some View {
        if let target = ItemTile.target(for: item) {
            NavigationLink(value: target) {
                ItemRow(item: item)
            }
        } else {
            ItemRow(item: item)
                .opacity(0.55)
        }
    }

    private func load() async {
        guard let client = store.makeClient() else { return }
        isLoading = true
        errorMessage = nil
        do {
            let list = try await client.list(store.baseURL ?? clientBaseFallback())
            items = list
            isLoading = false
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }

    private func clientBaseFallback() -> URL {
        URL(string: "http://127.0.0.1")!
    }
}
