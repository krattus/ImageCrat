import Foundation
import WinSDK
import ImageCratCore
import ImageCratWinSupport

/// About and Self-Check windows (owned, modal to the main window).
enum Dialogs {
    static let aboutClass = "ImageCratPreviewAbout"
    static let reportClass = "ImageCratPreviewReport"
    static let WM_CHECK_PROGRESS = W32.WM_APP + 2
    static let WM_CHECK_DONE = W32.WM_APP + 3
    static let idCopy = 10, idLink = 11, idEdit = 12, idWebsite = 13

    static var about: HWND?
    static var report: HWND?
    static var reportEdit: HWND?
    static var reportText = ""
    static var reportHeader = "Running the self-check…"
    static var reportPassed: Bool? = nil
    private static var lock = NSLock()
    private static var progressText = ""
    private static var results: [SelfCheck.Result] = []
    private static let buffer = BackBuffer()

    static func registerClasses() {
        for (name, proc) in [(aboutClass, aboutProc), (reportClass, reportProc)] as [(String, WNDPROC)] {
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = proc
            wc.hInstance = App.shared.hInstance
            wc.hCursor = loadCursor(W32.IDC_ARROW)
            wc.hbrBackground = GetSysColorBrush(W32.COLOR_WINDOW)
            wc.hIcon = App.shared.bigIcon
            wc.hIconSm = App.shared.smallIcon
            _ = withWide(name) { n -> ATOM in wc.lpszClassName = n; return RegisterClassExW(&wc) }
        }
    }

    static func s(_ v: Int, _ h: HWND?) -> Int { v * dpiOf(h) / 96 }

    /// Creates an owned window centred on the main window and disables the main window while it is open.
    private static func makeWindow(_ cls: String, _ title: String, width: Int, height: Int, resizable: Bool) -> HWND? {
        let app = App.shared
        let dpi = dpiOf(app.main)
        let w = width * dpi / 96, h = height * dpi / 96
        var mr = RECT()
        GetWindowRect(app.main, &mr)
        let x = Int(mr.left) + max(0, (Int(mr.right - mr.left) - w) / 2), y = Int(mr.top) + max(0, (Int(mr.bottom - mr.top) - h) / 2)
        let style = resizable ? (W32.WS_OVERLAPPEDWINDOW & ~W32.WS_MINIMIZEBOX) : (W32.WS_CAPTION | W32.WS_SYSMENU)
        let hwnd = withWide(cls) { c in withWide(title) { t in
            CreateWindowExW(W32.WS_EX_DLGMODALFRAME, c, t, style | W32.WS_CLIPCHILDREN, Int32(x), Int32(y), Int32(w), Int32(h), app.main, nil, app.hInstance, nil)
        } }
        if hwnd != nil { EnableWindow(app.main, false) }
        app.dialog = hwnd
        return hwnd
    }

    private static func closeWindow(_ h: HWND?) {
        let app = App.shared
        EnableWindow(app.main, true)
        SetForegroundWindow(app.main)
        DestroyWindow(h)
        if app.dialog == h { app.dialog = nil }
    }

    private static func button(_ parent: HWND?, _ id: Int, _ text: String, default isDefault: Bool = false) -> HWND? {
        let h = withWide("BUTTON") { c in withWide(text) { t in
            CreateWindowExW(0, c, t, W32.WS_CHILD | W32.WS_VISIBLE | W32.WS_TABSTOP | (isDefault ? W32.BS_DEFPUSHBUTTON : W32.BS_PUSHBUTTON), 0, 0, 10, 10, parent, hmenuID(id), App.shared.hInstance, nil)
        } }
        setFont(h, App.shared.uiFont)
        return h
    }

    // MARK: About

