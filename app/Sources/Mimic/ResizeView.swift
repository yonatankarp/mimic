import MimicCore
import SwiftUI

/// Resize This Mini: the size card, loaded with what the mini is now. With `project`, Resize
/// All: one card for every mini in it, loaded from `mini`, the first.
struct ResizeView: View {
    /// The mini whose sizes the card starts from: the one resized, or the first of `group`.
    let mini: Mini
    /// Several resized together: a project's (Resize All) or those selected.
    var group: [Mini]?
    var project: String?
    @Environment(AppModel.self) private var model
    @State private var card: SizeCard
    /// The main window's size under its toolbar: as big as the sheet can grow.
    let room: CGSize
    @State private var height: CGFloat
    @State private var forms = FormHeights(columns: 1)
    /// A refused resize: in words for people, and the raw error for the tooltip.
    @State private var problem: (words: String, detail: String)?

    init(mini: Mini, group: [Mini]? = nil, project: String? = nil, room: CGSize) {
        self.mini = mini
        self.group = group
        self.project = project
        self.room = room
        _height = State(initialValue: room.sheetHeight)
        var c = SizeCard.remembered()
        let saved = mini.settings
        c.setKind(saved.kind ?? .character)  // before the sizes: choosing a kind suggests sizes afresh
        if let sizes = saved.made ?? saved.requested { c.load(sizes.asMade) }
        if group != nil { c.forSeveral() }
        _card = State(initialValue: c)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.map { "Resize All in \($0)" } ?? group.map { "Resize \($0.count) Minis" } ?? "Resize \(mini.displayName)").font(.title2.bold())
                Text(group != nil
                     ? "Remakes every mini's print file with these sizes, one after another, \(takes) each. Minis already this size are left out. The minis themselves don't change."
                     : "Remakes the print file with these sizes. \(takes.capitalizedFirst)\(model.current == nil ? "" : ", once the jobs ahead of it are done"). The \(card.kind == .object ? "object" : "character") itself doesn't change.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding([.horizontal, .top], 20)
            Form { SizeSection(card: $card, seed: nil, several: several) }
                .formStyle(.grouped)
                .reportsHeight(0, into: $forms)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                if let reason = model.requiredProblem {
                    CantStart(reason: reason)
                } else if let problem {
                    Label(problem.words, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .help(problem.detail)
                }
                Spacer()
                Button("Cancel") { model.sheet = nil }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "Resize" : "Resize All") {
                    if let group {
                        if let why = model.resizeAll(group, sizes: card.sizes, scale: card.chosenScale) { problem = (why, why) }
                    } else {
                        do { try model.resize(mini, sizes: card.sizes) } catch { problem = (model.plainWords(error), "\(error)") }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.requiredProblem != nil || (group == nil && model.waiting(mini.name) != nil))
            }
            .padding(16)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 580, height: height)
        .fitsForms($height, $forms, room: room.height)
    }

    /// What Resize All sizes each character from, said in place of its real height.
    private var several: String? {
        group.map { g in SizeCard.severalNote(without: g.filter { $0.settings.realHeight == nil }.count, of: g.count) }
    }

    private var takes: String { JobProgress.about(model.estimate(mini.name, .prep, sizes: card.sizes).total) }
}
