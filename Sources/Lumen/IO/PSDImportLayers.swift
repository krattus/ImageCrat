import Foundation
import CoreGraphics
import ImageCratCore

// Layer records → Lumen layers: kind detection, shared attributes (masks, blending, locks, labels) and the group tree.

extension PSDImporter {
    /// Rebuilds the group hierarchy (records run bottom → top; a type-3 record opens a group, type 1/2 closes it).
    func buildTree() -> [Layer] {
        PSDSmart.prefetch(self)
        var stack: [[Layer]] = [[]]
        for i in records.indices {
            let r = records[i]
            records[i].planes = [:]   // the planes are only needed once: release them as the layers are built
            if let s = r.section {
                if s == 3 {
                    stack.append([])
                } else {
                    let children = stack.count > 1 ? stack.removeLast() : []
                    var g = Layer(name: r.name, content: .group(GroupContent(children: children, isExpanded: s == 1)))
                    g.blendMode = BlendMode(psdKey: r.sectionBlend ?? r.blendKey)
                    if let ab = artboard(r) {
                        g.content = .group(GroupContent(children: children, isExpanded: s == 1, artboard: ab))
                        report.add(.editable, layer: r.name, feature: "Artboard", detail: "\(Int(ab.rect.width)) × \(Int(ab.rect.height)) px")
                    }
                    common(&g, r, shapeUsesVectorMask: false)
                    stack[stack.count - 1].append(g)
                }
                continue
            }
            if let l = layer(r) { stack[stack.count - 1].append(l) }
        }
        while stack.count > 1 { let c = stack.removeLast(); stack[stack.count - 1] += c }
        return stack[0]
    }

    /// One non-group record → a layer of the matching kind. Anything that fails falls back to the stored pixels.
    func layer(_ r: PSDRecord) -> Layer? {
        var l: Layer
        var shapeUsesVectorMask = false
        if let restored = lumenLayer(r) {
            l = restored
            shapeUsesVectorMask = l.isShape
        } else if let kind = PSDAdjust.key(of: r) {
            switch PSDAdjust.settings(kind, r, self) {
            case .ok(let s, let note):
                l = Layer(name: r.name, content: .adjustment(s))
                report.add(note == nil ? .editable : .substituted, layer: r.name, feature: "Adjustment", detail: s.kind.displayName + (note.map { " — \($0)" } ?? ""))
            case .unsupported(let why):
                // an adjustment has no pixels of its own to fall back to
                report.add(.skipped, layer: r.name, feature: "Adjustment", detail: why)
                return nil
            }
        } else if let paint = PSDVector.fillPaint(r, self) {
            let vm = PSDVector.vectorMask(r, self)
            if let vm, !vm.disabled, !vm.path.isEmpty {
                var sc = ShapeContent(geometry: PSDVector.liveGeometry(r, vm.path, self) ?? .path(vm.path), fill: paint.paint)
                let stroke = PSDVector.stroke(r, self)
                if let s = stroke { sc.stroke = s.style; if !s.fillEnabled { sc.fill = .none } }
                l = Layer(name: r.name, content: .shape(sc))
                shapeUsesVectorMask = true
                var what = sc.geometry.kindName + ", " + paint.what
                if let s = stroke, !s.style.paint.isNone { what += ", stroke \(PSDImportReport.num(s.style.width)) px" }
                report.add(.editable, layer: r.name, feature: "Shape", detail: what)
                for n in paint.notes + (stroke?.notes ?? []) { report.add(.substituted, layer: r.name, feature: "Shape", detail: n) }
            } else {
                l = Layer(name: r.name, content: .fill(FillContent(paint: paint.paint)))
                report.add(.editable, layer: r.name, feature: "Fill layer", detail: paint.what)
                for n in paint.notes { report.add(.substituted, layer: r.name, feature: "Fill layer", detail: n) }
            }
        } else if let b = r.block("TySh") {
            do {
                let stored = pixels(r)
                var t = try PSDText.content(PSDCursor(bytes, b), self, layer: r.name, pixelWidth: stored != nil ? r.rect.width : nil)
                // a missing font: show what Photoshop drew until the type is edited, as Photoshop does
                if !t.missingFonts.isEmpty, let p = stored { t = t.capturingStoredPixels(p, origin: r.rect.origin) }
                l = Layer(name: r.name, content: .text(t))
            } catch {
                guard let p = pixelLayer(r) else { report.add(.skipped, layer: r.name, feature: "Type", detail: "The text data is unreadable (\(error)) and the layer has no pixels."); return nil }
                l = p
                report.add(.flattened, layer: r.name, feature: "Type", detail: "The text data could not be read (\(error)); the layer keeps its pixels.")
            }
        } else if r.has("SoLd") || r.has("SoLE") || r.has("PlLd") {
            if let so = PSDSmart.layer(r, self) { l = so } else if let p = pixelLayer(r) { l = p } else { return nil }
        } else {
            l = pixelLayer(r) ?? emptyLayer(r)
        }
        common(&l, r, shapeUsesVectorMask: shapeUsesVectorMask)
        restoreLumenMasks(&l, r)
        if PSDImporter.keepStoredPixels, !l.isRaster, let p = pixels(r) { stored[l.id] = RasterContent(buffer: p, origin: r.rect.origin) }
        return l
    }

