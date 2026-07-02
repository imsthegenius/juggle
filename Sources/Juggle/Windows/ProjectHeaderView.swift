import AppKit

/// The colored identity bar at the top of a project window. Carries the repo
/// (or worktree) tint, the project's display name, its branch, and the
/// contextual Merge action. Sits under the real traffic-light controls via a
/// transparent full-size-content titlebar.
@MainActor
final class ProjectHeaderView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let mergeButton = NSButton()
    private var onMerge: (() -> Void)?
    private var worktreeDisplayName = ""
    private var worktreePathDisplay = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setup() {
        wantsLayer = true

        nameLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        branchLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        branchLabel.lineBreakMode = .byTruncatingTail

        stateLabel.font = .systemFont(ofSize: 11, weight: .medium)
        stateLabel.isHidden = true

        mergeButton.title = "Merge"
        mergeButton.bezelStyle = .badge
        mergeButton.controlSize = .small
        mergeButton.isHidden = true
        mergeButton.target = self
        mergeButton.action = #selector(mergeTapped)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [nameLabel, branchLabel, spacer, stateLabel, mergeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 82),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        name: String,
        worktree: String,
        path: String,
        accent: NSColor,
        tintFraction: CGFloat,
        lightChrome: Bool,
        themeName: String
    ) {
        nameLabel.stringValue = name
        worktreeDisplayName = worktree
        worktreePathDisplay = path
        branchLabel.toolTip = "\(worktree) · \(path)\nTerminal theme: \(themeName)"

        let base = lightChrome
            ? NSColor(calibratedWhite: 0.88, alpha: 1)
            : NSColor(calibratedWhite: 0.16, alpha: 1)
        let fraction = lightChrome ? min(0.22, tintFraction * 0.55) : tintFraction
        layer?.backgroundColor = (base.blended(withFraction: fraction, of: accent) ?? base).cgColor

        nameLabel.textColor = lightChrome ? NSColor(calibratedWhite: 0.10, alpha: 1) : .white
        branchLabel.textColor = lightChrome
            ? NSColor(calibratedWhite: 0.18, alpha: 0.74)
            : NSColor.white.withAlphaComponent(0.62)
        stateLabel.textColor = lightChrome
            ? NSColor(calibratedWhite: 0.18, alpha: 0.78)
            : NSColor.white.withAlphaComponent(0.72)
    }

    func setBranch(_ branch: String?, dirty: Bool) {
        let branchText = Self.displayBranch(branch, fallback: worktreeDisplayName)
        var parts = [branchText]
        if !worktreePathDisplay.isEmpty { parts.append(worktreePathDisplay) }
        if dirty { parts.append("modified") }
        branchLabel.stringValue = parts.joined(separator: " · ")
    }

    nonisolated static func displayBranch(_ branch: String?, fallback: String) -> String {
        let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return fallback.isEmpty ? "Worktree" : fallback }
        if trimmed == "HEAD" || trimmed == "detached" { return "Detached checkout" }
        return trimmed
    }

    func setMerge(_ status: PRStatus, onMerge: @escaping () -> Void) {
        self.onMerge = onMerge
        switch status.availability {
        case .none:
            mergeButton.title = "Merge"
            mergeButton.isEnabled = true
            mergeButton.isHidden = true
            stateLabel.isHidden = true
        case .available:
            stateLabel.isHidden = true
            mergeButton.title = "Merge"
            mergeButton.isEnabled = true
            mergeButton.isHidden = false
        default:
            mergeButton.title = "Merge"
            mergeButton.isEnabled = true
            mergeButton.isHidden = true
            stateLabel.isHidden = false
            stateLabel.stringValue = status.summary
        }
    }

    func setMergeChecking() {
        stateLabel.isHidden = true
        mergeButton.title = "Checking..."
        mergeButton.isEnabled = false
        mergeButton.isHidden = false
    }

    @objc private func mergeTapped() { onMerge?() }
}
