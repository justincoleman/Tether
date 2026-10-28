import Darwin
import Foundation
import Network
import TetherCore

/// Listens for the iPhone app. Accepts only Tailscale and loopback peers, so
/// every byte travels inside Tailscale's WireGuard tunnel (docs/PROTOCOL.md).
@MainActor
final class CompanionServer {
    static let defaultPort: UInt16 = 7891

    private var listener: NWListener?
    var onConnection: ((WebSocketChannel, String) -> Void)?
    /// Called with nil once listening, or with the reason it stopped.
    var onStateChange: ((String?) -> Void)?

    func start(port: UInt16 = defaultPort) throws {
        let params = WebSocketChannel.parameters()
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.onStateChange?(nil)
                case .failed(let error): self?.onStateChange?("Phone connections are off: \(error.localizedDescription)")
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        guard let peer = Self.address(of: connection.endpoint), Tailnet.isAllowedPeer(peer) else {
            connection.cancel()
            return
        }
        let channel = WebSocketChannel(connection: connection)
        onConnection?(channel, peer)
        channel.start()
    }

    static func address(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)"
        case .ipv6(let a): return "\(a)"
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Every address on this Mac's interfaces, numeric.
    static func localAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = ptr.pointee.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            result.append(String(decoding: bytes, as: UTF8.self))
        }
        return result
    }
}
