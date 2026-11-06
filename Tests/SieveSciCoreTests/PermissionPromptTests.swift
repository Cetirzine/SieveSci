import Foundation
import Testing
@testable import SieveSciCore

/// Parallel agents asking for approval at once (the hang of 2026-11-06: three plan workers asked, the
/// window showed the first, and after it was answered the other two waited for prompts never shown).
@Suite struct PermissionPrompts {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var announced: [String] = []
        var waiting: [String: CheckedContinuation<PermissionDecision, Never>] = [:]
        func add(_ id: String) { lock.withLock { announced.append(id) } }
        var shown: [String] { lock.withLock { announced } }
        func park(_ id: String, _ c: CheckedContinuation<PermissionDecision, Never>) { lock.withLock { waiting[id] = c } }
        func answer(_ id: String, _ d: PermissionDecision) { lock.withLock { waiting.removeValue(forKey: id) }?.resume(returning: d) }
        func isWaiting(_ id: String) -> Bool { lock.withLock { waiting[id] != nil } }
    }

    func services(_ box: Box) throws -> SessionServices {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-perm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let s = try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (ScriptedProvider(replies: []), "m")),
                                    secrets: EnvironmentSecretStore(), permissionMode: .ask)
        s.emit = { e in if case .permissionRequested(let r) = e { box.add(r.id) } }
        s.requestPermission = { r in await withCheckedContinuation { box.park(r.id, $0) } }
        return s
    }

    static func req(_ id: String) -> PermissionRequest {
        PermissionRequest(id: id, tool: "bash", summary: id, input: [:], effect: .executes, rememberPattern: "bash")
    }

    func until(_ cond: @escaping () -> Bool) async {
        for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    @Test func aRequestIsAnnouncedWhenItIsAsked() async throws {
        let box = Box()
        let s = try services(box)
        let a = Task { await s.askUser(Self.req("a")) }
        await until { box.isWaiting("a") }
        let b = Task { await s.askUser(Self.req("b")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(box.shown == ["a"], "the second request waits its turn unannounced")
        box.answer("a", .allowOnce)
        #expect(await a.value == .allowOnce)
        await until { box.isWaiting("b") }
        #expect(box.shown == ["a", "b"], "the second is announced once it is the one asked")
        box.answer("b", .deny("no"))
        #expect(await b.value == .deny("no"))
    }

    @Test func aStoppedAgentIsNotAsked() async throws {
        let box = Box()
        let s = try services(box)
        let a = Task { await s.askUser(Self.req("a")) }
        await until { box.isWaiting("a") }
        let stopped = Task { await s.askUser(Self.req("b"), cancelled: { true }) }
        box.answer("a", .allowOnce)
        _ = await a.value
        #expect(await stopped.value == .deny("stopped by the user"))
        #expect(box.shown == ["a"])
    }
}
