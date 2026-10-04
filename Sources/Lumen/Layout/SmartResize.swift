import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Formats

struct SocialFormat: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var width: Int
    var height: Int

    var size: CGSize { CGSize(width: width, height: height) }
    var label: String { "\(name)  \(width) × \(height)" }

    static let all: [SocialFormat] = [
        SocialFormat(id: "igPost", name: "Instagram Post", width: 1080, height: 1080),
        SocialFormat(id: "igPortrait", name: "Instagram Portrait", width: 1080, height: 1350),
        SocialFormat(id: "story", name: "Story / Reel / TikTok", width: 1080, height: 1920),
        SocialFormat(id: "ytThumb", name: "YouTube Thumbnail", width: 1280, height: 720),
        SocialFormat(id: "xPost", name: "X / Twitter Post", width: 1600, height: 900),
        SocialFormat(id: "fbCover", name: "Facebook Cover", width: 1640, height: 624),
        SocialFormat(id: "fbPost", name: "Facebook Post", width: 1200, height: 630),
        SocialFormat(id: "liPost", name: "LinkedIn Post", width: 1200, height: 627),
        SocialFormat(id: "liBanner", name: "LinkedIn Banner", width: 1584, height: 396),
        SocialFormat(id: "pin", name: "Pinterest Pin", width: 1000, height: 1500),
    ]
}

struct SmartResizeOptions: Equatable {
    /// Smallest type size (px) in the adapted design; type is enlarged up to this when there is room.
    var minTextSize: Double = 24
    /// Breathing room kept between type / small elements and the edge, as a fraction of the shorter side.
    var padding: Double = 0.04
    /// Instead of cropping a photo background, keep all of it and fill the missing bands with Content-Aware Fill (small gaps only).
    var extendBackground = false
    /// Largest share of the target that may be invented by Content-Aware Fill.
    var maxExtend: Double = 0.3
    /// Keep type and small elements out of the areas the platform covers with its own UI (stories / reels).
    var respectSafeZones = true
}

/// Smart Resize: one design → many sizes. Every target format becomes an artboard holding an adapted copy of the design.
enum SmartResize {
    enum Role: Equatable { case background, text, subject, element }

    private static func isBackground(_ l: Layer, _ b: CGRect?, _ s: CGRect) -> Bool {
        if l.isFill { return true }
        guard let b else { return false }
        let inter = b.intersection(s)
        return !inter.isNull && inter.width * inter.height >= 0.85 * s.width * s.height
    }

    /// What each top-level layer of the design is: background (fills the design), type, the main subject
    /// (largest remaining layer; the topmost wins a tie) or a smaller element.
    static func roles(_ layers: [Layer], source s: CGRect, state st: DocumentState) -> [UUID: Role] {
        var out: [UUID: Role] = [:]
        var best: (id: UUID, area: CGFloat)?
        for l in layers {
            let b = Compositor.shared.contentBounds(l, state: st)
            if l.isAdjustment { continue }
            if isBackground(l, b, s) { out[l.id] = .background; continue }
            if l.isText { out[l.id] = .text; continue }
            out[l.id] = .element
            if let b, l.isVisible {
                let a = b.intersection(s).width * b.intersection(s).height
                if best == nil || a >= best!.area { best = (l.id, a) }     // later = higher in the stack
            }
        }
        if let b = best, b.area >= 0.02 * s.width * s.height { out[b.id] = .subject }
        return out
    }

    private enum Anchor { case start, center, end }

    private static func anchor(_ lo: CGFloat, _ hi: CGFloat, in a: CGFloat, _ b: CGFloat) -> Anchor {
        let mid = (lo + hi) / 2, c = (a + b) / 2
        if abs(mid - c) < 0.06 * (b - a) { return .center }
        return (lo - a) <= (b - hi) ? .start : .end
    }

