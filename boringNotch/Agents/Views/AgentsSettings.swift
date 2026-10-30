//
//  AgentsSettings.swift
//  boringNotch
//
//  Settings for the Claude Code / Codex integration.
//

import Defaults
import SwiftUI

struct AgentsSettings: View {
    @Default(.enableAgents) var enableAgents
    @Default(.agentsDefaultTab) var agentsDefaultTab
    @Default(.agentsLiveActivity) var agentsLiveActivity
    @Default(.agentsOpenOnApproval) var agentsOpenOnApproval
    @Default(.agentsFinishedBanner) var agentsFinishedBanner

    @State private var installed: [AgentProvider: Bool] = [:]
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableAgents) {
                    Text("Show Claude Code and Codex sessions")
                }
                Group {
                    Defaults.Toggle(key: .agentsDefaultTab) {
                        Text("Open the notch on the Agents tab")
                    }
                    Defaults.Toggle(key: .agentsLiveActivity) {
                        Text("Show running sessions in the closed notch")
                    }
                    Defaults.Toggle(key: .agentsFinishedBanner) {
                        Text("Announce when a session finishes")
                    }
                    Defaults.Toggle(key: .agentsOpenOnApproval) {
                        Text("Open the notch when a session needs you")
                    }
                    Defaults.Toggle(key: .agentsAnswerApprovals) {
                        Text("Answer permission prompts from the notch")
                    }
                    Defaults.Toggle(key: .agentsAnswerQuestions) {
                        Text("Answer Claude's questions from the notch")
                    }
                }
                .disabled(!enableAgents)
            } header: {
                Text("General")
            }

            Section {
                hookRow(.claude)
                hookRow(.codex)
            } header: {
                Text("Hooks")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                    Text(
                        "Hooks let the notch show what each session is doing and answer permission prompts. They are added to ~/.claude/settings.json and ~/.codex/hooks.json next to any existing hooks, and do nothing when Boring Notch isn't running. Codex asks you to trust new hooks: run /hooks in Codex once after installing. Already-running sessions pick hooks up when restarted."
                    )
                    .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.leading)
                .font(.caption)
            }

            Section {
                ForEach(AgentProvider.allCases) { provider in
                    HStack {
                        Text(provider.displayName)
                        Spacer()
                        Text(AgentCLI.executable(for: provider) ?? "Not found")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } header: {
                Text("Command-line tools")
            } footer: {
                Text("Used to start new tasks and send follow-ups from the notch.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Agents")
        .onAppear(perform: refresh)
    }

    private func hookRow(_ provider: AgentProvider) -> some View {
        AgentHookRow(
            provider: provider,
            isInstalled: installed[provider] ?? false,
            needsUpdate: AgentHookInstaller.needsUpdate(provider),
            toggle: { toggleHooks(provider) }
        )
        .disabled(!enableAgents)
    }

    private func toggleHooks(_ provider: AgentProvider) {
        do {
            errorMessage = nil
            if installed[provider] ?? false {
                try AgentHookInstaller.uninstall(provider)
            } else {
                try AgentHookInstaller.install(provider)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        for provider in AgentProvider.allCases {
            installed[provider] = AgentHookInstaller.isInstalled(provider)
        }
    }
}

private struct AgentHookRow: View {
    let provider: AgentProvider
    let isInstalled: Bool
    let needsUpdate: Bool
    let toggle: () -> Void

    private var status: String {
        if needsUpdate { return "Update available" }
        return isInstalled ? "Installed" : "Not installed"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(provider.displayName)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(needsUpdate ? .orange : isInstalled ? .green : .secondary)
            }
            Spacer()
            Button(needsUpdate ? "Update" : isInstalled ? "Remove" : "Install", action: toggle)
        }
    }
}
