import Foundation

/// Persists a one-time grant of access to NetEase Cloud Music's cache folder.
///
/// Files inside another app's sandbox container are protected by TCC
/// (`kTCCServiceSystemPolicyAppData`). The consent the system dialog hands out
/// is scoped to a single run — Apple documents it as valid "until it quits" —
/// and the matching switch in System Settings → Privacy & Security →
/// Files and Folders does not persist either, so a grant taken through the file
/// picker is stored here as a security-scoped bookmark and re-established on
/// every launch.
///
/// The picker route is the one Apple documents for "seamless access": the
/// panel runs out of process, and once the user confirms a folder the app may
/// read it without an additional consent dialog. Granting Full Disk Access
/// suppresses the app-data check entirely, which is why it stays as a fallback
/// for setups where the picker grant does not survive.
public final class NeteaseCacheAccess {
    public static let shared = NeteaseCacheAccess()

    public enum Key {
        public static let bookmark = "neteaseCacheBookmark"
        public static let path = "neteaseCachePath"
    }

    private let defaults: UserDefaults
    private var scopedURL: URL?
    private var didStartAccess = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - State

    /// Directory the user picked, resolved from the stored bookmark.
    public var grantedDirectory: URL? {
        if let data = defaults.data(forKey: Key.bookmark), let url = Self.resolve(data) {
            refreshIfStale(data)
            return url
        }
        if let path = defaults.string(forKey: Key.path), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return nil
    }

    public var isGranted: Bool { grantedDirectory != nil }
    public var grantedPath: String? { grantedDirectory?.path }

    /// True when `url` sits inside the granted directory.
    public func covers(_ url: URL) -> Bool {
        guard let granted = grantedDirectory?.standardizedFileURL.path else { return false }
        let candidate = url.standardizedFileURL.path
        return candidate == granted || candidate.hasPrefix(granted.hasSuffix("/") ? granted : granted + "/")
    }

    // MARK: - Lifecycle

    /// Re-establishes bookmark access. Safe to call repeatedly; call once at
    /// launch and after the user picks a folder.
    @discardableResult
    public func startAccess() -> Bool {
        guard let url = grantedDirectory else { return false }
        if !didStartAccess || scopedURL != url {
            scopedURL?.stopAccessingSecurityScopedResource()
            // Returns false for apps without App Sandbox, which is fine: the
            // bookmark still re-anchors the user's choice on the next launch.
            _ = url.startAccessingSecurityScopedResource()
            scopedURL = url
            didStartAccess = true
        }
        return true
    }

    public func stopAccess() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        didStartAccess = false
    }

    // MARK: - Grant

    /// Records `url` as the granted cache directory.
    /// - Returns: true when a security-scoped bookmark could be persisted.
    @discardableResult
    public func grant(_ url: URL) -> Bool {
        let directory = url.standardizedFileURL
        defaults.set(directory.path, forKey: Key.path)

        var stored = false
        if let data = bookmarkData(for: directory) {
            defaults.set(data, forKey: Key.bookmark)
            stored = true
        } else {
            defaults.removeObject(forKey: Key.bookmark)
        }
        stopAccess()
        startAccess()
        return stored
    }

    public func revoke() {
        stopAccess()
        defaults.removeObject(forKey: Key.bookmark)
        defaults.removeObject(forKey: Key.path)
    }

    // MARK: - Bookmark plumbing

    private func bookmarkData(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func refreshIfStale(_ data: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              stale,
              let fresh = bookmarkData(for: url) else { return }
        defaults.set(fresh, forKey: Key.bookmark)
        defaults.set(url.standardizedFileURL.path, forKey: Key.path)
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return nil
    }

    // MARK: - Picker

    /// Directory name NetEase keeps its encrypted playback cache in.
    public static let cacheFolderName = "online_play_cache"

    /// NetEase's cache inside its own container. Taken from the open file
    /// descriptors the monitor observes, so it is the path to point the picker
    /// at even while it cannot be read yet.
    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Containers/com.netease.163music/Data/Library/Caches/\(cacheFolderName)",
                isDirectory: true
            )
    }

    /// Where the file picker should open: the folder the monitor last reported
    /// as blocked, otherwise the known container location, otherwise the
    /// container root. The picker runs out of process, so it can be pointed at
    /// a folder the app itself is not allowed to stat yet.
    public static func defaultPickerDirectory(hint: URL?) -> URL {
        if let hint { return hint }
        if FileManager.default.fileExists(atPath: defaultCacheDirectory.path) {
            return defaultCacheDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.netease.163music", isDirectory: true)
    }
}
