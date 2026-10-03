import Foundation

/// One thing a mini's menus do. The right-click menu, the Mini menu, the toolbar on a mini's page
/// and the page for several selected minis are all built from these (#361), with the titles and
/// rules in `MiniMenu`, so they can't drift apart. The app adds the icons, shortcuts and help.
public enum MiniAction: CaseIterable, Sendable {
    case open, openTogether, copies, showInFinder, exportForTabletop, resize, resizeSeveral,
         buildShape, tryAgain, reportProblem, rename,
         anotherVersion, newShape, editAndMakeAgain, duplicate, moveToTrash
}

/// What the mini actions' rules go by: what the app is doing right now.
public struct MiniMenu: Sendable {
    /// The minis waiting in the queue, and the one being made.
    public var waiting: Set<String>
    public var making: String?
    /// A sheet is open: every action waits, so a shortcut can't swap it for another.
    public var sheetUp = false
    /// Something Mimic needs to make minis isn't set up.
    public var needsSetup = false
    public var installed = true
    /// Minis being put in one print file for Open Together or Copies.
    public var packing = false

    public init(waiting: Set<String> = [], making: String? = nil, sheetUp: Bool = false, needsSetup: Bool = false,
                installed: Bool = true, packing: Bool = false) {
        self.waiting = waiting; self.making = making; self.sheetUp = sheetUp
        self.needsSetup = needsSetup; self.installed = installed; self.packing = packing
    }

    /// Waiting in the queue or being made: it can't be resized, renamed or duplicated, as the
    /// queue would refuse it.
    public func busy(_ mini: Mini) -> Bool { waiting.contains(mini.name) || making == mini.name }

    /// Why it can't be moved to another project right now, or nil: the queue would refuse it too.
    public func whyCantMove(_ mini: Mini) -> String? { busy(mini) ? RequestError.cantMove(mini.name).description : nil }

    /// Its picture waits to be checked (#156), and it isn't waiting or being made.
    public func pictureToCheck(_ mini: Mini) -> Bool { !busy(mini) && mini.pictureToCheck }

    /// It didn't finish and can be tried again: not waiting or being made, and it kept what it
    /// was asked for. One whose picture is ready to check has Build Shape instead (#156).
    public func canRetry(_ mini: Mini) -> Bool {
        !mini.finished && !busy(mini) && mini.settings.requested != nil && !mini.settings.isImported && !mini.pictureToCheck
    }

    public func title(_ action: MiniAction, for minis: [Mini], slicer: String) -> String {
        switch action {
        case .open: String(localized: "Open in \(slicer)", bundle: .mimicCore)
        case .openTogether: String(localized: "Open Together in \(slicer)", bundle: .mimicCore)
        case .copies: String(localized: "Copies…", bundle: .mimicCore)
        case .showInFinder: String(localized: "Show in Finder", bundle: .mimicCore)
        case .exportForTabletop: String(localized: "Export for Virtual Tabletop…", bundle: .mimicCore)
        case .resize: String(localized: "Resize This Mini…", bundle: .mimicCore)
        case .resizeSeveral: String(localized: "Resize \(minis.count) Minis…", bundle: .mimicCore)
        case .buildShape: String(localized: "Build Shape", bundle: .mimicCore)
        case .tryAgain: String(localized: "Try Again", bundle: .mimicCore)
        case .reportProblem: String(localized: "Report a Problem…", bundle: .mimicCore)
        case .rename: String(localized: "Rename…", bundle: .mimicCore)
        case .anotherVersion: String(localized: "Make Another Version…", bundle: .mimicCore)
        case .newShape: String(localized: "New 3D Shape…", bundle: .mimicCore)
        case .editAndMakeAgain: String(localized: "Edit & Make Again…", bundle: .mimicCore)
        case .duplicate: String(localized: "Duplicate…", bundle: .mimicCore)
        case .moveToTrash: String(localized: "Move to Trash", bundle: .mimicCore)
        }
    }

    /// The one order the right-click menu and the Mini menu list them in, a section at a time
    /// (#482): open and share it, change it, make it again, what failed, then the Trash. The app
    /// adds Move to Project and Move in Queue after Duplicate. For several minis, Open and Resize
    /// are their versions for several; sections with nothing listed are left out, so no two
    /// dividers meet.
    public func sections(for minis: [Mini]) -> [[MiniAction]] {
        let several = minis.count > 1
        let order: [[MiniAction]] = [
            [several ? .openTogether : .open, .copies, .showInFinder, .exportForTabletop],
            [several ? .resizeSeveral : .resize, .rename, .duplicate],
            [.anotherVersion, .newShape, .editAndMakeAgain],
            [.buildShape, .tryAgain, .reportProblem],
            [.moveToTrash],
        ]
        return order.map { $0.filter { shows($0, for: minis) } }.filter { !$0.isEmpty }
    }

    /// Whether a menu lists it at all:Build Shape, Try Again and Report a Problem only for a
    /// mini they apply to. The rest are always listed, and `enabled` says when they work.
    public func shows(_ action: MiniAction, for minis: [Mini]) -> Bool {
        switch action {
        case .buildShape: one(minis).map(pictureToCheck) ?? false
        case .tryAgain, .reportProblem: one(minis).map(canRetry) ?? false
        default: true
        }
    }

    public func enabled(_ action: MiniAction, for minis: [Mini]) -> Bool {
        guard !sheetUp, shows(action, for: minis) else { return false }
        let mini = one(minis)
        switch action {
        case .open, .exportForTabletop: return mini?.finished == true
        case .openTogether: return minis.filter(\.finished).count >= 2 && !packing
        case .copies: return minis.contains(where: \.finished) && !packing
        case .showInFinder, .moveToTrash: return !minis.isEmpty
        case .resize: return mini.map { $0.hasModel && !busy($0) } == true && !needsSetup
        case .resizeSeveral: return minis.contains(where: \.hasModel) && !needsSetup
        case .buildShape, .tryAgain: return !needsSetup
        case .reportProblem: return true
        case .rename: return mini.map { !busy($0) } == true
        case .duplicate: return mini.map { $0.hasModel && !busy($0) } == true
        case .anotherVersion: return mini.map(JobRunner.canMakeAnotherVersion) == true && !needsSetup
        case .newShape: return mini.map(JobRunner.canMakeNewShape) == true && !needsSetup
        case .editAndMakeAgain: return mini.map(JobRunner.canMakeAnotherVersion) == true && installed
        }
    }

    /// The mini when there's exactly one.
    private func one(_ minis: [Mini]) -> Mini? { minis.count == 1 ? minis[0] : nil }
}
