import AppKit
import SwiftUI

struct ProjectOpenPromptActions {
    let openProject: () -> Void
    let showControlPanel: () -> Void
    let replayOnboarding: () -> Void
    let openRecentProject: (Project) -> Void

    init(
        openProject: @escaping () -> Void,
        showControlPanel: @escaping () -> Void,
        replayOnboarding: @escaping () -> Void,
        openRecentProject: @escaping (Project) -> Void = { _ in }
    ) {
        self.openProject = openProject
        self.showControlPanel = showControlPanel
        self.replayOnboarding = replayOnboarding
        self.openRecentProject = openRecentProject
    }
}

/// First visible surface for a fresh install/no-project launch.
/// It intentionally behaves like an IDE welcome window: pick a folder, then the
/// rest of the app has something concrete to restore, watch, and arrange.
struct ProjectOpenPromptView: View {
    let actions: ProjectOpenPromptActions
    let projects: [Project]

    init(actions: ProjectOpenPromptActions, projects: [Project] = []) {
        self.actions = actions
        self.projects = projects
    }

    private let accent = Color(nsColor: RepoColor.palette[0].nsColor)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
            Spacer(minLength: 0)
            footer
        }
        .frame(minWidth: 500, minHeight: 318)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.18))
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text("Juggle")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("Projects, worktrees, terminals")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        if projects.isEmpty {
            emptyProjectContent
        } else {
            recentProjectsContent
        }
    }

    private var emptyProjectContent: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(systemName: "folder")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(accent)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Open a project")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Choose a folder or git repository to start.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                launchActions
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
    }

    private var recentProjectsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Welcome back")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Open a recent project or choose another folder.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                launchActions
            }

            VStack(spacing: 7) {
                ForEach(projects.prefix(6)) { project in
                    Button { actions.openRecentProject(project) } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(nsColor: RepoColor.nsColor(for: project.colorName)))
                                .frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text(shortPath(project.rootPath))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.055)))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.075)))
                    }
                    .buttonStyle(.plain)
                    .help("Open \(project.displayName)")
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }

    private var launchActions: some View {
        HStack(spacing: 10) {
            Button(action: actions.openProject) {
                Label("Open Project...", systemImage: "folder.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(Color.black.opacity(0.88))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .keyboardShortcut(.defaultAction)
            .help("Choose a project folder or git repository")

            Button("Control Panel", action: actions.showControlPanel)
                .buttonStyle(.plain)
                .focusable(false)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))
                .controlSize(.large)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var footer: some View {
        HStack {
            Text(footerText)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Replay tour", action: actions.replayOnboarding)
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
        .background(Color.black.opacity(0.08))
    }

    private var footerText: String {
        projects.isEmpty
            ? "Use File > Open Project... or Command-O any time."
            : "Recent projects stay here when no terminal windows were restored."
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
