import AppKit
import SwiftUI
import ImageCratCore

/// Measures a docked panel against the room its group gives it: the size its SwiftUI content needs at that room
/// (`sizeThatFits` of the panel's own view, measured without the root scroller), whether its hosting view has the
/// content area's frame, and whether the root scroller holds what doesn't fit. Shared by the `panelsize` self test and
/// the `LUMEN_PANEL_TOUR` real-window tour.
enum PanelMetrics {
    struct Row {
        var panel: String
        var context: String
        /// The content area (group minus its tab bar).
        var given: CGSize
        /// What the panel's content needs when offered `given` (larger than `given` on an axis = it can't shrink to it).
        var needed: CGSize
        /// "root" (PanelContentRoot's scroller), "own" (the panel scrolls its own lists only) or "-".
        var scroll: String
        /// Size of the root scroller's document (what can be scrolled to), if there is one.
        var document: CGSize?
        /// Hosting view in its content area with the area's frame, and SwiftUI laid out at that size.
        var frameOK: Bool
        var frameNote: String

        var overflowsWidth: Bool { needed.width > given.width + 0.5 }
        var overflowsHeight: Bool { needed.height > given.height + 0.5 }
        var overflows: Bool { overflowsWidth || overflowsHeight }
        /// The part that doesn't fit can be scrolled to.
        var reachable: Bool {
            guard let d = document else { return false }
            return d.width + 1.5 >= needed.width && d.height + 1.5 >= needed.height
        }
        var verdict: String {
            if !frameOK { return "BAD FRAME" }
            if !overflows { return "fits" }
            return reachable ? (overflowsWidth ? "scrolls (h)" : "scrolls") : "CROPPED"
        }
        var ok: Bool { verdict == "fits" || verdict.hasPrefix("scrolls") }

        static let header = "panel                 context                          given        needed       scroll  verdict"
        var line: String {
            func s(_ z: CGSize) -> String { "\(Int(z.width.rounded()))×\(Int(z.height.rounded()))" }
            func pad(_ t: String, _ n: Int) -> String { t.count >= n ? t + " " : t + String(repeating: " ", count: n - t.count) }
            return pad(panel, 22) + pad(context, 33) + pad(s(given), 13) + pad(s(needed), 13) + pad(scroll, 8) + verdict + (overflows ? "  (document \(document.map(s) ?? "-"))" : "") + (frameNote.isEmpty ? "" : "  (\(frameNote))")
        }
    }

    // MARK: Measuring

    /// The panel's own content, themed as `PanelContentRoot` shows it but without the root scroller. One per panel id
    /// (its state stays at the defaults: sections collapsed, nothing typed).
    private static var probes: [String: NSHostingController<AnyView>] = [:]

    static func probe(_ id: String, width: CGFloat) -> NSHostingController<AnyView> {
        let v = AnyView(PanelContentRoot.panel(id).environment(\.panelWidth, width).environment(\.colorScheme, Theme.colorScheme).font(Theme.font))
        if let p = probes[id] { p.rootView = v; return p }
        let p = NSHostingController(rootView: v)
        p.sizingOptions = []
        probes[id] = p
        return p
    }

    static func resetProbes() { probes = [:] }

    /// Size the content takes when offered `size` (SwiftUI reports more than it was offered when it can't shrink).
    static func needed(_ id: String, in size: CGSize) -> CGSize {
        let r = probe(id, width: size.width).sizeThatFits(in: size)
        return CGSize(width: r.width.isFinite ? r.width : 0, height: r.height.isFinite ? r.height : 0)
    }

    /// The smallest height the content can take at `width` (and the width it then needs).
    static func minimum(_ id: String, width: CGFloat) -> CGSize { needed(id, in: CGSize(width: width, height: 1)) }

    /// The scroller `PanelContentRoot` puts around a panel: the scroll view filling the hosting view.
    static func rootScroller(_ host: NSView) -> NSScrollView? {
        var best: NSScrollView?
        func walk(_ v: NSView, depth: Int) {
            guard depth < 8, best == nil else { return }
            for s in v.subviews {
                if let sv = s as? NSScrollView {
                    let f = host.convert(sv.bounds, from: sv)
                    if abs(f.width - host.bounds.width) < 1.5 && abs(f.height - host.bounds.height) < 1.5 { best = sv; return }
                }
                walk(s, depth: depth + 1)
            }
        }
        walk(host, depth: 0)
        return best
    }

