import Foundation

/// What a window renders. Identity is the repo hue; attention is expressed as a
/// behavior on that hue (motion + intensity), never a competing color, with the
/// single exception of `error` which earns a restrained warning edge.
///
/// Only states the detector can actually produce are modeled here. The detection
/// layer speaks `RawAgentSignal`; `StateDetector` maps between them.
enum AttentionState: Equatable {
    /// Baseline: the agent is working, nothing wants the user.
    case working
    /// The agent needs a response (desktop notification / bell). The signature
    /// state: a steady, slow breathing pulse in the repo color.
    case blocked
    /// The agent reported that a task is done/idle. One soft pulse, then a calm
    /// held state (distinct from a transient long-command pulse).
    case done
    /// A long-running command completed. One transient pulse, no lingering glow.
    case commandFinished
    /// Something failed. Breathing carries a restrained warning edge.
    case error

    enum Motion {
        case none
        case breathe
        case breatheWarning
        case pulseOnce
    }

    var motion: Motion {
        switch self {
        case .working: .none
        case .blocked: .breathe
        case .done: .pulseOnce
        case .commandFinished: .pulseOnce
        case .error: .breatheWarning
        }
    }
}