    /// New origin along one axis for a span of length `len` (already scaled by `k`).
    private static func position(_ anchor: Anchor, lo: CGFloat, hi: CGFloat, len: CGFloat, k: CGFloat, from a: CGFloat, _ b: CGFloat, to c: CGFloat, _ d: CGFloat, pad: CGFloat) -> CGFloat {
        switch anchor {
        case .center: return c + (d - c) * (((lo + hi) / 2 - a) / (b - a)) - len / 2
        case .start: return c + max(min(pad, lo - a), (lo - a) * k)
        case .end: return d - max(min(pad, b - hi), (b - hi) * k) - len
        }
    }

    private static func clampInside(_ r: CGRect, _ box: CGRect) -> CGRect {
        var o = r
        if o.width <= box.width { o.origin.x = min(max(o.minX, box.minX), box.maxX - o.width) } else { o.origin.x = box.midX - o.width / 2 }
        if o.height <= box.height { o.origin.y = min(max(o.minY, box.minY), box.maxY - o.height) } else { o.origin.y = box.midY - o.height / 2 }
        return o
    }

    /// Where each layer's bounds go when the design is adapted from `s` to `d` (nil = leave as is).
    static func targets(_ layers: [Layer], from s: CGRect, to d: CGRect, state st: DocumentState, options o: SmartResizeOptions) -> [UUID: CGRect] {
        let role = roles(layers, source: s, state: st)
        let rw = d.width / s.width, rh = d.height / s.height
        let fit = min(rw, rh), fill = max(rw, rh)
        let mean = max(fit, min(fill, sqrt(rw * rh)))
        let pad = CGFloat(o.padding) * min(d.width, d.height)
        // stories and reels: the top and bottom bars belong to the platform
        let zone = o.respectSafeZones && SafeZones.resolve(.auto, size: d.size) == .story ? SafeZones.safeRect(.story, in: d) : d
        let safe = zone.insetBy(dx: pad, dy: pad)
        var out: [UUID: CGRect] = [:]
        var bounds: [UUID: CGRect] = [:]
        for l in layers {
            guard let b = Compositor.shared.contentBounds(l, state: st), b.width > 0, b.height > 0, let r = role[l.id] else { continue }
            bounds[l.id] = b
            if let c = l.constraints {            // explicit constraints win over the automatic rules
                var t = c.frame(for: b, from: s, to: d)
                if l.isText, t.size != b.size {
                    let k = min(t.width / b.width, t.height / b.height)
                    t = CGRect(x: t.midX - b.width * k / 2, y: t.midY - b.height * k / 2, width: b.width * k, height: b.height * k)
                }
                out[l.id] = t
                continue
            }
            let inside = s.insetBy(dx: -1, dy: -1).contains(b)
            switch r {
            case .background:
                // scale to fill, keeping the same point of the picture in the middle
                let c = CGPoint(x: d.midX + (b.midX - s.midX) * fill, y: d.midY + (b.midY - s.midY) * fill)
                out[l.id] = CGRect(x: c.x - b.width * fill / 2, y: c.y - b.height * fill / 2, width: b.width * fill, height: b.height * fill)
            case .text:
                var k = mean
                if let t = l.text {
                    let size = SelectSimilar.fontSize(t)
                    if size > 0, size * Double(k) < o.minTextSize { k = CGFloat(o.minTextSize / size) }
                }
                k = min(k, safe.width / b.width, safe.height / b.height)      // staying inside beats everything else
                let w = b.width * k, h = b.height * k
                let ax = anchor(b.minX, b.maxX, in: s.minX, s.maxX), ay = anchor(b.minY, b.maxY, in: s.minY, s.maxY)
                let x = position(ax, lo: b.minX, hi: b.maxX, len: w, k: k, from: s.minX, s.maxX, to: d.minX, d.maxX, pad: pad)
                let y = position(ay, lo: b.minY, hi: b.maxY, len: h, k: k, from: s.minY, s.maxY, to: d.minY, d.maxY, pad: pad)
                out[l.id] = clampInside(CGRect(x: x, y: y, width: w, height: h), safe)
            case .subject:
                var k = mean
                if inside { k = min(k, d.width / b.width, d.height / b.height) }
                let c = CGPoint(x: d.minX + (b.midX - s.minX) * rw, y: d.minY + (b.midY - s.minY) * rh)
                var t = CGRect(x: c.x - b.width * k / 2, y: c.y - b.height * k / 2, width: b.width * k, height: b.height * k)
                if inside { t = clampInside(t, d) }
                out[l.id] = t
            case .element:
                var k = mean
                if inside { k = min(k, safe.width / b.width, safe.height / b.height) }
                let w = b.width * k, h = b.height * k
                let ax = anchor(b.minX, b.maxX, in: s.minX, s.maxX), ay = anchor(b.minY, b.maxY, in: s.minY, s.maxY)
                let x = position(ax, lo: b.minX, hi: b.maxX, len: w, k: k, from: s.minX, s.maxX, to: d.minX, d.maxX, pad: pad)
                let y = position(ay, lo: b.minY, hi: b.maxY, len: h, k: k, from: s.minY, s.maxY, to: d.minY, d.maxY, pad: pad)
                var t = CGRect(x: x, y: y, width: w, height: h)
                if inside { t = clampInside(t, zone == d ? d : safe) }
                out[l.id] = t
            }
        }
        // type that was clear of the subject should stay clear of it
        if let sid = role.first(where: { $0.value == .subject })?.key, let sb = bounds[sid], var st1 = out[sid] {
            for l in layers where role[l.id] == .text && l.constraints == nil {
                guard let tb = bounds[l.id], var t = out[l.id], !tb.intersects(sb), t.intersects(st1) else { continue }
                let gap = pad / 2
                let above = tb.midY < sb.midY
                // first move the type, then (if it hit the edge) the subject
                t.origin.y = above ? st1.minY - gap - t.height : st1.maxY + gap
                t = clampInside(t, safe)
                if t.intersects(st1) {
                    st1.origin.y = above ? t.maxY + gap : t.minY - gap - st1.height
                    st1 = clampInside(st1, d)
                }
                if t.intersects(st1) {
                    // still no room: shrink the subject into what is left
                    let room = above ? d.maxY - (t.maxY + gap) : (t.minY - gap) - d.minY
                    if room > 40, room < st1.height {
                        let k = room / st1.height
                        let w = st1.width * k
                        st1 = CGRect(x: st1.midX - w / 2, y: above ? t.maxY + gap : d.minY, width: w, height: room)
                    }
                }
                out[l.id] = t
                out[sid] = st1
            }
        }
        return out
    }

