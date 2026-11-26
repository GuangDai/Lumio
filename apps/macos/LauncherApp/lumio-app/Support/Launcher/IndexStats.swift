//
//  IndexStats.swift
//  lumio-app
//
//  Application and folder index counts for Settings ▸ Indexing.
//

import Foundation
import SQLite3

nonisolated struct IndexStats: Equatable, Sendable {
    var apps = 0
    var folders = 0
    var updated: Date?
    var spotlightOn: Bool?

    /// The core's default database (see bridge/ffi `default_db_path`).
    private static var databasePath: String {
        if let custom = ProcessInfo.processInfo.environment["LUMIO_DB_PATH"], !custom.isEmpty { return custom }
        return NSHomeDirectory() + "/Library/Application Support/lumio/lumio.db"
    }

    /// Reads the counts. Call off the main thread.
    static func read() -> IndexStats {
        var stats = IndexStats(spotlightOn: spotlightEnabled())
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(databasePath, &handle, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(handle) }
        guard status == SQLITE_OK, let handle else { return stats }

        sqlite3_busy_timeout(handle, 400)
        var statement: OpaquePointer?
        let sql = """
            SELECT COUNT(CASE WHEN kind = 'app' THEN 1 END),
                   COUNT(CASE WHEN kind = 'folder' THEN 1 END), MAX(indexed_at_unix_s)
            FROM candidates WHERE kind IN ('app', 'folder')
            """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return stats }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return stats }

        stats.apps = Int(sqlite3_column_int64(statement, 0))
        stats.folders = Int(sqlite3_column_int64(statement, 1))
        let latest = sqlite3_column_int64(statement, 2)
        if latest > 0 { stats.updated = Date(timeIntervalSince1970: TimeInterval(latest)) }
        return stats
    }

    /// Checks whether macOS can provide additional folder matches on the data volume.
    private static func spotlightEnabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-s", "/System/Volumes/Data"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        if text.contains("indexing enabled") { return true }
        if text.contains("indexing disabled") || text.contains("indexing and searching disabled") { return false }
        return nil
    }
}
