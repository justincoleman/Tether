import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Deliberately runs outside the test runner with SIGPIPE's default disposition.
@main struct CodexPipeSmoke {
    static func main() async throws {
        signal(SIGPIPE, SIG_DFL)
        let fake = #"""
import json,sys,os,time
for line in sys.stdin:
    m=json.loads(line)
    if m.get('method')=='initialize':
        print(json.dumps({'id':m['id'],'result':{}}),flush=True)
    elif m.get('method')=='initialized':
        os.close(0)
        print(json.dumps({'method':'stdinClosed','params':{}}),flush=True)
        time.sleep(5)
        break
"""#
        let server = CodexAppServer(configuration: .init(workingDirectory: FileManager.default.temporaryDirectory.path,
            clientVersion: "pipe-test", executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-u", "-c", fake], requestTimeout: .seconds(3)))
        try await server.start()
        for await event in server.events {
            if case .notification("stdinClosed", _) = event { break }
        }
        do {
            _ = try await server.request("write-after-close", params: .string(String(repeating: "x", count: 512 * 1024)))
            fatalError("Request unexpectedly succeeded")
        } catch CodexAppServerError.writeFailed {
            // EPIPE must become a recoverable connection error, never a process signal.
        }
        await server.stop()
        print("PASS: closed child stdin produced writeFailed with default SIGPIPE disposition")
    }
}
