import Foundation

/// What the Mac's pairing QR encodes:
/// `tether://pair?v=1&host=100.x.y.z&port=7891&code=ABCD2345&name=Mac%20mini`.
public struct PairingLink: Hashable, Sendable {
    public static let scheme = "tether"
    public static let version = 1

    public var host: String
    public var port: Int
    public var code: String
    public var macName: String

    public init(host: String, port: Int, code: String, macName: String) {
        self.host = host
        self.port = port
        self.code = code
        self.macName = macName
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "pair"
        c.queryItems = [
            URLQueryItem(name: "v", value: String(Self.version)),
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "name", value: macName),
        ]
        return c.url!
    }

    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == Self.scheme, c.host == "pair" else { return nil }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value }
        guard q["v"].flatMap(Int.init) == Self.version,
              let host = q["host"], !host.isEmpty,
              let port = q["port"].flatMap(Int.init), (1...65535).contains(port),
              let code = q["code"], !code.isEmpty
        else { return nil }
        self.init(host: host, port: port, code: code, macName: q["name"] ?? host)
    }
}
