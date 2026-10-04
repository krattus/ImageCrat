import AppKit
import CoreImage
import ImageCratCore

/// Regression checks for bugs found by the tool robot that are not already pinned down by a scenario in
/// `QAToolChecks` / `QAPending`. Index of all of them (scenario name → bug):
///
///   tool/cloneStamp, tool/healing, tool/spotHealing/stroke   stroke preview stayed on the layer after the stroke
///   tool/cloneStamp/then-move-no-ghost                       …and showed as a ghost when the layer was moved
///   tool/crop/drag-return                                    Undo did nothing while the Crop tool was active
///   tool/crop/stale-after-resize                             crop box survived Canvas Size and cropped back
///   tool/crop/pending-box-then-image-size                    Image Size with a pending crop box scaled wrongly
///   tool/crop/straighten, tool/perspectiveCrop               one gesture recorded two undo steps
///   tool/crop/drag-return/rot30                              crop box hit-testing / drawing in a rotated view
///   tool/zoom/drag-rect/rot30                                zoom-drag in a rotated view
///   tool/marquee/click-inside, tool/marquee/outside-canvas   empty history steps
///   tool/polygonLasso, tool/magneticLasso                    unfinished outline survived a tool switch
///   tool/polygonLasso/shift-constrains                       Shift constrained the preview only
///   tool/move/hidden, tool/move/locked-*                     hidden layer moved; empty "Nudge" steps
///   tool/<paint tool>/alpha-lock, tool/magicEraser/alpha-lock transparency lock ignored
///   tool/removeTool|patch|contentAwareMove/refuses/*          locked / hidden layers edited
///   tool/*/mask-of-locked-layer, mask-of-hidden-layer         mask of a locked / hidden layer painted
///   tool/pathSelect|directSelect|addAnchor…/locked-*          locked shape layers edited
///   tool/artboard/locked, tool/artboard/grow-canvas-keeps-guides
///   tool/curvaturePen, tool/curvaturePen/undo-to-start       undone points came back; tool stuck; uncommitted edit
///   tool/text/unchanged-default-name                         uncommitted rename
///   tool/text/click-jitter/z0.25                             click became a tiny paragraph box when zoomed out
///   tool/text/box-resize                                     editor lost the keyboard focus after a handle drag
///   tool/text/document-switch, tool/text/document-close      text lost / layer left hidden / editor stuck
///   tool/text/cancel-keeps-layer-selection                   cancelled type click selected the top layer
///   tool/text/locked-layer                                   locked type layer editable
///   tool/count                                               empty "Move Count" step
///   canvas/delete-key/*                                      Delete cleared pixels of locked / hidden layers
///   pending/<session>/<command>/hooked|direct                pending edits vs. commands (the reported bug class)
///   pending/*/guide-from-ruler                               a guide dropped the pending transform
///   pending/*/arrow-keys                                     arrow keys discarded a pending warp
///   pending/*/shortcuts-ignored, pending/*/document-switch   commands / document changes in the middle of a drag
///   pending/tool-data-follows-geometry                       slices, notes, counts, samplers left behind by crop / resize
enum QARegressions {
    typealias R = ToolRobot
    static func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x + 0.37, y: y + 0.41) }

    static func scenario(_ name: String, _ fixture: String, tool: ToolKind = .move, _ body: (R, Document, QAFixture) -> Void) {
        QA.scenario("regress/\(name)") {
            QAScenarios.resetToolSettings()
            guard let f = QAFixtures.all(QA.out).first(where: { $0.name == fixture }) else { return }
            let r = R()
            let d = r.open(f.state, name: fixture)
            f.apply(to: d)
            r.select(.hand); r.select(tool)
            body(r, d, f)
            if r.doc === d { r.select(.hand); QAInvariant.idle(r, "after") }
            r.closeAll()
        }
    }

    static func run() {
        // Generative layer: choosing another variation after the layer was moved put it back where it was generated.
        scenario("generative-variation-follows-moved-layer", "generative") { r, d, f in
            AppModel.shared.moveShowTransform = false
            r.dragLine(P(100, 70), P(130, 95), steps: 3)
            let moved = QAToolChecks.bounds(d, f.active)
            GenPipeline.selectVariation(d, layerID: f.active!, index: 1)
            QA.check(QAToolChecks.near(QAToolChecks.bounds(d, f.active), moved), "the selected variation appears where the layer is now",
                     "\(QAMeasure.describe(moved)) → \(QAMeasure.describe(QAToolChecks.bounds(d, f.active)))")
        }
        // Masks stay aligned with the content through a transform: linked masks are transformed, unlinked stay put.
        for (fixture, linked) in [("mask-content", true), ("mask-unlinked", false)] {
            scenario("transform-\(fixture)", fixture) { r, d, f in
                guard let mt = r.toolOf(.move, MoveTool.self) else { return }
                // the mask hides x 60…90 of the block at 60…160: scale ×1.4 from the block's top-left corner
                let q = Quad(rect: QAFixtures.box)
                let target = q.tl + (q.br - q.tl) * 1.4
                r.down(q.br); r.drag(target); r.up(target)
                QA.check(mt.session != nil, "transform started from the box handle")
                r.key(R.kReturn, "\r")
                guard let m = d.state.layer(f.active)?.mask else { QA.check(false, "mask kept"); return }
                func maskAt(_ x: Int, _ y: Int) -> UInt8 {
                    let lx = x - m.origin.x, ly = y - m.origin.y
                    return lx >= 0 && ly >= 0 && lx < m.buffer.width && ly < m.buffer.height ? m.buffer.alpha(lx, ly) : m.outsideValue
                }
                if linked {
                    QA.check(maskAt(95, 80) < 40 && maskAt(110, 80) > 215, "a linked mask is scaled with the content (hidden strip now 60…102)", "\(maskAt(95, 80)) \(maskAt(110, 80))")
                } else {
                    QA.check(maskAt(95, 80) > 215 && maskAt(80, 80) < 40, "an unlinked mask stays where it was (hidden strip still 60…90)", "\(maskAt(95, 80)) \(maskAt(80, 80))")
                }
            }
        }
        scenario("transform-vector-mask", "vector-mask") { r, d, f in
            let v0 = d.state.layer(f.active)!.vectorMask!.bounds
            let q = Quad(rect: QAFixtures.box)
            let target = q.tl + (q.br - q.tl) * 1.4
            r.down(q.br); r.drag(target); r.up(target); r.key(R.kReturn, "\r")
            let v1 = d.state.layer(f.active)!.vectorMask!.bounds
            QA.check(abs(v1.width - v0.width * 1.4) < 1 && abs(v1.minX - (60 + (v0.minX - 60) * 1.4)) < 1, "the vector mask is transformed with the content",
                     "\(QAMeasure.describe(v0)) → \(QAMeasure.describe(v1))")
        }
        // Layer effects: Free Transform leaves their sizes alone; Image Size scales them only with "Scale Styles".
        scenario("effects-scale-option", "effects") { r, d, f in
            let fx0 = d.state.layer(f.active)!.effects
            let q = Quad(rect: QAFixtures.box)
            let target = q.tl + (q.br - q.tl) * 1.4
            r.down(q.br); r.drag(target); r.up(target); r.key(R.kReturn, "\r")
            QA.check(d.state.layer(f.active)!.effects == fx0, "Free Transform does not change the layer style")
            AppActions.imageSize(width: 480, height: 320, resolution: 72, scaleStyles: false)
            QA.check(d.state.layer(f.active)!.effects == fx0, "Image Size without Scale Styles keeps the effect sizes")
            d.undo()
            AppActions.imageSize(width: 480, height: 320, resolution: 72, scaleStyles: true)
            let fx1 = d.state.layer(f.active)!.effects
            QA.check(abs(fx1.dropShadow.distance - fx0.dropShadow.distance * 2) < 0.01 && abs(fx1.stroke.size - fx0.stroke.size * 2) < 0.01, "Image Size with Scale Styles scales them",
                     "shadow \(fx1.dropShadow.distance) stroke \(fx1.stroke.size)")
        }
        // Esc leaves nothing behind for every session type (Content-Aware Scale kept its preview override).
        for s in QAPending.sessions() where !s.midDrag && s.tool == .move {
            QA.scenario("regress/esc-cancels/\(s.name)") {
                var fixtures: [String: QAFixture] = [:]
                for f in QAFixtures.all(QA.out) { fixtures[f.name] = f }
                let (r, d, f) = QAPending.fresh(s, fixtures)
                let start = QASnapshot(d)
                s.begin(r, d, f)
                QA.check(s.pending(r), "\(s.name) is pending")
                r.drawOverlay()
                r.key(R.kEsc, "\u{1b}")
                QA.check(!s.pending(r), "Esc ends \(s.name)")
                QA.check(QAMeasure.fingerprint(d.state) == start.print && d.historyIndex == start.historyIndex, "Esc leaves the document exactly as it was", "\(d.history.map(\.name))")
                QA.check(QAMeasure.diff(r.liveComposite(), QAMeasure.composite(d.state)) < 0.01, "…and nothing of the preview on screen")
                r.select(.hand)
                QAInvariant.idle(r, s.name)
                r.closeAll()
            }
        }
        // A floating selection being transformed + a command that bypasses the hooks: the pixels are put back, the
        // command's own change (here: the new selection) is kept, and no history state contains the hole.
        scenario("float-transform-then-unhooked-select-all", "raster") { r, d, f in
            d.setSelection(QAFixtures.rectSelection(QAPending.selRect), commitName: "sel")
            AppActions.freeTransform()
            guard let s = r.toolOf(.move, MoveTool.self)?.session else { QA.check(false, "session"); return }
            let q = s.quad
            r.down(q.center); r.drag(q.center + CGPoint(x: 30, y: 20)); r.up(q.center + CGPoint(x: 30, y: 20))
            let live = r.liveComposite()
            AppActions.selectAll()
            QA.check(!(r.toolOf(.move, MoveTool.self)?.isBusy ?? true), "the floating move is applied before the other step is recorded")
            QA.check(d.state.selection?.opaqueBounds()?.width == d.state.width, "the command's own selection is kept")
            QA.check(QAMeasure.diff(QAMeasure.composite(d.state), live) < 0.6, "the moved pixels are in the layer")
            for h in d.history.suffix(2) { QA.check(QAMeasure.diff(QAMeasure.composite(h.state), live) < 0.6, "history step '\(h.name)' has the pixels in place") }
        }
        // History jump underneath a pending transform (History panel without the click hook, scripting): the box goes away.
        scenario("history-jump-under-pending-transform", "text") { r, d, f in
            r.dragLine(P(100, 70), P(110, 80), steps: 2)             // something to undo
            AppActions.freeTransform()
            guard let mt = r.toolOf(.move, MoveTool.self), let s = mt.session else { QA.check(false, "session"); return }
            let q = s.quad
            r.down(q.br); r.drag(q.br + CGPoint(x: 30, y: 20)); r.up(q.br + CGPoint(x: 30, y: 20))
            d.undo()
            r.drawOverlay()
            QA.check(!mt.isBusy && d.contentOverrides.isEmpty, "a history jump drops the pending transform box")
            QA.check(QAMeasure.diff(r.liveComposite(), QAMeasure.composite(d.state)) < 0.01, "the canvas shows the restored state")
            if let a = d.activeLayerID { QAInvariant.handlesMatchContent(d, a, "after undo") }
        }
    }
}
