// Sources/Sessylph/Session/SessionStateMachine.swift
import Foundation

enum SessionState: String, Sendable {
    case idle            // Not started
    case starting        // CLI process spawning
    case initializing    // Waiting for system/init message
    case ready           // Waiting for user input
    case streaming       // Claude is responding
    case awaitingPermission  // Waiting for user to approve tool use
    case compacting      // Context compaction in progress
    case terminated      // CLI exited (can restart)
    case error           // Unrecoverable error
}

@MainActor
@Observable
final class SessionStateMachine {
    private(set) var state: SessionState = .idle
    private(set) var lastError: String?
    private(set) var sessionId: String?
    private(set) var model: String?
    private(set) var totalCostUsd: Double = 0
    private(set) var pendingPermissionRequestId: String?

    func transition(to newState: SessionState) {
        state = newState
    }

    func handleInit(sessionId: String, model: String?) {
        self.sessionId = sessionId
        self.model = model
        transition(to: .ready)
    }

    func handleResult(cost: Double?) {
        if let cost { totalCostUsd += cost }
        pendingPermissionRequestId = nil
        transition(to: .ready)
    }

    func handlePermissionRequest(requestId: String) {
        pendingPermissionRequestId = requestId
        transition(to: .awaitingPermission)
    }

    func handlePermissionResolved() {
        pendingPermissionRequestId = nil
        transition(to: .streaming)
    }

    func handleError(_ message: String) {
        lastError = message
        transition(to: .error)
    }

    func handleTerminated() {
        transition(to: .terminated)
    }

    func reset() {
        state = .idle
        lastError = nil
        sessionId = nil
        model = nil
        totalCostUsd = 0
        pendingPermissionRequestId = nil
    }
}
