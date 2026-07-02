import AppKit

/// A real terminal window whose colored titlebar carries the project identity.
/// Layout top to bottom: a tinted project header (under the real traffic-light
/// controls), a 2px accent line that breathes for attention, then the terminal.
@MainActor
final class ProjectWindow: NSWindow {
    private let header = ProjectHeaderView()
    private let accentLine = NSView()

    /// The layer the attention renderer drives (the accent line under the header).
    var accentLayer: CALayer? { accentLine.layer }

    init(context: SessionContext, content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = context.displayName  // for the Window menu / Mission Control
        titleVisibility = .hidden    // the header draws the name instead
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        tabbingMode = .disallowed
        minSize = NSSize(width: 420, height: 260)

        accentLine.wantsLayer = true

        let host = NSView()
        for view in [header, accentLine, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: host.topAnchor),
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            accentLine.topAnchor.constraint(equalTo: header.bottomAnchor),
            accentLine.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            accentLine.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            accentLine.heightAnchor.constraint(equalToConstant: 2),

            content.topAnchor.constraint(equalTo: accentLine.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        contentView = host

        apply(context: context)
        center()
    }

    /// Header carries the project color; the accent line carries the worktree color.
    func apply(context: SessionContext) {
        header.configure(
            name: context.displayName,
            worktree: context.worktreeDisplayName,
            path: context.worktreePathDisplay,
            accent: context.headerColor,
            tintFraction: context.tintFraction,
            lightChrome: context.terminalThemeIsLight,
            themeName: context.terminalThemeName
        )
        accentLine.layer?.backgroundColor = context.lineColor.cgColor
    }

    func setBranch(_ branch: String?, dirty: Bool) {
        header.setBranch(branch, dirty: dirty)
    }

    func setMerge(_ status: PRStatus, onMerge: @escaping () -> Void) {
        header.setMerge(status, onMerge: onMerge)
    }

    func setMergeChecking() {
        header.setMergeChecking()
    }
}
