import Foundation
import os.log

public enum AppLogger {
    private static let subsystem = "com.keyswitcher.app"
    private static let log = OSLog(subsystem: subsystem, category: "general")
    private static let fileLock = NSLock()

    public static var logFileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/KeySwitcher", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("keyswitcher.log")
    }

    public static func info(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
        appendToFile("INFO", message)
    }

    public static func debug(_ message: String) {
        os_log("%{public}@", log: log, type: .debug, message)
        appendToFile("DEBUG", message)
    }

    public static func error(_ message: String) {
        os_log("%{public}@", log: log, type: .error, message)
        appendToFile("ERROR", message)
    }

    public static func warning(_ message: String) {
        os_log("%{public}@", log: log, type: .default, message)
        appendToFile("WARN", message)
    }

    /// Always written — use for layout-decision traces.
    public static func trace(_ message: String) {
        os_log("%{public}@", log: log, type: .info, message)
        appendToFile("TRACE", message)
    }

    public static func clearLogFile() {
        fileLock.lock()
        defer { fileLock.unlock() }
        try? Data().write(to: logFileURL)
    }

    private static func appendToFile(_ level: String, _ message: String) {
        fileLock.lock()
        defer { fileLock.unlock() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: url)
        }
    }
}
