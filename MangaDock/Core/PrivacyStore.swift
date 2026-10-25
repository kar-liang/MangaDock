import Foundation
import LocalAuthentication

/// Hidden comics + FaceID/passcode gate.
///
/// This is UI-level hiding + locking, NOT real encryption — the files stay in
/// the app sandbox. It stops someone who picks up the phone from browsing the
/// hidden shelf; it does not stop someone with the device + technical access.
final class PrivacyStore: ObservableObject {
    static let shared = PrivacyStore()

    @Published private(set) var entries: [ShelfEntry] = []

    private let key = "mangadock.privateShelf"
    private let defaults = UserDefaults.standard

    private init() { load() }

    var items: [WebDAVItem] { entries.compactMap { $0.item } }
    var count: Int { entries.count }

    func contains(_ item: WebDAVItem) -> Bool {
        entries.contains { $0.urlString == item.url.absoluteString }
    }

    /// Moves an item into the private space and off the visible shelf.
    func hide(_ item: WebDAVItem) {
        guard !contains(item) else { return }
        let entry = ShelfEntry(urlString: item.url.absoluteString,
                               name: item.name,
                               isDirectory: item.isDirectory,
                               size: item.size,
                               addedAt: Date())
        entries.insert(entry, at: 0)
        save()
        ShelfStore.shared.remove(item)
    }

    /// Puts a hidden item back on the visible shelf.
    func restore(_ entry: ShelfEntry) {
        entries.removeAll { $0.urlString == entry.urlString }
        save()
        if let item = entry.item {
            ShelfStore.shared.add(item)
        }
    }

    func remove(_ entry: ShelfEntry) {
        entries.removeAll { $0.urlString == entry.urlString }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([ShelfEntry].self, from: data) else { return }
        entries = list
    }

    // MARK: - FaceID / passcode

    @MainActor
    static func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return (try? await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "解锁隐私空间")) ?? false
        }

        // No biometrics enrolled — fall back to the device passcode.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "解锁隐私空间")) ?? false
    }
}
