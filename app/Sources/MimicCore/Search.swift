import Foundation

extension Gallery {
    /// The search field only appears past this many minis; a handful needs no searching.
    public static let searchAfter = 6

    /// The minis whose shown name contains the query, in the gallery's order. With the field
    /// hidden (six or fewer) the query is ignored, so a leftover search can't hide anything.
    public static func search(_ minis: [Mini], _ query: String) -> [Mini] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard minis.count > searchAfter, !q.isEmpty else { return minis }
        return minis.filter { $0.displayName.localizedCaseInsensitiveContains(q) }
    }
}
