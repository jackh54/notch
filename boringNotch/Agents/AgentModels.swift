//
//  AgentModels.swift
//  boringNotch
//
//  Coding-agent (Claude Code / Codex) session models.
//

import Defaults
import SwiftUI

enum AgentProvider: String, Codable, CaseIterable, Identifiable, Defaults.Serializable {
    case claude
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var icon: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.38, green: 0.78, blue: 0.72)
        }
    }
}

enum AgentSessionState: Int, Comparable {
    case idle
    case working
    case waiting
    case needsApproval

    static func < (lhs: AgentSessionState, rhs: AgentSessionState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var needsAttention: Bool { self == .waiting || self == .needsApproval }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .waiting: return "Waiting for you"
        case .needsApproval: return "Needs approval"
        }
    }

    var color: Color {
        switch self {
        case .idle: return .gray
        case .working: return .green
        case .waiting: return .yellow
        case .needsApproval: return .orange
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let provider: AgentProvider
    let sessionId: String
    var title: String
    var cwd: String
    var state: AgentSessionState = .idle
    /// What the agent is doing right now, e.g. "Bash: npm test".
    var activity: String?
    var lastMessage: String?
    var updatedAt: Date
    var pid: Int32?
    /// Where the session runs ("claude-desktop", "cli", "Codex Desktop", ...).
    var host: String?

    var id: String { AgentSession.key(provider, sessionId) }

    static func key(_ provider: AgentProvider, _ sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }

    var projectName: String {
        cwd.isEmpty ? "" : (cwd as NSString).lastPathComponent
    }

    var statusJSON: [String: Any] {
        var json: [String: Any] = [
            "provider": provider.rawValue, "id": sessionId, "title": title, "cwd": cwd,
            "state": String(describing: state), "updatedAt": ISO8601DateFormatter().string(from: updatedAt),
        ]
        json["activity"] = activity
        json["lastMessage"] = lastMessage
        json["host"] = host
        return json
    }

    /// Compact age of the last update, e.g. "now", "4m", "2h", "3d".
    func age(now: Date = .now) -> String {
        let seconds = Int(now.timeIntervalSince(updatedAt))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }

    var subtitle: String {
        if state != .idle, let activity, !activity.isEmpty { return activity }
        if let lastMessage, !lastMessage.isEmpty { return lastMessage }
        return projectName
    }
}

/// A tool-permission prompt an agent is blocked on, answerable from the notch.
struct AgentApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let sessionKey: String
    let provider: AgentProvider
    let toolName: String
    let detail: String
    let receivedAt: Date
}

struct AgentBanner: Equatable {
    let provider: AgentProvider
    let title: String
    let text: String
}

extension Notification.Name {
    static let agentNeedsAttention = Notification.Name("agentNeedsAttention")
    /// Opens the notch on the Agents tab.
    static let agentOpenRequested = Notification.Name("agentOpenRequested")
}

extension Defaults.Keys {
    // MARK: Agents
    static let enableAgents = Key<Bool>("enableAgents", default: true)
    static let agentsDefaultTab = Key<Bool>("agentsDefaultTab", default: true)
    static let agentsLiveActivity = Key<Bool>("agentsLiveActivity", default: true)
    static let agentsOpenOnApproval = Key<Bool>("agentsOpenOnApproval", default: true)
    static let agentsFinishedBanner = Key<Bool>("agentsFinishedBanner", default: true)
    static let agentsAnswerApprovals = Key<Bool>("agentsAnswerApprovals", default: true)
    static let didEnableLaunchAtLogin = Key<Bool>("didEnableLaunchAtLoginForFork", default: false)
    static let agentsHookPort = Key<Int>("agentsHookPort", default: 47615)
    static let agentsHookToken = Key<String>("agentsHookToken", default: "")
    static let agentsNewTaskProvider = Key<AgentProvider>("agentsNewTaskProvider", default: .claude)
    static let agentsLastDirectory = Key<String>("agentsLastDirectory", default: "")
}

enum AgentText {
    /// Collapses whitespace and trims so text fits a one-line row.
    static func oneLine(_ text: String, limit: Int = 160) -> String {
        // Agents answer in Markdown; drop the emphasis markers that would show up literally.
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let collapsed = plain.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// A short human description of a tool call from its hook payload.
    static func toolDetail(name: String, input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["command", "file_path", "path", "url", "pattern", "query", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
            if let value = input[key] as? [String], !value.isEmpty { return value.joined(separator: " ") }
        }
        if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return ""
    }
}
