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
    @Default(.agentsParticles) var agentsParticles
    @Default(.agentsParticleIntensity) var particleIntensity
    @Default(.agentsParticleColor) var particleColor
    @Default(.agentsParticleCustomColor) var particleCustomColor
    @Default(.agentsTokenReadout) var tokenReadout
    @Default(.agentsClaudeIcon) var claudeIcon
    @Default(.installCheckInID) var installCheckInID

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
                Defaults.Toggle(key: .agentsParticles) {
                    Text("Show tokens as particles")
                }
                Group {
                    Defaults.Toggle(key: .agentsParticlesClosed) {
                        Text("In the closed notch")
                    }
                    Defaults.Toggle(key: .agentsParticlesOpen) {
                        Text("In the open notch")
                    }
                    Picker("Intensity", selection: $particleIntensity) {
                        ForEach(AgentParticleIntensity.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Colour", selection: $particleColor) {
                        ForEach(AgentParticleColor.allCases) { Text($0.displayName).tag($0) }
                    }
                    if particleColor == .custom {
                        ColorPicker("Custom colour", selection: $particleCustomColor, supportsOpacity: false)
                    }
                }
                .disabled(!agentsParticles)

                Picker("Token count in the closed notch", selection: $tokenReadout) {
                    ForEach(AgentTokenReadout.allCases) { Text($0.displayName).tag($0) }
                }
                Defaults.Toggle(key: .agentsCountCachedTokens) {
                    Text("Count cached tokens")
                }
                Picker("Claude icon", selection: $claudeIcon) {
                    ForEach(AgentClaudeIcon.allCases) { Text($0.displayName).tag($0) }
                }
                Defaults.Toggle(key: .agentsAnimatePet) {
                    Text("Animate the pet")
                }
                .disabled(claudeIcon != .pet)
                Defaults.Toggle(key: .agentsAttentionGlow) {
                    Text("Glow when a session needs you")
                }
                Defaults.Toggle(key: .agentsSounds) {
                    Text("Play sounds when a session needs you or finishes")
                }
                Defaults.Toggle(key: .agentsPauseOnLowPower) {
                    Text("Pause animation in Low Power Mode")
                }
            } header: {
                Text("Notch animation")
            } footer: {
                Text("Particles only appear when tokens are actually used. Cache reads repeat the whole conversation on every call, so they are left out unless you count them. Reduce Motion in System Settings always stops the animation.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .disabled(!enableAgents)

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
                Defaults.Toggle(key: .shareInstallVersion) {
                    Text("Share which version I'm running")
                }
                if !installCheckInID.isEmpty {
                    HStack {
                        Text("Install ID")
                        Spacer()
                        Text(installCheckInID.prefix(8))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("Version sharing")
            } footer: {
                Text("Once a day the app sends a random ID and its version number to the developer of this fork, to show which versions are in use. Your name, IP address and activity are not stored. Turning this off deletes the ID and asks the server to forget it. Updates work either way.")
                    .foregroundStyle(.secondary)
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
