import AppKit
import Combine
import SwiftUI

/// The notch HUD: an ambient attention strip that hangs from the top-center of
/// the screen (under the menu bar / from the MacBook notch). It is the *push*
/// counterpart to the ⌘J switcher's *pull*: the user shouldn't have to invoke a
/// surface or stare at a window to learn that a PR went green or an agent got
/// blocked. The HUD shows, across every project at once, only what needs them —
/// in each project's identity color — and clicking a row jumps to that terminal.
///
/// Identity stays hue; the HUD never invents a competing palette. Error is the
/// one restrained second color, matching the window breathing model.

/// Why a terminal (or its PR) wants the user. Ordered by urgency for sorting.
enum HUDReason: Int, Comparable {
    case prReady = 0     // a PR went green — the owner's headline ambient case
    case blocked = 1     // agent waiting on input
    case error = 2       // command failed / crashed
    case done = 3        // task finished / idle

    static func < (lhs: HUDReason, rhs: HUDReason) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .prReady: "PR ready"
        case .blocked: "Blocked"
        case .error: "Error"
        case .done: "Done"
        }
    }

    var symbol: String {
        switch self {
        case .prReady: "checkmark.seal.fill"
        case .blocked: "bell.fill"
        case .error: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        }
    }
}

/// One dot in the collapsed notch pill. When `active` is true it can breathe;
/// when false it is just a quiet project-presence dot ("Juggle is here").
struct HUDDot: Identifiable, Equatable {
    let id: String
    let color: NSColor
    let active: Bool

    static func == (lhs: HUDDot, rhs: HUDDot) -> Bool {
        lhs.id == rhs.id && lhs.active == rhs.active
            && lhs.color.hexString == rhs.color.hexString
    }
}

@MainActor
final class NotchHUDModel: ObservableObject {
    @Published private(set) var items: [NeedsYouItem] = []
    @Published private(set) var idleDots: [HUDDot] = []
    /// Short-lived IDs for PR rows that just transitioned to ready. This drives
    /// the one-shot arrival flourish, not a persistent alert.
    @Published private(set) var arrivingItemIDs: Set<String> = []
    @Published var expanded = false
    @Published private(set) var hovered = false

    /// Activate a cockpit item (set by the host): jump to its terminal, open the
    /// worktree, or run the PR action depending on what the row represents.
    var onActivate: ((NeedsYouItem) -> Void)?
    /// Open the ⌘J switcher from the HUD header (set by the host).
    var onOpenSwitcher: (() -> Void)?
    /// Tells the host the visible-item count changed, so the panel can reposition
    /// on display changes or diagnostics can capture the new rendered size.
    var onItemsChanged: (() -> Void)?
    /// Open the project picker from the empty-state node (set by the host).
    var onAddProject: (() -> Void)?
    /// Merge a ready PR in-place — git merge, no blocking dialog (set by host).
    var onMerge: ((NeedsYouItem) -> Void)?
    /// Open a PR on GitHub (the row-tap for a PR-ready item) (set by host).
    var onOpenPR: ((NeedsYouItem) -> Void)?
    /// PRs currently being merged, so the row can show "Merging…" non-modally.
    @Published private(set) var mergingItemIDs: Set<String> = []
    /// PRs currently being freshly checked before merge.
    @Published private(set) var checkingItemIDs: Set<String> = []
    /// Rendered SwiftUI card/nub size. Diagnostics use this because the AppKit
    /// host window is intentionally fixed-size for smooth hover motion.
    private(set) var renderedSurfaceSize: CGSize = .zero
    var onRenderedSurfaceSize: ((CGSize) -> Void)?

    /// True when at least one project is registered. Drives the empty-state node
    /// ("Open Project") vs the calm all-clear node.
    @Published private(set) var hasProjects = false
    /// Bumped whenever the rendered content changes, so the view can scope its
    /// size animation to real content changes.
    @Published private(set) var revision = 0

    private var cancellables: Set<AnyCancellable> = []
    private static let panelClickMaxRows = 3
    private static let expandedHeaderHeight: CGFloat = 30
    private var panelRowFramesByID: [String: NSRect] = [:]
    private var panelMergeButtonFramesByID: [String: NSRect] = [:]
    /// Monotonic token so a pending hover-out collapse is cancelled the moment the
    /// pointer comes back (or a click forces a state). Swift-6-safe debounce: no
    /// Sendable capture, the Task hops to the main actor and checks the token.
    private var collapseToken = 0
    /// `onContinuousHover` emits repeated active positions. Track semantic
    /// inside/outside state so those samples don't restart animations.
    private var hovering = false
    private var arrivalBaselineEstablished = false

