//
//  AgentHookServer.swift
//  boringNotch
//
//  Loopback HTTP listener that receives Claude Code / Codex hook events.
//  The hook script POSTs the event JSON and prints whatever we answer, so a
//  permission request can be held open until it is decided in the notch.
//

import Foundation
import Network

final class AgentHookServer {
    /// Completes the HTTP exchange. Pass nil to answer with an empty body.
    typealias Reply = (_ body: Data?) -> Void

    /// Called on the main queue for every authenticated event.
    var onEvent: ((_ provider: AgentProvider, _ payload: [String: Any], _ requestID: UUID, _ reply: @escaping Reply) -> Void)?
    /// Called on the main queue when a client hangs up before we replied.
    var onDisconnect: ((_ requestID: UUID) -> Void)?

    private let queue = DispatchQueue(label: "boringnotch.agents.hookserver")
    private var listener: NWListener?
    private var token = ""
    private(set) var isRunning = false

    func start(port: Int, token: String) {
        stop()
        self.token = token
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed(let error):
                    NSLog("Agent hook server failed: \(error)")
                    self?.isRunning = false
                case .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            NSLog("Agent hook server could not start on port \(port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest(buffer) {
                self.handle(request, on: connection)
            } else if isComplete || error != nil || buffer.count > 8 << 20 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        // Path: /hook/<provider>?token=<token>
        guard request.method == "POST",
              let components = URLComponents(string: request.path),
              components.queryItems?.first(where: { $0.name == "token" })?.value == token,
              components.path.hasPrefix("/hook/"),
              let provider = AgentProvider(rawValue: String(components.path.dropFirst("/hook/".count))),
              let payload = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        else {
            respond(connection, status: "400 Bad Request", body: nil)
            return
        }

        let requestID = UUID()
        let replied = ManagedFlag()

        // Keep reading so we notice the hook process going away (e.g. the prompt
        // was answered in the terminal) while a reply is still pending.
        watchForClose(connection) { [weak self] in
            guard replied.setIfUnset() else { return }
            connection.cancel()
            DispatchQueue.main.async { self?.onDisconnect?(requestID) }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, let onEvent = self.onEvent else {
                self?.queue.async { if replied.setIfUnset() { self?.respond(connection, status: "200 OK", body: nil) } }
                return
            }
            onEvent(provider, payload, requestID) { body in
                self.queue.async {
                    guard replied.setIfUnset() else { return }
                    self.respond(connection, status: "200 OK", body: body)
                }
            }
        }
    }

    private func watchForClose(_ connection: NWConnection, onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                onClose()
            } else {
                self?.watchForClose(connection, onClose: onClose)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data?) {
        let body = body ?? Data()
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Thread-safe one-shot flag.
private final class ManagedFlag {
    private let lock = NSLock()
    private var value = false

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    /// Returns nil until the buffer holds a complete request.
    init?(_ buffer: Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= contentLength else { return nil }

        method = String(requestLine[0])
        path = String(requestLine[1])
        body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
    }
}
