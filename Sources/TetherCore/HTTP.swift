import Foundation

/// Just enough HTTP/1.1 for Claude Code's hook POSTs on localhost.
/// One request per connection; the server closes after responding.
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Header names lowercased.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum HTTPParseResult: Sendable, Equatable {
    case incomplete
    case complete(HTTPRequest)
    case invalid
}

public enum HTTPRequestParser {
    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 2 * 1024 * 1024

    public static func parse(_ input: Data) -> HTTPParseResult {
        let data = Data(input) // rebase slices to index 0
        let separator = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: separator) else {
            return data.count > maxHeaderBytes ? .invalid : .incomplete
        }
        let headerEnd = sepRange.lowerBound
        guard headerEnd <= maxHeaderBytes,
              let headerText = String(data: data[0..<headerEnd], encoding: .utf8) else { return .invalid }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = sepRange.upperBound
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0, n <= maxBodyBytes else { return .invalid }
            length = n
        } else if headers["transfer-encoding"] != nil {
            return .invalid // chunked bodies are not used by Claude Code hooks
        }
        guard data.count - bodyStart >= length else { return .incomplete }

        let body = data.subdata(in: bodyStart..<(bodyStart + length))
        var path = String(requestLine[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: body))
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
    public var contentType: String

    public init(status: Int, body: Data = Data(), contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    /// 200 with an empty body: Claude Code treats it as "hook ran, no decision".
    public static let empty = HTTPResponse(status: 200)

    public func serialized() -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Status"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
