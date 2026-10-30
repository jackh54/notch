//
//  AgentPetIcon.swift
//  boringNotch
//
//  The Claude Code pet, drawn as a pixel grid, and the icon view for each provider.
//

import Defaults
import SwiftUI

/// How the pet behaves, picked from what its session is doing.
enum AgentPetMood {
    case idle
    case working
    case alert
    case celebrating

    init(state: AgentSessionState) {
        switch state {
        case .idle: self = .idle
        case .working: self = .working
        case .waiting, .needsApproval: self = .alert
        }
    }
}

struct AgentPetIcon: View {
    var mood: AgentPetMood = .idle
    /// The pet's width; its height follows from the grid.
    var width: CGFloat = 16
    /// Nil draws in the current foreground style.
    var color: Color? = AgentProvider.claude.tint

    @Default(.agentsAnimatePet) private var animatePet
    @Default(.agentsPauseOnLowPower) private var pauseOnLowPower
    @ObservedObject private var motion = AgentMotion.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let framesPerSecond = 4.0
    /// Terminal cells are twice as tall as they are wide, so each grid pixel is too.
    private static let pixelAspect: CGFloat = 2

    private var isAnimated: Bool {
        animatePet && motion.allowsAnimation(reduceMotion: reduceMotion, pauseOnLowPower: pauseOnLowPower)
    }

    var body: some View {
        let height = width / CGFloat(AgentPetFrame.columns) * Self.pixelAspect * CGFloat(AgentPetFrame.rows)
        Group {
            if isAnimated {
                TimelineView(.periodic(from: .now, by: 1 / Self.framesPerSecond)) { context in
                    canvas(frame: AgentPetFrame(mood: mood, tick: Int(context.date.timeIntervalSinceReferenceDate * Self.framesPerSecond)))
                }
            } else {
                canvas(frame: AgentPetFrame(mood: mood, tick: 0))
            }
        }
        .frame(width: width, height: height)
    }

    private func canvas(frame: AgentPetFrame) -> some View {
        Canvas { context, size in
            let pixelWidth = size.width / CGFloat(AgentPetFrame.columns)
            let pixelHeight = pixelWidth * Self.pixelAspect
            var path = Path()
            for (row, line) in frame.pixels.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    path.addRect(CGRect(
                        x: CGFloat(column) * pixelWidth,
                        y: (CGFloat(row) + frame.lift) * pixelHeight,
                        width: pixelWidth + 0.2, height: pixelHeight + 0.2))
                }
            }
            context.fill(path, with: color.map { .color($0) } ?? .foreground)
        }
    }
}

extension AgentPetIcon {
    /// The pet as an image, for places that can't host a custom view, such as menu labels.
    static func image(width: CGFloat, color: Color) -> NSImage {
        let frame = AgentPetFrame(mood: .idle, tick: 1)
        let pixelWidth = width / CGFloat(AgentPetFrame.columns)
        let pixelHeight = pixelWidth * pixelAspect
        let size = CGSize(width: width, height: pixelHeight * CGFloat(AgentPetFrame.rows))

        return NSImage(size: size, flipped: true) { _ in
            NSColor(color).setFill()
            for (row, line) in frame.pixels.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "#" {
                    // The small overlap stops hairline seams between pixels.
                    NSRect(x: CGFloat(column) * pixelWidth, y: CGFloat(row) * pixelHeight,
                           width: pixelWidth + 0.3, height: pixelHeight + 0.3).fill()
                }
            }
            return true
        }
    }
}

/// One frame of the pet. "#" is a filled pixel; the eyes are the gaps left in the body.
private struct AgentPetFrame {
    static let columns = 16
    static let rows = 5

    private static let top = "..############.."
    private static let eyes = "..##.######.##.."
    private static let closedEyes = "..############.."
    private static let middle = "################"
    private static let bottom = "..############.."
    private static let legs = "...#.#....#.#..."
    private static let steppedLegs = "....#.#..#.#...."
    private static let armsUpTop = "#.############.#"
    private static let armsUpEyes = "#.##.######.##.#"

    /// One blink lasts one tick out of this many.
    private static let blinkPeriod = 18

    let pixels: [String]
    /// How far the pet is raised, in grid rows.
    let lift: CGFloat

    init(mood: AgentPetMood, tick: Int) {
        switch mood {
        case .idle:
            let blinking = tick % Self.blinkPeriod == 0
            pixels = [Self.top, blinking ? Self.closedEyes : Self.eyes, Self.middle, Self.bottom, Self.legs]
            lift = 0
        case .working:
            pixels = [Self.top, Self.eyes, Self.middle, Self.bottom, tick % 2 == 0 ? Self.legs : Self.steppedLegs]
            lift = 0
        case .alert:
            pixels = [Self.armsUpTop, Self.armsUpEyes, Self.middle, Self.bottom, Self.legs]
            lift = 0
        case .celebrating:
            let hopping = tick % 2 == 0
            pixels = [hopping ? Self.armsUpTop : Self.top, hopping ? Self.armsUpEyes : Self.eyes,
                      Self.middle, Self.bottom, Self.legs]
            lift = hopping ? -0.5 : 0
        }
    }
}

/// A provider's mark: the pet or a sparkle for Claude, depending on the setting.
struct AgentProviderIcon: View {
    let provider: AgentProvider
    var mood: AgentPetMood = .idle
    var size: CGFloat = 10

    @Default(.agentsClaudeIcon) private var claudeIcon

    var body: some View {
        if provider == .claude, claudeIcon == .pet {
            AgentPetIcon(mood: mood, width: size * 1.5)
        } else {
            Image(systemName: provider.icon)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(provider.tint)
        }
    }
}

/// The Agents tab button, in the same colour as the other tabs.
struct AgentTabIcon: View {
    @Default(.agentsClaudeIcon) private var claudeIcon

    var body: some View {
        if claudeIcon == .pet {
            AgentPetIcon(mood: .idle, width: 18, color: nil)
        } else {
            Image(systemName: AgentProvider.claude.icon)
        }
    }
}
