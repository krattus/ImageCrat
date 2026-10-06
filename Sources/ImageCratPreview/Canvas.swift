import Foundation
import WinSDK
import ImageCratCore

/// The image area: the current picture scaled to the view over a checkerboard, with zoom and pan.
/// Rendering is done in software into a client-sized DIB (premultiplied mip levels, bilinear below 100 %,
/// nearest above), then blitted in one call: no flicker, no GDI stretching artefacts.
final class Canvas {
    var hwnd: HWND?
    private let buffer = BackBuffer()

    /// Mip levels of the picture: premultiplied BGRA words, level 0 = full size.
    private var levels: [(w: Int, h: Int, px: [UInt32])] = []
    private(set) var imageWidth = 0
    private(set) var imageHeight = 0
    /// Message shown instead of a picture (or over it when `banner`).
    var message: String? = nil
    var banner: String? = nil
    /// Canvas-space rectangle outlined on top (the selected layer).
    var outline: IRect? = nil

    private(set) var zoom = 1.0
    private var offX = 0.0, offY = 0.0
    private(set) var fitMode = true
    private var dragging = false
    private var dragStart = (x: 0, y: 0), dragOff = (x: 0.0, y: 0.0)

    var onZoomChanged: (() -> Void)?

    var hasImage: Bool { !levels.isEmpty }

    // MARK: Content

    func setImage(_ img: RGBA8Image?, keepView: Bool = false) {
        levels = []
        if let img, img.width > 0, img.height > 0 {
            imageWidth = img.width; imageHeight = img.height
            buildLevels(img)
        } else {
            imageWidth = 0; imageHeight = 0
        }
        if !keepView { fitMode = true }
        layoutView()
        invalidate()
    }

    private func buildLevels(_ img: RGBA8Image) {
        var px = [UInt32](repeating: 0, count: img.width * img.height)
        img.pixels.withUnsafeBufferPointer { s in
            for i in 0..<(img.width * img.height) {
                let a = UInt32(s[i * 4 + 3])
                let r = (UInt32(s[i * 4]) * a + 127) / 255, g = (UInt32(s[i * 4 + 1]) * a + 127) / 255, b = (UInt32(s[i * 4 + 2]) * a + 127) / 255
                px[i] = a << 24 | r << 16 | g << 8 | b
            }
        }
        levels.append((img.width, img.height, px))
        var (w, h) = (img.width, img.height)
        while max(w, h) > 64 {
            let nw = max(1, w / 2), nh = max(1, h / 2)
            let src = levels[levels.count - 1].px
            var dst = [UInt32](repeating: 0, count: nw * nh)
            for y in 0..<nh {
                let y0 = min(h - 1, y * 2), y1 = min(h - 1, y * 2 + 1)
                for x in 0..<nw {
                    let x0 = min(w - 1, x * 2), x1 = min(w - 1, x * 2 + 1)
                    let a = src[y0 * w + x0], b = src[y0 * w + x1], c = src[y1 * w + x0], d = src[y1 * w + x1]
                    var out: UInt32 = 0
                    for shift in stride(from: 0, through: 24, by: 8) {
                        let s = ((a >> UInt32(shift)) & 255) + ((b >> UInt32(shift)) & 255) + ((c >> UInt32(shift)) & 255) + ((d >> UInt32(shift)) & 255)
                        out |= ((s + 2) / 4) << UInt32(shift)
                    }
                    dst[y * nw + x] = out
                }
            }
            levels.append((nw, nh, dst))
            w = nw; h = nh
        }
    }

    // MARK: View

    private var viewSize: (w: Int, h: Int) { clientSize(hwnd) }

    var fitZoom: Double {
        let v = viewSize
        guard imageWidth > 0, imageHeight > 0, v.w > 0, v.h > 0 else { return 1 }
        let margin = 2 * scale(16)
        return max(0.01, min(32, min(Double(v.w - margin) / Double(imageWidth), Double(v.h - margin) / Double(imageHeight))))
    }

    func scale(_ v: Int) -> Int { v * dpiOf(hwnd) / 96 }

    /// Recomputes the zoom (fit mode) and keeps the picture inside the view.
    func layoutView() {
        if fitMode { zoom = fitZoom; center() }
        clampOffsets()
        onZoomChanged?()
    }

    private func center() {
        let v = viewSize
        offX = (Double(v.w) - Double(imageWidth) * zoom) / 2
        offY = (Double(v.h) - Double(imageHeight) * zoom) / 2
    }

