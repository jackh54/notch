//
//  AgentUsageReader.swift
//  boringNotch
//
//  Adds up token usage from Claude Code transcripts and Codex rollouts.
//  Files are read incrementally, so a long session is only parsed once.
//

import Defaults
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

/// Turns new tokens into particles. It sits apart from `AgentManager` so the stream can run
/// without redrawing everything that observes the sessions, and every display shares one flow.
@MainActor
final class AgentTokenFlow: ObservableObject {
    struct Particle {
        let provider: AgentProvider
        let birth: Date
        let lifetime: TimeInterval
        /// Height in the stream, from 0 at the top to 1 at the bottom.
        let lane: Double
        let radius: CGFloat
    }

    /// Usage arrives in bursts, one completed message at a time; this spreads a burst out.
    private static let spreadSeconds: Double = 4
    private static let minimumRate: Double = 3
    private static let particleLimit = 40
    /// With no stream on screen nothing drains, so this stops a backlog from building up.
    private static let backlogLimit: Double = 60
    private static let lifetimes: ClosedRange<TimeInterval> = 1.2...1.9
    private static let radii: ClosedRange<CGFloat> = 0.7...1.5

    static let shared = AgentTokenFlow()

    @Published private(set) var isFlowing = false

    private var particles: [Particle] = []
    private var pending: [AgentProvider: Double] = [:]
    private var lastTick: Date?

    private init() {}

    /// Queues particles for `tokens`. The scale is logarithmic so that 500 tokens and
    /// 50,000 both look sensible, and no tokens means no particles.
    func add(_ tokens: Int, from provider: AgentProvider) {
        guard tokens > 0, Defaults[.agentsParticles] else { return }
        let added = log2(1 + Double(tokens) / 100) * Defaults[.agentsParticleIntensity].particlesPerDoubling
        pending[provider] = min(Self.backlogLimit, (pending[provider] ?? 0) + added)
        isFlowing = true
    }

    /// Advances to `now` and returns the live particles. Every stream shares this, so a second
    /// display sees the same particles rather than taking some from the first.
    func tick(now: Date) -> [Particle] {
        let elapsed = lastTick.map { now.timeIntervalSince($0) } ?? 0
        lastTick = now

        if elapsed > 0 {
            for (provider, count) in pending {
                let due = min(count, max(count * elapsed / Self.spreadSeconds, Self.minimumRate * elapsed))
                let spawned = Int(due.rounded(.down)) + (Double.random(in: 0..<1) < due.truncatingRemainder(dividingBy: 1) ? 1 : 0)
                for _ in 0..<spawned { spawn(provider, at: now) }
                pending[provider] = count - due
            }
            pending = pending.filter { $0.value > 0.01 }
        }

        particles.removeAll { now.timeIntervalSince($0.birth) > $0.lifetime }
        if pending.isEmpty, particles.isEmpty {
            // Called while the view is rendering, so the change has to wait for the next turn.
            lastTick = nil
            DispatchQueue.main.async { self.isFlowing = !self.pending.isEmpty }
        }
        return particles
    }

    #if DEBUG
    /// Spreads particles along the stream as if it had been running for a while.
    func loadFixture() {
        let now = Date()
        particles = (0..<30).map { index in
            Particle(
                provider: index % 4 == 3 ? .codex : .claude, birth: now.addingTimeInterval(0.7 - Double(index) * 0.1),
                lifetime: 3, lane: .random(in: 0...1), radius: .random(in: Self.radii))
        }
        isFlowing = true
    }
    #endif

    private func spawn(_ provider: AgentProvider, at date: Date) {
        particles.append(Particle(
            provider: provider, birth: date, lifetime: .random(in: Self.lifetimes),
            lane: .random(in: 0...1), radius: .random(in: Self.radii)))
        particles.removeFirst(max(0, particles.count - Self.particleLimit))
    }
}

/// Whether decorative animation may run right now.
@MainActor
final class AgentMotion: ObservableObject {
    static let shared = AgentMotion()

    @Published private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }

    func allowsAnimation(reduceMotion: Bool, pauseOnLowPower: Bool) -> Bool {
        !reduceMotion && !(pauseOnLowPower && isLowPower)
    }
}
