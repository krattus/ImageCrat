import SwiftUI
import ImageCratCore

/// Layer ▸ Matting: Defringe, Remove Black / White Matte, Color Decontaminate (edge colour clean-up of cut-outs).
enum Matting {
    // MARK: Pixel operations (RGBA premultiplied buffers, in place on a copy)

    /// Straight colour of every pixel within `band` gets the colour of the nearest "pure" pixel (multi-source BFS).
    /// `isSource(i)` marks pixels whose colour is trusted; `inBand(i)` marks pixels to recolour. Alpha is kept.
    /// `amount` 0…1 mixes between the original and the replacement colour.
    private static func propagate(_ b: PixelBuffer, isSource: (Int) -> Bool, inBand: (Int) -> Bool, maxDistance: Int, amount: Double) {
        let w = b.width, h = b.height, n = w * h
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        let rb = b.bytesPerRow
        var owner = [Int32](repeating: -1, count: n)
        var dist = [Int32](repeating: Int32.max, count: n)
        var queue = [Int32](); queue.reserveCapacity(n / 4)
        for i in 0..<n where isSource(i) {
            // only sources that touch a band pixel seed the search
            let x = i % w, y = i / w
            var touches = false
            for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
                let xx = x + dx, yy = y + dy
                if xx >= 0, yy >= 0, xx < w, yy < h, inBand(yy * w + xx) { touches = true }
            } }
            if touches { owner[i] = Int32(i); dist[i] = 0; queue.append(Int32(i)) }
        }
        var head = 0
        while head < queue.count {
            let i = Int(queue[head]); head += 1
            let x = i % w, y = i / w
            let d = dist[i] + 1
            if d > maxDistance { continue }
            for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                let j = yy * w + xx
                if dist[j] <= d || !inBand(j) { continue }
                dist[j] = d; owner[j] = owner[i]; queue.append(Int32(j))
            } }
        }
        let k = Float(max(0, min(1, amount)))
        var out = [UInt8](repeating: 0, count: 4 * n)
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            let q = p + y * rb + x * 4
            out[i * 4] = q[0]; out[i * 4 + 1] = q[1]; out[i * 4 + 2] = q[2]; out[i * 4 + 3] = q[3]
            guard inBand(i), owner[i] >= 0, owner[i] != Int32(i) else { continue }
            let o = Int(owner[i]); let ox = o % w, oy = o / w
            let s = p + oy * rb + ox * 4
            let sa = Float(max(1, s[3])), a = Float(q[3])
            for c in 0..<3 {
                let src = Float(s[c]) / sa            // straight 0…1
                let cur = a > 0 ? Float(q[c]) / a : src
                let v = cur + (src - cur) * k
                out[i * 4 + c] = UInt8(max(0, min(a, (v * a).rounded())))
            }
        } }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x, q = p + y * rb + x * 4
            q[0] = out[i * 4]; q[1] = out[i * 4 + 1]; q[2] = out[i * 4 + 2]
        } }
        b.markDirty()
    }

    /// Chamfer (8-neighbour) distance of every pixel to the nearest pixel where `isEdge` holds, capped at `cap`.
    private static func distanceTo(_ w: Int, _ h: Int, cap: Int, _ isEdge: (Int) -> Bool) -> [Int32] {
        var d = [Int32](repeating: Int32(cap + 1), count: w * h)
        var queue = [Int32]()
        for i in 0..<(w * h) where isEdge(i) { d[i] = 0; queue.append(Int32(i)) }
        var head = 0
        while head < queue.count {
            let i = Int(queue[head]); head += 1
            let nd = d[i] + 1
            if nd > cap { continue }
            let x = i % w, y = i / w
            for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
                let xx = x + dx, yy = y + dy
                guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                let j = yy * w + xx
                if d[j] > nd { d[j] = nd; queue.append(Int32(j)) }
            } }
        }
        return d
    }

    /// Defringe: the colour of pixels within `width` px of the layer edge is replaced with the colour of nearby interior pixels.
    static func defringe(_ b: PixelBuffer, width: Int) {
        let w = b.width, h = b.height
        let p = b.data.assumingMemoryBound(to: UInt8.self), rb = b.bytesPerRow
        @inline(__always) func alpha(_ i: Int) -> UInt8 { p[(i / w) * rb + (i % w) * 4 + 3] }
        let wd = max(1, width)
        // Edge = transparent pixels or the image border next to content.
        let dist = distanceTo(w, h, cap: wd + 1) { alpha($0) < 8 }
        propagate(b, isSource: { alpha($0) >= 250 && dist[$0] > wd }, inBand: { alpha($0) >= 8 && dist[$0] <= wd }, maxDistance: wd * 3 + 4, amount: 1)
    }

    /// Color Decontaminate: semi-transparent edge pixels take the colour of nearby opaque pixels.
    static func decontaminate(_ b: PixelBuffer, amount: Double = 1, width: Int = 3) {
        let w = b.width, h = b.height
        let p = b.data.assumingMemoryBound(to: UInt8.self), rb = b.bytesPerRow
        @inline(__always) func alpha(_ i: Int) -> UInt8 { p[(i / w) * rb + (i % w) * 4 + 3] }
        let dist = distanceTo(w, h, cap: width + 1) { alpha($0) < 250 }
        propagate(b, isSource: { dist[$0] > 1 }, inBand: { alpha($0) > 0 && alpha($0) < 250 || (dist[$0] <= 1 && alpha($0) > 0) },
                  maxDistance: width * 4 + 8, amount: amount)
    }

    /// Remove Black / White Matte: undo colour that was blended against black or white at soft edges.
    static func removeMatte(_ b: PixelBuffer, white: Bool) {
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<b.height {
            let row = p + y * b.bytesPerRow
            for x in 0..<b.width {
                let q = row + x * 4
                let a = Int(q[3])
                if a == 0 || a == 255 { continue }
                for c in 0..<3 {
                    let pm = Int(q[c])
                    // straight observed colour C = pm/a (0…255 scale); true colour T with C = T·α + M·(1−α).
                    // Premultiplied result T·α = C·α − M·(1−α)·α … expressed with pm = C·α/255:
                    let v: Int
                    if white {
                        // T·α = C − (1−α)  (0…255 scale, C = pm·255/a)
                        let cStraight = pm * 255 / a
                        v = cStraight - (255 - a)
                    } else {
                        // T·α = C
                        v = pm * 255 / a
                    }
                    q[c] = UInt8(max(0, min(a, v)))
                }
            }
        }
        b.markDirty()
    }

    // MARK: Commands

    /// Runs `f` on the active raster layer's pixels as one undoable step.
    static func run(_ name: String, _ f: (PixelBuffer) -> Void) {
        guard let d = AppActions.doc, let id = d.activeLayerID, let l = d.state.layer(id) else { NSSound.beep(); return }
        if !l.isRaster { AppActions.offerRasterize(layer: id); return }
        guard let (w, _) = d.beginPixelEdit(layerID: id, target: .content, coverCanvas: false) else { return }
        f(w)
        w.markDirty()
        d.commit(name)
        d.setNeedsRender()
    }

    static func register() {
        MenuRegistry.add("Layer", "Defringe…", submenu: "Matting") { DialogRegistry.show("edits.defringe") }
        MenuRegistry.add("Layer", "Remove Black Matte", submenu: "Matting") { run("Remove Black Matte") { removeMatte($0, white: false) } }
        MenuRegistry.add("Layer", "Remove White Matte", submenu: "Matting") { run("Remove White Matte") { removeMatte($0, white: true) } }
        MenuRegistry.add("Layer", "Color Decontaminate", submenu: "Matting") { run("Color Decontaminate") { decontaminate($0) } }
        DialogRegistry.register("edits.defringe") { AnyView(DefringeDialog()) }
    }
}

struct DefringeDialog: View {
    @State private var width: Double = 1
    var body: some View {
        DialogFrame(title: "Defringe", width: 280, onOK: {
            let n = Int(width.rounded())
            Matting.run("Defringe") { Matting.defringe($0, width: n) }
        }) {
            ValueSlider(label: "Width", value: $width, range: 1...200, unit: " px")
        }
    }
}