    static func showAbout() {
        if let about { SetForegroundWindow(about); return }
        about = makeWindow(aboutClass, "About ImageCrat Preview", width: 580, height: 370, resizable: false)
        guard let about else { return }
        // link (SysLink needs common controls 6, from the manifest); a button if it isn't available
        let link = withWide("SysLink") { c in withWide("<a href=\"\(BuildInfo.website)\">github.com/krattus/ImageCrat</a>") { t in
            CreateWindowExW(0, c, t, W32.WS_CHILD | W32.WS_VISIBLE | W32.WS_TABSTOP, 0, 0, 10, 10, about, hmenuID(idLink), App.shared.hInstance, nil)
        } }
        if link == nil { _ = button(about, idWebsite, "Open github.com/krattus/ImageCrat") } else { setFont(link, App.shared.uiFont) }
        _ = button(about, W32.IDOK, "OK", default: true)
        layoutAbout()
        ShowWindow(about, W32.SW_SHOW)
        SetFocus(GetDlgItem(about, Int32(W32.IDOK)))
    }

    private static func layoutAbout() {
        guard let about else { return }
        let (w, h) = clientSize(about)
        let sc = { (v: Int) in s(v, about) }
        let left = sc(140)
        MoveWindow(GetDlgItem(about, Int32(idLink)), Int32(left), Int32(sc(214)), Int32(w - left - sc(20)), Int32(sc(22)), true)
        MoveWindow(GetDlgItem(about, Int32(idWebsite)), Int32(left), Int32(sc(210)), Int32(w - left - sc(20)), Int32(sc(28)), true)
        MoveWindow(GetDlgItem(about, Int32(W32.IDOK)), Int32(w - sc(110)), Int32(h - sc(46)), Int32(sc(92)), Int32(sc(30)), true)
    }

    static let aboutLines: [String] = [
        "Version \(BuildInfo.version) — technical preview for Windows (\(BuildInfo.architecture))",
        "Build: \(BuildInfo.buildDate)",
        BuildInfo.licence,
    ]

    private static func paintAbout(_ hwnd: HWND?, _ dc: HDC?) {
        let (w, h) = clientSize(hwnd)
        buffer.ensure(w, h)
        guard let bdc = buffer.dc else { return }
        let sc = { (v: Int) in s(v, hwnd) }
        fillRect(bdc, makeRect(0, 0, w, h), rgb(255, 255, 255))
        fillRect(bdc, makeRect(0, h - sc(64), w, sc(64)), rgb(240, 240, 243))
        if let icon = App.shared.bigIcon { DrawIconEx(bdc, Int32(sc(24)), Int32(sc(28)), icon, Int32(sc(96)), Int32(sc(96)), 0, nil, W32.DI_NORMAL) }
        let left = sc(140)
        let old = SelectObject(bdc, gdi(App.shared.titleFont))
        drawText(bdc, "ImageCrat Preview", makeRect(left, sc(26), w - left - sc(20), sc(32)), W32.DT_LEFT | W32.DT_SINGLELINE, color: rgb(20, 20, 24))
        SelectObject(bdc, gdi(App.shared.uiFont))
        var y = sc(66)
        for l in aboutLines {
            drawText(bdc, l, makeRect(left, y, w - left - sc(20), sc(20)), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS, color: rgb(40, 40, 48))
            y += sc(21)
        }
        y += sc(8)
        let note = "Views Photoshop documents (layers and composite), PNG images and brush files. Editing, rendering and AI features of the Mac app arrive in later versions."
        drawText(bdc, note, makeRect(left, y, w - left - sc(24), sc(60)), W32.DT_LEFT | W32.DT_WORDBREAK, color: rgb(90, 90, 100))
        SelectObject(bdc, gdi(App.shared.smallFont))
        drawText(bdc, "Unsigned test build. \(BuildInfo.copyright).", makeRect(sc(20), h - sc(64), w - sc(150), sc(64)), W32.DT_LEFT | W32.DT_VCENTER | W32.DT_SINGLELINE, color: rgb(110, 110, 120))
        SelectObject(bdc, old)
        buffer.blit(to: dc)
    }

