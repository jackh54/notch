//
//  AgentDetailView.swift
//  boringNotch
//
//  The right-hand pane of the Agents tab for a session with nothing pending.
//

import SwiftUI

struct AgentDetailView: View {
    let session: AgentSession
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

            ScrollView(.vertical) {
                Text(detailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.never)
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
}