    init() {
        rebuild()
        let model = AppModel.shared
        // Recompute whenever attention, the project list, or PR status moves.
        model.$openTerminals.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        model.$projects.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        model.$activeProjectId.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        model.$prStatusesByPath.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        model.$prReadyPaths.receive(on: RunLoop.main).sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
    }

    /// Attention items are the urgent state; idle dots are the dormant "Juggle is
    /// active" state.
    var hasItems: Bool { !items.isEmpty }
    /// The node is the app's ambient presence: always visible, like the macOS
    /// menu bar or a Dynamic-Island pill. When there is nothing to act on it is a
    /// calm "all clear"; with no projects it becomes the first-run entry point.
    /// Always showing it fixes the "I opened the app and nothing happened" gap.
    var shouldShow: Bool { true }

    /// Pure aggregation: registered worktrees + open terminals + PR state →
    /// sorted cockpit items. Kept as a forwarding seam for older unit tests.
    static func computeItems(
        terminals: [OpenTerminal],
        projects: [Project],
        prStatusesByPath: [String: PRStatus] = [:],
        prReadyPaths: Set<String> = []
    ) -> [NeedsYouItem] {
        NeedsYouQueue.compute(
            projects: projects,
            terminals: terminals,
            prStatusesByPath: prStatusesByPath,
            prReadyPaths: prReadyPaths
        )
    }

    static func prArrivalIDs(
        previous: [NeedsYouItem],
        next: [NeedsYouItem],
        baselineEstablished: Bool
    ) -> Set<String> {
        guard baselineEstablished else { return [] }
        let previousReady = Set(previous.filter { $0.reason == .prReady }.map(\.id))
        let nextReady = Set(next.filter { $0.reason == .prReady }.map(\.id))
        return nextReady.subtracting(previousReady)
    }

    /// Dormant project-presence dots for the collapsed HUD when nothing needs the
    /// user. One dot per project with an open terminal. This is intentionally not
    /// an alert; it exists so the top node is visibly available after onboarding
    /// and can expand to explain "all clear" / open the switcher.
    static func computeIdleDots(terminals: [OpenTerminal], projects: [Project]) -> [HUDDot] {
        let projectsById = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var dots: [HUDDot] = []
        for terminal in terminals.sorted(by: { $0.projectId < $1.projectId }) {
            guard !seen.contains(terminal.projectId) else { continue }
            seen.insert(terminal.projectId)
            let project = projectsById[terminal.projectId]
            let colorName = project?.worktrees.first { $0.id == terminal.worktreeId }?.colorName
                ?? project?.colorName
            dots.append(HUDDot(id: terminal.projectId, color: RepoColor.nsColor(for: colorName), active: false))
        }
        return dots
    }

    func activate(_ item: NeedsYouItem) { onActivate?(item) }

    /// One-tap merge from the row's Merge button. Marks the row as merging so the
    /// UI reflects it immediately; the host clears it when the PR poll refreshes
    /// (a merged PR drops out of the queue).
    func requestMerge(_ item: NeedsYouItem) {
        guard !checkingItemIDs.contains(item.id), !mergingItemIDs.contains(item.id) else { return }
        checkingItemIDs.insert(item.id)
        onMerge?(item)
    }

    func openPR(_ item: NeedsYouItem) { onOpenPR?(item) }

    /// Clear a row's merging state (a merge failed and the user may retry).
    func mergeFinished(_ item: NeedsYouItem) {
        checkingItemIDs.remove(item.id)
        mergingItemIDs.remove(item.id)
    }

