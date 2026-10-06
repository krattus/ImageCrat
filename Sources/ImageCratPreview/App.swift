import Foundation
import WinSDK
import ImageCratCore
import ImageCratWinSupport

/// What the background loader hands to the UI thread.
struct Prepared {
    var file: LoadedFile
    var rows: [PanelRow]
    var picture: RGBA8Image?
    var message: String?
    var info: [(String, String)]
    var listTitle: String
    var emptyText: String
    var sheetCells: [FileLoader.SheetCell] = []
    var sheetLabels: [String] = []
    var sheetNote: String? = nil
}

/// Command identifiers (menus and accelerators).
enum Cmd {
    static let open = 100, export = 101, exit = 102, recentBase = 110, recentClear = 120
    static let fit = 200, actual = 201, zoomIn = 202, zoomOut = 203, showComposite = 204
    static let about = 300, selfCheck = 301, website = 302
}

/// Snapshot mode (hidden `--snapshot <png>` flag): render a window to PNG and quit.
struct SnapshotRequest {
    var output: String
    var select: Int? = nil
    var previewLayer: Int? = nil
    var zoom: Double? = nil
    var about = false
    var selfCheck = false
    var eyeOff: [Int] = []
}

final class App {
    static let shared = App()

    var headless = false
    var hInstance: HINSTANCE?
    var main: HWND?
    var status: HWND?
    let canvas = Canvas()
    let panel = Panel()
    var accel: HACCEL?
    var dialog: HWND?

    var uiFont: HFONT?, boldFont: HFONT?, smallFont: HFONT?, iconFont: HFONT?, iconBigFont: HFONT?, monoFont: HFONT?, titleFont: HFONT?
    var bigIcon: HICON?, smallIcon: HICON?
    private var fontDPI = 0

    var busy = false
    var current: Prepared?
    var currentPath: String? = nil
    var layerPreview: Int? = nil
    var panelWidth = 380   // at 96 dpi
    private var splitDrag = false
    var recent: [String] = []
    var recentMenu: HMENU?
    var mainMenu: HMENU?

    private let lock = NSLock()
    private var pending: (Int, Result<Prepared, Error>, String)? = nil
    private var generation = 0
    var snapshot: SnapshotRequest? = nil
    var exitCode: Int32 = 0

    static let WM_LOADED = W32.WM_APP + 1
    static let WM_SNAPSHOT_TIMER: UINT_PTR = 7
    static let mainClass = "ImageCratPreviewMain"
    static let canvasClass = "ImageCratPreviewCanvas"
    static let panelClass = "ImageCratPreviewPanel"

    func s(_ v: Int) -> Int { v * dpiOf(main) / 96 }

    // MARK: Startup

    func makeFonts(dpi: Int) {
        guard dpi != fontDPI else { return }
        for f in [uiFont, boldFont, smallFont, iconFont, iconBigFont, monoFont, titleFont] { if let f { DeleteObject(gdi(f)) } }
        uiFont = makeFont("Segoe UI", points: 9, dpi: dpi)
        boldFont = makeFont("Segoe UI", points: 9, dpi: dpi, weight: W32.FW_SEMIBOLD)
        smallFont = makeFont("Segoe UI", points: 8, dpi: dpi)
        titleFont = makeFont("Segoe UI", points: 14, dpi: dpi, weight: W32.FW_SEMIBOLD)
        iconFont = makeFont("Segoe MDL2 Assets", points: 11, dpi: dpi)
        iconBigFont = makeFont("Segoe MDL2 Assets", points: 16, dpi: dpi)
        monoFont = makeFont("Consolas", points: 9.5, dpi: dpi)
        fontDPI = dpi
        if let status { setFont(status, uiFont) }
    }

    func loadIcons() {
        // the icon is embedded as resource 1 (windows/ImageCratPreview.rc); fall back to ImageCrat.ico next to the exe
        bigIcon = HICON(OpaquePointer(LoadImageW(hInstance, resourcePointer(1), W32.IMAGE_ICON, 256, 256, W32.LR_DEFAULTCOLOR)))
        smallIcon = HICON(OpaquePointer(LoadImageW(hInstance, resourcePointer(1), W32.IMAGE_ICON, Int32(GetSystemMetrics(49)), Int32(GetSystemMetrics(50)), W32.LR_DEFAULTCOLOR)))
        if bigIcon == nil {
            let ico = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ImageCrat.ico").path
            bigIcon = withWide(ico) { HICON(OpaquePointer(LoadImageW(nil, $0, W32.IMAGE_ICON, 256, 256, W32.LR_LOADFROMFILE))) }
            smallIcon = withWide(ico) { HICON(OpaquePointer(LoadImageW(nil, $0, W32.IMAGE_ICON, 16, 16, W32.LR_LOADFROMFILE))) }
        }
    }

