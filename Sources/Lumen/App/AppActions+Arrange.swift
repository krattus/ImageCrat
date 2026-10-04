import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Smart object: back to original size

extension AppActions {
    /// Scale of a smart object relative to its source pixels (1 = 100%).
    static func smartObjectScale(_ so: SmartObjectContent) -> (x: Double, y: Double) {
        let sz = so.source.size
        guard sz.width > 0, sz.height > 0 else { return (1, 1) }
        return (Double(so.quad.tl.distance(to: so.quad.tr) / sz.width), Double(so.quad.tl.distance(to: so.quad.bl) / sz.height))
    }

    /// Restores a smart object to 100% of its source size around its current centre.
    /// `keepRotation` keeps the current angle (and flips); otherwise the transform (and any warp) is cleared entirely.
    static func resetSmartObject(_ ids: [UUID]? = nil, keepRotation: Bool) {
        guard let d = doc else { return }
        let targets = (ids ?? d.orderedSelection).filter { d.state.layer($0)?.isSmartObject == true }
        guard !targets.isEmpty else { NSSound.beep(); return }
        for id in targets {
            d.updateLayer(id) { l in
                guard var s = l.smart else { return }
                let c = s.quad.center, sz = s.source.size
                var q = Quad(rect: CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height))
                if keepRotation {
                    let top = s.quad.tr - s.quad.tl
                    let angle = atan2(top.y, top.x)
                    // keep a horizontal / vertical flip if there is one
                    let left = s.quad.bl - s.quad.tl
                    let flipped = (top.x * left.y - top.y * left.x) < 0
                    var t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: angle)
                    if flipped { t = t.scaledBy(x: 1, y: -1) }
                    t = t.translatedBy(x: -c.x, y: -c.y)
                    q = q.applying(t)
                } else {
                    s.warp = nil
                }
                s.quad = q
                l.smart = s
            }
        }
        d.commit(keepRotation ? "Reset to Original Size" : "Reset Transform")
    }
}

// MARK: - Batch rename

struct BatchRenameSettings: Equatable {
    enum Mode: String, CaseIterable, Identifiable { case template = "New Names", replace = "Find & Replace", affix = "Add Text"
        var id: String { rawValue } }
    enum Case: String, CaseIterable, Identifiable { case keep = "Keep", upper = "UPPERCASE", lower = "lowercase", title = "Title Case"
        var id: String { rawValue } }
    var mode: Mode = .template
    var template = "Layer {n}"
    var start = 1
    var step = 1
    var padding = 2
    var find = ""
    var replace = ""
    var useRegex = false
    var caseSensitive = false
    var prefix = ""
    var suffix = ""
    var letterCase: Case = .keep
    var topToBottom = true
    var stripCopy = false
}

