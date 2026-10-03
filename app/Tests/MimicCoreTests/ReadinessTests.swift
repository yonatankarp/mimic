import Foundation
import XCTest
@testable import MimicCore

/// What the checks so far decide: whether Make is blocked and whether pictures can be made.
final class ReadinessTests: XCTestCase {
    private func check(_ id: String, required: Bool = false) -> Check {
        Check(id: id, label: id, required: required, fix: "") { CheckResult(id: id, label: id, required: required, ok: true, fix: "") }
    }

    private func result(_ id: String, _ ok: Bool, required: Bool = false, label: String? = nil) -> CheckResult {
        CheckResult(id: id, label: label ?? "\(id) label", required: required, ok: ok, fix: "")
    }

    func testOnlyKnownRequiredFailuresBlockInTheChecksOrder() {
        let checks = [check("engine", required: true), check("models", required: true), check("space", required: true), check("slicer")]
        XCTAssertNil(Readiness(checks: checks, results: [:]).blocking, "a check still running doesn't block")
        let results = ["space": result("space", false, required: true), "engine": result("engine", false, required: true),
                       "models": result("models", true, required: true), "slicer": result("slicer", false)]
        XCTAssertEqual(Readiness(checks: checks, results: results).blocking,
                       "Mimic isn't fully set up yet: engine label, space label.", "in the checks' order; a feature's failure doesn't block")
        XCTAssertNil(Readiness(checks: checks, results: ["slicer": result("slicer", false)]).blocking)
    }

    func testPicturesAreReadyWhenEveryDrawThingsCheckIsGreen() {
        let checks = Checks.drawThingsIDs.sorted().map { check($0) }
        var results = Dictionary(uniqueKeysWithValues: Checks.drawThingsIDs.map { ($0, result($0, true)) })
        XCTAssertTrue(Readiness(checks: checks, results: results).picturesReady)
        XCTAssertFalse(Readiness(checks: checks, results: results).online)
        XCTAssertEqual(Readiness(checks: checks, results: results).pictureNeed(.bfl), "Draw Things", "Draw Things' checks ran, so it's Draw Things")
        results["drawthings-model"] = result("drawthings-model", false)
        XCTAssertFalse(Readiness(checks: checks, results: results).picturesReady)
        results["drawthings-model"] = nil
        XCTAssertFalse(Readiness(checks: checks, results: results).picturesReady, "not until it's known")
    }

    func testOnlinePicturesNeedOnlyTheKey() {
        let checks = [check(Checks.onlineID)]
        let ready = Readiness(checks: checks, results: [Checks.onlineID: result(Checks.onlineID, true)])
        XCTAssertTrue(ready.online)
        XCTAssertTrue(ready.picturesReady, "no Draw Things check needed")
        XCTAssertEqual(ready.pictureNeed(.bfl), "a working \(OnlineService.bfl.name) key")
        XCTAssertEqual(ready.pictureNeed(.drawThings), "a working online key")
        XCTAssertFalse(Readiness(checks: checks, results: [Checks.onlineID: result(Checks.onlineID, false)]).picturesReady)
    }

    func testDrawThingsOpensWhenNeededOnlyWhenClosed() {
        let checks = [check("drawthings-api")]
        let closed = Readiness(checks: checks, results: ["drawthings-api": result("drawthings-api", true, label: Checks.opensWhenNeeded)])
        XCTAssertTrue(closed.drawThingsOpensWhenNeeded)
        XCTAssertFalse(closed.drawThingsConnected, "closed: its connection isn't known")
        let open = Readiness(checks: checks, results: ["drawthings-api": result("drawthings-api", true, label: "Draw Things is open and connected")])
        XCTAssertFalse(open.drawThingsOpensWhenNeeded)
        XCTAssertTrue(open.drawThingsConnected)
        XCTAssertFalse(Readiness(checks: checks, results: ["drawthings-api": result("drawthings-api", false)]).drawThingsConnected)
    }
}