    func registerClasses() {
        func register(_ name: String, style: UINT, background: HBRUSH?, icon: Bool, proc: WNDPROC) {
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.style = style
            wc.lpfnWndProc = proc
            wc.hInstance = hInstance
            wc.hCursor = loadCursor(W32.IDC_ARROW)
            wc.hbrBackground = background
            if icon { wc.hIcon = bigIcon; wc.hIconSm = smallIcon }
            _ = withWide(name) { n -> ATOM in
                wc.lpszClassName = n
                return RegisterClassExW(&wc)
            }
        }
        register(App.mainClass, style: 0, background: GetSysColorBrush(W32.COLOR_BTNFACE), icon: true) { h, m, w, l in
            App.shared.mainProc(h, m, w, l)
        }
        register(App.canvasClass, style: W32.CS_DBLCLKS, background: nil, icon: false) { h, m, w, l in
            if let r = App.shared.canvas.handle(m, w, l) { return r }
            return DefWindowProcW(h, m, w, l)
        }
        register(App.panelClass, style: W32.CS_DBLCLKS, background: nil, icon: false) { h, m, w, l in
            if let r = App.shared.panel.handle(m, w, l) { return r }
            return DefWindowProcW(h, m, w, l)
        }
        Dialogs.registerClasses()
    }

    func createMainWindow(initialSize: (Int, Int)?) {
        let sysDPI = Int(GetDpiForSystem())
        let scaleV = { (v: Int) in v * max(96, sysDPI) / 96 }
        var work = RECT()
        SystemParametersInfoW(W32.SPI_GETWORKAREA, 0, &work, 0)
        let ww = Int(work.right - work.left), wh = Int(work.bottom - work.top)
        let w = initialSize?.0 ?? min(ww - 40, scaleV(1360)), h = initialSize?.1 ?? min(wh - 40, scaleV(860))
        let x = Int(work.left) + max(0, (ww - w) / 2), y = Int(work.top) + max(0, (wh - h) / 2)
        main = withWide(App.mainClass) { cls in withWide("ImageCrat Preview (technical preview)") { title in
            CreateWindowExW(W32.WS_EX_ACCEPTFILES, cls, title, W32.WS_OVERLAPPEDWINDOW | W32.WS_CLIPCHILDREN,
                            Int32(x), Int32(y), Int32(w), Int32(h), nil, nil, hInstance, nil)
        } }
        guard let main else { return }
        makeFonts(dpi: dpiOf(main))
        canvas.hwnd = withWide(App.canvasClass) { cls in
            CreateWindowExW(0, cls, nil, W32.WS_CHILD | W32.WS_VISIBLE | W32.WS_CLIPSIBLINGS, 0, 0, 10, 10, main, hmenuID(1), hInstance, nil)
        }
        panel.hwnd = withWide(App.panelClass) { cls in
            CreateWindowExW(0, cls, nil, W32.WS_CHILD | W32.WS_VISIBLE | W32.WS_VSCROLL | W32.WS_CLIPSIBLINGS, 0, 0, 10, 10, main, hmenuID(2), hInstance, nil)
        }
        status = withWide("msctls_statusbar32") { cls in
            CreateWindowExW(0, cls, nil, W32.WS_CHILD | W32.WS_VISIBLE | W32.SBARS_SIZEGRIP, 0, 0, 0, 0, main, hmenuID(3), hInstance, nil)
        }
        setFont(status, uiFont)
        if let smallIcon { _ = SendMessageW(main, W32.WM_SETICON, W32.ICON_SMALL, LPARAM(Int(bitPattern: smallIcon))) }
        if let bigIcon { _ = SendMessageW(main, W32.WM_SETICON, W32.ICON_BIG, LPARAM(Int(bitPattern: bigIcon))) }
        buildMenu()
        DragAcceptFiles(main, true)
        canvas.onZoomChanged = { [unowned self] in self.updateStatus() }
        panel.onSelect = { [unowned self] i in self.rowSelected(i) }
        panel.onActivate = { [unowned self] i in self.rowActivated(i) }
        panel.onEyeChanged = { [unowned self] i in self.eyeChanged(i) }
        showEmptyState()
        layout()
    }