    func updatePanelRowFrame(itemID: String, frame: CGRect) {
        panelRowFramesByID[itemID] = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    func updatePanelMergeButtonFrame(itemID: String, frame: CGRect) {
        panelMergeButtonFramesByID[itemID] = NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
    }

    /// AppKit-level click routing for the borderless notch panel.
    ///
    /// The visual source of truth stays in SwiftUI, but the interactive host is a
    /// top-level borderless `NSPanel`. In that host, AppKit can deliver mouse
    /// down/up to the `NSHostingView` while SwiftUI row gestures never fire. This
    /// is the exact regression the signed `--notch-click-test` guards: the panel
    /// is hit-testable and first-mouse is accepted, yet PR row/Merge callbacks
    /// remain at zero. Route only the stable, visible affordances here so a real
    /// click never dies in the bridge layer.
    func shouldHandlePanelClick(at point: NSPoint, in bounds: NSRect) -> Bool {
        panelClickTarget(at: point, in: bounds) != nil
    }

    @discardableResult
    func handlePanelClick(at point: NSPoint, in bounds: NSRect) -> Bool {
        handlePanelClick(from: point, to: point, in: bounds)
    }

    @discardableResult
    func handlePanelClick(from downPoint: NSPoint, to upPoint: NSPoint, in bounds: NSRect) -> Bool {
        guard let downTarget = panelClickTarget(at: downPoint, in: bounds),
              panelClickTarget(at: upPoint, in: bounds) == downTarget
        else { return false }

        return performPanelClickTarget(downTarget)
    }

    private func performPanelClickTarget(_ target: PanelClickTarget) -> Bool {
        switch target {
        case .collapsed:
            expanded = true
            return true
        case .header(.openSwitcher):
            onOpenSwitcher?()
            return true
        case .header(.collapse):
            collapseNow()
            return true
        case .item(let id, let inMergeButton):
            guard let item = items.first(where: { $0.id == id }) else { return false }
            if inMergeButton, item.primaryAction == .mergePR {
                requestMerge(item)
            } else if item.primaryAction == .mergePR || item.primaryAction == .openPR {
                openPR(item)
            } else {
                activate(item)
                collapseNow()
            }
            return true
        case .emptyAddProject:
            collapseNow()
            onAddProject?()
            return true
        }
    }

    func updateRenderedSurfaceSize(_ size: CGSize) {
        let rounded = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard renderedSurfaceSize != rounded else { return }
        renderedSurfaceSize = rounded
        onRenderedSurfaceSize?(rounded)
    }

    // MARK: Hover / collapse intent
    //
    // The node is ambient, so it should open the way macOS menu-bar extras and
    // Dynamic-Island-style HUDs do: hovering reveals detail, leaving hides it,
    // and acting on a row dismisses it. Click still works (see the view) for
    // trackpad taps, but hover is the primary, lower-friction path the owner asked
    // for. A short close delay keeps the card from flickering as the pointer
    // crosses between rows.

    /// Hover entered/exited the node. Enter expands immediately (when there's
    /// anything to show); exit schedules a collapse that a quick re-entry cancels.
    func hoverChanged(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        hovered = inside
        collapseToken += 1
        if inside {
            // No `withAnimation` here: the view owns a single `.animation` keyed
            // on `expanded`, so motion has one source and one clock.
            expanded = true
        } else {
            let token = collapseToken
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 260_000_000)
                guard token == self.collapseToken else { return }
                self.expanded = false
            }
        }
    }

    /// Collapse now (a row was activated, or a click landed outside the node).
    func collapseNow() {
        hovering = false
        hovered = false
        collapseToken += 1
        expanded = false
    }

    /// Diagnostic only (`--notch-shot`/`--notch-live`): inject sample items so the
    /// HUD can be previewed headlessly. Not used in normal runs, where `rebuild()`
    /// owns items.
    func seedForPreview(_ sample: [NeedsYouItem], arriving: Set<String> = []) {
        // Stop live AppModel publishers from immediately rebuilding back to the
        // user's real state while a diagnostic/test is trying to hold sample data.
        cancellables.removeAll()
        items = sample
        arrivingItemIDs = arriving
        arrivalBaselineEstablished = true
        hasProjects = true
        revision += 1
        idleDots = sample.map { HUDDot(id: $0.projectName, color: $0.color, active: false) }
        prunePanelClickFrames()
    }

    /// Diagnostic only (`--notch-empty`): force the first-run / no-repo state so
    /// the empty-state node can be previewed headlessly. A plain `init()` reads
    /// the user's real `AppModel.shared.projects`, which is usually non-empty, so
    /// it would render "All clear" instead. Detaching the live publishers (as in
    /// `seedForPreview`) keeps `rebuild()` from snapping back to real state.
    func seedEmptyForPreview() {
        cancellables.removeAll()
        items = []
        idleDots = []
        arrivingItemIDs = []
        arrivalBaselineEstablished = true
        hasProjects = false
        panelRowFramesByID = [:]
        panelMergeButtonFramesByID = [:]
        revision += 1
    }

    private func rebuild() {
        let model = AppModel.shared
        let next = model.needsYouItems
        let nextIdleDots = Self.computeIdleDots(terminals: model.visibleOpenTerminals, projects: model.visibleProjects)
        let arrivals = Self.prArrivalIDs(
            previous: items,
            next: next,
            baselineEstablished: arrivalBaselineEstablished
        )
        let visibilityChanged = (next.isEmpty && nextIdleDots.isEmpty) != (items.isEmpty && idleDots.isEmpty)
            || next != items
            || nextIdleDots != idleDots
        items = next
        idleDots = nextIdleDots
        hasProjects = !model.projects.isEmpty
        arrivalBaselineEstablished = true
        arrivingItemIDs = arrivingItemIDs.intersection(Set(next.map(\.id)))
        // A merged PR drops out of `next`; pruning here clears its "Merging…".
        mergingItemIDs = mergingItemIDs.intersection(Set(next.map(\.id)))
        checkingItemIDs = checkingItemIDs.intersection(Set(next.map(\.id)))
        prunePanelClickFrames()
        if visibilityChanged { revision += 1 }
        if !arrivals.isEmpty { markPRArrivals(arrivals) }
        if visibilityChanged { onItemsChanged?() }
    }

    private func prunePanelClickFrames() {
        let ids = Set(items.map(\.id))
        panelRowFramesByID = panelRowFramesByID.filter { ids.contains($0.key) }
        panelMergeButtonFramesByID = panelMergeButtonFramesByID.filter { ids.contains($0.key) }
    }

    private func markPRArrivals(_ ids: Set<String>) {
        withAnimation(.snappy(duration: 0.18, extraBounce: 0)) {
            arrivingItemIDs.formUnion(ids)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            withAnimation(.smooth(duration: 0.45, extraBounce: 0)) {
                self.arrivingItemIDs.subtract(ids)
            }
        }
    }

    private enum HeaderClickAction {
        case openSwitcher
        case collapse
    }

    private enum PanelClickTarget: Equatable {
        case collapsed
        case header(HeaderClickAction)
        case item(id: String, inMergeButton: Bool)
        case emptyAddProject
    }

    private struct ItemClickHit {
        let item: NeedsYouItem
        let inMergeButton: Bool
    }

    private func panelClickTarget(at point: NSPoint, in bounds: NSRect) -> PanelClickTarget? {
        guard bounds.contains(point) else { return nil }
        guard expanded else { return .collapsed }
        if let headerAction = headerAction(at: point, in: bounds) { return .header(headerAction) }
        if let hit = itemHit(at: point, in: bounds) {
            return .item(id: hit.item.id, inMergeButton: hit.inMergeButton)
        }
        if !hasProjects, point.y > Self.expandedHeaderHeight { return .emptyAddProject }
        return nil
    }

    private func headerAction(at point: NSPoint, in bounds: NSRect) -> HeaderClickAction? {
        guard point.y <= Self.expandedHeaderHeight else { return nil }
        if hasProjects, point.x >= bounds.width - 88, point.x < bounds.width - 46 { return .openSwitcher }
        if point.x >= bounds.width - 46 { return .collapse }
        return nil
    }

    private func itemHit(at point: NSPoint, in bounds: NSRect) -> ItemClickHit? {
        guard !items.isEmpty else { return nil }
        let visibleItems = Array(items.prefix(Self.panelClickMaxRows))
        for item in visibleItems {
            guard let rowFrame = panelRowFramesByID[item.id], rowFrame.width > 1, rowFrame.height > 1 else { continue }
            guard rowFrame.contains(point) else { continue }
            return ItemClickHit(
                item: item,
                inMergeButton: panelMergeButtonFramesByID[item.id]?.contains(point) == true
            )
        }
        return nil
    }
}

