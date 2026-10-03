import SwiftUI

/// What a sheet's side-by-side forms need, for `fitsForms`: each one's content height, and the
/// height they're shown at (the same for all of them).
struct FormHeights: Equatable {
    var content: [CGFloat]
    var shown: CGFloat = 0
    /// The sheet's height around the forms (title and buttons), taken from the first report.
    var chrome: CGFloat?
    init(columns: Int) { content = Array(repeating: 0, count: columns) }
}

extension CGSize {
    /// The size of a big sheet (New Mini, Resize, Import, Compare) in a main window with this
    /// room under its toolbar: up to 1080 × 720, the starting height before `fitsForms` fits it.
    var sheetWidth: CGFloat { min(1080, width - 40) }
    var sheetHeight: CGFloat { min(720, height - 8) }
}

extension View {
    /// Keeps `forms` up to date with this form, column `column` of them.
    func reportsHeight(_ column: Int, into forms: Binding<FormHeights>) -> some View {
        onScrollGeometryChange(for: CGSize.self) { CGSize(width: $0.contentSize.height, height: $0.containerSize.height) } action: { _, g in
            forms.wrappedValue.content[column] = g.width
            forms.wrappedValue.shown = g.height
        }
    }

    /// Makes `height` fit the sheet's tallest form without scrolling, as far as `room` (the main
    /// window's height under its toolbar) allows; a smaller window scrolls the rest. Worked out
    /// from the content, which doesn't change with the sheet's height: the forms' own height
    /// lags a resize, and following it overshot.
    func fitsForms(_ height: Binding<CGFloat>, _ forms: Binding<FormHeights>, room: CGFloat) -> some View {
        onChange(of: forms.wrappedValue, initial: true) { _, f in
            guard f.shown > 0, !f.content.contains(0), let tallest = f.content.max() else { return }  // all reported
            let chrome = f.chrome ?? height.wrappedValue - f.shown
            if f.chrome == nil { forms.wrappedValue.chrome = chrome }
            let fitted = min((chrome + tallest).rounded(.up), room - 8)
            if abs(fitted - height.wrappedValue) >= 1 { height.wrappedValue = fitted }
        }
    }
}
