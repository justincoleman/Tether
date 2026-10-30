import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TetherCore

// Each case owns external processes. Avoid launching every fixture alongside
// the package's parallel git tests on small CI runners.
@Suite(.serialized) struct CodexAppServerTests {
    // A local child speaking the actual newline-delimited RPC transport. No
    // Codex account, network, or model request is involved.
    private static let server = #"""
import json, sys, time
initialized = False
initialization = None
waiting = []
def emit(value, split=False):
    text = json.dumps(value) + '\n'
    if split:
        sys.stdout.write(text[:7]); sys.stdout.flush(); time.sleep(0.01)
        sys.stdout.write(text[7:])
    else:
        sys.stdout.write(text)
    sys.stdout.flush()
for line in sys.stdin:
    m = json.loads(line)
    method = m.get('method')
    if method == 'initialize':
        initialization = m['params']
        emit({'id':m['id'],'result':{'userAgent':'fake'}}, True)
    elif method == 'initialized':
        initialized = True
        emit({'method':'ready','params':{'initialized':True}})
        emit({'id':'approval-a','method':'item/commandExecution/requestApproval','params':{'command':'pwd'}})
    elif method == 'echo':
        if not initialized:
            emit({'id':m['id'],'error':{'code':-1,'message':'not initialized'}})
        else:
            emit({'id':m['id'],'result':{'input':m['params'],'initialization':initialization}})
    elif method == 'reverse':
        waiting.append(m)
        if len(waiting) == 2:
            for item in reversed(waiting):
                emit({'id':item['id'],'result':item['params']})
            waiting = []
    elif method == 'fail':
        emit({'id':m['id'],'error':{'code':-32000,'message':'request rejected'}})
    elif method == 'malformed':
        emit({'id':m['id']})
    elif method == 'integerApproval':
        emit({'id':42,'method':'approval','params':{}})
        emit({'id':m['id'],'result':None})
    elif method == 'unicode':
        raw = (json.dumps({'id':m['id'],'result':'😀 café'}, ensure_ascii=False) + '\n').encode('utf-8')
        offset = raw.index('😀'.encode('utf-8')) + 1
        sys.stdout.buffer.write(raw[:offset]); sys.stdout.buffer.flush(); time.sleep(0.01)
        sys.stdout.buffer.write(raw[offset:]); sys.stdout.buffer.flush()
    elif method == 'oversized':
        sys.stdout.write('x' * (16 * 1024 * 1024 + 1)); sys.stdout.flush()
    elif method == 'partialExit':
        sys.stdout.write('{"id":'); sys.stdout.flush(); sys.exit(0)
    elif method == 'exit':
        sys.exit(0)
    elif method == 'hang':
        pass
    elif method is None:
        emit({'method':'replyObserved','params':m})
"""#

    private func client(timeout: Duration = .seconds(30)) -> CodexAppServer {
        CodexAppServer(configuration: .init(
            workingDirectory: FileManager.default.temporaryDirectory.path,
            clientVersion: "test-version",
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-u", "-c", Self.server],
            requestTimeout: timeout))
    }

    @Test func brokenPipeCannotTerminateClientProcess() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/test-codex-pipe.sh").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit, "Child was killed by a signal")
        #expect(process.terminationStatus == 0, "\(String(decoding: data, as: UTF8.self))")
    }

    @Test func initializesBeforeRequestsAndReadsFragmentedFrames() async throws {
        let c = client()
        try await c.start()
        let result = try await c.request("echo", params: .object(["text": .string("hello")]))
        #expect(result["input"]?["text"]?.stringValue == "hello")
        #expect(result["initialization"]?["clientInfo"]?["name"]?.stringValue == "tether")
        #expect(result["initialization"]?["clientInfo"]?["version"]?.stringValue == "test-version")
        await c.stop()
    }

    @Test func routesOutOfOrderRepliesToTheirCallers() async throws {
        let c = client()
        try await c.start()
        async let first = c.request("reverse", params: .string("first"))
        async let second = c.request("reverse", params: .string("second"))
        let results = try await (first, second)
        #expect(results.0 == .string("first"))
        #expect(results.1 == .string("second"))
        await c.stop()
    }

    @Test func forwardsNotificationsAndAnswersStringServerRequestIDs() async throws {
        let c = client()
        try await c.start()
        var events = c.events.makeAsyncIterator()
        guard case .notification(let ready, let params) = await events.next() else {
            Issue.record("missing notification"); await c.stop(); return
        }
        #expect(ready == "ready" && params["initialized"] == .bool(true))
        guard case .request(let id, let method, let request) = await events.next() else {
            Issue.record("missing server request"); await c.stop(); return
        }
        #expect(id == .string("approval-a"))
        #expect(method == "item/commandExecution/requestApproval" && request["command"] == .string("pwd"))
        try await c.respond(to: id, result: .object(["decision": .string("decline")]))
        guard case .notification(let observed, let reply) = await events.next() else {
            Issue.record("missing reply observation"); await c.stop(); return
        }
        #expect(observed == "replyObserved")
        #expect(reply["id"] == id && reply["result"]?["decision"] == .string("decline"))
        await c.stop()
    }

    @Test func preservesSplitUTF8AndRejectsTruncatedOrOversizedFrames() async throws {
        let c = client()
        try await c.start()
        #expect(try await c.request("unicode", params: .null) == .string("😀 café"))
        await #expect(throws: CodexAppServerError.self) { try await c.request("partialExit", params: .null) }
        await c.stop()
        let large = client()
        try await large.start()
        await #expect(throws: CodexAppServerError.self) { try await large.request("oversized", params: .null) }
        await large.stop()
    }

    @Test func answersIntegerServerRequestWithError() async throws {
        let c = client()
        try await c.start()
        _ = try await c.request("integerApproval", params: .null)
        var events = c.events.makeAsyncIterator()
        while let event = await events.next() {
            if case .request(let id, _, _) = event, id == .number(42) {
                try await c.respondError(to: id, message: "Unsupported request")
            }
            if case .notification(let method, let params) = event, method == "replyObserved" {
                #expect(params["id"] == .number(42))
                #expect(params["error"]?["code"] == .number(-32601))
                await c.stop()
                return
            }
        }
        Issue.record("missing integer reply")
    }

    @Test func optionalRealCLIInitializeOnly() async throws {
        guard let executable = ProcessInfo.processInfo.environment["TETHER_CODEX_SMOKE_EXECUTABLE"] else { return }
        let c = CodexAppServer(configuration: .init(
            workingDirectory: FileManager.default.temporaryDirectory.path,
            clientVersion: "test-version", executableURL: URL(fileURLWithPath: executable)))
        try await c.start()
        await c.stop()
    }

    @Test func rpcErrorsDoNotLoseTheConnection() async throws {
        let c = client()
        try await c.start()
        await #expect(throws: CodexAppServerError.self) { try await c.request("fail", params: .object([:])) }
        #expect(try await c.request("echo", params: .string("after"))["input"] == .string("after"))
        await c.stop()
    }

    @Test func malformedReplyFailsPendingRequest() async throws {
        let c = client()
        try await c.start()
        await #expect(throws: CodexAppServerError.self) { try await c.request("malformed", params: .object([:])) }
        await c.stop()
    }

    @Test func eofAndStopReleasePendingRequests() async throws {
        let c = client()
        try await c.start()
        await #expect(throws: CodexAppServerError.self) { try await c.request("exit", params: .object([:])) }
        await c.stop()
        let other = client()
        try await other.start()
        let pending = Task { try await other.request("hang", params: .object([:])) }
        try await Task.sleep(for: .milliseconds(30))
        await other.stop()
        await #expect(throws: CodexAppServerError.self) { try await pending.value }
    }

    @Test func stopWaitsForChildIgnoringTermination() async throws {
        let stubborn = #"""
import json,sys,signal,os
signal.signal(signal.SIGTERM, signal.SIG_IGN)
for line in sys.stdin:
    m=json.loads(line)
    if m.get('method')=='initialize':
        print(json.dumps({'id':m['id'],'result':{}}),flush=True)
    elif m.get('method')=='initialized':
        print(json.dumps({'method':'childPID','params':{'pid':os.getpid()}}),flush=True)
# Closing stdin must not accidentally terminate this fixture before SIGKILL.
while True:
    signal.pause()
"""#
        let c = CodexAppServer(configuration: .init(
            workingDirectory: FileManager.default.temporaryDirectory.path, clientVersion: "test",
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["python3", "-u", "-c", stubborn]))
        try await c.start()
        var childPID: Int32?
        for await event in c.events {
            if case .notification("childPID", let params) = event,
               case .number(let pid)? = params["pid"] { childPID = Int32(pid); break }
        }
        await c.stop()
        let pid = try #require(childPID)
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "Awaited stop left its owned child alive")
    }

    @Test func unansweredRequestsTimeOutAndStopTheConnection() async throws {
        let c = client(timeout: .seconds(10))
        try await c.start()
        await #expect(throws: CodexAppServerError.self) { try await c.request("hang", params: .object([:])) }
        await #expect(throws: CodexAppServerError.self) { try await c.request("echo", params: .null) }
        await c.stop()
    }
}