    private func clampOffsets() {
        let v = viewSize
        let iw = Double(imageWidth) * zoom, ih = Double(imageHeight) * zoom
        let m = Double(scale(16))
        if iw + 2 * m <= Double(v.w) { offX = (Double(v.w) - iw) / 2 } else { offX = min(m, max(Double(v.w) - iw - m, offX)) }
        if ih + 2 * m <= Double(v.h) { offY = (Double(v.h) - ih) / 2 } else { offY = min(m, max(Double(v.h) - ih - m, offY)) }
        offX = offX.rounded(); offY = offY.rounded()
    }

    func fit() { fitMode = true; layoutView(); invalidate() }

    /// Sets the zoom, keeping the canvas point under (ax, ay) (view coordinates) in place.
    func setZoom(_ z: Double, anchor: (x: Int, y: Int)? = nil) {
        guard hasImage else { return }
        let v = viewSize
        let a = anchor ?? (v.w / 2, v.h / 2)
        let nz = max(0.01, min(32, z))
        let cx = (Double(a.x) - offX) / zoom, cy = (Double(a.y) - offY) / zoom
        zoom = nz
        offX = Double(a.x) - cx * nz; offY = Double(a.y) - cy * nz
        fitMode = false
        clampOffsets()
        onZoomChanged?()
        invalidate()
    }

    static let steps: [Double] = [0.01, 0.02, 0.03, 0.05, 0.0667, 0.0833, 0.125, 0.1667, 0.25, 0.333, 0.5, 0.6667, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32]

    func zoomStep(_ dir: Int, anchor: (x: Int, y: Int)? = nil) {
        let z = dir > 0 ? (Canvas.steps.first { $0 > zoom * 1.001 } ?? 32) : (Canvas.steps.last { $0 < zoom * 0.999 } ?? 0.01)
        setZoom(z, anchor: anchor)
    }

    func scroll(dx: Int, dy: Int) {
        guard hasImage else { return }
        offX += Double(dx); offY += Double(dy)
        if fitMode { fitMode = false }
        clampOffsets()
        invalidate()
    }

    func invalidate() { if let hwnd { InvalidateRect(hwnd, nil, false) } }

    // MARK: Painting

    func paint(_ dc: HDC?) {
        let v = viewSize
        render(width: v.w, height: v.h)
        buffer.blit(to: dc)
    }

