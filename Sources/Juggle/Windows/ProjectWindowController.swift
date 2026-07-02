import AppKit

@MainActor
final class ProjectWindowController: NSWindowController, NSWindowDelegate {
    let id = UUID()
    private(set) var context: SessionContext
    var onClose: (() -> Void)?
    var onMoved: (() -> Void)?
    var gridSlot = 0
    var screenIndex = 0

    private let session: TerminalSession
    private var renderer: AttentionRenderer?
    private var refreshWork: DispatchWorkItem?

    init(context: SessionContext, controllers: RepoControllerRegistry) {
        self.context = context
        self.session = TerminalSession(context: context, controllers: controllers)
        let window = ProjectWindow(context: context, content: session.view)
        super.init(window: window)
        window.delegate = self

        if let layer = window.accentLayer {
            renderer = CABreathingRenderer(layer: layer)
        }
        session.onAttentionChange = { [weak self] state in
            self?.attentionChanged(state)
        }
        // The window shows the project's name, never the raw shell title — but the
        // raw title (running program / cwd) labels the terminal in the panel tree.
        session.onTitleChange = { [weak self] raw in
            guard let self else { return }
            self.window?.title = self.context.displayName
            AppModel.shared.updateTerminalTitle(id: self.id, title: raw)
        }
        AppModel.shared.registerTerminal(
            id: id,
            projectId: context.projectId,
            worktreeId: context.worktreeId,
            title: context.worktreeDisplayName
        )
        refreshGitState()
        refreshPRState()
    }

    /// Bring this window forward and put the cursor in its terminal so the user
    /// can type immediately (used by click-to-jump from the control panel).
    func focusTerminal() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(session.view)
        NSApp.activate(ignoringOtherApps: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Re-apply identity and preference-derived behavior after a settings change.
    func updateContext(_ context: SessionContext) {
        self.context = context
        (window as? ProjectWindow)?.apply(context: context)
        session.applyAppearance(context)
        render(session.attentionState)
    }

    func diagnosticReport() -> String {
        session.diagnosticReport(window: window)
    }

    private func attentionChanged(_ state: AttentionState) {
        render(state)
        AppModel.shared.updateTerminalAttention(id: id, state)
        if state == .blocked, context.soundOnBlocked { NSSound.beep() }
    }

    private func render(_ state: AttentionState) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || !context.breathingEnabled
        renderer?.render(state, repoColor: context.lineColor, reducedMotion: reduce)
    }

    private func refreshGitState() {
        let path = context.cwd
        Task { [weak self] in
            let snapshot = await GitService.shared.snapshot(at: path)
            guard let self else { return }
            let branch = snapshot.branch ?? self.context.branch
            (self.window as? ProjectWindow)?.setBranch(branch, dirty: snapshot.isDirty)
        }
    }

    /// Surface the contextual Merge action only when git says the branch is
    /// actually mergeable.
    private func refreshPRState() {
        let path = context.cwd
        Task { [weak self] in
            let status = await GhService.shared.status(at: path)
            guard let self else { return }
            (self.window as? ProjectWindow)?.setMerge(status) { [weak self] in
                self?.confirmMergeAfterFreshCheck()
            }
        }
    }

    private func confirmMergeAfterFreshCheck() {
        let path = context.cwd
        (window as? ProjectWindow)?.setMergeChecking()
        Task { [weak self] in
            guard let self else { return }
            let status = await GhService.shared.refreshStatus(at: path)
            AppModel.shared.setPRStatus(status, for: path)
            (self.window as? ProjectWindow)?.setMerge(status) { [weak self] in
                self?.confirmMergeAfterFreshCheck()
            }
            self.confirmMerge(status)
        }
    }

    private func confirmMerge(_ status: PRStatus) {
        guard status.availability == .available, let number = status.number, let headOid = status.headOid else {
            alert("Not mergeable yet", mergeBlockerMessage(for: status))
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merge PR #\(number)?"
        alert.informativeText = "Runs gh pr merge --squash. This cannot be undone."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let path = context.cwd
        Task { [weak self] in
            let result = await GhService.shared.merge(at: path, number: number, headOid: headOid)
            if result.succeeded {
                AppModel.shared.setPRStatus(.none, for: path)
                self?.refreshPRState()
                self?.refreshGitState()
            } else {
                self?.alert("Merge failed", result.failureMessage ?? "gh could not merge the PR.")
            }
        }
    }

    private func mergeBlockerMessage(for status: PRStatus) -> String {
        switch status.availability {
        case .none:
            return "No open pull request was found for this branch."
        case .available:
            return "GitHub did not return the PR number or head commit needed to merge safely."
        case .checksRunning, .behind, .draft, .blocked:
            return status.summary.isEmpty ? "GitHub does not report this PR as mergeable right now." : status.summary
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        session.clearAttention()
        // Debounce the git/gh refresh: focus arrives in bursts (app activation,
        // window cycling, popover show/close). Data is fresh, ~0.5s behind focus.
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshGitState()
            self.refreshPRState()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func windowWillClose(_ notification: Notification) {
        refreshWork?.cancel()
        AppModel.shared.removeTerminal(id: id)
        onClose?()
    }

    func windowDidMove(_ notification: Notification) {
        onMoved?()
    }
}
