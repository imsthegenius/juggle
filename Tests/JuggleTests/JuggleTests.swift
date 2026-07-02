import AppKit
import XCTest
@testable import Juggle

final class StateDetectorTests: XCTestCase {
    @MainActor
    func testAttentionFromBellAndNotification() {
        let detector = StateDetector()
        detector.ingest(.bell)
        XCTAssertEqual(detector.state, .blocked)

        detector.clear()
        XCTAssertEqual(detector.state, .working)

        detector.ingest(.desktopNotification(title: "agent", body: "needs you"))
        XCTAssertEqual(detector.state, .blocked)
    }

    @MainActor
    func testCommandFinishedMapping() {
        let detector = StateDetector()

        detector.ingest(.commandFinished(exitCode: 1, durationNanos: 1))
        XCTAssertEqual(detector.state, .error, "non-zero exit is an error")

        detector.clear()
        detector.ingest(.commandFinished(exitCode: 0, durationNanos: 11_000_000_000))
        XCTAssertEqual(detector.state, .commandFinished, "long successful command notifies")

        detector.clear()
        detector.ingest(.commandFinished(exitCode: 0, durationNanos: 1_000_000_000))
        XCTAssertEqual(detector.state, .working, "short successful command is routine")
    }

    @MainActor
    func testDoneNotificationMapsToDoneButApprovalMapsToBlocked() {
        let detector = StateDetector()

        detector.ingest(.desktopNotification(title: "Claude", body: "Task completed"))
        XCTAssertEqual(detector.state, .done, "explicit completion notification is done/idle")

        detector.clear()
        detector.ingest(.desktopNotification(title: "Claude", body: "Waiting for approval"))
        XCTAssertEqual(detector.state, .blocked, "approval/input notifications still mean blocked")
    }

    @MainActor
    func testNilExitNeverNotifies() {
        let detector = StateDetector()
        detector.ingest(.commandFinished(exitCode: nil, durationNanos: 1))
        XCTAssertEqual(detector.state, .working)
        detector.ingest(.commandFinished(exitCode: nil, durationNanos: 11_000_000_000))
        XCTAssertEqual(detector.state, .working, "unreported exit is not evidence of success")
    }

    @MainActor
    func testProgressErrorAndFocusClear() {
        let detector = StateDetector()
        detector.ingest(.progressError)
        XCTAssertEqual(detector.state, .error)
        detector.ingest(.focused)
        XCTAssertEqual(detector.state, .working)
    }
}

final class RepoColorTests: XCTestCase {
    func testAssignmentIsDeterministic() {
        let key = "/Users/example/Desktop/mission-control"
        XCTAssertEqual(RepoColor.assign(forKey: key), RepoColor.assign(forKey: key))
        XCTAssertTrue(RepoColor.palette.contains(RepoColor.assign(forKey: key)))
    }

    func testNamedLookup() {
        XCTAssertEqual(RepoColor.named("Teal")?.name, "Teal")
        XCTAssertNil(RepoColor.named("Nope"))
    }

    func testShadesDifferFromBase() {
        let color = RepoColor.palette[0]
        func red(_ value: NSColor) -> CGFloat { value.usingColorSpace(.sRGB)?.redComponent ?? -1 }
        XCTAssertEqual(red(color.shaded(0)), red(color.nsColor), accuracy: 0.001)
        XCTAssertNotEqual(red(color.shaded(1)), red(color.nsColor))
        XCTAssertNotEqual(red(color.shaded(-1)), red(color.nsColor))
    }

    func testShadeBlendClamps() {
        let color = RepoColor.palette[0]
        func red(_ value: NSColor) -> CGFloat { value.usingColorSpace(.sRGB)?.redComponent ?? -1 }
        XCTAssertEqual(red(color.shaded(3)), red(color.shaded(4)), accuracy: 0.001, "blend clamps at level 3")
    }
}

final class PreferencesTests: XCTestCase {
    func testSliderMappings() {
        var prefs = Preferences()
        prefs.titlebarTint = 0
        prefs.windowGap = 0
        XCTAssertEqual(prefs.tintFraction, 0.18, accuracy: 0.001)
        XCTAssertEqual(prefs.gapPoints, 0, accuracy: 0.001)    // flush

        prefs.titlebarTint = 1
        prefs.windowGap = 1
        XCTAssertEqual(prefs.tintFraction, 0.52, accuracy: 0.001)
        XCTAssertEqual(prefs.gapPoints, 12, accuracy: 0.001)
    }
}

final class PreferencesCodableTests: XCTestCase {
    /// An older saved workspace.json predates `terminalFontSize`; decoding it must
    /// still succeed (and fill the default) rather than throwing — a throw would
    /// drop the user's whole project list along with their preferences.
    func testDecodeMissingFieldUsesDefault() throws {
        let json = Data("""
        {"titlebarTint":0.5,"windowGap":0.0,"breathing":true,"soundOnBlocked":false,\
        "gridColumns":3,"gridRows":2,"terminalTheme":"Dracula"}
        """.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(prefs.terminalFontSize, 11, "missing field falls back to the Basic Terminal.app profile size")
        XCTAssertEqual(prefs.gridColumns, 3)
        XCTAssertEqual(prefs.terminalTheme, "Dracula")
    }

    func testDecodeEmptyObjectIsAllDefaults() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs, Preferences())
    }

    func testLegacyThirteenPointTerminalSizeIsPreserved() throws {
        let json = Data(#"{"terminalFontSize":13}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(prefs.terminalFontSize, 13)
    }

    func testTerminalFontSizeAllowsTerminalAppBasicSize() throws {
        let json = Data(#"{"terminalFontSize":10}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(prefs.terminalFontSize, 11)
        XCTAssertEqual(Preferences.terminalFontSizeRange.lowerBound, 11)
    }

    func testRoundTrip() throws {
        var prefs = Preferences()
        prefs.terminalFontSize = 12
        prefs.gridColumns = 4
        let data = try JSONEncoder().encode(prefs)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), prefs)
    }
}

final class RepoColorResolveTests: XCTestCase {
    func testResolvesPaletteName() {
        XCTAssertEqual(RepoColor.nsColor(for: "Teal").hexString.uppercased(), "#20C7CE")
    }

    func testResolvesCustomHex() {
        XCTAssertEqual(RepoColor.nsColor(for: "#123456").hexString.uppercased(), "#123456")
    }

    func testNilFallsBackToFirstPalette() {
        XCTAssertEqual(RepoColor.nsColor(for: nil).hexString.uppercased(),
                       RepoColor.palette[0].nsColor.hexString.uppercased())
    }

    func testHexStringRoundTripsThroughNSColor() {
        let color = NSColor(hex: "#A977F0")
        XCTAssertEqual(color?.hexString.uppercased(), "#A977F0")
    }

    func testHueComponentSafeReturnsUsableSliderSeed() {
        let hue = RepoColor.nsColor(for: "#20C7CE").hueComponentSafe
        XCTAssertGreaterThanOrEqual(hue, 0)
        XCTAssertLessThanOrEqual(hue, 1)
    }
}

final class GitRootTests: XCTestCase {
    func testNonRepoFallsBackToExpandedInput() {
        let temp = NSTemporaryDirectory()
        XCTAssertEqual(GitRoot.find(from: temp), (temp as NSString).expandingTildeInPath)
    }

    func testFindsEnclosingRepo() {
        // This source file lives inside the juggle git repo.
        let resolved = GitRoot.find(from: (#file as NSString).deletingLastPathComponent)
        XCTAssertTrue(resolved.hasSuffix("juggle"), "should resolve to the repo root, got \(resolved)")
    }
}
