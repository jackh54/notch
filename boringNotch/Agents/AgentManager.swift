//
//  AgentManager.swift
//  boringNotch
//
//  Tracks Claude Code and Codex sessions and the actions the notch can take on them.
//

import Combine
import Defaults
import SwiftUI

@MainActor
final class AgentManager: ObservableObject {
    static let shared = AgentManager()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var approvals: [AgentApprovalRequest] = []
    @Published private(set) var questions: [AgentQuestionRequest] = []
    @Published private(set) var banner: AgentBanner?
    @Published var lastError: String?
    /// True while the prompt field has keyboard focus; keeps the notch open.
    @Published var isComposing: Bool = false
    /// Set by the keyboard shortcut; the Agents tab focuses its prompt field and clears it.
    @Published var wantsPromptFocus: Bool = false

    /// State learned from hook events, keyed by session key.
    private struct HookInfo {
        var cwd: String = ""
        var state: AgentSessionState = .idle
        var activity: String?
        var lastMessage: String?
        var updatedAt: Date = .now
    }

    private var hookInfo: [String: HookInfo] = [:]
    private var polled: [AgentSession] = []
    /// Headless tasks started from the notch, keyed by session key.
    private var localRuns: [String: AgentSession] = [:]
    private var pendingReplies: [UUID: AgentHookServer.Reply] = [:]
    /// The original tool input of each pending question, echoed back with the answers.
    private var questionInputs: [UUID: [String: Any]] = [:]
    private var runProcesses: [String: Process] = [:]

    private let server = AgentHookServer()
    private var pollTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    private static let hookOnlyLifetime: TimeInterval = 15 * 60
    private static let stalledWorkLifetime: TimeInterval = 10 * 60

    private init() {}

    // MARK: - Lifecycle

