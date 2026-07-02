import AppKit
import Foundation

/// The shared cockpit model for Juggle's two primary surfaces:
/// - the first screen in the menu-bar control panel
/// - the ambient top notch HUD
///
/// This intentionally answers one product question: "what needs me across my
/// projects and PRs right now?" It is computed from project/worktree state,
/// live terminal attention, and cached GitHub PR state. A ready PR is included
/// even when its worktree has no open terminal, because the user still needs to
/// know about it.
enum NeedsYouPrimaryAction: Equatable {
    case mergePR
    case openPR
    case jumpToTerminal
}

struct NeedsYouItem: Identifiable, Equatable {
    let id: String
    let projectId: String
    let worktreeId: String
    let worktreePath: String
    let branch: String
    let projectName: String
    let color: NSColor
    let reason: HUDReason
    let detail: String?
    let meta: String?
    let activateTerminalId: UUID?
    let primaryAction: NeedsYouPrimaryAction
    let prURL: String?

    static func == (lhs: NeedsYouItem, rhs: NeedsYouItem) -> Bool {
        lhs.id == rhs.id
            && lhs.projectId == rhs.projectId
            && lhs.worktreeId == rhs.worktreeId
            && lhs.worktreePath == rhs.worktreePath
            && lhs.branch == rhs.branch
            && lhs.projectName == rhs.projectName
            && lhs.color.hexString == rhs.color.hexString
            && lhs.reason == rhs.reason
            && lhs.detail == rhs.detail
            && lhs.meta == rhs.meta
            && lhs.activateTerminalId == rhs.activateTerminalId
            && lhs.primaryAction == rhs.primaryAction
            && lhs.prURL == rhs.prURL
    }

    var collapsedTitle: String {
        switch reason {
        case .prReady:
            if let detail, !detail.isEmpty {
                let number = detail.components(separatedBy: " · ").first ?? "PR"
                return "\(projectName) · \(number) ready"
            }
            return "\(projectName) · PR ready"
        case .blocked: return "\(projectName) · Blocked"
        case .error: return "\(projectName) · Error"
        case .done: return "\(projectName) · Done"
        }
    }
}

enum NeedsYouQueue {
    static func compute(
        projects: [Project],
        terminals: [OpenTerminal],
        prStatusesByPath: [String: PRStatus],
        prReadyPaths: Set<String> = []
    ) -> [NeedsYouItem] {
        let terminalByWorktree = Dictionary(grouping: terminals, by: \.worktreeId)
        var consumedWorktreeIds: Set<String> = []
        var items: [NeedsYouItem] = []

        for project in projects {
            for worktree in project.worktrees {
                guard let status = prStatus(for: worktree.path, statuses: prStatusesByPath) else { continue }
                let terminal = terminalByWorktree[worktree.id]?.first
                consumedWorktreeIds.insert(worktree.id)
                let mergeable = status.availability == .available
                items.append(NeedsYouItem(
                    id: "pr:\(worktree.path)",
                    projectId: project.id,
                    worktreeId: worktree.id,
                    worktreePath: worktree.path,
                    branch: displayBranch(worktree.branch),
                    projectName: project.displayName,
                    color: color(project: project, worktree: worktree),
                    reason: mergeable ? .prReady : .blocked,
                    detail: mergeable ? prDetail(status: status) : prBlockerDetail(status: status),
                    meta: prMeta(status: status, fallbackBranch: displayBranch(worktree.branch)),
                    activateTerminalId: terminal?.id,
                    primaryAction: mergeable ? .mergePR : .openPR,
                    prURL: status.url
                ))
            }
        }

        let projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for terminal in terminals {
            guard !consumedWorktreeIds.contains(terminal.worktreeId) else { continue }
            guard let reason = reason(for: terminal.attention) else { continue }
            let project = projectsById[terminal.projectId]
            let worktree = project?.worktrees.first { $0.id == terminal.worktreeId }
            items.append(NeedsYouItem(
                id: "terminal:\(terminal.id.uuidString)",
                projectId: terminal.projectId,
                worktreeId: terminal.worktreeId,
                worktreePath: worktree?.path ?? "",
                branch: displayBranch(worktree?.branch ?? ""),
                projectName: project?.displayName ?? URL(fileURLWithPath: terminal.projectId).lastPathComponent,
                color: project.map { color(project: $0, worktree: worktree) } ?? .tertiaryLabelColor,
                reason: reason,
                detail: terminal.title,
                meta: worktreeMeta(worktree),
                activateTerminalId: terminal.id,
                primaryAction: .jumpToTerminal,
                prURL: nil
            ))
        }

        return items.sorted { lhs, rhs in
            if lhs.reason != rhs.reason { return lhs.reason < rhs.reason }
            if lhs.projectName != rhs.projectName { return lhs.projectName < rhs.projectName }
            return lhs.branch < rhs.branch
        }
    }

    private static func prStatus(
        for path: String,
        statuses: [String: PRStatus]
    ) -> PRStatus? {
        if let status = statuses[path], status.availability != .none { return status }
        return nil
    }

    private static func reason(for attention: AttentionState) -> HUDReason? {
        switch attention {
        case .blocked: return .blocked
        case .error: return .error
        case .done: return .done
        case .working, .commandFinished: return nil
        }
    }

    private static func color(project: Project, worktree: Worktree?) -> NSColor {
        let base = RepoColor.nsColor(for: project.colorName)
        guard let worktree else { return base }
        return worktree.colorName.map { RepoColor.nsColor(for: $0) } ?? base.shadedRepo(worktree.shade)
    }

    static func displayBranch(_ branch: String) -> String {
        branch.isEmpty ? "main" : branch
    }

    static func prDetail(status: PRStatus?) -> String {
        guard let status else { return "PR ready" }
        let number = status.number.map { "#\($0)" } ?? "PR"
        let title = status.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return "\(number) ready" }
        return "\(number) · \(title)"
    }

    static func prBlockerDetail(status: PRStatus) -> String {
        let number = status.number.map { "#\($0)" } ?? "PR"
        return "\(number) · \(status.summary.isEmpty ? "Not mergeable" : status.summary)"
    }

    static func prMeta(status: PRStatus?, fallbackBranch: String? = nil) -> String? {
        var parts: [String] = []
        if let headRefName = status?.headRefName, !headRefName.isEmpty {
            parts.append(headRefName)
        } else if let fallbackBranch, !fallbackBranch.isEmpty {
            parts.append(fallbackBranch)
        }
        if let additions = status?.additions, let deletions = status?.deletions {
            parts.append("+\(additions) −\(deletions)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func worktreeMeta(_ worktree: Worktree?) -> String? {
        guard let worktree else { return nil }
        let branch = displayBranch(worktree.branch)
        return branch.isEmpty ? nil : branch
    }
}
