import AppKit
import SwiftUI

// MARK: - Theme

/// The mockup's exact colour ramp as SwiftUI `Color`s, so the in-app flow lives
/// in the same colour-on-dark identity as the rest of Juggle. `accent(named:)`
/// resolves against the shared `RepoColor.palette` — no parallel palette.
enum Onb {
    static let window = Color(nsColor: NSColor(hex: "#0e0e12") ?? .windowBackgroundColor)
    static let primary = Color(nsColor: NSColor(hex: "#f4f4f6") ?? .textColor)
    static let muted = Color(nsColor: NSColor(hex: "#9a9aa6") ?? .secondaryLabelColor)
    static let tertiary = Color(nsColor: NSColor(hex: "#6a6a76") ?? .tertiaryLabelColor)
    static let line = Color.white.opacity(0.08)
    static let onButton = Color(nsColor: NSColor(hex: "#06121a") ?? .black)

    static func accent(named name: String) -> Color {
        Color(nsColor: RepoColor.named(name)?.nsColor ?? RepoColor.palette[0].nsColor)
    }

    /// Mirror `CABreathingRenderer`: under Reduce Motion the accent holds instead
    /// of animating. Read straight from the system like the window controller.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

private extension View {
    /// A 1px bottom hairline — the mockup's `border-bottom` per panel row.
    func bottomRule() -> some View {
        overlay(Rectangle().fill(Onb.line).frame(height: 1), alignment: .bottom)
    }
    /// Wrap any chip content in the panel's pill capsule.
    var asChip: some View {
        self
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Onb.line))
            .fixedSize()
    }
}

// MARK: - The real Juggle icon (never a placeholder)

/// Loads the real app icon. At runtime in a bundled `.app`,
/// `NSApp.applicationIconImage` carries it; under `swift run` (no bundle) that
/// returns the generic icon, so we fall back to the repo's `Packaging/` asset.
enum AppIconSource {
    static func load() -> NSImage? {
        if let icon = NSApp.applicationIconImage,
           icon.isValid, icon.representations.isEmpty == false {
            return icon
        }
        for relative in ["Packaging/AppIcon.icns", "Packaging/icon-source.png"] {
            if FileManager.default.fileExists(atPath: relative),
               let image = NSImage(contentsOf: URL(fileURLWithPath: relative)) {
                return image
            }
        }
        return nil
    }
}

// MARK: - Shared building blocks

/// The signature attention behaviour, lifted from `CABreathingRenderer`:
/// 1.1s ease-in-out, opacity 1.0 ↔ 0.32, autoreversing forever. Reduce Motion
/// degrades to a held-full accent, exactly like the live terminal accent line.
struct Breathing: ViewModifier {
    let reduceMotion: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(reduceMotion ? 1.0 : (dim ? 0.32 : 1.0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

extension View {
    func breathing(reduceMotion: Bool) -> some View { modifier(Breathing(reduceMotion: reduceMotion)) }
}

/// A skeleton mini terminal window: traffic-light dots, a name, an accent line
/// (which breathes when its agent needs you), and skeleton content lines.
struct MiniWindow: View {
    let name: String
    let accent: Color
    var breathes: Bool = false
    var compact: Bool = false
    var reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 7, height: 7)
                }
                if !name.isEmpty {
                    Text(name).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9)).padding(.leading, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(accent.opacity(0.26))

            accent
                .frame(height: 3)
                .breathing(reduceMotion: breathes ? reduceMotion : true)   // only its own window breathes

            skeleton
        }
        .background(Color(nsColor: NSColor(hex: "#0c0c10") ?? .black))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Onb.line))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var skeleton: some View {
        let widths: [CGFloat] = compact ? [0.7] : [0.70, 0.45, 0.58]
        return GeometryReader { geo in
            VStack(alignment: .leading, spacing: 5) {
                ForEach(widths, id: \.self) { fraction in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.10))
                        .frame(width: max(4, geo.size.width * fraction - 16), height: 4)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .frame(height: compact ? 30 : 54)
    }
}

struct Swatch: View {
    let color: Color
    var size: CGFloat = 15
    var body: some View {
        RoundedRectangle(cornerRadius: 5).fill(color).frame(width: size, height: size)
    }
}

