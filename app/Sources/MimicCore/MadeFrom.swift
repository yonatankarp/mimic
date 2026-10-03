import Foundation

/// What a mini's page says it was made from, in its Made from section (#83): only what its
/// settings recorded, so an older mini leaves out a row rather than showing a blank one.
public struct MadeFrom: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
    }

    public let rows: [Row]
    /// The description it was drawn from, for Copy Description; nil for a picture.
    public let description: String?
    /// What was changed in its picture, as typed, oldest first (#156): what tells versions apart.
    public let fixes: [String]

    public var isEmpty: Bool { rows.isEmpty && description == nil && fixes.isEmpty }

    /// `created` is when it was asked for (`Mini.created`), which a resize leaves alone.
    public init(_ s: MiniSettings, created: Date, now: Date = Date(), timeZone: TimeZone = .current) {
        var rows: [Row] = []
        func add(_ label: String, _ value: String?) { if let value { rows.append(Row(label: label, value: value)) } }
        let source = String(localized: "Source", bundle: .mimicCore)
        if s.isImported { add(source, String(localized: "A 3D model you imported", bundle: .mimicCore)) }
        switch s.source {
        case .image:
            let sides = s.sides ?? []
            let front = String(localized: "front", bundle: .mimicCore, comment: "A picture of the front of the character")
            add(source, sides.isEmpty ? String(localized: "A picture", bundle: .mimicCore)
                : String(localized: "Pictures of the \(([front] + sides.dropLast().map(\.words)).joined(separator: ", ")) and \(sides.last!.words)",
                         bundle: .mimicCore))
        case .desc:
            add(source, String(localized: "A description", bundle: .mimicCore))
            add(String(localized: "You typed", bundle: .mimicCore), s.descOriginal.flatMap { $0.isEmpty || $0 == s.desc ? nil : $0 })
        case nil: break
        }
        add(String(localized: "Variation number", bundle: .mimicCore), s.seed.map(String.init))
        // New 3D Shape keeps the picture's number and gives the shape its own (#141), so without
        // this two versions read the same.
        add(String(localized: "3D shape number", bundle: .mimicCore), s.shapeSeed.map(String.init))
        add(String(localized: "3D model", bundle: .mimicCore), s.madeWith?.name)
        // A description is always drawn, never sculpted, so the switch only means something for a picture.
        if s.source == .image {
            add(String(localized: "Grey sculpt", bundle: .mimicCore),
                s.restyle.map { $0 ? String(localized: "On", bundle: .mimicCore) : String(localized: "Off", bundle: .mimicCore) })
        }
        if s.cartoon == true { add(String(localized: "Cartoon", bundle: .mimicCore), String(localized: "Yes", bundle: .mimicCore)) }
        if created != .distantPast { add(String(localized: "Made", bundle: .mimicCore), Mini.listDate(created, now: now, timeZone: timeZone)) }
        self.rows = rows
        description = s.source == .desc ? s.desc.flatMap { $0.isEmpty ? nil : $0 } : nil
        fixes = s.fixes ?? []
    }
}
