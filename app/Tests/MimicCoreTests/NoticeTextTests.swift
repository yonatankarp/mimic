import XCTest
@testable import MimicCore

/// The words of a finished mini's notification and of Report a Problem's question.
final class NoticeTextTests: XCTestCase {
    private func ended(step: JobStep, exit: Int32) -> JobStatus {
        var s = JobStatus(name: "dwarf", kind: .generate, step: step, started: Date())
        s.running = false
        s.exit = exit
        return s
    }

    func testAReadyMiniSaysSoAndOffersTheSlicer() {
        let text = MiniNotification.text(ended(step: .print, exit: 0), who: "Élodie the Druid")
        XCTAssertEqual(text, .init(title: "Élodie the Druid is ready", body: "Ready to print.", category: MiniNotification.ready))
        XCTAssertEqual(MiniNotification.openTitle(slicer: "Bambu Studio"), "Open in Bambu Studio")
    }

    func testAFailedMiniSaysWhichStepItStoppedIn() {
        let text = MiniNotification.text(ended(step: .shape, exit: 1), who: "Dwarf")
        XCTAssertEqual(text, .init(title: "Dwarf didn't finish", body: "Something went wrong while building the 3D shape.",
                                   category: MiniNotification.failed))
        XCTAssertEqual(MiniNotification.text(ended(step: .picture, exit: 1), who: "Dwarf").body,
                       "Something went wrong while getting the picture ready.")
        XCTAssertEqual(MiniNotification.retryTitle, "Try Again")
    }

    /// A resize keeps its old size whether stopped or taken out of the queue; an import goes to
    /// the Trash. (A new mini and a Try Again: JobTests, beside what Stop does to them.)
    func testStopAndTakeOutSayWhatHappensToAResize() {
        var resize = JobStatus(name: "dwarf", kind: .prep, step: .print, started: Date())
        XCTAssertEqual([resize.stopAsks, resize.stopSays], ["It keeps its previous size.", "It keeps its previous size."])
        resize.again = true
        XCTAssertEqual(resize.stopSays, "It keeps its previous size.", "a resize tried again keeps its size too")
        resize.importing = true; resize.again = false
        XCTAssertEqual(resize.stopSays, "Nothing was kept. It's in the Trash if you want the pieces.")
        XCTAssertEqual(QueueEntry(name: "dwarf", job: .prep).takeOutSays(importing: false), "It keeps its current size.")
        XCTAssertEqual(QueueEntry(name: "dwarf", job: .prep).takeOutSays(importing: true),
                       "It hasn't been made yet, so it goes to the Trash, where you can get it back.")
        XCTAssertEqual(QueueEntry(name: "dwarf", job: .generate).takeOutSays(importing: false),
                       "It hasn't been made yet, so its picture and settings go to the Trash, where you can get them back.")
    }

    /// Print prep's footprint warning: the figure's bottom reaches past its base, and the way out
    /// is a bigger base (it once said "some thin parts may be fragile", which wasn't it).
    func testTheFootprintNoteSaysTheBaseIsTooSmall() {
        XCTAssertEqual(PrepReport.footprintNote,
                       "The bottom of the figure reaches past the edge of its base. Resize This Mini with a bigger base size to fit it on.")
    }

    func testTheIdentifiersStayAsTheyWere() {
        // Notifications already in Notification Center carry these: changing one leaves their buttons dead.
        XCTAssertEqual([MiniNotification.ready, MiniNotification.failed, MiniNotification.retry, MiniNotification.open, MiniNotification.mini],
                       ["mini-ready", "mini-failed", "try-again", "open-in-slicer", "mini"])
    }

    func testReportingAMiniNamesItAndItsSettings() {
        let q = ReportQuestion(mini: "Élodie the Druid")
        XCTAssertEqual(q.title, "Report a problem with “Élodie the Druid”?")
        XCTAssertEqual(q.text, "Mimic puts its notes on making this mini, its settings and your description of it, and which Mac, version and setup this is, "
            + "into one file, with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to.")
    }

    func testReportingFromTheHelpMenuIsAboutWhatHappened() {
        let q = ReportQuestion(mini: nil)
        XCTAssertEqual(q.title, "Report a problem?")
        XCTAssertEqual(q.text, "Mimic puts its notes on what happened, and which Mac, version and setup this is, into one file, "
            + "with keys and passwords taken out. Then it shows you the file and opens a form on GitHub to attach it to.")
    }
}