struct StatusChip: View {
    let label: String
    let dot: Color?
    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(Onb.muted)
        .asChip
    }
}

struct KeyCap: View {
    let glyph: String
    var body: some View {
        Text(glyph)
            .font(.system(size: 24, weight: .semibold))
            .frame(width: 64, height: 64)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: NSColor(hex: "#16161c") ?? .black)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Onb.line))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
    }
}

/// A `gridColumns` × `gridRows` cell grid with the top-left `activeColumns ×
/// activeRows` block lit in the accent — the mockup's tiling indicator.
struct GridCells: View {
    let gridColumns: Int
    let gridRows: Int
    let activeColumns: Int
    let activeRows: Int
    let width: CGFloat
    let cellHeight: CGFloat
    let accent: Color

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<gridRows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(0..<gridColumns, id: \.self) { col in
                        RoundedRectangle(cornerRadius: 2)
                            .fill((col < activeColumns && row < activeRows) ? accent : Color.white.opacity(0.12))
                            .frame(height: cellHeight)
                    }
                }
            }
        }
        .frame(width: width)
    }
}

// MARK: - Per-step previews

/// Core — six colour-coded windows, one breathing because its agent needs you.
struct CorePreview: View {
    let reduceMotion: Bool
    private let names = ["api", "web", "infra", "docs", "cli", "app"]
    private let hues = ["Teal", "Coral", "Iris", "Lime", "Amber", "Violet"]

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                MiniWindow(name: name, accent: Onb.accent(named: hues[index]),
                           breathes: index == 4, reduceMotion: reduceMotion)
            }
        }
        .frame(maxWidth: 420)
    }
}

/// Control — the menu-bar cockpit (project ▸ worktrees ▸ grid), never over terminals.
struct ControlPreview: View {
    let reduceMotion: Bool
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Spacer()
                Text("9:41").font(.system(size: 12)).foregroundStyle(Onb.tertiary)
                let accent = Onb.accent(named: "Iris")
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(accent.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .overlay(Text("⠿").font(.system(size: 11)).foregroundStyle(accent))
            }
            .frame(width: 300)

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Swatch(color: Onb.accent(named: "Iris"))
                    Text("juggle").font(.system(size: 13, weight: .semibold)).foregroundStyle(Onb.primary)
                    Spacer()
                    Text("~/Documents").font(.system(size: 10, design: .monospaced)).foregroundStyle(Onb.tertiary)
                }
                .padding(.horizontal, 13).padding(.vertical, 11)
                .bottomRule()

                worktree(swatch: Onb.accent(named: "Mint"), name: "main") {
                    StatusChip(label: "Terminal", dot: nil)
                }
                worktree(swatch: Onb.accent(named: "Amber"), name: "feat/auth") {
                    HStack(spacing: 5) {
                        Text("#171").font(.system(size: 10, weight: .semibold))
                        Text("+65").font(.system(size: 10)).foregroundStyle(Onb.accent(named: "Lime"))
                        Circle().fill(Onb.accent(named: "Amber")).frame(width: 6, height: 6)
                    }.asChip
                }
                .bottomRule()

                gridBar
            }
            .background(Color(nsColor: NSColor(hex: "#101015") ?? .black))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Onb.line))
            .clipShape(RoundedRectangle(cornerRadius: 13))
        }
        .frame(width: 300)
    }

    private func worktree(swatch: Color, name: String, chip: () -> some View) -> some View {
        HStack(spacing: 8) {
            Swatch(color: swatch, size: 11)
            Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Onb.muted)
            Spacer()
            chip()
        }
        .padding(.leading, 30).padding(.trailing, 13).padding(.vertical, 8)
    }

    private var gridBar: some View {
        HStack(spacing: 10) {
            Text("GRID").font(.system(size: 11, weight: .semibold)).kerning(0.5).foregroundStyle(Onb.tertiary)
            GridCells(gridColumns: 5, gridRows: 4, activeColumns: 3, activeRows: 2,
                      width: 96, cellHeight: 9, accent: Onb.accent(named: "Iris"))
            Text("3×2").font(.system(size: 11)).foregroundStyle(Onb.muted)
            Spacer()
            Text("Tile").font(.system(size: 11)).foregroundStyle(Onb.muted)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Onb.line))
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
    }
}