    func pixelLayer(_ r: PSDRecord) -> Layer? {
        guard let buf = pixels(r) else { return nil }
        return Layer.raster(name: r.name, buffer: buf, origin: r.rect.origin)
    }

    /// A layer without pixels ("empty layer"): canvas-sized like File ▸ New Layer, unless the canvas is huge.
    func emptyLayer(_ r: PSDRecord) -> Layer {
        if !r.rect.isEmpty && !truncated { report.add(.info, layer: r.name, feature: "Pixels", detail: "The layer's pixel data could not be read; it is empty.") }
        let small = W * H > 16_000_000
        return Layer.raster(name: r.name, width: small ? 1 : W, height: small ? 1 : H)
    }

    // MARK: Attributes shared by every layer kind

    func common(_ l: inout Layer, _ r: PSDRecord, shapeUsesVectorMask: Bool) {
        if !l.isGroup {
            let m = BlendMode(psdKey: r.blendKey)
            l.blendMode = m == .passThrough ? .normal : m
        }
        l.opacity = Double(r.opacity) / 255
        l.isClipped = r.clipping != 0
        l.isVisible = r.flags & 0x02 == 0
        let isBackground = r.name == "Background" && records.first?.name == r.name
        if r.flags & 0x01 != 0, !isBackground { l.locks.transparency = true }
        for b in r.blocks {
            var c = PSDCursor(bytes, b.range)
            switch b.key {
            case "iOpa": if let v = try? c.u8() { l.fillOpacity = Double(v) / 255 }
            case "lclr": if let v = try? c.u16() { l.colorLabel = PSDImporter.labels[v] ?? .none }
            case "lspf":
                // the bottom "Background" layer is always position/transparency locked in Photoshop; Lumen's is a plain layer
                if let v = try? c.u32(), !(isBackground && v & 0x8000_0002 == 0) {
                    l.locks = LayerLocks(transparency: v & 1 != 0 || l.locks.transparency, pixels: v & 2 != 0, position: v & 4 != 0, all: v & 0x8000_0000 != 0)
                }
            case "knko": if let v = try? c.u8(), v != 0 { l.knockout = v == 2 ? .deep : .shallow }
            case "infx": if let v = try? c.u8() { l.blendInteriorEffectsAsGroup = v != 0 }
            case "clbl": if let v = try? c.u8() { l.blendClippedAsGroup = v != 0 }
            case "lmgm": if let v = try? c.u8() { l.layerMaskHidesEffects = v != 0 }
            case "vmgm": if let v = try? c.u8() { l.vectorMaskHidesEffects = v != 0 }
            case "brst":
                // channels excluded from blending (0 red, 1 green, 2 blue)
                while c.remaining >= 4, let ch = try? c.u32() {
                    if ch == 0 { l.channelR = false } else if ch == 1 { l.channelG = false } else if ch == 2 { l.channelB = false }
                }
            default: break
            }
        }
        // layer style: the multi-instance block wins when both are present
        if let b = r.block("lmfx") ?? r.block("lfx2"), let fx = PSDLayerStyle.decode(PSDCursor(bytes).data(b)) {
            l.effects = fx
            if let id = fx.patternOverlay.enabled ? fx.patternOverlay.patternID : nil { usePattern(id) }
        } else if r.has("lrFX"), !r.has("lfx2"), !r.has("lmfx") {
            report.add(.skipped, layer: r.name, feature: "Layer style", detail: "Only the pre-Photoshop 6 effect list is stored; it is not read.")
        }
        if r.linkGroup != 0, records.filter({ $0.linkGroup == r.linkGroup && $0.section != 3 }).count > 1 {
            if linkIDs[r.linkGroup] == nil { linkIDs[r.linkGroup] = UUID() }
            l.linkID = linkIDs[r.linkGroup]
        }
        blendIf(&l, r)
        masks(&l, r, shapeUsesVectorMask: shapeUsesVectorMask)
    }

