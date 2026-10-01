import XCTest
@testable import MimicCore

/// What a job's programs run with, and the power setting that holds the queue.
final class ToolsTests: XCTestCase {
    /// Homebrew on the PATH, launched from the Dock or not, and nothing of the app's own
    /// environment: only the five set here reach a job's programs.
    func testAJobsProgramsGetTheirOwnEnvironment() {
        setenv("MIMIC_LEAK_CHECK", "1", 1)
        defer { unsetenv("MIMIC_LEAK_CHECK") }
        let env = Tools.childEnvironment(home: "/Users/someone")
        XCTAssertEqual(Set(env.keys), ["PATH", "HOME", "USER", "LANG", "TMPDIR"])
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(env["HOME"], "/Users/someone")
        XCTAssertEqual(env["USER"], NSUserName())
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(Tools.childEnvironment()["HOME"], NSHomeDirectory())
    }

    /// The running binary as a real file, not the symlink it may have been started through.
    func testOwnExecutableIsTheRealFile() {
        let path = Tools.ownExecutable()
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, path, "a symlink is left in it")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path)
    }

    /// The setting holds the queue only on battery; off, nothing does. A Mac without a battery is
    /// never on it.
    func testThePowerSettingHoldsOnlyOnBattery() throws {
        let suite = "mimic-power-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(Power.holds(suite: suite)(), "off by default")
        defaults.set(true, forKey: Power.key)
        XCTAssertEqual(Power.holds(suite: suite)(), Power.onBattery())
        if !Power.hasBattery() { XCTAssertFalse(Power.onBattery(), "on a battery it doesn't have") }
        defaults.set(false, forKey: Power.key)
        XCTAssertFalse(Power.holds(suite: suite)())
    }
}