/// Identity — a hue per project, a shade per worktree; the one that needs you breathes.
struct IdentityPreview: View {
    let reduceMotion: Bool
    var body: some View {
        VStack(spacing: 22) {
            HStack(spacing: 9) {
                ForEach(RepoColor.palette, id: \.name) { color in
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: color.nsColor))
                        .frame(width: 26, height: 26)
                }
            }

            HStack(spacing: 16) {
                MiniWindow(name: "payments", accent: Onb.accent(named: "Rose"),
                           breathes: true, reduceMotion: reduceMotion)
                    .frame(width: 150)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Circle().fill(Onb.accent(named: "Rose"))
                            .frame(width: 7, height: 7)
                            .breathing(reduceMotion: reduceMotion)
                            .shadow(color: Onb.accent(named: "Rose").opacity(0.8), radius: 8)
                        Text("needs you").font(.system(size: 13, weight: .semibold)).foregroundStyle(Onb.primary)
                    }
                    Text("click its row → jump straight to the cursor")
                        .font(.system(size: 12.5)).foregroundStyle(Onb.muted)
                        .frame(maxWidth: 150, alignment: .leading)
                }
            }
        }
    }
}

/// Layout — snap into a grid; the lit cells show today's 3×2 tiling.
struct LayoutPreview: View {
    let reduceMotion: Bool
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 14) {
                GridCells(gridColumns: 5, gridRows: 4, activeColumns: 3, activeRows: 2,
                          width: 150, cellHeight: 15, accent: Onb.accent(named: "Lime"))
                Text("3 × 2").font(.system(size: 22, weight: .semibold)).foregroundStyle(Onb.primary)
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(["Teal", "Coral", "Iris", "Lime", "Amber", "Violet"], id: \.self) { hue in
                    MiniWindow(name: "", accent: Onb.accent(named: hue), compact: true, reduceMotion: reduceMotion)
                }
            }
            .frame(width: 280)
        }
        .frame(maxWidth: 360)
    }
}

/// Git — branch, diff and PR status per window; open a draft PR / merge from the panel.
struct GitPreview: View {
    let reduceMotion: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Swatch(color: Onb.accent(named: "Amber"))
                Text("payments").font(.system(size: 13, weight: .semibold)).foregroundStyle(Onb.primary)
                Spacer()
                Text("~/Desktop").font(.system(size: 10, design: .monospaced)).foregroundStyle(Onb.tertiary)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .bottomRule()

            worktree(swatch: Onb.accent(named: "Mint"), name: "main") {
                StatusChip(label: "Terminal", dot: nil)
            }
            worktree(swatch: Onb.accent(named: "Lime"), name: "feat/checkout") {
                HStack(spacing: 5) {
                    Text("⌥").font(.system(size: 10))
                    Text("#171").font(.system(size: 10, weight: .semibold)).foregroundStyle(Onb.primary)
                    Text("+65").font(.system(size: 10)).foregroundStyle(Onb.accent(named: "Lime"))
                    Text("−3").font(.system(size: 10)).foregroundStyle(Onb.accent(named: "Rose"))
                    Circle().fill(Onb.accent(named: "Lime")).frame(width: 6, height: 6)
                    Text("Merge").font(.system(size: 10))
                }.asChip
            }
            worktree(swatch: Onb.accent(named: "Sky"), name: "fix/race") {
                HStack(spacing: 5) {
                    Text("#158").font(.system(size: 10, weight: .semibold))
                    Circle().fill(Onb.accent(named: "Amber")).frame(width: 6, height: 6)
                    Text("Behind").font(.system(size: 10))
                }.asChip
            }
            .bottomRule()

