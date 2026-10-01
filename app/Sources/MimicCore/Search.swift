import Foundation

/// How the list is ordered: by when each mini was asked for (newest first, as always), by the
/// name it's shown with (A to Z) or by its height (tallest first).
public enum GallerySort: String, CaseIterable, Sendable {
    case made, name, size
}

/// Which minis the list shows.
public enum GalleryShow: String, CaseIterable, Sendable {
    case all, characters, objects, unfinished

    public func includes(_ mini: Mini) -> Bool {
        switch self {
        case .all: true
        case .characters: !mini.settings.isObject
        case .objects: mini.settings.isObject
        case .unfinished: !mini.finished
        }
    }
}

extension Gallery {
    /// The search field only appears past this many minis; a handful needs no searching.
    public static let searchAfter = 6

    /// The minis whose shown name or description contains the query, in the gallery's order,
    /// ignoring capitals and accents ("elodie" finds "Élodie"). With the field hidden (six or fewer) the query is ignored, so a leftover search can't hide anything.
    public static func search(_ minis: [Mini], _ query: String) -> [Mini] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard minis.count > searchAfter, !q.isEmpty else { return minis }
        return minis.filter { mini in
            [mini.displayName, mini.settings.desc, mini.settings.descOriginal].contains { $0?.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// What the list shows: searched, filtered, then sorted. Everything comes from what the
    /// gallery read on its reload (`Mini.settings`, `Mini.finished`), never from disk.
    public static func arrange(_ minis: [Mini], query: String, show: GalleryShow, sort: GallerySort) -> [Mini] {
        sorted(search(minis, query).filter(show.includes), by: sort)
    }

    /// Whether anything may be hidden: a search in the field, or a filter. Every project is
    /// open then and the ones with nothing to show are left out.
    public static func narrowed(_ minis: [Mini], query: String, show: GalleryShow) -> Bool {
        show != .all || (minis.count > searchAfter && !query.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Ties, and minis with no size, go newest first after the rest.
    public static func sorted(_ minis: [Mini], by sort: GallerySort) -> [Mini] {
        let newest = minis.sorted { $0.created > $1.created }
        switch sort {
        case .made:
            return newest
        case .name:
            // The name as shown, so it stays right whatever the list shows as a name.
            let names = newest.map(\.displayName)
            return zip(newest, names).enumerated().sorted { a, b in
                switch a.element.1.localizedStandardCompare(b.element.1) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: a.offset < b.offset
                }
            }.map(\.element.0)
        case .size:
            let heights = newest.map(height)
            return zip(newest, heights).enumerated().sorted { a, b in
                switch (a.element.1, b.element.1) {
                case let (x?, y?) where x != y: x > y
                case (_?, nil): true
                case (nil, _?): false
                default: a.offset < b.offset
                }
            }.map(\.element.0)
        }
    }

    /// Its height in millimetres: as made, else as asked for. The default 32 when those sizes
    /// leave it out, as the list says; nil for a mini from before sizes were kept.
    static func height(_ mini: Mini) -> Double? {
        guard let sizes = mini.settings.made ?? mini.settings.requested else { return nil }
        return sizes.height.flatMap(Double.init).flatMap { $0 == 0 ? nil : $0 } ?? 32
    }

    /// The selection with what the list no longer shows taken out, so nothing hidden by a search
    /// or filter is moved, resized or trashed with what's selected.
    public static func visible(_ selection: Set<String>, in shown: [Mini]) -> Set<String> {
        selection.intersection(shown.map(\.id))
    }

    /// The selection once the list shows `shown`: what of it is still shown, else the list's
    /// first mini, never one a search or filter hides. Empty when the list shows none.
    public static func keeping(_ selection: Set<String>, in shown: [Mini]) -> Set<String> {
        let kept = visible(selection, in: shown)
        return kept.isEmpty ? Set(shown.prefix(1).map(\.id)) : kept
    }
}
