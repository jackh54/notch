//
//  AgentTemperatureEffect.swift
//  boringNotch
//
//  Frost or fire drawn under a session icon, following the CPU temperature.
//

import Defaults
import SwiftUI

enum AgentThermalLevel: Int, Comparable {
    case cold
    case fire
    case bigFire

    static let fireAt = 45.0
    static let bigFireAt = 70.0
    /// How far the temperature must fall below a threshold before the level drops,
    /// so a reading that hovers on a threshold doesn't flip the effect back and forth.
    static let hysteresis = 3.0

    init(celsius: Double) {
        switch celsius {
        case Self.bigFireAt...: self = .bigFire
        case Self.fireAt...: self = .fire
        default: self = .cold
        }
    }

    func next(celsius: Double) -> AgentThermalLevel {
        let rising = AgentThermalLevel(celsius: celsius)
        let falling = AgentThermalLevel(celsius: celsius + Self.hysteresis)
        if rising > self { return rising }
        if falling < self { return falling }
        return self
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

// Private IOKit calls; the HID event system is the only way to read Apple Silicon die
// temperatures without root. ProcessInfo.thermalState stays "nominal" until the Mac throttles.
@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ matching: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?
@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: AnyObject, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> Unmanaged<AnyObject>?
@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: Int32) -> Double

@MainActor
final class AgentTemperatureMonitor: ObservableObject {
    static let shared = AgentTemperatureMonitor()

    /// Nil when the Mac has no readable die sensors, such as an Intel Mac.
    @Published private(set) var level: AgentThermalLevel?

    private static let pollInterval: Duration = .seconds(5)
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField = Int32(temperatureEvent << 16)

    /// The sensors stop answering once their client is released, so it lives as long as they do.
    private let client: AnyObject?
    private let sensors: [AnyObject]

    private init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
        sensors = client.map(Self.dieSensors(of:)) ?? []
        guard !sensors.isEmpty else { return }
        // The monitor is a singleton, so the loop runs for the app's lifetime.
        Task {
            while true {
                if let celsius = hottestDie() {
                    level = level?.next(celsius: celsius) ?? AgentThermalLevel(celsius: celsius)
                }
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    private static func dieSensors(of client: AnyObject) -> [AnyObject] {
        // Apple vendor page, temperature sensor usage.
        _ = IOHIDEventSystemClientSetMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [] }
        return services.filter { service in
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String
            return name?.contains("tdie") == true
        }
    }

    private func hottestDie() -> Double? {
        sensors.compactMap { sensor -> Double? in
            guard let event = IOHIDServiceClientCopyEvent(sensor, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            let celsius = IOHIDEventGetFloatValue(event, Self.temperatureField)
            // Some sensors report garbage while uncalibrated.
            return (1...150).contains(celsius) ? celsius : nil
        }.max()
    }
}

/// Drawn behind a session icon: frost when the CPU is cool, flames licking up from
/// beneath when it's warm, and a blaze with embers when it's hot.
struct AgentTemperatureEffect: View {
    var size: CGFloat = 10

    @Default(.agentsPauseOnLowPower) private var pauseOnLowPower
    @ObservedObject private var temperature = AgentTemperatureMonitor.shared
    @ObservedObject private var motion = AgentMotion.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { size * 1.5 }

    var body: some View {
        if let level = temperature.level {
            Group {
                if motion.allowsAnimation(reduceMotion: reduceMotion, pauseOnLowPower: pauseOnLowPower) {
                    TimelineView(.animation) { context in
                        effect(level, time: context.date.timeIntervalSinceReferenceDate)
                    }
                } else {
                    effect(level, time: 0)
                }
            }
            .frame(width: width * 1.4, height: size * 2.6, alignment: .bottom)
            .offset(y: size * 0.3)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.6), value: level)
        }
    }

