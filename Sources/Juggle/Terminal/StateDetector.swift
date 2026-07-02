import Foundation

/// Maps raw engine signals to a single presentation `AttentionState`. Pure
/// policy: no AppKit, no animation. The reliability open question lives entirely
/// here — when better "blocked" detection lands, only this mapping changes.
@MainActor
final class StateDetector {
    private(set) var state: AttentionState = .working
    var onChange: ((AttentionState) -> Void)?

    /// A successful command faster than this is routine and raises no attention.
    private let longRunningThresholdNanos: UInt64 = 10_000_000_000 // 10s

    func ingest(_ signal: RawAgentSignal) {
        switch signal {
        case .bell:
            transition(to: .blocked)
        case let .desktopNotification(title, body):
            transition(to: Self.notificationLooksDone(title: title, body: body) ? .done : .blocked)
        case let .commandFinished(exitCode, durationNanos):
            if let code = exitCode, code != 0 {
                transition(to: .error)
            } else if exitCode == 0, durationNanos >= longRunningThresholdNanos {
                transition(to: .commandFinished)
            }
            // A nil (unreported) exit, or a short successful command, is routine:
            // no state change.
        case .progressError:
            transition(to: .error)
        case .focused:
            transition(to: .working)
        }
    }

    private static func notificationLooksDone(title: String, body: String) -> Bool {
        let text = "\(title) \(body)".lowercased()
        if ["waiting", "input", "permission", "approval", "approve", "yes", "continue"].contains(where: text.contains) {
            return false
        }
        return ["done", "complete", "completed", "finished", "success", "idle"].contains(where: text.contains)
    }

    /// The user is now attending to this surface (focus / first input).
    func clear() {
        transition(to: .working)
    }

    private func transition(to next: AttentionState) {
        guard next != state else { return }
        state = next
        onChange?(next)
    }
}
