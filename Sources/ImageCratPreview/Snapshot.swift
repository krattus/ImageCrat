import Foundation
import WinSDK
import ImageCratCore

/// Hidden `--snapshot <png>` mode: the app renders one of its windows to a PNG and quits. Used to take screenshots
/// in the build VM (no screen-capture tool there) and as a smoke test of the GUI.
enum Snapshot {
    static var waitingForFile = false

    static func start() {
        guard let req = App.shared.snapshot else { return }
        if req.about { Dialogs.showAbout(); schedule(); return }
        if req.selfCheck { Dialogs.showSelfCheck(); return }   // captured when the battery finishes
        if !waitingForFile { schedule() }
    }

    static func loaded() {
        guard let req = App.shared.snapshot else { return }
        let app = App.shared
        for i in req.eyeOff { app.panel.setEye(i, false) }
        if let i = req.select { app.panel.select(i) }
        if let i = req.previewLayer { app.rowActivated(i) }
        if let z = req.zoom { app.canvas.setZoom(z) }
        schedule()
    }

    static func selfCheckDone() {
        if App.shared.snapshot != nil { schedule() }
    }

    static func schedule() { SetTimer(App.shared.main, App.WM_SNAPSHOT_TIMER, 600, nil) }

    /// Captures the dialog if one is open, else the main window, and quits.
    static func step() {
        guard let req = App.shared.snapshot else { return }
        let target = App.shared.dialog ?? App.shared.main
        if let (w, h, px) = capture(target) {
            do {
                try PNGCodec.encode(RGBA8Image(width: w, height: h, pixels: px).pixelBuffer()).write(to: URL(fileURLWithPath: req.output))
                print("snapshot: wrote \(req.output) (\(w) × \(h))")
            } catch {
                FileHandle.standardError.write(Data("snapshot: can't write \(req.output): \(error)\n".utf8))
                App.shared.exitCode = 1
            }
        } else {
            FileHandle.standardError.write(Data("snapshot: capture failed\n".utf8))
            App.shared.exitCode = 1
        }
        print("menu: " + menuOutline(GetMenu(App.shared.main)))
        if let d = App.shared.dialog { DestroyWindow(d) }
        DestroyWindow(App.shared.main)
    }

    /// The window as the user sees it (PrintWindow: full content where the compositor is running, WM_PRINT otherwise).
    static func capture(_ hwnd: HWND?) -> (Int, Int, [UInt8])? {
        var r = RECT()
        GetWindowRect(hwnd, &r)
        let w = Int(r.right - r.left), h = Int(r.bottom - r.top)
        guard w > 0, h > 0 else { return nil }
        for method in 0..<3 {
            let b = BackBuffer()
            b.ensure(w, h)
            guard let bits = b.bits else { return nil }
            for i in 0..<(w * h) { bits[i] = 0xFF00_FF00 }   // sentinel green
            var ok = true
            switch method {
            case 0: ok = PrintWindow(hwnd, b.dc, W32.PW_RENDERFULLCONTENT)
            case 1: ok = PrintWindow(hwnd, b.dc, 0)
            default:
                // WM_PRINT straight to the window (frame, client and children)
                _ = SendMessageW(hwnd, 0x0317, WPARAM(UInt(bitPattern: Int(bitPattern: b.dc))), LPARAM(0x4 | 0x2 | 0x10 | 0x8))
            }
            let px = b.rgba()
            // accept when something other than the sentinel was drawn
            var drawn = 0
            for i in stride(from: 0, to: w * h, by: 97) where !(px[i * 4] == 0 && px[i * 4 + 1] == 255 && px[i * 4 + 2] == 0) { drawn += 1 }
            guard ok && drawn > (w * h / 97) / 2 else { continue }
            // without a compositor (hidden build-VM session) the frame and menu bar aren't drawn: keep the client area
            if px[0] == 0 && px[1] == 255 && px[2] == 0 {
                var o = POINT(x: 0, y: 0)
                ClientToScreen(hwnd, &o)
                let (cw, ch) = clientSize(hwnd)
                let ox = Int(o.x - r.left), oy = Int(o.y - r.top)
                guard cw > 0, ch > 0, ox >= 0, oy >= 0, ox + cw <= w, oy + ch <= h else { return (w, h, px) }
                var out = [UInt8](repeating: 0, count: cw * ch * 4)
                for y in 0..<ch { for x in 0..<(cw * 4) { out[y * cw * 4 + x] = px[((oy + y) * w + ox) * 4 + x] } }
                return (cw, ch, out)
            }
            return (w, h, px)
        }
        return nil
    }

    /// "File [Open…, Open Recent […], …] View […]" — the menu bar as text (the hidden session can't draw it).
    static func menuOutline(_ m: HMENU?) -> String {
        guard let m else { return "" }
        var parts: [String] = []
        for i in 0..<max(0, Int(GetMenuItemCount(m))) {
            var buf = [WCHAR](repeating: 0, count: 256)
            let n = GetMenuStringW(m, UINT(i), &buf, Int32(buf.count), W32.MF_BYPOSITION)
            let text = n > 0 ? String(wideBuffer: buf).replacingOccurrences(of: "&", with: "").replacingOccurrences(of: "\t", with: " (") : "—"
            let label = text.contains(" (") ? text + ")" : text
            if let sub = GetSubMenu(m, Int32(i)) { parts.append("\(label) [\(menuOutline(sub))]") } else { parts.append(label) }
        }
        return parts.joined(separator: ", ")
    }
}