    @ViewBuilder
    private func effect(_ level: AgentThermalLevel, time: TimeInterval) -> some View {
        switch level {
        case .cold:
            frost(time: time)
        case .fire:
            ZStack(alignment: .bottom) {
                flame(time: time + 1.3, height: 0.75, speed: 1, colors: [.orange, .yellow]).offset(x: -width * 0.42)
                flame(time: time + 0.4, height: 0.75, speed: 1, colors: [.orange, .yellow]).offset(x: width * 0.42)
                flame(time: time + 2.2, height: 0.85, speed: 1, colors: [.orange, .yellow]).offset(x: -width * 0.16)
                flame(time: time + 0.9, height: 0.85, speed: 1, colors: [.orange, .yellow]).offset(x: width * 0.16)
            }
        case .bigFire:
            ZStack(alignment: .bottom) {
                flame(time: time + 2.1, height: 1.1, speed: 1.7, colors: [.red, .orange, .yellow]).offset(x: -width * 0.42)
                flame(time: time + 0.9, height: 1.1, speed: 1.7, colors: [.red, .orange, .yellow]).offset(x: width * 0.42)
                flame(time: time + 1.5, height: 1.4, speed: 1.8, colors: [.red, .orange, .yellow]).offset(x: -width * 0.22)
                flame(time: time + 0.3, height: 1.4, speed: 1.8, colors: [.red, .orange, .yellow]).offset(x: width * 0.22)
                flame(time: time, height: 1.75, speed: 1.9, colors: [.red, .orange, .yellow])
                embers(time: time)
            }
        }
    }

    private func frost(time: TimeInterval) -> some View {
        ZStack(alignment: .bottom) {
            Capsule()
                .fill(Color.cyan.opacity(0.8 + 0.2 * sin(time * 1.2)))
                .frame(width: width * 1.2, height: size * 0.42)
                .blur(radius: size * 0.22)
            ForEach(0..<4, id: \.self) { index in
                let progress = (time * 0.3 + Double(index) / 4).truncatingRemainder(dividingBy: 1)
                Image(systemName: "snowflake")
                    .font(.system(size: size * 0.5, weight: .heavy))
                    .foregroundStyle(Color(red: 0.8, green: 0.95, blue: 1))
                    .shadow(color: .cyan, radius: size * 0.15)
                    .rotationEffect(.degrees(progress * 180))
                    .offset(x: width * (CGFloat(index) - 1.5) * 0.38 + size * 0.15 * sin(progress * 8 + Double(index)),
                            y: -size * 1.5 * (1 - progress))
                    .opacity(sin(progress * .pi))
            }
        }
    }

    /// Flicker comes from summed sines at unrelated frequencies, so it never visibly loops.
    private func flame(time: TimeInterval, height: CGFloat, speed: Double, colors: [Color]) -> some View {
        let t = time * speed
        let stretch = 1 + 0.12 * sin(t * 7.3) + 0.07 * sin(t * 13.1)
        let sway = 5 * sin(t * 3.7) + 2 * sin(t * 9.4)
        return Image(systemName: "flame.fill")
            .font(.system(size: size * height, weight: .bold))
            .foregroundStyle(LinearGradient(colors: colors, startPoint: .bottom, endPoint: .top))
            .scaleEffect(x: 2 - stretch, y: stretch, anchor: .bottom)
            .rotationEffect(.degrees(sway), anchor: .bottom)
            .shadow(color: .orange.opacity(0.9), radius: size * 0.17)
    }

    private func embers(time: TimeInterval) -> some View {
        ForEach(0..<4, id: \.self) { index in
            let progress = (time * 0.8 + Double(index) / 4).truncatingRemainder(dividingBy: 1)
            Circle()
                .fill(index.isMultiple(of: 2) ? Color.yellow : Color.orange)
                .frame(width: size * 0.19, height: size * 0.19)
                .shadow(color: .orange, radius: size * 0.15)
                .offset(x: width * 0.5 * sin(progress * 5 + Double(index) * 1.7),
                        y: -size * (1.1 + 0.8 * progress))
                .opacity(1 - progress)
        }
    }
}
