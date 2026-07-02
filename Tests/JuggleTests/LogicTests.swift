import AppKit
import XCTest
@testable import Juggle

final class WorktreeParsingTests: XCTestCase {
    func testStandardTwoWorktrees() {
        let output = """
        worktree /Users/x/repo
        HEAD abc123
        branch refs/heads/main

        worktree /Users/x/repo/.worktrees/feature
        HEAD def456
        branch refs/heads/feature/new-thing

        """
        let refs = GitService.parseWorktreeList(output)
        XCTAssertEqual(refs, [
            WorktreeRef(path: "/Users/x/repo", branch: "main"),
            WorktreeRef(path: "/Users/x/repo/.worktrees/feature", branch: "feature/new-thing"),
        ])
    }

    func testDetachedHead() {
        let output = "worktree /Users/x/repo\nHEAD abc123\ndetached\n\n"
        XCTAssertEqual(GitService.parseWorktreeList(output).first?.branch, "detached")
    }

    func testTrailingEntryFlushesWithoutBlankLine() {
        let output = "worktree /Users/x/repo\nHEAD abc\nbranch refs/heads/main"
        let refs = GitService.parseWorktreeList(output)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.branch, "main")
    }

    func testEmptyOutput() {
        XCTAssertTrue(GitService.parseWorktreeList("").isEmpty)
    }
}

final class BranchListParsingTests: XCTestCase {
    func testParsesAndTrimsBranchNames() {
        let output = "main\nfeature/x\n  release/1.0  \n"
        XCTAssertEqual(GitService.parseBranchList(output), ["main", "feature/x", "release/1.0"])
    }

    func testDropsHEADAndBlankLines() {
        let output = "main\nHEAD\n\nfeature/y\n"
        XCTAssertEqual(GitService.parseBranchList(output), ["main", "feature/y"])
    }

    func testEmptyOutputIsEmpty() {
        XCTAssertTrue(GitService.parseBranchList("").isEmpty)
    }
}

final class WorktreeDisplayTests: XCTestCase {
    func testDetachedWorktreeUsesPlainEnglishLabel() {
        let worktree = Worktree(
            id: "repo#detached",
            projectId: "/repo",
            branch: "detached",
            path: "/repo/.codex/worktrees/abc",
            shade: 0,
            isPrimary: false
        )

        XCTAssertEqual(worktree.displayBranch, "Detached checkout")
    }

    func testEmptyPrimaryBranchLabelsAsPrimaryCheckout() {
        let worktree = Worktree(
            id: "repo#0",
            projectId: "/repo",
            branch: "",
            path: "/repo",
            shade: 0,
            isPrimary: true
        )

        XCTAssertEqual(worktree.displayBranch, "Primary checkout")
    }
}

final class TerminalAppearanceTests: XCTestCase {
    func testLightThemeNamesAreRecognisedForWindowChrome() {
        XCTAssertTrue(TerminalTheming.isLightTheme(named: "Basic"))
        XCTAssertTrue(TerminalTheming.isLightTheme(named: "Clear Light"))
        XCTAssertTrue(TerminalTheming.isLightTheme(named: "Catppuccin Latte"))
        XCTAssertTrue(TerminalTheming.isLightTheme(named: "One Half Light"))
        XCTAssertFalse(TerminalTheming.isLightTheme(named: "Clear Dark"))
        XCTAssertFalse(TerminalTheming.isLightTheme(named: "Catppuccin Mocha"))
    }

    func testThemeBackgroundColorComesFromCatalog() {
        let latte = TerminalTheming.backgroundColor(named: "Catppuccin Latte").usingColorSpace(.sRGB)
        XCTAssertEqual(latte?.redComponent ?? 0, 0.937, accuracy: 0.02)
        XCTAssertEqual(latte?.greenComponent ?? 0, 0.945, accuracy: 0.02)
        XCTAssertEqual(latte?.blueComponent ?? 0, 0.961, accuracy: 0.02)
    }

