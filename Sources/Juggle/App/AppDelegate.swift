import AppKit
import Combine
import SwiftUI

enum JuggleShortcutAction: Equatable {
    case newTerminal
    case tileGrid
    case openRepo
    case settings
    case switcher
    case controlPanel
    case closeWindow
    case quit
    case none

    static func resolve(modifiers: NSEvent.ModifierFlags, characters: String?) -> JuggleShortcutAction {
        let modifiers = modifiers.intersection(.deviceIndependentFlagsMask)
        switch (modifiers, characters?.lowercased()) {
        case (.command, "n"): return .newTerminal
        case ([.command, .option], "g"): return .tileGrid
        case (.command, "o"): return .openRepo
        case (.command, ","): return .settings
        case (.command, "j"): return .switcher
        case (.command, "0"): return .controlPanel
        case (.command, "w"): return .closeWindow
        case (.command, "q"): return .quit
        default: return .none
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = AppController()
    private var controlPanel: NSWindow?
    private var commandCentre: NSWindow?
    private var shortcutMonitor: Any?
    private var onboardingWindow: NSWindow?
    private var onboardingModel: OnboardingModel?
    private var projectOpenWindow: NSWindow?
    private var suppressProjectPromptCloseFallback = false

    // ⌘J project switcher (R4/R12): a transient, centered command surface.
    private var switcherPanel: KeyablePanel?
    private var switcherModel: SwitcherModel?

    // Notch HUD: an ambient attention strip hanging from the menu bar / notch.
    private var notchPanel: NotchPanel?
    private var notchModel: NotchHUDModel?
    private var notchObserver: AnyCancellable?
    private var notchOutsideClickLocalMonitor: Any?
    private var notchOutsideClickGlobalMonitor: Any?
    private var prReadyPoll: Timer?
    private var activeScopeObserver: AnyCancellable?

    private var statusItem: NSStatusItem?
    private let controlPopover = NSPopover()
    private var attentionObserver: AnyCancellable?

    private static let appDelegateDiagnosticFlags: Set<String> = [
        "--onboarding-shots",
        "--project-open-shot",
        "--launch-surface-shot",
        "--control-panel-shot",
        "--notch-shot",
        "--notch-live",
        "--notch-click-test",
        "--notch-empty",
        "--launch-home-shot",
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Juggle is a dark app (its identity is color-on-dark); don't follow the
        // system light appearance for the panels.
        let diagnosticMode = hasAppDelegateDiagnostic
        let permitsUnbundledLaunch = diagnosticMode || Self.permitsControllerDiagnosticLaunch()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = JuggleMenu.build(target: self)
        installShortcutMonitor()
        setupStatusItem()
        guard !Self.shouldBlockUnbundledWorkspaceLaunch(diagnosticMode: permitsUnbundledLaunch) else {
            NSApp.activate(ignoringOtherApps: true)
            showUnsafeUnbundledLaunchNotice()
            return
        }
        if !diagnosticMode {
            controller.start()
            // Build the HUD after `controller.start()` has loaded persisted projects
            // and preferences. Otherwise the first PR poll sees an empty model and a
            // user who disabled the HUD still gets the default-on surface.
            setupNotchHUD()
        }
        NSApp.activate(ignoringOtherApps: true)
        // Launch follows the IDE pattern: restore saved work when projects exist;
        // otherwise put a real "open a project" window in front. The onboarding
        // tour remains explicit via Settings ▸ "Replay onboarding", and
        // `--onboarding-shots <dir>` still renders each step to PNG.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.runAppDelegateDiagnosticIfPresent() { return }
            self.showLaunchSurfaceForCurrentWorkspace()
        }
        // Reposition the HUD when displays change (notch laptop ⇄ external).
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    /// The embedded terminal binds some Cmd shortcuts itself, so it can swallow
    /// ⌘N before the menu sees it. A local monitor intercepts Juggle's own
    /// shortcuts first, no matter which window (terminal included) is focused.
    private func installShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // While the switcher is key, it owns ↑/↓/↩/esc; typing still flows to
            // its search field. (⌘J / ⌘, etc. below still toggle as normal.)
            if self.switcherPanel?.isVisible == true, self.switcherPanel?.isKeyWindow == true,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                switch event.keyCode {
                case 125: self.switcherModel?.move(1); return nil      // ↓
                case 126: self.switcherModel?.move(-1); return nil     // ↑
                case 36, 76: self.switcherModel?.activateSelection(); return nil  // ↩ / enter
                case 53: self.closeSwitcher(); return nil              // esc
                default: break
                }
            }
            switch JuggleShortcutAction.resolve(
                modifiers: event.modifierFlags,
                characters: event.charactersIgnoringModifiers
            ) {
            case .newTerminal: self.newTerminal(nil); return nil
            case .tileGrid: self.tileGrid(nil); return nil
            case .openRepo: self.openRepo(nil); return nil
            case .settings: self.showCommandCentre(nil); return nil
            case .switcher: self.toggleSwitcher(); return nil
            case .controlPanel: self.toggleControlPopover(nil); return nil
            case .quit:
                NSApp.terminate(nil)
                return nil
            case .closeWindow:
                // The embedded libghostty terminal binds ⌘W itself and swallows it
                // before the menu's key equivalent fires, so "Close Window" never
                // ran on a focused terminal. The local monitor sees the event
                // first: close the key window (its delegate cleanup + retile run as
                // normal). Fall through to the menu when nothing is key.
                if let window = NSApp.keyWindow {
                    window.performClose(nil)
                    return nil
                }
                return event
            case .none: return event
            }
        }
    }

    static func shouldBlockUnbundledWorkspaceLaunch(
        diagnosticMode: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundlePath: String = Bundle.main.bundlePath
    ) -> Bool {
        guard environment["JUGGLE_ALLOW_UNBUNDLED_WORKSPACE"] != "1" else { return false }
        guard !diagnosticMode else { return false }
        return URL(fileURLWithPath: bundlePath).pathExtension != "app"
    }

    enum LaunchSurfaceKind: Equatable {
        case projectOpenPrompt
        case recentProjectsHome
        case restoredWorkspace
    }

    static func launchSurfaceKind(projectCount: Int, openTerminalCount: Int) -> LaunchSurfaceKind {
        guard projectCount > 0 else { return .projectOpenPrompt }
        guard openTerminalCount == 0 else { return .restoredWorkspace }
        return .recentProjectsHome
    }

    static func permitsControllerDiagnosticLaunch(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // `--qa-shot` is still owned by `AppController.start()` because it opens
        // terminal windows before capturing them. It can pass the unbundled-launch
        // guard only when the caller supplied an isolated app-support store;
        // otherwise it could restore the user's real Desktop/Documents projects
        // under SwiftPM's ad-hoc identity, which is exactly what the guard prevents.
        guard arguments.contains("--qa-shot") else { return false }
        return hasIsolatedAppSupport(environment: environment)
    }

    static func hasIsolatedAppSupport(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["JUGGLE_APP_SUPPORT_DIR"]?.isEmpty == false
    }

    private func showUnsafeUnbundledLaunchNotice() {
        let alert = NSAlert()
        alert.messageText = "Use the signed Juggle app for workspace launches"
        alert.informativeText = """
        This launch came from an unbundled SwiftPM binary. Loading saved Desktop/Documents projects from here can pollute macOS folder permissions and break other agents' access.

        Use scripts/juggle-ship.sh and open ~/Applications/Juggle.app, or use scripts/juggle-diagnostic.sh for visual diagnostics.
        """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    /// Closing every terminal leaves the control panel as the home base, so the
    /// app stays alive until the user quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Menu-bar home base

    /// Juggle lives in the menu bar: a status item expands the control panel as a
    /// popover (so it never floats over the terminals), and the icon tints when a
    /// terminal needs attention. The panel can be detached into a full window for
    /// reviewing diffs.
    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = StatusBarIcon.image()
            button.action = #selector(toggleControlPopover(_:))
            button.target = self
            button.toolTip = "Juggle — projects, worktrees, terminals"
        }
        statusItem = item

        controlPopover.behavior = .transient
        controlPopover.contentSize = NSSize(width: 520, height: 640)
        controlPopover.contentViewController = NSHostingController(rootView: ControlPanelView())

        attentionObserver = AppModel.shared.$openTerminals
            .receive(on: RunLoop.main)
            .sink { [weak self] terminals in self?.updateAttentionIndicator(terminals) }
    }

    @objc func toggleControlPopover(_ sender: Any?) {
        if controlPopover.isShown {
            controlPopover.performClose(sender)
        } else {
            showControlPopover()
        }
    }

    private func showControlPopover() {
        guard let button = statusItem?.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        controlPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async { [weak self] in
            self?.controlPopover.contentViewController?.view.window?.makeFirstResponder(nil)
        }
    }

    /// Detach the popover into a real, resizable window (e.g. to review diffs).
    @objc func detachControlPanel(_ sender: Any?) {
        controlPopover.performClose(sender)
        showControlPanel(nil)
    }

    private func updateAttentionIndicator(_ terminals: [OpenTerminal]) {
        guard let button = statusItem?.button else { return }
        let needsAttention = terminals.contains(where: \.needsAttention)
        button.contentTintColor = needsAttention ? CockpitStyle.nsAccent : nil
        button.image = StatusBarIcon.image(filled: needsAttention)
    }

    // MARK: - Menu actions

    @objc func showControlPanel(_ sender: Any?) {
        if controlPanel == nil {
            controlPanel = makePanel(title: "Juggle", size: NSSize(width: 520, height: 640),
                                     view: ControlPanelView())
        }
        controlPanel?.makeKeyAndOrderFront(nil)
        controlPanel?.makeFirstResponder(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Settings (⌘,) — the standard macOS preferences window. A titled window with
    /// the `.preference` toolbar style turns the `TabView`'s `tabItem`s into the
    /// expected top toolbar pills and auto-sizes to the active tab, instead of the
    /// old free-floating fixed-size panel with a doubly-hardcoded frame. Reuses one
    /// instance and centers on first show, matching `Settings…` behaviour.
    @objc func showCommandCentre(_ sender: Any?) {
        if commandCentre == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Juggle Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            window.center()
            commandCentre = window
        }
        commandCentre?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Project switcher (⌘J)

    /// R4/R12: a centered, transient command surface that jumps focus to a
    /// terminal by repo and echoes attention (blocked/error rows sort first).
    /// Separate from Settings on purpose — ⌘, is preferences, ⌘J is "go to".
    @objc func toggleSwitcher() {
        if switcherPanel?.isVisible == true { closeSwitcher(); return }
        showSwitcher()
    }

    private func showSwitcher() {
        let model = switcherModel ?? SwitcherModel()
        model.onActivate = { [weak self] id in
            self?.controller.focusTerminal(id)
            self?.closeSwitcher()
        }
        switcherModel = model

        let panel = switcherPanel ?? makeSwitcherPanel(model: model)
        switcherPanel = panel
        positionSwitcher(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func makeSwitcherPanel(model: SwitcherModel) -> KeyablePanel {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(rootView: ProjectSwitcherView(model: model))
        return panel
    }

    /// Center the switcher horizontally and place it in the upper third of the
    /// screen the pointer is on (Spotlight-like), so it's catchable wherever the
    /// user is working across displays.
    private func positionSwitcher(_ panel: NSPanel) {
        panel.layoutIfNeeded()
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - frame.height * 0.16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closeSwitcher() {
        switcherPanel?.orderOut(nil)
    }

    // MARK: - Notch HUD (ambient attention)

    /// Build the always-on attention strip and start the gentle PR-ready poll.
    /// Honours the `notchHUD` preference; toggling it in Settings re-runs this.
    private func setupNotchHUD() {
        guard AppModel.shared.preferences.notchHUD else { teardownNotchHUD(); return }
        guard notchPanel == nil else { return }

        let model = NotchHUDModel()
        model.onActivate = { [weak self] item in self?.activateNeedsYouItem(item) }
        model.onOpenSwitcher = { [weak self] in self?.toggleSwitcher() }
        model.onItemsChanged = { [weak self] in self?.positionNotchHUD() }
        model.onAddProject = { [weak self] in self?.controller.openProjectViaPanel() }
        model.onMerge = { [weak self] item in self?.mergeNeedsYouItem(item) }
        model.onOpenPR = { [weak self] item in self?.openNeedsYouPR(item) }
        notchModel = model

        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 72, height: 16),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // First-mouse hosting keeps the one-click path alive. The panel frame
        // itself follows SwiftUI's reported surface size with no AppKit animation.
        let hosting = FirstMouseHostingView(rootView: NotchHUDView(model: model))
        hosting.autoresizingMask = [.width, .height]
        hosting.onHoverChange = { [weak model] inside in model?.hoverChanged(inside) }
        hosting.shouldHandlePanelClick = { [weak model] point, bounds in
            model?.shouldHandlePanelClick(at: point, in: bounds) ?? false
        }
        hosting.handlePanelClick = { [weak model] downPoint, upPoint, bounds in
            model?.handlePanelClick(from: downPoint, to: upPoint, in: bounds) ?? false
        }
        model.onRenderedSurfaceSize = { [weak self] size in self?.applyNotchSurfaceSize(size) }
        panel.contentView = hosting
        notchPanel = panel

        // Reposition on item/display changes and toggle outside-click monitors on
        // expansion. Surface-size callbacks keep the panel frame slaved to the
        // SwiftUI morph.
        notchObserver = Publishers.Merge(
            model.$items.map { _ in () },
            model.$expanded.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.positionNotchHUD()
            self?.updateNotchOutsideClickMonitors()
        }

        positionNotchHUD()
        startPRReadyPoll()
    }

    func activateNeedsYouItem(_ item: NeedsYouItem) {
        switch item.primaryAction {
        case .jumpToTerminal:
            if let id = item.activateTerminalId { controller.focusTerminal(id) }
        case .openPR:
            openNeedsYouPR(item)
        case .mergePR:
            controller.mergePR(at: item.worktreePath)
        }
    }

    /// Inline merge from the notch (no blocking dialog). On success force an
    /// immediate PR refresh so the merged row drops out; on failure clear the
    /// "Merging…" state so the button returns for a retry.
    private func mergeNeedsYouItem(_ item: NeedsYouItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.controller.mergePRDirect(at: item.worktreePath)
            if result.outcome == .merged {
                self.refreshPRReady()
            } else {
                self.notchModel?.mergeFinished(item)
                if result.outcome == .failed {
                    self.alert("Merge failed", result.failureMessage ?? "gh could not merge the PR.")
                }
            }
        }
    }

    /// Tapping a PR row opens it on GitHub (review it), leaving Merge as the
    /// explicit action. Falls back to focusing the terminal if there's no URL.
    private func openNeedsYouPR(_ item: NeedsYouItem) {
        if let urlString = item.prURL, let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        } else if let id = item.activateTerminalId {
            controller.focusTerminal(id)
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func teardownNotchHUD() {
        prReadyPoll?.invalidate(); prReadyPoll = nil
        notchObserver?.cancel(); notchObserver = nil
        removeNotchOutsideClickMonitors()
        notchPanel?.orderOut(nil)
        notchPanel = nil
        notchModel = nil
    }

    /// Called by Settings when the `notchHUD` toggle flips.
    func applyNotchHUDPreference() {
        if AppModel.shared.preferences.notchHUD { setupNotchHUD() }
        else { teardownNotchHUD() }
    }

    @objc private func screenParametersChanged() { positionNotchHUD() }

    /// Apply the SwiftUI-rendered surface size to the borderless panel with no
    /// AppKit animation. SwiftUI owns the morph; AppKit only follows each
    /// reported size and re-pins the surface to the top center.
    private func applyNotchSurfaceSize(_ size: CGSize) {
        guard let panel = notchPanel, notchModel?.shouldShow == true else { return }
        let width = max(46, size.width.rounded(.up))
        let height = max(16, size.height.rounded(.up))
        guard let frame = (panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let target = NSRect(
            x: (frame.midX - width / 2).rounded(),
            y: (frame.maxY - height - 2).rounded(),
            width: width,
            height: height
        )
        guard panel.frame != target else { return }
        panel.setFrame(target, display: true, animate: false)
        panel.orderFront(nil)
    }

    /// Re-pin after display/item changes. If SwiftUI has not reported a size yet,
    /// force one layout pass and use the hosting view's fitting size.
    private func positionNotchHUD() {
        guard let panel = notchPanel, let model = notchModel else { return }
        guard model.shouldShow else { panel.orderOut(nil); return }

        if model.renderedSurfaceSize.width > 1, model.renderedSurfaceSize.height > 1 {
            applyNotchSurfaceSize(model.renderedSurfaceSize)
            return
        }
        panel.contentView?.layoutSubtreeIfNeeded()
        applyNotchSurfaceSize(panel.contentView?.fittingSize ?? panel.frame.size)
    }

    /// When the notch is expanded, any click outside the card should dismiss it —
    /// the owner explicitly called out that requiring the tiny ✕ is bad UX. Use
    /// both local and global AppKit event monitors: local for clicks inside Juggle
    /// windows, global for clicks elsewhere. The click is never swallowed; it
    /// still does what the user clicked, while the HUD quietly collapses.
    private func updateNotchOutsideClickMonitors() {
        guard notchModel?.expanded == true else {
            removeNotchOutsideClickMonitors()
            return
        }
        guard notchOutsideClickLocalMonitor == nil, notchOutsideClickGlobalMonitor == nil else { return }

        notchOutsideClickLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            self?.collapseNotchIfClickOutside(screenPoint: self?.screenPoint(for: event))
            return event
        }
        notchOutsideClickGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.collapseNotchIfClickOutside(screenPoint: NSEvent.mouseLocation) }
        }
    }

    private func removeNotchOutsideClickMonitors() {
        if let monitor = notchOutsideClickLocalMonitor {
            NSEvent.removeMonitor(monitor)
            notchOutsideClickLocalMonitor = nil
        }
        if let monitor = notchOutsideClickGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            notchOutsideClickGlobalMonitor = nil
        }
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        if let window = event.window {
            return window.convertPoint(toScreen: event.locationInWindow)
        }
        return NSEvent.mouseLocation
    }

    private func collapseNotchIfClickOutside(screenPoint: NSPoint?) {
        guard let model = notchModel, model.expanded, let panel = notchPanel else { return }
        guard let screenPoint, panel.frame.contains(screenPoint) else {
            model.collapseNow()
            return
        }
        // Clicks inside the panel are owned by the HUD itself.
    }

    /// Gentle PR-ready poll: every 45s, read the cached `gh` status for each
    /// registered worktree (the 15s TTL + in-flight coalescing in `GhService`
    /// means this is cheap and never stampedes), and publish the green set for
    /// the cockpit + HUD. This deliberately includes closed worktrees: the whole
    /// point is learning that a PR is ready without already staring at its
    /// terminal.
    private func startPRReadyPoll() {
        prReadyPoll?.invalidate()
        activeScopeObserver = AppModel.shared.$activeProjectId
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshPRReady() }
        let timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPRReady() }
        }
        timer.tolerance = 10
        prReadyPoll = timer
        // Defer the first poll so the gh fan-out doesn't compete with launch
        // (window restoration + first render) — that contention is what made the
        // first few seconds of hover feel janky before settling.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self.refreshPRReady()
        }
    }

    private func refreshPRReady() {
        let model = AppModel.shared
        let observedAt = Date()
        // One unique path per registered, observable worktree.
        let paths = Set(model.prObservableWorktreePaths)
        guard !paths.isEmpty else {
            model.setPRStatusesByPath([:])
            return
        }
        // Fan out the gh calls concurrently — one slow worktree no longer stalls
        // the rest (the old sequential loop made cold launches drag).
        Task { @MainActor in
            let statuses = await withTaskGroup(of: (String, PRStatus).self) { group in
                for path in paths {
                    group.addTask { (path, await GhService.shared.status(at: path)) }
                }
                var acc: [String: PRStatus] = [:]
                for await (path, status) in group where status.availability != .none {
                    acc[path] = status
                }
                return acc
            }
            model.applyPRPollStatuses(statuses, observedAt: observedAt, replacing: paths)
        }
    }

    @objc func openRepo(_ sender: Any?) { controller.openProjectViaPanel() }
    @objc func newTerminal(_ sender: Any?) { controller.newTerminalForKeyWindow() }
    @objc func tileGrid(_ sender: Any?) { controller.tileGrid() }

    @objc func chooseGrid(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return }
        controller.setGrid(columns: parts[0], rows: parts[1])
    }

    private func makePanel<Content: View>(title: String, size: NSSize, view: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    // MARK: - Project open prompt

    /// Zero-project launch surface. Mirrors IDEs: the app opens into the user's
    /// existing workspace when one is saved; otherwise the frontmost thing is a
    /// folder/project picker, not a tour and not a dead notch-only state.
    func showProjectOpenPrompt() {
        showProjectOpenPrompt(projects: [])
    }

    private func showProjectOpenPrompt(projects: [Project]) {
        if let window = projectOpenWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let actions = ProjectOpenPromptActions(
            openProject: { [weak self] in self?.openProjectFromPrompt() },
            showControlPanel: { [weak self] in
                self?.closeProjectOpenPrompt(showFallback: false)
                self?.showControlPanel(nil)
            },
            replayOnboarding: { [weak self] in
                self?.closeProjectOpenPrompt(showFallback: false)
                self?.showOnboarding()
            },
            openRecentProject: { [weak self] project in
                self?.openRecentProjectFromPrompt(project)
            }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: ProjectOpenPromptView(actions: actions, projects: projects)))
        window.title = projects.isEmpty ? "Juggle" : "Juggle Home"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.setContentSize(projects.isEmpty ? NSSize(width: 540, height: 340) : NSSize(width: 640, height: 460))
        window.minSize = projects.isEmpty ? NSSize(width: 500, height: 318) : NSSize(width: 560, height: 400)
        window.center()
        window.delegate = self
        projectOpenWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openProjectFromPrompt() {
        controller.openProjectViaPanel(
            onOpened: { [weak self] _ in
                self?.closeProjectOpenPrompt(showFallback: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.positionNotchHUD()
                    self?.showControlPanel(nil)
                }
            },
            onCancel: { [weak self] in self?.showProjectOpenPrompt() }
        )
    }

    private func openRecentProjectFromPrompt(_ project: Project) {
        closeProjectOpenPrompt(showFallback: false)
        AppModel.shared.setActiveProject(project.id)
        guard let worktree = project.primaryWorktree else {
            showControlPanel(nil)
            return
        }
        AppModel.shared.openWindow(projectId: project.id, worktreeId: worktree.id)
        positionNotchHUD()
    }

    private func closeProjectOpenPrompt(showFallback: Bool) {
        guard projectOpenWindow != nil else { return }
        suppressProjectPromptCloseFallback = !showFallback
        projectOpenWindow?.close()
        projectOpenWindow = nil
        suppressProjectPromptCloseFallback = false
    }

    private func showLaunchSurfaceForCurrentWorkspace() {
        switch Self.launchSurfaceKind(
            projectCount: AppModel.shared.projects.count,
            openTerminalCount: AppModel.shared.openTerminals.count
        ) {
        case .projectOpenPrompt:
            showProjectOpenPrompt()
        case .recentProjectsHome:
            showProjectOpenPrompt(projects: AppModel.shared.projects)
        case .restoredWorkspace:
            positionNotchHUD()
        }
    }

    // MARK: - First-run onboarding

    /// Show the 7-step onboarding window, hosted like the control panel (a real
    /// `NSWindow` + `NSHostingController`, dark, ~1040×650). Used on first run and
    /// for "Replay onboarding…" from Settings.
    func showOnboarding() {
        let model = OnboardingModel()
        onboardingModel = model
        let actions = OnboardingActions(
            startFirstProject: { [weak self] in self?.startFirstProject() },
            signInGh: { Self.openTerminalRunningGhLogin() },
            installGh: { Self.openGhInstallPage() },
            dismiss: { [weak self] in self?.dismissOnboarding() }
        )
        let window = makeOnboardingWindow(model: model, actions: actions)
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if model.ghAuth == nil { Task { await model.checkGh() } }
    }

    private func makeOnboardingWindow(model: OnboardingModel, actions: OnboardingActions) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(model: model, actions: actions)))
        // Borderless, transparent, shadowed: SwiftUI draws the rounded card
        // (1040×650) centred, leaving margins for the drop shadow. Matches the
        // mockup's clean card (no titlebar/traffic lights) and avoids titlebar-
        // height fragility. Drag by the card; Esc / the flow dismisses it.
        window.styleMask = .borderless
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let size = NSSize(width: 1120, height: 730)
        window.setContentSize(size)
        window.minSize = size
        window.maxSize = size
        window.center()
        window.delegate = self
        return window
    }

    /// "Start juggling" / "Add your first project": retire onboarding, open the
    /// real project picker, then surface Juggle's home surfaces. Without this the
    /// first-run path feels like it merely opened Terminal.app: the new terminal is
    /// `.working`, so the HUD has no urgent items yet, and the old flow left the
    /// control panel hidden. After the first project opens, the control popover
    /// appears and the dormant notch node is visible as the always-available hub.
    private func startFirstProject() {
        AppModel.shared.preferences.hasOnboarded = true
        onboardingWindow?.close()
        onboardingWindow = nil
        onboardingModel = nil
        controller.openProjectViaPanel(
            onOpened: { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self?.positionNotchHUD()
                    self?.showControlPopover()
                }
            },
            onCancel: { [weak self] in self?.showControlPopover() }
        )
    }

    /// Escape / dismissed without a project: retire onboarding and surface the
    /// menu-bar cockpit as the home base (nothing else is frontmost).
    private func dismissOnboarding() {
        AppModel.shared.preferences.hasOnboarded = true
        onboardingWindow?.close()
        onboardingWindow = nil
        onboardingModel = nil
        showControlPopover()
    }

    // Red-dot close / windowWillClose: anti-nag — once onboarding has been shown,
    // don't re-show it on the next launch even if the user dismissed it.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === projectOpenWindow {
            projectOpenWindow = nil
            if !suppressProjectPromptCloseFallback, AppModel.shared.projects.isEmpty {
                showControlPopover()
            }
            return
        }
        guard window === onboardingWindow else { return }
        AppModel.shared.preferences.hasOnboarded = true
        onboardingWindow = nil
        onboardingModel = nil
    }

    /// Open Terminal.app running `gh auth login`, so the not-signed-in row leads
    /// somewhere real — no faked in-app login form.
    private static func openTerminalRunningGhLogin() {
        let script = """
        tell application \"Terminal\"
            activate
            do script \"gh auth login\"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private static func openGhInstallPage() {
        if let url = URL(string: "https://cli.github.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func onboardingShotsDir() -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--onboarding-shots"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Diagnostics must not load/restore the user's real workspace before they
    /// run. Under `swift run`, that would touch Desktop/Documents projects with
    /// an ad-hoc code identity and pollute TCC. Keep this list in sync with the
    /// visual harness flags documented in AGENTS.md.
    private var hasAppDelegateDiagnostic: Bool {
        Self.appDelegateDiagnosticFlags.contains { diagnosticArg($0) != nil }
    }

    private func runAppDelegateDiagnosticIfPresent() -> Bool {
        if let shotsDir = onboardingShotsDir() { runOnboardingShots(to: shotsDir); return true }
        if let promptDir = diagnosticArg("--project-open-shot") { runProjectOpenShot(to: promptDir); return true }
        if let launchHomeDir = diagnosticArg("--launch-home-shot") {
            seedDiagnosticWorkspace(restoredWindows: false)
            runLaunchSurfaceShot(to: launchHomeDir)
            return true
        }
        if let launchDir = diagnosticArg("--launch-surface-shot") { runLaunchSurfaceShot(to: launchDir); return true }
        if let controlDir = diagnosticArg("--control-panel-shot") { runControlPanelShot(to: controlDir); return true }
        if let notchDir = diagnosticArg("--notch-shot") { runNotchShots(to: notchDir); return true }
        if let liveDir = diagnosticArg("--notch-live") { runNotchLive(to: liveDir); return true }
        if let clickDir = diagnosticArg("--notch-click-test") { runNotchClickTest(to: clickDir); return true }
        if let emptyDir = diagnosticArg("--notch-empty") { runNotchEmptyShots(to: emptyDir); return true }
        return false
    }

    private struct DiagnosticWorkspace: Codable {
        var projects: [Project]
        var preferences: Preferences
        var activeProjectId: String?
        var openWindows: [OpenWindowState]
    }


    private func seedDiagnosticControlPanelWorkspace() {
        guard let supportDir = ProcessInfo.processInfo.environment["JUGGLE_APP_SUPPORT_DIR"], !supportDir.isEmpty else { return }
        let supportURL = URL(fileURLWithPath: supportDir, isDirectory: true)
        let root = supportURL.appendingPathComponent("mission-control", isDirectory: true)
        let feature = root.appendingPathComponent(".worktrees/feat-merge-readiness", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: feature, withIntermediateDirectories: true)
        let projectId = root.path
        let main = Worktree(
            id: "\(projectId)#0",
            projectId: projectId,
            branch: "main",
            path: root.path,
            shade: 0,
            isPrimary: true
        )
        let ready = Worktree(
            id: "\(projectId)#1",
            projectId: projectId,
            branch: "feat/merge-readiness",
            path: feature.path,
            shade: 1,
            isPrimary: false,
            colorName: "Teal"
        )
        let project = Project(
            id: projectId,
            displayName: "mission-control",
            rootPath: root.path,
            colorName: "Teal",
            worktrees: [main, ready]
        )
        let apiRoot = supportURL.appendingPathComponent("api-service", isDirectory: true)
        let docsRoot = supportURL.appendingPathComponent("docs-site", isDirectory: true)
        try? FileManager.default.createDirectory(at: apiRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: docsRoot, withIntermediateDirectories: true)
        let apiProject = diagnosticProject(id: apiRoot.path, name: "api-service", colorName: "Iris")
        let docsProject = diagnosticProject(id: docsRoot.path, name: "docs-site", colorName: "Coral")
        let workspace = DiagnosticWorkspace(
            projects: [project, apiProject, docsProject],
            preferences: Preferences(),
            activeProjectId: project.id,
            openWindows: []
        )
        guard let data = try? JSONEncoder().encode(workspace) else { return }
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try? data.write(to: supportURL.appendingPathComponent("workspace.json"), options: .atomic)

        AppModel.shared.load()
        AppModel.shared.registerTerminal(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042") ?? UUID(),
            projectId: project.id,
            worktreeId: main.id,
            title: "Agent is waiting for approval"
        )
        if let terminal = AppModel.shared.openTerminals.first {
            AppModel.shared.updateTerminalAttention(id: terminal.id, .blocked)
        }
        AppModel.shared.setPRStatusesByPath([
            ready.path: PRStatus(
                availability: .available,
                number: 42,
                headOid: "abc123",
                summary: "Ready",
                additions: 144,
                deletions: 0,
                title: "Add scoped merge checks",
                url: "https://github.com/example/mission-control/pull/42",
                headRefName: "feat/merge-readiness"
            )
        ])
    }

    private func seedDiagnosticIdleNotchWorkspace() {
        seedDiagnosticWorkspace(restoredWindows: false)
        AppModel.shared.load()
        guard let project = AppModel.shared.projects.first,
              let worktree = project.primaryWorktree
        else { return }
        AppModel.shared.registerTerminal(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000043") ?? UUID(),
            projectId: project.id,
            worktreeId: worktree.id,
            title: "Agent working"
        )
        AppModel.shared.setPRStatusesByPath([:])
    }

    private func seedDiagnosticWorkspace(restoredWindows: Bool) {
        guard let supportDir = ProcessInfo.processInfo.environment["JUGGLE_APP_SUPPORT_DIR"], !supportDir.isEmpty else { return }
        let supportURL = URL(fileURLWithPath: supportDir, isDirectory: true)
        let root = supportURL.appendingPathComponent("sample-project", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectId = root.path
        let worktree = Worktree(
            id: "\(projectId)#0",
            projectId: projectId,
            branch: "main",
            path: root.path,
            shade: 0,
            isPrimary: true
        )
        let project = Project(
            id: projectId,
            displayName: "sample-project",
            rootPath: root.path,
            colorName: "Teal",
            worktrees: [worktree]
        )
        let workspace = DiagnosticWorkspace(
            projects: [project],
            preferences: Preferences(),
            activeProjectId: project.id,
            openWindows: restoredWindows ? [OpenWindowState(projectId: projectId, worktreeId: worktree.id, slot: 0)] : []
        )
        guard let data = try? JSONEncoder().encode(workspace) else { return }
        try? FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        try? data.write(to: supportURL.appendingPathComponent("workspace.json"), options: .atomic)
    }

    private func diagnosticProject(id: String, name: String, colorName: String) -> Project {
        let worktree = Worktree(
            id: "\(id)#0",
            projectId: id,
            branch: "main",
            path: id,
            shade: 0,
            isPrimary: true
        )
        return Project(
            id: id,
            displayName: name,
            rootPath: id,
            colorName: colorName,
            worktrees: [worktree]
        )
    }

    private func diagnosticArg(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// Drive the REAL notch panel (the one `setupNotchHUD` builds): seed items,
    /// capture the live panel collapsed, flip `expanded`, then capture again and
    /// log both frame sizes. This catches a collapsed-sized panel clipping the
    /// expanded card.
    private func runNotchLive(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        seedDiagnosticIdleNotchWorkspace()
        setupNotchHUD()
        guard let model = notchModel else { NSApp.terminate(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            self.positionNotchHUD()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let idleCollapsed = model.renderedSurfaceSize
                if let p = self.notchPanel { self.captureWindow(p, to: "\(dir)/0-live-idle-collapsed.png") }
                self.seedDiagnosticControlPanelWorkspace()
                let sample = AppModel.shared.needsYouItems
                model.seedForPreview(sample, arriving: Set(sample.prefix(1).map(\.id)))
                self.positionNotchHUD()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let collapsed = model.renderedSurfaceSize
                    if let p = self.notchPanel { self.captureWindow(p, to: "\(dir)/1-live-collapsed.png") }
                    model.expanded = true   // the click path
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        let expanded = model.renderedSurfaceSize
                        if let p = self.notchPanel { self.captureWindow(p, to: "\(dir)/2-live-expanded.png") }
                        let windowSize = self.notchPanel?.frame.size ?? .zero
                        let appModel = AppModel.shared
                        let line = "projects=\(appModel.projects.count) visibleProjects=\(appModel.visibleProjects.count) scope=\(appModel.scopeTitle) items=\(sample.count) idle=\(Int(idleCollapsed.width))x\(Int(idleCollapsed.height)) collapsed=\(Int(collapsed.width))x\(Int(collapsed.height)) expanded=\(Int(expanded.width))x\(Int(expanded.height)) window=\(Int(windowSize.width))x\(Int(windowSize.height)) grew=\(expanded.height > collapsed.height + 10)\n"
                        try? line.write(toFile: "\(dir)/result.txt", atomically: true, encoding: .utf8)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                    }
                }
            }
        }
    }

    /// Exercise the real notch panel's mouse-event path, not just its rendered
    /// pixels. This catches regressions where hover reveals the HUD but the
    /// panel sizing / outside-click monitor prevents SwiftUI actions from
    /// receiving the click.
    private func runNotchClickTest(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        setupNotchHUD()
        guard let model = notchModel else { NSApp.terminate(nil); return }

        let sample = diagnosticNeedsYou(
            project: "mission-control",
            color: "Teal",
            reason: .prReady,
            detail: "#42 · Add scoped merge checks",
            meta: "feat/merge-readiness · +144 −0",
            action: .mergePR
        )
        var mergeRequests = 0
        var openPRRequests = 0
        model.onMerge = { _ in mergeRequests += 1 }
        model.onOpenPR = { _ in openPRRequests += 1 }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let panel = self.notchPanel else { NSApp.terminate(nil); return }
            model.seedForPreview([sample])
            model.expanded = true
            self.positionNotchHUD()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.captureWindow(panel, to: "\(dir)/1-before-click.png")
                let bounds = panel.contentView?.bounds ?? NSRect(origin: .zero, size: panel.frame.size)
                let surface = model.renderedSurfaceSize
                let surfaceX = (bounds.width - surface.width) / 2
                let surfaceTopFromWindowBottom = bounds.height
                let rowMidY = surfaceTopFromWindowBottom - 58
                let rowPoint = NSPoint(x: surfaceX + 92, y: rowMidY)
                let mergePoint = NSPoint(x: surfaceX + surface.width - 47, y: rowMidY)
                let rowViewPoint = panel.contentView?.convert(rowPoint, from: nil) ?? rowPoint
                let mergeViewPoint = panel.contentView?.convert(mergePoint, from: nil) ?? mergePoint
                let rowHit = panel.contentView?.hitTest(rowViewPoint)
                let mergeHit = panel.contentView?.hitTest(mergeViewPoint)

                panel.makeKey()
                self.postDiagnosticClick(at: rowPoint, in: panel)
                model.expanded = true
                panel.makeKey()
                self.postDiagnosticClick(at: mergePoint, in: panel)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.captureWindow(panel, to: "\(dir)/2-after-click.png")
                    let line = """
                    surface=\(Int(surface.width))x\(Int(surface.height)) window=\(Int(bounds.width))x\(Int(bounds.height))
                    rowWindowPoint=\(Int(rowPoint.x)),\(Int(rowPoint.y)) rowViewPoint=\(Int(rowViewPoint.x)),\(Int(rowViewPoint.y)) rowHit=\(String(describing: rowHit.map { type(of: $0) })) rowAcceptsFirstMouse=\(rowHit?.acceptsFirstMouse(for: nil) == true)
                    mergeWindowPoint=\(Int(mergePoint.x)),\(Int(mergePoint.y)) mergeViewPoint=\(Int(mergeViewPoint.x)),\(Int(mergeViewPoint.y)) mergeHit=\(String(describing: mergeHit.map { type(of: $0) })) mergeAcceptsFirstMouse=\(mergeHit?.acceptsFirstMouse(for: nil) == true)
                    openPRRequests=\(openPRRequests) mergeRequests=\(mergeRequests) expandedAfter=\(model.expanded)
                    """
                    try? line.write(toFile: "\(dir)/result.txt", atomically: true, encoding: .utf8)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                }
            }
        }
    }

    private func postDiagnosticClick(at point: NSPoint, in window: NSWindow) {
        let screenPoint = window.convertPoint(toScreen: point)
        let displayBounds = CGDisplayBounds(CGMainDisplayID())
        let quartzPoint = CGPoint(x: screenPoint.x, y: displayBounds.height - screenPoint.y)
        let source = CGEventSource(stateID: .hidSystemState)
        // Move the real pointer to the target so AppKit's outside-click monitor,
        // which intentionally classifies events in screen coordinates, sees the
        // same location a user click would.
        CGWarpMouseCursorPosition(quartzPoint)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: quartzPoint, mouseButton: .left)?
            .post(tap: .cghidEventTap)

        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp + 0.03,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )
        if let down { NSApp.sendEvent(down) }
        if let up { NSApp.sendEvent(up) }
    }

    /// Preview the notch HUD (collapsed + expanded) with seeded sample items by
    /// rendering each state in a real on-screen window and capturing it — the same
    /// reliable path `--onboarding-shots` uses (offscreen SwiftUI material views
    /// cache transparent, so a real window is required). Exits when done.
    private func runNotchShots(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = NotchHUDModel()
        let sample = [
            diagnosticNeedsYou(project: "mission-control", color: "Teal", reason: .prReady,
                               detail: "#42 · Add scoped merge checks", meta: "feat/merge-readiness · +144 −0",
                               action: .mergePR),
            diagnosticNeedsYou(project: "api-service", color: "Rose", reason: .blocked,
                               detail: "Agent is waiting for approval", meta: nil,
                               action: .jumpToTerminal),
            diagnosticNeedsYou(project: "ledger", color: "Iris", reason: .error,
                               detail: "tests failed", meta: nil,
                               action: .jumpToTerminal),
            diagnosticNeedsYou(project: "juggle", color: "Violet", reason: .done,
                               detail: "implementation finished", meta: nil,
                               action: .jumpToTerminal),
        ]

        let preview = ZStack {
            Color(white: 0.10)
            NotchHUDView(model: model, reducedMotion: true).padding(28)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: preview))
        window.styleMask = [.borderless]
        window.setContentSize(NSSize(width: 500, height: 320))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Seed AFTER the model's own subscriptions have flushed (they emit
        // AppModel's empty state on subscribe), then capture collapsed, expand,
        // re-seed (expansion triggers no reset, but be safe), capture, exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            model.seedForPreview(sample, arriving: Set(sample.prefix(1).map(\.id)))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.captureWindow(window, to: "\(dir)/1-collapsed.png")
                model.expanded = true
                model.seedForPreview(sample, arriving: Set(sample.prefix(1).map(\.id)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    self?.captureWindow(window, to: "\(dir)/2-expanded.png")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
                }
            }
        }
    }

    /// Render the empty-state (no projects) node collapsed + expanded and exit.
    /// This is the headless QA for the "I opened the app and nothing happened"
    /// fix: with zero projects the node must still be present and teach "Add a
    /// project". A fresh `NotchHUDModel` with no AppModel projects is exactly that
    /// state, so we render it directly.
    private func runNotchEmptyShots(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let model = NotchHUDModel()
        model.seedEmptyForPreview()
        let preview = ZStack {
            Color(white: 0.10)
            NotchHUDView(model: model, reducedMotion: true).padding(28)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: preview))
        window.styleMask = [.borderless]
        window.setContentSize(NSSize(width: 420, height: 240))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.captureWindow(window, to: "\(dir)/1-empty-collapsed.png")
            model.expanded = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self?.captureWindow(window, to: "\(dir)/2-empty-expanded.png")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
    }

    /// Render the no-project launch prompt. This catches regressions where the app
    /// opens into only the notch/control popover instead of a real IDE-style
    /// "open a project" window.
    private func runProjectOpenShot(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        showProjectOpenPrompt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            if let window = self?.projectOpenWindow {
                self?.captureWindow(window, to: "\(dir)/1-project-open.png")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    /// Render whichever surface the real launch branch chooses for the currently
    /// loaded workspace. Run with `JUGGLE_APP_SUPPORT_DIR=<empty dir>` to simulate
    /// a first install without touching the user's actual Application Support
    /// store.
    private func runLaunchSurfaceShot(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard Self.hasIsolatedAppSupport() else {
            let line = "projects=0 openTerminals=0 surface=missing-isolated-support\n"
            try? line.write(toFile: "\(dir)/result.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            return
        }
        AppModel.shared.load()
        showLaunchSurfaceForCurrentWorkspace()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { NSApp.terminate(nil); return }
            let surface: String
            if let window = self.projectOpenWindow {
                surface = AppModel.shared.projects.isEmpty ? "project-open-prompt" : "home-recent-projects-window"
                self.captureWindow(window, to: "\(dir)/1-launch-surface.png")
            } else if self.controlPopover.isShown, let window = self.controlPopover.contentViewController?.view.window {
                surface = "control-popover"
                self.captureWindow(window, to: "\(dir)/1-launch-surface.png")
            } else if !AppModel.shared.projects.isEmpty, !AppModel.shared.openTerminals.isEmpty {
                surface = "restored-workspace"
            } else {
                surface = "none"
            }
            let line = "projects=\(AppModel.shared.projects.count) openTerminals=\(AppModel.shared.openTerminals.count) surface=\(surface)\n"
            try? line.write(toFile: "\(dir)/result.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    /// Render the detached menu-bar cockpit. This is the visual harness for the
    /// control panel/top-menu surface; `--qa-shot` captures terminal windows and
    /// cannot catch dark-on-dark popover regressions.
    private func runControlPanelShot(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        seedDiagnosticControlPanelWorkspace()
        showControlPanel(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if let window = self?.controlPanel {
                self?.captureWindow(window, to: "\(dir)/1-control-panel.png")
            }
            let model = AppModel.shared
            let worktreeCount = model.projects.reduce(0) { $0 + $1.worktrees.count }
            let prReadyCount = model.needsYouItems.filter { $0.reason == .prReady }.count
            let line = "projects=\(model.projects.count) visibleProjects=\(model.visibleProjects.count) scope=\(model.scopeTitle) worktrees=\(worktreeCount) openTerminals=\(model.openTerminals.count) visibleTerminals=\(model.visibleOpenTerminals.count) needsYou=\(model.needsYouItems.count) prReady=\(prReadyCount)\n"
            try? line.write(toFile: "\(dir)/result.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
    }

    /// Render every onboarding step to `<dir>/NN-step.png` and exit. Mirrors the
    /// existing `--qa-shot` capture: the window renders into a bitmap rep.
    private func runOnboardingShots(to dir: String) {
        // (empty-state diagnostic lives just above)
        showOnboarding()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.captureOnboardingStep(0, dir: dir)
        }
    }

    private func captureOnboardingStep(_ i: Int, dir: String) {
        guard onboardingWindow != nil, let model = onboardingModel else {
            NSApp.terminate(nil); return
        }
        let step = OnboardingStep.all[i]
        if let window = onboardingWindow {
            captureWindow(window, to: "\(dir)/\(String(format: "%02d", i + 1))-\(step.id.rawValue).png")
        }
        if i < OnboardingStep.all.count - 1 {
            model.next()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                self?.captureOnboardingStep(i + 1, dir: dir)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
        }
    }

    private func captureWindow(_ window: NSWindow, to path: String) {
        guard let view = window.contentView, view.bounds.width > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func diagnosticNeedsYou(project: String,
                                    color: String,
                                    reason: HUDReason,
                                    detail: String?,
                                    meta: String?,
                                    action: NeedsYouPrimaryAction) -> NeedsYouItem {
        NeedsYouItem(
            id: "diagnostic:\(project):\(reason)",
            projectId: "/diagnostic/\(project)",
            worktreeId: "/diagnostic/\(project)#0",
            worktreePath: "/diagnostic/\(project)",
            branch: "main",
            projectName: project,
            color: RepoColor.nsColor(for: color),
            reason: reason,
            detail: detail,
            meta: meta,
            activateTerminalId: UUID(),
            primaryAction: action,
            prURL: nil
        )
    }
}