    /// Longest side (px) of the copy Content-Aware Fill works on when extending a background.
    static var fillSize: CGFloat = 640

    /// Keeps the whole picture and invents the missing bands with Content-Aware Fill. nil when the gap is too large (or nothing is missing).
    static func extendedBackground(_ l: Layer, bounds b: CGRect, from s: CGRect, to d: CGRect, state st: DocumentState, options o: SmartResizeOptions) -> Layer? {
        guard l.isRaster, l.mask == nil, b.insetBy(dx: -1, dy: -1).contains(s) else { return nil }
        let fit = min(d.width / s.width, d.height / s.height)
        let covered = CGRect(x: d.midX - s.width * fit / 2, y: d.midY - s.height * fit / 2, width: s.width * fit, height: s.height * fit).integral
        let missing = 1 - (covered.width * covered.height) / (d.width * d.height)
        guard missing > 0.005, missing <= CGFloat(o.maxExtend) else { return nil }
        let sp = CanvasSpace(width: st.width, height: st.height)
        // the design area scaled to fit, rendered into a target-sized buffer
        let placed = LayerTransformer.apply(Homography(affine: LayoutGeom.map(s, to: covered)), to: l, space: sp)
        guard let img = Compositor.shared.contentImage(placed, space: sp) else { return nil }
        let dr = IRect(enclosing: d)
        var buf = RenderEngine.renderBuffer(img.cropped(to: sp.ciRect(covered)), docRect: dr, space: sp)
        let local = covered.offsetBy(dx: -d.minX, dy: -d.minY)
        // Content-Aware Fill works on a copy of at most `fillSize` px (the invented bands are soft anyway), then the bands are scaled back up
        let f = min(1, fillSize / CGFloat(max(dr.width, dr.height)))
        let sw = max(8, Int((CGFloat(dr.width) * f).rounded())), sh = max(8, Int((CGFloat(dr.height) * f).rounded()))
        var work = buf
        if f < 1 {
            work = PixelBuffer(width: sw, height: sh)
            work.drawImage(buf.makeCGImage(), in: CGRect(x: 0, y: 0, width: sw, height: sh))
            work.markDirty()
        }
        let kx = CGFloat(sw) / CGFloat(dr.width), ky = CGFloat(sh) / CGFloat(dr.height)
        // real picture in the working copy (shrunk by a pixel so half-covered edge pixels count as missing)
        let real = CGRect(x: ceil(local.minX * kx), y: ceil(local.minY * ky), width: floor(local.maxX * kx) - ceil(local.minX * kx), height: floor(local.maxY * ky) - ceil(local.minY * ky))
        // one band at a time, each together with just the strip of real picture next to it (keeps the fill local and quick)
        func fill(_ band: IRect, context: IRect) {
            guard !band.isEmpty, !context.isEmpty else { return }
            let region = band.union(context)
            let piece = work.cropped(to: region)
            let hole = SelectionOps.rectMask(band.offsetBy(dx: -region.x, dy: -region.y).cgRect, width: region.width, height: region.height)
            let done = Inpainter.inpaint(piece, hole: hole)
            let target = work.copy()
            target.copyPixels(from: done, at: IPoint(x: region.x, y: region.y))
            target.markDirty()
            work = target
        }
        let rx0 = Int(real.minX), rx1 = Int(real.maxX), ry0 = Int(real.minY), ry1 = Int(real.maxY)
        let reachX = max(48, 3 * max(rx0, sw - rx1)), reachY = max(48, 3 * max(ry0, sh - ry1))
        fill(IRect(x: 0, y: 0, width: rx0, height: sh), context: IRect(x: rx0, y: 0, width: min(reachX, rx1 - rx0), height: sh))
        fill(IRect(x: rx1, y: 0, width: sw - rx1, height: sh), context: IRect(x: max(rx0, rx1 - reachX), y: 0, width: min(reachX, rx1 - rx0), height: sh))
        fill(IRect(x: 0, y: 0, width: sw, height: ry0), context: IRect(x: 0, y: ry0, width: sw, height: min(reachY, ry1 - ry0)))
        fill(IRect(x: 0, y: ry1, width: sw, height: sh - ry1), context: IRect(x: 0, y: max(ry0, ry1 - reachY), width: sw, height: min(reachY, ry1 - ry0)))
        if f < 1 {
            // invented bands underneath, the sharp original on top
            let merged = PixelBuffer(width: dr.width, height: dr.height)
            merged.drawImage(work.makeCGImage(), in: CGRect(x: 0, y: 0, width: dr.width, height: dr.height))
            merged.drawImage(buf.makeCGImage(), in: CGRect(x: 0, y: 0, width: dr.width, height: dr.height))
            merged.markDirty()
            buf = merged
        } else {
            buf = work
        }
        var out = l
        out.content = .raster(RasterContent(buffer: buf, origin: dr.origin))
        return out
    }

