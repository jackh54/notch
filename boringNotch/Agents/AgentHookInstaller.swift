//
//  AgentHookInstaller.swift
//  boringNotch
//
//  Installs the hook script and registers it with Claude Code and Codex.
//  Existing hooks from other tools are left untouched.
//

import Defaults
import Foundation

enum AgentHookInstaller {
    static let scriptName = "notch-agent-hook"

    static var scriptURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("boringNotch/\(scriptName)")
    }

    /// Events we subscribe to; the value is the hook timeout in seconds.
    private static func events(for provider: AgentProvider) -> [(name: String, timeout: Int)] {
        let common: [(String, Int)] = [
            ("SessionStart", 5), ("UserPromptSubmit", 5), ("PreToolUse", 5), ("PostToolUse", 5),
            ("PermissionRequest", approvalTimeout), ("Stop", 5),
        ]
        switch provider {
        case .claude: return common + [("Notification", 5), ("SessionEnd", 5)]
        case .codex: return common
        }
    }

    /// How long a permission prompt can wait on the notch before the agent falls back to its own prompt.
    static let approvalTimeout = 300

    private static func settingsURL(for provider: AgentProvider) -> URL {
        switch provider {
        case .claude: return AgentPaths.claudeSettings
        case .codex: return AgentPaths.codexHooks
        }
    }

    // MARK: - Script

    /// Writes the forwarding script. It is silent and exits 0 when the app isn't running,
    /// so agents behave exactly as normal without the notch.
    static func writeScript() throws {
        let url = "http://127.0.0.1:\(Defaults[.agentsHookPort])/hook/$1?token=\(Defaults[.agentsHookToken])"
        let script = """
            #!/bin/sh
            # Forwards Claude Code / Codex hook events to the notch app.
            # Usage: \(scriptName) <claude|codex> [timeout-seconds]
            /usr/bin/curl -s --connect-timeout 1 --max-time "${2:-5}" \\
              -H 'Content-Type: application/json' -H 'Expect:' \\
              --data-binary @- "\(url)" 2>/dev/null
            exit 0

            """
        try FileManager.default.createDirectory(
            at: scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // MARK: - Registration

    static func isInstalled(_ provider: AgentProvider, at url: URL? = nil) -> Bool {
        guard let root = readJSON(url ?? settingsURL(for: provider)),
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        return events(for: provider).allSatisfy { event in
            (hooks[event.name] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    /// `url` overrides the provider's settings file.
    static func install(_ provider: AgentProvider, at url: URL? = nil) throws {
        try writeScript()

        let url = url ?? settingsURL(for: provider)
        var root = try loadForEditing(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for event in events(for: provider) {
            var groups = (hooks[event.name] as? [[String: Any]] ?? []).filter { !isOurs($0) }
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": "\"\(scriptURL.path)\" \(provider.rawValue) \(event.timeout)",
                    "timeout": event.timeout + 5,
                ]]
            ])
            hooks[event.name] = groups
        }

        root["hooks"] = hooks
        try save(root, to: url)
    }

    static func uninstall(_ provider: AgentProvider, at url: URL? = nil) throws {
        let url = url ?? settingsURL(for: provider)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try loadForEditing(url)
        guard var hooks = root["hooks"] as? [String: Any] else { return }

        for (name, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let remaining = groups.filter { !isOurs($0) }
            hooks[name] = remaining.isEmpty ? nil : remaining
        }

        root["hooks"] = hooks.isEmpty ? nil : hooks
        try save(root, to: url)
    }

    // MARK: - Helpers

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains(scriptName) == true
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Refuses to touch a settings file that exists but can't be parsed, rather than overwriting it.
    private static func loadForEditing(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let root = readJSON(url) else {
            throw NSError(domain: "AgentHookInstaller", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(url.path) isn't valid JSON, so it was left unchanged."
            ])
        }
        return root
    }

    private static func save(_ root: [String: Any], to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("notch-backup")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: url, to: backup)
        }

        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