    /// Renders the view into the back buffer.
    func render(width: Int, height: Int) {
        buffer.ensure(width, height)
        guard let bits = buffer.bits else { return }
        GdiFlush()
        let bg = bgra(56, 56, 60)
        for i in 0..<(buffer.width * buffer.height) { bits[i] = bg }
        let cs = max(4, scale(8))
        if let lvl0 = levels.first {
            // visible destination rectangle of the picture
            let dx0 = max(0, Int(floor(offX))), dy0 = max(0, Int(floor(offY)))
            let dx1 = min(buffer.width, Int(ceil(offX + Double(imageWidth) * zoom)))
            let dy1 = min(buffer.height, Int(ceil(offY + Double(imageHeight) * zoom)))
            if dx1 > dx0 && dy1 > dy0 {
                // level: the smallest one that still has at least one texel per screen pixel
                var li = 0
                if zoom < 1 { li = min(levels.count - 1, max(0, Int(floor(log2(1 / zoom))))) }
                let L = levels[li]
                let ls = Double(L.w) / Double(lvl0.w)   // level pixels per canvas pixel
                let bilinear = zoom * (1 / ls) < 1.0001 && zoom < 1   // downscaling within the level
                // column tables
                let n = dx1 - dx0
                var cx0 = [Int](repeating: 0, count: n), cx1 = [Int](repeating: 0, count: n), cfx = [UInt32](repeating: 0, count: n)
                for i in 0..<n {
                    let cxf = (Double(dx0 + i) + 0.5 - offX) / zoom   // canvas x
                    if bilinear {
                        let lx = cxf * ls - 0.5
                        let fx = floor(lx)
                        cx0[i] = max(0, min(L.w - 1, Int(fx))); cx1[i] = max(0, min(L.w - 1, Int(fx) + 1))
                        cfx[i] = UInt32(max(0, min(256, ((lx - fx) * 256).rounded())))
                    } else {
                        cx0[i] = max(0, min(L.w - 1, Int(cxf * ls))); cx1[i] = cx0[i]; cfx[i] = 0
                    }
                }
                L.px.withUnsafeBufferPointer { src in
                    for y in dy0..<dy1 {
                        let cyf = (Double(y) + 0.5 - offY) / zoom
                        var ry0: Int, ry1: Int, fy: UInt32
                        if bilinear {
                            let ly = cyf * ls - 0.5
                            let f = floor(ly)
                            ry0 = max(0, min(L.h - 1, Int(f))); ry1 = max(0, min(L.h - 1, Int(f) + 1)); fy = UInt32(max(0, min(256, ((ly - f) * 256).rounded())))
                        } else {
                            ry0 = max(0, min(L.h - 1, Int(cyf * ls))); ry1 = ry0; fy = 0
                        }
                        let row = bits + y * buffer.width
                        let r0 = ry0 * L.w, r1 = ry1 * L.w
                        let checkRow = ((y - Int(offY)) / cs) & 1
                        for i in 0..<n {
                            var p: UInt32
                            if bilinear {
                                p = mix(mix(src[r0 + cx0[i]], src[r0 + cx1[i]], cfx[i]), mix(src[r1 + cx0[i]], src[r1 + cx1[i]], cfx[i]), fy)
                            } else {
                                p = src[r0 + cx0[i]]
                            }
                            let a = p >> 24
                            let x = dx0 + i
                            if a == 255 { row[x] = p; continue }
                            let check: UInt32 = (((x - Int(offX)) / cs) & 1) ^ checkRow == 0 ? 255 : 204
                            let k = 255 - a
                            let cb = (check * k + 127) / 255
                            let r = ((p >> 16) & 255) + cb, g = ((p >> 8) & 255) + cb, b = (p & 255) + cb
                            row[x] = 0xFF00_0000 | min(255, r) << 16 | min(255, g) << 8 | min(255, b)
                        }
                    }
                }
            }
            if let o = outline { drawOutline(o) }
        }
        if let dc = buffer.dc {
            let font = App.shared.uiFont
            let old = SelectObject(dc, gdi(font))
            if let m = message {
                let icon = App.shared.bigIcon
                let isz = scale(96)
                let textTop = height / 2 - scale(10)
                if levels.isEmpty, let icon { DrawIconEx(dc, Int32(width / 2 - isz / 2), Int32(textTop - isz - scale(12)), icon, Int32(isz), Int32(isz), 0, nil, W32.DI_NORMAL) }
                let r = makeRect(scale(24), levels.isEmpty ? textTop : height / 2 - scale(40), width - scale(48), height / 2)
                drawText(dc, m, r, W32.DT_CENTER | W32.DT_WORDBREAK, color: rgb(225, 225, 230))
            }
            if let b = banner {
                let bh = scale(28)
                fillPixels(buffer, 0, 0, width, bh, bgra(30, 90, 160))
                drawText(dc, b, makeRect(scale(10), 0, width - scale(20), bh), W32.DT_LEFT | W32.DT_VCENTER | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS, color: rgb(255, 255, 255))
            }
            SelectObject(dc, old)
        }
    }

    @inline(__always) private func mix(_ a: UInt32, _ b: UInt32, _ f: UInt32) -> UInt32 {
        if f == 0 { return a }
        let g = 256 - f
        let rb = (((a & 0x00FF_00FF) &* g &+ (b & 0x00FF_00FF) &* f) >> 8) & 0x00FF_00FF
        let ag = ((((a >> 8) & 0x00FF_00FF) &* g &+ ((b >> 8) & 0x00FF_00FF) &* f) >> 8) & 0x00FF_00FF
        return rb | ag << 8
    }

    /// Dashed outline of a canvas rectangle (marching-ants style, static).
    private func drawOutline(_ r: IRect) {
        guard let bits = buffer.bits, r.width > 0, r.height > 0 else { return }
        let x0 = Int((offX + Double(r.x) * zoom).rounded()), y0 = Int((offY + Double(r.y) * zoom).rounded())
        let x1 = Int((offX + Double(r.x + r.width) * zoom).rounded()) - 1, y1 = Int((offY + Double(r.y + r.height) * zoom).rounded()) - 1
        func put(_ x: Int, _ y: Int, _ k: Int) {
            guard x >= 0, y >= 0, x < buffer.width, y < buffer.height else { return }
            bits[y * buffer.width + x] = (k / 4) % 2 == 0 ? bgra(0, 0, 0) : bgra(255, 255, 255)
        }
        if x1 >= x0 { for x in x0...x1 { put(x, y0, x); put(x, y1, x) } }
        if y1 >= y0 { for y in y0...y1 { put(x0, y, y); put(x1, y, y) } }
    }

