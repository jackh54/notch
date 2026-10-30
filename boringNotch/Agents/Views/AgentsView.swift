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

    /// The row matching the right-hand pane; a pending request takes over that pane.
    private var highlightedID: String? {
        agents.currentRequest?.sessionKey ?? selected?.id
    }

    private var replyTarget: AgentSession? {
        agents.sessions.first { $0.id == replyTargetID }
    }

    private var directory: String {
        lastDirectory.isEmpty ? AgentPaths.home.path : lastDirectory
    }

    var body: some View {
        VStack(spacing: 8) {
            if agents.sessions.isEmpty && agents.currentRequest == nil {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 10) {
                    sessionList
                    if let request = agents.currentRequest {
                        AgentRequestPane(request: request)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if let selected {
                        AgentDetailView(session: selected, onReply: { beginReply(to: selected) })
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
        .onAppear {
            agents.requestViewAppeared()
            focusPromptIfRequested()
        }
        .onChange(of: agents.wantsPromptFocus) { focusPromptIfRequested() }
        .onDisappear {
            agents.requestViewDisappeared()
            agents.isComposing = false
        }
    }

    // MARK: - Sessions

    private var sessionList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 2) {
                ForEach(agents.sessions) { session in
                    AgentSessionRow(session: session, isSelected: session.id == highlightedID)
                        .onTapGesture {
                            selectedID = session.id
                            agents.showRequest(for: session)
                        }
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
