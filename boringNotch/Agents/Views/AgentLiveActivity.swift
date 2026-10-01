//
//  AgentLiveActivity.swift
//  boringNotch
//
//  Closed-notch indicator for running agent sessions.
//

import SwiftUI

struct AgentLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var agents = AgentManager.shared

    private var sideLength: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    var body: some View {
        HStack {
            Image(systemName: agents.primarySession?.provider.icon ?? "sparkle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(agents.primarySession?.provider.tint ?? .gray)
                .frame(width: sideLength, height: sideLength)

            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

            status
                .frame(width: sideLength, height: sideLength)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    @ViewBuilder
    private var status: some View {
        if agents.attentionCount > 0 {
            Image(systemName: agents.approvals.isEmpty ? "ellipsis.bubble.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
        } else if agents.workingCount > 1 {
            Text("\(agents.workingCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.green)
                .contentTransition(.numericText())
        } else {
            AgentStateIndicator(state: .working)
        }
    }
}

/// One-line strip under the closed notch announcing a finished session.
struct AgentBannerView: View {
    let banner: AgentBanner

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: banner.provider.icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(banner.provider.tint)
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
