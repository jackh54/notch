//
//  AgentLiveActivity.swift
//  boringNotch
//
//  Closed-notch indicator for running agent sessions.
//

import Defaults
import SwiftUI

struct AgentLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var agents = AgentManager.shared

    @Default(.agentsParticles) private var particles
    @Default(.agentsParticlesClosed) private var particlesClosed
    @Default(.agentsTokenReadout) private var tokenReadout
    @Default(.agentsAttentionGlow) private var attentionGlow

    private var sideLength: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }
    private var wingWidth: CGFloat { sideLength + Self.extraWingWidth }

    /// How much each side grows to make room for particles and the readout. The sides stay
    /// equal so the content remains centred on the camera housing.
    static var extraWingWidth: CGFloat {
        let wantsRoom = (Defaults[.agentsParticles] && Defaults[.agentsParticlesClosed])
            || Defaults[.agentsTokenReadout] != .off
        return wantsRoom ? 28 : 0
    }

    private var showsParticles: Bool { particles && particlesClosed }

    var body: some View {
        HStack {
            leftWing
                .frame(width: wingWidth, height: sideLength, alignment: Self.extraWingWidth > 0 ? .leading : .center)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            status
                .frame(width: wingWidth, height: sideLength, alignment: Self.extraWingWidth > 0 ? .trailing : .center)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
        .background {
            if showsParticles {
                AgentParticleStream()
                    .padding(.vertical, 6)
            }
        }
        .overlay(alignment: .bottom) {
            if attentionGlow, agents.attentionCount > 0 {
                AgentAttentionGlow()
            }
        }
    }

    private var leftWing: some View {
        HStack(spacing: 3) {
            if let session = agents.primarySession {
                AgentProviderIcon(provider: session.provider, mood: AgentPetMood(state: session.state), size: 11)
            } else {
                Image(systemName: AgentProvider.claude.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.gray)
            }
            if agents.workingProviders.count > 1 {
                VStack(spacing: 2) {
                    ForEach(AgentProvider.allCases) { provider in
                        Circle()
                            .fill(provider.tint)
                            .frame(width: 4, height: 4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if agents.attentionCount > 0 {
            Image(systemName: agents.approvals.isEmpty ? "ellipsis.bubble.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
        } else if let readout = agents.closedReadout(tokenReadout) {
            statusText(readout, color: agents.primarySession?.provider.tint ?? .green)
        } else if agents.workingCount > 1 {
            statusText("\(agents.workingCount)", color: .green)
        } else if let started = agents.primarySession?.turnStartedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                statusText(AgentText.elapsed(since: started, now: context.date), color: .green)
            }
        } else {
            AgentStateIndicator(state: .working)
        }
    }

    private func statusText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .contentTransition(.numericText())
    }
}

/// A soft line along the closed notch's lower edge while a session needs the user.
private struct AgentAttentionGlow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBright = false

    var body: some View {
        LinearGradient(colors: [.clear, .orange, .orange, .clear], startPoint: .leading, endPoint: .trailing)
            .frame(height: 2)
            .blur(radius: 1)
            .opacity(reduceMotion || isBright ? 0.9 : 0.35)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { isBright = true }
            }
    }
}

/// One-line strip under the closed notch announcing a finished session.
struct AgentBannerView: View {
    let banner: AgentBanner

    var body: some View {
        HStack(spacing: 6) {
            AgentProviderIcon(provider: banner.provider, mood: banner.outcome == .failed ? .alert : .celebrating, size: 10)
            if banner.outcome == .failed {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.red)
            }
            Text(banner.title)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .layoutPriority(1)
            Text(banner.text)
                .font(.caption)
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .frame(maxWidth: 360)
        .padding(.bottom, 10)
    }
}
