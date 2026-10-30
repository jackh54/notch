//
//  AgentDetailView.swift
//  boringNotch
//
//  The right-hand pane of the Agents tab for a session with nothing pending.
//

import Defaults
import SwiftUI

struct AgentDetailView: View {
    let session: AgentSession
    let onReply: () -> Void

    @ObservedObject var agents = AgentManager.shared
    @Default(.agentsCountCachedTokens) private var countCachedTokens
    @Default(.agentsParticles) private var particles
    @Default(.agentsParticlesOpen) private var particlesOpen

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
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
                metaLine
            }

            if particles, particlesOpen, session.state != .idle {
                AgentParticleStream()
                    .frame(height: 5)
            }

            content
        }
        .padding(8)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Header

    private var metaLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if let branch = session.gitBranch {
                    metaItem(branch, icon: "arrow.triangle.branch")
                }
                if let model = session.model {
                    metaItem(AgentText.modelName(model))
                }
                if let started = session.turnStartedAt {
                    metaItem(AgentText.elapsed(since: started, now: context.date), icon: "clock")
                }
                let tokens = session.usage.total(includingCached: countCachedTokens)
                if tokens > 0 {
                    metaItem("\(AgentText.tokens(tokens)) tokens")
                }
                if session.subagentCount > 0 {
                    metaItem("\(session.subagentCount)", icon: "person.2.fill")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metaItem(_ text: String, icon: String? = nil) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(size: 10, design: .rounded))
        .foregroundStyle(.gray)
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

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if session.state != .idle, !session.recentTools.isEmpty {
            AgentToolTimeline(calls: session.recentTools)
        } else if session.state != .idle, let activity = session.activity, !activity.isEmpty {
            Text(activity)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.vertical) {
                AgentMarkdownView(text: session.fullMessage ?? session.lastMessage
                                  ?? AgentText.abbreviated(path: session.cwd))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
    }
}

// MARK: - Tool timeline

/// The latest tool calls of the running turn, newest at the bottom.
struct AgentToolTimeline: View {
    let calls: [AgentToolCall]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 3) {
                ForEach(calls) { call in
                    row(call, now: context.date)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ call: AgentToolCall, now: Date) -> some View {
        HStack(spacing: 6) {
            Image(systemName: call.failed ? "xmark.octagon.fill" : call.icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(iconColor(call))
                .frame(width: 12)
            Text(call.name)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Text(call.detail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.gray)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(AgentText.elapsed(since: call.startedAt, now: call.finishedAt ?? now))
                .font(.system(size: 9, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.gray.opacity(0.7))
        }
        .opacity(call.finishedAt == nil ? 1 : 0.65)
    }

    private func iconColor(_ call: AgentToolCall) -> Color {
        if call.failed { return .red }
        return call.finishedAt == nil ? AgentSessionState.working.color : .gray
    }
}

// MARK: - Markdown

/// Renders an agent's message: paragraphs, headings, inline styles and code blocks.
struct AgentMarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case paragraph(String)
        case heading(String)
        case code(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .paragraph(let paragraph):
            Text(inline(paragraph))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
        case .heading(let heading):
            Text(inline(heading))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        case .code(let code):
            Text(code)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let finished = code {
                    blocks.append(.code(finished.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flushParagraph()
            } else if trimmed.hasPrefix("#") {
                flushParagraph()
                blocks.append(.heading(String(trimmed.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                paragraph.append("• " + trimmed.dropFirst(2))
            } else {
                paragraph.append(line)
            }
        }
        // A message cut off inside a code block still shows what arrived.
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }
}
