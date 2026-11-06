import Foundation
import Testing
@testable import SieveSciCore

/// Auto mode (no approvals, always sandboxed) and YOLO mode (no approvals, no sandbox).
@Suite struct PermissionModes {
    @Test func yoloAndAutoAllowButTheDenyListStillHolds() {
        for mode in [PermissionMode.auto, .yolo] {
            let p = PermissionPolicy(mode: mode)
            #expect(p.evaluate(tool: "bash", input: ["command": "python run.py"], effect: .executes) == .allow)
            #expect(p.evaluate(tool: "write_file", input: ["path": "a.txt"], effect: .writesFiles) == .allow)
            if case .deny = p.evaluate(tool: "bash", input: ["command": "sudo rm -rf /tmp/x"], effect: .executes) {} else {
                Issue.record("\(mode): sudo must stay refused")
            }
        }
        #expect(PermissionPolicy(mode: .ask).evaluate(tool: "bash", input: ["command": "ls"], effect: .executes) == .ask)
    }

    @Test func autoAlwaysSandboxesAndYoloNever() {
        #expect(SandboxMode.off.effective(for: .auto) == .workspaceWrite)
        #expect(SandboxMode.workspaceWriteOffline.effective(for: .auto) == .workspaceWriteOffline)
        for s in SandboxMode.allCases { #expect(s.effective(for: .yolo) == .off) }
        for m in [PermissionMode.ask, .acceptEdits, .plan] {
            for s in SandboxMode.allCases { #expect(s.effective(for: m) == s) }
        }
    }

    @Test func yoloIsNeverSteppedInto() {
        #expect(!PermissionMode.cycle.contains(.yolo))
        #expect(Set(PermissionMode.menu) == Set(PermissionMode.allCases))
    }

    @Test func autoWithoutASandboxFromBeforeIsYolo() {
        var c = AppConfig()
        c.permissionMode = .auto; c.sandboxMode = .off
        #expect(c.migrated().permissionMode == .yolo)
        c.sandboxMode = .workspaceWrite
        #expect(c.migrated().permissionMode == .auto)
        c.permissionMode = .ask; c.sandboxMode = .off
        #expect(c.migrated().permissionMode == .ask)
    }
}
