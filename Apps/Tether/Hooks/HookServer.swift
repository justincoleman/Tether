import Foundation
import Network
import TetherCore

/// Loopback-only HTTP server for Claude Code hooks. Parsing and routing live
/// in TetherCore; this file only moves bytes.
final class HookServer: @unchecked Sendable {
    private let router: HookRouter
    private let queue = DispatchQueue(label: "tether.hook-server")
    private var listener: NWListener?

    init(router: HookRouter) {
        self.router = router
    }

    /// Binds 127.0.0.1 on a random free port and returns it.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let once = ResumeOnce()
        let boxed = Unchecked(listener)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = boxed.value.port?.rawValue, once.claim() {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        let boxed = Unchecked(connection)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            let connection = boxed.value
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequestParser.parse(buffer) {
            case .complete(let request):
                let router = self.router
                Task {
                    let response = await router.handle(request)
                    let connection = boxed.value
                    connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            case .invalid:
                connection.send(content: HTTPResponse(status: 400).serialized(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }
}

/// Network objects are thread-safe, but older SDKs don't mark them Sendable.
private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Guards a continuation against the listener reporting more than one state.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
