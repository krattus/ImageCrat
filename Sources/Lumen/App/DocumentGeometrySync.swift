import Foundation
import CoreGraphics
import ImageCratCore

/// Frame-animation frames, layer comps, video-timeline keyframes and the tool overlays (slices, notes, count marks,
/// colour samplers) store document coordinates outside the layers. A whole-document geometry command (Image Size,
/// Canvas Size, Rotate / Flip Canvas, Crop, Reveal All, growing the canvas for an artboard) has to take them along —
/// otherwise selecting a frame, applying a comp or playing the timeline puts the layers back where they were before
/// the command.
extension AppActions {
    /// Frames as left by the last `syncStoredGeometry` (the Timeline's commit hook must not re-base them again).
    static var lastSyncedFrames: [AnimationFrame]?

    /// `old`: the state before the command; `st`: the transformed state (layers already mapped by `h`).
    static func syncStoredGeometry(from old: DocumentState, to st: inout DocumentState, h: Homography) {
        /// The frame / comp offset of a layer, carried through the transform: new anchor + mapped offset.
        func remap(_ p: CGPoint, _ a0: CGPoint, _ a1: CGPoint) -> CGPoint {
            let moved = h.apply(CGPoint(x: a0.x + (p.x - a0.x), y: a0.y + (p.y - a0.y)))
            let base = h.apply(a0)
            return CGPoint(x: a1.x + (moved.x - base.x), y: a1.y + (moved.y - base.y))
        }
        if !st.frames.isEmpty {
            for i in st.frames.indices {
                for (id, p) in st.frames[i].positions {
                    guard let lo = old.layer(id), let ln = st.layer(id), let a0 = Animation.anchor(lo), let a1 = Animation.anchor(ln) else { continue }
                    st.frames[i].positions[id] = remap(p, a0, a1)
                }
            }
            lastSyncedFrames = st.frames
        }
        if !st.layerComps.isEmpty {
            for i in st.layerComps.indices {
                for (id, e) in st.layerComps[i].entries {
                    guard let p = e.position, let lo = old.layer(id), let ln = st.layer(id), let a0 = anchor(lo, old), let a1 = anchor(ln, st) else { continue }
                    st.layerComps[i].entries[id]?.position = remap(p, a0, a1)
                }
            }
        }
        if var tl = st.videoTimeline {
            // Position keys are layer centres; Transform keys hold an absolute scale and rotation.
            let a = h.isAffine ? h.affine : nil
            let det = a.map { $0.a * $0.d - $0.b * $0.c } ?? 1
            let k = a.map { Double($0.scaleFactor) } ?? 1
            let rot = (a != nil && det > 0) ? Double(a!.rotationAngle) * 180 / .pi : 0
            for ti in tl.tracks.indices {
                for (prop, keys) in tl.tracks[ti].keyframes {
                    tl.tracks[ti].keyframes[prop] = keys.map { key in
                        var n = key
                        switch key.value {
                        case .point(let p): n.value = .point(h.apply(p))
                        case .transform(let s, let r): if det > 0 { n.value = .transform(scale: s * k, rotation: r + rot) }
                        default: break
                        }
                        return n
                    }
                }
            }
            st.videoTimeline = tl
        }
        // Slices, notes, count marks and colour samplers are mapped by the callers through `ToolDocData.mapped`.
    }

    static func syncStoredGeometry(from old: DocumentState, to st: inout DocumentState, dx: Double, dy: Double) {
        syncStoredGeometry(from: old, to: &st, h: Homography(affine: CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))))
    }
}
