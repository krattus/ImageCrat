import AppKit
import SwiftUI
import ImageCratCore

// Panel content against the room the dock gives it: groups can be short, columns as narrow as
// `DockMetrics.minColumnWidth`, floating windows and icon-column pop-overs small. `PanelContentRoot` puts every panel in
// a `PanelScroller`, so content that can't shrink to its group is scrolled to rather than cut off; `WrappingHStack` and
// `segmentedOrMenu()` let rows of controls fit narrow columns in the first place.

/// The width a panel is shown at (its group's width); infinite outside panels (dialogs, the options bar), so views that
/// switch to a compact layout in narrow columns keep their usual one there.
extension EnvironmentValues {
    @Entry var panelWidth: CGFloat = .infinity
}

/// A panel at exactly the size of its group — or, when its content can't shrink that far (a short group, a narrow column,
/// a small floating window or pop-over), at the size it needs, scrolled, so nothing is cut off. Content that fits (also
/// panels that scroll their own lists) is laid out exactly as before, and the scroller then neither scrolls nor bounces.
/// (The scroller clips at the panel's edges; no focusable control sits close enough to an edge for its focus ring to
/// be cut — the `panelsize` self test checks.)
struct PanelScroller<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        GeometryReader { g in
            ScrollView([.vertical, .horizontal]) {
                PanelFitLayout(viewport: g.size) { content }
                    .environment(\.panelWidth, g.size.width)
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.vertical, .horizontal])
        }
    }
}

/// Offers the panel the visible size; takes more (what the panel reports it needs) only on an axis where it can't shrink
/// to it. Narrower content stays centred, as panels always were; wider content starts at the leading edge.
struct PanelFitLayout: Layout {
    var viewport: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return viewport }
        let need = s.sizeThatFits(ProposedViewSize(viewport))
        return CGSize(width: max(viewport.width, need.width.isFinite ? need.width : 0), height: max(viewport.height, need.height.isFinite ? need.height : 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let s = subviews.first else { return }
        let p = ProposedViewSize(bounds.size)
        let size = s.sizeThatFits(p)
        let x = size.width.isFinite && size.width < bounds.width ? (bounds.width - size.width) / 2 : 0
        s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading, proposal: p)
    }
}

/// An `HStack` that wraps: laid out like an `HStack` (same spacing, the least flexible views sized first) when its views
/// fit the width it is offered, otherwise they flow onto further rows, leading-aligned (buttons, toggles and icon rows
/// in narrow panel columns). A view needs its ideal width, or — when it stretches (sliders, text fields, spacers) — its
/// smallest width.
struct WrappingHStack: Layout {
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    var lineSpacing: CGFloat = 6

    private struct Row {
        var range: Range<Int>
        var widths: [CGFloat]
        var heights: [CGFloat]
        var size: CGSize
    }

    private func need(_ s: LayoutSubview) -> CGFloat {
        let ideal = s.sizeThatFits(.unspecified).width
        let wide = s.sizeThatFits(ProposedViewSize(width: 10_000, height: nil)).width
        return wide > ideal + 1 ? s.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width : ideal
    }

    private func gap(_ subviews: Subviews, _ i: Int) -> CGFloat {
        spacing ?? subviews[i - 1].spacing.distance(to: subviews[i].spacing, along: .horizontal)
    }

    /// Index ranges of the rows the views take at `width` (one row when they fit, or the width is unknown).
    private func lines(_ width: CGFloat?, _ subviews: Subviews) -> [Range<Int>] {
        guard !subviews.isEmpty else { return [] }
        guard let width, width.isFinite, subviews.count > 1 else { return [subviews.startIndex..<subviews.endIndex] }
        var out: [Range<Int>] = []
        var start = subviews.startIndex
        var x: CGFloat = 0
        for i in subviews.indices {
            let n = need(subviews[i])
            if i == start { x = n; continue }
            let add = gap(subviews, i) + n
            if x + add > width + 0.5 {
                out.append(start..<i)
                start = i
                x = n
            } else {
                x += add
            }
        }
        out.append(start..<subviews.endIndex)
        return out
    }

