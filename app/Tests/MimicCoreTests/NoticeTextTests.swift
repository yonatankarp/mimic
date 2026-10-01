import XCTest
@testable import MimicCore

/// The words of a finished mini's notification and of Report a Problem's question.
final class NoticeTextTests: XCTestCase {
    private func ended(step: Int, exit: Int32) -> JobStatus {
        var s = JobStatus(name: "dwarf", kind: .generate, step: step, started: Date())
        s.running = false
        s.exit = exit
        return s
    }

    func testAReadyMiniSaysSoAndOffersTheSlicer() {
        let text = MiniNotification.text(ended(step: 3, exit: 0), who: "Élodie the Druid")
        XCTAssertEqual(text, .init(title: "Élodie the Druid is ready", body: "Ready to print.", category: MiniNotification.ready))
        XCTAssertEqual(MiniNotification.openTitle(slicer: "Bambu Studio"), "Open in Bambu Studio")
    }

    func testAFailedMiniSaysWhichStepItStoppedIn() {
        let text = MiniNotification.text(ended(step: 2, exit: 1), who: "Dwarf")
        XCTAssertEqual(text, .init(title: "Dwarf didn't finish", body: "Something went wrong while building the 3d shape.",
                                   category: MiniNotification.failed))
        XCTAssertEqual(MiniNotification.text(ended(step: 1, exit: 1), who: "Dwarf").body,
                       "Something went wrong while getting the picture ready.")
        XCTAssertEqual(MiniNotification.retryTitle, "Try Again")
    }

    func testTheIdentifiersStayAsTheyWere() {
        // Notifications already in Notification Center carry these: changing one leaves their buttons dead.
        XCTAssertEqual([MiniNotification.ready, MiniNotification.failed, MiniNotification.retry, MiniNotification.open, MiniNotification.mini],
                       ["mini-ready", "mini-failed", "try-again", "open-in-slicer", "mini"])
    }

    func testReportingAMiniNamesItAndItsSettings() {
        let q = ReportQuestion(mini: "Élodie the Druid")
        XCTAssertEqual(q.title, "Report a problem with “Élodie the Druid”?")
        XCTAssertEqual(q.text, "Mimic puts its notes on making this mini, the mini's settings, and which Mac and version this is, "
            + "into one file, with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to.")
    }

    func testReportingFromTheHelpMenuIsAboutWhatHappened() {
        let q = ReportQuestion(mini: nil)
        XCTAssertEqual(q.title, "Report a problem?")
        XCTAssertEqual(q.text, "Mimic puts its notes on what happened, and which Mac and version this is, into one file, "
            + "with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to.")
    }
}