    static func hasScrollView(_ host: NSView) -> Bool { Workspace2SelfTest.find(NSScrollView.self, in: host).contains { !$0.isHiddenOrHasHiddenAncestor } }

    /// Problems with where a content area and its hosting view are (empty means fine).
    static func frameProblems(_ cv: DockContentView) -> String {
        guard !cv.isHidden else { return "" }
        var out: [String] = []
        if cv.bounds.width < 1 || cv.bounds.height < 1 { out.append("content area \(Int(cv.bounds.width))×\(Int(cv.bounds.height))") }
        let hosts = cv.subviews.filter { $0 is NSHostingView<PanelContentRoot> }
        if hosts.count > 1 { out.append("\(hosts.count) hosting views") }
        guard let h = cv.hosted else { return out.joined(separator: ", ") }
        if h.superview !== cv { out.append("host not in its content area") }
        if !h.frame.equalTo(cv.bounds, tolerance: 0.5) { out.append("host \(fmt(h.frame)) ≠ area \(fmt(cv.bounds))") }
        if let r = rootScroller(h) {
            let f = h.convert(r.bounds, from: r)
            if !f.equalTo(h.bounds, tolerance: 1) { out.append("SwiftUI laid out at \(fmt(f))") }
        } else if let first = h.subviews.first(where: { !$0.isHidden }), PanelContentRoot.scrolls {
            out.append("no root scroller (first subview \(type(of: first)) \(fmt(first.frame)))")
        }
        return out.joined(separator: ", ")
    }

    static func fmt(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))" }

    /// Measures panel `id` shown in content area `cv`.
    static func measure(_ id: String, in cv: DockContentView, context: String) -> Row {
        let given = cv.bounds.size
        let host = WorkspaceManager.shared.host(id)
        let need = needed(id, in: given)
        let root = rootScroller(host)
        let doc = root.flatMap { $0.documentView?.frame.size }
        let problems = frameProblems(cv) + (cv.hosted === host ? "" : " (another panel shown)")
        return Row(panel: id, context: context, given: given, needed: need, scroll: root != nil ? "root" : hasScrollView(host) ? "own" : "-",
                   document: doc, frameOK: problems.trimmingCharacters(in: .whitespaces).isEmpty, frameNote: problems.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Focus rings

    /// Focusable AppKit controls, fully visible in the panel, whose focus ring would be cut by its left, right or bottom
    /// edge (the root scroller clips there; the top edge is under the tab bar, which covers a ring there anyway).
    /// Controls inside a panel's own scrolling list are left out: that list clips them, as it always did.
    static func focusRingsCut(_ host: NSView) -> [String] {
        var out: [String] = []
        guard let clip = rootScroller(host)?.contentView else { return [] }
        let vis = clip.bounds
        for c in Workspace2SelfTest.find(NSControl.self, in: host) where !(c is NSScroller) && !c.isHiddenOrHasHiddenAncestor && c.focusRingType != .none && c.acceptsFirstResponder {
            guard c.isDescendant(of: clip) else { continue }
            // the ring is drawn about 3 pt around the control's focus-ring mask (its bezel)
            let mask = clip.convert(c.focusRingMaskBounds.isEmpty ? c.bounds : c.focusRingMaskBounds, from: c)
            // (controls in a panel's own scrolling list are clipped by that list, as they always were)
            guard c.enclosingScrollView === rootScroller(host), vis.insetBy(dx: -0.5, dy: -0.5).contains(mask) else { continue }
            let ring = mask.insetBy(dx: -3, dy: -3)
            if ring.minX < vis.minX - 0.5 || ring.maxX > vis.maxX + 0.5 || ring.maxY > vis.maxY + 0.5 {
                out.append("\(type(of: c)) ring \(fmt(ring)) in \(fmt(vis))")
            }
        }
        return out
    }

    // MARK: Pictures

    /// A view of an offscreen window drawn through its layer tree (what SwiftUI shows) — small windows only.
    static func snapshot(_ v: NSView, to url: URL) {
        v.window?.displayIfNeeded()
        let scale = v.window?.backingScaleFactor ?? 2
        let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
        guard let layer = v.layer, w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `cacheDisplay` capture (what AppKit draws for a view of an on-screen window).
    static func capture(_ v: NSView, to url: URL) {
        guard v.bounds.width >= 1, v.bounds.height >= 1, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    static func fileName(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}