    func testTerminalProfilesMatchTerminalAppFontDefaults() {
        XCTAssertEqual(TerminalTheming.defaultFontSize(named: "Basic"), 11)
        XCTAssertEqual(TerminalTheming.defaultFontSize(named: "Clear Dark"), 12)
        XCTAssertEqual(TerminalTheming.defaultFontSize(named: "Clear Light"), 12)
        XCTAssertEqual(TerminalTheming.fontFamily(named: "Basic"), "SF Mono")
        XCTAssertEqual(TerminalTheming.fontFamily(named: "Clear Dark"), "SF Mono Terminal")
    }

    func testTerminalConfigKeepsTerminalAppFontAndSmoothing() {
        let rendered = RepoControllerRegistry.terminalConfiguration(themeName: "Clear Dark", fontSize: 12).rendered
        XCTAssertTrue(rendered.contains("font-family = SF Mono Terminal"))
        XCTAssertTrue(rendered.contains("font-size = 12"))
        XCTAssertTrue(rendered.contains("font-thicken = false"))
        XCTAssertTrue(rendered.contains("cursor-style = block"))
        XCTAssertTrue(rendered.contains("cursor-style-blink = false"))
    }

    /// The whole point of the SF Mono profiles is a *monospaced* grid. SF Mono
    /// ships only inside Terminal.app's bundle, so an unregistered family would
    /// resolve to proportional Helvetica. The registrar must always hand back a
    /// genuinely monospaced family — never Helvetica — for the rendered config.
    func testTerminalFontAlwaysResolvesToAMonospacedFamily() {
        for theme in ["Basic", "Clear Dark", "Clear Light"] {
            let preferred = TerminalTheming.fontFamily(named: theme)
            let resolved = TerminalFontRegistrar.resolvedMonospacedFamily(preferred: preferred)
            XCTAssertTrue(
                TerminalFontRegistrar.isMonospacedFamilyAvailable(resolved),
                "\(theme): resolved family \(resolved) must be monospaced"
            )
            XCTAssertNotEqual(resolved, "Helvetica", "\(theme) must never fall back to a proportional font")
        }
    }

    func testUnknownFamilyFallsBackToMenlo() {
        XCTAssertEqual(
            TerminalFontRegistrar.resolvedMonospacedFamily(preferred: "DefinitelyNotARealFont123"),
            "Menlo"
        )
    }

    func testClearTerminalProfilesUseTerminalAppColors() {
        let dark = TerminalTheming.theme(named: "Clear Dark").dark.rendered
        XCTAssertTrue(dark.contains("background = 212734"))
        XCTAssertTrue(dark.contains("foreground = E6E6E6"))
        XCTAssertTrue(dark.contains("background-opacity = 0.95"))
        XCTAssertTrue(dark.contains("palette = 0=#35424C"))

        let light = TerminalTheming.theme(named: "Clear Light").light.rendered
        XCTAssertTrue(light.contains("background = FFFFFF"))
        XCTAssertTrue(light.contains("foreground = 3A4851"))
        XCTAssertTrue(light.contains("background-opacity = 0.93"))
        XCTAssertTrue(light.contains("palette = 0=#2D3840"))
    }
}

final class ProjectHeaderDisplayTests: XCTestCase {
    func testHeadBranchRendersAsDetachedCheckout() {
        XCTAssertEqual(
            ProjectHeaderView.displayBranch("HEAD", fallback: "agent/worktree"),
            "Detached checkout"
        )
    }
}

final class ShortcutResolutionTests: XCTestCase {
    func testTerminalSafeAppShortcutsResolveBeforeGhosttyCanSwallowThem() {
        XCTAssertEqual(
            JuggleShortcutAction.resolve(modifiers: .command, characters: "q"),
            .quit
        )
        XCTAssertEqual(
            JuggleShortcutAction.resolve(modifiers: .command, characters: "w"),
            .closeWindow
        )
        XCTAssertEqual(
            JuggleShortcutAction.resolve(modifiers: [.command, .option], characters: "g"),
            .tileGrid
        )
    }
}