    /// Adapted copies of `layers` (a design occupying `s`) for the area `d`. Ids are new.
    static func adapt(_ layers: [Layer], from s: CGRect, to d: CGRect, state st: DocumentState, options o: SmartResizeOptions = SmartResizeOptions()) -> [Layer] {
        let sp = CanvasSpace(width: st.width, height: st.height)
        let tg = targets(layers, from: s, to: d, state: st, options: o)
        let role = roles(layers, source: s, state: st)
        let fill = max(d.width / s.width, d.height / s.height)
        let cover = CGAffineTransform(translationX: -s.midX, y: -s.midY).concatenating(CGAffineTransform(scaleX: fill, y: fill))
            .concatenating(CGAffineTransform(translationX: d.midX, y: d.midY))
        return layers.map { l in
            var copy = l.duplicated()
            guard let b = Compositor.shared.contentBounds(l, state: st), let t = tg[l.id] else {
                // adjustment layers and empty layers just follow the design (their masks scale with it)
                return LayoutGeom.transformed(copy, cover, space: sp, document: true)
            }
            if l.isFill {
                return LayoutGeom.transformed(copy, cover, space: sp, document: true)
            }
            if role[l.id] == .background, l.constraints == nil, o.extendBackground,
               let ext = extendedBackground(copy, bounds: b, from: s, to: d, state: st, options: o) {
                return ext
            }
            let k = Double(sqrt((t.width / b.width) * (t.height / b.height)))
            copy = LayoutGeom.transformed(copy, LayoutGeom.map(b, to: t), space: sp, scaleEffects: abs(k - 1) > 0.01 ? k : nil, document: true)
            return copy
        }
    }

