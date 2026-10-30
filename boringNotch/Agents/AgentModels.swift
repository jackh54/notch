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
    /// When the current turn began; nil while idle.
    var turnStartedAt: Date?
    /// The newest tool calls of the current turn, oldest first.
    var recentTools: [AgentToolCall] = []
    var subagentCount: Int = 0
    /// The last message with its Markdown intact; `lastMessage` is the one-line form.
    var fullMessage: String?
    var model: String?
    var gitBranch: String?
    var usage = AgentTokenUsage()
    var tokensPerMinute: Int = 0

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
        json["model"] = model
        json["gitBranch"] = gitBranch
        json["subagents"] = subagentCount
        json["tokens"] = usage.total(includingCached: Defaults[.agentsCountCachedTokens])
        json["tokensPerMinute"] = tokensPerMinute
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

/// One tool call from hook events.
struct AgentToolCall: Identifiable, Equatable {
    let id: UUID
    let toolUseID: String?
    let name: String
    let detail: String
    let startedAt: Date
    var finishedAt: Date?
    var failed: Bool = false

    var icon: String {
        switch name {
        case "Bash", "shell", "exec_command": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Agent", "Task": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// Tokens used by a session, split the way providers bill them.
struct AgentTokenUsage: Equatable {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0

    /// Cache reads repeat the whole context on every call, so by default only new tokens count.
    func total(includingCached: Bool) -> Int {
        input + output + cacheCreation + (includingCached ? cacheRead : 0)
    }

    func adding(_ other: AgentTokenUsage) -> AgentTokenUsage {
        AgentTokenUsage(
            input: input + other.input, output: output + other.output,
            cacheCreation: cacheCreation + other.cacheCreation, cacheRead: cacheRead + other.cacheRead)
    }

    /// The tokens added since `earlier`, never negative.
    func removing(_ earlier: AgentTokenUsage) -> AgentTokenUsage {
        AgentTokenUsage(
            input: max(0, input - earlier.input), output: max(0, output - earlier.output),
            cacheCreation: max(0, cacheCreation - earlier.cacheCreation),
            cacheRead: max(0, cacheRead - earlier.cacheRead))
    }

    static func += (left: inout AgentTokenUsage, right: AgentTokenUsage) {
        left = left.adding(right)
    }
}

/// What a tool call will do, in a form the approval card can present.
enum AgentToolPreview: Equatable {
    case command(String)
    case edit(path: String, old: String, new: String)
    case write(path: String, lineCount: Int)
    case web(url: String)
    case generic(String)

    /// Matches on the input's shape rather than the tool name, so Codex tools work too.
    init(input: [String: Any]?, detail: String) {
        let path = input?["file_path"] as? String ?? input?["path"] as? String
        if let path, let old = input?["old_string"] as? String, let new = input?["new_string"] as? String {
            self = .edit(path: path, old: old, new: new)
        } else if let path, let content = input?["content"] as? String {
            self = .write(path: path, lineCount: content.split(separator: "\n", omittingEmptySubsequences: false).count)
        } else if let url = input?["url"] as? String {
            self = .web(url: url)
        } else if input?["command"] != nil, !detail.isEmpty {
            self = .command(detail)
        } else {
            self = .generic(detail)
        }
    }
}

/// An allow rule Claude Code offers for a permission prompt.
struct AgentPermissionRule: Equatable {
    let toolName: String
    let ruleContent: String?

    var label: String {
        ruleContent.map { "\(toolName)(\($0))" } ?? toolName
    }

    /// Reads the `addRules` allow entries of `permission_suggestions`. Other suggestions,
    /// such as switching the permission mode, are ignored on purpose.
    static func rules(fromSuggestions suggestions: [[String: Any]]?) -> [AgentPermissionRule] {
        (suggestions ?? []).flatMap { suggestion -> [AgentPermissionRule] in
            guard suggestion["type"] as? String == "addRules",
                  suggestion["behavior"] as? String == "allow",
                  let rules = suggestion["rules"] as? [[String: Any]]
            else { return [] }
            return rules.compactMap { rule in
                (rule["toolName"] as? String).map {
                    AgentPermissionRule(toolName: $0, ruleContent: rule["ruleContent"] as? String)
                }
            }
        }
    }
}

/// A tool-permission prompt an agent is blocked on, answerable from the notch.
struct AgentApprovalRequest: Identifiable, Equatable {
    let id: UUID
    let sessionKey: String
    let provider: AgentProvider
    let toolName: String
    let detail: String
    let preview: AgentToolPreview
    /// Rules that "Allow for session" can apply; empty when none are on offer.
    let sessionRules: [AgentPermissionRule]
    let receivedAt: Date
}

/// One multiple-choice question from an agent.
struct AgentQuestion: Equatable {
    struct Option: Equatable {
        let label: String
        let detail: String
    }

    let text: String
    let header: String
    let options: [Option]
    let multiSelect: Bool
}

/// A set of questions an agent is blocked on, answerable from the notch.
struct AgentQuestionRequest: Identifiable, Equatable {
    let id: UUID
    let sessionKey: String
    let questions: [AgentQuestion]
    let receivedAt: Date

    /// Parses the input of Claude Code's AskUserQuestion tool.
    static func questions(fromToolInput input: [String: Any]?) -> [AgentQuestion] {
        (input?["questions"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let text = raw["question"] as? String else { return nil }
            let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option in
                (option["label"] as? String).map {
                    AgentQuestion.Option(label: $0, detail: option["description"] as? String ?? "")
                }
            }
            return AgentQuestion(
                text: text, header: raw["header"] as? String ?? "",
                options: options, multiSelect: raw["multiSelect"] as? Bool ?? false)
        }
    }
}

/// Anything an agent is blocked on until the user answers it in the notch.
enum AgentRequest: Identifiable, Equatable {
    case approval(AgentApprovalRequest)
    case question(AgentQuestionRequest)

    var id: UUID {
        switch self {
        case .approval(let approval): return approval.id
        case .question(let question): return question.id
        }
    }

    var sessionKey: String {
        switch self {
        case .approval(let approval): return approval.sessionKey
        case .question(let question): return question.sessionKey
        }
    }

    var receivedAt: Date {
        switch self {
        case .approval(let approval): return approval.receivedAt
        case .question(let question): return question.receivedAt
        }
    }
}

struct AgentBanner: Equatable {
    enum Outcome {
        case finished
        case failed
    }

    let sessionKey: String
    let provider: AgentProvider
    let title: String
    let text: String
    var outcome: Outcome = .finished
}

enum AgentParticleIntensity: String, CaseIterable, Identifiable, Defaults.Serializable {
    case subtle
    case normal
    case lively

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .normal: return "Normal"
        case .lively: return "Lively"
        }
    }

    /// Particles added each time a burst of tokens doubles in size.
    var particlesPerDoubling: Double {
        switch self {
        case .subtle: return 1.5
        case .normal: return 3
        case .lively: return 6
        }
    }
}

enum AgentParticleColor: String, CaseIterable, Identifiable, Defaults.Serializable {
    case provider
    case state
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .provider: return "Provider"
        case .state: return "Session state"
        case .custom: return "Custom"
        }
    }
}

