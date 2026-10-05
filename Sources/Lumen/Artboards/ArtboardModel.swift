import AppKit
import CoreGraphics
import ImageCratCore

/// Photoshop's artboard model on top of Lumen's artboard groups (`GroupContent.artboard`):
/// - an artboard is a top-level group with its own rectangle and background that clips its contents;
/// - a document with at least one artboard is in artboard mode: the canvas outside the artboards is pasteboard;
///   with Auto-size Canvas on (the default) the canvas grows and shrinks on every side after each step to fit the
///   artboards and the layers outside them (the view and every stored position move along, so nothing jumps on
///   screen); with it off the canvas only grows to hold the artboards and gives back room on the right / bottom;
/// - layers dragged onto another artboard move into it (with the layers clipped to them), unless auto-nesting is off;
/// - artboards are always top-level: they never go into a group or another artboard;
/// - every command here is one history step.
enum ArtboardOps {
    // MARK: Queries

    static func boards(_ st: DocumentState) -> [Layer] { st.allLayers.filter { $0.isArtboard } }
    static func isArtboardDocument(_ st: DocumentState) -> Bool { st.layers.contains(where: \.isArtboard) || st.allLayers.contains(where: \.isArtboard) }

    /// Union of the artboard rectangles (hidden ones too unless `visibleOnly`).
    static func union(_ st: DocumentState, visibleOnly: Bool = false) -> CGRect? {
        var u: CGRect?
        for l in boards(st) where !visibleOnly || l.isVisible {
            guard let r = l.artboard?.rect, r.width > 0, r.height > 0 else { continue }
            u = u.map { $0.union(r) } ?? r
        }
        return u
    }

    /// The artboard that holds `id` (the layer itself when it is one).
    static func artboard(containing id: UUID?, _ st: DocumentState) -> Layer? {
        var cur = id
        while let i = cur, let l = st.layer(i) {
            if l.isArtboard { return l }
            cur = st.parentID(of: i)
        }
        return nil
    }

    /// Topmost visible artboard under doc point `p`.
    static func artboard(at p: CGPoint, _ st: DocumentState) -> Layer? {
        boards(st).reversed().first { $0.isVisible && ($0.artboard?.rect.contains(p) ?? false) }
    }

    /// Bounds of the layers that sit outside every artboard (fill / adjustment layers cover everything and don't count).
    static func looseContentBounds(_ st: DocumentState, visibleOnly: Bool = false) -> CGRect? {
        var u: CGRect?
        for l in st.layers where !l.isArtboard && !l.isFill && !l.isAdjustment && (!visibleOnly || l.isVisible) {
            guard let b = Compositor.shared.contentBounds(l, state: st), !b.isNull, b.width > 0, b.height > 0, b.width.isFinite, b.height.isFinite else { continue }
            u = u.map { $0.union(b) } ?? b
        }
        return u
    }

    /// "Artboard N" not used yet.
    static func nextName(_ st: DocumentState) -> String {
        let names = Set(st.allLayers.map(\.name))
        var n = boards(st).count + 1
        while names.contains("Artboard \(n)") { n += 1 }
        return "Artboard \(n)"
    }

    /// Room between artboards placed next to each other (Photoshop leaves a gap, too).
    static let gap: CGFloat = 100

    /// First free rectangle of `size` on `side` of `r`, stepping past artboards already there.
    static func freeRect(_ st: DocumentState, size: CGSize, beside r: CGRect, side: ArtboardTool.Side, ignoring: Set<UUID> = []) -> CGRect {
        let others = boards(st).filter { !ignoring.contains($0.id) }.compactMap { $0.artboard?.rect }
        func step(_ x: CGRect) -> CGRect {
            switch side {
            case .right: return CGRect(x: x.maxX + gap, y: r.minY, width: size.width, height: size.height)
            case .left: return CGRect(x: x.minX - gap - size.width, y: r.minY, width: size.width, height: size.height)
            case .bottom: return CGRect(x: r.minX, y: x.maxY + gap, width: size.width, height: size.height)
            case .top: return CGRect(x: r.minX, y: x.minY - gap - size.height, width: size.width, height: size.height)
            }
        }
        var nr = step(r)
        var n = 0
        while n < 200, let hit = others.first(where: { $0.insetBy(dx: -1, dy: -1).intersects(nr) }) {
            nr = step(side == .right || side == .left ? CGRect(x: hit.minX, y: nr.minY, width: hit.width, height: nr.height) : CGRect(x: nr.minX, y: hit.minY, width: nr.width, height: hit.height))
            n += 1
        }
        return nr.integral
    }

