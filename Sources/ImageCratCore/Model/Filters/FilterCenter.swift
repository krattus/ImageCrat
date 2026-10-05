import Foundation

// MARK: - Centre point of the filters that work about a centre (Twirl, Pinch, Spherize, Radial / Spin Blur, …)
//
// One mechanism for every such filter. The centre lives in the filter's `values` (so smart filters, Last Filter,
// recorded actions, `.imagecrat` files and the Lumen data inside PSDs carry it without any extra plumbing):
//   - `centerMode`: how the centre is chosen (`FilterCenterMode.rawValue`); absent in filters made before the option
//     existed, which keep their old behaviour (stored `cx`/`cy`, canvas-sized radius);
//   - `cx`, `cy`: the resolved centre, normalized to the canvas (0…1, y down), the same keys the older Center X / Y
//     parameters used;
//   - `centerW`, `centerH`: the size of the box the centre was taken from (object, selection or canvas), normalized
//     to the canvas; radius-like parameters are relative to it (1 × 1 = the canvas, the old behaviour).
// The renderer only reads the resolved values; the mode says how to re-resolve them when the filter runs again
// (Repeat Filter, an action, a smart filter after its layer moved).

/// How the centre of a centre-based filter is chosen.
package enum FilterCenterMode: Int, CaseIterable, Codable, Identifiable {
    /// The middle of the content the filter processes (alpha bounds of the layer's pixels; a smart object's bounds).
    case object = 0
    /// The middle of the active selection's bounds (as Photoshop does when a selection is active).
    case selection = 1
    /// The middle of the document (the behaviour before this option existed).
    case canvas = 2
    /// A point the user picked.
    case custom = 3

    package var id: Int { rawValue }

    package var title: String {
        switch self {
        case .object: return "Object"
        case .selection: return "Selection"
        case .canvas: return "Canvas"
        case .custom: return "Custom"
        }
    }
}

/// Everything a centre is resolved from, in document pixels (y down).
package struct FilterCenterContext: Equatable {
    package var canvasWidth: Double
    package var canvasHeight: Double
    /// Bounds of the content the filter processes; nil = nothing there (the canvas is used).
    package var object: CGRect?
    /// Bounds of the active selection; nil = no selection.
    package var selection: CGRect?

    package init(canvasWidth: Double, canvasHeight: Double, object: CGRect? = nil, selection: CGRect? = nil) {
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight; self.object = object; self.selection = selection
    }

    package var canvas: CGRect { CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight) }

    /// The box `mode` centres on (custom: nil, the point is the user's).
    package func box(_ mode: FilterCenterMode) -> CGRect? {
        func usable(_ r: CGRect?) -> CGRect? {
            guard let r, !r.isNull, !r.isInfinite, r.width > 0, r.height > 0,
                  [r.minX, r.minY, r.width, r.height].allSatisfy({ $0.isFinite }) else { return nil }
            return r
        }
        switch mode {
        case .object: return usable(object) ?? canvas
        case .selection: return usable(selection) ?? usable(object) ?? canvas
        case .canvas: return canvas
        case .custom: return nil
        }
    }
}

package enum FilterCenterKey {
    package static let mode = "centerMode", x = "cx", y = "cy", width = "centerW", height = "centerH"
    /// Keys of the centre option (not shown as ordinary parameters).
    package static let all: Set<String> = [mode, x, y, width, height]
}

extension FilterKind {
    /// Filters that distort, blur or light about a centre point and get the Center option.
    package var usesCenter: Bool {
        switch self {
        case .twirl, .pinch, .spherize, .vortex, .polarCoordinates, .kaleidoscope, .radialBlur, .spinBlur, .lensFlare, .spotlight, .vignette:
            return true
        default:
            return false
        }
    }

    /// The centre mode a new filter starts with when none is remembered. A lens flare keeps its off-centre default spot
    /// (a flare in the very middle of the picture puts all its ghosts on top of it).
    package var defaultCenterMode: FilterCenterMode { self == .lensFlare ? .custom : .object }

    package static var centerKinds: [FilterKind] { allCases.filter(\.usesCenter) }
}

extension FilterInstance {
    /// The centre mode, or nil for a filter made before the option existed (it keeps its stored centre and canvas sizing).
    package var centerMode: FilterCenterMode? {
        get { values[FilterCenterKey.mode].flatMap { $0.isFinite ? FilterCenterMode(rawValue: Int($0.rounded())) : nil } }
        set { values[FilterCenterKey.mode] = newValue.map { Double($0.rawValue) } }
    }