    static let labels: [Int: LayerColorLabel] = [0: .none, 1: .red, 2: .orange, 3: .yellow, 4: .green, 5: .blue, 6: .violet, 7: .gray]

    func usePattern(_ id: String) { if patterns[id] != nil, !usedPatterns.contains(id) { usedPatterns.append(id) } }

    /// Blending ranges: composite gray first, then one entry per channel; each entry is this-layer (black low/high,
    /// white low/high) followed by the underlying layer. Lumen keeps one channel: gray wins, then R, G, B.
    func blendIf(_ l: inout Layer, _ r: PSDRecord) {
        let b = r.blendRanges
        guard mode == 3, b.count >= 8 else { return }
        var found: [(BlendIfChannel, BlendIf)] = []
        for (i, ch) in [BlendIfChannel.gray, .red, .green, .blue].enumerated() {
            let o = b.lowerBound + i * 8
            guard o + 8 <= b.upperBound else { break }
            let v = (0..<8).map { Double(bytes[o + $0]) }
            let bi = BlendIf(channel: ch, thisLow: [v[0], max(v[0], v[1])], thisHigh: [v[2], max(v[2], v[3])],
                             underLow: [v[4], max(v[4], v[5])], underHigh: [v[6], max(v[6], v[7])])
            if !bi.isDefault { found.append((ch, bi)) }
        }
        guard let first = found.first else { return }
        l.blendIf = first.1
        if found.count > 1 {
            report.add(.substituted, layer: r.name, feature: "Blend If", detail: "Ranges are set on \(found.count) channels; only \(first.0.rawValue) is kept.")
        }
    }

    func maskBuffer(_ rect: IRect, _ plane: [UInt8]?, invert: Bool) -> PixelBuffer? {
        guard let plane, PSDLimits.plausible(rect.width, rect.height), plane.count >= rect.width * rect.height else { return nil }
        return PSDImporter.gray(width: rect.width, height: rect.height, plane, invert: invert)
    }

