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

    public var isEmpty: Bool { rows.isEmpty && description == nil }

    /// `created` is when it was asked for (`Mini.created`), which a resize leaves alone.
    public init(_ s: MiniSettings, created: Date, now: Date = Date(), timeZone: TimeZone = .current) {
        var rows: [Row] = []
        func add(_ label: String, _ value: String?) { if let value { rows.append(Row(label: label, value: value)) } }
        if s.isImported { add("Source", "A 3D model you imported") }
        switch s.source {
        case .image:
            add("Source", "A picture")
        case .desc:
            add("Source", "A description")
            add("You typed", s.descOriginal.flatMap { $0.isEmpty || $0 == s.desc ? nil : $0 })
        case nil: break
        }
        add("Variation number", s.seed.map(String.init))
        // No model recorded is Pixal3D, the only one before 0.4.0, but only for a mini that has
        // settings at all: one without says nothing about how it was made.
        if !s.isImported && (s.source != nil || s.requested != nil) { add("3D model", EngineDownload.model(s.model)?.name) }
        // A description is always drawn, never sculpted, so the switch only means something for a picture.
        if s.source == .image { add("Grey sculpt", s.restyle.map { $0 ? "On" : "Off" }) }
        if s.cartoon == true { add("Cartoon", "Yes") }
        if created != .distantPast { add("Made", Mini.listDate(created, now: now, timeZone: timeZone)) }
        self.rows = rows
        description = s.source == .desc ? s.desc.flatMap { $0.isEmpty ? nil : $0 } : nil
    }
}