    /// The current view as straight RGBA (snapshots).
    func snapshotRGBA() -> (Int, Int, [UInt8]) {
        let v = viewSize
        render(width: v.w, height: v.h)
        return (buffer.width, buffer.height, buffer.rgba())
    }

    // MARK: Input

    func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch msg {
        case W32.WM_ERASEBKGND:
            return 1
        case W32.WM_PAINT:
            var ps = PAINTSTRUCT()
            let dc = BeginPaint(hwnd, &ps)
            paint(dc)
            EndPaint(hwnd, &ps)
            return 0
        case W32.WM_PRINTCLIENT:
            paint(HDC(bitPattern: UInt(wParam)))
            return 0
        case W32.WM_SIZE:
            layoutView()
            invalidate()
            return 0
        case W32.WM_LBUTTONDOWN, W32.WM_MBUTTONDOWN:
            SetFocus(hwnd)
            guard hasImage else { return 0 }
            dragging = true
            dragStart = pointFrom(lParam)
            dragOff = (offX, offY)
            SetCapture(hwnd)
            SetCursor(loadCursor(W32.IDC_SIZEALL))
            return 0
        case W32.WM_MOUSEMOVE:
            if dragging {
                let p = pointFrom(lParam)
                offX = dragOff.x + Double(p.x - dragStart.x)
                offY = dragOff.y + Double(p.y - dragStart.y)
                fitMode = false
                clampOffsets()
                invalidate()
            }
            App.shared.mouseMoved(canvasPoint(pointFrom(lParam)))
            return 0
        case W32.WM_LBUTTONUP, W32.WM_MBUTTONUP:
            if dragging { dragging = false; ReleaseCapture() }
            return 0
        case W32.WM_CAPTURECHANGED:
            dragging = false
            return 0
        case W32.WM_LBUTTONDBLCLK:
            if hasImage { if fitMode { setZoom(1, anchor: pointFrom(lParam)) } else { fit() } }
            return 0
        case W32.WM_SETCURSOR:
            if loWord(lParam) == W32.HTCLIENT {
                SetCursor(loadCursor(dragging ? W32.IDC_SIZEALL : (App.shared.busy ? W32.IDC_APPSTARTING : W32.IDC_ARROW)))
                return 1
            }
            return nil
        case W32.WM_MOUSEWHEEL, W32.WM_MOUSEHWHEEL:
            let d = wheelDelta(wParam)
            var pt = POINT(x: LONG(pointFrom(lParam).x), y: LONG(pointFrom(lParam).y))
            ScreenToClient(hwnd, &pt)
            if msg == W32.WM_MOUSEWHEEL && keyDown(W32.VK_CONTROL) {
                let f = pow(1.0015, Double(d))   // one notch (120) ≈ ×1.2
                setZoom(zoom * f, anchor: (Int(pt.x), Int(pt.y)))
            } else if msg == W32.WM_MOUSEHWHEEL || keyDown(W32.VK_SHIFT) {
                scroll(dx: msg == W32.WM_MOUSEHWHEEL ? -d : d, dy: 0)
            } else {
                scroll(dx: 0, dy: d)
            }
            return 0
        case W32.WM_KEYDOWN:
            let step = scale(40)
            switch Int(wParam) {
            case W32.VK_LEFT: scroll(dx: step, dy: 0)
            case W32.VK_RIGHT: scroll(dx: -step, dy: 0)
            case W32.VK_UP: scroll(dx: 0, dy: step)
            case W32.VK_DOWN: scroll(dx: 0, dy: -step)
            case W32.VK_PRIOR: scroll(dx: 0, dy: viewSize.h * 9 / 10)
            case W32.VK_NEXT: scroll(dx: 0, dy: -viewSize.h * 9 / 10)
            default: return nil
            }
            return 0
        default:
            return nil
        }
    }

    /// Canvas pixel under a view point (nil outside the picture).
    func canvasPoint(_ p: (x: Int, y: Int)) -> (Int, Int)? {
        guard hasImage else { return nil }
        let x = Int(floor((Double(p.x) - offX) / zoom)), y = Int(floor((Double(p.y) - offY) / zoom))
        return x >= 0 && y >= 0 && x < imageWidth && y < imageHeight ? (x, y) : nil
    }
}