    /// The design to adapt: the active artboard, the first artboard, or (when there are none) the whole canvas.
    static func source(_ d: Document) -> (layers: [Layer], rect: CGRect, artboard: Layer?) {
        if let ab = Collage.activeArtboard(d, d.state) ?? AppActions.artboards(d).first, let r = ab.artboard?.rect {
            return (ab.children, r, ab)
        }
        return (d.state.layers, d.state.canvasCGRect, nil)
    }

    /// Creates one artboard per format next to the design. Returns the new artboard ids (one history step).
    @discardableResult
    static func run(_ d: Document, formats: [SocialFormat], options o: SmartResizeOptions = SmartResizeOptions()) -> [UUID] {
        guard !formats.isEmpty else { return [] }
        // without artboards the current design becomes the first one, so it sits beside its variants
        if AppActions.artboards(d).isEmpty {
            var orig = Layer(name: "Original", content: .group(GroupContent(children: d.state.layers, isExpanded: false, artboard: Artboard(rect: d.state.canvasCGRect, background: nil))))
            orig.blendMode = .normal
            d.state.layers = [orig]
            d.activeLayerID = orig.id
        }
        let src = source(d)
        let boards = AppActions.artboards(d).compactMap { $0.artboard?.rect }
        var x = (boards.map(\.maxX).max() ?? CGFloat(d.state.width)) + 100
        var rects: [CGRect] = []
        for f in formats {
            rects.append(CGRect(x: x, y: src.rect.minY, width: CGFloat(f.width), height: CGFloat(f.height)).integral)
            x += CGFloat(f.width) + 100
        }
        if let u = LayoutGeom.union(rects) { AppActions.growCanvas(d, toInclude: u) }
        var st = d.state
        var ids: [UUID] = []
        for (f, r) in zip(formats, rects) {
            let kids = adapt(src.layers, from: src.rect, to: r, state: st, options: o)
            var board = Layer(name: "\(f.name) \(f.width)×\(f.height)", content: .group(GroupContent(children: kids, isExpanded: false,
                                                                                                  artboard: Artboard(rect: r, background: src.artboard?.artboard?.background ?? .white))))
            board.blendMode = .normal
            st.layers.append(board)
            ids.append(board.id)
        }
        d.state = st
        if let last = ids.last { d.activeLayerID = last; d.selectedLayerIDs = [last] }
        d.commit(formats.count == 1 ? "Smart Resize" : "Smart Resize (\(formats.count) formats)")
        Compositor.shared.clearCaches()
        d.needsFitOnScreen = true
        AppActions.canvas?.fitOnScreen()
        return ids
    }
}

/// File ▸ Smart Resize…
struct SmartResizeDialog: View {
    @State private var chosen: Set<String> = ["igPost", "igPortrait", "story", "ytThumb"]
    @State private var custom: [SocialFormat] = []
    @State private var cw: Double = 1200
    @State private var ch: Double = 1200
    @State private var o = SmartResizeOptions()
    @State private var zones = true

    private var formats: [SocialFormat] { (SocialFormat.all + custom).filter { chosen.contains($0.id) } }

