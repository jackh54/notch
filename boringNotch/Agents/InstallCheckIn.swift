//
//  InstallCheckIn.swift
//  boringNotch
//
//  Tells the fork's server which version this install runs. Sends a random ID, the version
//  and the build, and nothing else. This is separate from Sparkle on purpose, so updates
//  keep working whether or not this server is up.
//

import AppKit
import Defaults
import Foundation

@MainActor
final class InstallCheckIn {
    static let shared = InstallCheckIn()

    private static let checkInInterval: TimeInterval = 24 * 60 * 60
    private static let pollInterval: Duration = .seconds(60 * 60)

    private var pollTask: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    private init() {}

    private var baseURL: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["NOTCH_CHECKIN_URL"] { return URL(string: override) }
        #endif
        return (Bundle.main.object(forInfoDictionaryKey: "NotchCheckInURL") as? String).flatMap(URL.init(string:))
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkInIfDue()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    #if DEBUG
    /// Checks in with the server in NOTCH_CHECKIN_URL, then quits. Pass `--check-in-test`
    /// to use it; the pause leaves time for the request to finish.
    static func runTestIfRequested() -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--check-in-test") else { return false }
        shared.start()
        Task {
            try? await Task.sleep(for: .seconds(4))
            NSLog("check-in test: id \(Defaults[.installCheckInID].prefix(8)), date \(String(describing: Defaults[.installCheckInDate]))")
            NSApp.terminate(nil)
        }
        return true
    }
    #endif

    private func checkInIfDue() async {
        let lastCheckIn = Defaults[.installCheckInDate] ?? .distantPast
        let isDue = Date().timeIntervalSince(lastCheckIn) >= Self.checkInInterval
            || Defaults[.installCheckInBuild] != build
        guard isDue, let url = baseURL?.appendingPathComponent("checkin") else { return }

        if Defaults[.installCheckInID].isEmpty {
            Defaults[.installCheckInID] = UUID().uuidString.lowercased()
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "installId": Defaults[.installCheckInID], "version": version, "build": build,
        ])

        guard let (_, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status)
        else { return }

        Defaults[.installCheckInDate] = .now
        Defaults[.installCheckInBuild] = build
    }
}
