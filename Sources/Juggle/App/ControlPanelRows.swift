import AppKit
import SwiftUI

struct ProjectRow: View {
    let project: Project
    @ObservedObject private var model = AppModel.shared
    @State private var name = ""
    @State private var showingNewWorktree = false
    @State private var newBranch = ""
    @State private var showingOpenWorktree = false
    @State private var openableBranches: [String] = []
    @State private var loadingBranches = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                ColorSwatchPicker(currentName: project.colorName) { picked in
                    if let picked { model.recolor(projectId: project.id, colorName: picked) }
                }
                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CockpitStyle.primaryText)
                    .onSubmit { model.rename(projectId: project.id, to: name) }
                Spacer()
                Text(shortPath(project.rootPath))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CockpitStyle.tertiaryText)
                    .lineLimit(1).truncationMode(.head)
                Button("Open") {
                    if let worktree = project.primaryWorktree {
                        model.openWindow(projectId: project.id, worktreeId: worktree.id)
                    }
                }
                .buttonStyle(RowControlButtonStyle())
                Menu {
                    Button("New worktree…", systemImage: "plus") { showingNewWorktree = true }
                    Button("Open existing branch…", systemImage: "folder.badge.plus") { beginOpenWorktree() }
                } label: {
                    Label("Worktree", systemImage: "plus.square.on.square")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CockpitStyle.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(CockpitStyle.controlFill))
                        .overlay(Capsule().strokeBorder(CockpitStyle.controlStroke))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Menu {
                    Button("Remove from Juggle", role: .destructive) { model.remove(projectId: project.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CockpitStyle.secondaryText)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }

            ForEach(orderedWorktrees) { worktree in
                WorktreeRow(project: project, worktree: worktree)
            }
        }
        .padding(.vertical, 4)
        .foregroundStyle(CockpitStyle.primaryText)
        .onAppear { name = project.displayName }
        .alert("New worktree", isPresented: $showingNewWorktree) {
            TextField("branch name (e.g. feature/x)", text: $newBranch)
            Button("Create") {
                let branch = newBranch
                newBranch = ""
                Task { await model.createWorktree(projectId: project.id, branch: branch) }
            }
            .disabled(newBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { newBranch = "" }
        } message: {
            Text("Creates a new branch under .worktrees/ and opens a terminal in it.")
        }
        .confirmationDialog("Open an existing branch as a worktree", isPresented: $showingOpenWorktree, titleVisibility: .visible) {
            ForEach(openableBranches, id: \.self) { branch in
                Button(branch) {
                    Task { await model.openExistingWorktree(projectId: project.id, branch: branch) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(openWorktreeMessage)
        }
    }

    /// Load branches that aren't already checked out, then present the picker.
    /// If git has no other branches, we still show the dialog with a clear message.
    private func beginOpenWorktree() {
        loadingBranches = true
        Task {
            let branches = await model.openableBranches(projectId: project.id)
            await MainActor.run {
                openableBranches = branches
                loadingBranches = false
                showingOpenWorktree = true
            }
        }
    }

    private var openWorktreeMessage: String {
        if loadingBranches { return "Loading branches…" }
        if openableBranches.isEmpty {
            return "No other local branches to open. Create one with “New worktree…”, or make a branch in the terminal first."
        }
        return "Checks the selected branch out into a worktree under .worktrees/."
    }

    private var orderedWorktrees: [Worktree] {
        project.worktrees.sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if (lhs.branch == "detached") != (rhs.branch == "detached") {
                return rhs.branch == "detached"
            }
            return lhs.displayBranch.localizedCaseInsensitiveCompare(rhs.displayBranch) == .orderedAscending
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct WorktreeRow: View {
    let project: Project
    let worktree: Worktree
    @ObservedObject private var model = AppModel.shared

    private var terminals: [OpenTerminal] { model.terminals(forWorktree: worktree.id) }
    private var hasOpenTerminal: Bool { !terminals.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                ColorSwatchPicker(currentName: worktree.colorName ?? project.colorName, allowClear: true) { picked in
                    model.setWorktreeColor(projectId: project.id, worktreeId: worktree.id, colorName: picked)
                }
                .scaleEffect(0.8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(worktree.displayBranch)
                            .font(.system(size: 11.5, weight: hasOpenTerminal ? .semibold : .regular, design: .monospaced))
                            .foregroundStyle(hasOpenTerminal ? CockpitStyle.primaryText : CockpitStyle.secondaryText)
                            .lineLimit(1).truncationMode(.middle)
                        if hasOpenTerminal {
                            Text("open")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundStyle(CockpitStyle.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(CockpitStyle.accent.opacity(0.13)))
                        }
                    }
                    Text(worktree.shortPath)
                        .font(.system(size: 9.8, design: .monospaced))
                        .foregroundStyle(CockpitStyle.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                PRChip(path: worktree.path, branch: worktree.branch)

                Button("Terminal") {
                    model.openWindow(projectId: project.id, worktreeId: worktree.id)
                }
                .buttonStyle(RowControlButtonStyle(compact: true))
            }

            // project ▸ worktree ▸ open terminals — each can blink for attention
            // and click to jump straight to its window.
            ForEach(terminals) { terminal in
                TerminalRow(terminal: terminal)
            }
        }
        .padding(.leading, 22)
        .opacity(worktree.branch == "detached" && !hasOpenTerminal ? 0.62 : 1)
    }
}

/// A live terminal in the tree: a status dot that blinks when its agent is
/// blocked, and a click that raises + focuses the window.
private struct TerminalRow: View {
    let terminal: OpenTerminal
    @ObservedObject private var model = AppModel.shared
    @State private var pulsing = false

    var body: some View {
        Button { AppModel.shared.focusTerminal(id: terminal.id) } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color(nsColor: dotColor))
                    .frame(width: 7, height: 7)
                    .opacity(terminal.needsAttention && pulsing ? 0.25 : 1)
                Image(systemName: "terminal")
                    .font(.system(size: 9.5))
                    .foregroundStyle(CockpitStyle.tertiaryText)
                Text(terminal.title)
                    .font(.system(size: 11))
                    .foregroundStyle(terminal.needsAttention ? CockpitStyle.primaryText : CockpitStyle.secondaryText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 18)
        .help("Jump to this terminal")
        .onAppear { updatePulse() }
        .onChange(of: terminal.needsAttention) { _, _ in updatePulse() }
    }

    private var dotColor: NSColor {
        switch terminal.attention {
        case .working: .tertiaryLabelColor
        case .blocked, .done, .commandFinished: terminalColor
        case .error: .systemRed
        }
    }

    private var terminalColor: NSColor {
        guard let project = model.project(terminal.projectId) else { return CockpitStyle.nsAccent }
        guard let worktree = project.worktrees.first(where: { $0.id == terminal.worktreeId }) else {
            return RepoColor.nsColor(for: project.colorName)
        }
        if let colorName = worktree.colorName { return RepoColor.nsColor(for: colorName) }
        return RepoColor.nsColor(for: project.colorName).shadedRepo(worktree.shade)
    }

    private func updatePulse() {
        if terminal.needsAttention {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulsing = true }
        } else {
            withAnimation(.default) { pulsing = false }
        }
    }
}

/// A compact, native PR status chip for a worktree's branch — number, diff size,
/// CI/merge state — with Open-PR / Merge actions. The info is a plain pill (so it
/// always renders), and the actions live behind a small trailing chevron menu.
private struct PRChip: View {
    let path: String
    let branch: String
    @ObservedObject private var model = AppModel.shared
    @State private var status: PRStatus = .none
    @State private var loaded = false
    @State private var checkingMerge = false

    private var canCreateDraftPR: Bool {
        !branch.isEmpty && branch != "detached"
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            } else if status.availability == .none {
                if canCreateDraftPR {
                    Button {
                        appController()?.openDraftPR(at: path)
                        scheduleReload()
                    } label: {
                        Label("Open PR", systemImage: "arrow.triangle.pull")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(CockpitStyle.primaryText)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .help("Create a draft pull request for \(branch)")
                } else {
                    EmptyView()
                }
            } else {
                HStack(spacing: 5) {
                    infoPill
                    if status.availability == .available {
                        Button {
                            beginMerge()
                        } label: {
                            Label(checkingMerge ? "Checking..." : "Merge",
                                  systemImage: checkingMerge ? "arrow.clockwise" : "arrow.triangle.merge")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.black.opacity(0.84))
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                        .tint(CockpitStyle.accent)
                        .disabled(checkingMerge)
                        .help(mergeHelp)
                    }
                    actionMenu
                }
            }
        }
        .task(id: path) { await load() }
    }

    private var infoPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 9)).foregroundStyle(CockpitStyle.secondaryText)
            if let number = status.number {
                Text("#\(number)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(CockpitStyle.primaryText)
            }
            if let adds = status.additions, let dels = status.deletions, adds + dels > 0 {
                Text("+\(adds)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(CockpitStyle.secondaryText)
                Text("−\(dels)").font(.system(size: 9.5, weight: .medium)).foregroundStyle(CockpitStyle.secondaryText)
            }
            Circle().fill(Color(nsColor: stateColor)).frame(width: 6, height: 6)
            Text(status.summary).font(.system(size: 9.5)).foregroundStyle(CockpitStyle.secondaryText).lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(CockpitStyle.controlFill))
        .overlay(Capsule().strokeBorder(CockpitStyle.controlStroke))
        .fixedSize()
        .help(status.title ?? status.summary)
    }

    private var actionMenu: some View {
        Menu {
            if let number = status.number, let title = status.title {
                Section("#\(number) · \(title)") {
                    if status.availability == .available {
                        Button("Merge pull request…", systemImage: "arrow.triangle.merge") {
                            beginMerge()
                        }
                    }
                    if status.url != nil {
                        Button("View on GitHub", systemImage: "safari") { openOnGitHub() }
                    }
                }
            } else if status.availability == .available {
                Button("Merge pull request…", systemImage: "arrow.triangle.merge") {
                    beginMerge()
                }
            }
            Divider()
            if canCreateDraftPR {
                Button("Open new draft PR", systemImage: "arrow.triangle.pull") {
                    appController()?.openDraftPR(at: path); scheduleReload()
                }
            }
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(CockpitStyle.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var mergeHelp: String {
        if let number = status.number, let title = status.title {
            return "Merge #\(number) — \(title)"
        }
        return "Merge this pull request"
    }

    private func openOnGitHub() {
        guard let urlString = status.url, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func beginMerge() {
        guard !checkingMerge else { return }
        checkingMerge = true
        Task { @MainActor in
            if let controller = appController() {
                await controller.mergePRAfterFreshCheck(at: path)
            }
            checkingMerge = false
            await load()
        }
    }

    private var stateColor: NSColor {
        switch status.availability {
        case .available, .checksRunning, .behind: CockpitStyle.nsAccent
        case .blocked: .systemRed
        case .draft, .none: .systemGray
        }
    }

    private func load() async {
        if let cached = model.prStatusesByPath[path] {
            status = cached
            loaded = true
            if CommandLine.arguments.contains("--control-panel-shot") { return }
        }
        status = await GhService.shared.status(at: path)
        loaded = true
    }

    /// gh actions take a few seconds; re-check once they've had time to land.
    private func scheduleReload() {
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await load()
        }
    }
}

private struct RowControlButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 10.5 : 11, weight: .medium))
            .foregroundStyle(CockpitStyle.primaryText)
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 5)
            .background(Capsule().fill(configuration.isPressed ? Color.white.opacity(0.12) : CockpitStyle.controlFill))
            .overlay(Capsule().strokeBorder(CockpitStyle.controlStroke))
    }
}
