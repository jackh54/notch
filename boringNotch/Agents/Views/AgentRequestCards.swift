//
//  AgentRequestCards.swift
//  boringNotch
//
//  The cards for answering an agent's permission prompts and questions.
//

import KeyboardShortcuts
import SwiftUI

/// Shows the request at the front of the queue and how many more are behind it.
struct AgentRequestPane: View {
    let request: AgentRequest

    @ObservedObject var agents = AgentManager.shared

    private var session: AgentSession? {
        agents.sessions.first { $0.id == request.sessionKey }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            switch request {
            case .approval(let approval):
                AgentApprovalCard(approval: approval)
                    .id(approval.id)
            case .question(let question):
                AgentQuestionCard(request: question)
                    .id(question.id)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(stateLabel)
                .font(.system(.caption2, design: .rounded).weight(.semibold))
                .foregroundStyle(stateColor)
            if let session {
                Text(session.title)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            AgentRequestCountdown(receivedAt: request.receivedAt)
            pager
        }
    }

    private var stateLabel: String {
        if case .approval = request { return AgentSessionState.needsApproval.label }
        return AgentSessionState.waiting.label
    }

    private var stateColor: Color {
        if case .approval = request { return AgentSessionState.needsApproval.color }
        return AgentSessionState.waiting.color
    }

    @ViewBuilder
    private var pager: some View {
        let pending = agents.pendingRequests
        if pending.count > 1, let index = pending.firstIndex(where: { $0.id == request.id }) {
            HStack(spacing: 4) {
                pagerButton("chevron.left", offset: -1)
                Text("\(index + 1) of \(pending.count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                pagerButton("chevron.right", offset: 1)
            }
        }
    }

    private func pagerButton(_ icon: String, offset: Int) -> some View {
        Button {
            agents.showRequest(offset: offset)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.gray)
    }
}

/// Time left before the hook gives up and the agent shows its own prompt.
struct AgentRequestCountdown: View {
    let receivedAt: Date

    private static let urgentSeconds = 30

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let deadline = receivedAt.addingTimeInterval(TimeInterval(AgentHookInstaller.approvalTimeout))
            let remaining = max(0, Int(deadline.timeIntervalSince(context.date)))
            Text("\(remaining / 60):\(String(format: "%02d", remaining % 60))")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(remaining <= Self.urgentSeconds ? .orange : .gray)
                .help("Time left before the agent falls back to its own prompt")
        }
    }
}

struct AgentApprovalCard: View {
    let approval: AgentApprovalRequest

    @ObservedObject var agents = AgentManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) {
                AgentToolPreviewView(toolName: approval.toolName, preview: approval.preview)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.never)

            if !approval.sessionRules.isEmpty {
                Text("For session adds \(approval.sessionRules.map(\.label).joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 6) {
                Button { agents.deny(approval) } label: {
                    AgentShortcutLabel("Deny", shortcut: .denyAgentRequest)
                }
                .buttonStyle(AgentPillButtonStyle(color: .white.opacity(0.15)))

                if !approval.sessionRules.isEmpty {
                    Button("For session") { agents.allowForSession(approval) }
                        .buttonStyle(AgentPillButtonStyle(color: .white.opacity(0.15)))
                }

                Button { agents.allow(approval) } label: {
                    AgentShortcutLabel("Allow", shortcut: .allowAgentRequest)
                }
                .buttonStyle(AgentPillButtonStyle(color: .green.opacity(0.7)))
            }
        }
    }
}

/// What a tool call will do, laid out for its kind of tool.
struct AgentToolPreviewView: View {
    let toolName: String
    let preview: AgentToolPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch preview {
            case .command(let command):
                title(toolName)
                codeBlock(command)
            case .edit(let path, let old, let new):
                title(AgentText.abbreviated(path: path))
                AgentDiffView(old: old, new: new)
            case .write(let path, let lineCount):
                title(AgentText.abbreviated(path: path))
                caption(lineCount == 1 ? "Writes 1 line" : "Writes \(lineCount) lines")
            case .web(let url):
                title(URL(string: url)?.host ?? url)
                caption(url)
            case .generic(let detail):
                title(toolName)
                if !detail.isEmpty { codeBlock(detail) }
            }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.gray)
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// A compact diff of an edit. Lines common to both ends are left out.
struct AgentDiffView: View {
    let old: String
    let new: String

