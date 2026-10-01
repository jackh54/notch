//
//  AgentsView.swift
//  boringNotch
//
//  The open-notch tab for Claude Code and Codex sessions.
//

import Defaults
import SwiftUI

struct AgentsView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var agents = AgentManager.shared

    @State private var selectedID: String?
    @State private var replyTargetID: String?
    @State private var prompt: String = ""
    @FocusState private var promptFocused: Bool

    @Default(.agentsNewTaskProvider) private var newTaskProvider
    @Default(.agentsLastDirectory) private var lastDirectory

    private var selected: AgentSession? {
        agents.sessions.first { $0.id == selectedID } ?? agents.primarySession ?? agents.sessions.first
    }

    private var replyTarget: AgentSession? {
        agents.sessions.first { $0.id == replyTargetID }
    }

    private var directory: String {
        lastDirectory.isEmpty ? AgentPaths.home.path : lastDirectory
    }

    var body: some View {
        VStack(spacing: 8) {
            if agents.sessions.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 10) {
                    sessionList
                    if let selected {
                        AgentDetailView(
                            session: selected,
                            approval: agents.approval(for: selected),
                            question: agents.question(for: selected),
                            onReply: { beginReply(to: selected) }
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            promptBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: promptFocused) { _, focused in
            agents.isComposing = focused
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // Typing moved elsewhere: release the notch so it can close normally.
            guard promptFocused else { return }
            promptFocused = false
            agents.isComposing = false
            vm.close()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentNeedsAttention)) { _ in
            // Show the session that needs the user rather than whatever was selected before.
            selectedID = nil
        }
        .onAppear(perform: focusPromptIfRequested)
        .onChange(of: agents.wantsPromptFocus) { focusPromptIfRequested() }
        .onDisappear {
            agents.isComposing = false
        }
    }

    // MARK: - Sessions

    private var sessionList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(agents.sessions) { session in
                    AgentSessionRow(session: session, isSelected: session.id == selected?.id)
                        .onTapGesture { selectedID = session.id }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(width: agents.hasPendingRequests ? 190 : 250)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkle")
                .imageScale(.large)
                .foregroundStyle(.gray)
            Text("No active Claude Code or Codex sessions")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Prompt

    private var promptBar: some View {
        HStack(spacing: 8) {
            if let replyTarget {
                HStack(spacing: 4) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                    Text(replyTarget.title).lineLimit(1)
                    Button {
                        replyTargetID = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
                .foregroundStyle(replyTarget.provider.tint)
                .frame(maxWidth: 170)
            } else {
                newTaskMenus
            }

            TextField(placeholder, text: $prompt)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .rounded))
                .focused($promptFocused)
                .onSubmit(submit)
                .onExitCommand {
                    promptFocused = false
                    vm.close()
                }

            if let error = agents.lastError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help(error)
            }

            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .imageScale(.large)
            }
            .buttonStyle(.plain)
            .foregroundStyle(prompt.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .white)
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    private var newTaskMenus: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(AgentProvider.allCases) { provider in
                    Button(provider.displayName) { newTaskProvider = provider }
                }
            } label: {
                Label(newTaskProvider.shortName, systemImage: newTaskProvider.icon)
                    .foregroundStyle(newTaskProvider.tint)
            }

            Menu {
                ForEach(agents.knownDirectories, id: \.self) { path in
                    Button(path.replacingOccurrences(of: AgentPaths.home.path, with: "~")) { lastDirectory = path }
                }
                Divider()
                Button("Home folder") { lastDirectory = AgentPaths.home.path }
            } label: {
                Label((directory as NSString).lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .font(.caption)
        .fixedSize()
    }

    private var placeholder: String {
        if let replyTarget {
            return replyTarget.provider == .claude ? "Ask a follow-up (runs in a fork)…" : "Queue a message…"
        }
        return "New \(newTaskProvider.shortName) task…"
    }

    private func focusPromptIfRequested() {
        guard agents.wantsPromptFocus else { return }
        agents.wantsPromptFocus = false
        // The notch panel only takes key focus on demand, so ask for it before focusing the field.
        NSApp.windows.first { $0 is BoringNotchSkyLightWindow && $0.isVisible }?.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            promptFocused = true
        }
    }

    private func beginReply(to session: AgentSession) {
        replyTargetID = session.id
        promptFocused = true
    }

    private func submit() {
        agents.send(prompt, to: replyTarget, provider: newTaskProvider, directory: directory)
        prompt = ""
        replyTargetID = nil
    }
}

// MARK: - Row

