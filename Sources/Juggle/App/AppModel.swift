import AppKit
import Combine

/// The single source of truth: projects, their worktrees, and user preferences,
/// persisted to Application Support. The control panel and Settings bind
/// to it; the AppKit window layer reads `SessionContext`s built from it.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var projects: [Project] = []
    @Published private(set) var openTerminals: [OpenTerminal] = []
    @Published private(set) var activeProjectId: String?
    @Published var preferences = Preferences()

    /// Worktree paths whose PR is green and mergeable right now. Published so the
    /// notch HUD can surface "PR ready" ambiently — the owner's headline case:
    /// the user must learn a PR is ready without staring at that window. Fed by
    /// `AppController`'s gentle poll off the cached `GhService`, never a direct
    /// per-frame spawn.
    @Published private(set) var prReadyPaths: Set<String> = []
    @Published private(set) var prStatusesByPath: [String: PRStatus] = [:]
    private var prStatusObservedAtByPath: [String: Date] = [:]

    /// Window assignments restored from the last session (R17). `AppController`
    /// reads this on launch to reopen the same project/worktree windows into the
    /// same grid slots, then keeps it current via `saveOpenWindows`. Live PTY
    /// processes are never captured — only identity + slot.
    private(set) var restoredWindows: [OpenWindowState] = []

    /// Set by AppController so SwiftUI surfaces can open real terminal windows,
    /// and so live windows can react to preference changes.
    var onOpenWindow: ((SessionContext) -> Void)?
    var onPreferencesChanged: ((Preferences) -> Void)?
    /// Set by AppController: bring a specific live terminal forward and focus it.
    var onFocusTerminal: ((UUID) -> Void)?

    private let storeURL: URL
    private var prefsObserver: AnyCancellable?

    private struct Persisted: Codable {
        var projects: [Project]
        var preferences: Preferences
        /// Optional so a `workspace.json` written before active project scope
        /// landed still decodes instead of dropping the user's saved projects.
        var activeProjectId: String?
        /// Optional so a `workspace.json` written before window-restore landed
        /// still decodes (a throw here would drop the user's whole project list).
        var openWindows: [OpenWindowState]?
    }

    init(storeURL: URL? = nil) {
        if let storeURL {
            self.storeURL = storeURL
        } else {
            let base: URL
            if let override = ProcessInfo.processInfo.environment["JUGGLE_APP_SUPPORT_DIR"], !override.isEmpty {
                base = URL(fileURLWithPath: override, isDirectory: true)
            } else {
                base = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Juggle", isDirectory: true)
            }
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.storeURL = base.appendingPathComponent("workspace.json")
        }

        prefsObserver = $preferences
            .dropFirst()
            .sink { [weak self] prefs in
                self?.save()
                self?.onPreferencesChanged?(prefs)
            }
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else { return }
        projects = decoded.projects
        activeProjectId = normalizedActiveProjectId(decoded.activeProjectId, projects: decoded.projects)
        preferences = decoded.preferences
        restoredWindows = decoded.openWindows ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(
            Persisted(
                projects: projects,
                preferences: preferences,
                activeProjectId: activeProjectId,
                openWindows: restoredWindows
            )
        )
        else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    /// Persist the live window set (identity + grid slot) so the next launch can
    /// restore the layout (R17 / AE4). Called by `AppController` whenever windows
    /// open, close, or change slots.
    func saveOpenWindows(_ windows: [OpenWindowState]) {
        restoredWindows = windows
        save()
    }

    // MARK: - Projects

    @discardableResult
    func addProject(atRoot path: String) -> Project {
        let root = GitRoot.find(from: path)
        if let existing = projects.first(where: { $0.rootPath == root }) {
            setActiveProject(existing.id)
            Task { await refreshWorktrees(projectId: existing.id) }
            return existing
        }

        let name = URL(fileURLWithPath: root).lastPathComponent
        let colorName = RepoColor.assign(forKey: root).name
        let main = Worktree(id: "\(root)#0", projectId: root, branch: "", path: root, shade: 0, isPrimary: true)
        let project = Project(id: root, displayName: name, rootPath: root, colorName: colorName, worktrees: [main])
        projects.append(project)
        activeProjectId = project.id
        save()
        Task { await refreshWorktrees(projectId: root) }
        return project
    }

    func setActiveProject(_ projectId: String) {
        guard projects.contains(where: { $0.id == projectId }) else { return }
        guard activeProjectId != projectId else {
            Task { await refreshWorktrees(projectId: projectId) }
            return
        }
        activeProjectId = projectId
        save()
        Task { await refreshWorktrees(projectId: projectId) }
    }

    func showAllProjects() {
        guard activeProjectId != nil else { return }
        activeProjectId = nil
        save()
    }

    var activeProject: Project? {
        guard let activeProjectId else { return nil }
        return project(activeProjectId)
    }

    var scopeTitle: String {
        activeProject?.displayName ?? "All projects"
    }

    var visibleProjects: [Project] {
        guard let activeProject else { return projects }
        return [activeProject]
    }

    var visibleOpenTerminals: [OpenTerminal] {
        guard let activeProject else { return openTerminals }
        let worktreeIds = Set(activeProject.worktrees.map(\.id))
        return openTerminals.filter {
            $0.projectId == activeProject.id && worktreeIds.contains($0.worktreeId)
        }
    }

    func rename(projectId: String, to name: String) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[i].displayName = trimmed
        save()
    }

    func recolor(projectId: String, colorName: String) {
        guard let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        projects[i].colorName = colorName
        save()
        onPreferencesChanged?(preferences)   // re-tint any open windows of this project
    }

    /// Override a single worktree's color (pass nil to fall back to the project shade).
    func setWorktreeColor(projectId: String, worktreeId: String, colorName: String?) {
        guard let pi = projects.firstIndex(where: { $0.id == projectId }),
              let wi = projects[pi].worktrees.firstIndex(where: { $0.id == worktreeId }) else { return }
        projects[pi].worktrees[wi].colorName = colorName
        save()
        onPreferencesChanged?(preferences)
    }

    func createWorktree(projectId: String, branch: String) async {
        guard let project = project(projectId) else { return }
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty else { return }
        let created = await GitService.shared.createWorktree(at: project.rootPath, branch: branch)
        if created {
            await refreshWorktrees(projectId: projectId)
            openWorktree(projectId: projectId, branch: branch)
        }
    }

    /// Existing-branch branches available to open as a worktree: the project's
    /// local branches minus any already checked out in a worktree.
    func openableBranches(projectId: String) async -> [String] {
        guard let project = project(projectId) else { return [] }
        let all = await GitService.shared.localBranches(at: project.rootPath)
        let inUse = Set(project.worktrees.map(\.branch))
        return all.filter { !inUse.contains($0) }
    }

    /// Open an EXISTING branch as a worktree (vs. `createWorktree`, which makes a
    /// new branch). Refreshes the worktree list so the new row appears.
    func openExistingWorktree(projectId: String, branch: String) async {
        guard let project = project(projectId) else { return }
        let added = await GitService.shared.addWorktreeForExistingBranch(at: project.rootPath, branch: branch)
        if added {
            await refreshWorktrees(projectId: projectId)
            openWorktree(projectId: projectId, branch: branch)
        }
    }

    /// After creating/opening a worktree, jump the user straight into it. The
    /// control panel should not leave a new row as a dead-end that requires a
    /// second "Terminal" click — the point of Juggle is moving work forward.
    private func openWorktree(projectId: String, branch: String) {
        guard let worktree = project(projectId)?.worktrees.first(where: { $0.branch == branch }) else { return }
        openWindow(projectId: projectId, worktreeId: worktree.id)
    }

    func remove(projectId: String) {
        let wasActive = activeProjectId == projectId
        projects.removeAll { $0.id == projectId }
        if wasActive { activeProjectId = projects.first?.id }
        save()
    }

    func project(_ id: String) -> Project? { projects.first { $0.id == id } }

    func context(projectId: String, worktreeId: String) -> SessionContext? {
        guard let project = project(projectId),
              let worktree = project.worktrees.first(where: { $0.id == worktreeId })
        else { return nil }
        let headerColor = RepoColor.nsColor(for: project.colorName)
        // Override color wins; otherwise the worktree is a shade of the project hue.
        let lineColor = worktree.colorName.map { RepoColor.nsColor(for: $0) }
            ?? headerColor.shadedRepo(worktree.shade)
        return SessionContext(
            projectId: project.id,
            worktreeId: worktree.id,
            displayName: project.displayName,
            worktreeDisplayName: worktree.displayBranch,
            worktreePathDisplay: worktree.shortPath,
            cwd: worktree.path,
            headerColor: headerColor,
            lineColor: lineColor,
            tintFraction: preferences.tintFraction,
            terminalThemeName: preferences.terminalTheme,
            terminalThemeIsLight: TerminalTheming.isLightTheme(named: preferences.terminalTheme),
            breathingEnabled: preferences.breathing,
            soundOnBlocked: preferences.soundOnBlocked,
            branch: worktree.branch.isEmpty ? nil : worktree.branch
        )
    }

    func openWindow(projectId: String, worktreeId: String) {
        setActiveProject(projectId)
        guard let context = context(projectId: projectId, worktreeId: worktreeId) else { return }
        onOpenWindow?(context)
    }

    // MARK: - Open terminals (project ▸ worktree ▸ terminals tree + attention)

    func registerTerminal(id: UUID, projectId: String, worktreeId: String, title: String) {
        openTerminals.removeAll { $0.id == id }
        openTerminals.append(OpenTerminal(
            id: id, projectId: projectId, worktreeId: worktreeId, title: title, attention: .working
        ))
    }

    func updateTerminalTitle(id: UUID, title: String) {
        guard let i = openTerminals.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard openTerminals[i].title != trimmed else { return }   // a re-emitted identical title (every prompt redraw) is not a change
        openTerminals[i].title = trimmed
    }

    func updateTerminalAttention(id: UUID, _ state: AttentionState) {
        guard let i = openTerminals.firstIndex(where: { $0.id == id }) else { return }
        openTerminals[i].attention = state
    }

    func removeTerminal(id: UUID) {
        openTerminals.removeAll { $0.id == id }
    }

    func focusTerminal(id: UUID) { onFocusTerminal?(id) }

    func terminals(forWorktree worktreeId: String) -> [OpenTerminal] {
        openTerminals.filter { $0.worktreeId == worktreeId }
    }

    /// The cockpit queue used by both the menu-bar home surface and the notch
    /// HUD. It follows the current project scope, while still including closed
    /// worktrees inside that scope so a green PR can surface even if its
    /// terminal was closed.
    var needsYouItems: [NeedsYouItem] {
        NeedsYouQueue.compute(
            projects: visibleProjects,
            terminals: visibleOpenTerminals,
            prStatusesByPath: prStatusesByPath,
            prReadyPaths: prReadyPaths
        )
    }

    /// Worktrees worth polling for PR state inside the current project scope.
    /// This is broader than open terminals so a closed worktree can still report
    /// that its PR is ready.
    var prObservableWorktreePaths: [String] {
        visibleProjects.flatMap(\.worktrees)
            .filter { $0.branch != "detached" }
            .map(\.path)
    }

    /// Replace the set of worktree paths whose PR is ready to merge. Only pings
    /// observers when the set actually changes, so the 45s poll is free when
    /// nothing flipped.
    func setPRReadyPaths(_ paths: Set<String>) {
        guard paths != prReadyPaths else { return }
        prReadyPaths = paths
    }

    /// Replace the cached PR statuses used by the notch HUD. The control panel
    /// still owns detailed actions; this cache exists so ambient PR-ready rows can
    /// say *which* PR is ready (#, title, branch, diff) instead of a generic label.
    func setPRStatusesByPath(_ statuses: [String: PRStatus]) {
        let observedAt = Date()
        prStatusObservedAtByPath = Dictionary(uniqueKeysWithValues: statuses.keys.map { ($0, observedAt) })
        publishPRStatusesByPath(statuses)
    }

    /// Apply a passive poll without letting it overwrite a newer explicit
    /// preflight. Merge actions call `setPRStatus` with their fresh result; if an
    /// older poll finishes later, its whole-map replacement must not resurrect a
    /// stale ready row or erase a fresh blocker.
    func applyPRPollStatuses(_ statuses: [String: PRStatus], observedAt: Date, replacing paths: Set<String>) {
        var next = prStatusesByPath
        for path in paths {
            if let current = prStatusObservedAtByPath[path], current > observedAt { continue }
            if let status = statuses[path], status.availability != .none {
                next[path] = status
            } else {
                next.removeValue(forKey: path)
            }
            prStatusObservedAtByPath[path] = observedAt
        }
        publishPRStatusesByPath(next)
    }

    func setPRStatus(_ status: PRStatus, for path: String, observedAt: Date = Date()) {
        var statuses = prStatusesByPath
        if status.availability == .none {
            statuses.removeValue(forKey: path)
        } else {
            statuses[path] = status
        }
        prStatusObservedAtByPath[path] = observedAt
        publishPRStatusesByPath(statuses)
    }

    private func publishPRStatusesByPath(_ statuses: [String: PRStatus]) {
        let ready = Set(statuses.compactMap { path, status in
            status.availability == .available ? path : nil
        })
        guard statuses != prStatusesByPath || ready != prReadyPaths else { return }
        prStatusesByPath = statuses
        prReadyPaths = ready
    }

    func refreshWorktrees(projectId: String) async {
        let refs = await GitService.shared.worktrees(at: projectId)
        guard !refs.isEmpty,
              let i = projects.firstIndex(where: { $0.id == projectId }) else { return }
        let root = projects[i].rootPath
        let existingColors = Dictionary(
            projects[i].worktrees.map { ($0.path, $0.colorName) },
            uniquingKeysWith: { first, _ in first }
        )
        projects[i].worktrees = refs.enumerated().map { index, ref in
            let primary = ref.path == root
            return Worktree(
                id: "\(projectId)#\(index)",
                projectId: projectId,
                branch: ref.branch,
                path: ref.path,
                shade: primary ? 0 : shade(forIndex: index),
                isPrimary: primary,
                colorName: existingColors[ref.path] ?? nil
            )
        }
        save()
    }

    /// Alternate lighter/darker shades for non-primary worktrees: +1, -1, +2, -2.
    func shade(forIndex index: Int) -> Int {
        let step = (index + 1) / 2
        return index.isMultiple(of: 2) ? -step : step
    }

    private func normalizedActiveProjectId(_ decodedId: String?, projects: [Project]) -> String? {
        if let decodedId, projects.contains(where: { $0.id == decodedId }) {
            return decodedId
        }
        // Old single-project workspaces had no scope field; treat the one saved
        // project as current. Multi-project old workspaces stay explicit "All
        // projects" until the user opens/selects one.
        return projects.count == 1 ? projects.first?.id : nil
    }
}
