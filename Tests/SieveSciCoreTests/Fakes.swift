import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SieveSciCore

/// A provider that replies from a script, for exercising the agent machinery without network.
final class ScriptedProvider: LLMProvider, @unchecked Sendable {
    let profile: ProviderProfile
    private let lock = NSLock()
    private var replies: [String]
    private(set) var requests: [LLMRequest] = []
    var stop: StopReason = .endTurn

    init(id: String = "fake", replies: [String]) {
        profile = ProviderProfile(id: id, displayName: id, family: .openaiChat, baseURL: "http://localhost", auth: .none, apiKeyRef: "", models: ["m"])
        self.replies = replies
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let text = replies.isEmpty ? "" : replies.removeFirst()
        let stop = self.stop
        lock.unlock()
        return AsyncThrowingStream { c in
            c.yield(.textDelta(text))
            c.yield(.completed(LLMResponse(message: Message(role: .assistant, blocks: [.text(text)]), stopReason: stop,
                                           usage: Usage(input: 10, output: 5))))
            c.finish()
        }
    }
}

func makeServices(_ provider: LLMProvider = ScriptedProvider(replies: []), checker: LLMProvider? = nil) throws -> (SessionServices, URL) {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    let s = try SessionServices(taskId: "t1", workspace: ws,
                                models: RoleModels(main: (provider, "m"), checker: checker.map { ($0, "m") }),
                                secrets: EnvironmentSecretStore())
    return (s, ws)
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}

/// Answers HTTP requests from canned bodies keyed by URL substring (first match wins), so tools that
/// call web APIs run offline. A route may list several responses; they are served in turn and the
/// last one repeats. Unmatched URLs get 404.
final class RoutedHTTP: HTTPStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(String, [(Int, String)])]
    private(set) var urls: [String] = []

    init(_ routes: [(String, String)]) { self.routes = routes.map { ($0.0, [(200, $0.1)]) } }
    init(sequenced: [(String, [(Int, String)])]) { routes = sequenced }

    func send(_ request: URLRequest) async throws -> (Int, Data) {
        let url = request.url?.absoluteString ?? ""
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
        guard let i = routes.firstIndex(where: { url.contains($0.0) }) else { return (404, Data(#"{"error":"not found"}"#.utf8)) }
        let r = routes[i].1.count > 1 ? routes[i].1.removeFirst() : routes[i].1[0]
        return (r.0, Data(r.1.utf8))
    }

    func postSSE(_ request: URLRequest) async throws -> HTTPStreamResponse { throw ToolError.invalidInput("no SSE in tests") }
}

func toolContext(http: HTTPStreaming) throws -> (ToolContext, SessionServices) {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    let s = try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (ScriptedProvider(replies: []), "m")),
                                secrets: EnvironmentSecretStore(), http: http)
    return (ToolContext(workspace: ws, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s), s)
}