enum AgentTokenReadout: String, CaseIterable, Identifiable, Defaults.Serializable {
    case off
    case perMinute
    case sessionTotal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .perMinute: return "Per minute"
        case .sessionTotal: return "Session total"
        }
    }
}

enum AgentClaudeIcon: String, CaseIterable, Identifiable, Defaults.Serializable {
    case pet
    case sparkle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pet: return "Pet"
        case .sparkle: return "Sparkle"
        }
    }
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
    static let agentsAnswerQuestions = Key<Bool>("agentsAnswerQuestions", default: true)
    static let didEnableLaunchAtLogin = Key<Bool>("didEnableLaunchAtLoginForFork", default: false)
    static let agentsHookPort = Key<Int>("agentsHookPort", default: 47615)
    static let agentsHookToken = Key<String>("agentsHookToken", default: "")
    static let agentsNewTaskProvider = Key<AgentProvider>("agentsNewTaskProvider", default: .claude)
    static let agentsLastDirectory = Key<String>("agentsLastDirectory", default: "")
    static let agentsCountCachedTokens = Key<Bool>("agentsCountCachedTokens", default: false)
    static let agentsParticles = Key<Bool>("agentsParticles", default: true)
    static let agentsParticlesClosed = Key<Bool>("agentsParticlesClosed", default: true)
    static let agentsParticlesOpen = Key<Bool>("agentsParticlesOpen", default: true)
    static let agentsParticleIntensity = Key<AgentParticleIntensity>("agentsParticleIntensity", default: .normal)
    static let agentsParticleColor = Key<AgentParticleColor>("agentsParticleColor", default: .provider)
    static let agentsParticleCustomColor = Key<Color>("agentsParticleCustomColor", default: .cyan)
    static let agentsTokenReadout = Key<AgentTokenReadout>("agentsTokenReadout", default: .sessionTotal)
    static let agentsClaudeIcon = Key<AgentClaudeIcon>("agentsClaudeIcon", default: .pet)
    static let agentsAnimatePet = Key<Bool>("agentsAnimatePet", default: true)
    static let agentsAttentionGlow = Key<Bool>("agentsAttentionGlow", default: true)
    static let agentsSounds = Key<Bool>("agentsSounds", default: false)
    static let agentsPauseOnLowPower = Key<Bool>("agentsPauseOnLowPower", default: true)
}

enum AgentText {
    /// Collapses whitespace and trims so text fits a one-line row.
    static func oneLine(_ text: String, limit: Int = 160) -> String {
        // Agents answer in Markdown; drop the emphasis markers that would show up literally.
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let collapsed = plain.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

    /// Compact token count, e.g. "940", "12.4k", "1.2M".
    static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1000: return "\(count)"
        case ..<1_000_000: return compact(Double(count) / 1000, suffix: "k")
        default: return compact(Double(count) / 1_000_000, suffix: "M")
        }
    }

    private static func compact(_ value: Double, suffix: String) -> String {
        let text = value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return text.replacingOccurrences(of: ".0", with: "") + suffix
    }

    /// Time since `date`, e.g. "45s", "12m", "1h 5m".
    static func elapsed(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        default: return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
    }

    /// Shortens a Claude model id, e.g. "claude-opus-5-5" to "Opus 5.5". Other ids pass through.
    static func modelName(_ model: String) -> String {
        guard model.hasPrefix("claude-") else { return model }
        let parts = model.dropFirst("claude-".count).split(separator: "-")
        guard let family = parts.first else { return model }
        // A long numeric part is a date stamp rather than a version.
        let version = parts.dropFirst().filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return ([family.capitalized] + (version.isEmpty ? [] : [version.joined(separator: ".")])).joined(separator: " ")
    }

    /// Replaces the home folder with "~".
    static func abbreviated(path: String) -> String {
        path.replacingOccurrences(of: AgentPaths.home.path, with: "~")
    }

    /// Keeps Markdown intact but bounds what a session holds on to.
    static func clipped(_ text: String, limit: Int = 8000) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
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
