import AppKit
import SwiftUI

/// The cockpit: add projects, name them, set per-project and per-worktree colors,
/// open terminals, create worktrees, watch open terminals (with attention), and
/// open / merge PRs. Lives in the menu-bar popover; can detach into a window.
struct ControlPanelView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(spacing: 0) {
            ControlPanelHeader(
                projectCount: model.projects.count,
                scopeTitle: model.scopeTitle,
                needsCount: model.needsYouItems.count
            )

            separator

            if model.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.projects.count > 1 {
                            ProjectScopeBar()
                        }
                        NeedsYouSection(items: model.needsYouItems)
                        Divider().opacity(0.55)
                        HStack {
                            Text(model.activeProject == nil ? "Projects" : "Current project")
                                .font(.system(size: 11, weight: .bold))
                                .textCase(.uppercase)
                                .kerning(0.8)
                                .foregroundStyle(CockpitStyle.secondaryText)
                            Spacer()
                            Text(projectCountText)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(CockpitStyle.tertiaryText)
                        }
                        ForEach(model.visibleProjects) { project in
                            ProjectRow(project: project)
                                .padding(10)
                                .background(cardFill)
                                .overlay(cardStroke)
                        }
                    }
                    .padding(14)
                }
            }

            separator
            footer
        }
        .frame(minWidth: 500, minHeight: 560)
        .foregroundStyle(CockpitStyle.primaryText)
        .tint(CockpitStyle.accent)
        .preferredColorScheme(.dark)
        .background(CockpitStyle.panelBackground)
    }

    private var projectCountText: String {
        if model.activeProject != nil {
            return "\(model.visibleProjects.count) of \(model.projects.count)"
        }
        return "\(model.projects.count)"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(CockpitStyle.tertiaryText)
            Text("No project open").foregroundStyle(CockpitStyle.secondaryText)
            Button("Open Project...") { appController()?.openProjectViaPanel() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Grid")
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(CockpitStyle.secondaryText)
            GridSizePicker(columns: model.preferences.gridColumns, rows: model.preferences.gridRows) { columns, rows in
                appController()?.setGrid(columns: columns, rows: rows)
            }
            Spacer()
            Button("Tile") { appController()?.tileGrid() }
                .buttonStyle(CockpitPillButtonStyle())
                .help("Snap all open windows into the grid (⌘⌥G)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(CockpitStyle.footerBackground)
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.075))
            .frame(height: 1)
    }
}

private var cardFill: some ShapeStyle {
    CockpitStyle.cardFill
}

private var cardStroke: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(CockpitStyle.cardStroke)
}

private struct ControlPanelHeader: View {
    let projectCount: Int
    let scopeTitle: String
    let needsCount: Int

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(CockpitStyle.accent.opacity(0.16))
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(CockpitStyle.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Juggle")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(CockpitStyle.primaryText)
                    if needsCount > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(CockpitStyle.accent).frame(width: 5, height: 5)
                            Text("\(needsCount)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(CockpitStyle.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CockpitStyle.accent.opacity(0.12)))
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11.2))
                    .foregroundStyle(CockpitStyle.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                HeaderIconButton(systemName: "macwindow", help: "Open as a window — review diffs without it closing") {
                    detachControlPanel()
                }
                HeaderIconButton(systemName: "magnifyingglass", help: "Jump to a terminal (⌘J)") {
                    openSwitcher()
                }
                HeaderIconButton(systemName: "gearshape", help: "Settings — colours, layout, attention, terminal (⌘,)") {
                    openCommandCentre()
                }
                Button(action: { appController()?.openProjectViaPanel() }) {
                    Label("Open", systemImage: "folder.badge.plus")
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(CockpitPillButtonStyle(prominent: true))
                .help("Open a project folder or git repository")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(CockpitStyle.headerBackground)
    }

    private var subtitle: String {
        if projectCount == 0 { return "Open a folder or repo" }
        let projectText = "\(projectCount) project\(projectCount == 1 ? "" : "s")"
        return "\(scopeTitle) · \(projectText)"
    }
}

private struct ProjectScopeBar: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        HStack(spacing: 10) {
            Text("Scope")
                .font(.system(size: 11, weight: .bold))
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(CockpitStyle.secondaryText)