    /// One row as an HStack lays it out: views that don't stretch (labels, buttons) get their ideal width, the
    /// stretching ones share what is left, least flexible first. (A row too narrow even for that — one view wider than
    /// the panel — shares the width out among all its views.)
    private func row(_ r: Range<Int>, _ subviews: Subviews, width: CGFloat?) -> Row {
        let gaps = r.dropFirst().reduce(CGFloat(0)) { $0 + gap(subviews, $1) }
        var widths = [CGFloat](repeating: 0, count: r.count)
        if let width, width.isFinite {
            let avail = max(0, width - gaps)
            let ideal = r.map { subviews[$0].sizeThatFits(.unspecified).width }
            let lo = r.map { subviews[$0].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width }
            let hi = r.map { subviews[$0].sizeThatFits(ProposedViewSize(width: 10_000, height: nil)).width }
            let ks = Array(0..<r.count)   // (positions in this row)
            let rigid = ks.map { hi[$0] <= ideal[$0] + 1 }
            let rigidSum = ks.filter { rigid[$0] }.reduce(CGFloat(0)) { $0 + ideal[$1] }
            let flexMin = ks.filter { !rigid[$0] }.reduce(CGFloat(0)) { $0 + lo[$1] }
            let fits = rigidSum + flexMin <= avail + 0.5
            var pool = fits ? ks.filter { !rigid[$0] } : ks
            if fits { for k in ks where rigid[k] { widths[k] = ideal[k] } }
            pool.sort { hi[$0] - lo[$0] < hi[$1] - lo[$1] }
            var remaining = fits ? max(0, avail - rigidSum) : avail
            for (n, k) in pool.enumerated() {
                let share = remaining / CGFloat(pool.count - n)
                let w = subviews[r.lowerBound + k].sizeThatFits(ProposedViewSize(width: share, height: nil)).width
                widths[k] = w
                remaining = max(0, remaining - w)
            }
        } else {
            for i in r { widths[i - r.lowerBound] = subviews[i].sizeThatFits(.unspecified).width }
        }
        let heights = r.map { subviews[$0].sizeThatFits(ProposedViewSize(width: widths[$0 - r.lowerBound], height: nil)).height }
        return Row(range: r, widths: widths, heights: heights, size: CGSize(width: widths.reduce(0, +) + gaps, height: heights.max() ?? 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = lines(proposal.width, subviews).map { row($0, subviews, width: proposal.width) }
        let h = rows.reduce(CGFloat(0)) { $0 + $1.size.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: rows.map(\.size.width).max() ?? 0, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for l in lines(bounds.width, subviews) {
            let r = row(l, subviews, width: bounds.width)
            var x = bounds.minX
            for i in l {
                let k = i - l.lowerBound
                if i > l.lowerBound { x += gap(subviews, i) }
                let dy = alignment == .top ? 0 : alignment == .bottom ? r.size.height - r.heights[k] : (r.size.height - r.heights[k]) / 2
                subviews[i].place(at: CGPoint(x: x, y: y + dy), anchor: .topLeading, proposal: ProposedViewSize(width: r.widths[k], height: r.heights[k]))
                x += r.widths[k]
            }
            y += r.size.height + lineSpacing
        }
    }
}

extension View {
    /// A segmented picker where its segments fit the width offered, a pop-up menu where they don't (segments can't
    /// shrink: in a narrow panel column they would be cut off).
    func segmentedOrMenu() -> some View {
        ViewThatFits(in: .horizontal) {
            pickerStyle(.segmented)
            pickerStyle(.menu)
        }
    }
}

/// Sizes for a panel's own window or pop-over, from what its content needs.
enum PanelSizing {
    /// The size panel `id` takes at `width`: `height` is its natural height when its content has one (a column of
    /// controls), nil when it takes whatever height it gets (lists that scroll); `width` is more than asked when it can't
    /// be that narrow.
    static func natural(_ id: String, width: CGFloat) -> (width: CGFloat, height: CGFloat?) {
        let big: CGFloat = 20000
        let h = NSHostingController(rootView: PanelContentRoot.panel(id).environment(\.panelWidth, width).environment(\.colorScheme, Theme.colorScheme).font(Theme.font))
        h.sizingOptions = []
        let tall = h.sizeThatFits(in: CGSize(width: width, height: big))
        let w = tall.width.isFinite ? max(width, tall.width) : width
        return (w, tall.height.isFinite && tall.height < big - 1 ? tall.height : nil)
    }

    /// A window (or pop-over) content size for panel `id`, starting from `base`: wide enough for the content (up to the
    /// widest column), as tall as its natural height plus the tab bar (within `minHeight`…`maxHeight`), or `base.height`
    /// for list panels.
    static func windowSize(_ id: String, base: CGSize, minHeight: CGFloat, maxHeight: CGFloat) -> CGSize {
        let n = natural(id, width: base.width)
        let w = min(max(base.width, n.width), DockMetrics.maxColumnWidth)
        let h = n.height.map { $0 + DockMetrics.tabBarHeight } ?? base.height
        return CGSize(width: w.rounded(.up), height: min(max(h.rounded(.up), minHeight), max(minHeight, maxHeight)))
    }
}
