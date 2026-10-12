import Foundation
import Network

/// A short-lived, loopback-only HTTP callback. It never serves files or echoes OAuth data.
public final class ChatGPTLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "HarborReply.oauth-callback")
    private var listener: NWListener?
    private var startWaiter: CheckedContinuation<URL, Error>?
    private var callbackWaiter: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var callbackDelivered = false
    private var callback: URL?
    private var connections: [NWConnection] = []
    private var timer: DispatchWorkItem?
    public init() {}
    public func start(timeout: Double = 180) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let result = self.result { continuation.resume(with: result); return }
                    self.startWaiter = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                        let listener = try NWListener(using: parameters)
                        self.listener = listener
                        listener.stateUpdateHandler = { [weak self] state in
                            guard let self else { return }
                            switch state {
                            case .ready:
                                guard let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback") else { self.finish(.failure(ChatGPTError.listener)); return }
                                self.callback = url; self.startWaiter?.resume(returning: url); self.startWaiter = nil
                            case .failed: self.finish(.failure(ChatGPTError.listener))
                            default: break
                            }
                        }
                        listener.newConnectionHandler = { [weak self] connection in
                            guard let self, self.result == nil, self.connections.count < 8 else { connection.cancel(); return }
                            self.connections.append(connection); connection.start(queue: self.queue); self.receive(connection, bytes: Data())
                        }
                        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(ChatGPTError.expiredAttempt)) }
                        self.timer = timer; self.queue.asyncAfter(deadline: .now() + timeout, execute: timer)
                        listener.start(queue: self.queue)
                    } catch { self.finish(.failure(ChatGPTError.listener)) }
                }
            }
        } onCancel: { self.cancel() }
    }
    public func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.callbackDelivered && self.callbackWaiter == nil else { continuation.resume(throwing: ChatGPTError.callback); return }
                    if let result = self.result { self.callbackDelivered = true; continuation.resume(with: result) }
                    else { self.callbackWaiter = continuation }
                }
            }
        } onCancel: { self.cancel() }
    }
    public func cancel() { queue.async { self.finish(.failure(ChatGPTError.cancelled)) } }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] chunk, _, complete, error in
            guard let self, self.result == nil else { connection.cancel(); return }
            let data = bytes + (chunk ?? Data())
            guard data.count <= 16_384, error == nil else { self.close(connection); return }
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n\r\n") {
                let lines = text.components(separatedBy: "\r\n"); let first = lines[0].split(separator: " ")
                let expectedHost = "127.0.0.1:\(self.callback?.port ?? 0)"
                let host = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("host:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard first.count == 3, first[0] == "GET", first[1].hasPrefix("/auth/callback?"), host == expectedHost,
                      let callback = URL(string: "http://" + expectedHost + first[1]) else { self.close(connection); return }
                let body = "HarborReply received the sign-in callback. Return to the app to check the result."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    self.finish(.success(callback))
                })
            } else if complete { self.close(connection) }
            else { self.receive(connection, bytes: data) }
        }
    }
    private func close(_ connection: NWConnection) { connection.cancel(); connections.removeAll { $0 === connection } }
    private func finish(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value; timer?.cancel(); timer = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        connections.forEach { $0.cancel() }; connections = []
        startWaiter?.resume(with: value); startWaiter = nil
        if let waiter = callbackWaiter { callbackDelivered = true; waiter.resume(with: value); callbackWaiter = nil }
    }
}
