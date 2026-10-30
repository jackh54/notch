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
            let transcript = transcriptURL(sessionId: entry.sessionId, cwd: cwd)
            let tail = transcript.flatMap { transcriptTail($0, sessionId: entry.sessionId) }

            return AgentSession(
                provider: .claude,
                sessionId: entry.sessionId,
                title: name.isEmpty ? (cwd as NSString).lastPathComponent : name,
                cwd: cwd,
                state: entry.status == "busy" ? .working : .idle,
                lastMessage: tail?.message.map { AgentText.oneLine($0, limit: 600) },
                updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                pid: entry.pid,
                host: entry.entrypoint,
                turnStartedAt: entry.status == "busy" ? Date(timeIntervalSince1970: milliseconds / 1000) : nil,
                fullMessage: tail?.message,
                model: tail?.model,
                gitBranch: tail?.gitBranch,
                usage: transcript.map(AgentUsageReader.claudeUsage) ?? AgentTokenUsage()
            )
        }
    }

    // MARK: Transcript

    private struct TranscriptTail {
        var message: String?
        var model: String?
        var gitBranch: String?
    }

    private static let cacheLock = NSLock()
    private static var tailCache: [String: (modified: Date, tail: TranscriptTail)] = [:]

    /// Transcripts live in a folder named after the cwd with non-alphanumerics replaced by "-".
    static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        guard !cwd.isEmpty else { return nil }
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return AgentPaths.claudeProjects.appendingPathComponent("\(folder)/\(sessionId).jsonl")
    }

    /// The last thing Claude said and the model and branch it was on.
    private static func transcriptTail(_ url: URL, sessionId: String) -> TranscriptTail? {
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }

        cacheLock.lock()
        let cached = tailCache[sessionId]
        cacheLock.unlock()
        if let cached, cached.modified == modified { return cached.tail }

        let tail = readTranscriptTail(url)
        cacheLock.lock()
        tailCache[sessionId] = (modified, tail)
        cacheLock.unlock()
        return tail
    }

    private static func readTranscriptTail(_ url: URL) -> TranscriptTail {
        var tail = TranscriptTail()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return tail }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return tail }

        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard line.range(of: Data("\"type\":\"assistant\"".utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { continue }

            if tail.gitBranch == nil { tail.gitBranch = object["gitBranch"] as? String }
            // Locally generated messages carry a placeholder such as "<synthetic>".
            if tail.model == nil, let model = message["model"] as? String, !model.hasPrefix("<") { tail.model = model }

            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tail.message = AgentText.clipped(text)
                break
            }
        }
        return tail
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
                   COALESCE(preview, ''), COALESCE(rollout_path, ''), COALESCE(originator, ''), COALESCE(git_branch, '')
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
            let rollout = text(5)
            let gitBranch = text(7)
            let tail = cachedRolloutTail(path: rollout)

            sessions.append(AgentSession(
                provider: .codex,
                sessionId: text(0),
                title: title.isEmpty ? (cwd as NSString).lastPathComponent : AgentText.oneLine(title, limit: 80),
                cwd: cwd,
                state: tail.isRunning ? .working : .idle,
                lastMessage: tail.lastMessage.map { AgentText.oneLine($0, limit: 600) } ?? AgentText.oneLine(text(4)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3))),
                host: text(6),
                fullMessage: tail.lastMessage,
                model: tail.model,
                gitBranch: gitBranch.isEmpty ? nil : gitBranch,
                usage: rollout.isEmpty ? AgentTokenUsage() : AgentUsageReader.codexUsage(rollout: rollout)
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

    private typealias RolloutTail = (isRunning: Bool, lastMessage: String?, model: String?)

    private static let cacheLock = NSLock()
    private static var tailCache: [String: (modified: Date, tail: RolloutTail)] = [:]

    /// Rollouts are parsed every poll for every recent thread, so only reread those that changed.
    private static func cachedRolloutTail(path: String) -> RolloutTail {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard let modified else { return (false, nil, nil) }

        cacheLock.lock()
        let cached = tailCache[path]
        cacheLock.unlock()
        if let cached, cached.modified == modified { return cached.tail }

        let tail = rolloutTail(path: path)
        cacheLock.lock()
        tailCache[path] = (modified, tail)
        cacheLock.unlock()
        return tail
    }

    /// A turn is running when the newest turn marker in the rollout is `task_started`.
    private static func rolloutTail(path: String) -> RolloutTail {
        guard !path.isEmpty, let handle = FileHandle(forReadingAtPath: path) else { return (false, nil, nil) }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return (false, nil, nil) }

        var isRunning: Bool?
        var lastMessage: String?
        var model: String?
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            // Cheap pre-filter: only event and turn lines matter and rollouts are large.
            let isTurnContext = line.range(of: Data("\"turn_context\"".utf8)) != nil
            guard isTurnContext || line.range(of: Data("\"event_msg\"".utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }

            if object["type"] as? String == "turn_context" {
                if model == nil { model = payload["model"] as? String }
                continue
            }
            guard object["type"] as? String == "event_msg", let type = payload["type"] as? String else { continue }

            switch type {
            case "task_started":
                if isRunning == nil { isRunning = true }
            case "task_complete", "turn_aborted":
                if isRunning == nil { isRunning = false }
                if lastMessage == nil, let message = payload["last_agent_message"] as? String {
                    lastMessage = AgentText.clipped(message)
                }
            case "agent_message":
                if lastMessage == nil, let message = payload["message"] as? String {
                    lastMessage = AgentText.clipped(message)
                }
            default:
                break
            }
            if isRunning != nil && lastMessage != nil && model != nil { break }
        }
        return (isRunning ?? false, lastMessage, model)
    }
}
