import AppKit

/// Renders an `AttentionState` onto a window's identity accent. Decoupled from
/// detection so chrome iteration (U8) never touches `StateDetector`.
@MainActor
protocol AttentionRenderer: AnyObject {
    func render(_ state: AttentionState, repoColor: NSColor, reducedMotion: Bool)
}

/// The signature behavior: the repo's accent breathes when an agent needs you.
/// Identity stays the hue; attention is motion + intensity on that hue. Honors
/// reduce-motion by degrading to a static intensity instead of animation.
@MainActor
final class CABreathingRenderer: AttentionRenderer {
    private weak var layer: CALayer?

    init(layer: CALayer) {
        self.layer = layer
    }

    func render(_ state: AttentionState, repoColor: NSColor, reducedMotion: Bool) {
        guard let layer else { return }
        layer.removeAllAnimations()

        switch state.motion {
        case .none:
            layer.backgroundColor = repoColor.cgColor
            layer.opacity = 1

        case .breathe:
            layer.backgroundColor = repoColor.cgColor
            reducedMotion ? setStaticIntensity(layer) : addBreathing(layer)

        case .breatheWarning:
            let warning = repoColor.blended(withFraction: 0.45, of: .systemRed) ?? repoColor
            layer.backgroundColor = warning.cgColor
            reducedMotion ? setStaticIntensity(layer) : addBreathing(layer)

        case .pulseOnce:
            layer.backgroundColor = repoColor.cgColor
            // Done/idle is intentionally calmer after the one pulse; command
            // finished is purely transient and returns to the normal accent.
            layer.opacity = state == .done ? 0.68 : 1
            if !reducedMotion { addSinglePulse(layer) }
        }
    }

    private func setStaticIntensity(_ layer: CALayer) {
        // Reduce-motion: a brighter, held accent stands in for the pulse.
        layer.opacity = 1
    }

    private func addBreathing(_ layer: CALayer) {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1.0
        breathe.toValue = 0.32
        breathe.duration = 1.1
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breathe, forKey: "attention.breathe")
    }

    private func addSinglePulse(_ layer: CALayer) {
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [1.0, 0.3, 1.0]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 0.9
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: "attention.pulse")
    }
}