            Text("Open draft PR · Merge — straight from the panel")
                .font(.system(size: 12)).foregroundStyle(Onb.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 13).padding(.vertical, 11)
        }
        .background(Color(nsColor: NSColor(hex: "#101015") ?? .black))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Onb.line))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .frame(width: 340)
    }

    private func worktree(swatch: Color, name: String, chip: () -> some View) -> some View {
        HStack(spacing: 8) {
            Swatch(color: swatch, size: 11)
            Text(name).font(.system(size: 11, design: .monospaced)).foregroundStyle(Onb.muted)
            Spacer()
            chip()
        }
        .padding(.leading, 30).padding(.trailing, 13).padding(.vertical, 8)
    }
}

// MARK: - Permissions preview (the one wired to live state)

/// Two grants. Files & folders is explained (macOS asks once on the first project
/// — a non-sandboxed app can't summon TCC on demand, so we never fake a dialog).
/// GitHub CLI is smart-detected live from `gh auth status`.
struct PermissionsPreview: View {
    let ghAuth: GhAuthState?
    let accent: Color
    let onSignIn: () -> Void
    let onInstall: () -> Void
    let onMarkSignedIn: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            row(icon: "folder", tint: accent, title: "Files & folders",
                desc: "macOS asks once when you open your first project folder — that's how Juggle runs git inside it.",
                trailing: trailingInfo("On first project"))
            .bottomRule()

            row(icon: "terminal.fill", tint: Onb.tertiary, title: "GitHub CLI",
                desc: ghDesc, trailing: ghTrailing)

            if needsGhAction {
                Button("I'm already signed in", action: onMarkSignedIn)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(Onb.muted)
                    .padding(.top, 12)
            }
        }
        .frame(width: 400)
    }

    private var needsGhAction: Bool { ghAuth == .notSignedIn || ghAuth == .notInstalled }

    private var ghDesc: String {
        switch ghAuth {
        case .signedIn(let name):
            return name.map { "Signed in as \($0) — PR & merge buttons ready." }
                       ?? "Marked as signed in — PR & merge buttons ready."
        case .notSignedIn: return "Connect gh for one-click PRs and merges, straight from the panel."
        case .notInstalled: return "Install the GitHub CLI for one-click PRs and merges."
        case nil: return "Checking whether the GitHub CLI is available…"
        }
    }

    @ViewBuilder private var ghTrailing: some View {
        switch ghAuth {
        case .signedIn(let name):
            badge("✓ Signed in" + (name.map { " as @" + $0 } ?? ""), tint: Onb.accent(named: "Mint"))
        case .notSignedIn:
            button("Sign in", action: onSignIn)
        case .notInstalled:
            button("Install", action: onInstall)
        case nil:
            ProgressView().controlSize(.small).frame(height: 16)
        }
    }

    private func row(icon: String, tint: Color, title: String, desc: String, trailing: some View) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Onb.primary)
                Text(desc).font(.system(size: 12.5)).foregroundStyle(Onb.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 16).padding(.horizontal, 4)
    }

    private func trailingInfo(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Onb.muted)
    }
    private func badge(_ text: String, tint: Color) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.16)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.45)))
    }
    private func button(_ text: String, action: @escaping () -> Void) -> some View {
        Button(text, action: action)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Onb.primary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(accent.opacity(0.18)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(accent.opacity(0.5)))
            .buttonStyle(.plain)
    }
}

// MARK: - Go preview (real icon + real first-project action)

/// The takeoff: summon from anywhere with ⌘0, the real app icon, and a real
/// "add your first project" action wired to `appController()?.openProjectViaPanel()`.
struct GoPreview: View {
    let onStart: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            if let icon = AppIconSource.load() {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Onb.line))
                    .shadow(color: Onb.accent(named: "Violet").opacity(0.35), radius: 18, y: 6)
            }
            HStack(spacing: 12) {
                KeyCap(glyph: "⌘")
                KeyCap(glyph: "0")
            }
            Text("Summon Juggle from anywhere — it lives in the menu bar.")
                .font(.system(size: 13.5)).foregroundStyle(Onb.muted).multilineTextAlignment(.center)

            Button {
                onStart()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text("Add your first project")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Onb.onButton)
                .padding(.horizontal, 20).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 11).fill(Onb.accent(named: "Violet")))
            }
            .buttonStyle(.plain)
        }
    }
}
