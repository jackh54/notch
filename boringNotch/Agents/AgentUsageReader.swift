//
//  AgentUsageReader.swift
//  boringNotch
//
//  Adds up token usage from Claude Code transcripts and Codex rollouts.
//  Files are read incrementally, so a long session is only parsed once.
//

import Foundation
import SwiftUI

enum AgentUsageReader {
    private struct FileState {
        var offset: UInt64 = 0
        var total = AgentTokenUsage()
        /// A Claude message spans several transcript lines that repeat its usage, so only the latest counts.
        var byMessage: [String: AgentTokenUsage] = [:]
    }

    private static let lock = NSLock()
    private static var files: [String: FileState] = [:]

    // MARK: - Claude Code

    /// Usage for a session's transcript plus any subagent transcripts next to it.
    static func claudeUsage(transcript: URL) -> AgentTokenUsage {
        let subagentFolder = transcript.deletingPathExtension().appendingPathComponent("subagents")
        let subagents = (try? FileManager.default.contentsOfDirectory(
            at: subagentFolder, includingPropertiesForKeys: nil)) ?? []

        return ([transcript] + subagents.filter { $0.pathExtension == "jsonl" }).reduce(into: AgentTokenUsage()) {
            $0 += claudeFileUsage($1)
        }
    }

    private static func claudeFileUsage(_ url: URL) -> AgentTokenUsage {
        updated(url) { state, line in
            guard line.range(of: Data("\"usage\"".utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let id = message["id"] as? String,
                  let usage = message["usage"] as? [String: Any]
            else { return }

            let new = AgentTokenUsage(
                input: usage["input_tokens"] as? Int ?? 0,
                output: usage["output_tokens"] as? Int ?? 0,
                cacheCreation: usage["cache_creation_input_tokens"] as? Int ?? 0,
                cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0)
            state.total = state.total.adding(new).removing(state.byMessage[id] ?? AgentTokenUsage())
            state.byMessage[id] = new
        }
    }

    // MARK: - Codex

    /// Codex writes a running total, so the newest `token_count` event is the whole session.
    static func codexUsage(rollout path: String) -> AgentTokenUsage {
        updated(URL(fileURLWithPath: path)) { state, line in
            guard line.range(of: Data("\"token_count\"".utf8)) != nil,
                  let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any]
            else { return }

            // Codex counts cache reads and writes inside input_tokens.
            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cached_input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_write_input_tokens"] as? Int ?? 0
            state.total = AgentTokenUsage(
                input: max(0, input - cacheRead - cacheCreation),
                output: usage["output_tokens"] as? Int ?? 0,
                cacheCreation: cacheCreation,
                cacheRead: cacheRead)
        }
    }

    // MARK: - Incremental reading

    /// Feeds lines appended since the last call to `parse` and returns the file's running total.
    private static func updated(_ url: URL, parse: (inout FileState, Data) -> Void) -> AgentTokenUsage {
        lock.lock()
        defer { lock.unlock() }

        var state = files[url.path] ?? FileState()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return state.total }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset { state = FileState() }
        guard size > state.offset else { return state.total }

        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd(),
              // The last line may still be being written; leave it for the next read.
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        else { return state.total }

        for line in data[data.startIndex..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            parse(&state, Data(line))
        }
        state.offset += UInt64(data.distance(from: data.startIndex, to: lastNewline) + 1)
        files[url.path] = state
        return state.total
    }
}

/// New tokens waiting to be shown, kept apart from `AgentManager` so the particle stream can
/// run without redrawing everything that observes the sessions.
@MainActor
final class AgentTokenFlow: ObservableObject {
    static let shared = AgentTokenFlow()

    /// Usage arrives in bursts, one completed message at a time; this spreads a burst out.
    private static let drainSeconds: Double = 4
    private static let finishedBelow: Double = 1

    @Published private(set) var isFlowing = false
    private var pending: [AgentProvider: Double] = [:]

    private init() {}

    func add(_ tokens: Int, from provider: AgentProvider) {
        guard tokens > 0 else { return }
        pending[provider, default: 0] += Double(tokens)
        isFlowing = true
    }

    /// Takes the tokens due over `elapsed` seconds.
    func drain(elapsed: TimeInterval) -> [AgentProvider: Double] {
        let share = min(1, elapsed / Self.drainSeconds)
        var due: [AgentProvider: Double] = [:]
        for (provider, tokens) in pending {
            let taken = tokens < Self.finishedBelow ? tokens : tokens * share
            due[provider] = taken
            pending[provider] = tokens - taken
        }
        pending = pending.filter { $0.value > 0 }
        if pending.isEmpty { isFlowing = false }
        return due
    }
}
