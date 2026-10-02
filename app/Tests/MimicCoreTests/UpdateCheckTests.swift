import XCTest
@testable import MimicCore

/// Check for updates when Mimic opens: on by default, and Sparkle's old switch carried over and
/// taken away, so its daily check can't come back.
final class UpdateCheckTests: XCTestCase {
    private let suite = "mimic-tests-\(UUID().uuidString)"
    private func defaults() throws -> UserDefaults { try XCTUnwrap(UserDefaults(suiteName: suite)) }
    override func tearDown() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

    func testOnUnlessTurnedOff() throws {
        let d = try defaults()
        XCTAssertTrue(UpdateCheck.atLaunch(d))
        d.set(false, forKey: UpdateCheck.key)
        XCTAssertFalse(UpdateCheck.atLaunch(d))
    }

    func testTheOldSwitchTurnedOffStaysOff() throws {
        let d = try defaults()
        d.set(false, forKey: UpdateCheck.sparkleKey)
        XCTAssertFalse(UpdateCheck.atLaunch(d))
        XCTAssertNil(d.object(forKey: UpdateCheck.sparkleKey), "Sparkle's own switch is gone")
        XCTAssertFalse(UpdateCheck.atLaunch(d), "and the answer is kept")
    }

    /// Saved as on, Sparkle's switch overrides the Info.plist and its daily check comes back.
    func testTheOldSwitchTurnedOnIsTakenAway() throws {
        let d = try defaults()
        d.set(true, forKey: UpdateCheck.sparkleKey)
        XCTAssertTrue(UpdateCheck.atLaunch(d))
        XCTAssertNil(d.object(forKey: UpdateCheck.sparkleKey))
    }
}
