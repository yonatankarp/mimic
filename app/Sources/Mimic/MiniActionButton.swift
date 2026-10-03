import MimicCore
import SwiftUI

extension AppModel {
    /// What the mini actions' rules go by, right now (`MiniMenu`).
    var miniMenu: MiniMenu {
        MiniMenu(waiting: Set(queue.map(\.name)), making: current?.name, sheetUp: sheet != nil,
                 needsSetup: requiredProblem != nil, installed: setup.installed, packing: packing)
    }
}

/// One of a mini's actions, for the right-click menu, the Mini menu, the toolbar and the page for
/// several selected minis (#361): its title and when it works come from `MiniMenu`, so they all
/// agree. Not listed at all when it doesn't apply (Build Shape, Try Again, Report a Problem).
struct MiniActionButton: View {
    /// Why Make Another Version, New 3D Shape and Edit & Make Again are off for an imported model (#96).
    static let imported = "Off for a model you imported: there's no picture or description to make it again from. Resize and Duplicate work."

    let action: MiniAction
    let minis: [Mini]
    /// No icon in the menu bar, as the other items there have none, nor on a toolbar button.
    var showsIcon = true
    /// Only the Mini menu has the shortcuts: a second item with one would take it.
    var withShortcut = false
    @Environment(AppModel.self) private var model
    /// Optional: the menu bar's items are given only what they use.
    @Environment(Reporter.self) private var reporter: Reporter?

    var body: some View {
        let menu = model.miniMenu
        if menu.shows(action, for: minis) {
            let title = menu.title(action, for: minis, slicer: model.slicerName)
            Button(role: action == .moveToTrash ? .destructive : nil, action: perform) {
                if !showsIcon { Text(title) } else { Label(title, systemImage: icon) }
            }
            .keyboardShortcut(withShortcut ? shortcut : nil)
            .help(help)
            .disabled(!menu.enabled(action, for: minis))
        }
    }

    private var mini: Mini? { minis.count == 1 ? minis[0] : nil }

    private func perform() {
        switch (action, mini) {
        case (.openTogether, _): model.openTogether(minis)
        case (.copies, _): model.sheet = .copies(minis)
        case (.showInFinder, _): model.showInFinder(minis)
        case (.resizeSeveral, _): model.sheet = .resizeSeveral(minis)
        case (.moveToTrash, _): model.askToTrash(minis)
        case (.open, let mini?): if let stl = mini.stl { model.openInSlicer(stl) }
        case (.exportForTabletop, let mini?): model.exportForTabletop(mini)
        case (.resize, let mini?): model.sheet = .resize(mini)
        case (.buildShape, let mini?): model.buildShape(mini)
        case (.tryAgain, let mini?): model.tryAgain(mini)
        case (.reportProblem, let mini?): reporter?.report(mini)
        case (.rename, let mini?): model.sheet = .rename(mini)
        case (.anotherVersion, let mini?): model.sheet = .version(mini, newShape: false)
        case (.newShape, let mini?): model.sheet = .version(mini, newShape: true)
        case (.editAndMakeAgain, let mini?): model.sheet = .makeAgain(mini, MakeStart.again(mini, install: model.install))
        case (.duplicate, let mini?): model.sheet = .duplicate(mini)
        case (_, nil): break  // the rest are for one mini
        }
    }

    private var shortcut: KeyboardShortcut? {
        switch action {
        case .open, .openTogether: KeyboardShortcut("o")
        case .showInFinder: KeyboardShortcut("r", modifiers: [.command, .option])
        case .exportForTabletop: KeyboardShortcut("e", modifiers: [.command, .shift])
        case .resize, .resizeSeveral: KeyboardShortcut("r")
        case .moveToTrash: KeyboardShortcut(.delete)
        default: nil
        }
    }

    private var icon: String {
        switch action {
        case .open, .openTogether: "printer"
        case .copies: "square.grid.2x2"
        case .showInFinder: "folder"
        case .exportForTabletop: "square.and.arrow.up"
        case .resize, .resizeSeveral: "arrow.up.left.and.arrow.down.right"
        case .buildShape, .newShape: "cube"
        case .tryAgain: "arrow.clockwise"
        case .reportProblem: "exclamationmark.bubble"
        case .rename: "pencil"
        case .anotherVersion: "square.on.square"
        case .editAndMakeAgain: "slider.horizontal.3"
        case .duplicate: "plus.square.on.square"
        case .moveToTrash: "trash"
        }
    }

    private var help: String {
        let imported = mini?.settings.isImported == true
        return switch action {
        case .open: "Opens the print file in \(model.slicerName) to slice and print"
        case .openTogether: "One print file with all of them on the bed, each its own object named after it."
        case .copies: minis.count == 1 ? "Several of this mini on the plate, in one print file" : "Several of each on the plate, in one print file"
        case .showInFinder: "Shows the print file and the previews in Finder."
        case .exportForTabletop: "A low-poly .glb to drag into a virtual tabletop"
        case .resize: "Remakes the print file at new sizes, in about a minute"
        case .resizeSeveral: "One size for all of them; each waits its turn"
        case .buildShape: "Makes the 3D shape from the picture it's waiting with"
        case .tryAgain: model.requiredProblem ?? "Makes it again from the step that failed"
        case .reportProblem: "Makes a file of what happened and opens a form on GitHub to send it with"
        case .rename: "Gives it a new name"
        case .anotherVersion: imported ? Self.imported : "Makes it again with a new variation number, with a change to its picture if you like"
        case .newShape: imported ? Self.imported : "Keeps this picture, or redraws it with a change, and makes the 3D shape again"
        case .editAndMakeAgain: imported ? Self.imported : "Opens New Mini filled in from this mini, to change what you like"
        case .duplicate: "Keeps a copy under a new name, then asks what size to make it"
        case .moveToTrash: "Edit → Undo puts it back"
        }
    }
}
