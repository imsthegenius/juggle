import AppKit
import SwiftUI

// MARK: - Step model

/// The seven in-app steps. The mockup's frame 0 ("drag to Applications") is the
/// DMG window, not an in-app screen — so it is intentionally absent here (follow-up).
enum OnboardingStepID: String, CaseIterable, Sendable {
    case core, control, identity, layout, git, permissions, go
}

struct OnboardingStep: Identifiable {
    let id: OnboardingStepID
    let pill: String
    let title: String          // a `\n` marks the intentional line break
    let description: String
    let accentName: String     // a name in `RepoColor.palette`
    let cta: String
    let showsSkip: Bool

    /// Verbatim copy and the Teal→Iris→Rose→Lime→Amber→Sky→Violet accent ramp
    /// from `onboarding-mockup.html`, in order.
    static let all: [OnboardingStep] = [
        OnboardingStep(id: .core,        pill: "Core",
            title: "Real windows,\nnot tabs.",
            description: "Every repo and worktree gets its own native macOS window — colour-coded — so you can see everything you're juggling at a glance.",
            accentName: "Teal", cta: "Continue", showsSkip: false),
        OnboardingStep(id: .control,     pill: "Control",
            title: "Your cockpit lives\nin the menu bar.",
            description: "Click the menu-bar icon — or press ⌘0 — to expand the control panel. It never floats over your terminals: pop it open, add a project, tuck it away.",
            accentName: "Iris", cta: "Continue", showsSkip: false),
        OnboardingStep(id: .identity,    pill: "Identity",
            title: "Colour is how\nyou keep track.",
            description: "Each project is a hue; each worktree a shade. When an agent needs you, its window breathes in its colour — click its row to land on the cursor.",
            accentName: "Rose", cta: "Continue", showsSkip: false),
        OnboardingStep(id: .layout,      pill: "Layout",
            title: "Snap it all\ninto a grid.",
            description: "Tile every window into 2×2, 3×2, 4×3 — whatever fits your displays. Drag a window to snap it into place. ⌘⌥G re-tiles.",
            accentName: "Lime", cta: "Continue", showsSkip: false),
        OnboardingStep(id: .git,         pill: "Git",
            title: "Worktrees and PRs,\nbuilt in.",
            description: "Every window shows its branch, diff and PR status. Open a draft PR or merge — right from the panel, no context-switch.",
            accentName: "Amber", cta: "Continue", showsSkip: false),
        OnboardingStep(id: .permissions, pill: "Permissions",
            title: "Two quick grants\nand you're ready.",
            description: "Let Juggle into your project folders, and connect the GitHub CLI for one-click PRs. Skip either and set it up later.",
            accentName: "Sky", cta: "Continue", showsSkip: true),
        OnboardingStep(id: .go,          pill: "Go",
            title: "Ready to juggle?",
            description: "Press ⌘0 anytime to summon Juggle. Add your first project and your first colour-coded window opens.",
            accentName: "Violet", cta: "Start juggling", showsSkip: false),
    ]
}

// MARK: - State + side effects

/// App-level actions the onboarding buttons trigger. Hosted by `AppDelegate`
/// (which owns real app hooks), passed in so the view never fakes behaviour.
struct OnboardingActions {
    var startFirstProject: () -> Void   // ⌘0's lesson: open the first project, then retire onboarding
    var signInGh: () -> Void            // open Terminal running `gh auth login`
    var installGh: () -> Void           // open https://cli.github.com
    var dismiss: () -> Void             // Escape / close: retire without opening a project
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var index: Int = 0
    @Published var ghAuth: GhAuthState? = nil      // nil = still checking

    private let steps = OnboardingStep.all
    var step: OnboardingStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }

    /// One local `gh auth status`, off-main via `ShellRunner`. Cheap (reads the
    /// keyring — no network); resolves before the user reaches step 6.
    func checkGh() async { ghAuth = await GhService.shared.authStatus() }

    /// "I'm already signed in" manual override — satisfy the row without checking.
    func markSignedIn() { ghAuth = .signedIn(username: nil) }

    func next() { guard !isLast else { return }; index += 1 }
    func back() { guard !isFirst else { return }; index -= 1 }
    func skip() { guard !isLast else { return }; index += 1 }   // permissions → go
}

