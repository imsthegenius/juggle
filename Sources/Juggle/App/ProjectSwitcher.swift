import AppKit
import Combine
import SwiftUI

/// R4 + R12: the keyboard switcher — a Spotlight-style command surface that jumps
/// focus to a terminal by repo, and **echoes attention** so a blocked agent on a
/// window parked on another display floats to the top and is still catchable.
///
/// Roles, kept deliberately distinct:
///   • Notch HUD (always-on)  — *push*: ambiently tells you WHAT needs you (PR
///     ready, blocked, error, done) across every project, with no keystroke.
///   • ⌘J switcher (on demand) — *pull*: when you decide to act, jump to any
///     terminal by typing. It mirrors the same attention order so the two read
///     the same, but it is a jump tool, not the awareness surface.
///   • Settings (⌘,)          — preferences only.
///
/// One row per open terminal: project-colored dot, title, branch, and a restrained
/// state glyph. Attention-needing rows sort first. Type to filter; ↑/↓ to move;
/// ↩ to jump; esc to dismiss (key handling lives in `AppDelegate`).
struct SwitcherRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let projectName: String
    let branch: String?
    let color: NSColor
    let attention: AttentionState

    var needsAttention: Bool { attention == .blocked || attention == .done || attention == .error }
}

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var query = "" { didSet { rebuild() } }
    @Published private(set) var rows: [SwitcherRow] = []
    @Published var selectedID: UUID?

    /// Set by the host: jump to a terminal, and close the switcher.
    var onActivate: ((UUID) -> Void)?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        rebuild()
        // R12: keep echoing live — a window that becomes blocked while the
        // switcher is open re-sorts to the top without a reopen.
        AppModel.shared.$openTerminals
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        AppModel.shared.$projects
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
        AppModel.shared.$activeProjectId
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &cancellables)
    }

    func move(_ delta: Int) {
        guard !rows.isEmpty else { selectedID = nil; return }
        let current = rows.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(0, current + delta), rows.count - 1)
        selectedID = rows[next].id
    }

    func activateSelection() {
        guard let id = selectedID else { return }
        onActivate?(id)
    }

    private func rebuild() {
        let model = AppModel.shared
        let projects = Dictionary(uniqueKeysWithValues: model.projects.map { ($0.id, $0) })
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()

        let mapped: [SwitcherRow] = model.visibleOpenTerminals.map { terminal in
            let project = projects[terminal.projectId]
            let worktree = project?.worktrees.first { $0.id == terminal.worktreeId }
            let colorName = worktree?.colorName ?? project?.colorName
            let fallbackProjectName = URL(fileURLWithPath: terminal.projectId).lastPathComponent
            return SwitcherRow(
                id: terminal.id,
                title: terminal.title,
                // Real rows should always have a `Project`, but this fallback keeps
                // the switcher useful (and searchable) if a stale live-terminal row
                // briefly outlives its model entry.
                projectName: project?.displayName ?? (fallbackProjectName.isEmpty ? "Project" : fallbackProjectName),
                branch: worktree.map { $0.branch.isEmpty ? "main" : $0.branch },
                color: RepoColor.nsColor(for: colorName),
                attention: terminal.attention
            )
        }
        .filter { row in
            trimmed.isEmpty
                || row.projectName.lowercased().contains(trimmed)
                || row.title.lowercased().contains(trimmed)
                || (row.branch?.lowercased().contains(trimmed) ?? false)
        }
        // Attention first (the whole point of the echo), then project, then title.
        .sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention { return lhs.needsAttention }
            if lhs.projectName != rhs.projectName { return lhs.projectName < rhs.projectName }
            return lhs.title < rhs.title
        }

        rows = mapped
        if selectedID == nil || !mapped.contains(where: { $0.id == selectedID }) {
            selectedID = mapped.first?.id
        }
    }
}

struct ProjectSwitcherView: View {
    @ObservedObject var model: SwitcherModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14, weight: .medium))
                TextField("Jump to a terminal…", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if model.rows.isEmpty {
                emptyState
            } else {
                rowList
            }

            Divider()
            footer
        }
        .frame(width: 560)
        .frame(maxHeight: 420)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .onAppear { searchFocused = true }
    }

    private var rowList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        SwitcherRowView(row: row, selected: row.id == model.selectedID)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedID = row.id
                                model.activateSelection()
                            }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 330)
            .onChange(of: model.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.on.rectangle.slash")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "No open terminals" : "No matches")
                .foregroundStyle(.secondary)
            Text("⌘N opens a terminal · ⌘O adds a project")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            shortcutHint("↑↓", "Navigate")
            shortcutHint("↩", "Jump")
            shortcutHint("esc", "Close")
            Spacer()
            Text("\(model.rows.count) open")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

private struct SwitcherRowView: View {
    let row: SwitcherRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 11) {
            Circle()
                .fill(Color(nsColor: row.color))
                .frame(width: 10, height: 10)
                .overlay(
                    Circle().strokeBorder(Color(nsColor: row.color).opacity(0.5), lineWidth: row.needsAttention ? 3 : 0)
                        .frame(width: 16, height: 16)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(row.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(row.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if let branch = row.branch {
                Text(branch)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .trailing)
            }

            stateGlyph
                .frame(width: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                // Single-accent rule (U8): the selected-row highlight uses the
                // app accent, not `Color.accentColor` (the system highlight,
                // default blue), which reads as a competing second accent.
                .fill(selected ? CockpitStyle.accent.opacity(0.22) : .clear)
                .padding(.horizontal, 6)
        )
    }

    @ViewBuilder private var stateGlyph: some View {
        switch row.attention {
        case .blocked:
            Image(systemName: "bell.fill").font(.system(size: 11)).foregroundStyle(Color(nsColor: row.color))
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color(nsColor: row.color))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red)
        case .commandFinished:
            Image(systemName: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        case .working:
            EmptyView()
        }
    }
}

/// A borderless panel that can still become key, so the switcher's search field
/// receives typing and the host can route ↑/↓/↩/esc to it.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
