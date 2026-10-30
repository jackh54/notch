//
//  AgentSnapshots.swift
//  boringNotch
//
//  Debug builds only: renders each Agents state from fixtures to PNGs, for checking layout
//  where the screen can't be captured. Run the app with `--agent-snapshots <folder>`.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum AgentSnapshots {
    /// Starts rendering and returns true when the launch arguments ask for it.
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--agent-snapshots"), arguments.count > flag + 1 else { return false }

        let folder = URL(fileURLWithPath: arguments[flag + 1])
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task {
            await renderAll(to: folder)
            NSApp.terminate(nil)
        }
        return true
    }

    private static var keepAlive: [NSWindow] = []

    private static func renderAll(to folder: URL) async {
        let agents = AgentManager.shared
        let vm = BoringViewModel()
        // With no screen attached the closed notch would otherwise report a height of zero.
        vm.hideOnClosed = false
        let closedSize = CGSize(width: 340, height: 40)
        let openSize = CGSize(width: openNotchSize.width - 24, height: agentNotchSize.height - 44)
        let requestSize = CGSize(width: openNotchSize.width - 24, height: agentRequestNotchSize.height - 44)

        func tab() -> some View {
            AgentsView().environmentObject(vm).padding(8).background(.black)
        }
        func closed() -> some View {
            ZStack {
                Color.black
                AgentLiveActivity().environmentObject(vm)
            }
        }

        agents.loadFixture(sessions: [Fixture.working, Fixture.finished])
        AgentTokenFlow.shared.loadFixture()
        await render(closed(), size: closedSize, to: folder, name: "closed-working")
        AgentTokenFlow.shared.loadFixture()
        await render(tab(), size: openSize, to: folder, name: "tab-working")

        agents.loadFixture(sessions: [Fixture.finished, Fixture.working])
        await render(AgentDetailView(session: Fixture.finished, onReply: {}).background(.black), size: openSize, to: folder, name: "detail-idle")

        agents.loadFixture(sessions: [Fixture.waiting, Fixture.finished], approvals: [Fixture.bashApproval, Fixture.editApproval])
        await render(closed(), size: closedSize, to: folder, name: "closed-attention")
        await render(tab(), size: requestSize, to: folder, name: "tab-approval-bash")

        agents.loadFixture(sessions: [Fixture.waiting], approvals: [Fixture.editApproval])
        await render(tab(), size: requestSize, to: folder, name: "tab-approval-edit")

        agents.loadFixture(sessions: [Fixture.waiting], questions: [Fixture.question])
        await render(tab(), size: requestSize, to: folder, name: "tab-question")

        agents.loadFixture(sessions: [], error: "Claude exited with 1. Not logged in. Run /login.")
        await render(tab(), size: openSize, to: folder, name: "tab-empty-error")

        let pets = HStack(spacing: 24) {
            AgentPetIcon(mood: .idle, width: 96)
            AgentPetIcon(mood: .working, width: 96)
            AgentPetIcon(mood: .alert, width: 96)
            AgentPetIcon(mood: .celebrating, width: 96)
        }
        .padding(24)
        .background(.black)
        await render(pets, size: CGSize(width: 520, height: 110), to: folder, name: "pet-moods")
    }

    private static func render(_ view: some View, size: CGSize, to folder: URL, name: String) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        keepAlive.append(window)

        // Gives SwiftUI time to lay out and animations time to settle.
        try? await Task.sleep(for: .milliseconds(700))
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?
            .write(to: folder.appendingPathComponent("\(name).png"))
    }

    private enum Fixture {
        static let now = Date()

        static let working = AgentSession(
            provider: .claude, sessionId: "working", title: "Polish the notch", cwd: "/Users/jack/Documents/GitHub/notch",
            state: .working, activity: "Bash: xcodebuild", updatedAt: now,
            turnStartedAt: now.addingTimeInterval(-134),
            recentTools: [
                tool("Read", "boringNotch/Agents/AgentManager.swift", ago: 40, took: 1),
                tool("Grep", "currentRequest", ago: 30, took: 1),
                tool("Edit", "boringNotch/Agents/Views/AgentLiveActivity.swift", ago: 22, took: 2),
                tool("Bash", "xcodebuild -scheme boringNotch build", ago: 14, took: nil),
            ],
            subagentCount: 2, model: "claude-opus-5-5", gitBranch: "feat/agent-notch-polish",
            usage: AgentTokenUsage(input: 1200, output: 11_200))

        static let finished = AgentSession(
            provider: .codex, sessionId: "finished", title: "Fix the release flow", cwd: "/Users/jack/Documents/GitHub/notch",
            lastMessage: "Done. The release workflow now signs ad hoc.", updatedAt: now.addingTimeInterval(-300),
            fullMessage: """
            ## Release fixed

            The workflow now **signs ad hoc** and uploads `appcast.xml`.

            - Updated `fork_release.yml`
            - Added the signing step

            ```sh
            scripts/adhoc-sign.sh "Boring Notch.app"
            ```
            """,
            model: "gpt-6.1-sol", gitBranch: "main", usage: AgentTokenUsage(input: 69_000, output: 3_153))

        static var waiting: AgentSession {
            var session = working
            session.state = .needsApproval
            return session
        }

        static let bashApproval = AgentApprovalRequest(
            id: UUID(), sessionKey: waiting.id, provider: .claude, toolName: "Bash", detail: "npm run lint -- --fix",
            preview: .command("npm run lint -- --fix"),
            sessionRules: [AgentPermissionRule(toolName: "Bash", ruleContent: "npm run lint:*")],
            receivedAt: now.addingTimeInterval(-20))

        static let editApproval = AgentApprovalRequest(
            id: UUID(), sessionKey: waiting.id, provider: .claude, toolName: "Edit", detail: "AgentModels.swift",
            preview: .edit(
                path: AgentPaths.home.appendingPathComponent("notch/AgentModels.swift").path,
                old: "let id: UUID\nlet title = \"Old\"\nlet size = 1",
                new: "let id: UUID\nlet title = \"New\"\nlet size = 1", replaceAll: false),
            sessionRules: [], receivedAt: now.addingTimeInterval(-5))

        static let question = AgentQuestionRequest(
            id: UUID(), sessionKey: waiting.id,
            questions: [AgentQuestion(
                text: "Which icon should the Agents tab use?", header: "Icon",
                options: [
                    .init(label: "Pet", detail: "The pixel mascot"),
                    .init(label: "Sparkle", detail: "The original star"),
                ], multiSelect: false)],
            receivedAt: now.addingTimeInterval(-3))

        private static func tool(_ name: String, _ detail: String, ago: TimeInterval, took: TimeInterval?) -> AgentToolCall {
            let started = now.addingTimeInterval(-ago)
            return AgentToolCall(
                id: UUID(), toolUseID: nil, name: name, detail: detail, startedAt: started,
                finishedAt: took.map { started.addingTimeInterval($0) })
        }
    }
}
#endif
