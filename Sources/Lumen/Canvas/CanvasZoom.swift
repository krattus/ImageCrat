import AppKit
import ImageCratCore

/// Zoom levels, parsing and formatting shared by the status-bar zoom control, the View menu and the canvas.
/// `Document.zoom` is screen points per document pixel: 100 % shows one image pixel per point (2×2 device pixels on a
/// Retina display), the same scale as the rulers, the Navigator, tool hit radii and the "nearest" render threshold.
enum ZoomMath {
    static let minZoom = 0.01, maxZoom = 64.0
    static func clamp(_ z: Double) -> Double { min(max(z, minZoom), maxZoom) }

    /// The preset ladder of the zoom menu (percent labels as Photoshop prints them).
    static let ladder: [(label: String, zoom: Double)] = [
        ("6.25%", 0.0625), ("12.5%", 0.125), ("25%", 0.25), ("33.3%", 1.0 / 3), ("50%", 0.5), ("66.7%", 2.0 / 3), ("100%", 1),
        ("150%", 1.5), ("200%", 2), ("300%", 3), ("400%", 4), ("800%", 8), ("1600%", 16), ("3200%", 32),
    ]

    /// ⌘+ / ⌘− (and the − / + buttons) step through `CanvasView.zoomSteps`.
    static func stepIn(_ z: Double) -> Double { CanvasView.zoomSteps.first { $0 > z * 1.01 } ?? maxZoom }
    static func stepOut(_ z: Double) -> Double { CanvasView.zoomSteps.last { $0 < z * 0.99 } ?? minZoom }

    /// "6.3%" below 10 %, "150%" above.
    static func format(_ z: Double) -> String {
        guard z.isFinite else { return "–" }
        let p = z * 100, r1 = (p * 10).rounded() / 10
        return r1 < 10 ? String(format: "%.1f%%", r1) : "\(Int(p.rounded()))%"
    }

    enum Input: Equatable { case zoom(Double), fit, fill }

    /// Text typed into the zoom field: `150`, `150%`, `33.3`, `33,3`, `1:2`, `2:1`, `2x`, `fit`, `fill`.
    /// Numbers are clamped to the allowed range; anything else (empty, zero, negative, nan, words) is nil.
    static func parse(_ raw: String) -> Input? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch s {
        case "fit", "fit on screen", "fit screen": return .fit
        case "fill", "fill screen": return .fill
        default: break
        }
        s = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
        func num(_ t: Substring) -> Double? {
            guard !t.isEmpty, t.allSatisfy({ $0.isNumber || $0 == "." }), let v = Double(t), v.isFinite, v > 0 else { return nil }
            return v
        }
        var z: Double?
        if let i = s.firstIndex(of: ":") {
            if let a = num(s[..<i]), let b = num(s[s.index(after: i)...]) { z = a / b }
        } else if s.hasSuffix("x") || s.hasSuffix("×") {
            z = num(s.dropLast())
        } else {
            z = num(s.hasSuffix("%") ? s.dropLast() : Substring(s)).map { $0 / 100 }
        }
        guard let v = z, v.isFinite, v > 0 else { return nil }
        return .zoom(clamp(v))
    }

    /// Size of `r` (doc space) on screen per unit of zoom, for a view rotated by `rotation` (radians).
    static func rotatedExtent(_ size: CGSize, rotation: Double) -> CGSize {
        let c = abs(cos(rotation)), s = abs(sin(rotation))
        return CGSize(width: size.width * c + size.height * s, height: size.width * s + size.height * c)
    }

    enum FitMode { case fit, fill, width, height }

    static func fitZoom(_ extent: CGSize, in avail: CGSize, mode: FitMode) -> Double {
        let sx = Double(avail.width / max(extent.width, 1e-9)), sy = Double(avail.height / max(extent.height, 1e-9))
        switch mode {
        case .fit: return clamp(min(sx, sy))
        case .fill: return clamp(max(sx, sy))
        case .width: return clamp(sx)
        case .height: return clamp(sy)
        }
    }

    /// Screen points per physical inch of `screen` (macOS draws in points; a 27" 5K display at its default "looks like
    /// 2560 × 1440" mode is about 109). Falls back to the traditional 72 when the display doesn't report its size.
    nonisolated(unsafe) static var screenPPIOverride: Double?
    static func screenPointsPerInch(_ screen: NSScreen?) -> Double {
        if let o = screenPPIOverride { return o }
        guard let sc = screen ?? NSScreen.main,
              let n = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return 72 }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
        guard mm.width > 1 else { return 72 }
        let ppi = Double(sc.frame.width) / (Double(mm.width) / 25.4)
        return ppi.isFinite && ppi > 20 ? ppi : 72
    }

    /// View ▸ Print Size: an inch of the document (its resolution in pixels) covers an inch of the screen.
    static func printSizeZoom(resolution: Double, screenPPI: Double) -> Double { clamp(screenPPI / max(resolution, 1)) }
}

// MARK: - Canvas

extension CanvasView {
    /// Margin kept around a fitted rectangle (each side, view points).
    static let fitMargin: CGFloat = 20

