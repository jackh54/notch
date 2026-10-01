//
//  AgentCLI.swift
//  boringNotch
//
//  Launches the Claude Code and Codex command-line tools.
//

import AppKit
import Foundation

enum AgentCLI {
    struct Result {
        let status: Int32
        let output: String
        let errorOutput: String
    }

    static func executable(for provider: AgentProvider) -> String? {
        let home = AgentPaths.home.path
        let candidates: [String]
        switch provider {
        case .claude:
            candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
                          "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"]
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts a new headless task in `directory`.
    static func newTaskArguments(_ provider: AgentProvider, prompt: String, directory: String) -> [String] {
        switch provider {
        case .claude: return ["-p", prompt]
        case .codex: return ["exec", "--skip-git-repo-check", "-C", directory, prompt]
        }
    }

    /// Sends a follow-up to an existing session.
    static func followUpArguments(_ session: AgentSession, prompt: String) -> [String] {
        switch session.provider {
        case .claude:
            // A live session's transcript is owned by its own process, so the
            // follow-up runs in a fork that carries the session's context.
            return ["-p", prompt, "--resume", session.sessionId, "--fork-session"]
        case .codex:
            // Queued onto the real thread; Codex runs it after the current turn.
            return ["queue", "--thread", session.sessionId, "--message", prompt]
        }
    }

    /// Runs the CLI through a login shell so it sees the user's PATH and environment.
    /// `onStart` receives the launched process so the caller can terminate it.
    static func run(
        _ provider: AgentProvider, arguments: [String], directory: String?,
        onStart: (@Sendable (Process) -> Void)? = nil
    ) async -> Result {
        guard let executable = executable(for: provider) else {
            return Result(status: 127, output: "", errorOutput: "\(provider.displayName) CLI not found.")
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "exec \"$0\" \"$@\"", executable] + arguments
                if let directory, FileManager.default.fileExists(atPath: directory) {
                    process.currentDirectoryURL = URL(fileURLWithPath: directory)
                }
                process.standardInput = FileHandle.nullDevice

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: 126, output: "", errorOutput: error.localizedDescription))
                    return
                }
                onStart?(process)

                // Drain both pipes concurrently so a chatty stderr can't block the child.
                var errorData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    output: String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    errorOutput: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }

    // MARK: - Focus

    /// Brings the app hosting a session (terminal, IDE or desktop app) to the front.
    @MainActor
    static func focus(_ session: AgentSession) {
        if let pid = session.pid, let app = hostApplication(of: pid) {
            app.activate()
            return
        }

        let bundleIDs: [String]
        switch session.provider {
        case .claude: bundleIDs = ["com.anthropic.claudefordesktop"]
        case .codex: bundleIDs = ["com.openai.codex", "com.openai.chat"]
        }
        for bundleID in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate()
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                return
            }
        }
    }

    /// Walks up the process tree to the first ancestor that is a regular GUI app.
    private static func hostApplication(of pid: Int32) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<16 {
            if let app = NSRunningApplication(processIdentifier: current), app.activationPolicy == .regular {
                return app
            }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
