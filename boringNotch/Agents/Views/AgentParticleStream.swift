//
//  AgentParticleStream.swift
//  boringNotch
//
//  Particles that drift across the notch while agents work, jumping the camera through portals.
//

import Defaults
import SwiftUI

struct AgentParticleStream: View {
    /// Width of the camera housing in the middle of the stream. Particles cross it through a
    /// pair of portals; at zero they run straight across.
    var gapWidth: CGFloat = 0

    @ObservedObject private var flow = AgentTokenFlow.shared
    @ObservedObject private var motion = AgentMotion.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Default(.agentsParticleColor) private var colorMode
    @Default(.agentsParticleCustomColor) private var customColor
    @Default(.agentsPauseOnLowPower) private var pauseOnLowPower

    private static let framesPerSecond = 30.0
    private static let trailSpan = 0.09
    private static let trailSamples = 8
    private static let sparkCount = 3

    private var isRunning: Bool {
        flow.isFlowing && motion.allowsAnimation(reduceMotion: reduceMotion, pauseOnLowPower: pauseOnLowPower)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / Self.framesPerSecond, paused: !isRunning)) { context in
            let now = context.date
            let particles = isRunning ? flow.tick(now: now) : []
            let openness = isRunning ? flow.portalOpenness : 0
            Canvas { canvas, size in
                canvas.blendMode = .plusLighter
                let path = AgentParticlePath(size: size, gapWidth: gapWidth)
                for particle in particles {
                    draw(particle, along: path, in: &canvas, now: now)
                }
                if path.hasPortals, openness > 0 {
                    drawPortals(along: path, openness: openness, particles: particles, in: &canvas, now: now)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ particle: AgentTokenFlow.Particle, along path: AgentParticlePath, in canvas: inout GraphicsContext, now: Date) {
        let progress = particle.progress(at: now)
        guard (0...1).contains(progress), let head = path.placement(of: particle, at: progress) else { return }

        let twinkle = 0.85 + 0.15 * sin(now.timeIntervalSinceReferenceDate * 14 + particle.lane * 40)
        let opacity = head.opacity * twinkle
        let color = color(for: particle.provider)
        let radius = particle.radius * head.scale

        if let comet = comet(of: particle, along: path, at: progress) {
            canvas.fill(comet.outline, with: .linearGradient(
                Gradient(colors: [color.opacity(0), color.opacity(0.7 * opacity)]),
                startPoint: comet.tail, endPoint: head.point))
        }
        canvas.fill(circle(at: head.point, radius: radius * 3.5), with: .radialGradient(
            Gradient(colors: [color.opacity(0.55 * opacity), color.opacity(0)]),
            center: head.point, startRadius: 0, endRadius: radius * 3.5))
        canvas.fill(circle(at: head.point, radius: radius), with: .color(color.opacity(opacity)))
        canvas.fill(circle(at: head.point, radius: radius * 0.5), with: .color(.white.opacity(0.8 * opacity)))
    }

    /// A tail that tapers to a point and follows the particle's curve.
    private func comet(
        of particle: AgentTokenFlow.Particle, along path: AgentParticlePath, at progress: Double
    ) -> (outline: Path, tail: CGPoint)? {
        let earliest = path.trailStart(from: progress, span: Self.trailSpan)
        let samples = (0...Self.trailSamples).compactMap { step -> (point: CGPoint, width: CGFloat)? in
            let share = Double(step) / Double(Self.trailSamples)
            guard let placement = path.placement(of: particle, at: progress + (earliest - progress) * share) else { return nil }
            return (placement.point, particle.radius * placement.scale * (1 - share))
        }
        guard samples.count > 1, let tail = samples.last?.point else { return nil }

        var sides: (left: [CGPoint], right: [CGPoint]) = ([], [])
        for (index, sample) in samples.enumerated() {
            let ahead = samples[max(0, index - 1)].point
            let behind = samples[min(samples.count - 1, index + 1)].point
            let (dx, dy) = (ahead.x - behind.x, ahead.y - behind.y)
            let length = max(0.001, (dx * dx + dy * dy).squareRoot())
            let side = CGPoint(x: -dy / length * sample.width, y: dx / length * sample.width)
            sides.left.append(CGPoint(x: sample.point.x + side.x, y: sample.point.y + side.y))
            sides.right.append(CGPoint(x: sample.point.x - side.x, y: sample.point.y - side.y))
        }
        var outline = Path()
        outline.addLines(sides.left + sides.right.reversed())
        outline.closeSubpath()
        return (outline, tail)
    }

    private func drawPortals(
        along path: AgentParticlePath, openness: Double, particles: [AgentTokenFlow.Particle],
        in canvas: inout GraphicsContext, now: Date
    ) {
        let surge = min(1, particles.reduce(0) { $0 + path.crossing(at: $1.progress(at: now)) } / 3)
        let spin = now.timeIntervalSinceReferenceDate * 5

        for (x, direction, provider) in [
            (path.entryX, 1.0, flow.portalProviders.entry),
            (path.exitX, -1.0, flow.portalProviders.exit),
        ] {
            let color = color(for: provider)
            let halfWidth = (2.6 + surge * 0.8) * openness
            let halfHeight = (path.size.height * 0.28 + surge * 1.5) * openness
            let center = CGPoint(x: x, y: path.size.height / 2)
            let portal = Path(ellipseIn: CGRect(
                x: center.x - halfWidth, y: center.y - halfHeight, width: halfWidth * 2, height: halfHeight * 2))

            canvas.fill(
                Path(ellipseIn: CGRect(
                    x: center.x - halfWidth * 2.2, y: center.y - halfHeight * 1.2,
                    width: halfWidth * 4.4, height: halfHeight * 2.4)),
                with: .color(color.opacity(0.12 + surge * 0.14)))
            canvas.fill(portal, with: .color(color.opacity(0.18)))
            canvas.stroke(portal, with: .color(color.opacity(0.65 + surge * 0.35)), lineWidth: 1.1)

            for spark in 0..<Self.sparkCount {
                let angle = (spin + Double(spark) * 2 * .pi / Double(Self.sparkCount)) * direction
                let point = CGPoint(x: center.x + cos(angle) * halfWidth, y: center.y + sin(angle) * halfHeight)
                canvas.fill(circle(at: point, radius: 0.8), with: .color(.white.opacity(0.75 * openness)))
            }
        }
    }

    private func circle(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func color(for provider: AgentProvider) -> Color {
        switch colorMode {
        case .provider: return provider.tint
        case .state: return AgentSessionState.working.color
        case .custom: return customColor
        }
    }
}

private extension AgentTokenFlow.Particle {
    func progress(at date: Date) -> Double { date.timeIntervalSince(birth) / lifetime }
}

/// Where a particle is at each point in its life. It holds one height all the way across. With a
/// gap it runs into the first portal, is gone for a moment, then comes out of the second at the
/// same height, fading before it reaches whatever sits at the far end.
private struct AgentParticlePath {
    struct Placement {
        let point: CGPoint
        let scale: CGFloat
        let opacity: Double
    }

    private static let entryEnd = 0.47
    private static let exitStart = 0.53
    private static let crossingSpan = 0.16
    /// How far the portals sit from the edge of the camera housing.
    private static let portalInset: CGFloat = 5
    /// Keeps the stream clear of the content at each end. The far side holds the token count.
    private static let startInset: CGFloat = 10
    private static let endInset: CGFloat = 22
    /// Share of the height particles use with portals, so that every lane lands inside a ring.
    private static let laneSpread = 0.46
    private static let easing = 1.3
    private static let smallestScale = 0.3
    /// The share of each side of the journey spent shrinking towards the portal.
    private static let shrinkShare = 0.3

    let size: CGSize
    let gapWidth: CGFloat

    var hasPortals: Bool { gapWidth > 0 }
    var entryX: CGFloat { (size.width - gapWidth) / 2 - Self.portalInset }
    var exitX: CGFloat { size.width - entryX }

    /// Nil while the particle is between the portals.
    func placement(of particle: AgentTokenFlow.Particle, at progress: Double) -> Placement? {
        guard hasPortals else {
            return Placement(
                point: CGPoint(x: progress * size.width, y: particle.lane * size.height),
                scale: 1, opacity: min(1, min(progress, 1 - progress) * 6))
        }
        if progress <= Self.entryEnd {
            let travelled = progress / Self.entryEnd
            return place(
                x: Self.startInset + (entryX - Self.startInset) * pow(travelled, Self.easing),
                portalShare: travelled, lane: particle.lane,
                opacity: min(1, travelled * 6))
        }
        if progress >= Self.exitStart {
            let travelled = (progress - Self.exitStart) / (1 - Self.exitStart)
            let farEnd = size.width - Self.endInset
            return place(
                x: exitX + (farEnd - exitX) * (1 - pow(1 - travelled, Self.easing)),
                portalShare: 1 - travelled, lane: particle.lane,
                opacity: min(1, (1 - travelled) * 1.8))
        }
        return nil
    }

    /// Where a trail starts, kept on the particle's own side of the portals.
    func trailStart(from progress: Double, span: Double) -> Double {
        max(!hasPortals || progress <= Self.entryEnd ? 0 : Self.exitStart, progress - span)
    }

    /// How close a particle is to jumping, from 0 to 1 at the moment it does.
    func crossing(at progress: Double) -> Double {
        max(0, 1 - abs(progress - 0.5) / Self.crossingSpan)
    }

    /// `portalShare` is how far along the journey towards the portal the particle is, from 0 to 1.
    private func place(x: CGFloat, portalShare: Double, lane: Double, opacity: Double) -> Placement {
        let shrink = max(0, (portalShare - (1 - Self.shrinkShare)) / Self.shrinkShare)
        return Placement(
            point: CGPoint(x: x, y: size.height * (0.5 + (lane - 0.5) * Self.laneSpread)),
            scale: 1 - (1 - Self.smallestScale) * shrink * shrink, opacity: opacity)
    }
}
