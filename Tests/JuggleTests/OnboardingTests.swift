import AppKit
import XCTest
@testable import Juggle

/// Legacy onboarding completion still round-trips, but launch now keys off the
/// project list and shows the project-open prompt when that list is empty. A
/// throw here would silently drop the user's projects, so decoding must never
/// fail on a missing field.
final class OnboardingPreferenceTests: XCTestCase {
    func testDefaultsToFalse() {
        let prefs = Preferences()
        XCTAssertFalse(prefs.hasOnboarded, "a fresh install has not onboarded")
    }

    func testDecodeFromOlderJSONWithoutTheFieldIsFalse() throws {
        // Predates hasOnboarded — decoding must still succeed and default false.
        let json = Data(#"{"titlebarTint":0.5,"windowGap":0.0,"breathing":true,"soundOnBlocked":false,"gridColumns":2,"gridRows":2,"terminalTheme":"Dracula","terminalFontSize":13}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertFalse(prefs.hasOnboarded, "older stores decode to not-onboarded")
    }

    func testSetToTrueRoundTrips() throws {
        var prefs = Preferences()
        prefs.hasOnboarded = true
        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertTrue(decoded.hasOnboarded, "finishing onboarding persists across save/load")
    }

    func testDoesNotInterfereWithExistingDecoding() throws {
        // The empty-object case (used by PreferencesCodableTests) still maps to all defaults.
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs, Preferences())
        XCTAssertFalse(prefs.hasOnboarded)
    }
}

final class GhAuthParseTests: XCTestCase {
    /// Verbatim `gh auth status` output (authenticated, keyring). The active
    /// account name is pulled from the `Logged in … account <name>` line.
    func testParsesActiveAccountFromAuthStatus() {
        let output = """
        github.com
          ✓ Logged in to github.com account imsthegenius (keyring)
          - Active account: true
          - Git operations protocol: https
          - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
        """
        XCTAssertEqual(GhService.activeAccount(in: output), "imsthegenius")
    }

    /// When several accounts are configured, the one marked `Active account: true`
    /// wins (its preceding `Logged in …` line carries the name).
    func testPrefersExplicitlyActiveAccount() {
        let output = """
        github.com
          ✓ Logged in to github.com account secondary (keyring)
          - Active account: false
          ✓ Logged in to github.com account primary (keyring)
          - Active account: true
        """
        XCTAssertEqual(GhService.activeAccount(in: output), "primary")
    }

    func testNoAccountLineReturnsNil() {
        XCTAssertNil(GhService.activeAccount(in: "github.com\n  - nope"))
        XCTAssertNil(GhService.activeAccount(in: ""))
    }

    func testAccountNameOnLineParses() {
        XCTAssertEqual(GhService.accountName(on: "✓ Logged in to ghe.example.com account dev (oauth_token)"), "dev")
        XCTAssertNil(GhService.accountName(on: "some unrelated line"))
    }
}