    func start() {
        if Defaults[.agentsHookToken].isEmpty {
            Defaults[.agentsHookToken] = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }

        server.onEvent = { [weak self] provider, payload, wait, requestID, reply in
            MainActor.assumeIsolated {
                self?.handleHook(provider: provider, payload: payload, wait: wait, requestID: requestID, reply: reply)
            }
        }
        server.onStatus = { [weak self] in
            MainActor.assumeIsolated { self?.statusJSON() }
        }
        server.onOpen = {
            NotificationCenter.default.post(name: .agentOpenRequested, object: nil)
        }
        server.onDisconnect = { [weak self] requestID in
            MainActor.assumeIsolated {
                self?.dropRequest(requestID)
            }
        }

        Defaults.publisher(.enableAgents)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                Task { @MainActor in
                    enabled ? self?.activate() : self?.deactivate()
                }
            }
            .store(in: &cancellables)
    }

    private func activate() {
        server.start(port: Defaults[.agentsHookPort], token: Defaults[.agentsHookToken])
        // Keep an already-installed script pointing at the current port and token.
        if FileManager.default.fileExists(atPath: AgentHookInstaller.scriptURL.path) {
            try? AgentHookInstaller.writeScript()
        }

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let loaded = await Task.detached(priority: .utility) {
                    ClaudeSessionSource.load() + CodexSessionSource.load()
                }.value
                guard !Task.isCancelled else { return }
                self?.polled = loaded
                self?.publish()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        server.stop()
        for approval in approvals { resolve(approval, allow: nil) }
        for question in questions { answerInAgent(question) }
        polled = []
        hookInfo = [:]
        publish()
    }

    // MARK: - Derived state

    var attentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var workingCount: Int { sessions.filter { $0.state == .working }.count }

    /// Whether the closed notch should show the agent indicator.
    var hasLiveActivity: Bool {
        Defaults[.enableAgents] && Defaults[.agentsLiveActivity] && (attentionCount > 0 || workingCount > 0)
    }

    /// The session the closed notch represents: the one that most needs the user.
    var primarySession: AgentSession? {
        sessions.first { $0.state.needsAttention } ?? sessions.first { $0.state == .working }
    }

    /// The approval the keyboard shortcuts act on: the oldest one still pending.
    func allowOldestApproval() { approvals.first.map(allow) }
    func denyOldestApproval() { approvals.first.map(deny) }

    func approval(for session: AgentSession) -> AgentApprovalRequest? {
        approvals.first { $0.sessionKey == session.id }
    }

    func question(for session: AgentSession) -> AgentQuestionRequest? {
        questions.first { $0.sessionKey == session.id }
    }

    /// True while an agent is blocked on an answer from the notch.
    var hasPendingRequests: Bool { !approvals.isEmpty || !questions.isEmpty }

    /// Working directories worth offering for a new task, most recent first.
    var knownDirectories: [String] {
        var seen = Set<String>()
        let last = Defaults[.agentsLastDirectory]
        return ([last] + sessions.map(\.cwd)).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func statusJSON() -> Data? {
        let body: [String: Any] = [
            "sessions": sessions.map(\.statusJSON),
            "approvals": approvals.map { ["session": $0.sessionKey, "tool": $0.toolName, "detail": $0.detail] },
            "questions": questions.map { ["session": $0.sessionKey, "questions": $0.questions.map(\.text)] },
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: - Merging

    private func publish() {
        let now = Date()
        var merged: [String: AgentSession] = [:]

        for session in polled { merged[session.id] = session }
        for (key, run) in localRuns {
            // While the run is alive it may also be in the registry; keep our title for it.
            if merged[key] != nil { merged[key]?.title = run.title } else { merged[key] = run }
        }

        for (key, info) in hookInfo {
            if var session = merged[key] {
                if let activity = info.activity { session.activity = activity }
                if let message = info.lastMessage { session.lastMessage = message }
                // Hooks know about prompts the session registry doesn't; trust them unless they're older.
                if info.state.needsAttention, info.updatedAt > session.updatedAt.addingTimeInterval(-2) {
                    session.state = info.state
                } else if session.provider == .codex, info.updatedAt > session.updatedAt {
                    session.state = info.state
                }
                session.updatedAt = max(session.updatedAt, info.updatedAt)
                merged[key] = session
            } else if now.timeIntervalSince(info.updatedAt) < Self.hookOnlyLifetime,
                      let session = hookOnlySession(key: key, info: info, now: now) {
                merged[key] = session
            }
        }

        for approval in approvals {
            merged[approval.sessionKey]?.state = .needsApproval
        }
        for question in questions where merged[question.sessionKey]?.state != .needsApproval {
            merged[question.sessionKey]?.state = .waiting
        }

        let sorted = merged.values.sorted {
            if $0.state.needsAttention != $1.state.needsAttention { return $0.state.needsAttention }
            if ($0.state == .working) != ($1.state == .working) { return $0.state == .working }
            return $0.updatedAt > $1.updatedAt
        }

        announceTransitions(from: sessions, to: sorted)
        if sorted != sessions {
            withAnimation(.smooth) { sessions = sorted }
        }

        hookInfo = hookInfo.filter { now.timeIntervalSince($0.value.updatedAt) < Self.hookOnlyLifetime }
    }

    /// A session we only know from hook events (e.g. a headless run with no registry entry).
    private func hookOnlySession(key: String, info: HookInfo, now: Date) -> AgentSession? {
        let parts = key.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let provider = AgentProvider(rawValue: String(parts[0])) else { return nil }

        var state = info.state
        if state == .working, now.timeIntervalSince(info.updatedAt) > Self.stalledWorkLifetime { state = .idle }

        return AgentSession(
            provider: provider,
            sessionId: String(parts[1]),
            title: info.cwd.isEmpty ? provider.displayName : (info.cwd as NSString).lastPathComponent,
            cwd: info.cwd,
            state: state,
            activity: info.activity,
            lastMessage: info.lastMessage,
            updatedAt: info.updatedAt
        )
    }

    private func announceTransitions(from old: [AgentSession], to new: [AgentSession]) {
        let previous = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0.state) })
        var needsAttention = false

        for session in new {
            guard let before = previous[session.id], before != session.state else {
                if previous[session.id] == nil, session.state.needsAttention { needsAttention = true }
                continue
            }
            if session.state.needsAttention, !before.needsAttention {
                needsAttention = true
            } else if before == .working, session.state == .idle, Defaults[.agentsFinishedBanner] {
                show(AgentBanner(provider: session.provider, title: session.title,
                                 text: session.lastMessage.map { AgentText.oneLine($0, limit: 80) } ?? "Finished"))
            }
        }

        if needsAttention {
            NotificationCenter.default.post(name: .agentNeedsAttention, object: nil)
        }
    }

    private func show(_ banner: AgentBanner) {
        bannerTask?.cancel()
        withAnimation(.smooth) { self.banner = banner }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self?.banner = nil }
        }
    }

    // MARK: - Hook events

    private func handleHook(provider: AgentProvider, payload: [String: Any], wait: Int, requestID: UUID, reply: @escaping AgentHookServer.Reply) {
        guard let sessionId = payload["session_id"] as? String,
              let event = payload["hook_event_name"] as? String
        else {
            reply(nil)
            return
        }

        let key = AgentSession.key(provider, sessionId)
        var info = hookInfo[key] ?? HookInfo()
        if let cwd = payload["cwd"] as? String { info.cwd = cwd }
        info.updatedAt = .now

        let toolName = payload["tool_name"] as? String ?? ""
        let toolDetail = AgentText.toolDetail(name: toolName, input: payload["tool_input"] as? [String: Any])
        var holdsReply = false

        switch event {
        case "SessionStart":
            info.state = .idle
        case "UserPromptSubmit":
            info.state = .working
            info.activity = "Thinking…"
        case "PreToolUse" where toolName == AgentHookInstaller.questionTool:
            let toolInput = payload["tool_input"] as? [String: Any]
            let parsed = AgentQuestionRequest.questions(fromToolInput: toolInput)
            info.state = .waiting
            info.activity = AgentText.oneLine(parsed.first?.text ?? "Asking a question")
            // The same tool call also arrives through the short generic hook; only the long one can wait.
            if wait >= 60, !parsed.isEmpty, Defaults[.agentsAnswerQuestions] {
                pendingReplies[requestID] = reply
                questionInputs[requestID] = toolInput
                holdsReply = true
                questions.append(AgentQuestionRequest(id: requestID, sessionKey: key, questions: parsed))
            }
        case "PreToolUse":
            info.state = .working
            info.activity = AgentText.oneLine(toolDetail.isEmpty ? toolName : "\(toolName): \(toolDetail)")
        case "PermissionRequest" where toolName == AgentHookInstaller.questionTool:
            // Reached when the question was handed back to the agent; its own dialog collects the answer.
            info.state = .waiting
        case "PostToolUse", "PostToolUseFailure":
            info.state = .working
            dropApprovals(forSession: key)
        case "PermissionRequest":
            info.state = .needsApproval
            info.activity = AgentText.oneLine(toolDetail.isEmpty ? toolName : "\(toolName): \(toolDetail)")
            // When answering from the notch is off we only flag the session and let the agent prompt as usual.
            if Defaults[.agentsAnswerApprovals] {
                pendingReplies[requestID] = reply
                holdsReply = true
                approvals.append(AgentApprovalRequest(
                    id: requestID, sessionKey: key, provider: provider,
                    toolName: toolName, detail: toolDetail, receivedAt: .now))
            }
        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            if ["idle_prompt", "agent_needs_input", "elicitation_dialog", "permission_prompt"].contains(type) {
                info.state = .waiting
                if let message = payload["message"] as? String { info.activity = AgentText.oneLine(message) }
            }
        case "Stop":
            info.state = .idle
            info.activity = nil
            if let message = payload["last_assistant_message"] as? String, !message.isEmpty {
                info.lastMessage = AgentText.oneLine(message, limit: 600)
            }
            dropApprovals(forSession: key)
        case "SessionEnd":
            dropApprovals(forSession: key)
            hookInfo[key] = nil
            reply(nil)
            publish()
            return
        default:
            break
        }

        hookInfo[key] = info
        if !holdsReply { reply(nil) }
        publish()
    }

    // MARK: - Approvals

    func allow(_ approval: AgentApprovalRequest) { resolve(approval, allow: true) }
    func deny(_ approval: AgentApprovalRequest) { resolve(approval, allow: false) }

    /// `allow == nil` hands the decision back to the agent's own prompt.
    private func resolve(_ approval: AgentApprovalRequest, allow: Bool?) {
        guard let reply = pendingReplies.removeValue(forKey: approval.id) else { return }
        approvals.removeAll { $0.id == approval.id }

        if let allow {
            var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            if !allow { decision["message"] = "Denied from the notch." }
            let body: [String: Any] = [
                "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
            ]
            reply(try? JSONSerialization.data(withJSONObject: body))
            hookInfo[approval.sessionKey]?.state = .working
            hookInfo[approval.sessionKey]?.updatedAt = .now
        } else {
            reply(nil)
        }
        publish()
    }

    /// The hook went away before we answered: the prompt was answered elsewhere, so the session is moving again.
    private func dropRequest(_ id: UUID) {
        guard pendingReplies.removeValue(forKey: id) != nil else { return }
        questionInputs[id] = nil

        if let approval = approvals.first(where: { $0.id == id }) {
            approvals.removeAll { $0.id == id }
            if hookInfo[approval.sessionKey]?.state == .needsApproval {
                hookInfo[approval.sessionKey]?.state = .working
            }
        }
        if let question = questions.first(where: { $0.id == id }) {
            questions.removeAll { $0.id == id }
            if hookInfo[question.sessionKey]?.state == .waiting {
                hookInfo[question.sessionKey]?.state = .working
            }
        }
        publish()
    }

    private func dropApprovals(forSession key: String) {
        for approval in approvals where approval.sessionKey == key {
            pendingReplies.removeValue(forKey: approval.id)?(nil)
        }
        approvals.removeAll { $0.sessionKey == key }

        for question in questions where question.sessionKey == key {
            pendingReplies.removeValue(forKey: question.id)?(nil)
            questionInputs[question.id] = nil
        }
        questions.removeAll { $0.sessionKey == key }
    }

    // MARK: - Questions

    /// Sends the chosen answers back to the agent. `answers` maps each question's text to the
    /// chosen option label, with several labels joined by ", " for multi-select questions.
    func answer(_ question: AgentQuestionRequest, with answers: [String: String]) {
        guard let reply = pendingReplies.removeValue(forKey: question.id) else { return }
        var input = questionInputs.removeValue(forKey: question.id) ?? [:]
        questions.removeAll { $0.id == question.id }

        input["answers"] = answers
        let body: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
                "permissionDecisionReason": "Answered from the notch.",
                "updatedInput": input,
            ]
        ]
        reply(try? JSONSerialization.data(withJSONObject: body))
        hookInfo[question.sessionKey]?.state = .working
        hookInfo[question.sessionKey]?.activity = "Thinking…"
        hookInfo[question.sessionKey]?.updatedAt = .now
        publish()
    }

    /// Releases the question so the agent shows its own dialog instead.
    func answerInAgent(_ question: AgentQuestionRequest) {
        guard let reply = pendingReplies.removeValue(forKey: question.id) else { return }
        questionInputs[question.id] = nil
        questions.removeAll { $0.id == question.id }
        reply(nil)
        publish()
    }

    // MARK: - Actions

    /// Opens the notch on the Agents tab with the prompt field ready for typing.
    func openForTyping() {
        wantsPromptFocus = true
        NotificationCenter.default.post(name: .agentOpenRequested, object: nil)
    }

    func focus(_ session: AgentSession) {
        AgentCLI.focus(session)
    }

    /// Sends `prompt` as a follow-up to `session`, or starts a new task when `session` is nil.
    func send(_ prompt: String, to session: AgentSession?, provider: AgentProvider, directory: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        lastError = nil

        let provider = session?.provider ?? provider
        let directory = session.map(\.cwd) ?? directory
        var arguments = session.map { AgentCLI.followUpArguments($0, prompt: prompt) }
            ?? AgentCLI.newTaskArguments(provider, prompt: prompt, directory: directory)

        // Claude runs get a known session id so their hook events land on the row we show for them.
        var runKey: String?
        if provider == .claude {
            let runID = UUID().uuidString.lowercased()
            arguments += ["--session-id", runID]
            let key = AgentSession.key(.claude, runID)
            localRuns[key] = AgentSession(
                provider: .claude, sessionId: runID,
                title: AgentText.oneLine(session.map { "↩ \($0.title): \(prompt)" } ?? prompt, limit: 80),
                cwd: directory, state: .working, activity: "Starting…", updatedAt: .now, host: "notch")
            runKey = key
            publish()
        }
        if session == nil { Defaults[.agentsLastDirectory] = directory }

        Task {
            let result = await AgentCLI.run(provider, arguments: arguments, directory: directory) { process in
                Task { @MainActor in
                    if let runKey { self.runProcesses[runKey] = process }
                }
            }

            if let runKey {
                runProcesses[runKey] = nil
                // Dismissed while running: it was stopped on purpose, so there is nothing to report.
                guard localRuns[runKey] != nil else { return }
                localRuns[runKey]?.state = .idle
                localRuns[runKey]?.activity = nil
                localRuns[runKey]?.updatedAt = .now
                if !result.output.isEmpty {
                    localRuns[runKey]?.lastMessage = AgentText.oneLine(result.output, limit: 600)
                }
            }
            if result.status != 0 {
                let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
                lastError = AgentText.oneLine("\(provider.shortName) exited with \(result.status). \(detail)", limit: 240)
                if let runKey { localRuns[runKey]?.lastMessage = lastError }
            }
            publish()
        }
    }

    /// Removes a notch-started task from the list, stopping it if it is still running.
    func dismiss(_ session: AgentSession) {
        runProcesses.removeValue(forKey: session.id)?.terminate()
        localRuns[session.id] = nil
        hookInfo[session.id] = nil
        publish()
    }

    func isLocalRun(_ session: AgentSession) -> Bool {
        localRuns[session.id] != nil
    }
}