struct NotchHUDView: View {
    @ObservedObject var model: NotchHUDModel
    var reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private static let clickCoordinateSpace = "notchHUDSurface"

    private let maxDots = 5
    private let maxRows = 3
    @State private var hotItemID: String?

    /// One animation curve drives the visible morph — collapsed↔expanded, width,
    /// height, and corner radius all interpolate from SwiftUI state.
    private var morph: Animation {
        reducedMotion ? .easeOut(duration: 0.12) : .interpolatingSpring(duration: 0.34, bounce: 0.14)
    }

    private var isExpanded: Bool { model.expanded }
    private var arrivalActive: Bool { model.items.contains { model.arrivingItemIDs.contains($0.id) } }
    private var surfaceHovered: Bool { model.hovered }

    var body: some View {
        surface
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityLabel)
    }

    private var surface: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                header
                detail
                    .transition(.opacity)
            } else {
                restingNub
                    .transition(.opacity)
            }
        }
        // Hug the content on both axes. The AppKit panel is slaved to this
        // reported size with `animate: false`, leaving SwiftUI as the only
        // animation clock.
        .fixedSize()
        .background(container)
        .background(sizeReporter)
        .overlay(containerStroke)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(
            color: .black.opacity(isExpanded ? 0.42 : (surfaceHovered ? 0.28 : 0.22)),
            radius: isExpanded ? 18 : (surfaceHovered ? 10 : 7),
            x: 0,
            y: isExpanded ? 10 : 4
        )
        .animation(morph, value: model.expanded)
        .animation(morph, value: model.revision)
        .animation(.smooth(duration: 0.5), value: arrivalActive)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .coordinateSpace(name: Self.clickCoordinateSpace)
    }

    // MARK: Resting nub — the austere at-rest tab (WhisperFlow-minimal).

    /// At rest the node is a tiny, quiet tab — never a sentence. It carries only
    /// the ambient signal: neutral when idle, the project color-dot(s) when a
    /// project needs you (and it breathes). Every word — project, PR number,
    /// status, actions — is reserved for the hover-expanded card. This is the
    /// whole point of the WhisperFlow language: silent until you approach it.
    @ViewBuilder
    private var restingNub: some View {
        Group {
            if model.hasItems {
                HStack(spacing: 5) {
                    ForEach(model.items.prefix(maxDots)) { item in
                        Circle()
                            .fill(Color(nsColor: item.color))
                            .frame(width: 6, height: 6)
                    }
                }
            } else if model.hasProjects {
                HStack(spacing: 6) {
                    if model.idleDots.isEmpty {
                        Image(systemName: "square.grid.2x2.fill")
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.64))
                    } else {
                        ForEach(model.idleDots.prefix(maxDots)) { dot in
                            Circle()
                                .fill(Color(nsColor: dot.color))
                                .frame(width: 6, height: 6)
                        }
                    }
                    Capsule()
                        .fill(.white.opacity(0.46))
                        .frame(width: 18, height: 4)
                }
            } else {
                Image(systemName: "plus")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(minWidth: 46)
        .padding(.horizontal, 13)
        .frame(height: 16)
        .contentShape(Capsule())
        .onTapGesture { model.expanded = true }
    }

    // MARK: Header — the expanded card's top row.

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            leadingCluster
            Spacer(minLength: 8)
            trailingCluster
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .padding(.top, isExpanded ? 3 : 0)
    }

    @ViewBuilder
    private var leadingCluster: some View {
        if isExpanded {
            Text(titleText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Self.secondaryText)
                .lineLimit(1)
                .transition(.opacity)
        } else if let first = model.items.first {
            statusDot(first.color)
            Image(systemName: first.reason.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(reasonTint(first.reason, base: first.color))
            Text(first.collapsedTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .leading)
                .foregroundStyle(.primary)
            if model.items.count > 1 {
                Text("+\(model.items.count - 1)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        } else if model.hasProjects {
            ForEach(model.idleDots.prefix(maxDots)) { dot in
                statusDot(dot.color, size: 7)
            }
            Text("All clear")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Set up Juggle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.primary)
        }
    }

    @ViewBuilder
    private var trailingCluster: some View {
        if isExpanded {
            HStack(spacing: 10) {
                if model.hasProjects {
                    headerButton("magnifyingglass", help: "Jump to a terminal (⌘J)") { model.onOpenSwitcher?() }
                }
                headerButton("xmark", help: "Collapse") { model.collapseNow() }
            }
            .transition(.opacity)
        } else if !model.hasProjects {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Detail — revealed below the header on expand.

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.075))
                .frame(height: 1)
            if model.hasItems {
                itemRows
            } else if model.hasProjects {
                allClearDetail
            } else {
                emptyStateDetail
            }
        }
        .frame(width: model.hasProjects ? 392 : 320)
    }

    private var itemRows: some View {
        VStack(spacing: 3) {
            ForEach(model.items.prefix(maxRows)) { item in
                // The row isn't one big Button anymore: a PR row carries its own
                // Merge button, so the body uses a tap gesture (tapping a PR opens
                // it on GitHub; tapping an agent row jumps to its terminal).
                row(item)
            }
            if model.items.count > maxRows {
                Text("+\(model.items.count - maxRows) more")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
        .padding(.vertical, 6)
    }

    private var allClearDetail: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.primaryText)
                Text("No PRs ready and no agents waiting.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Self.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
    }

    /// First-run / no-repo node. This is the answer to "I opened the app and
    /// nothing happened": the node is always visible and, with no projects, it
    /// teaches the one action that matters.
    private var emptyStateDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No project is open. Choose a folder or git repository.")
                .font(.system(size: 11))
                .foregroundStyle(Self.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.collapseNow()
                model.onAddProject?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text("Open Project...")
                }
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Capsule().fill(.white.opacity(0.14)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    // MARK: Geometry + chrome

    private var cornerRadius: CGFloat { isExpanded ? 17 : 8 }

    private var titleText: String {
        if model.hasItems { return "Juggle needs you" }
        if model.hasProjects { return "All clear" }
        return "Set up Juggle"
    }

    private var accessibilityLabel: String {
        if model.hasItems { return "Juggle needs you" }
        if model.hasProjects { return "Juggle, all clear" }
        return "Juggle, add a project"
    }

    private func statusDot(_ color: NSColor, size: CGFloat = 8) -> some View {
        Circle().fill(Color(nsColor: color)).frame(width: size, height: size)
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Self.iconText)
        .help(help)
    }

    private var sizeReporter: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size, initial: true) { _, newSize in
                    model.updateRenderedSurfaceSize(newSize)
                }
        }
    }

    private var container: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isExpanded ? Self.expandedFill : Self.collapsedFill)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isExpanded ? 0.018 : 0.045))
            )
    }

    private var containerStroke: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(isExpanded ? 0.105 : 0.16), lineWidth: 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(leadingTint.opacity(arrivalActive ? 0.08 : 0), lineWidth: 1)
            )
    }

    private static let expandedFill = Color(nsColor: NSColor(calibratedWhite: 0.052, alpha: 1))
    private static let collapsedFill = Color(nsColor: NSColor(calibratedWhite: 0.30, alpha: 1))
    private static let primaryText = Color.white.opacity(0.92)
    private static let secondaryText = Color.white.opacity(0.62)
    private static let tertiaryText = Color.white.opacity(0.38)
    private static let iconText = Color.white.opacity(0.58)

    /// PR rows get a real Merge button (one-tap, no blocking dialog); agent rows
    /// keep the jump affordance. While merging, the button becomes a quiet label.
    @ViewBuilder
    private func rowTrailing(_ item: NeedsYouItem, highlighted: Bool) -> some View {
        let accent = Color(nsColor: item.color)
        if item.primaryAction == .mergePR {
            if model.checkingItemIDs.contains(item.id) {
                Text("Checking…")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Self.secondaryText)
            } else if model.mergingItemIDs.contains(item.id) {
                Text("Merging…")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Self.secondaryText)
            } else {
                Text("Merge")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(Capsule().fill(accent.opacity(highlighted ? 0.22 : 0.16)))
                    .overlay(Capsule().strokeBorder(accent.opacity(highlighted ? 0.62 : 0.42), lineWidth: 1))
                    .foregroundStyle(accent)
                    .contentShape(Capsule())
                    .onTapGesture { model.requestMerge(item) }
                    .help("Merge this PR (gh pr merge --squash)")
                    .background(panelClickFrameReporter(itemID: item.id, kind: .mergeButton))
            }
        } else {
            Image(systemName: actionSymbol(item.primaryAction))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(highlighted ? accent : Self.iconText)
        }
    }

    private func row(_ item: NeedsYouItem) -> some View {
        let isHot = hotItemID == item.id
        let isArriving = model.arrivingItemIDs.contains(item.id)
        let highlighted = isHot || isArriving
        return HStack(spacing: 9) {
            HStack(spacing: 9) {
                Circle().fill(Color(nsColor: item.color)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.projectName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Self.primaryText)
                            .lineLimit(1).truncationMode(.middle)
                        Text(item.reason.label)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(reasonTint(item.reason, base: item.color))
                    }
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Self.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let meta = item.meta, !meta.isEmpty {
                        HStack(spacing: 8) {
                            Text(metaBranch(meta))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Self.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 6)
                            if let diff = metaDiff(meta) {
                                Text(diff)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Self.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { activateRowBody(item) }
            Spacer(minLength: 8)
            rowTrailing(item, highlighted: highlighted)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(highlighted ? 0.092 : 0.052))
                .padding(.horizontal, 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: item.color).opacity(highlighted ? 0.18 : 0))
                .padding(.horizontal, 6)
        )
        .scaleEffect(highlighted && !reducedMotion ? 1.012 : 1, anchor: .center)
        .animation(.snappy(duration: 0.16, extraBounce: 0), value: highlighted)
        .onContinuousHover { phase in
            switch phase {
            case .active: hotItemID = item.id
            case .ended: if hotItemID == item.id { hotItemID = nil }
            }
        }
        .background(panelClickFrameReporter(itemID: item.id, kind: .row))
    }

    private enum PanelClickFrameKind {
        case row
        case mergeButton
    }

    private func panelClickFrameReporter(itemID: String, kind: PanelClickFrameKind) -> some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.frame(in: .named(Self.clickCoordinateSpace)), initial: true) { _, frame in
                    switch kind {
                    case .row:
                        model.updatePanelRowFrame(itemID: itemID, frame: frame)
                    case .mergeButton:
                        model.updatePanelMergeButtonFrame(itemID: itemID, frame: frame)
                    }
                }
        }
    }

    /// Error earns the restrained warning tint; everything else stays in hue.
    private func reasonTint(_ reason: HUDReason, base: NSColor) -> Color {
        reason == .error ? Color(nsColor: .systemRed) : Color(nsColor: base)
    }

    private func actionSymbol(_ action: NeedsYouPrimaryAction) -> String {
        switch action {
        case .mergePR: return "arrow.triangle.merge"
        case .openPR: return "safari"
        case .jumpToTerminal: return "arrow.right.circle"
        }
    }

    private func activateRowBody(_ item: NeedsYouItem) {
        if item.primaryAction == .mergePR || item.primaryAction == .openPR {
            model.openPR(item)
        } else {
            model.activate(item)
            model.collapseNow()
        }
    }

    private func metaBranch(_ meta: String) -> String {
        let parts = meta.components(separatedBy: " · ")
        guard parts.count > 1, parts.last?.hasPrefix("+") == true else { return meta }
        return parts.dropLast().joined(separator: " · ")
    }

    private func metaDiff(_ meta: String) -> String? {
        let parts = meta.components(separatedBy: " · ")
        guard let last = parts.last, last.hasPrefix("+") else { return nil }
        return last
    }

    private var leadingTint: Color {
        Color(nsColor: model.items.first?.color ?? .white)
    }
}

/// A borderless panel pinned under the menu bar / notch. It can become key when
/// the user clicks a control; otherwise it passively floats above normal windows.
/// Its frame is slaved to the SwiftUI surface size with no AppKit animation, so
/// SwiftUI remains the only animation clock.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view for the notch panel that accepts the *first* mouse click.
///
/// The notch lives in a borderless panel and owns a tracking area over its
/// current bounds; the panel bounds match the visible SwiftUI surface.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    var shouldHandlePanelClick: ((NSPoint, NSRect) -> Bool)?
    var handlePanelClick: ((NSPoint, NSPoint, NSRect) -> Bool)?
    private var hoverTrackingArea: NSTrackingArea?
    private var pendingPanelClick: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if shouldHandlePanelClick?(point, bounds) == true {
            pendingPanelClick = point
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let downPoint = pendingPanelClick {
            let upPoint = convert(event.locationInWindow, from: nil)
            pendingPanelClick = nil
            _ = handlePanelClick?(downPoint, upPoint, bounds)
            return
        }
        super.mouseUp(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTrackingArea()
    }

    func refreshTrackingArea() {
        if let existing = hoverTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
