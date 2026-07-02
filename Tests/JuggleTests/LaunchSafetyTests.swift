import XCTest
@testable import Juggle

@MainActor
final class LaunchSafetyTests: XCTestCase {
    func testUnbundledNonDiagnosticLaunchBlocksByDefault() {
        XCTAssertTrue(
            AppDelegate.shouldBlockUnbundledWorkspaceLaunch(
                diagnosticMode: false,
                environment: [:],
                bundlePath: "/Users/example/Developer/juggle/.build/arm64-apple-macosx/release/Juggle"
            ),
            "real workspace launches from SwiftPM's unbundled binary should be blocked to avoid TCC code-identity churn"
        )
    }

    func testBundledAppLaunchIsAllowed() {
        XCTAssertFalse(
            AppDelegate.shouldBlockUnbundledWorkspaceLaunch(
                diagnosticMode: false,
                environment: [:],
                bundlePath: "/Users/example/Applications/Juggle.app"
            ),
            "the stably signed .app bundle is the safe routine launch identity"
        )
    }

    func testDiagnosticLaunchIsAllowed() {
        XCTAssertFalse(
            AppDelegate.shouldBlockUnbundledWorkspaceLaunch(
                diagnosticMode: true,
                environment: [:],
                bundlePath: "/Users/example/Developer/juggle/.build/arm64-apple-macosx/release/Juggle"
            ),
            "diagnostics run against isolated stores and must still be launchable by the harness"
        )
    }

    func testExplicitUnbundledWorkspaceOverrideIsAllowed() {
        XCTAssertFalse(
            AppDelegate.shouldBlockUnbundledWorkspaceLaunch(
                diagnosticMode: false,
                environment: ["JUGGLE_ALLOW_UNBUNDLED_WORKSPACE": "1"],
                bundlePath: "/Users/example/Developer/juggle/.build/arm64-apple-macosx/release/Juggle"
            ),
            "the escape hatch is explicit for rare local debugging where the caller accepts the TCC risk"
        )
    }

    func testQAShotWithoutIsolatedStoreDoesNotBypassUnbundledLaunchGuard() {
        XCTAssertFalse(AppDelegate.permitsControllerDiagnosticLaunch(
            arguments: ["Juggle", "--qa-shot", "/tmp/shot"],
            environment: [:]
        ))
    }

    func testQAShotWithIsolatedStoreMayPassThroughToControllerParser() {
        XCTAssertTrue(AppDelegate.permitsControllerDiagnosticLaunch(
            arguments: ["Juggle", "--qa-shot", "/tmp/shot"],
            environment: ["JUGGLE_APP_SUPPORT_DIR": "/tmp/juggle-isolated-store"]
        ))
    }

    func testIsolatedAppSupportRequiresNonEmptyOverride() {
        XCTAssertFalse(AppDelegate.hasIsolatedAppSupport(environment: [:]))
        XCTAssertFalse(AppDelegate.hasIsolatedAppSupport(environment: ["JUGGLE_APP_SUPPORT_DIR": ""]))
        XCTAssertTrue(AppDelegate.hasIsolatedAppSupport(environment: ["JUGGLE_APP_SUPPORT_DIR": "/tmp/juggle-isolated-store"]))
    }

    func testLaunchSurfaceShowsProjectPromptForEmptyWorkspace() {
        XCTAssertEqual(
            AppDelegate.launchSurfaceKind(projectCount: 0, openTerminalCount: 0),
            .projectOpenPrompt
        )
    }

    func testLaunchSurfaceShowsHomeForSavedProjectsWithoutVisibleWorkspace() {
        XCTAssertEqual(
            AppDelegate.launchSurfaceKind(projectCount: 2, openTerminalCount: 0),
            .recentProjectsHome
        )
    }

    func testLaunchSurfaceDoesNotInterruptRestoredWorkspace() {
        XCTAssertEqual(
            AppDelegate.launchSurfaceKind(projectCount: 2, openTerminalCount: 1),
            .restoredWorkspace
        )
    }
}