    /// The resolved centre, normalized to the canvas (0…1, y down). Filters without one use their Center X / Y
    /// parameter defaults, or the middle of the canvas.
    package var centerPoint: (x: Double, y: Double) {
        func v(_ k: String) -> Double { values[k].flatMap { $0.isFinite ? $0 : nil } ?? kind.params.first { $0.key == k }?.defaultValue ?? 0.5 }
        return (v(FilterCenterKey.x), v(FilterCenterKey.y))
    }

    /// Size of the box radius-like parameters are relative to, normalized to the canvas (1 × 1 = the canvas).
    package var centerBox: (width: Double, height: Double) {
        func v(_ k: String) -> Double { values[k].flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1 }
        return (v(FilterCenterKey.width), v(FilterCenterKey.height))
    }

    /// The centre in document pixels (y down).
    package func centerPixel(canvasWidth w: Double, canvasHeight h: Double) -> (x: Double, y: Double) {
        let c = centerPoint
        return (c.x * w, c.y * h)
    }

    /// A custom centre at document pixel (`x`, `y`); the sizing box stays what it was (moving the crosshair a little
    /// doesn't make a twirl jump to the size of the canvas).
    package mutating func setCustomCenter(x: Double, y: Double, canvasWidth w: Double, canvasHeight h: Double) {
        guard kind.usesCenter, w > 0, h > 0, x.isFinite, y.isFinite else { return }
        centerMode = .custom
        values[FilterCenterKey.x] = x / w
        values[FilterCenterKey.y] = y / h
        if values[FilterCenterKey.width] == nil { values[FilterCenterKey.width] = 1 }
        if values[FilterCenterKey.height] == nil { values[FilterCenterKey.height] = 1 }
    }

    /// Gives a filter made before the Center option an explicit mode that renders exactly as it did: Canvas when it
    /// was centred on the canvas, otherwise Custom at its stored point.
    package mutating func adoptLegacyCenter() {
        guard kind.usesCenter, centerMode == nil else { return }
        let c = centerPoint
        let onCanvas = abs(c.x - 0.5) < 1e-9 && abs(c.y - 0.5) < 1e-9 && centerBox == (1, 1)
        centerMode = onCanvas ? .canvas : .custom
        values[FilterCenterKey.x] = c.x; values[FilterCenterKey.y] = c.y
        values[FilterCenterKey.width] = centerBox.width; values[FilterCenterKey.height] = centerBox.height
    }

    /// Resolves the centre for `mode` (default: the filter's own) from `ctx`: writes the mode, the centre and the
    /// sizing box. Custom keeps the stored point. No-op for filters without a centre.
    package mutating func resolveCenter(_ ctx: FilterCenterContext, mode: FilterCenterMode? = nil) {
        guard kind.usesCenter, ctx.canvasWidth > 0, ctx.canvasHeight > 0 else { return }
        let m = mode ?? centerMode ?? kind.defaultCenterMode
        centerMode = m
        guard let b = ctx.box(m) else {
            let c = centerPoint, s = centerBox
            values[FilterCenterKey.x] = c.x; values[FilterCenterKey.y] = c.y
            values[FilterCenterKey.width] = s.width; values[FilterCenterKey.height] = s.height
            return
        }
        values[FilterCenterKey.x] = Double(b.midX) / ctx.canvasWidth
        values[FilterCenterKey.y] = Double(b.midY) / ctx.canvasHeight
        values[FilterCenterKey.width] = Double(b.width) / ctx.canvasWidth
        values[FilterCenterKey.height] = Double(b.height) / ctx.canvasHeight
    }

    /// A copy resolved from `ctx` when its mode follows the content (Object, Selection; limited to `modes`); others
    /// are returned as they are. (A smart filter re-renders with only the object known: its selection centre stays.)
    package func reresolvedCenter(_ ctx: FilterCenterContext, modes: Set<FilterCenterMode> = [.object, .selection]) -> FilterInstance {
        guard kind.usesCenter, let m = centerMode, m == .object || m == .selection, modes.contains(m) else { return self }
        var g = self
        g.resolveCenter(ctx)
        return g
    }
}