    func buildMenu() {
        let bar = CreateMenu()
        let file = CreatePopupMenu(), view = CreatePopupMenu(), help = CreatePopupMenu()
        recentMenu = CreatePopupMenu()
        func add(_ m: HMENU?, _ id: Int, _ text: String, _ flags: UINT = W32.MF_STRING) { _ = withWide(text) { AppendMenuW(m, flags, UINT_PTR(id), $0) } }
        func sep(_ m: HMENU?) { AppendMenuW(m, W32.MF_SEPARATOR, 0, nil) }
        func sub(_ m: HMENU?, _ child: HMENU?, _ text: String) { _ = withWide(text) { AppendMenuW(m, W32.MF_POPUP, UINT_PTR(UInt(bitPattern: Int(bitPattern: child))), $0) } }
        add(file, Cmd.open, "&Open…\tCtrl+O")
        sub(file, recentMenu, "Open &Recent")
        add(file, Cmd.export, "&Export Composite as PNG…\tCtrl+E")
        sep(file)
        add(file, Cmd.exit, "E&xit\tAlt+F4")
        add(view, Cmd.fit, "&Fit on Screen\tCtrl+0")
        add(view, Cmd.actual, "&Actual Pixels (100%)\tCtrl+1")
        add(view, Cmd.zoomIn, "Zoom &In\tCtrl++")
        add(view, Cmd.zoomOut, "Zoom &Out\tCtrl+-")
        sep(view)
        add(view, Cmd.showComposite, "Show &Composite\tEsc")
        add(help, Cmd.selfCheck, "Run &Self-Check")
        add(help, Cmd.website, "ImageCrat on &GitHub")
        sep(help)
        add(help, Cmd.about, "&About ImageCrat Preview")
        sub(bar, file, "&File")
        sub(bar, view, "&View")
        sub(bar, help, "&Help")
        SetMenu(main, bar)
        mainMenu = bar
        loadRecent()
        rebuildRecentMenu()
        // accelerators
        var acc: [ACCEL] = [
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: 0x4F, cmd: WORD(Cmd.open)),
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: 0x45, cmd: WORD(Cmd.export)),
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: 0x30, cmd: WORD(Cmd.fit)),
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: 0x60, cmd: WORD(Cmd.fit)),          // numpad 0
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: 0x31, cmd: WORD(Cmd.actual)),
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: 0x61, cmd: WORD(Cmd.actual)),       // numpad 1
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: W32.VK_OEM_PLUS, cmd: WORD(Cmd.zoomIn)),
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: W32.VK_ADD, cmd: WORD(Cmd.zoomIn)),
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: W32.VK_OEM_MINUS, cmd: WORD(Cmd.zoomOut)),
            ACCEL(fVirt: W32.FVIRTKEY | W32.FCONTROL, key: W32.VK_SUBTRACT, cmd: WORD(Cmd.zoomOut)),
            ACCEL(fVirt: W32.FVIRTKEY, key: W32.VK_ESCAPE, cmd: WORD(Cmd.showComposite)),
            ACCEL(fVirt: W32.FVIRTKEY, key: W32.VK_F1, cmd: WORD(Cmd.about)),
        ]
        accel = CreateAcceleratorTableW(&acc, Int32(acc.count))
    }

    // MARK: Recent files

    private var recentFile: URL? {
        guard let base = ProcessInfo.processInfo.environment["APPDATA"] else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent("ImageCrat").appendingPathComponent("Preview").appendingPathComponent("recent.txt")
    }

    func loadRecent() {
        guard let u = recentFile, let s = try? String(contentsOf: u, encoding: .utf8) else { return }
        recent = s.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }.prefix(10).map { $0 }
    }

    func saveRecent() {
        guard let u = recentFile, !headless else { return }
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? recent.joined(separator: "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    func addRecent(_ path: String) {
        recent.removeAll { $0.caseInsensitiveCompare(path) == .orderedSame }
        recent.insert(path, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
        saveRecent()
        rebuildRecentMenu()
    }

    func rebuildRecentMenu() {
        guard let m = recentMenu else { return }
        while GetMenuItemCount(m) > 0 { DeleteMenu(m, 0, W32.MF_BYPOSITION) }
        if recent.isEmpty {
            _ = withWide("(no recent files)") { AppendMenuW(m, W32.MF_STRING | W32.MF_GRAYED, 0, $0) }
            return
        }
        for (i, p) in recent.enumerated() {
            let label = "&\((i + 1) % 10)  \(p)"
            _ = withWide(label) { AppendMenuW(m, W32.MF_STRING, UINT_PTR(Cmd.recentBase + i), $0) }
        }
        AppendMenuW(m, W32.MF_SEPARATOR, 0, nil)
        _ = withWide("&Clear Recent Files") { AppendMenuW(m, W32.MF_STRING, UINT_PTR(Cmd.recentClear), $0) }
    }

    // MARK: Layout

    func layout() {
        guard let main else { return }
        let (w, h) = clientSize(main)
        _ = SendMessageW(status, W32.WM_SIZE, 0, 0)
        var sr = RECT()
        GetWindowRect(status, &sr)
        let sh = Int(sr.bottom - sr.top)
        let pw = max(s(240), min(w - s(200), s(panelWidth)))
        let gap = s(5)
        let cw = max(1, w - pw - gap)
        MoveWindow(canvas.hwnd, 0, 0, Int32(cw), Int32(max(1, h - sh)), true)
        MoveWindow(panel.hwnd, Int32(cw + gap), 0, Int32(pw), Int32(max(1, h - sh)), true)
        var parts: [Int32] = [Int32(max(10, w - s(470))), Int32(max(20, w - s(300))), Int32(max(30, w - s(170))), -1]
        _ = parts.withUnsafeMutableBufferPointer { SendMessageW(status, W32.SB_SETPARTS, WPARAM(4), LPARAM(Int(bitPattern: $0.baseAddress))) }
        InvalidateRect(main, nil, true)
        updateStatus()
    }

    private func splitterRect() -> (x0: Int, x1: Int) {
        var r = RECT()
        GetWindowRect(canvas.hwnd, &r)
        let cw = Int(r.right - r.left)
        return (cw, cw + s(5))
    }

    func setStatus(_ part: Int, _ text: String) {
        _ = withWide(text) { SendMessageW(status, W32.SB_SETTEXTW, WPARAM(part), LPARAM(Int(bitPattern: $0))) }
    }

    func updateStatus() {
        if busy { setStatus(0, "Opening…") }
        else if let c = current { setStatus(0, c.file.url.path) }
        else { setStatus(0, "Ready — open a .psd, .psb, .png or brush file, or drop one on the window") }
        setStatus(1, canvas.hasImage ? "\(canvas.imageWidth) × \(canvas.imageHeight) px" : "")
        setStatus(2, canvas.hasImage ? String(format: "Zoom %.1f%%", canvas.zoom * 100).replacingOccurrences(of: ".0%", with: "%") : "")
    }

    func mouseMoved(_ p: (Int, Int)?) {
        setStatus(3, p.map { "x \($0.0), y \($0.1)" } ?? "")
    }

    // MARK: Main window procedure

    func mainProc(_ h: HWND?, _ m: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT {
        switch m {
        case W32.WM_SIZE:
            layout()
            return 0
        case W32.WM_GETMINMAXINFO:
            if let p = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(l)) {
                p.pointee.ptMinTrackSize.x = LONG(s(640)); p.pointee.ptMinTrackSize.y = LONG(s(420))
            }
            return 0
        case W32.WM_COMMAND:
            command(loWordW(w))
            return 0
        case W32.WM_INITMENUPOPUP:
            let canExport = current?.picture != nil
            EnableMenuItem(mainMenu, UINT(Cmd.export), W32.MF_BYCOMMAND | (canExport ? W32.MF_ENABLED : W32.MF_GRAYED))
            EnableMenuItem(mainMenu, UINT(Cmd.showComposite), W32.MF_BYCOMMAND | (layerPreview != nil ? W32.MF_ENABLED : W32.MF_GRAYED))
            for id in [Cmd.fit, Cmd.actual, Cmd.zoomIn, Cmd.zoomOut] {
                EnableMenuItem(mainMenu, UINT(id), W32.MF_BYCOMMAND | (canvas.hasImage ? W32.MF_ENABLED : W32.MF_GRAYED))
            }
            return 0
        case W32.WM_DROPFILES:
            let drop = HDROP(bitPattern: UInt(w))
            var buf = [WCHAR](repeating: 0, count: 32768)
            let n = DragQueryFileW(drop, 0, &buf, UINT(buf.count))
            DragFinish(drop)
            if n > 0 { open(String(wideBuffer: buf)) }
            return 0
        case App.WM_LOADED:
            finishLoad()
            return 0
        case W32.WM_TIMER:
            if w == WPARAM(App.WM_SNAPSHOT_TIMER) { KillTimer(main, App.WM_SNAPSHOT_TIMER); Snapshot.step() }
            return 0
        case W32.WM_SETCURSOR:
            if HWND(bitPattern: UInt(w)) == main && loWord(l) == W32.HTCLIENT {
                SetCursor(loadCursor(W32.IDC_SIZEWE))
                return 1
            }
            return DefWindowProcW(h, m, w, l)
        case W32.WM_LBUTTONDOWN:
            splitDrag = true
            SetCapture(main)
            return 0
        case W32.WM_MOUSEMOVE:
            if splitDrag {
                let x = pointFrom(l).x
                let (cw, _) = clientSize(main)
                panelWidth = max(240, min((cw - x) * 96 / dpiOf(main), (cw - 200) * 96 / dpiOf(main)))
                layout()
            }
            return 0
        case W32.WM_LBUTTONUP:
            if splitDrag { splitDrag = false; ReleaseCapture() }
            return 0
        case W32.WM_DPICHANGED:
            makeFonts(dpi: hiWordW(w))
            if let r = UnsafePointer<RECT>(bitPattern: Int(l)) {
                SetWindowPos(main, nil, r.pointee.left, r.pointee.top, r.pointee.right - r.pointee.left, r.pointee.bottom - r.pointee.top, W32.SWP_NOZORDER | W32.SWP_NOACTIVATE)
            }
            layout()
            panel.updateScroll()
            canvas.layoutView()
            return 0
        case W32.WM_SETFOCUS:
            SetFocus(canvas.hwnd)
            return 0
        case W32.WM_CLOSE:
            DestroyWindow(main)
            return 0
        case W32.WM_DESTROY:
            PostQuitMessage(exitCode)
            return 0
        default:
            return DefWindowProcW(h, m, w, l)
        }
    }

    func command(_ id: Int) {
        switch id {
        case Cmd.open: openDialog()
        case Cmd.export: exportComposite()
        case Cmd.exit: SendMessageW(main, W32.WM_CLOSE, 0, 0)
        case Cmd.recentBase..<(Cmd.recentBase + 10):
            let i = id - Cmd.recentBase
            if recent.indices.contains(i) { open(recent[i]) }
        case Cmd.recentClear: recent = []; saveRecent(); rebuildRecentMenu()
        case Cmd.fit: canvas.fit()
        case Cmd.actual: canvas.setZoom(1)
        case Cmd.zoomIn: canvas.zoomStep(1)
        case Cmd.zoomOut: canvas.zoomStep(-1)
        case Cmd.showComposite: showComposite()
        case Cmd.about: Dialogs.showAbout()
        case Cmd.selfCheck: Dialogs.showSelfCheck()
        case Cmd.website: openURL(BuildInfo.website)
        default: break
        }
    }

    // MARK: Files

    static let filter: [WCHAR] = {
        let parts = [
            "All supported files", "*.psd;*.psb;*.png;*.abr;*.gbr;*.gih;*.brush;*.brushset;*.kpp;*.icbrushes",
            "Photoshop documents (*.psd, *.psb)", "*.psd;*.psb",
            "PNG images (*.png)", "*.png",
            "Brush files (*.abr, *.gbr, *.gih, *.brush, *.brushset, *.kpp, *.icbrushes)", "*.abr;*.gbr;*.gih;*.brush;*.brushset;*.kpp;*.icbrushes",
            "All files (*.*)", "*.*",
        ]
        var out: [WCHAR] = []
        for p in parts { out += Array(p.utf16); out.append(0) }
        out.append(0)
        return out
    }()

    func openDialog() {
        var buf = [WCHAR](repeating: 0, count: 32768)
        var filter = App.filter
        var ofn = OPENFILENAMEW()
        ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        ofn.hwndOwner = main
        let ok: Bool = filter.withUnsafeMutableBufferPointer { f in
            buf.withUnsafeMutableBufferPointer { b in
                ofn.lpstrFilter = UnsafePointer(f.baseAddress)
                ofn.lpstrFile = b.baseAddress
                ofn.nMaxFile = DWORD(b.count)
                ofn.Flags = W32.OFN_FILEMUSTEXIST | W32.OFN_PATHMUSTEXIST | W32.OFN_EXPLORER | W32.OFN_HIDEREADONLY | W32.OFN_NOCHANGEDIR
                return GetOpenFileNameW(&ofn)
            }
        }
        if ok { open(String(wideBuffer: buf)) }
    }

    func exportComposite() {
        guard let c = current, let pic = c.picture else {
            messageBox(main, "There is no picture to export. Open a .psd, .psb, .png or brush file first.", "Export Composite", W32.MB_OK | W32.MB_ICONINFORMATION)
            return
        }
        let base = c.file.url.deletingPathExtension().lastPathComponent
        let suffix: String
        switch c.file.content { case .brushes: suffix = " brushes"; case .image: suffix = " copy"; default: suffix = " composite" }
        var buf = (base + suffix + ".png").wide
        buf += [WCHAR](repeating: 0, count: max(0, 32768 - buf.count))
        var filter = Array("PNG image (*.png)".utf16) + [0] + Array("*.png".utf16) + [0, 0]
        var ext = "png".wide
        var ofn = OPENFILENAMEW()
        ofn.lStructSize = DWORD(MemoryLayout<OPENFILENAMEW>.size)
        ofn.hwndOwner = main
        let ok: Bool = filter.withUnsafeMutableBufferPointer { f in ext.withUnsafeMutableBufferPointer { e in
            buf.withUnsafeMutableBufferPointer { b in
                ofn.lpstrFilter = UnsafePointer(f.baseAddress)
                ofn.lpstrDefExt = UnsafePointer(e.baseAddress)
                ofn.lpstrFile = b.baseAddress
                ofn.nMaxFile = DWORD(b.count)
                ofn.Flags = W32.OFN_OVERWRITEPROMPT | W32.OFN_PATHMUSTEXIST | W32.OFN_EXPLORER | W32.OFN_HIDEREADONLY | W32.OFN_NOCHANGEDIR
                return GetSaveFileNameW(&ofn)
            }
        } }
        guard ok else { return }
        let path = String(wideBuffer: buf)
        do {
            try PNGCodec.encode(pic.pixelBuffer()).write(to: URL(fileURLWithPath: path))
            setStatus(0, "Exported \(pic.width) × \(pic.height) px to \(path)")
        } catch {
            messageBox(main, "The PNG could not be written.\n\n\(error.localizedDescription)")
        }
    }

    /// Opens `path` on a background thread; the result arrives as WM_LOADED.
    func open(_ path: String) {
        generation += 1
        let gen = generation
        busy = true
        layerPreview = nil
        canvas.banner = nil
        canvas.outline = nil
        canvas.message = "Opening \(URL(fileURLWithPath: path).lastPathComponent)…"
        canvas.setImage(nil)
        updateStatus()
        let mainHwnd = main
        Thread.detachNewThread { [unowned self] in
            let result: Result<Prepared, Error>
            do { result = .success(try App.prepare(FileLoader.load(URL(fileURLWithPath: path)))) } catch { result = .failure(error) }
            self.lock.lock()
            self.pending = (gen, result, path)
            self.lock.unlock()
            PostMessageW(mainHwnd, App.WM_LOADED, 0, 0)
        }
    }

    /// Decodes everything the UI needs (thumbnails, the brush sheet) off the UI thread.
    static func prepare(_ f: LoadedFile) -> Prepared {
        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(f.fileSize), countStyle: .file)
        switch f.content {
        case .psd(let psd, let comp, let err):
            var rows: [PanelRow] = []
            for (i, l) in psd.layers.enumerated() {
                var thumb: RGBA8Image? = nil
                var glyph: String? = nil
                switch l.kind {
                case .group: glyph = Panel.folderGlyph
                case .artboard: glyph = "\u{E8A9}"
                case .adjustment: glyph = "\u{E706}"
                default:
                    thumb = psd.layerThumbnail(l.recordIndex, maxSide: 96)
                    if thumb == nil { glyph = l.kind == .text ? "\u{E8D2}" : (l.kind == .smartObject ? "\u{E8B9}" : "\u{E91B}") }
                }
                var line2 = [l.kindDetail.isEmpty || l.kind == .group ? l.kind.displayName : "\(l.kind.displayName) (\(l.kindDetail))",
                             l.blendMode.displayName, "\(Int((l.opacity * 100).rounded()))%"]
                if let fo = l.fillOpacity, fo < 1 { line2.append("fill \(Int((fo * 100).rounded()))%") }
                if l.isClipped { line2.append("clipped") }
                if l.hasMask { line2.append("mask") }
                let fx = l.effects.isEmpty ? "" : "fx  " + l.effects.joined(separator: ", ") + (l.effectsVisible ? "" : " (off)")
                rows.append(PanelRow(title: l.name.isEmpty ? "(unnamed layer)" : l.name, line2: line2.joined(separator: " · "), line3: fx,
                                     depth: l.depth, thumbnail: thumb, glyph: glyph, hasEye: true, eyeOn: l.isVisible, index: i))
            }
            var info: [(String, String)] = [
                ("Size", "\(psd.width) × \(psd.height) px"),
                ("Bit depth", "\(psd.depth) bits/channel"),
                ("Colour mode", PSDColorMode.name(psd.colorMode) + (psd.iccProfileSize > 0 ? " (profile embedded)" : "")),
                ("Layers", "\(psd.layers.count)"),
                ("Resolution", psd.resolution.map { String(format: "%.0f ppi", $0) } ?? "not stored"),
                ("Format", (psd.isPSB ? "PSB (large document)" : "PSD") + ", \(sizeText)"),
            ]
            if !psd.warnings.isEmpty { info.append(("Warning", psd.warnings[0])) }
            let msg = comp == nil ? "This document has no composite image to show (\(err ?? "none stored")).\n\nIts layers are listed on the right: double-click one to preview its pixels." : nil
            return Prepared(file: f, rows: rows, picture: comp, message: msg, info: info, listTitle: "Layers",
                            emptyText: "This document has no layers (only a flattened image).")
        case .image(let img, let kind):
            let info: [(String, String)] = [("Size", "\(img.width) × \(img.height) px"), ("Format", kind), ("Transparency", img.isOpaque ? "none" : "yes"), ("File size", sizeText)]
            return Prepared(file: f, rows: [], picture: img, message: nil, info: info, listTitle: "Layers", emptyText: "A PNG image has a single layer.")
        case .brushes(let set, let tips):
            let limit = 300
            let shown = Array(tips.prefix(limit))
            let sheet = FileLoader.brushSheet(shown)
            var rows: [PanelRow] = []
            for (i, t) in tips.enumerated() {
                rows.append(PanelRow(title: t.name.isEmpty ? "Brush \(i + 1)" : t.name, line2: t.detail, line3: t.folder, depth: 0,
                                     thumbnail: t.image.downscaled(maxSide: 96), glyph: nil, hasEye: false, eyeOn: true, index: i))
            }
            let info: [(String, String)] = [("Format", set.format.isEmpty ? "Brush file" : set.format), ("Set", set.name), ("Brushes", "\(set.brushes.count)"),
                                            ("Patterns", "\(set.patterns.count)"), ("File size", sizeText)] + (set.skipped.isEmpty ? [] : [("Skipped", "\(set.skipped.count): \(set.skipped[0])")])
            var p = Prepared(file: f, rows: rows, picture: sheet.image, message: nil, info: info, listTitle: "Brushes", emptyText: "No brushes.")
            p.sheetCells = sheet.cells
            p.sheetLabels = shown.map(\.name)
            if tips.count > limit { p.sheetNote = "Showing the first \(limit) of \(tips.count) brush tips." }
            return p
        }
    }

    func finishLoad() {
        lock.lock()
        let p = pending
        pending = nil
        lock.unlock()
        guard let (gen, result, path) = p, gen == generation else { return }
        busy = false
        canvas.message = nil
        switch result {
        case .failure(let error):
            let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            canvas.message = current == nil ? welcomeText : nil
            if let c = current { canvas.setImage(c.picture) } else { canvas.setImage(nil) }
            updateStatus()
            FileHandle.standardError.write(Data("error: \(path): \(text)\n".utf8))
            messageBox(main, "“\(URL(fileURLWithPath: path).lastPathComponent)” could not be opened.\n\n\(text)")
            if headless { exitCode = 1 }
        case .success(var prep):
            if !prep.sheetCells.isEmpty, let pic = prep.picture { prep.picture = drawSheetLabels(pic, prep.sheetCells, prep.sheetLabels) }
            current = prep
            currentPath = path
            setWindowText(main, "\(prep.file.displayName) — ImageCrat Preview (technical preview)")
            panel.title = prep.file.displayName
            panel.infoLines = prep.info
            panel.listTitle = prep.listTitle
            panel.emptyText = prep.emptyText
            panel.rows = prep.rows
            canvas.message = prep.message
            canvas.banner = prep.sheetNote
            canvas.setImage(prep.picture)
            if !headless || snapshot == nil { addRecent(path) }
            updateStatus()
        }
        if snapshot != nil { Snapshot.loaded() }
    }

    /// Writes the brush names under the tips of the sheet (GDI text into a DIB, read back).
    func drawSheetLabels(_ img: RGBA8Image, _ cells: [FileLoader.SheetCell], _ labels: [String]) -> RGBA8Image {
        let b = BackBuffer()
        b.ensure(img.width, img.height)
        guard let bits = b.bits, let dc = b.dc, b.width == img.width else { return img }
        for i in 0..<(img.width * img.height) {
            bits[i] = bgra(Int(img.pixels[i * 4]), Int(img.pixels[i * 4 + 1]), Int(img.pixels[i * 4 + 2]))
        }
        let font = makeFont("Segoe UI", points: 8.5, dpi: 96)
        let old = SelectObject(dc, gdi(font))
        for c in cells where c.index < labels.count {
            let r = c.labelRect
            drawText(dc, labels[c.index], makeRect(r.x, r.y, r.width, r.height), W32.DT_CENTER | W32.DT_WORDBREAK | W32.DT_END_ELLIPSIS, color: rgb(40, 40, 48))
        }
        SelectObject(dc, old)
        DeleteObject(gdi(font))
        var out = img
        let px = b.rgba()
        for i in 0..<(img.width * img.height) { out.pixels[i * 4] = px[i * 4]; out.pixels[i * 4 + 1] = px[i * 4 + 1]; out.pixels[i * 4 + 2] = px[i * 4 + 2] }
        return out
    }

    let welcomeText = "Open a Photoshop document (.psd, .psb), a PNG or a brush file (.abr, .gbr, .brushset, .kpp …)\nwith File ▸ Open (Ctrl+O), or drop it on this window.\n\nTechnical preview: viewing only — editing arrives in later versions."

    func showEmptyState() {
        canvas.message = welcomeText
        panel.title = "No document"
        panel.infoLines = [("Version", BuildInfo.version + " (\(BuildInfo.architecture))"), ("Build", BuildInfo.buildDate)]
        panel.rows = []
        panel.emptyText = "Open a file to see its layers, or its brushes."
        canvas.setImage(nil)
    }

    // MARK: Layers

    func rowSelected(_ i: Int?) {
        guard let c = current, case .psd(let psd, _, _) = c.file.content, let i, psd.layers.indices.contains(i) else { canvas.outline = nil; canvas.invalidate(); return }
        let l = psd.layers[i]
        canvas.outline = (l.kind == .group || l.kind == .artboard || l.rect.width == 0) ? nil : l.rect
        canvas.invalidate()
        setStatus(0, PSDFile.describe(l).trimmingCharacters(in: .whitespaces))
    }

    func rowActivated(_ i: Int) {
        guard let c = current, case .psd(let psd, _, _) = c.file.content, psd.layers.indices.contains(i) else { return }
        let l = psd.layers[i]
        guard let img = psd.layerImage(l.recordIndex) else {
            setStatus(0, "“\(l.name)” has no pixels of its own to preview (\(l.kind.displayName.lowercased())).")
            return
        }
        // the layer in place on a transparent canvas
        var full = RGBA8Image(width: psd.width, height: psd.height)
        for y in 0..<img.height {
            let cy = l.rect.y + y
            guard cy >= 0, cy < psd.height else { continue }
            for x in 0..<img.width {
                let cx = l.rect.x + x
                guard cx >= 0, cx < psd.width else { continue }
                let s = (y * img.width + x) * 4, d = (cy * psd.width + cx) * 4
                full.pixels[d] = img.pixels[s]; full.pixels[d + 1] = img.pixels[s + 1]; full.pixels[d + 2] = img.pixels[s + 2]; full.pixels[d + 3] = img.pixels[s + 3]
            }
        }
        layerPreview = i
        canvas.message = nil
        canvas.banner = "Layer preview: \(l.name) — its stored pixels only (no mask, effects or blending). Esc shows the composite."
        canvas.setImage(full, keepView: canvas.imageWidth == psd.width && canvas.imageHeight == psd.height)
    }

    func showComposite() {
        guard layerPreview != nil, let c = current else { return }
        layerPreview = nil
        canvas.banner = c.sheetNote
        canvas.message = c.message
        canvas.setImage(c.picture, keepView: c.picture?.width == canvas.imageWidth && c.picture?.height == canvas.imageHeight)
    }

    func eyeChanged(_ i: Int) {
        guard i < panel.rows.count else { return }
        let r = panel.rows[i]
        setStatus(0, "“\(r.title)”: thumbnail \(r.eyeOn ? "shown" : "dimmed") (the composite is not re-rendered in this preview)")
    }
}