    var body: some View {
        DialogFrame(title: "Smart Resize", width: 400, okTitle: "Create \(formats.count) Artboard\(formats.count == 1 ? "" : "s")", onOK: { run() }) {
            Text("Makes one artboard per format with the design adapted: backgrounds fill, the main subject and type keep their place, type stays readable. Tweak each one afterwards.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SocialFormat.all + custom) { f in
                    HStack {
                        Toggle2(label: f.name, on: Binding(get: { chosen.contains(f.id) }, set: { on in if on { chosen.insert(f.id) } else { chosen.remove(f.id) } }))
                        Spacer()
                        Text(verbatim: "\(f.width) × \(f.height)").font(Theme.mono).foregroundStyle(Theme.textDim)
                    }
                }
            }
            HStack {
                NumberField(label: "Custom", value: $cw, width: 50)
                NumberField(label: "×", value: $ch, width: 50)
                Button("Add") {
                    let f = SocialFormat(id: "custom\(custom.count)-\(Int(cw))x\(Int(ch))", name: "Custom", width: max(16, Int(cw)), height: max(16, Int(ch)))
                    custom.append(f); chosen.insert(f.id)
                }.buttonStyle(PanelButtonStyle())
            }
            Divider()
            ValueSlider(label: "Smallest type", value: $o.minTextSize, range: 8...72, unit: "px", labelWidth: 90)
            Toggle2(label: "Keep type clear of story / reel interface bars", on: $o.respectSafeZones)
            Toggle2(label: "Extend photo backgrounds with Content-Aware Fill (small gaps)", on: $o.extendBackground)
            Toggle2(label: "Show safe zones on the new artboards", on: $zones)
        }
    }

    private func run() {
        guard let d = AppActions.doc else { return }
        SmartResize.run(d, formats: formats, options: o)
        if zones && SafeZones.kind == .off { SafeZones.set(.auto) }
    }
}

// MARK: - Safe zones

enum SafeZoneKind: String, CaseIterable, Identifiable {
    case off = "Off"
    case auto = "Auto (by Format)"
    case story = "Instagram Story / Reel"
    case tiktok = "TikTok"
    case shorts = "YouTube Shorts"
    case youtube = "YouTube Thumbnail"
    case feed = "Instagram Feed (Grid Crop)"
    case title = "Title / Action Safe"
    var id: String { rawValue }
}

/// View ▸ Safe Zones: translucent overlays marking where the platforms put their own UI. Never printed or exported.
enum SafeZones {
    static var kind: SafeZoneKind = SafeZoneKind(rawValue: UserDefaults.standard.string(forKey: "Lumen.SafeZones") ?? "") ?? .off {
        didSet { LayoutPrefs.set(kind.rawValue, "Lumen.SafeZones") }
    }

    static func set(_ k: SafeZoneKind) {
        kind = kind == k && k != .off ? .off : k
        AppModel.shared.setStatus("Safe Zones: \(kind.rawValue)")
        AppActions.canvas?.overlay.needsDisplay = true
    }

    struct Zone {
        var label: String
        /// Areas covered by platform UI, in unit coordinates (0…1, y down).
        var unsafe: [CGRect]
        /// Extra guide outlines (unit coordinates).
        var guides: [CGRect] = []
    }

    /// The kind `auto` resolves to for a given size.
    static func resolve(_ k: SafeZoneKind, size: CGSize) -> SafeZoneKind {
        guard k == .auto, size.height > 0 else { return k }
        let a = size.width / size.height
        if a <= 0.62 { return .story }
        if a >= 1.7 && a <= 1.85 { return .youtube }
        if a > 0.62 && a < 0.95 { return .feed }
        return .title
    }