// MARK: - The window content

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let actions: OnboardingActions

    @FocusState private var focused: Bool

    private var reduceMotion: Bool { Onb.reduceMotion }
    private var accent: Color { Onb.accent(named: model.step.accentName) }

    var body: some View {
        Group {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Onb.window)
                glow
                content
            }
            .frame(width: 1040, height: 650)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Onb.line))
            .frame(maxWidth: .infinity, maxHeight: .infinity)      // center the card in the window
        }
        .frame(width: 1120, height: 730)                          // == window (card + shadow margins)
        .focusable()
        .focused($focused)
        .onAppear {
            focused = true
            if model.ghAuth == nil { Task { await model.checkGh() } }
        }
        .onKeyPress(.leftArrow)  { animate { model.back() }; return .handled }
        .onKeyPress(.rightArrow) { advance(); return .handled }
        .onKeyPress(.return)     { advance(); return .handled }
        .onKeyPress(.escape)     { actions.dismiss(); return .handled }
    }

    // glow + content + previews + bottom bar …
    private var glow: some View {
        RadialGradient(
            colors: [accent.opacity(0.22), .clear],
            center: UnitPoint(x: 0.72, y: 0.40),
            startRadius: 1, endRadius: 460
        )
        .allowsHitTesting(false)
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 40) {
                leftRail
                    .frame(maxWidth: 440, alignment: .leading)
                preview
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, 48)
            .padding(.horizontal, 56)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
    }

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(model.step.pill)
                .font(.system(size: 12.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(accent.opacity(0.32)))
                .overlay(Capsule().strokeBorder(accent.opacity(0.55)))

            Text(model.step.title)
                .font(.system(size: 42, weight: .semibold))
                .kerning(-0.8)
                .lineSpacing(2)
                .foregroundStyle(Onb.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.step.description)
                .font(.system(size: 16.5))
                .lineSpacing(4)
                .foregroundStyle(Onb.muted)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var preview: some View {
        Group {
            switch model.step.id {
            case .core:        CorePreview(reduceMotion: reduceMotion)
            case .control:     ControlPreview(reduceMotion: reduceMotion)
            case .identity:    IdentityPreview(reduceMotion: reduceMotion)
            case .layout:      LayoutPreview(reduceMotion: reduceMotion)
            case .git:         GitPreview(reduceMotion: reduceMotion)
            case .permissions:
                PermissionsPreview(
                    ghAuth: model.ghAuth, accent: accent,
                    onSignIn: actions.signInGh,
                    onInstall: actions.installGh,
                    onMarkSignedIn: { model.markSignedIn() }
                )
            case .go:          GoPreview(onStart: actions.startFirstProject)
            }
        }
        .id(model.step.id)
        .transition(reduceMotion ? .identity : .opacity)
        .frame(maxHeight: .infinity)
    }

    private func animate(_ block: () -> Void) {
        if reduceMotion { block() }
        else { withAnimation(.easeInOut(duration: 0.42)) { block() } }
    }

    private func advance() {
        if model.isLast { actions.startFirstProject() }
        else { animate { model.next() } }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Button {
                animate { model.back() }
            } label: {
                Text("‹")
                    .font(.system(size: 18))
                    .foregroundStyle(Onb.muted)
                    .frame(width: 34, height: 34)
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Onb.line))
            }
            .buttonStyle(.plain)
            .disabled(model.isFirst)
            .opacity(model.isFirst ? 0.3 : 1)
            .help("Back")

            ProgressDots(count: OnboardingStep.all.count, current: model.index, accent: accent)

            Spacer()

            if model.step.showsSkip {
                Button("Skip") { animate { model.skip() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 14))
                    .foregroundStyle(Onb.muted)
                    .help("Skip this grant — set it up later")
            }

            Button(model.step.cta) { advance() }
                .buttonStyle(PrimaryCTA(tint: accent))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
        .overlay(Rectangle().fill(Onb.line).frame(height: 1), alignment: .top)
        .background(Color.black.opacity(0.22))
    }
}

// MARK: - Bottom-bar chrome

struct ProgressDots: View {
    let count: Int
    let current: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? accent : Color.white.opacity(0.14))
                    .frame(height: 4)
                    .frame(width: index == current ? 34 : 22)
            }
        }
    }
}

struct PrimaryCTA: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14.5, weight: .semibold))
            .foregroundStyle(Onb.onButton)
            .padding(.horizontal, 22).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(tint))
            .shadow(color: tint.opacity(0.4), radius: 10, y: 3)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