            Menu {
                Button { model.showAllProjects() } label: {
                    Label("All projects", systemImage: model.activeProjectId == nil ? "checkmark" : "square.grid.2x2")
                }
                Divider()
                ForEach(model.projects) { project in
                    Button { model.setActiveProject(project.id) } label: {
                        Label(project.displayName, systemImage: model.activeProjectId == project.id ? "checkmark" : "folder")
                    }
                }
            } label: {
                Text(model.scopeTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                .foregroundStyle(CockpitStyle.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(CockpitStyle.controlFill))
                .overlay(Capsule().strokeBorder(CockpitStyle.controlStroke))
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if model.activeProject != nil {
                Button("All projects") { model.showAllProjects() }
                    .buttonStyle(CockpitPillButtonStyle())
                    .help("Show every saved project")
            }
        }
        .padding(10)
        .background(cardFill)
        .overlay(cardStroke)
    }
}

private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CockpitStyle.secondaryText)
                .frame(width: 31, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CockpitStyle.controlFill))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(CockpitStyle.controlStroke))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct CockpitPillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? CockpitStyle.accent : CockpitStyle.primaryText)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, prominent ? 12 : 10)
            .padding(.vertical, prominent ? 7 : 6)
            .background(
                Capsule().fill(
                    prominent
                    ? CockpitStyle.accent.opacity(configuration.isPressed ? 0.24 : 0.15)
                    : (configuration.isPressed ? Color.white.opacity(0.12) : CockpitStyle.controlFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    prominent ? CockpitStyle.accent.opacity(0.44) : CockpitStyle.controlStroke,
                    lineWidth: 1
                )
            )
    }
}

private struct NeedsYouSection: View {
    let items: [NeedsYouItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Needs you")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(CockpitStyle.primaryText)
                    Text(summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CockpitStyle.secondaryText)
                }
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(CockpitStyle.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(CockpitStyle.accent.opacity(0.12)))
                }
            }

            if items.isEmpty {
                allClear
            } else {
                VStack(spacing: 7) {
                    ForEach(items.prefix(5)) { item in
                        NeedsYouRow(item: item)
                    }
                    if items.count > 5 {
                        Button { openSwitcher() } label: {
                            HStack {
                                Text("+\(items.count - 5) more")
                                Spacer()
                                Text("Open switcher")
                                    .foregroundStyle(CockpitStyle.secondaryText)
                                Image(systemName: "magnifyingglass")
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(CockpitStyle.primaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(CockpitStyle.controlFill))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var summary: String {
        guard !items.isEmpty else { return "No green PRs, blocked agents, or failed runs right now." }
        let ready = items.filter { $0.reason == .prReady }.count
        let blocked = items.filter { $0.reason == .blocked }.count
        var parts: [String] = []
        if ready > 0 { parts.append("\(ready) PR\(ready == 1 ? "" : "s") ready") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        if parts.isEmpty { parts.append("\(items.count) update\(items.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private var allClear: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(CockpitStyle.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CockpitStyle.primaryText)
                Text("Hover the top island any time to see what changed.")
                    .font(.system(size: 11))
                    .foregroundStyle(CockpitStyle.secondaryText)
            }
            Spacer()
        }
        .padding(12)
        .background(cardFill)
        .overlay(cardStroke)
    }
}

private struct NeedsYouRow: View {
    let item: NeedsYouItem
    @State private var checkingMerge = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(nsColor: item.color))
                .frame(width: 10, height: 10)

            textStack
            Spacer(minLength: 8)
            actionButton
        }
        .padding(10)
        .background(cardFill)
        .overlay(cardStroke)
        .contentShape(Rectangle())
    }

    private var textStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.projectName)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(CockpitStyle.primaryText)
                    .lineLimit(1)
                Text(item.reason.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(reasonTint)
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11.3))
                    .foregroundStyle(CockpitStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let meta = item.meta, !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(CockpitStyle.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if item.primaryAction == .mergePR {
            Button(actionTitle) { beginMerge() }
                .buttonStyle(NeedsYouActionButtonStyle(color: Color(nsColor: item.color), prominent: true))
                .disabled(checkingMerge)
        } else {
            Button(actionTitle) { activateNeedsYou(item) }
                .buttonStyle(NeedsYouActionButtonStyle(color: Color(nsColor: item.color)))
        }
    }

    private var actionTitle: String {
        if checkingMerge { return "Checking..." }
        switch item.primaryAction {
        case .mergePR: return "Merge"
        case .openPR: return "Review"
        case .jumpToTerminal: return "Jump"
        }
    }

    private var reasonTint: Color {
        item.reason == .error ? Color(nsColor: .systemRed) : Color(nsColor: item.color)
    }

    private func beginMerge() {
        guard !checkingMerge else { return }
        checkingMerge = true
        Task { @MainActor in
            if let controller = appController() {
                await controller.mergePRAfterFreshCheck(at: item.worktreePath)
            }
            checkingMerge = false
        }
    }
}

private struct NeedsYouActionButtonStyle: ButtonStyle {
    let color: Color
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.86) : CockpitStyle.primaryText)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    prominent
                    ? color.opacity(configuration.isPressed ? 0.78 : 0.92)
                    : (configuration.isPressed ? Color.white.opacity(0.12) : CockpitStyle.controlFill)
                )
            )
            .overlay(Capsule().strokeBorder(prominent ? color.opacity(0.62) : CockpitStyle.controlStroke))
    }
}