struct AgentSessionRow: View {
    let session: AgentSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            AgentStateIndicator(state: session.state)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: session.provider.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(session.provider.tint)
                    Text(session.title)
                        .font(.system(.caption, design: .rounded).weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Text(session.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if session.state == .idle {
                Text(session.age())
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(.gray.opacity(0.7))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
    }
}

struct AgentStateIndicator: View {
    let state: AgentSessionState

    var body: some View {
        switch state {
        case .working:
            Image(systemName: "circle.dotted")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(state.color)
                .symbolEffect(.variableColor.iterative, options: .repeating)
        case .needsApproval, .waiting:
            Circle()
                .fill(state.color)
                .frame(width: 7, height: 7)
                .shadow(color: state.color.opacity(0.8), radius: 3)
        case .idle:
            Circle()
                .fill(state.color.opacity(0.5))
                .frame(width: 6, height: 6)
        }
    }
}

// MARK: - Detail

struct AgentDetailView: View {
    let session: AgentSession
    let approval: AgentApprovalRequest?
    let question: AgentQuestionRequest?
    let onReply: () -> Void

    @ObservedObject var agents = AgentManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(session.state.label)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(session.state.color)
                Text(session.projectName)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                Spacer(minLength: 0)
                actionButtons
            }

            if let approval {
                approvalCard(approval)
            } else if let question {
                AgentQuestionCard(request: question)
                    .id(question.id)
            } else {
                ScrollView(.vertical) {
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var detailText: String {
        if session.state == .working || session.state == .waiting, let activity = session.activity, !activity.isEmpty {
            return activity
        }
        return session.lastMessage ?? session.cwd.replacingOccurrences(of: AgentPaths.home.path, with: "~")
    }

    private var actionButtons: some View {
        HStack(spacing: 4) {
            if agents.isLocalRun(session) {
                iconButton("xmark", help: session.state == .idle ? "Dismiss" : "Stop and dismiss") {
                    agents.dismiss(session)
                }
            } else {
                iconButton("arrowshape.turn.up.left", help: session.provider == .claude
                           ? "Ask a follow-up in a fork of this session"
                           : "Queue a message to this thread", action: onReply)
                iconButton("arrow.up.forward.app", help: "Open") { agents.focus(session) }
            }
        }
    }

    private func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(help)
    }

    private func approvalCard(_ approval: AgentApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) {
                (Text(approval.toolName).fontWeight(.bold).foregroundStyle(.white)
                    + Text(approval.detail.isEmpty ? "" : "  \(approval.detail)"))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.never)

            HStack(spacing: 6) {
                Button("Deny") { agents.deny(approval) }
                    .buttonStyle(AgentPillButtonStyle(color: .white.opacity(0.15)))
                Button("Allow") { agents.allow(approval) }
                    .buttonStyle(AgentPillButtonStyle(color: .green.opacity(0.7)))
            }
        }
    }
}

struct AgentPillButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(color.opacity(configuration.isPressed ? 0.6 : 1), in: Capsule())
    }
}

// MARK: - Question

/// Walks through an agent's questions one at a time and sends the answers back.
struct AgentQuestionCard: View {
    let request: AgentQuestionRequest

    @ObservedObject var agents = AgentManager.shared
    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []

    private var current: AgentQuestion { request.questions[min(index, request.questions.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if request.questions.count > 1 {
                    Text("\(index + 1)/\(request.questions.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray)
                }
                Text(current.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView(.vertical) {
                VStack(spacing: 5) {
                    ForEach(current.options, id: \.label) { option in
                        optionRow(option)
                    }
                }
            }
            .scrollIndicators(.never)

            HStack(spacing: 6) {
                Button("Answer in Claude") { agents.answerInAgent(request) }
                    .buttonStyle(AgentPillButtonStyle(color: .white.opacity(0.15)))
                if current.multiSelect {
                    Button(index + 1 < request.questions.count ? "Next" : "Send") {
                        choose(current.options.map(\.label).filter(picked.contains).joined(separator: ", "))
                    }
                    .buttonStyle(AgentPillButtonStyle(color: .green.opacity(0.7)))
                    .disabled(picked.isEmpty)
                    .opacity(picked.isEmpty ? 0.5 : 1)
                }
            }
        }
    }

    private func optionRow(_ option: AgentQuestion.Option) -> some View {
        let isPicked = picked.contains(option.label)
        return Button {
            if current.multiSelect {
                if isPicked { picked.remove(option.label) } else { picked.insert(option.label) }
            } else {
                choose(option.label)
            }
        } label: {
            HStack(spacing: 8) {
                if current.multiSelect {
                    Image(systemName: isPicked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !option.detail.isEmpty {
                        Text(option.detail)
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.white.opacity(isPicked ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .help(option.detail)
    }

    /// Records the answer to the current question and moves on, sending everything after the last one.
    private func choose(_ answer: String) {
        answers[current.text] = answer
        picked = []
        if index + 1 < request.questions.count {
            index += 1
        } else {
            agents.answer(request, with: answers)
        }
    }
}