    static let aboutProc: WNDPROC = { h, m, w, l in Dialogs.aboutHandle(h, m, w, l) }

    static func aboutHandle(_ h: HWND?, _ m: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT {
        switch m {
        case W32.WM_ERASEBKGND: return 1
        case W32.WM_PAINT:
            var ps = PAINTSTRUCT()
            let dc = BeginPaint(h, &ps)
            paintAbout(h, dc)
            EndPaint(h, &ps)
            return 0
        case W32.WM_PRINTCLIENT:
            paintAbout(h, HDC(bitPattern: UInt(w)))
            return 0
        case W32.WM_SIZE: layoutAbout(); return 0
        case W32.WM_COMMAND:
            let id = loWordW(w)
            if id == W32.IDOK || id == W32.IDCANCEL { closeWindow(h); Dialogs.about = nil }
            if id == idWebsite { openURL(BuildInfo.website) }
            return 0
        case W32.WM_NOTIFY:
            if let hdr = UnsafePointer<NMHDR>(bitPattern: Int(l)), hdr.pointee.idFrom == UINT_PTR(idLink),
               hdr.pointee.code == W32.NM_CLICK || hdr.pointee.code == W32.NM_RETURN {
                openURL(BuildInfo.website)
            }
            return 0
        case W32.WM_CTLCOLORSTATIC:
            // the link sits on the white part of the window
            SetBkColor(HDC(bitPattern: UInt(w)), rgb(255, 255, 255))
            return LRESULT(Int(bitPattern: GetStockObject(0)))   // WHITE_BRUSH
        case W32.WM_CLOSE: closeWindow(h); Dialogs.about = nil; return 0
        default: return DefWindowProcW(h, m, w, l)
        }
    }

    // MARK: Self-check

    static func showSelfCheck() {
        if let report { SetForegroundWindow(report); return }
        report = makeWindow(reportClass, "ImageCrat Self-Check", width: 760, height: 600, resizable: true)
        guard let report else { return }
        reportEdit = withWide("EDIT") { c in
            CreateWindowExW(W32.WS_EX_CLIENTEDGE, c, nil, W32.WS_CHILD | W32.WS_VISIBLE | W32.WS_VSCROLL | W32.WS_HSCROLL | W32.ES_MULTILINE | W32.ES_READONLY | W32.ES_AUTOVSCROLL | W32.ES_AUTOHSCROLL,
                            0, 0, 10, 10, report, hmenuID(idEdit), App.shared.hInstance, nil)
        }
        setFont(reportEdit, App.shared.monoFont)
        _ = button(report, idCopy, "Copy Report")
        _ = button(report, W32.IDOK, "Close", default: true)
        reportPassed = nil
        reportHeader = "Running the self-check…"
        reportText = ""
        layoutReport()
        ShowWindow(report, W32.SW_SHOW)
        let target = report
        Thread.detachNewThread {
            let r = SelfCheck.run { i, n, name in
                lock.lock(); progressText = "[\(i + 1)/\(n)] \(name)…"; lock.unlock()
                PostMessageW(target, WM_CHECK_PROGRESS, 0, 0)
            }
            lock.lock(); results = r; lock.unlock()
            PostMessageW(target, WM_CHECK_DONE, 0, 0)
        }
    }

    private static func layoutReport() {
        guard let report else { return }
        let (w, h) = clientSize(report)
        let sc = { (v: Int) in s(v, report) }
        MoveWindow(reportEdit, Int32(sc(12)), Int32(sc(64)), Int32(w - sc(24)), Int32(max(10, h - sc(64) - sc(56))), true)
        MoveWindow(GetDlgItem(report, Int32(idCopy)), Int32(w - sc(230)), Int32(h - sc(44)), Int32(sc(110)), Int32(sc(30)), true)
        MoveWindow(GetDlgItem(report, Int32(W32.IDOK)), Int32(w - sc(110)), Int32(h - sc(44)), Int32(sc(98)), Int32(sc(30)), true)
        InvalidateRect(report, nil, false)
    }

    private static func paintReport(_ hwnd: HWND?, _ dc: HDC?) {
        let (w, h) = clientSize(hwnd)
        buffer.ensure(w, h)
        guard let bdc = buffer.dc else { return }
        let sc = { (v: Int) in s(v, hwnd) }
        fillRect(bdc, makeRect(0, 0, w, h), rgb(248, 248, 250))
        let color: COLORREF = reportPassed == nil ? rgb(60, 60, 70) : (reportPassed! ? rgb(16, 124, 64) : rgb(196, 30, 40))
        if let p = reportPassed { fillRect(bdc, makeRect(0, 0, sc(8), sc(56)), p ? rgb(16, 160, 80) : rgb(220, 40, 50)) }
        let old = SelectObject(bdc, gdi(App.shared.titleFont))
        drawText(bdc, reportHeader, makeRect(sc(20), sc(8), w - sc(40), sc(30)), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS, color: color)
        SelectObject(bdc, gdi(App.shared.smallFont))
        drawText(bdc, "\(BuildInfo.versionLine)", makeRect(sc(20), sc(38), w - sc(40), sc(20)), W32.DT_LEFT | W32.DT_SINGLELINE | W32.DT_END_ELLIPSIS, color: rgb(100, 100, 110))
        SelectObject(bdc, old)
        buffer.blit(to: dc)
    }

    static let reportProc: WNDPROC = { h, m, w, l in Dialogs.reportHandle(h, m, w, l) }

    static func reportHandle(_ h: HWND?, _ m: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT {
        switch m {
        case W32.WM_ERASEBKGND: return 1
        case W32.WM_PAINT:
            var ps = PAINTSTRUCT()
            let dc = BeginPaint(h, &ps)
            paintReport(h, dc)
            EndPaint(h, &ps)
            return 0
        case W32.WM_PRINTCLIENT:
            paintReport(h, HDC(bitPattern: UInt(w)))
            return 0
        case W32.WM_SIZE: layoutReport(); return 0
        case W32.WM_GETMINMAXINFO:
            if let p = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(l)) { p.pointee.ptMinTrackSize.x = LONG(s(420, h)); p.pointee.ptMinTrackSize.y = LONG(s(300, h)) }
            return 0
        case WM_CHECK_PROGRESS:
            lock.lock(); let t = progressText; lock.unlock()
            reportHeader = "Running the self-check… \(t)"
            InvalidateRect(h, nil, false)
            return 0
        case WM_CHECK_DONE:
            lock.lock(); let r = results; lock.unlock()
            let failed = r.filter { !$0.passed }.count
            reportPassed = failed == 0
            reportHeader = failed == 0 ? "PASS — all \(r.count) checks passed" : "FAIL — \(failed) of \(r.count) checks failed"
            reportText = SelfCheck.report(r)
            setWindowText(reportEdit, reportText.replacingOccurrences(of: "\n", with: "\r\n"))
            InvalidateRect(h, nil, false)
            Snapshot.selfCheckDone()
            return 0
        case W32.WM_COMMAND:
            let id = loWordW(w)
            if id == W32.IDOK || id == W32.IDCANCEL { closeWindow(h); Dialogs.report = nil }
            if id == idCopy, !reportText.isEmpty { copyToClipboard(h, reportText.replacingOccurrences(of: "\n", with: "\r\n")) }
            return 0
        case W32.WM_CTLCOLORSTATIC:
            // read-only EDIT: white background
            SetBkColor(HDC(bitPattern: UInt(w)), rgb(255, 255, 255))
            return LRESULT(Int(bitPattern: GetStockObject(0)))   // WHITE_BRUSH
        case W32.WM_CLOSE: closeWindow(h); Dialogs.report = nil; return 0
        default: return DefWindowProcW(h, m, w, l)
        }
    }
}