    // MARK: Canvas

    /// Resizes the canvas to `w` × `h` after moving everything by (`dx`, `dy`) (selection, channels, paths, guides,
    /// tool marks, stored frame / comp / timeline positions and the artboard origin go along). The view keeps showing
    /// the same pixels, now and when the step is undone or redone (see `installCommitHook`).
    static func resizeCanvas(_ d: Document, dx: Int, dy: Int, width w: Int, height h: Int) {
        let lim = maxCanvasDimension
        let w = min(max(1, w), lim), h = min(max(1, h), lim)
        guard dx != 0 || dy != 0 || w != d.state.width || h != d.state.height else { return }
        var st = d.state
        if dx != 0 || dy != 0 {
            for i in st.layers.indices { st.layers[i].translate(dx: Double(dx), dy: Double(dy), document: true) }
            AppActions.syncStoredGeometry(from: d.state, to: &st, dx: Double(dx), dy: Double(dy))
            st.paths = st.paths.map { var p = $0; p.path = p.path.applying(CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))); return p }
            st.guides = st.guides.map { var g = $0; g.position += g.isVertical ? Double(dx) : Double(dy); return g }
            st.toolData = st.toolData.mapped { CGPoint(x: $0.x + CGFloat(dx), y: $0.y + CGFloat(dy)) }
            st.artboardOrigin = CGPoint(x: st.artboardOrigin.x + CGFloat(dx), y: st.artboardOrigin.y + CGFloat(dy))
            let p = pendingShift?.doc == d.id ? pendingShift!.shift : .zero
            pendingShift = (d.id, CGPoint(x: p.x + CGFloat(dx), y: p.y + CGFloat(dy)))
        }
        func resized(_ b: PixelBuffer) -> PixelBuffer {
            let n = PixelBuffer(width: w, height: h, format: .gray)
            n.copyPixels(from: b, at: IPoint(x: dx, y: dy))
            n.markDirty()
            return n
        }
        if let s = st.selection { st.selection = resized(s) }
        st.alphaChannels = st.alphaChannels.map { var c = $0; c.buffer = resized(c.buffer); return c }
        st.width = w
        st.height = h
        d.state = st
        if dx != 0 || dy != 0 { keepView(d, dx: CGFloat(dx), dy: CGFloat(dy)) }
    }

    /// Shifts the view by the same amount the document moved, so nothing jumps on screen.
    static func keepView(_ d: Document, dx: CGFloat, dy: CGFloat) {
        if let c = AppActions.canvas, c.document === d {
            d.viewOffset = d.viewOffset - c.linear(CGPoint(x: dx, y: dy), zoom: CGFloat(d.zoom))
        } else {
            let z = CGFloat(d.zoom), r = CGFloat(d.viewRotation)
            d.viewOffset = d.viewOffset - CGPoint(x: (dx * cos(r) - dy * sin(r)) * z, y: (dx * sin(r) + dy * cos(r)) * z)
        }
    }

    /// Fits the canvas after an artboard command: Auto-size Canvas on → `autoSizeAll`; off → `growToArtboards`.
    static func autoSize(_ d: Document) {
        if ArtboardSettings.shared.prefs.autoSizeCanvas { autoSizeAll(d) } else { growToArtboards(d) }
    }

    /// Auto-size Canvas: the canvas is exactly the artboards plus the layers outside them, on all four sides (it
    /// grows and shrinks; when the left / top moves, everything moves with it and the view follows).
    static func autoSizeAll(_ d: Document) {
        guard let r = autoSizeRect(d.state) else { return }
        resizeCanvas(d, dx: -Int(r.minX), dy: -Int(r.minY), width: Int(r.width), height: Int(r.height))
    }

    /// The canvas Auto-size Canvas makes (doc pixels, whole numbers): the artboards and the layers outside them.
    static func autoSizeRect(_ st: DocumentState) -> CGRect? {
        guard var u = union(st) else { return nil }
        if let loose = looseContentBounds(st) { u = u.union(loose) }
        let r = u.integral
        guard r.width >= 1, r.height >= 1, r.minX.isFinite, r.minY.isFinite else { return nil }
        return r
    }

    /// Auto-size Canvas off (and the behaviour before the option existed): the canvas grows on any side to hold every
    /// artboard, and gives up room on the right / bottom that neither an artboard nor a layer outside the artboards
    /// needs. The top-left corner only moves when an artboard goes past it (use `fitCanvas` to trim all four sides).
    static func growToArtboards(_ d: Document) {
        guard let u = union(d.state) else { return }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        let dx = max(0, Int(ceil(-u.minX))), dy = max(0, Int(ceil(-u.minY)))
        var maxX = u.maxX, maxY = u.maxY
        if let loose = looseContentBounds(d.state) {   // layers on the pasteboard keep the room they use (inside the canvas)
            maxX = max(maxX, min(loose.maxX, W)); maxY = max(maxY, min(loose.maxY, H))
        }
        let w = Int(ceil(maxX)) + dx, h = Int(ceil(maxY)) + dy
        resizeCanvas(d, dx: dx, dy: dy, width: w, height: h)
    }

    /// Fit on Screen (⌘0) in an artboard document: the visible artboards and the visible layers outside them (on the
    /// canvas), i.e. what Photoshop's auto-sized canvas holds. Nil for documents without artboards.
    static func screenFitRect(_ st: DocumentState) -> CGRect? {
        guard isArtboardDocument(st), var u = union(st, visibleOnly: true) ?? union(st) else { return nil }
        if let loose = looseContentBounds(st, visibleOnly: true)?.intersection(st.canvasCGRect), !loose.isNull, loose.width > 0, loose.height > 0 {
            u = u.union(loose)
        }
        let r = u.intersection(st.canvasCGRect)
        return r.isNull || r.width < 1 || r.height < 1 ? nil : r
    }

    /// Canvas = the artboards (and the layers outside them), on all four sides.
    static func fitCanvas(_ d: Document) {
        guard var u = union(d.state) else { return }
        if let loose = looseContentBounds(d.state) { u = u.union(loose.intersection(d.state.canvasCGRect.union(u))) }
        let r = u.integral
        resizeCanvas(d, dx: -Int(r.minX), dy: -Int(r.minY), width: Int(r.width), height: Int(r.height))
    }

    // MARK: Commit hook (auto-size, top-level artboards, auto-nesting)

    /// Auto-nesting (Preferences ▸ Artboards, the Artboard tool's gear menu).
    static var autoNest: Bool {
        get { ArtboardSettings.shared.prefs.autoNest }
        set { ArtboardSettings.shared.prefs.autoNest = newValue }
    }
    /// Copies the Move tool made with ⌥-drag in the step being committed (nested by where they land).
    nonisolated(unsafe) static var movedCopies: Set<UUID> = []
    nonisolated(unsafe) private static var inHook = false
    nonisolated(unsafe) private static var installed = false
    /// Canvas shift (doc pixels) made by the step being committed, and per history step (by entry id), so undo / redo
    /// can move the view by the same amount (nothing jumps on screen either way).
    nonisolated(unsafe) static var pendingShift: (doc: UUID, shift: CGPoint)?
    nonisolated(unsafe) static var stepShift: [UUID: CGPoint] = [:]
    /// The history entry each document's view currently matches.
    nonisolated(unsafe) private static var shownEntry: [UUID: UUID] = [:]

    static func installCommitHook() {
        guard !installed else { return }
        installed = true
        let previous = Document.willCommit
        Document.willCommit = { d in
            previous?(d)
            willCommit(d)
        }
        let previousCommit = Document.didCommit
        Document.didCommit = { d in
            previousCommit?(d)
            didCommit(d)
        }
        let previousRestore = Document.didRestore
        Document.didRestore = { d in
            previousRestore?(d)
            didRestore(d)
        }
    }

    static func willCommit(_ d: Document) {
        guard !inHook, d.history.indices.contains(d.historyIndex) else { return }
        inHook = true
        defer { inHook = false; movedCopies = [] }
        let before = d.committedState
        guard isArtboardDocument(d.state) else {
            if d.state.artboardOrigin != .zero { d.state.artboardOrigin = .zero }   // (only artboard documents have one)
            return
        }
        var st = d.state
        var changed = false
        if !isArtboardDocument(before), st.artboardOrigin != .zero, pendingShift?.doc != d.id {
            st.artboardOrigin = .zero   // the document just became an artboard document: its origin is the canvas corner
            changed = true
        }
        if liftNestedArtboards(&st, before: before) { changed = true }
        func rects(_ s: DocumentState) -> [UUID: CGRect] {
            var m: [UUID: CGRect] = [:]
            for l in boards(s) { m[l.id] = l.artboard?.rect }
            return m
        }
        let r0 = rects(before), r1 = rects(st)
        if r0 == r1, autoNest, nestMovedLayers(&st, before: before, selected: d.withoutDescendants(d.orderedSelection), copies: movedCopies) { changed = true }
        if changed { d.state = st }
        // Auto-size Canvas after any change. A step that set the canvas size itself (an artboard command sized it
        // already; Canvas Size, Crop, Image Size, Rotate Canvas) keeps the canvas it made.
        if ArtboardSettings.shared.prefs.autoSizeCanvas, before.width == d.state.width, before.height == d.state.height {
            autoSizeAll(d)
        }
    }

    static func didCommit(_ d: Document) {
        guard d.history.indices.contains(d.historyIndex) else { return }
        let entry = d.history[d.historyIndex].id
        if let p = pendingShift, p.doc == d.id, p.shift != .zero { stepShift[entry] = p.shift }
        if pendingShift?.doc == d.id { pendingShift = nil }
        shownEntry[d.id] = entry
    }

    /// Undo / redo / History panel: steps that moved the canvas corner move the view back (or again).
    static func didRestore(_ d: Document) {
        guard d.history.indices.contains(d.historyIndex) else { return }
        let now = d.historyIndex
        defer { shownEntry[d.id] = d.history[now].id }
        guard let from = shownEntry[d.id], let was = d.history.firstIndex(where: { $0.id == from }), was != now else { return }
        var s = CGPoint.zero
        if now < was {
            for k in (now + 1)...was { if let p = stepShift[d.history[k].id] { s.x -= p.x; s.y -= p.y } }
        } else {
            for k in (was + 1)...now { if let p = stepShift[d.history[k].id] { s.x += p.x; s.y += p.y } }
        }
        if s != .zero { keepView(d, dx: s.x, dy: s.y) }
    }

    /// Commits an artboard command after fitting the canvas to the artboards (see `autoSize`).
    static func commitSized(_ d: Document, _ name: String) {
        autoSize(d)
        d.commit(name)
    }

    /// Artboards can't sit inside groups or other artboards (Photoshop keeps them at the top level): lifts any that
    /// ended up in one (dragged in the Layers panel, or any other path) above their top-level ancestor.
    @discardableResult
    static func liftNestedArtboards(_ st: inout DocumentState, before: DocumentState) -> Bool {
        var moved = false
        var guardCount = 0
        while guardCount < 100, let nested = st.allLayers.first(where: { $0.isArtboard && st.parentID(of: $0.id) != nil }) {
            guardCount += 1
            var top = nested.id
            while let p = st.parentID(of: top) { top = p }
            guard let l = st.removeLayer(nested.id) else { break }
            st.insertLayer(l, above: top)
            moved = true
        }
        return moved
    }

    /// Ids of the layers clipped to `id` (the clipped layers right above it, bottom first).
    static func clippedLayers(above id: UUID, _ st: DocumentState) -> [UUID] {
        guard let l = st.layer(id), !l.isClipped else { return [] }
        let sib = st.siblings(of: id)
        guard let i = sib.firstIndex(where: { $0.id == id }) else { return [] }
        var out: [UUID] = []
        var j = i + 1
        while j < sib.count, sib[j].isClipped { out.append(sib[j].id); j += 1 }
        return out
    }

    /// Layers the step moved (pure translation) onto another artboard go into it; layers moved off their artboard
    /// entirely go back to the top level above it. Layers clipped to a moved layer go along (still clipped);
    /// `copies` (⌥-drag duplicates, new in this step) are placed by where they land. Returns true when something
    /// moved in the tree.
    static func nestMovedLayers(_ st: inout DocumentState, before: DocumentState, selected: [UUID], copies: Set<UUID> = []) -> Bool {
        var changed = false
        let moving = Set(selected)
        for id in selected {
            guard let now = st.layer(id), !now.isArtboard, !now.isFill, !now.isAdjustment,
                  let b1 = Compositor.shared.contentBounds(now, state: st), !b1.isNull, b1.width > 0 || b1.height > 0 else { continue }
            if let was = before.layer(id) {
                guard st.parentID(of: id) == before.parentID(of: id),
                      let b0 = Compositor.shared.contentBounds(was, state: before), !b0.isNull, abs(b1.width - b0.width) < 0.5, abs(b1.height - b0.height) < 0.5,
                      abs(b1.minX - b0.minX) >= 0.5 || abs(b1.minY - b0.minY) >= 0.5 else { continue }
            } else if !copies.contains(id) {
                continue
            }
            // a clipped layer whose base moves too travels with its base
            if now.isClipped, let base = st.clippingBase(of: id), moving.contains(base.id) { continue }
            let current = artboard(containing: st.parentID(of: id), st)
            let target = artboard(at: CGPoint(x: b1.midX, y: b1.midY), st)
            if target?.id == current?.id { continue }
            let anchor: UUID, inside: Bool
            if let t = target {
                anchor = t.id; inside = true
            } else if let c = current, let r = c.artboard?.rect, !r.intersects(b1) {
                anchor = c.id; inside = false
            } else { continue }
            let travelling = [id] + clippedLayers(above: id, st)
            var layers: [Layer] = []
            for t in travelling { if let l = st.removeLayer(t) { layers.append(l) } }
            guard !layers.isEmpty else { continue }
            layers[0].isClipped = false
            st.insertLayer(layers[0], above: anchor, inside: inside)
            var prev = layers[0].id
            for l in layers.dropFirst() {
                st.insertLayer(l, above: prev)
                prev = l.id
            }
            changed = true
        }
        return changed
    }

    // MARK: Commands

    static func makeLayer(_ name: String, rect: CGRect, background: RGBA? = .white, children: [Layer] = [], preset: String? = nil) -> Layer {
        var ab = Artboard(rect: rect.integral, background: background)
        ab.presetName = preset
        var l = Layer(name: name, content: .group(GroupContent(children: children, isExpanded: true, artboard: ab)))
        l.blendMode = .normal
        return l
    }

    /// New artboard. The first one in a normal document takes the layers it covers (they keep their place on the
    /// image and are clipped to it); layers outside stay on the pasteboard.
    @discardableResult
    static func create(_ d: Document, rect: CGRect, name: String? = nil, background: RGBA? = .white, preset: String? = nil, commitName: String = "New Artboard") -> UUID {
        let r = rect.integral
        var layer = makeLayer(name ?? nextName(d.state), rect: r, background: background, preset: preset)
        if !isArtboardDocument(d.state) {
            d.state.artboardOrigin = .zero   // artboard positions are measured from the canvas corner as it is now
            var adopted: [Layer] = [], kept: [Layer] = []
            for l in d.state.layers {
                let b = Compositor.shared.contentBounds(l, state: d.state)
                // empty layers (no bounds yet) go in too: they are about to be painted on the new page
                if l.isFill || l.isAdjustment || (b.map { $0.isNull || $0.width <= 0 || $0.intersects(r) } ?? true) { adopted.append(l) } else { kept.append(l) }
            }
            layer.children = adopted
            d.state.layers = kept + [layer]
        } else {
            d.state.layers.append(layer)
        }
        d.activeLayerID = layer.id
        d.selectedLayerIDs = [layer.id]
        commitSized(d, commitName)
        Compositor.shared.clearCaches()
        return layer.id
    }

    /// Duplicate Artboard: the artboard and its contents, placed in the next free spot to the right.
    @discardableResult
    static func duplicate(_ d: Document, _ ids: [UUID], side: ArtboardTool.Side = .right, commitName: String = "Duplicate Artboard") -> [UUID] {
        var out: [UUID] = []
        for id in ids {
            guard let src = d.state.layer(id), let ab = src.artboard else { continue }
            let nr = freeRect(d.state, size: ab.rect.size, beside: ab.rect, side: side)
            var copy = src.duplicated(newName: uniqueCopyName(src.name, d.state))
            copy.translate(dx: Double(nr.minX - ab.rect.minX), dy: Double(nr.minY - ab.rect.minY), document: true)
            d.state.insertLayer(copy, above: id)
            out.append(copy.id)
        }
        guard !out.isEmpty else { Beep.play(); return [] }
        d.activeLayerID = out.last
        d.selectedLayerIDs = Set(out)
        commitSized(d, commitName)
        Compositor.shared.clearCaches()
        return out
    }

    static func uniqueCopyName(_ base: String, _ st: DocumentState) -> String {
        let names = Set(st.allLayers.map(\.name))
        var n = base + " copy"
        var i = 2
        while names.contains(n) { n = base + " copy \(i)"; i += 1 }
        return n
    }

    /// Delete Artboard: with its contents, or (keepContents) only the artboard — its layers go to the top level.
    static func delete(_ d: Document, _ ids: [UUID], keepContents: Bool, commitName: String? = nil) {
        let boards = ids.filter { d.state.layer($0)?.isArtboard == true }
        guard !boards.isEmpty else { Beep.play(); return }
        var selectAfter: [UUID] = []
        for id in boards {
            guard let l = d.state.layer(id) else { continue }
            if keepContents {
                for c in l.children { d.state.insertLayer(c, below: id); selectAfter.append(c.id) }
            }
            d.state.removeLayer(id)
        }
        if selectAfter.isEmpty { selectAfter = d.state.layers.last.map { [$0.id] } ?? [] }
        d.activeLayerID = selectAfter.last
        d.selectedLayerIDs = Set(selectAfter)
        commitSized(d, commitName ?? (keepContents ? "Ungroup Artboards" : "Delete Artboard"))
        Compositor.shared.clearCaches()
    }

    /// Layer ▸ Ungroup Artboards: the contents stay where they are; the last artboard leaves artboard mode.
    static func ungroup(_ d: Document, _ ids: [UUID]) { delete(d, ids, keepContents: true, commitName: "Ungroup Artboards") }

    static func rename(_ d: Document, _ id: UUID, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let l = d.state.layer(id), l.name != n else { return }
        d.updateLayer(id) { $0.name = n }
        d.commit("Rename Artboard")
    }

    /// Artboard from Group: the group becomes an artboard fitted to its contents (canvas-sized when it is empty).
    @discardableResult
    static func fromGroup(_ d: Document, _ id: UUID) -> Bool {
        // (an artboard can't hold another artboard)
        guard let g = d.state.layer(id), g.isGroup, !g.isArtboard, !g.children.allLayers.contains(where: \.isArtboard) else { Beep.play(); return false }
        let b = Compositor.shared.contentBounds(g, state: d.state).flatMap { $0.isNull || $0.width < 1 || $0.height < 1 ? nil : $0 } ?? d.state.canvasCGRect
        d.updateLayer(id) { l in
            guard case .group(var gc) = l.content else { return }
            gc.artboard = Artboard(rect: b.integral)
            gc.isExpanded = true
            l.content = .group(gc)
            l.blendMode = .normal
        }
        d.activeLayerID = id
        d.selectedLayerIDs = [id]
        commitSized(d, "Artboard from Group")
        Compositor.shared.clearCaches()
        return true
    }

    static func setBackground(_ d: Document, _ ids: [UUID], _ bg: RGBA?, commit: Bool = true) {
        let boards = ids.filter { d.state.layer($0)?.isArtboard == true }
        guard !boards.isEmpty else { return }
        for id in boards {
            d.updateLayer(id) { l in
                guard case .group(var g) = l.content else { return }
                g.artboard?.background = bg
                l.content = .group(g)
            }
        }
        Compositor.shared.clearCaches()
        if commit { d.commit("Artboard Background") }
    }

    static func setRect(_ d: Document, _ id: UUID, _ r: CGRect, preset: String? = nil, commitName: String? = "Resize Artboard") {
        guard r.width >= 1, r.height >= 1, r.width.isFinite, r.height.isFinite else { return }
        d.updateLayer(id) { l in
            guard case .group(var g) = l.content, var ab = g.artboard else { return }
            ab.rect = r.integral
            ab.presetName = preset
            g.artboard = ab
            l.content = .group(g)
        }
        Compositor.shared.clearCaches()
        if let n = commitName { commitSized(d, n) }
    }

    /// Moves an artboard (and everything in it) to doc position `p`.
    static func move(_ d: Document, _ id: UUID, to p: CGPoint, commitName: String? = "Move Artboard") {
        guard let r = d.state.layer(id)?.artboard?.rect else { return }
        let dx = (p.x - r.minX).rounded(), dy = (p.y - r.minY).rounded()
        guard dx != 0 || dy != 0 else { return }
        d.updateLayer(id) { $0.translate(dx: Double(dx), dy: Double(dy), document: true) }
        Compositor.shared.clearCaches()
        if let n = commitName { commitSized(d, n) }
    }

    enum Alignment: String, CaseIterable { case left = "Left", centerX = "Horizontal Centers", right = "Right", top = "Top", centerY = "Vertical Centers", bottom = "Bottom" }

    /// Aligns the selected artboards' edges (or centres) with each other.
    static func align(_ d: Document, _ ids: [UUID], _ a: Alignment) {
        let boards = ids.compactMap { id in d.state.layer(id)?.artboard.map { (id, $0.rect) } }
        guard boards.count > 1 else { Beep.play(); return }
        let u = boards.map(\.1).reduce(boards[0].1) { $0.union($1) }
        for (id, r) in boards {
            var p = r.origin
            switch a {
            case .left: p.x = u.minX
            case .centerX: p.x = (u.midX - r.width / 2).rounded()
            case .right: p.x = u.maxX - r.width
            case .top: p.y = u.minY
            case .centerY: p.y = (u.midY - r.height / 2).rounded()
            case .bottom: p.y = u.maxY - r.height
            }
            move(d, id, to: p, commitName: nil)
        }
        commitSized(d, "Align Artboards")
    }

    /// Lays the selected artboards out in a row (or column) with `spacing` pixels between them, in their current order.
    static func distribute(_ d: Document, _ ids: [UUID], horizontal: Bool, spacing: CGFloat) {
        var boards = ids.compactMap { id in d.state.layer(id)?.artboard.map { (id, $0.rect) } }
        guard boards.count > 1 else { Beep.play(); return }
        boards.sort { horizontal ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
        var pos = horizontal ? boards[0].1.maxX : boards[0].1.maxY
        for (id, r) in boards.dropFirst() {
            let s = max(0, spacing.rounded())
            move(d, id, to: horizontal ? CGPoint(x: pos + s, y: r.minY) : CGPoint(x: r.minX, y: pos + s), commitName: nil)
            pos += s + (horizontal ? r.width : r.height)
        }
        commitSized(d, "Distribute Artboards")
    }

    /// Selected artboards (an artboard counts as selected when it or a layer in it is).
    static func selectedBoards(_ d: Document) -> [UUID] {
        var out: [UUID] = []
        for id in d.orderedSelection + (d.activeLayerID.map { [$0] } ?? []) {
            if let a = artboard(containing: id, d.state), !out.contains(a.id) { out.append(a.id) }
        }
        return out
    }
}