enum BatchRename {
    /// New names for `layers` (given in the order they should be numbered).
    static func names(for layers: [Layer], _ s: BatchRenameSettings, state: DocumentState? = nil) -> [String] {
        layers.enumerated().map { i, l in
            var name = l.name
            if s.stripCopy {
                while let r = name.range(of: #"\s+copy(\s+\d+)?$"#, options: [.regularExpression, .caseInsensitive]) { name.removeSubrange(r) }
            }
            let n = s.start + i * s.step
            let num = String(format: "%0\(max(1, s.padding))d", n)
            switch s.mode {
            case .template:
                var out = s.template
                let b = state.flatMap { Compositor.shared.contentBounds(l, state: $0) }
                let tokens: [(String, String)] = [
                    ("{name}", name), ("{n}", num), ("{N}", "\(n)"), ("{kind}", l.kindName),
                    ("{a}", letters(n - 1, upper: false)), ("{A}", letters(n - 1, upper: true)),
                    ("{w}", b.map { "\(Int($0.width.rounded()))" } ?? ""), ("{h}", b.map { "\(Int($0.height.rounded()))" } ?? ""),
                    ("{auto}", out.contains("{auto}") ? AssistNaming.token(for: l) : ""),
                ]
                for (k, v) in tokens { out = out.replacingOccurrences(of: k, with: v) }
                name = out
            case .replace:
                if !s.find.isEmpty {
                    var opts: String.CompareOptions = s.caseSensitive ? [] : [.caseInsensitive]
                    if s.useRegex { opts.insert(.regularExpression) }
                    name = name.replacingOccurrences(of: s.find, with: s.replace, options: opts)
                }
            case .affix:
                name = s.prefix.replacingOccurrences(of: "{n}", with: num) + name + s.suffix.replacingOccurrences(of: "{n}", with: num)
            }
            switch s.letterCase {
            case .keep: break
            case .upper: name = name.uppercased()
            case .lower: name = name.lowercased()
            case .title: name = name.capitalized
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? l.name : trimmed
        }
    }

    /// a, b, … z, aa, ab …
    static func letters(_ index: Int, upper: Bool) -> String {
        var i = max(0, index), out = ""
        repeat {
            out = String(UnicodeScalar(UInt8((upper ? 65 : 97) + i % 26))) + out
            i = i / 26 - 1
        } while i >= 0
        return out
    }

    /// Selected layers in numbering order.
    static func targets(_ d: Document, topToBottom: Bool) -> [Layer] {
        let ids = d.orderedSelection          // bottom-first
        let layers = ids.compactMap { d.state.layer($0) }
        return topToBottom ? layers.reversed() : layers
    }

    static func apply(_ s: BatchRenameSettings) {
        guard let d = AppActions.doc else { return }
        let layers = targets(d, topToBottom: s.topToBottom)
        guard !layers.isEmpty else { NSSound.beep(); return }
        let new = names(for: layers, s, state: d.state)
        for (l, n) in zip(layers, new) where l.name != n { d.updateLayer(l.id) { $0.name = n } }
        d.commit(layers.count == 1 ? "Rename Layer" : "Rename \(layers.count) Layers")
    }
}

struct BatchRenameDialog: View {
    @State private var s = BatchRenameSettings()
    @Bindable var app = AppModel.shared

    var layers: [Layer] { app.activeDocument.map { BatchRename.targets($0, topToBottom: s.topToBottom) } ?? [] }

    var body: some View {
        DialogFrame(title: "Rename Layers", width: 460, okTitle: "Rename", onOK: { BatchRename.apply(s) }) {
            Picker("", selection: $s.mode) { ForEach(BatchRenameSettings.Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch s.mode {
            case .template:
                HStack { Text("Name").foregroundStyle(Theme.textDim).frame(width: 70, alignment: .leading); TextField("Layer {n}", text: $s.template)
                    Button("Auto") { s.template = "{auto}"; AssistNaming.prepare() }.buttonStyle(PanelButtonStyle()).help("Describe each layer automatically ({auto} token)") }
                Text("Tokens: {n} number · {N} number without zeros · {a}/{A} letters · {name} current name · {kind} · {w} {h} size · {auto} automatic description")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                numbering
            case .replace:
                HStack { Text("Find").foregroundStyle(Theme.textDim).frame(width: 70, alignment: .leading); TextField("", text: $s.find) }
                HStack { Text("Replace").foregroundStyle(Theme.textDim).frame(width: 70, alignment: .leading); TextField("", text: $s.replace) }
                HStack { Toggle2(label: "Regular expression", on: $s.useRegex); Toggle2(label: "Case sensitive", on: $s.caseSensitive) }
            case .affix:
                HStack { Text("Before").foregroundStyle(Theme.textDim).frame(width: 70, alignment: .leading); TextField("prefix", text: $s.prefix) }
                HStack { Text("After").foregroundStyle(Theme.textDim).frame(width: 70, alignment: .leading); TextField("suffix ({n} = number)", text: $s.suffix) }
                numbering
            }
            HStack {
                Picker("Case", selection: $s.letterCase) { ForEach(BatchRenameSettings.Case.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 190)
                Toggle2(label: "Remove “copy”", on: $s.stripCopy)
            }
            Picker("Order", selection: $s.topToBottom) { Text("Top to bottom").tag(true); Text("Bottom to top").tag(false) }.frame(width: 220)
            Divider()
            let new = BatchRename.names(for: layers, s, state: app.activeDocument?.state)
            if layers.isEmpty {
                Text("Select the layers to rename in the Layers panel.").foregroundStyle(Theme.textFaint)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(zip(layers, new).enumerated()), id: \.offset) { _, pair in
                            HStack(spacing: 6) {
                                Text(pair.0.name).foregroundStyle(Theme.textDim).lineLimit(1).frame(width: 190, alignment: .leading)
                                Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(Theme.textFaint)
                                Text(pair.1).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 170)
                Text("\(layers.count) layer\(layers.count == 1 ? "" : "s") selected").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
    }

    @ViewBuilder var numbering: some View {
        HStack {
            NumberField(label: "Start", value: Binding(get: { Double(s.start) }, set: { s.start = Int($0) }), width: 44)
            NumberField(label: "Step", value: Binding(get: { Double(s.step) }, set: { s.step = max(1, Int($0)) }), width: 36)
            NumberField(label: "Digits", value: Binding(get: { Double(s.padding) }, set: { s.padding = max(1, min(6, Int($0))) }), width: 30)
        }
    }
}

// MARK: - Arrange selected layers on a shape


enum ArrangeOnShape {
    /// The guide outline in document space.
    static func path(_ s: ArrangeSettings, doc: Document) -> CGPath? {
        let r = CGRect(x: s.centerX - s.width / 2, y: s.centerY - s.height / 2, width: s.width, height: s.height)
        let sq = CGRect(x: s.centerX - s.width / 2, y: s.centerY - s.width / 2, width: s.width, height: s.width)
        let p = CGMutablePath()
        switch s.shape {
        case .circle:
            p.addEllipse(in: sq)
            return rotated(startingAtTop(p, rect: sq), s)
        case .ellipse:
            p.addEllipse(in: r)
            return rotated(startingAtTop(p, rect: r), s)
        case .square: p.addRect(sq)
        case .rectangle: p.addRect(r)
        case .triangle:
            p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        case .polygon:
            return rotated(VectorPath.polygon(in: r, sides: max(3, s.sides), starRatio: 1).cgPath, s)
        case .star:
            return rotated(VectorPath.polygon(in: r, sides: max(3, s.sides), starRatio: max(0.05, min(1, s.starInset))).cgPath, s)
        case .line:
            p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        case .arc:
            let a = CGFloat(s.arcAngle * .pi / 180)
            let start = -CGFloat.pi / 2 - a / 2
            let n = 64
            for k in 0...n {
                let t = start + a * CGFloat(k) / CGFloat(n)
                let pt = CGPoint(x: s.centerX + cos(t) * s.width / 2, y: s.centerY + sin(t) * s.height / 2)
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        case .spiral:
            let n = max(32, Int(s.turns * 96))
            for k in 0...n {
                let f = CGFloat(k) / CGFloat(n)
                let t = f * CGFloat(s.turns) * 2 * .pi - .pi / 2
                let pt = CGPoint(x: s.centerX + cos(t) * s.width / 2 * f, y: s.centerY + sin(t) * s.height / 2 * f)
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        case .wave:
            let n = 128
            for k in 0...n {
                let f = CGFloat(k) / CGFloat(n)
                let pt = CGPoint(x: r.minX + r.width * f, y: s.centerY - sin(f * CGFloat(s.waves) * 2 * .pi) * s.height / 2)
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        case .grid:
            return nil
        case .custom:
            guard let sh = ShapeLibrary.shape(s.customID) else { return nil }
            return rotated(sh.path(in: r).resolved.path, s)
        case .path:
            guard let pid = doc.activePathID, let np = doc.state.paths.first(where: { $0.id == pid }) else { return nil }
            return np.path.resolved.path
        }
        return rotated(p, s)
    }

    private static func startingAtTop(_ p: CGPath, rect: CGRect) -> CGPath {
        // CGPath ellipses start at the right; rotate a quarter turn so the first layer sits at the top
        var t = CGAffineTransform(translationX: rect.midX, y: rect.midY).rotated(by: -.pi / 2).translatedBy(x: -rect.midX, y: -rect.midY)
        // keep the ellipse's proportions by building it directly instead when not square
        if abs(rect.width - rect.height) > 0.5 {
            let q = CGMutablePath()
            let n = 96
            for k in 0..<n {
                let a = -CGFloat.pi / 2 + CGFloat(k) / CGFloat(n) * 2 * .pi
                let pt = CGPoint(x: rect.midX + cos(a) * rect.width / 2, y: rect.midY + sin(a) * rect.height / 2)
                if k == 0 { q.move(to: pt) } else { q.addLine(to: pt) }
            }
            q.closeSubpath()
            return q
        }
        return p.copy(using: &t) ?? p
    }

    private static func rotated(_ p: CGPath, _ s: ArrangeSettings) -> CGPath {
        guard s.rotation != 0 else { return p }
        var t = CGAffineTransform(translationX: s.centerX, y: s.centerY).rotated(by: CGFloat(s.rotation * .pi / 180)).translatedBy(x: -s.centerX, y: -s.centerY)
        return p.copy(using: &t) ?? p
    }

    struct Slot { var point: CGPoint; var angle: CGFloat }   // angle = tangent direction (radians, y-down)

    /// Polylines of a path (one per subpath), with whether each is closed.
    static func polylines(_ path: CGPath) -> [(pts: [CGPoint], closed: Bool)] {
        var out: [(pts: [CGPoint], closed: Bool)] = []
        var cur: [CGPoint] = []
        var closed = false
        func flush() { if cur.count > 1 { out.append((cur, closed)) }; cur = []; closed = false }
        path.flattened(threshold: 0.25).applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint: flush(); cur = [el.points[0]]
            case .addLineToPoint: cur.append(el.points[0])
            case .closeSubpath:
                if let f = cur.first, let l = cur.last, f.distance(to: l) > 0.01 { cur.append(f) }
                closed = true
            default: break
            }
        }
        flush()
        return out
    }

    /// `count` evenly spaced slots along the outline (by arc length), or on the corners when `atCorners`.
    static func slots(_ s: ArrangeSettings, count: Int, doc: Document, cellSize: CGSize) -> [Slot] {
        guard count > 0 else { return [] }
        if s.shape == .grid {
            let cols = max(1, s.columns)
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cw = cols > 1 ? s.width / Double(cols - 1) : 0, ch = rows > 1 ? s.height / Double(rows - 1) : 0
            return (0..<count).map { i in
                Slot(point: CGPoint(x: s.centerX - s.width / 2 + Double(i % cols) * cw, y: s.centerY - s.height / 2 + Double(i / cols) * ch), angle: 0)
            }
        }
        guard let path = path(s, doc: doc) else { return [] }
        let lines = polylines(path)
        guard var line = lines.max(by: { length($0.pts) < length($1.pts) }) else { return [] }
        if !s.clockwise { line.pts.reverse() }
        let total = length(line.pts)
        guard total > 0 else { return [] }
        if s.atCorners, line.closed {
            // corners = direction changes of the polyline
            var corners: [Int] = [0]
            for i in 1..<(line.pts.count - 1) {
                let a = line.pts[i] - line.pts[i - 1], b = line.pts[i + 1] - line.pts[i]
                if abs(atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)) > 0.2 { corners.append(i) }
            }
            if corners.count >= 2 {
                return (0..<count).map { i in
                    let ci = corners[i % corners.count]
                    let lap = CGFloat(i / corners.count)
                    // extra laps sit between corners
                    if lap == 0 { return Slot(point: line.pts[ci], angle: tangent(line.pts, at: ci, closed: true)) }
                    let next = corners[(i % corners.count + 1) % corners.count]
                    let f = lap / (CGFloat((count - 1) / corners.count) + 1)
                    return Slot(point: line.pts[ci].lerp(line.pts[next], f), angle: tangent(line.pts, at: ci, closed: true))
                }
            }
        }
        let n = line.closed ? count : max(1, count - 1)
        let offset = CGFloat(s.startOffset / 100) * total
        return (0..<count).map { i in
            var dist = offset + (line.closed ? total * CGFloat(i) / CGFloat(n) : (count == 1 ? total / 2 : total * CGFloat(i) / CGFloat(n)))
            if line.closed { dist = dist.truncatingRemainder(dividingBy: total) } else { dist = min(total, dist) }
            return slot(line.pts, at: dist)
        }
    }

    static func length(_ pts: [CGPoint]) -> CGFloat {
        var l: CGFloat = 0
        for i in 1..<max(1, pts.count) { l += pts[i].distance(to: pts[i - 1]) }
        return l
    }

    private static func tangent(_ pts: [CGPoint], at i: Int, closed: Bool) -> CGFloat {
        let a = pts[max(0, i - 1)], b = pts[min(pts.count - 1, i + 1)]
        return atan2(b.y - a.y, b.x - a.x)
    }

    private static func slot(_ pts: [CGPoint], at dist: CGFloat) -> Slot {
        var acc: CGFloat = 0
        for i in 1..<pts.count {
            let seg = pts[i].distance(to: pts[i - 1])
            if acc + seg >= dist || i == pts.count - 1 {
                let f = seg > 0 ? min(1, max(0, (dist - acc) / seg)) : 0
                return Slot(point: pts[i - 1].lerp(pts[i], f), angle: atan2(pts[i].y - pts[i - 1].y, pts[i].x - pts[i - 1].x))
            }
            acc += seg
        }
        return Slot(point: pts.last ?? .zero, angle: 0)
    }

    /// Ordered layer ids to arrange.
    static func orderedIDs(_ s: ArrangeSettings, base: DocumentState, ids: [UUID]) -> [UUID] {
        switch s.order {
        case .stack: return ids.reversed()            // top layer first
        case .reverse: return ids
        case .position:
            return ids.sorted { (Compositor.shared.contentBounds(base.layer($0)!, state: base)?.midX ?? 0) < (Compositor.shared.contentBounds(base.layer($1)!, state: base)?.midX ?? 0) }
        case .random:
            var g = SeededGenerator(seed: UInt64(max(1, s.seed)))
            return ids.shuffled(using: &g)
        }
    }

    /// Returns `base` with the layers moved (and optionally rotated / scaled) onto the shape.
    static func arranged(_ s: ArrangeSettings, base: DocumentState, ids: [UUID], doc: Document) -> DocumentState {
        var st = base
        let order = orderedIDs(s, base: base, ids: ids)
        let sp = CanvasSpace(width: base.width, height: base.height)
        var cell = CGSize.zero
        for id in order { if let l = base.layer(id), let b = Compositor.shared.contentBounds(l, state: base) { cell.width = max(cell.width, b.width); cell.height = max(cell.height, b.height) } }
        let slots = slots(s, count: order.count, doc: doc, cellSize: cell)
        guard slots.count == order.count else { return base }
        var rng = SeededGenerator(seed: UInt64(max(1, s.seed)) &* 7919)
        let center = CGPoint(x: s.centerX, y: s.centerY)
        for (i, id) in order.enumerated() {
            guard let l = base.layer(id), let b = Compositor.shared.contentBounds(l, state: base) else { continue }
            let c = CGPoint(x: b.midX, y: b.midY)
            var target = slots[i].point
            if s.jitterPosition > 0 {
                target.x += CGFloat(Double.random(in: -1...1, using: &rng) * s.jitterPosition)
                target.y += CGFloat(Double.random(in: -1...1, using: &rng) * s.jitterPosition)
            }
            var angle: CGFloat = 0
            switch s.facing {
            case .upright: angle = 0
            case .tangent: angle = slots[i].angle
            case .outward: angle = atan2(target.y - center.y, target.x - center.x) + .pi / 2
            case .inward: angle = atan2(target.y - center.y, target.x - center.x) - .pi / 2
            }
            angle += CGFloat(s.extraRotation * .pi / 180)
            if s.jitterRotation > 0 { angle += CGFloat(Double.random(in: -1...1, using: &rng) * s.jitterRotation * .pi / 180) }
            let f = order.count > 1 ? CGFloat(i) / CGFloat(order.count - 1) : 0
            let scale = 1 + (CGFloat(s.scaleEnd) / 100 - 1) * f
            var t = CGAffineTransform(translationX: -c.x, y: -c.y)
            if abs(scale - 1) > 0.001 { t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale)) }
            if abs(angle) > 0.0001 { t = t.concatenating(CGAffineTransform(rotationAngle: angle)) }
            t = t.concatenating(CGAffineTransform(translationX: target.x, y: target.y))
            if abs(angle) < 0.0001 && abs(scale - 1) < 0.001 {
                st.updateLayer(id) { $0.translate(dx: Double(target.x - c.x), dy: Double(target.y - c.y)) }
            } else {
                let moved = LayerTransformer.apply(Homography(affine: t), to: l, space: sp)
                st.updateLayer(id) { $0 = moved }
            }
        }
        return st
    }

    /// Default settings for the current selection: centred on the layers, sized to their spread.
    static func defaults(_ d: Document) -> ArrangeSettings {
        var s = ArrangeSettings()
        var u: CGRect?
        var maxSide: CGFloat = 0
        for id in d.orderedSelection {
            if let l = d.state.layer(id), let b = Compositor.shared.contentBounds(l, state: d.state) {
                u = u.map { $0.union(b) } ?? b
                maxSide = max(maxSide, max(b.width, b.height))
            }
        }
        let canvas = d.state.canvasCGRect
        let b = u ?? canvas
        s.centerX = Double(b.midX); s.centerY = Double(b.midY)
        let side = min(Double(min(canvas.width, canvas.height)) * 0.7, max(Double(max(b.width, b.height)), Double(maxSide) * 2.2))
        s.width = max(40, side); s.height = max(40, side)
        return s
    }
}

/// Small deterministic generator (SplitMix64) so "Random" orders and jitter are repeatable.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Live dialog: arranges the selected layers on a shape; the guide outline is drawn over the canvas.
struct ArrangeOnShapeDialog: View {
    @State private var s: ArrangeSettings
    @State private var showGuide = true
    private let base: DocumentState?
    private let ids: [UUID]

    init() {
        let d = AppActions.doc
        base = d?.state
        ids = d?.orderedSelection ?? []
        _s = State(initialValue: d.map { ArrangeOnShape.defaults($0) } ?? ArrangeSettings())
    }

    var body: some View {
        DialogFrame(title: "Arrange on Shape", width: 340, onOK: { finish(apply: true) }, onCancel: { finish(apply: false) }) {
            if ids.count < 2 {
                Text("Select two or more layers in the Layers panel (⌘-click or ⇧-click), then choose Arrange on Shape.").foregroundStyle(Theme.textFaint)
            } else {
                Picker("Shape", selection: $s.shape) { ForEach(ArrangeSettings.Shape.allCases) { Text($0.rawValue).tag($0) } }
                if s.shape == .custom {
                    HStack { Text("Custom shape").foregroundStyle(Theme.textDim); ShapeLibraryPicker(id: $s.customID) }
                }
                if s.shape == .path && AppActions.doc?.activePathID == nil {
                    Text("Select a path in the Paths panel first.").foregroundStyle(.orange).font(Theme.fontSmall)
                }
                let square = s.shape == .circle || s.shape == .square
                ValueSlider(label: square ? "Size" : "Width", value: $s.width, range: 10...4000, unit: "px", labelWidth: 84)
                if !square { ValueSlider(label: "Height", value: $s.height, range: 0...4000, unit: "px", labelWidth: 84) }
                HStack {
                    NumberField(label: "Centre X", value: $s.centerX, width: 54)
                    NumberField(label: "Y", value: $s.centerY, width: 54)
                    Button("Canvas centre") { if let b = base { s.centerX = Double(b.width) / 2; s.centerY = Double(b.height) / 2 } }.buttonStyle(PanelButtonStyle())
                }
                switch s.shape {
                case .polygon, .star:
                    ValueSlider(label: s.shape == .star ? "Points" : "Sides", value: Binding(get: { Double(s.sides) }, set: { s.sides = Int($0) }), range: 3...24, step: 1, labelWidth: 84)
                    if s.shape == .star { ValueSlider(label: "Inset", value: Binding(get: { s.starInset * 100 }, set: { s.starInset = $0 / 100 }), range: 5...95, unit: "%", labelWidth: 84) }
                case .arc: ValueSlider(label: "Arc angle", value: $s.arcAngle, range: 10...360, unit: "°", labelWidth: 84)
                case .spiral: ValueSlider(label: "Turns", value: $s.turns, range: 0.5...8, format: "%.1f", labelWidth: 84)
                case .wave: ValueSlider(label: "Waves", value: $s.waves, range: 0.5...8, format: "%.1f", labelWidth: 84)
                case .grid: ValueSlider(label: "Columns", value: Binding(get: { Double(s.columns) }, set: { s.columns = Int($0) }), range: 1...20, step: 1, labelWidth: 84)
                default: EmptyView()
                }
                if s.shape != .grid {
                    ValueSlider(label: "Rotate shape", value: $s.rotation, range: -180...180, unit: "°", labelWidth: 84)
                    ValueSlider(label: "Start", value: $s.startOffset, range: 0...100, unit: "%", labelWidth: 84)
                    HStack {
                        Toggle2(label: "Clockwise", on: $s.clockwise)
                        if [.square, .rectangle, .triangle, .polygon, .star].contains(s.shape) { Toggle2(label: "On corners", on: $s.atCorners) }
                    }
                }
                Picker("Order", selection: $s.order) { ForEach(ArrangeSettings.Order.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Layers", selection: $s.facing) { ForEach(ArrangeSettings.Facing.allCases) { Text($0.rawValue).tag($0) } }
                DisclosureGroup("More") {
                    ValueSlider(label: "Extra rotation", value: $s.extraRotation, range: -180...180, unit: "°", labelWidth: 96)
                    ValueSlider(label: "Size at end", value: $s.scaleEnd, range: 10...300, unit: "%", labelWidth: 96)
                    ValueSlider(label: "Scatter", value: $s.jitterPosition, range: 0...300, unit: "px", labelWidth: 96)
                    ValueSlider(label: "Random tilt", value: $s.jitterRotation, range: 0...180, unit: "°", labelWidth: 96)
                    HStack {
                        NumberField(label: "Seed", value: Binding(get: { Double(s.seed) }, set: { s.seed = max(1, Int($0)) }), width: 44)
                        Button("Shuffle") { s.seed = Int.random(in: 1...9999) }.buttonStyle(PanelButtonStyle())
                    }
                }
                Toggle2(label: "Show guide shape", on: $showGuide)
                Text("\(ids.count) layers · they stay separate, editable layers").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
        .onChange(of: s) { _, _ in update() }
        .onChange(of: showGuide) { _, _ in update() }
        .onAppear { update() }
    }

    private func update() {
        guard let d = AppActions.doc, let b = base, ids.count >= 2 else { return }
        d.state = ArrangeOnShape.arranged(s, base: b, ids: ids, doc: d)
        ArrangeGuide.path = showGuide ? ArrangeOnShape.path(s, doc: d) : nil
        d.setNeedsRender()
        AppActions.canvas?.overlay.needsDisplay = true
    }

    private func finish(apply: Bool) {
        ArrangeGuide.path = nil
        AppActions.canvas?.overlay.needsDisplay = true
        guard let d = AppActions.doc, let b = base, ids.count >= 2 else { return }
        if apply {
            d.state = ArrangeOnShape.arranged(s, base: b, ids: ids, doc: d)
            d.commit("Arrange on \(s.shape.rawValue)")
        } else {
            d.state = b
            d.setNeedsRender()
        }
    }
}

/// Guide outline shown on the canvas while the Arrange dialog is open.
enum ArrangeGuide {
    static var path: CGPath?

    static func draw(_ ctx: CGContext, canvas: CanvasView) {
        guard let p = path else { return }
        var t = canvas.docToViewTransform
        guard let v = p.copy(using: &t) else { return }
        ctx.saveGState()
        ctx.addPath(v)
        ctx.setStrokeColor(NSColor(calibratedRed: 1, green: 0.2, blue: 0.8, alpha: 0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.strokePath()
        ctx.restoreGState()
    }
}

// MARK: - Registration

enum ArrangeModule {
    static func register() {
        let multi = { (AppActions.doc?.orderedSelection.count ?? 0) >= 2 }
        let any = { !(AppActions.doc?.orderedSelection.isEmpty ?? true) }
        let so = { AppActions.doc?.activeLayer?.isSmartObject == true }
        DialogRegistry.register("batchRename") { AnyView(BatchRenameDialog()) }
        DialogRegistry.register("arrangeOnShape", dims: false) { AnyView(ArrangeOnShapeDialog()) }
        MenuRegistry.add("Layer", "Rename Layers…", dividerBefore: true, enabled: any) { DialogRegistry.show("batchRename") }
        MenuRegistry.add("Layer", "Arrange on Shape…", enabled: multi) { DialogRegistry.show("arrangeOnShape") }
        MenuRegistry.add("Layer/Smart Objects", "Reset to Original Size (100%)", enabled: so) { AppActions.resetSmartObject(keepRotation: true) }
        MenuRegistry.add("Layer/Smart Objects", "Reset Transform", enabled: so) { AppActions.resetSmartObject(keepRotation: false) }
    }
}