    private var changes: (removed: [String], added: [String]) {
        var removed = old.components(separatedBy: "\n")
        var added = new.components(separatedBy: "\n")
        while let first = removed.first, first == added.first {
            removed.removeFirst()
            added.removeFirst()
        }
        while let last = removed.last, last == added.last {
            removed.removeLast()
            added.removeLast()
        }
        return (removed, added)
    }

    var body: some View {
        let changes = changes
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(changes.removed.enumerated()), id: \.offset) { _, line in
                row("−", line, color: .red)
            }
            ForEach(Array(changes.added.enumerated()), id: \.offset) { _, line in
                row("+", line, color: .green)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ marker: String, _ line: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(marker)
                .foregroundStyle(color)
            Text(line)
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(0.14))
    }
}

/// A button title with the keyboard shortcut that does the same thing.
private struct AgentShortcutLabel: View {
    let title: LocalizedStringKey
    let shortcut: KeyboardShortcuts.Name

    init(_ title: LocalizedStringKey, shortcut: KeyboardShortcuts.Name) {
        self.title = title
        self.shortcut = shortcut
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if let hint = KeyboardShortcuts.getShortcut(for: shortcut)?.description {
                Text(hint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .opacity(0.6)
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

/// Walks through an agent's questions one at a time and sends the answers back.
struct AgentQuestionCard: View {
    let request: AgentQuestionRequest

    @ObservedObject var agents = AgentManager.shared
    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []
    @State private var isTypingOther = false
    @State private var otherText = ""
    @FocusState private var otherFocused: Bool

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

            if isTypingOther {
                TextField("Your answer…", text: $otherText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($otherFocused)
                    .onSubmit(chooseCurrent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 6) {
                Button("Answer in Claude") { agents.answerInAgent(request) }
                    .buttonStyle(AgentPillButtonStyle(color: .white.opacity(0.15)))
                if !isTypingOther {
                    Button("Other…", action: beginTypingOther)
                        .buttonStyle(AgentPillButtonStyle(color: .white.opacity(0.15)))
                }
                if current.multiSelect || isTypingOther {
                    Button(index + 1 < request.questions.count ? "Next" : "Send", action: chooseCurrent)
                        .buttonStyle(AgentPillButtonStyle(color: .green.opacity(0.7)))
                        .disabled(currentAnswer.isEmpty)
                        .opacity(currentAnswer.isEmpty ? 0.5 : 1)
                }
            }
        }
        .onChange(of: otherFocused) { _, focused in
            agents.isComposing = focused
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // Typing moved elsewhere: release the notch so it can close normally.
            otherFocused = false
        }
        .onDisappear {
            if otherFocused { agents.isComposing = false }
        }
    }

    private var typedAnswer: String {
        otherText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The picked labels in option order, followed by anything typed.
    private var currentAnswer: String {
        let labels = current.options.map(\.label).filter(picked.contains)
        return (labels + (isTypingOther && !typedAnswer.isEmpty ? [typedAnswer] : [])).joined(separator: ", ")
    }

    private func chooseCurrent() {
        guard !currentAnswer.isEmpty else { return }
        choose(currentAnswer)
    }

    private func beginTypingOther() {
        guard agents.requestIsArmed else { return }
        isTypingOther = true
        agents.makeNotchKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            otherFocused = true
        }
    }

    private func optionRow(_ option: AgentQuestion.Option) -> some View {
        let isPicked = picked.contains(option.label)
        return Button {
            guard agents.requestIsArmed else { return }
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
        isTypingOther = false
        otherText = ""
        otherFocused = false
        if index + 1 < request.questions.count {
            index += 1
        } else {
            agents.answer(request, with: answers)
        }
    }
}