    func masks(_ l: inout Layer, _ r: PSDRecord, shapeUsesVectorMask: Bool) {
        let vm = shapeUsesVectorMask ? nil : PSDVector.vectorMask(r, self)
        var vectorLive = false
        if let vm, !vm.path.isEmpty {
            l.vectorMask = vm.path
            l.vectorMaskEnabled = !vm.disabled
            vectorLive = true
            report.add(.editable, layer: r.name, feature: "Vector mask", detail: "\(vm.path.subpaths.count) path\(vm.path.subpaths.count == 1 ? "" : "s")" + (vm.disabled ? " (disabled)" : ""))
        }
        guard let m = r.mask else { return }
        var mask: LayerMask? = nil
        if m.fromVector {
            // channel -2 is Photoshop's rendering of the vector mask; the pixel mask (if any) is the "real" one
            if let rr = m.realRect, let buf = maskBuffer(rr, r.planes[-3], invert: m.realFlags & 0x04 != 0) {
                mask = LayerMask(buffer: buf, origin: rr.origin, outsideValue: m.realFlags & 0x04 != 0 ? 255 - m.realDefault : m.realDefault,
                                 isEnabled: m.realFlags & 0x02 == 0, isLinked: m.realFlags & 0x01 == 0)
            } else if !vectorLive && !shapeUsesVectorMask, let buf = maskBuffer(m.rect, r.planes[-2], invert: false) {
                mask = LayerMask(buffer: buf, origin: m.rect.origin, outsideValue: m.defaultColor, isEnabled: m.flags & 0x02 == 0)
                report.add(.flattened, layer: r.name, feature: "Vector mask", detail: "The path could not be read; its rendered pixels are used as a pixel mask.")
            }
        } else if let buf = maskBuffer(m.rect, r.planes[-2], invert: m.flags & 0x04 != 0) {
            mask = LayerMask(buffer: buf, origin: m.rect.origin, outsideValue: m.flags & 0x04 != 0 ? 255 - m.defaultColor : m.defaultColor,
                             isEnabled: m.flags & 0x02 == 0, isLinked: m.flags & 0x01 == 0)
        } else if m.rect.isEmpty, m.defaultColor != 255, r.chans.contains(where: { $0.id == -2 }) {
            // an empty mask rectangle means "the default colour everywhere" (all white needs no mask at all)
            mask = LayerMask(buffer: PixelBuffer(width: 1, height: 1, gray: m.defaultColor), origin: .zero, outsideValue: m.defaultColor,
                             isEnabled: m.flags & 0x02 == 0, isLinked: m.flags & 0x01 == 0)
        }
        if var k = mask {
            if let d = m.userDensity, d.isFinite { k.density = clamp(d, 0, 1) }
            if let f = m.userFeather, f.isFinite, f > 0 { k.feather = min(f, 1000) }
            l.mask = k
        }
        if vectorLive, (m.vectorFeather ?? 0) > 0 || (m.vectorDensity ?? 1) < 0.999 {
            report.add(.substituted, layer: r.name, feature: "Vector mask", detail: "Feather / density of the vector mask are not supported and were dropped.")
        }
    }

    func artboard(_ r: PSDRecord) -> Artboard? {
        guard let b = r.block("artb") ?? r.block("artd") ?? r.block("abdd"),
              let d = try? PSDDescriptor.readVersioned(PSDCursor(bytes).data(b)), let rc = d.object("artboardRect"),
              let t = rc.double("Top "), let lf = rc.double("Left"), let bt = rc.double("Btom"), let rt = rc.double("Rght"),
              [t, lf, bt, rt].allSatisfy({ $0.isFinite && abs($0) < 1e7 }), rt > lf, bt > t else { return nil }
        var bg: RGBA? = .white
        switch PSDImportReport.int(d.double("artboardBackgroundType")) ?? 1 {
        case 2: bg = .black
        case 3: bg = nil
        case 4: bg = PSDLayerStyle.parseColor(d.object("Clr ")) ?? .white
        default: break
        }
        var ab = Artboard(rect: CGRect(x: lf, y: t, width: rt - lf, height: bt - t), background: bg)
        if let p = d.string("artboardPresetName"), !p.isEmpty, p != "Custom" { ab.presetName = p }   // Photoshop writes "Custom" for free sizes
        return ab
    }

}
