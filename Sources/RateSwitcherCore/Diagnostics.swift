import Foundation
import os

public final class Diagnostics {
    public static let shared = Diagnostics()

    private let logger = Logger(subsystem: "io.github.music-rate-switcher", category: "app")
    private let queue = DispatchQueue(label: "io.github.music-rate-switcher.diagnostics")
    private var recentLines: [String] = []
    private let formatter: ISO8601DateFormatter
    public let logURL: URL

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MusicRateSwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        logURL = base.appendingPathComponent("MusicRateSwitcher.log")
    }

    public func info(_ message: String) { write("INFO", message) }
    public func warning(_ message: String) { write("WARN", message) }
    public func error(_ message: String) { write("ERROR", message) }

    public func recentText() -> String {
        queue.sync { recentLines.joined(separator: "\n") }
    }

    private func write(_ level: String, _ message: String) {
        logger.log("[\(level, privacy: .public)] \(message, privacy: .public)")
        queue.async { [formatter, logURL] in
            let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
            self.recentLines.append(line)
            if self.recentLines.count > 300 { self.recentLines.removeFirst(self.recentLines.count - 300) }
            let data = Data((line + "\n").utf8)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: data)
            } else if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    // Unified logging remains available even if the file cannot be written.
                }
            }
            self.rotateIfNeeded()
        }
    }

    private func rotateIfNeeded() {
        guard
            let values = try? logURL.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size > 2 * 1_024 * 1_024
        else { return }
        let oldURL = logURL.deletingLastPathComponent().appendingPathComponent("MusicRateSwitcher.old.log")
        try? FileManager.default.removeItem(at: oldURL)
        try? FileManager.default.moveItem(at: logURL, to: oldURL)
    }
}
