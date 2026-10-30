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
    @Published private(set) var approvals: [AgentApprovalRequest] = [] {
        didSet { refreshCurrentRequest() }
    }
    @Published private(set) var questions: [AgentQuestionRequest] = [] {
        didSet { refreshCurrentRequest() }
    }
    /// The request on screen. The card and the keyboard shortcuts both act on this one.
    @Published private(set) var currentRequest: AgentRequest?
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
        var fullMessage: String?
        var updatedAt: Date = .now
        var turnStartedAt: Date?
        var recentTools: [AgentToolCall] = []
        var subagentCount = 0
        var transcriptPath: String?
    }

    private var hookInfo: [String: HookInfo] = [:]
    private var polled: [AgentSession] = []
    /// Headless tasks started from the notch, keyed by session key.
    private var localRuns: [String: AgentSession] = [:]
    private var pendingReplies: [UUID: AgentHookServer.Reply] = [:]
    /// The original tool input of each pending question, echoed back with the answers.
    private var questionInputs: [UUID: [String: Any]] = [:]
    private var runProcesses: [String: Process] = [:]
    /// Usage of sessions the registry doesn't list, read from the transcript their hooks named.
    private var hookUsage: [String: AgentTokenUsage] = [:]
    /// The last usage seen per session, so only new tokens count as flow.
    private var usageBaselines: [String: AgentTokenUsage] = [:]
    private var usageSamples: [String: [(date: Date, tokens: Int)]] = [:]
    /// The request the user stepped to, if they moved away from the oldest one.
    private var focusedRequestID: UUID?
    private var requestShownAt: Date = .distantPast
    /// How many Agents tabs are on screen; there can be one per display.
    private var requestViewers = 0

    private let server = AgentHookServer()
    private var pollTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var queuedBanners: [AgentBanner] = []
    /// Notch-started runs that exited with an error, announced as failures.
    private var failedRuns: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    private static let hookOnlyLifetime: TimeInterval = 15 * 60
    private static let stalledWorkLifetime: TimeInterval = 10 * 60
    /// Input is ignored for this long after a card appears, so a click aimed at the previous card can't land on it.
    private static let requestArmDelay: TimeInterval = 0.4
    private static let recentToolLimit = 5
    private static let usageRateWindow: TimeInterval = 60
    private static let bannerDuration: Duration = .seconds(6)

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
                let transcripts = self?.hookTranscripts ?? [:]
                let (loaded, usage) = await Task.detached(priority: .utility) {
                    let sessions = ClaudeSessionSource.load() + CodexSessionSource.load()
                    let polledKeys = Set(sessions.map(\.id))
                    let usage = transcripts.filter { !polledKeys.contains($0.key) }
                        .mapValues { AgentUsageReader.claudeUsage(transcript: URL(fileURLWithPath: $0)) }
                    return (sessions, usage)
                }.value
                guard !Task.isCancelled else { return }
                self?.polled = loaded
                self?.hookUsage = usage
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

    var workingProviders: Set<AgentProvider> {
        Set(sessions.filter { $0.state == .working }.map(\.provider))
    }

    /// The token figure for the closed notch, covering every working session.
    func closedReadout(_ readout: AgentTokenReadout) -> String? {
        let working = sessions.filter { $0.state == .working }
        switch readout {
        case .off:
            return nil
        case .perMinute:
            let rate = working.reduce(0) { $0 + $1.tokensPerMinute }
            return rate > 0 ? "\(AgentText.tokens(rate))/m" : nil
        case .sessionTotal:
            let includeCached = Defaults[.agentsCountCachedTokens]
            let total = working.reduce(0) { $0 + $1.usage.total(includingCached: includeCached) }
            return total > 0 ? AgentText.tokens(total) : nil
        }
    }

    /// Whether the closed notch should show the agent indicator.
    var hasLiveActivity: Bool {
        Defaults[.enableAgents] && Defaults[.agentsLiveActivity] && (attentionCount > 0 || workingCount > 0)
    }

    /// The session the closed notch represents: the one that most needs the user.
    var primarySession: AgentSession? {
        sessions.first { $0.state.needsAttention } ?? sessions.first { $0.state == .working }
    }

    /// True while an agent is blocked on an answer from the notch.
    var hasPendingRequests: Bool { !approvals.isEmpty || !questions.isEmpty }

    /// Everything agents are blocked on, oldest first. New requests queue behind the one on screen.
    var pendingRequests: [AgentRequest] {
        (approvals.map(AgentRequest.approval) + questions.map(AgentRequest.question))
            .sorted { $0.receivedAt < $1.receivedAt }
    }

    /// False just after a card appears; see `requestArmDelay`.
    var requestIsArmed: Bool {
        Date().timeIntervalSince(requestShownAt) >= Self.requestArmDelay
    }

    private func refreshCurrentRequest() {
        let pending = pendingRequests
        let next = pending.first { $0.id == focusedRequestID } ?? pending.first
        if next?.id != currentRequest?.id { requestShownAt = .now }
        currentRequest = next
    }

    /// Steps through the queue, wrapping at either end.
    func showRequest(offset: Int) {
        let pending = pendingRequests
        guard let currentID = currentRequest?.id,
              let index = pending.firstIndex(where: { $0.id == currentID })
        else { return }
        focusedRequestID = pending[(index + offset + pending.count) % pending.count].id
        refreshCurrentRequest()
    }

    /// Brings up the request `session` is blocked on, if it has one.
    func showRequest(for session: AgentSession) {
        guard let request = pendingRequests.first(where: { $0.sessionKey == session.id }) else { return }
        focusedRequestID = request.id
        refreshCurrentRequest()
    }

    func requestViewAppeared() { requestViewers += 1 }
    func requestViewDisappeared() { requestViewers = max(0, requestViewers - 1) }

    /// The shortcuts answer the card on screen. With no card showing they open it instead,
    /// so nothing is ever approved unseen.
    func allowCurrentRequest() { decideCurrentRequest(using: allow) }
    func denyCurrentRequest() { decideCurrentRequest(using: deny) }

    private func decideCurrentRequest(using decide: (AgentApprovalRequest) -> Void) {
        guard case .approval(let approval) = currentRequest else { return }
        guard requestViewers > 0 else {
            NotificationCenter.default.post(name: .agentOpenRequested, object: nil)
            return
        }
        decide(approval)
    }

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

    /// Claude transcripts learned from hooks, for sessions that may never reach the registry.
    private var hookTranscripts: [String: String] {
        hookInfo.compactMapValues(\.transcriptPath)
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
                if let message = info.fullMessage { session.fullMessage = message }
                if let started = info.turnStartedAt { session.turnStartedAt = started }
                session.recentTools = info.recentTools
                session.subagentCount = info.subagentCount
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

        for key in merged.keys {
            if merged[key]?.usage == AgentTokenUsage(), let usage = hookUsage[key] { merged[key]?.usage = usage }
            if merged[key]?.state == .idle { merged[key]?.turnStartedAt = nil }
        }
        recordUsage(&merged, now: now)

        // Sessions with a request keep their queue position so rows don't move under the pointer.
        var requestOrder: [String: Int] = [:]
        for (index, request) in pendingRequests.enumerated() where requestOrder[request.sessionKey] == nil {
            requestOrder[request.sessionKey] = index
        }

        let sorted = merged.values.sorted {
            let leftOrder = requestOrder[$0.id] ?? .max
            let rightOrder = requestOrder[$1.id] ?? .max
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if $0.state.needsAttention != $1.state.needsAttention { return $0.state.needsAttention }
            if ($0.state == .working) != ($1.state == .working) { return $0.state == .working }
            // Working rows sort by when they started, which unlike updatedAt doesn't change on every tool call.
            return ($0.turnStartedAt ?? $0.updatedAt) > ($1.turnStartedAt ?? $1.updatedAt)
        }

        announceTransitions(from: sessions, to: sorted)
        if sorted != sessions {
            withAnimation(.smooth) { sessions = sorted }
        }

        hookInfo = hookInfo.filter { now.timeIntervalSince($0.value.updatedAt) < Self.hookOnlyLifetime }
    }

    /// Turns growth in each session's usage into a rate and into tokens for the particle stream.
    private func recordUsage(_ sessions: inout [String: AgentSession], now: Date) {
        let includeCached = Defaults[.agentsCountCachedTokens]
        for (key, session) in sessions where session.usage != AgentTokenUsage() {
            let delta = session.usage.removing(usageBaselines[key] ?? session.usage)
            usageBaselines[key] = session.usage

            let tokens = delta.total(includingCached: includeCached)
            if tokens > 0 {
                usageSamples[key, default: []].append((now, tokens))
                AgentTokenFlow.shared.add(tokens, from: session.provider)
            }
            let recent = (usageSamples[key] ?? []).filter { now.timeIntervalSince($0.date) < Self.usageRateWindow }
            usageSamples[key] = recent
            sessions[key]?.tokensPerMinute = recent.reduce(0) { $0 + $1.tokens }
        }
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
            updatedAt: info.updatedAt,
            turnStartedAt: info.turnStartedAt,
            recentTools: info.recentTools,
            subagentCount: info.subagentCount,
            fullMessage: info.fullMessage
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
            } else if before == .working, session.state == .idle {
                let failed = failedRuns.remove(session.id) != nil
                if Defaults[.agentsFinishedBanner] {
                    show(AgentBanner(
                        sessionKey: session.id, provider: session.provider, title: session.title,
                        text: session.lastMessage.map { AgentText.oneLine($0, limit: 80) } ?? "Finished",
                        outcome: failed ? .failed : .finished))
                }
                playSound(failed ? Self.failedSound : Self.finishedSound)
            }
        }

        if needsAttention {
            NotificationCenter.default.post(name: .agentNeedsAttention, object: nil)
            playSound(Self.attentionSound)
        }
    }

    private static let attentionSound = "Ping"
    private static let finishedSound = "Glass"
    private static let failedSound = "Basso"

    private func playSound(_ name: String) {
        guard Defaults[.agentsSounds] else { return }
        NSSound(named: name)?.play()
    }

    /// Banners take turns, so sessions finishing together are all announced.
    private func show(_ banner: AgentBanner) {
        guard self.banner == nil else {
            queuedBanners.append(banner)
            return
        }
        withAnimation(.smooth) { self.banner = banner }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.smooth) { self.banner = nil }
            if !self.queuedBanners.isEmpty { self.show(self.queuedBanners.removeFirst()) }
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
        if provider == .claude, let path = payload["transcript_path"] as? String { info.transcriptPath = path }
        info.updatedAt = .now

        let toolName = payload["tool_name"] as? String ?? ""
        let toolInput = payload["tool_input"] as? [String: Any]
        let toolDetail = AgentText.toolDetail(name: toolName, input: toolInput)
        let toolUseID = payload["tool_use_id"] as? String
        var holdsReply = false

        switch event {
        case "SessionStart":
            info.state = .idle
        case "UserPromptSubmit":
            info.state = .working
            info.activity = "Thinking…"
            info.turnStartedAt = .now
            info.recentTools = []
            info.subagentCount = 0
        case "PreToolUse" where toolName == AgentHookInstaller.questionTool:
            let parsed = AgentQuestionRequest.questions(fromToolInput: toolInput)
            info.state = .waiting
            info.activity = AgentText.oneLine(parsed.first?.text ?? "Asking a question")
            // The same tool call also arrives through the short generic hook; only the long one can wait.
            if wait >= 60, !parsed.isEmpty, Defaults[.agentsAnswerQuestions] {
                pendingReplies[requestID] = reply
                questionInputs[requestID] = toolInput
                holdsReply = true
                questions.append(AgentQuestionRequest(id: requestID, sessionKey: key, questions: parsed, receivedAt: .now))
            }
        case "PreToolUse":
            info.state = .working
            info.activity = AgentText.oneLine(toolDetail.isEmpty ? toolName : "\(toolName): \(toolDetail)")
            info.recentTools.append(AgentToolCall(
                id: UUID(), toolUseID: toolUseID, name: toolName,
                detail: AgentText.oneLine(toolDetail, limit: 120), startedAt: .now))
            info.recentTools.removeFirst(max(0, info.recentTools.count - Self.recentToolLimit))
        case "PermissionRequest" where toolName == AgentHookInstaller.questionTool:
            // Reached when the question was handed back to the agent; its own dialog collects the answer.
            info.state = .waiting
        case "PostToolUse", "PostToolUseFailure":
            info.state = .working
            dropApprovals(forSession: key)
            let call = info.recentTools.lastIndex { $0.finishedAt == nil && $0.toolUseID == toolUseID && toolUseID != nil }
                ?? info.recentTools.lastIndex { $0.finishedAt == nil && $0.name == toolName }
            if let call {
                info.recentTools[call].finishedAt = .now
                info.recentTools[call].failed = event == "PostToolUseFailure"
            }
        case "SubagentStart":
            info.subagentCount += 1
        case "SubagentStop":
            info.subagentCount = max(0, info.subagentCount - 1)
        case "PermissionRequest":
            info.state = .needsApproval
            info.activity = AgentText.oneLine(toolDetail.isEmpty ? toolName : "\(toolName): \(toolDetail)")
            // When answering from the notch is off we only flag the session and let the agent prompt as usual.
            if Defaults[.agentsAnswerApprovals] {
                pendingReplies[requestID] = reply
                holdsReply = true
                approvals.append(AgentApprovalRequest(
                    id: requestID, sessionKey: key, provider: provider,
                    toolName: toolName, detail: toolDetail,
                    preview: AgentToolPreview(input: toolInput, detail: toolDetail),
                    sessionRules: provider == .claude ? AgentPermissionRule.rules(
                        fromSuggestions: payload["permission_suggestions"] as? [[String: Any]]) : [],
                    receivedAt: .now))
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
            info.turnStartedAt = nil
            info.subagentCount = 0
            if let message = payload["last_assistant_message"] as? String, !message.isEmpty {
                info.lastMessage = AgentText.oneLine(message, limit: 600)
                info.fullMessage = AgentText.clipped(message)
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

    func allow(_ approval: AgentApprovalRequest) {
        guard requestIsArmed else { return }
        resolve(approval, allow: true)
    }

    func deny(_ approval: AgentApprovalRequest) {
        guard requestIsArmed else { return }
        resolve(approval, allow: false)
    }

    /// Allows this call and adds Claude's suggested rules for the rest of the session.
    /// The destination is always "session", so nothing is written to settings files.
    func allowForSession(_ approval: AgentApprovalRequest) {
        guard requestIsArmed, !approval.sessionRules.isEmpty else { return }
        resolve(approval, allow: true, sessionRules: approval.sessionRules)
    }

    /// `allow == nil` hands the decision back to the agent's own prompt.
    private func resolve(_ approval: AgentApprovalRequest, allow: Bool?, sessionRules: [AgentPermissionRule] = []) {
        guard let reply = pendingReplies.removeValue(forKey: approval.id) else { return }
        approvals.removeAll { $0.id == approval.id }

        if let allow {
            var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            if !allow { decision["message"] = "Denied from the notch." }
            if !sessionRules.isEmpty {
                let rules = sessionRules.map { rule -> [String: Any] in
                    var entry: [String: Any] = ["toolName": rule.toolName]
                    entry["ruleContent"] = rule.ruleContent
                    return entry
                }
                decision["updatedPermissions"] = [[
                    "type": "addRules", "rules": rules, "behavior": "allow", "destination": "session",
                ] as [String: Any]]
            }
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

    /// The notch panel only takes key focus on demand, so text fields ask for it first.
    func makeNotchKey() {
        NSApp.windows.first { $0 is BoringNotchSkyLightWindow && $0.isVisible }?.makeKey()
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
                cwd: directory, state: .working, activity: "Starting…", updatedAt: .now, host: "notch",
                turnStartedAt: .now)
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
                    localRuns[runKey]?.fullMessage = AgentText.clipped(result.output)
                }
            }
            if result.status != 0 {
                let detail = result.errorOutput.isEmpty ? result.output : result.errorOutput
                lastError = AgentText.oneLine("\(provider.shortName) exited with \(result.status). \(detail)", limit: 240)
                if let runKey {
                    localRuns[runKey]?.lastMessage = lastError
                    failedRuns.insert(runKey)
                }
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

    #if DEBUG
    /// Replaces the published state for rendering snapshots.
    func loadFixture(
        sessions: [AgentSession], approvals: [AgentApprovalRequest] = [],
        questions: [AgentQuestionRequest] = [], error: String? = nil
    ) {
        self.sessions = sessions
        self.approvals = approvals
        self.questions = questions
        lastError = error
        requestShownAt = .distantPast
    }
    #endif
}
