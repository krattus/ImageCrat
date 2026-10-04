import ImageCratCore
import Foundation
import CoreGraphics

// Type on a path stays linked to the path or shape it was made from (`TextOnPath.source`):
// - editing that path (Direct Selection, Pen / anchor tools, Path Selection, transforms) or reshaping that shape (shape
//   tools, Free Transform, Properties) re-flows the text live, in the same history step as the edit;
// - the link breaks — the text keeps the path it has and owns it from then on, as in Photoshop — when the source is
//   deleted (or is no longer a shape), its subpath is gone, the Work Path is replaced by a new path, or the type side
//   changes: its type path edited directly, or the type layer moved / transformed.
// Following happens on every state change (`Document.stateDidChange`, cheap: only linked type layers are looked at and
// nothing is assigned unless the source changed); breaking only when a step is committed (`Document.willCommit`), so a
// transient state in the middle of a command never cuts a link.

enum TypePathLink {
    static func install() {
        let previousChange = Document.stateDidChange
        Document.stateDidChange = { d in previousChange?(d); sync(d, committing: false) }
        let previousCommit = Document.willCommit
        Document.willCommit = { d in previousCommit?(d); sync(d, committing: true) }
    }

    // MARK: Sources

    /// The subpaths of a source (document coordinates): a path in the Paths panel, or a shape layer's outline.
    static func subpaths(_ st: DocumentState, pathID: UUID?, layerID: UUID?) -> [Subpath]? {
        if let pid = pathID { return st.paths.first { $0.id == pid }?.path.subpaths }
        if let lid = layerID, let s = st.layer(lid)?.shape { return TypeOnPath.subpaths(of: s) }
        return nil
    }

    /// The link for type made on `sp` (one of `TypeOnPath.candidates`): the active path first, then the active shape
    /// layer, then the other visible shape layers (the order the Type tool hits them in).
    static func source(for sp: Subpath, in d: Document) -> TextPathSource? {
        var refs: [(UUID?, UUID?)] = []
        if let pid = d.activePathID { refs.append((pid, nil)) }
        if let a = d.activeLayerID, d.state.layer(a)?.isShape == true { refs.append((nil, a)) }
        for (l, _) in d.state.layers.flattenedForDisplay(includeCollapsed: true) where l.isShape && l.id != d.activeLayerID { refs.append((nil, l.id)) }
        for (pid, lid) in refs {
            guard let subs = subpaths(d.state, pathID: pid, layerID: lid), let i = subs.firstIndex(of: sp) else { continue }
            return TextPathSource(pathID: pid, layerID: lid, subpath: i, subpathCount: subs.count, synced: sp)
        }
        return nil
    }

    // MARK: Sync

    /// Type layers with a linked path, in the layer tree (groups included).
    static func linkedLayers(_ layers: [Layer], into out: inout [UUID]) {
        for l in layers {
            switch l.content {
            case .text(let t): if t.pathText?.source != nil { out.append(l.id) }
            case .group(let g): linkedLayers(g.children, into: &out)
            default: break
            }
        }
    }

    /// Brings every linked type layer in step with its source. `committing`: a step is being recorded, links that can't
    /// be followed any more break now (while editing they are only skipped).
    static func sync(_ d: Document, committing: Bool) {
        var ids: [UUID] = []
        linkedLayers(d.state.layers, into: &ids)
        guard !ids.isEmpty else { return }
        var st = d.state
        var changed = false
        for id in ids {
            guard let t = st.layer(id)?.text, let pt = t.pathText, let src = pt.source else { continue }
            switch resolve(st, t, pt, src) {
            case .inStep:
                continue
            case .reindexed(let s):
                var n = pt; n.source = s
                st.updateLayer(id) { $0.text?.pathText = n }
                changed = true
            case .follow(let sub, let s):
                var n = pt
                retarget(&n, to: t.transform.isIdentity ? VectorPath(subpaths: [sub]) : VectorPath(subpaths: [sub]).applying(t.transform.inverted()))
                n.source = s
                st.updateLayer(id) { $0.text?.pathText = n }
                changed = true
            case .broken:
                guard committing else { continue }
                st.updateLayer(id) { $0.text?.pathText?.source = nil }
                changed = true
            }
        }
        if changed { d.state = st }
    }

    enum Outcome { case inStep, reindexed(TextPathSource), follow(Subpath, TextPathSource), broken }

    static func resolve(_ st: DocumentState, _ t: TextContent, _ pt: TextOnPath, _ src: TextPathSource) -> Outcome {
        // the type side changed (type path edited, layer moved / transformed): the text owns its path now
        let docPath = t.transform.isIdentity ? pt.path : pt.path.applying(t.transform)
        guard docPath.subpaths.count == 1, close(docPath.subpaths[0], src.synced) else { return .broken }
        guard let subs = subpaths(st, pathID: src.pathID, layerID: src.layerID) else { return .broken }
        var s = src
        if subs.count != src.subpathCount {
            // components added or removed: find the subpath again (unchanged), else keep the index if it can only have
            // moved up (components added after it)
            if let i = subs.firstIndex(where: { close($0, src.synced) }) {
                s.subpath = i; s.subpathCount = subs.count
                return .reindexed(s)
            }
            guard subs.count > src.subpathCount, src.subpath < subs.count else { return .broken }
            s.subpathCount = subs.count
        }
        guard s.subpath < subs.count, subs[s.subpath].points.count >= 2 else { return .broken }
        let sub = subs[s.subpath]
        if sub == src.synced { return s == src ? .inStep : .reindexed(s) }
        s.synced = sub
        return .follow(sub, s)
    }

    /// New path for the text: the start point keeps its place along a closed path (same share of the perimeter) and
    /// its distance from the start of an open one, clamped to the new length.
    static func retarget(_ p: inout TextOnPath, to path: VectorPath) {
        let oldTotal = PathSampler(p.path).total
        let sampler = PathSampler(path)
        let total = sampler.total
        var off = CGFloat(p.startOffset)
        if sampler.closed, oldTotal > 0 { off = off / oldTotal * total }
        p.startOffset = Double(min(max(0, off), total))
        p.path = path
    }

    static func close(_ a: Subpath, _ b: Subpath, eps: CGFloat = 1e-3) -> Bool {
        guard a.closed == b.closed, a.points.count == b.points.count else { return false }
        func near(_ p: CGPoint, _ q: CGPoint) -> Bool { abs(p.x - q.x) <= eps && abs(p.y - q.y) <= eps }
        for (p, q) in zip(a.points, b.points) where !near(p.anchor, q.anchor) || !near(p.inControl, q.inControl) || !near(p.outControl, q.outControl) {
            return false
        }
        return true
    }

    // MARK: Explicit breaks

    /// The Work Path is about to be replaced by a new path: type made on it keeps its path (unlinked).
    static func unlink(_ d: Document, pathID: UUID) {
        var ids: [UUID] = []
        linkedLayers(d.state.layers, into: &ids)
        let hit = ids.filter { d.state.layer($0)?.text?.pathText?.source?.pathID == pathID }
        guard !hit.isEmpty else { return }
        var st = d.state
        for id in hit { st.updateLayer(id) { $0.text?.pathText?.source = nil } }
        d.state = st
    }
}