    /// The part of the canvas not covered by the rulers.
    var contentArea: CGRect {
        let ins = contentInsets
        return CGRect(x: ins.left, y: ins.top, width: max(bounds.width - ins.left - ins.right, 1), height: max(bounds.height - ins.top - ins.bottom, 1))
    }

    /// Screen size of a doc rect per unit zoom in the current view (rotation and flip included).
    func viewExtent(of r: CGRect) -> CGSize {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].map { linear($0, zoom: 1) }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGSize(width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// What Fit on Screen (⌘0), Fill Screen and Fit Width / Height show: the whole canvas; in an artboard document the
    /// artboards and the layers outside them (Photoshop's auto-sized canvas), not leftover canvas margins.
    func fitTarget(_ d: Document) -> CGRect {
        ArtboardOps.screenFitRect(d.state) ?? d.state.canvasCGRect
    }

    /// Zoom that fits doc rect `r` into the content area.
    func fitZoom(_ r: CGRect, mode: ZoomMath.FitMode = .fit, margin: CGFloat = CanvasView.fitMargin) -> Double {
        let a = contentArea
        let m = mode == .fill ? 0 : margin
        return ZoomMath.fitZoom(viewExtent(of: r), in: CGSize(width: max(a.width - 2 * m, 1), height: max(a.height - 2 * m, 1)), mode: mode)
    }

    /// Zooms so doc rect `r` fits (or fills) the content area, centred.
    func fit(_ r: CGRect, mode: ZoomMath.FitMode = .fit, animated: Bool = false) {
        guard document != nil, bounds.width > 10, bounds.height > 10, r.width > 0, r.height > 0 else { return }
        let a = contentArea
        show(zoom: fitZoom(r, mode: mode), docPoint: CGPoint(x: r.midX, y: r.midY), at: CGPoint(x: a.midX, y: a.midY), animated: animated)
    }

    /// Final view: doc point `p` at view point `v` with zoom `z`; animated or at once.
    func show(zoom z: Double, docPoint p: CGPoint, at v: CGPoint, animated: Bool) {
        guard let d = document else { return }
        let nz = ZoomMath.clamp(z)
        if animated && ZoomAnimator.allowed {
            ZoomAnimator.start(self, d, zoom: nz, docPoint: p, at: v)
        } else {
            ZoomAnimator.stop()
            d.zoom = nz
            d.viewOffset = v - linear(p, zoom: CGFloat(nz))
            setNeedsRender()
        }
    }

    /// Zoom about a view point (the view centre by default), optionally animated.
    func zoom(to z: Double, anchorView: CGPoint? = nil, animated: Bool) {
        ZoomAnimator.finish()
        let a = anchorView ?? CGPoint(x: bounds.midX, y: bounds.midY)
        show(zoom: z, docPoint: viewToDoc(a), at: a, animated: animated)
    }
}

/// Short eased transition for preset jumps (menu, field, ⌘0 / ⌘1, zoom to selection). Pinch, scroll, scrubbing and
/// the slider never animate; any of them stops a running transition.
enum ZoomAnimator {
    nonisolated(unsafe) static var duration: TimeInterval = 0.18
    nonisolated(unsafe) static var enabled = true
    static var allowed: Bool { enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private struct Run {
        weak var canvas: CanvasView?
        weak var doc: Document?
        var z0: Double, z1: Double, p0: CGPoint, p1: CGPoint, v0: CGPoint, v1: CGPoint
        var start: Date
    }
    nonisolated(unsafe) private static var run: Run?
    nonisolated(unsafe) private static var timer: Timer?
    static var isRunning: Bool { run != nil }

    static func start(_ c: CanvasView, _ d: Document, zoom z: Double, docPoint p: CGPoint, at v: CGPoint) {
        stop()
        // the doc point now at the destination view point slides to `p` (stays put for a zoom about an anchor)
        run = Run(canvas: c, doc: d, z0: d.zoom, z1: z, p0: c.viewToDoc(v), p1: p, v0: v, v1: v, start: Date())
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func tick() {
        guard let r = run else { return stop() }
        let t = min(1, Date().timeIntervalSince(r.start) / max(duration, 0.001))
        apply(r, t)
        if t >= 1 { stop() }
    }

    /// Log-space zoom; the doc point under the moving view anchor is interpolated linearly.
    private static func apply(_ r: Run, _ t: Double) {
        guard let c = r.canvas, let d = r.doc, c.document === d else { return }
        let e = 1 - pow(1 - t, 3)
        let z = t >= 1 ? r.z1 : exp(log(r.z0) + (log(r.z1) - log(r.z0)) * e)
        let k = CGFloat(e)
        let p = CGPoint(x: r.p0.x + (r.p1.x - r.p0.x) * k, y: r.p0.y + (r.p1.y - r.p0.y) * k)
        let v = CGPoint(x: r.v0.x + (r.v1.x - r.v0.x) * k, y: r.v0.y + (r.v1.y - r.v0.y) * k)
        d.zoom = z
        d.viewOffset = v - c.linear(p, zoom: CGFloat(z))
        c.setNeedsRender()
    }

    /// Jumps a running transition to its end (before the next step is computed from the current zoom).
    static func finish() {
        if let r = run { apply(r, 1) }
        stop()
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
        run = nil
    }
}
