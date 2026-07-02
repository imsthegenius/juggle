import AppKit

/// Owns the live terminal windows and grid arrangement; reads from `AppModel`.
/// SwiftUI surfaces (control panel, Settings) drive it through the model's
/// callbacks.
@MainActor
final class AppController {
    private let model = AppModel.shared
    private let controllers = RepoControllerRegistry()
    private let grid = WindowGridManager()
    private var windows: [ProjectWindowController] = []
    private var isArranging = false
    private var snapWork: DispatchWorkItem?

    func start() {
        model.load()
        // SF Mono ships only inside Terminal.app's bundle; register those faces
        // for this process before any Ghostty controller is created so a saved
        // "SF Mono"/"SF Mono Terminal" preference resolves to a real monospaced
        // font instead of CoreText's proportional Helvetica fallback.
        TerminalFontRegistrar.ensureRegistered()
        model.onOpenWindow = { [weak self] context in self?.openWindow(context) }
        model.onPreferencesChanged = { [weak self] _ in self?.applyPreferences() }
        model.onFocusTerminal = { [weak self] id in self?.focusTerminal(id) }
        // `RepoControllerRegistry` is constructed before the persisted
        // workspace is loaded. Push the loaded terminal theme/font into the
        // registry before the first window creates a Ghostty controller;
        // otherwise a saved light theme still opens a dark default terminal.
        applyPreferences()

        // `Juggle <path> ...` opens those repos. `--qa-shot <dir>` renders the
        // windows to PNGs and exits (used for headless visual QA).
        let args = Array(CommandLine.arguments.dropFirst())
        var qaShotDir: String?
        var repoPaths: [String] = []
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--qa-shot", index + 1 < args.count {
                qaShotDir = args[index + 1]
                index += 2
                continue
            }
            if !arg.hasPrefix("--"), isDirectory(arg) { repoPaths.append(arg) }
            index += 1
        }

        for path in repoPaths {
            let project = model.addProject(atRoot: path)
            if let worktree = project.primaryWorktree {
                model.openWindow(projectId: project.id, worktreeId: worktree.id)
            }
        }
        if repoPaths.isEmpty {
            restoreWindows()        // R17: reopen last session's grid (not processes)
        } else {
            tileGrid()
        }
        if let qaShotDir { scheduleDiagnosticCapture(to: qaShotDir) }
    }

    /// R17 / AE4: reopen the windows that were open at last quit, each into the
    /// grid slot it held, restoring layout + colors + assignments. A fresh shell
    /// spawns in each worktree's cwd; the previously running agents do not return.
    private func restoreWindows() {
        let saved = model.restoredWindows.sorted {
            ($0.screenIndex, $0.slot) < ($1.screenIndex, $1.slot)
        }
        guard !saved.isEmpty else { return }
        for entry in saved {
            guard let context = model.context(projectId: entry.projectId, worktreeId: entry.worktreeId)
            else { continue }
            openWindow(context, preferredSlot: entry.slot, preferredScreenIndex: entry.screenIndex)
        }
        tileGrid()
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func scheduleDiagnosticCapture(to dir: String) {
        (NSApp.delegate as? AppDelegate)?.showControlPanel(nil)
        (NSApp.delegate as? AppDelegate)?.showCommandCentre(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            var metrics: [String] = []
            for (idx, controller) in self.windows.enumerated() {
                metrics.append("== terminal-window[\(idx)] \(controller.window?.title ?? "untitled") ==")
                metrics.append(controller.diagnosticReport())
            }
            try? metrics.joined(separator: "\n").write(
                to: URL(fileURLWithPath: "\(dir)/terminal-metrics.txt"),
                atomically: true,
                encoding: .utf8
            )
            for (idx, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView, view.bounds.width > 1,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let title = window.title.isEmpty ? "window" : window.title.replacingOccurrences(of: "/", with: "_")
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "\(dir)/\(idx)-\(title).png"))
                }
            }
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    func openWindow(_ context: SessionContext,
                    preferredSlot: Int? = nil,
                    preferredScreenIndex: Int? = nil) -> ProjectWindowController {
        let controller = ProjectWindowController(context: context, controllers: controllers)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windows.removeAll { $0 === controller }
            self.persistOpenWindows()
            self.tileGrid()
        }
        controller.onMoved = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowDidDrag(controller)
        }
        let screenIndex = preferredScreenIndex ?? activeScreenIndex()
        controller.screenIndex = screenIndex
        controller.gridSlot = preferredSlot ?? nextFreeSlot(on: screenIndex)
        windows.append(controller)
        controller.window?.makeKeyAndOrderFront(nil)
        persistOpenWindows()
        tileGrid()                 // drop the new window straight into its grid cell
        return controller
    }

    /// Snapshot the live window set (identity + slot) into the model so the next
    /// launch can restore it (R17). Called on every open / close / slot change.
    private func persistOpenWindows() {
        model.saveOpenWindows(windows.map {
            OpenWindowState(projectId: $0.context.projectId,
                            worktreeId: $0.context.worktreeId,
                            slot: $0.gridSlot,
                            screenIndex: $0.screenIndex)
        })
    }

    private func nextFreeSlot(on screenIndex: Int) -> Int {
        let used = Set(windows.filter { $0.screenIndex == screenIndex }.map(\.gridSlot))
        var slot = 0
        while used.contains(slot) { slot += 1 }
        return slot
    }

    /// F1: choose a project folder, register it, open its primary worktree.
    func openProjectViaPanel(onOpened: ((Project) -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose a project folder or git repository"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else {
                onCancel?()
                return
            }
            let project = self.model.addProject(atRoot: url.path)
            if let worktree = project.primaryWorktree {
                self.model.openWindow(projectId: project.id, worktreeId: worktree.id)
            }
            onOpened?(project)
        }
    }

    /// Click-to-jump from the control panel: raise that terminal and focus it.
    func focusTerminal(_ id: UUID) {
        windows.first { $0.id == id }?.focusTerminal()
    }

    /// Open another terminal for the focused window's project + worktree.
    func newTerminalForKeyWindow() {
        let source = windows.first { $0.window === NSApp.keyWindow } ?? windows.last
        guard let context = source?.context else { return }
        openWindow(context)
    }

    /// Snap every visible window into its assigned display's grid cells. Slots are
    /// per-display, so the same slot can exist on display 0 and display 1.
    func tileGrid() {
        isArranging = true
        defer { isArranging = false }
        grid.gap = model.preferences.gapPoints
        let screens = orderedScreens()
        let grouped = Dictionary(grouping: windows) { min(max(0, $0.screenIndex), max(0, screens.count - 1)) }
        for (screenIndex, controllers) in grouped {
            let entries = visibleEntries(from: controllers)
            guard !entries.isEmpty else { continue }
            grid.tile(entries,
                      columns: model.preferences.gridColumns,
                      rows: model.preferences.gridRows,
                      on: screens.indices.contains(screenIndex) ? screens[screenIndex] : NSScreen.main)
        }
    }

    /// Visible, non-miniaturized windows paired with their slots — the set the
    /// grid operates on. Shared by `tileGrid` (all) and `snapToGrid` (one).
    private func visibleEntries() -> [(slot: Int, window: NSWindow)] {
        visibleEntries(from: windows)
    }

    private func visibleEntries(from controllers: [ProjectWindowController]) -> [(slot: Int, window: NSWindow)] {
        controllers.compactMap { controller -> (slot: Int, window: NSWindow)? in
            guard let window = controller.window, window.isVisible, !window.isMiniaturized else { return nil }
            return (controller.gridSlot, window)
        }
    }

    func setGrid(columns: Int, rows: Int) {
        model.preferences.gridColumns = max(1, columns)
        model.preferences.gridRows = max(1, rows)
        tileGrid()
    }

    /// Drag-to-snap: after a manual move settles, snap the window into the nearest
    /// cell, swapping slots with whatever was there.
    private func windowDidDrag(_ controller: ProjectWindowController) {
        guard !isArranging else { return }
        snapWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.snapToGrid(controller)
        }
        snapWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func snapToGrid(_ controller: ProjectWindowController) {
        guard let window = controller.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let screenIndex = screenIndex(for: screen)
        let frame = screen.visibleFrame
        let columns = max(1, model.preferences.gridColumns)
        let peers = windows.filter { $0.screenIndex == screenIndex || $0 === controller }
        let maxSlot = peers.map(\.gridSlot).max() ?? 0
        let rows = grid.effectiveRows(model.preferences.gridRows, columns: columns, maxSlot: maxSlot)
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let target = grid.nearestSlot(to: center, columns: columns, rows: rows, in: frame)
        let movedDisplays = screenIndex != controller.screenIndex
        if movedDisplays || target != controller.gridSlot {
            if let occupant = windows.first(where: {
                $0.screenIndex == screenIndex && $0.gridSlot == target && $0 !== controller
            }) {
                occupant.gridSlot = controller.gridSlot
                occupant.screenIndex = controller.screenIndex
            }
            controller.screenIndex = screenIndex
            controller.gridSlot = target
            persistOpenWindows()       // a slot/display swap changes saved layout (R17/R3)
            tileGrid()                 // a real slot swap may have moved another window too
        } else {
            // Slot unchanged: only the dragged window is out of place. Re-snap
            // just it into the cell a full tileGrid would compute (same geometry),
            // one setFrame instead of re-tiling every window.
            isArranging = true
            defer { isArranging = false }
            grid.gap = model.preferences.gapPoints
            grid.snap(window, slot: controller.gridSlot, among: visibleEntries(from: peers),
                      columns: model.preferences.gridColumns, rows: model.preferences.gridRows,
                      on: screen)
        }
    }

    private func orderedScreens() -> [NSScreen] {
        let screens = NSScreen.screens
        guard let main = NSScreen.main else { return screens }
        return screens.sorted { lhs, rhs in
            if lhs == main { return true }
            if rhs == main { return false }
            if lhs.frame.minX != rhs.frame.minX { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.minY > rhs.frame.minY
        }
    }

    private func screenIndex(for screen: NSScreen) -> Int {
        orderedScreens().firstIndex(of: screen) ?? 0
    }

    private func activeScreenIndex() -> Int {
        if let screen = NSApp.keyWindow?.screen { return screenIndex(for: screen) }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screenIndex(for: screen)
        }
        return 0
    }

    // MARK: - Git write actions (from the control panel)

    func openDraftPR(at path: String) {
        Task { [weak self] in
            let result = await GhService.shared.openDraftPR(at: path)
            self?.alert(
                result.succeeded ? "Draft PR opened" : "Couldn't open PR",
                result.succeeded ? "A draft pull request was created for this branch."
                                 : (result.failureMessage ?? "gh could not create a PR.")
            )
        }
    }

    func mergePR(at path: String) {
        Task { [weak self] in await self?.mergePRAfterFreshCheck(at: path) }
    }

    @discardableResult
    func mergePRAfterFreshCheck(at path: String) async -> PRMergeResult {
        let status = await GhService.shared.refreshStatus(at: path)
        model.setPRStatus(status, for: path)
        guard status.availability == .available, let number = status.number, let headOid = status.headOid else {
            alert("Not mergeable yet", mergeBlockerMessage(for: status))
            return PRMergeResult(outcome: .notMergeable, status: status)
        }
        let confirm = NSAlert()
        confirm.messageText = "Merge PR #\(number)?"
        confirm.informativeText = "Runs gh pr merge --squash. This cannot be undone."
        confirm.addButton(withTitle: "Merge")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else {
            return PRMergeResult(outcome: .cancelled, status: status)
        }
        let result = await GhService.shared.merge(at: path, number: number, headOid: headOid)
        if result.succeeded { model.setPRStatus(.none, for: path) }
        alert(result.succeeded ? "Merged" : "Merge failed",
              result.succeeded ? "PR #\(number) was merged." : (result.failureMessage ?? "gh could not merge the PR."))
        return PRMergeResult(outcome: result.succeeded ? .merged : .failed,
                             status: status,
                             failureMessage: result.failureMessage)
    }

    /// Merge a ready PR with no blocking confirm dialog — the notch's inline
    /// "Merge" button is the explicit intent. On success the PR drops out of the
    /// poll (the row vanishes); only a real failure surfaces, non-modally handled
    /// by the caller via the returned flag.
    @discardableResult
    func mergePRDirect(at path: String) async -> PRMergeResult {
        let result = await GhService.shared.mergeIfAvailable(at: path)
        switch result.outcome {
        case .merged:
            model.setPRStatus(.none, for: path)
        case .notMergeable, .failed, .cancelled:
            model.setPRStatus(result.status, for: path)
        }
        return result
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

    private func applyPreferences() {
        controllers.applyTheme(model.preferences.terminalTheme)
        controllers.applyFontSize(model.preferences.terminalFontSize)
        for controller in windows {
            guard let context = model.context(
                projectId: controller.context.projectId,
                worktreeId: controller.context.worktreeId
            ) else { continue }
            controller.updateContext(context)
        }
        tileGrid()   // re-apply gap / grid changes
    }
}