final class StatusBarIconTests: XCTestCase {
    func testMenuBarIconIsATemplateImageWithSize() {
        let icon = StatusBarIcon.image()
        XCTAssertTrue(icon.isTemplate, "menu-bar icon must be a template so it adapts to light/dark and tints")
        XCTAssertGreaterThan(icon.size.width, 0)
        XCTAssertGreaterThan(icon.size.height, 0)
    }

    func testMenuBarIconActuallyDrawsCoverage() {
        // A blank template would render an invisible menu-bar item. Rasterise and
        // assert some pixels are actually inked.
        let icon = StatusBarIcon.image(filled: true)
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return XCTFail("icon produced no bitmap")
        }
        var inked = 0
        for y in 0 ..< rep.pixelsHigh {
            for x in 0 ..< rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                inked += 1
            }
        }
        XCTAssertGreaterThan(inked, 0, "menu-bar glyph must draw visible coverage")
    }
}

final class PRStatusMappingTests: XCTestCase {
    private func object(_ mergeState: String, draft: Bool = false, state: String = "OPEN") -> [String: Any] {
        ["state": state, "number": 7, "headRefOid": "deadbeef", "isDraft": draft,
         "mergeStateStatus": mergeState, "title": "Polish notch HUD", "url": "https://example.com/pr/7",
         "headRefName": "feat/notch"]
    }

    func testCleanIsAvailable() {
        let status = GhService.map(object("CLEAN"))
        XCTAssertEqual(status.availability, .available)
        XCTAssertEqual(status.number, 7)
        XCTAssertEqual(status.headOid, "deadbeef")
        XCTAssertEqual(status.title, "Polish notch HUD")
        XCTAssertEqual(status.url, "https://example.com/pr/7")
        XCTAssertEqual(status.headRefName, "feat/notch")
    }

    func testBehind() { XCTAssertEqual(GhService.map(object("BEHIND")).availability, .behind) }
    func testUnstableIsChecksRunning() { XCTAssertEqual(GhService.map(object("UNSTABLE")).availability, .checksRunning) }
    func testUnknownStateIsBlocked() { XCTAssertEqual(GhService.map(object("WUT")).availability, .blocked) }
    func testDraftWins() { XCTAssertEqual(GhService.map(object("CLEAN", draft: true)).availability, .draft) }
    func testNonOpenPRIsNone() { XCTAssertEqual(GhService.map(object("CLEAN", state: "MERGED")).availability, .none) }
}

final class ShadeIndexTests: XCTestCase {
    @MainActor
    func testAlternatingShades() {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("shade-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let model = AppModel(storeURL: store)
        XCTAssertEqual(model.shade(forIndex: 1), 1)
        XCTAssertEqual(model.shade(forIndex: 2), -1)
        XCTAssertEqual(model.shade(forIndex: 3), 2)
        XCTAssertEqual(model.shade(forIndex: 4), -2)
        XCTAssertEqual(model.shade(forIndex: 5), 3)
    }
}

final class NSColorHexTests: XCTestCase {
    func testSixCharParse() {
        let color = NSColor(hex: "#FF0000")?.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.redComponent ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(color?.greenComponent ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual(color?.blueComponent ?? 1, 0, accuracy: 0.001)
    }

    func testEightCharAlpha() {
        let color = NSColor(hex: "#FF000080")?.usingColorSpace(.sRGB)
        XCTAssertEqual(color?.redComponent ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(color?.alphaComponent ?? 0, 0.502, accuracy: 0.01)
    }

    func testInvalidReturnsNil() {
        XCTAssertNil(NSColor(hex: "ZZZZZZ"))
        XCTAssertNil(NSColor(hex: "#FFFF"))
    }
}