    static func zone(_ k: SafeZoneKind, size: CGSize) -> Zone? {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        switch resolve(k, size: size) {
        case .off, .auto: return nil
        case .story:
            // profile bar on top, caption / reply bar at the bottom, action buttons on the right (Reels)
            return Zone(label: "Story / Reel safe zone", unsafe: [r(0, 0, 1, 0.13), r(0, 0.82, 1, 0.18), r(0.86, 0.52, 0.14, 0.30)])
        case .tiktok:
            return Zone(label: "TikTok safe zone", unsafe: [r(0, 0, 1, 0.11), r(0, 0.75, 1, 0.25), r(0.87, 0.36, 0.13, 0.39), r(0, 0.11, 0.04, 0.64)])
        case .shorts:
            return Zone(label: "YouTube Shorts safe zone", unsafe: [r(0, 0, 1, 0.15), r(0, 0.65, 1, 0.35), r(0.82, 0.15, 0.18, 0.5), r(0, 0.15, 0.045, 0.5)])
        case .youtube:
            // duration badge bottom-right, Watch Later / queue buttons top-right
            return Zone(label: "YouTube thumbnail", unsafe: [r(0.84, 0.84, 0.16, 0.16), r(0.88, 0, 0.12, 0.22)], guides: [r(0.05, 0.05, 0.9, 0.9)])
        case .feed:
            // the profile grid shows a centred square (and a 3:4 crop) of taller posts
            let a = size.width / max(1, size.height)
            guard a < 1 else { return Zone(label: "Instagram feed", unsafe: [], guides: [r(0.05, 0.05, 0.9, 0.9)]) }
            let band = (1 - a) / 2
            return Zone(label: "Grid crop (1:1)", unsafe: [r(0, 0, 1, band), r(0, 1 - band, 1, band)])
        case .title:
            return Zone(label: "Action safe 95% · title safe 90%", unsafe: [r(0, 0, 1, 0.025), r(0, 0.975, 1, 0.025), r(0, 0.025, 0.025, 0.95), r(0.975, 0.025, 0.025, 0.95)],
                        guides: [r(0.05, 0.05, 0.9, 0.9)])
        }
    }

    /// The area type and logos should stay inside (document space) for a frame of the given kind.
    static func safeRect(_ k: SafeZoneKind, in frame: CGRect) -> CGRect {
        guard let z = zone(k, size: frame.size) else { return frame }
        var lo = CGPoint(x: 0, y: 0), hi = CGPoint(x: 1, y: 1)
        for u in z.unsafe {
            if u.width >= 0.99 { if u.minY <= 0.001 { lo.y = max(lo.y, u.maxY) } else if u.maxY >= 0.999 { hi.y = min(hi.y, u.minY) } }
            else if u.height >= 0.5 { if u.minX <= 0.001 { lo.x = max(lo.x, u.maxX) } else if u.maxX >= 0.999 { hi.x = min(hi.x, u.minX) } }
        }
        return CGRect(x: frame.minX + lo.x * frame.width, y: frame.minY + lo.y * frame.height, width: (hi.x - lo.x) * frame.width, height: (hi.y - lo.y) * frame.height)
    }

    /// The frames the zones are drawn on: every visible artboard, or the canvas when there are none.
    static func frames(_ st: DocumentState) -> [CGRect] {
        let boards = st.allLayers.filter { $0.isVisible }.compactMap { $0.artboard?.rect }
        return boards.isEmpty ? [st.canvasCGRect] : boards
    }

    static func draw(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        guard kind != .off else { return }
        let red = NSColor(calibratedRed: 1, green: 0.23, blue: 0.2, alpha: 1)
        for f in frames(doc.state) {
            guard let z = zone(kind, size: f.size) else { continue }
            func docRect(_ u: CGRect) -> CGRect { CGRect(x: f.minX + u.minX * f.width, y: f.minY + u.minY * f.height, width: u.width * f.width, height: u.height * f.height) }
            ctx.saveGState()
            for u in z.unsafe {
                let p = canvas.docToViewPath(docRect(u))
                ctx.addPath(p)
                ctx.setFillColor(red.withAlphaComponent(0.2).cgColor)
                ctx.fillPath()
                ctx.addPath(p)
                ctx.setStrokeColor(red.withAlphaComponent(0.75).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.strokePath()
            }
            for g in z.guides {
                ctx.addPath(canvas.docToViewPath(docRect(g)))
                ctx.setStrokeColor(NSColor(calibratedRed: 0.2, green: 0.9, blue: 1, alpha: 0.85).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [6, 4])
                ctx.strokePath()
            }
            ctx.restoreGState()
            let v = canvas.docToView(f)
            if v.width > 120 {
                NSGraphicsContext.saveGraphicsState()
                ExtraOverlays.badge(z.label, at: CGPoint(x: v.minX + 4, y: v.maxY - 18), color: red.withAlphaComponent(0.85), fontSize: 9)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }
}
