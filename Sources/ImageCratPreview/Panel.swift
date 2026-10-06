import Foundation
import WinSDK
import ImageCratCore

/// One row of the side panel list: a layer of a PSD or a brush of a brush file.
struct PanelRow {
    var title: String
    var line2: String
    var line3: String
    var depth: Int
    var thumbnail: RGBA8Image?
    /// Glyph (Segoe MDL2 Assets) drawn instead of a thumbnail (groups, adjustments, text without pixels).
    var glyph: String?
    var hasEye: Bool
    var eyeOn: Bool
    /// Index into `PSDFile.layers` / the brush list.
    var index: Int
}

/// Side panel: document info at the top, then the layer (or brush) list. Custom drawn into one back buffer.
final class Panel {
    static let folderGlyph = "folder"
    var hwnd: HWND?
    private let buffer = BackBuffer()
    var title = "Document"
    var infoLines: [(String, String)] = []
    var rows: [PanelRow] = [] { didSet { selected = nil; scrollY = 0; updateScroll() } }
    var listTitle = "Layers"
    var emptyText = "Open a file to see its layers."
    private(set) var selected: Int? = nil
    private var scrollY = 0
    private var thumbCache: [Int: (Int, RGBA8Image)] = [:]

    var onSelect: ((Int?) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onEyeChanged: ((Int) -> Void)?

    private func s(_ v: Int) -> Int { v * dpiOf(hwnd) / 96 }
    private var rowHeight: Int { s(54) }
    private var thumbSize: Int { s(42) }

    // MARK: Layout

    /// Height of the info block (title + key/value lines + list heading).
    private var headerHeight: Int {
        s(12) + s(22) + infoLines.count * s(19) + s(12) + s(30)
    }

    private var listTop: Int { headerHeight }

    private var listHeight: Int { max(0, clientSize(hwnd).h - listTop) }

    private var contentHeight: Int { rows.count * rowHeight }

    func updateScroll() {
        guard let hwnd else { return }
        scrollY = max(0, min(scrollY, contentHeight - listHeight))
        var si = SCROLLINFO()
        si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
        si.fMask = W32.SIF_ALL
        si.nMin = 0
        si.nMax = Int32(max(0, contentHeight + listTop - 1))
        si.nPage = UINT(clientSize(hwnd).h)
        si.nPos = Int32(scrollY)
        SetScrollInfo(hwnd, W32.SB_VERT, &si, true)
        thumbCache = thumbCache.filter { $0.value.0 == thumbSize }
        InvalidateRect(hwnd, nil, false)
    }

    func select(_ i: Int?, notify: Bool = true) {
        selected = i
        if let i { ensureVisible(i) }
        InvalidateRect(hwnd, nil, false)
        if notify { onSelect?(i) }
    }

    private func ensureVisible(_ i: Int) {
        let top = i * rowHeight, bottom = top + rowHeight
        if top < scrollY { scrollY = top } else if bottom > scrollY + listHeight { scrollY = bottom - listHeight }
        updateScroll()
    }

    func setEye(_ i: Int, _ on: Bool) {
        guard rows.indices.contains(i), rows[i].hasEye else { return }
        rows[i].eyeOn = on
        InvalidateRect(hwnd, nil, false)
    }

    // MARK: Painting

    private func paint(_ dc: HDC?) {
        let (w, h) = clientSize(hwnd)
        buffer.ensure(w, h)
        guard let bdc = buffer.dc else { return }
        let app = App.shared
        let bgPanel = rgb(243, 243, 246)
        fillRect(bdc, makeRect(0, 0, w, h), bgPanel)
        let old = SelectObject(bdc, gdi(app.uiFont))
        // header
        var y = s(12)
        SelectObject(bdc, gdi(app.boldFont))
        drawText(bdc, title, makeRect(s(12), y, w - s(24), s(22)), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS | W32.DT_VCENTER, color: rgb(20, 20, 24))
        y += s(22)
        SelectObject(bdc, gdi(app.uiFont))
        let keyW = s(92)
        for (k, v) in infoLines {
            drawText(bdc, k, makeRect(s(12), y, keyW, s(19)), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_VCENTER, color: rgb(100, 100, 110))
            drawText(bdc, v, makeRect(s(12) + keyW, y, w - keyW - s(24), s(19)), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_VCENTER | W32.DT_END_ELLIPSIS, color: rgb(20, 20, 24))
            y += s(19)
        }
        y += s(12)
        // list heading
        fillRect(bdc, makeRect(0, y, w, s(30)), rgb(228, 228, 234))
        fillRect(bdc, makeRect(0, y, w, 1), rgb(205, 205, 212))
        SelectObject(bdc, gdi(app.boldFont))
        drawText(bdc, "\(listTitle)\(rows.isEmpty ? "" : "  (\(rows.count))")", makeRect(s(12), y, w - s(24), s(30)), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_VCENTER, color: rgb(40, 40, 48))
        SelectObject(bdc, gdi(app.uiFont))
        let top = listTop
        // list (clipped to the list area)
        let clip = CreateRectRgn(0, Int32(top), Int32(w), Int32(h))
        SelectClipRgn(bdc, clip)
        fillRect(bdc, makeRect(0, top, w, h - top), rgb(255, 255, 255))
        if rows.isEmpty {
            drawText(bdc, emptyText, makeRect(s(16), top + s(16), w - s(32), s(80)), W32.DT_LEFT | W32.DT_WORDBREAK, color: rgb(110, 110, 120))
        }
        let first = max(0, scrollY / rowHeight), last = min(rows.count, (scrollY + listHeight) / rowHeight + 1)
        if first < last {
            for i in first..<last { drawRow(bdc, i, y: top + i * rowHeight - scrollY, width: w) }
        }
        SelectClipRgn(bdc, nil)
        DeleteObject(gdi(clip))
        SelectObject(bdc, old)
        buffer.blit(to: dc)
    }

    private func drawRow(_ dc: HDC?, _ i: Int, y: Int, width w: Int) {
        let app = App.shared
        let r = rows[i]
        let sel = selected == i
        fillRect(dc, makeRect(0, y, w, rowHeight), sel ? rgb(204, 228, 255) : (i % 2 == 0 ? rgb(255, 255, 255) : rgb(249, 249, 251)))
        fillRect(dc, makeRect(0, y + rowHeight - 1, w, 1), rgb(232, 232, 238))
        var x = s(6)
        // eye
        let eyeW = s(28)
        if r.hasEye {
            SelectObject(dc, gdi(app.iconFont))
            drawText(dc, r.eyeOn ? "\u{E890}" : "\u{ED1A}", makeRect(x, y, eyeW, rowHeight), W32.DT_CENTER | W32.DT_VCENTER | W32.DT_SINGLELINE,
                     color: r.eyeOn ? rgb(30, 30, 36) : rgb(170, 170, 178))
            SelectObject(dc, gdi(app.uiFont))
        }
        x += eyeW + s(4) + r.depth * s(16)
        // thumbnail / glyph
        let ts = thumbSize
        let ty = y + (rowHeight - ts) / 2
        if let t = r.thumbnail, r.glyph == nil {
            let img = scaledThumb(i, t)
            // frame
            fillRect(dc, makeRect(x - 1, ty - 1, ts + 2, ts + 2), rgb(190, 190, 198))
            let ox = x + (ts - img.width) / 2, oy = ty + (ts - img.height) / 2
            if img.width < ts || img.height < ts { fillRect(dc, makeRect(x, ty, ts, ts), rgb(236, 236, 240)) }
            GdiFlush()
            drawImage(img, into: buffer, x: ox, y: oy, w: img.width, h: img.height, checker: max(3, s(4)), faded: !r.eyeOn)
        } else {
            fillRect(dc, makeRect(x - 1, ty - 1, ts + 2, ts + 2), rgb(220, 220, 226))
            fillRect(dc, makeRect(x, ty, ts, ts), rgb(246, 246, 249))
            if r.glyph == Panel.folderGlyph {
                // a folder, drawn (icon fonts differ between Windows versions)
                let edge = r.eyeOn ? rgb(196, 150, 50) : rgb(200, 190, 170), fill = r.eyeOn ? rgb(240, 200, 100) : rgb(232, 226, 212)
                let fx = x + ts * 18 / 100, fy = ty + ts * 28 / 100, fw = ts * 64 / 100, fh = ts * 46 / 100
                fillRect(dc, makeRect(fx, fy - ts * 8 / 100, fw * 42 / 100, ts * 10 / 100), edge)
                fillRect(dc, makeRect(fx, fy, fw, fh), edge)
                fillRect(dc, makeRect(fx + 1, fy + 1 + ts * 6 / 100, fw - 2, fh - 2 - ts * 6 / 100), fill)
            } else {
                SelectObject(dc, gdi(app.iconBigFont))
                drawText(dc, r.glyph ?? "\u{E91B}", makeRect(x, ty, ts, ts), W32.DT_CENTER | W32.DT_VCENTER | W32.DT_SINGLELINE,
                         color: r.eyeOn ? rgb(70, 90, 130) : rgb(180, 180, 190))
                SelectObject(dc, gdi(app.uiFont))
            }
        }
        x += ts + s(10)
        // text
        let tw = w - x - s(8)
        let lh = s(16)
        let ty0 = y + (rowHeight - 3 * lh) / 2
        SelectObject(dc, gdi(app.boldFont))
        drawText(dc, r.title, makeRect(x, ty0, tw, lh), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS, color: r.eyeOn ? rgb(20, 20, 24) : rgb(130, 130, 138))
        SelectObject(dc, gdi(app.smallFont))
        drawText(dc, r.line2, makeRect(x, ty0 + lh, tw, lh), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS, color: rgb(90, 90, 100))
        if !r.line3.isEmpty {
            drawText(dc, r.line3, makeRect(x, ty0 + 2 * lh, tw, lh), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS, color: rgb(120, 60, 150))
        }
        SelectObject(dc, gdi(app.uiFont))
    }

    private func scaledThumb(_ i: Int, _ t: RGBA8Image) -> RGBA8Image {
        let ts = thumbSize
        if let c = thumbCache[i], c.0 == ts { return c.1 }
        let img = max(t.width, t.height) > ts ? t.downscaled(maxSide: ts) : t
        thumbCache[i] = (ts, img)
        return img
    }

    /// Straight RGBA snapshot of the panel (tests).
    func snapshotRGBA() -> (Int, Int, [UInt8]) {
        paint(nil)
        return (buffer.width, buffer.height, buffer.rgba())
    }

    // MARK: Input

    private func rowAt(_ y: Int) -> Int? {
        guard y >= listTop else { return nil }
        let i = (y - listTop + scrollY) / rowHeight
        return rows.indices.contains(i) ? i : nil
    }

    func handle(_ msg: UINT, _ wParam: WPARAM, _ lParam: LPARAM) -> LRESULT? {
        switch msg {
        case W32.WM_ERASEBKGND: return 1
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
            updateScroll()
            return 0
        case W32.WM_LBUTTONDOWN, W32.WM_LBUTTONDBLCLK:
            SetFocus(hwnd)
            let p = pointFrom(lParam)
            guard let i = rowAt(p.y) else { return 0 }
            if p.x < s(6) + s(28) + s(4), rows[i].hasEye {
                rows[i].eyeOn.toggle()
                InvalidateRect(hwnd, nil, false)
                onEyeChanged?(i)
                return 0
            }
            select(i)
            if msg == W32.WM_LBUTTONDBLCLK { onActivate?(i) }
            return 0
        case W32.WM_MOUSEWHEEL:
            scrollBy(-wheelDelta(wParam) * rowHeight / 120)
            return 0
        case W32.WM_VSCROLL:
            let code = loWordW(wParam)
            switch code {
            case W32.SB_LINEUP: scrollBy(-rowHeight / 2)
            case W32.SB_LINEDOWN: scrollBy(rowHeight / 2)
            case W32.SB_PAGEUP: scrollBy(-listHeight)
            case W32.SB_PAGEDOWN: scrollBy(listHeight)
            case W32.SB_TOP: scrollBy(-contentHeight)
            case W32.SB_BOTTOM: scrollBy(contentHeight)
            case W32.SB_THUMBTRACK, W32.SB_THUMBPOSITION:
                var si = SCROLLINFO()
                si.cbSize = UINT(MemoryLayout<SCROLLINFO>.size)
                si.fMask = W32.SIF_TRACKPOS
                GetScrollInfo(hwnd, W32.SB_VERT, &si)
                scrollY = Int(si.nTrackPos)
                updateScroll()
            default: break
            }
            return 0
        case W32.WM_KEYDOWN:
            let n = rows.count
            guard n > 0 else { return nil }
            switch Int(wParam) {
            case W32.VK_UP: select(max(0, (selected ?? 1) - 1))
            case W32.VK_DOWN: select(min(n - 1, (selected ?? -1) + 1))
            case W32.VK_HOME: select(0)
            case W32.VK_END: select(n - 1)
            case 0x0D: if let i = selected { onActivate?(i) }
            case W32.VK_SPACE.asInt: if let i = selected, rows[i].hasEye { rows[i].eyeOn.toggle(); InvalidateRect(hwnd, nil, false); onEyeChanged?(i) }
            default: return nil
            }
            return 0
        default: return nil
        }
    }

    private func scrollBy(_ d: Int) {
        scrollY += d
        updateScroll()
    }
}

extension Int32 { var asInt: Int { Int(self) } }
