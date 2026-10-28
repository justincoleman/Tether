import Foundation
import Network
import TetherProtocol

/// One WebSocket over Network.framework: the Mac uses it for each accepted
/// phone, the phone as its client. Network.framework rather than URLSession
/// so the phone can reach a Tailscale IP without an ATS exception.
///
/// Every callback runs on the main queue. Frames are JSON text.
@MainActor
final class WebSocketChannel {
    static let maxMessageSize = 16 * 1024 * 1024

    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    /// Called once, whether the peer closed, the network failed, or `close()` ran.
    var onClose: ((NWError?) -> Void)?
    private(set) var isClosed = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// A client connection to `ws://host:port/`.
    convenience init(host: String, port: Int) {
        let urlHost = host.contains(":") ? "[\(host)]" : host
        let url = URL(string: "ws://\(urlHost):\(port)/")!
        self.init(connection: NWConnection(to: .url(url), using: Self.parameters()))
    }

    static func parameters() -> NWParameters {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = maxMessageSize
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        return params
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    func send<Message: Encodable>(_ message: Message) {
        guard let data = try? WireCodec.encoder().encode(message) else { return }
        send(data, opcode: .text)
    }

    func sendPing() {
        send(Data(), opcode: .ping)
    }

    func close(_ error: NWError? = nil) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose?(error)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        guard !isClosed else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.close(error) }
        })
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready: onReady?()
        case .failed(let error): close(error)
        // No route yet (offline, Tailscale down). The owner decides when to retry.
        case .waiting(let error): close(error)
        case .cancelled: close(nil)
        default: break
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] content, context, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let error { self.close(error); return }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if meta?.opcode == .close { self.close(nil); return }
                if let content, !content.isEmpty, meta?.opcode == .text || meta?.opcode == .binary {
                    self.onMessage?(content)
                } else if content == nil, meta == nil {
                    // End of stream without a close frame.
                    self.close(nil)
                    return
                }
                self.receive()
            }
        }
    }
}
