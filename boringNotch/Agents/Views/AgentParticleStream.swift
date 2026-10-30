//
//  AgentParticleStream.swift
//  boringNotch
//
//  Particles that drift across the notch as an agent uses tokens.
//

import Defaults
import SwiftUI

struct AgentParticleStream: View {
    @ObservedObject private var flow = AgentTokenFlow.shared
    @ObservedObject private var motion = AgentMotion.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Default(.agentsParticleColor) private var colorMode
    @Default(.agentsParticleCustomColor) private var customColor
    @Default(.agentsPauseOnLowPower) private var pauseOnLowPower

    private static let framesPerSecond = 30.0

    private var isRunning: Bool {
        flow.isFlowing && motion.allowsAnimation(reduceMotion: reduceMotion, pauseOnLowPower: pauseOnLowPower)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.framesPerSecond, paused: !isRunning)) { context in
            let now = context.date
            let particles = isRunning ? flow.tick(now: now) : []
            Canvas { canvas, size in
                canvas.blendMode = .plusLighter
                for particle in particles {
                    draw(particle, in: &canvas, size: size, now: now)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ particle: AgentTokenFlow.Particle, in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let progress = now.timeIntervalSince(particle.birth) / particle.lifetime
        guard (0...1).contains(progress) else { return }

        let wobble = sin(progress * .pi * 2 + particle.lane * 6) * 0.08
        let center = CGPoint(x: progress * size.width, y: min(1, max(0, particle.lane + wobble)) * size.height)
        // Fades in and out at the edges so particles don't pop.
        let opacity = min(1, min(progress, 1 - progress) * 6)
        let color = color(for: particle).opacity(opacity)

        let radius = particle.radius
        canvas.fill(circle(at: center, radius: radius * 2.2), with: .color(color.opacity(0.22 * opacity)))
        canvas.fill(circle(at: center, radius: radius), with: .color(color))

        var trail = Path()
        trail.move(to: CGPoint(x: center.x - radius * 5, y: center.y))
        trail.addLine(to: center)
        canvas.stroke(trail, with: .color(color.opacity(0.35 * opacity)), lineWidth: radius)
    }

    private func circle(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func color(for particle: AgentTokenFlow.Particle) -> Color {
        switch colorMode {
        case .provider: return particle.provider.tint
        case .state: return AgentSessionState.working.color
        case .custom: return customColor
        }
    }
}
