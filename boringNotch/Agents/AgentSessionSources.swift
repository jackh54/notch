//
//  AgentSessionSources.swift
//  boringNotch
//
//  Reads session state that Claude Code and Codex keep on disk.
//

import Foundation
import SQLite3

enum AgentPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static let claudeDirectory = home.appendingPathComponent(".claude")
    static let claudeSessions = claudeDirectory.appendingPathComponent("sessions")
    static let claudeSettings = claudeDirectory.appendingPathComponent("settings.json")
    static let claudeProjects = claudeDirectory.appendingPathComponent("projects")

    static let codexDirectory = home.appendingPathComponent(".codex")
    static let codexState = codexDirectory.appendingPathComponent("state_5.sqlite")
    static let codexHooks = codexDirectory.appendingPathComponent("hooks.json")
}

// MARK: - Claude Code

/// Claude Code writes one `<pid>.json` per running session, including a busy/idle status.
enum ClaudeSessionSource {
    private struct Entry: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        let name: String?
        let status: String?
        let entrypoint: String?
        let startedAt: Double?
        let updatedAt: Double?
        let statusUpdatedAt: Double?
    }

    static func load() -> [AgentSession] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AgentPaths.claudeSessions, includingPropertiesForKeys: nil)) ?? []

        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  isAlive(entry.pid)
            else { return nil }

            let cwd = entry.cwd ?? ""
            let milliseconds = entry.statusUpdatedAt ?? entry.updatedAt ?? entry.startedAt ?? 0
            let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            return AgentSession(
                provider: .claude,
                sessionId: entry.sessionId,
                title: name.isEmpty ? (cwd as NSString).lastPathComponent : name,
                cwd: cwd,
                state: entry.status == "busy" ? .working : .idle,
                lastMessage: lastAssistantMessage(sessionId: entry.sessionId, cwd: cwd),
                updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                pid: entry.pid,
                host: entry.entrypoint
            )
        }
    }

    // MARK: Transcript

    private static let cacheLock = NSLock()
    private static var messageCache: [String: (modified: Date, message: String?)] = [:]

    /// The last thing Claude said, read from the tail of the session transcript.
    private static func lastAssistantMessage(sessionId: String, cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        // Transcripts live in a folder named after the cwd with non-alphanumerics replaced by "-".
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        let url = AgentPaths.claudeProjects.appendingPathComponent("\(folder)/\(sessionId).jsonl")
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }

        cacheLock.lock()
        let cached = messageCache[sessionId]
        cacheLock.unlock()
        if let cached, cached.modified == modified { return cached.message }

        let message = readLastAssistantMessage(url)
        cacheLock.lock()
        messageCache[sessionId] = (modified, message)
        cacheLock.unlock()
        return message
    }

    private static func readLastAssistantMessage(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: " ")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AgentText.oneLine(text, limit: 600)
            }
        }
        return nil
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

// MARK: - Codex

/// Codex keeps threads in a SQLite index and each thread's events in a rollout JSONL file.
enum CodexSessionSource {
    /// Threads touched within this window are shown.
    static let recency: TimeInterval = 3 * 24 * 60 * 60
    static let limit = 8

    static func load() -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: AgentPaths.codexState.path) else { return [] }

        let path = AgentPaths.codexState.path
        // The index is in WAL mode; fall back to an immutable snapshot if a shared read isn't possible.
        let db = open("file:\(path)?mode=ro") ?? open("file:\(path)?mode=ro&immutable=1")
        guard let db else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), ''), cwd, updated_at,
                   COALESCE(preview, ''), COALESCE(rollout_path, ''), COALESCE(originator, '')
            FROM threads
            WHERE archived = 0 AND thread_source = 'user' AND updated_at >= ?
            ORDER BY updated_at DESC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(Date().timeIntervalSince1970 - recency))
        sqlite3_bind_int(statement, 2, Int32(limit))

        var sessions: [AgentSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            let cwd = text(2)
            let title = text(1)
            let tail = rolloutTail(path: text(5))

            sessions.append(AgentSession(
                provider: .codex,
                sessionId: text(0),
                title: title.isEmpty ? (cwd as NSString).lastPathComponent : AgentText.oneLine(title, limit: 80),
                cwd: cwd,
                state: tail.isRunning ? .working : .idle,
                lastMessage: tail.lastMessage ?? AgentText.oneLine(text(4)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3))),
                host: text(6)
            ))
        }
        return sessions
    }

    private static func open(_ uri: String) -> OpaquePointer? {
        var db: OpaquePointer?
        if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
           sqlite3_exec(db, "SELECT 1 FROM threads LIMIT 1", nil, nil, nil) == SQLITE_OK {
            return db
        }
        sqlite3_close(db)
        return nil
    }

    /// A turn is running when the newest turn marker in the rollout is `task_started`.
    private static func rolloutTail(path: String) -> (isRunning: Bool, lastMessage: String?) {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return (false, nil) }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return (false, nil) }

        var isRunning: Bool?
        var lastMessage: String?
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            // Cheap pre-filter: only event lines matter and rollouts are large.
            guard line.range(of: Data("\"event_msg\"".utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String
            else { continue }

            switch type {
            case "task_started":
                if isRunning == nil { isRunning = true }
            case "task_complete", "turn_aborted":
                if isRunning == nil { isRunning = false }
                if lastMessage == nil, let message = payload["last_agent_message"] as? String {
                    lastMessage = AgentText.oneLine(message, limit: 600)
                }
            case "agent_message":
                if lastMessage == nil, let message = payload["message"] as? String {
                    lastMessage = AgentText.oneLine(message, limit: 600)
                }
            default:
                break
            }
            if isRunning != nil && lastMessage != nil { break }
        }
        return (isRunning ?? false, lastMessage)
    }
}
