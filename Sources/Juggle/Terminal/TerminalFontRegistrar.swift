import CoreText
import Foundation

/// macOS ships the SF Mono faces **only inside Terminal.app's own bundle** — they
/// are not installed in the shared font collection. Ghostty resolves
/// `font-family = SF Mono` through CoreText, and CoreText silently swaps an
/// unknown family for a *proportional* fallback (Helvetica). In a fixed terminal
/// grid that reads as misaligned, "thin", and unlike the system Terminal — the
/// exact symptom of "replicate my Terminal but it still looks wrong".
///
/// So before any terminal is created we register Terminal.app's bundled faces for
/// this process, and we never emit a `font-family` that would resolve to a
/// non-monospaced face: if SF Mono cannot be found we fall back to Menlo, which
/// is always installed and always monospaced.
enum TerminalFontRegistrar {
    /// Where Apple keeps the SF Mono faces (current path first, legacy second).
    private static let bundledFontDirectories = [
        "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts",
        "/Applications/Utilities/Terminal.app/Contents/Resources/Fonts",
    ]

    /// Registers the bundled faces exactly once. `static let` initialisation is
    /// thread-safe, so this is safe to trigger from any thread. Failures are
    /// deliberately ignored: a missing/again-registered file just means callers
    /// fall back to a system monospaced font.
    private static let registrationToken: Void = {
        let fileManager = FileManager.default
        for directory in bundledFontDirectories {
            let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            ) else { continue }
            for fontURL in entries
            where ["otf", "ttf", "ttc"].contains(fontURL.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
            }
        }
    }()

    /// Make sure the bundled SF Mono faces are registered for this process.
    /// Idempotent and cheap after the first call.
    static func ensureRegistered() {
        _ = registrationToken
    }

    /// Whether `family` resolves to a genuinely monospaced face *right now*.
    /// CoreText resolution is what Ghostty itself does, so this is the truth.
    static func isMonospacedFamilyAvailable(_ family: String) -> Bool {
        ensureRegistered()
        let attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: family]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let resolved = CTFontCopyFamilyName(font) as String
        guard resolved.caseInsensitiveCompare(family) == .orderedSame else { return false }
        return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
    }

    /// The preferred family when it is a real monospaced face, otherwise a
    /// guaranteed-installed monospaced fallback so terminal text is never drawn
    /// in a proportional font.
    static func resolvedMonospacedFamily(preferred: String, fallback: String = "Menlo") -> String {
        isMonospacedFamilyAvailable(preferred) ? preferred : fallback
    }
}
