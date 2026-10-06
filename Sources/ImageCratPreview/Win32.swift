import Foundation
import WinSDK
import ImageCratCore

// Small Win32 helpers. Constants are spelled out here (rather than taken from the SDK headers) because many of them
// are compound macros that Swift imports with varying types, or not at all.

enum W32 {
    // window styles
    static let WS_OVERLAPPEDWINDOW: DWORD = 0x00CF_0000
    static let WS_POPUP: DWORD = 0x8000_0000
    static let WS_CHILD: DWORD = 0x4000_0000
    static let WS_VISIBLE: DWORD = 0x1000_0000
    static let WS_CLIPSIBLINGS: DWORD = 0x0400_0000
    static let WS_CLIPCHILDREN: DWORD = 0x0200_0000
    static let WS_CAPTION: DWORD = 0x00C0_0000
    static let WS_BORDER: DWORD = 0x0080_0000
    static let WS_VSCROLL: DWORD = 0x0020_0000
    static let WS_HSCROLL: DWORD = 0x0010_0000
    static let WS_SYSMENU: DWORD = 0x0008_0000
    static let WS_THICKFRAME: DWORD = 0x0004_0000
    static let WS_TABSTOP: DWORD = 0x0001_0000
    static let WS_MINIMIZEBOX: DWORD = 0x0002_0000
    static let WS_MAXIMIZEBOX: DWORD = 0x0001_0000
    static let WS_EX_ACCEPTFILES: DWORD = 0x0000_0010
    static let WS_EX_DLGMODALFRAME: DWORD = 0x0000_0001
    static let WS_EX_CLIENTEDGE: DWORD = 0x0000_0200
    static let WS_EX_TOOLWINDOW: DWORD = 0x0000_0080
    // control styles
    static let ES_MULTILINE: DWORD = 0x0004
    static let ES_READONLY: DWORD = 0x0800
    static let ES_AUTOVSCROLL: DWORD = 0x0040
    static let ES_AUTOHSCROLL: DWORD = 0x0080
    static let BS_PUSHBUTTON: DWORD = 0x0000
    static let BS_DEFPUSHBUTTON: DWORD = 0x0001
    static let SBARS_SIZEGRIP: DWORD = 0x0100
    static let SS_LEFT: DWORD = 0x0000
    // class styles
    static let CS_VREDRAW: UINT = 0x0001
    static let CS_HREDRAW: UINT = 0x0002
    static let CS_DBLCLKS: UINT = 0x0008

    // messages
    static let WM_CREATE: UINT = 0x0001
    static let WM_DESTROY: UINT = 0x0002
    static let WM_SIZE: UINT = 0x0005
    static let WM_SETFOCUS: UINT = 0x0007
    static let WM_ENABLE: UINT = 0x000A
    static let WM_SETTEXT: UINT = 0x000C
    static let WM_PAINT: UINT = 0x000F
    static let WM_CLOSE: UINT = 0x0010
    static let WM_ERASEBKGND: UINT = 0x0014
    static let WM_SETCURSOR: UINT = 0x0020
    static let WM_GETMINMAXINFO: UINT = 0x0024
    static let WM_SETFONT: UINT = 0x0030
    static let WM_NOTIFY: UINT = 0x004E
    static let WM_KEYDOWN: UINT = 0x0100
    static let WM_KEYUP: UINT = 0x0101
    static let WM_CHAR: UINT = 0x0102
    static let WM_COMMAND: UINT = 0x0111
    static let WM_TIMER: UINT = 0x0113
    static let WM_HSCROLL: UINT = 0x0114
    static let WM_VSCROLL: UINT = 0x0115
    static let WM_INITMENUPOPUP: UINT = 0x0117
    static let WM_CTLCOLORSTATIC: UINT = 0x0138
    static let WM_MOUSEMOVE: UINT = 0x0200
    static let WM_LBUTTONDOWN: UINT = 0x0201
    static let WM_LBUTTONUP: UINT = 0x0202
    static let WM_LBUTTONDBLCLK: UINT = 0x0203
    static let WM_RBUTTONDOWN: UINT = 0x0204
    static let WM_MBUTTONDOWN: UINT = 0x0207
    static let WM_MBUTTONUP: UINT = 0x0208
    static let WM_MOUSEWHEEL: UINT = 0x020A
    static let WM_MOUSEHWHEEL: UINT = 0x020E
    static let WM_CAPTURECHANGED: UINT = 0x0215
    static let WM_DROPFILES: UINT = 0x0233
    static let WM_DPICHANGED: UINT = 0x02E0
    static let WM_PRINTCLIENT: UINT = 0x0318
    static let WM_USER: UINT = 0x0400
    static let WM_APP: UINT = 0x8000

    // status bar
    static let SB_SETPARTS: UINT = 0x0404
    static let SB_SETTEXTW: UINT = 0x040B
    // scroll bars
    static let SB_VERT: Int32 = 1
    static let SB_HORZ: Int32 = 0
    static let SIF_RANGE: UINT = 0x1
    static let SIF_PAGE: UINT = 0x2
    static let SIF_POS: UINT = 0x4
    static let SIF_TRACKPOS: UINT = 0x10
    static let SIF_ALL: UINT = 0x17
    static let SB_LINEUP: Int = 0, SB_LINEDOWN: Int = 1, SB_PAGEUP: Int = 2, SB_PAGEDOWN: Int = 3
    static let SB_THUMBPOSITION: Int = 4, SB_THUMBTRACK: Int = 5, SB_TOP: Int = 6, SB_BOTTOM: Int = 7

    // menus
    static let MF_STRING: UINT = 0x0000
    static let MF_GRAYED: UINT = 0x0001
    static let MF_POPUP: UINT = 0x0010
    static let MF_SEPARATOR: UINT = 0x0800
    static let MF_BYCOMMAND: UINT = 0x0000
    static let MF_BYPOSITION: UINT = 0x0400
    static let MF_ENABLED: UINT = 0x0000

    // accelerators
    static let FVIRTKEY: UInt8 = 0x01
    static let FSHIFT: UInt8 = 0x04
    static let FCONTROL: UInt8 = 0x08

    // virtual keys
    static let VK_SHIFT: Int32 = 0x10
    static let VK_CONTROL: Int32 = 0x11
    static let VK_ESCAPE: UInt16 = 0x1B
    static let VK_SPACE: Int32 = 0x20
    static let VK_PRIOR: Int = 0x21, VK_NEXT: Int = 0x22, VK_END: Int = 0x23, VK_HOME: Int = 0x24
    static let VK_LEFT: Int = 0x25, VK_UP: Int = 0x26, VK_RIGHT: Int = 0x27, VK_DOWN: Int = 0x28
    static let VK_ADD: UInt16 = 0x6B
    static let VK_SUBTRACT: UInt16 = 0x6D
    static let VK_OEM_PLUS: UInt16 = 0xBB
    static let VK_OEM_MINUS: UInt16 = 0xBD
    static let VK_F1: UInt16 = 0x70

    // ShowWindow
    static let SW_HIDE: Int32 = 0
    static let SW_SHOWNORMAL: Int32 = 1
    static let SW_SHOW: Int32 = 5
    static let SW_SHOWNOACTIVATE: Int32 = 4
    // SetWindowPos
    static let SWP_NOSIZE: UINT = 0x0001
    static let SWP_NOMOVE: UINT = 0x0002
    static let SWP_NOZORDER: UINT = 0x0004
    static let SWP_NOACTIVATE: UINT = 0x0010
    // MessageBox
    static let MB_OK: UINT = 0x0000
    static let MB_ICONERROR: UINT = 0x0010
    static let MB_ICONWARNING: UINT = 0x0030
    static let MB_ICONINFORMATION: UINT = 0x0040
    // DrawText
    static let DT_LEFT: UINT = 0x0000
    static let DT_CENTER: UINT = 0x0001
    static let DT_RIGHT: UINT = 0x0002
    static let DT_VCENTER: UINT = 0x0004
    static let DT_BOTTOM: UINT = 0x0008
    static let DT_WORDBREAK: UINT = 0x0010
    static let DT_SINGLELINE: UINT = 0x0020
    static let DT_NOPREFIX: UINT = 0x0800
    static let DT_CALCRECT: UINT = 0x0400
    static let DT_END_ELLIPSIS: UINT = 0x8000
    // GDI
    static let TRANSPARENT: Int32 = 1
    static let DIB_RGB_COLORS: UINT = 0
    static let SRCCOPY: DWORD = 0x00CC_0020
    static let BI_RGB: DWORD = 0
    static let PS_SOLID: Int32 = 0
    static let PS_DOT: Int32 = 2
    static let NULL_BRUSH: Int32 = 5
    static let FW_NORMAL: Int32 = 400
    static let FW_SEMIBOLD: Int32 = 600
    static let FW_BOLD: Int32 = 700
    static let DEFAULT_CHARSET: DWORD = 1
    static let CLEARTYPE_QUALITY: DWORD = 5
    // cursors
    static let IDC_ARROW = 32512
    static let IDC_SIZEWE = 32644
    static let IDC_HAND = 32649
    static let IDC_SIZEALL = 32646
    static let IDC_WAIT = 32514
    static let IDC_APPSTARTING = 32650
    // icons / images
    static let IMAGE_ICON: UINT = 1
    static let LR_DEFAULTCOLOR: UINT = 0
    static let LR_SHARED: UINT = 0x8000
    static let LR_LOADFROMFILE: UINT = 0x0010
    static let DI_NORMAL: UINT = 0x0003
    static let ICON_SMALL: WPARAM = 0
    static let ICON_BIG: WPARAM = 1
    static let WM_SETICON: UINT = 0x0080
    // misc
    static let HTCLIENT: Int = 1
    static let IDOK: Int = 1
    static let IDCANCEL: Int = 2
    static let PW_CLIENTONLY: UINT = 0x1
    static let PW_RENDERFULLCONTENT: UINT = 0x2
    static let OFN_OVERWRITEPROMPT: DWORD = 0x0000_0002
    static let OFN_HIDEREADONLY: DWORD = 0x0000_0004
    static let OFN_NOCHANGEDIR: DWORD = 0x0000_0008
    static let OFN_PATHMUSTEXIST: DWORD = 0x0000_0800
    static let OFN_FILEMUSTEXIST: DWORD = 0x0000_1000
    static let OFN_EXPLORER: DWORD = 0x0008_0000
    static let ICC_WIN95_CLASSES: DWORD = 0x0000_00FF
    static let ICC_LINK_CLASS: DWORD = 0x0000_8000
    static let ICC_BAR_CLASSES: DWORD = 0x0000_0004
    static let NM_CLICK: UINT = UINT(bitPattern: -2)
    static let NM_RETURN: UINT = UINT(bitPattern: -4)
    static let CF_UNICODETEXT: UINT = 13
    static let GMEM_MOVEABLE: UINT = 0x0002
    static let SM_CXSCREEN: Int32 = 0
    static let SM_CYSCREEN: Int32 = 1
    static let COLOR_WINDOW: Int32 = 5
    static let COLOR_BTNFACE: Int32 = 15
    static let SPI_GETWORKAREA: UINT = 0x0030
    static let EXCEPTION_EXECUTE_HANDLER: Int32 = 1
}

// MARK: - Strings

/// Calls `body` with a NUL-terminated UTF-16 copy of `s`.
@inline(__always)
func withWide<R>(_ s: String, _ body: (UnsafePointer<WCHAR>) -> R) -> R {
    s.withCString(encodedAs: UTF16.self) { body($0) }
}

extension String {
    /// NUL-terminated UTF-16.
    var wide: [WCHAR] { Array(utf16) + [0] }

    init(wideBuffer b: [WCHAR]) {
        let n = b.firstIndex(of: 0) ?? b.count
        self = String(decoding: b[0..<n], as: UTF16.self)
    }
}

// MARK: - Parameters

@inline(__always) func loWord(_ v: LPARAM) -> Int { Int(UInt64(bitPattern: Int64(v)) & 0xFFFF) }
@inline(__always) func hiWord(_ v: LPARAM) -> Int { Int((UInt64(bitPattern: Int64(v)) >> 16) & 0xFFFF) }
@inline(__always) func loWordW(_ v: WPARAM) -> Int { Int(UInt64(v) & 0xFFFF) }
@inline(__always) func hiWordW(_ v: WPARAM) -> Int { Int((UInt64(v) >> 16) & 0xFFFF) }
/// Signed client coordinates of a mouse message.
@inline(__always) func pointFrom(_ l: LPARAM) -> (x: Int, y: Int) {
    let u = UInt64(bitPattern: Int64(l))
    return (Int(Int16(truncatingIfNeeded: u & 0xFFFF)), Int(Int16(truncatingIfNeeded: (u >> 16) & 0xFFFF)))
}
@inline(__always) func wheelDelta(_ w: WPARAM) -> Int { Int(Int16(truncatingIfNeeded: (UInt64(w) >> 16) & 0xFFFF)) }

func keyDown(_ vk: Int32) -> Bool { GetKeyState(vk) < 0 }

func rgb(_ r: Int, _ g: Int, _ b: Int) -> COLORREF { COLORREF(UInt32(r & 255) | UInt32(g & 255) << 8 | UInt32(b & 255) << 16) }

func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR>? { UnsafePointer<WCHAR>(bitPattern: UInt(id)) }

func loadCursor(_ id: Int) -> HCURSOR? { LoadCursorW(nil, resourcePointer(id)) }

func gdi<T>(_ p: UnsafeMutablePointer<T>?) -> HGDIOBJ? { p.map { UnsafeMutableRawPointer($0) } }

func brush(_ c: COLORREF) -> HBRUSH? { CreateSolidBrush(c) }

func fillRect(_ dc: HDC?, _ r: RECT, _ c: COLORREF) {
    var rr = r
    let b = CreateSolidBrush(c)
    FillRect(dc, &rr, b)
    DeleteObject(gdi(b))
}

func makeRect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> RECT {
    RECT(left: LONG(x), top: LONG(y), right: LONG(x + w), bottom: LONG(y + h))
}

func clientSize(_ hwnd: HWND?) -> (w: Int, h: Int) {
    var rc = RECT()
    GetClientRect(hwnd, &rc)
    return (Int(rc.right - rc.left), Int(rc.bottom - rc.top))
}

/// Draws `text` in `r` with the given DrawText flags.
func drawText(_ dc: HDC?, _ text: String, _ r: RECT, _ flags: UINT, color: COLORREF) {
    var rr = r
    SetTextColor(dc, color)
    SetBkMode(dc, W32.TRANSPARENT)
    var w = Array(text.utf16)
    if w.isEmpty { return }
    _ = w.withUnsafeMutableBufferPointer { DrawTextW(dc, $0.baseAddress, Int32($0.count), &rr, flags | W32.DT_NOPREFIX) }
}

/// Height `text` needs at `width` px with word wrap.
func measureText(_ dc: HDC?, _ text: String, width: Int, flags: UINT = W32.DT_WORDBREAK) -> Int {
    var rr = makeRect(0, 0, width, 0)
    var w = Array(text.utf16)
    if w.isEmpty { return 0 }
    _ = w.withUnsafeMutableBufferPointer { DrawTextW(dc, $0.baseAddress, Int32($0.count), &rr, flags | W32.DT_CALCRECT | W32.DT_NOPREFIX) }
    return Int(rr.bottom - rr.top)
}

func messageBox(_ owner: HWND?, _ text: String, _ title: String = "ImageCrat Preview", _ flags: UINT = W32.MB_OK | W32.MB_ICONERROR) {
    if App.shared.headless { FileHandle.standardError.write(Data("[message box] \(title): \(text)\n".utf8)); return }
    _ = withWide(text) { t in withWide(title) { c in MessageBoxW(owner, t, c, flags) } }
}

func setWindowText(_ hwnd: HWND?, _ s: String) { _ = withWide(s) { SetWindowTextW(hwnd, $0) } }

/// Font of `points` size at `dpi`.
func makeFont(_ face: String, points: Double, dpi: Int, weight: Int32 = W32.FW_NORMAL, italic: Bool = false) -> HFONT? {
    let h = -Int32((points * Double(dpi) / 72).rounded())
    return withWide(face) {
        CreateFontW(h, 0, 0, 0, weight, italic ? 1 : 0, 0, 0, W32.DEFAULT_CHARSET, 0, 0, W32.CLEARTYPE_QUALITY, 0, $0)
    }
}

func setFont(_ hwnd: HWND?, _ font: HFONT?) {
    _ = SendMessageW(hwnd, W32.WM_SETFONT, WPARAM(UInt(bitPattern: font.map { Int(bitPattern: $0) } ?? 0)), 1)
}

func dpiOf(_ hwnd: HWND?) -> Int {
    let d = Int(GetDpiForWindow(hwnd))
    return d > 0 ? d : 96
}

func hmenuID(_ id: Int) -> HMENU? { HMENU(bitPattern: UInt(id)) }

/// Copies `text` to the Windows clipboard (the report window's "Copy Report").
func copyToClipboard(_ owner: HWND?, _ text: String) {
    guard OpenClipboard(owner) else { return }
    defer { CloseClipboard() }
    EmptyClipboard()
    let w = text.wide
    let bytes = w.count * 2
    guard let h = GlobalAlloc(W32.GMEM_MOVEABLE, SIZE_T(bytes)), let p = GlobalLock(h) else { return }
    w.withUnsafeBytes { src in p.copyMemory(from: src.baseAddress!, byteCount: bytes) }
    GlobalUnlock(h)
    SetClipboardData(W32.CF_UNICODETEXT, HANDLE(h))
}

func openURL(_ url: String) {
    _ = withWide("open") { verb in withWide(url) { u in ShellExecuteW(nil, verb, u, nil, nil, W32.SW_SHOWNORMAL) } }
}

// MARK: - Back buffer

/// A 32-bit top-down DIB section with a memory DC: draw pixels through `bits` and text with GDI, then blit.
final class BackBuffer {
    private(set) var dc: HDC?
    private var bitmap: HBITMAP?
    private var old: HGDIOBJ?
    private(set) var bits: UnsafeMutablePointer<UInt32>?
    private(set) var width = 0
    private(set) var height = 0

    /// Makes sure the buffer is `w` × `h` (recreated when the size changes).
    func ensure(_ w: Int, _ h: Int) {
        let w = max(1, w), h = max(1, h)
        if w == width && h == height && dc != nil { return }
        release()
        var bmi = BITMAPINFO()
        bmi.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        bmi.bmiHeader.biWidth = LONG(w)
        bmi.bmiHeader.biHeight = -LONG(h)   // top-down
        bmi.bmiHeader.biPlanes = 1
        bmi.bmiHeader.biBitCount = 32
        bmi.bmiHeader.biCompression = W32.BI_RGB
        let screen = GetDC(nil)
        dc = CreateCompatibleDC(screen)
        ReleaseDC(nil, screen)
        var p: UnsafeMutableRawPointer? = nil
        bitmap = CreateDIBSection(dc, &bmi, W32.DIB_RGB_COLORS, &p, nil, 0)
        guard bitmap != nil, let p else { release(); return }
        bits = p.assumingMemoryBound(to: UInt32.self)
        old = SelectObject(dc, gdi(bitmap))
        width = w; height = h
    }

    func blit(to target: HDC?, x: Int = 0, y: Int = 0) {
        guard let dc else { return }
        GdiFlush()
        BitBlt(target, Int32(x), Int32(y), Int32(width), Int32(height), dc, 0, 0, W32.SRCCOPY)
    }

    /// Straight RGBA copy of the pixels (for snapshots).
    func rgba() -> [UInt8] {
        GdiFlush()
        guard let bits else { return [] }
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = bits[i]
            out[i * 4] = UInt8((v >> 16) & 255); out[i * 4 + 1] = UInt8((v >> 8) & 255); out[i * 4 + 2] = UInt8(v & 255)
        }
        return out
    }

    func release() {
        if let dc {
            if let old { SelectObject(dc, old) }
            DeleteDC(dc)
        }
        if let bitmap { DeleteObject(gdi(bitmap)) }
        dc = nil; bitmap = nil; old = nil; bits = nil; width = 0; height = 0
    }

    deinit { release() }
}

/// BGRA (0xAARRGGBB in memory order B, G, R, A) of an opaque colour.
@inline(__always) func bgra(_ r: Int, _ g: Int, _ b: Int) -> UInt32 { 0xFF00_0000 | UInt32(r & 255) << 16 | UInt32(g & 255) << 8 | UInt32(b & 255) }

/// Draws straight-RGBA `img` over a checkerboard into `buf` at (x, y), scaled to `w` × `h` (box/nearest sampling).
/// `faded`: drawn at 35% (hidden layers).
func drawImage(_ img: RGBA8Image, into buf: BackBuffer, x: Int, y: Int, w: Int, h: Int, checker: Int = 4, faded: Bool = false) {
    guard let bits = buf.bits, img.width > 0, img.height > 0, w > 0, h > 0 else { return }
    let sx = Double(img.width) / Double(w), sy = Double(img.height) / Double(h)
    img.pixels.withUnsafeBufferPointer { p in
        for yy in 0..<h {
            let dy = y + yy
            guard dy >= 0, dy < buf.height else { continue }
            let y0 = min(img.height - 1, Int(Double(yy) * sy)), y1 = min(img.height, max(y0 + 1, Int(Double(yy + 1) * sy)))
            for xx in 0..<w {
                let dx = x + xx
                guard dx >= 0, dx < buf.width else { continue }
                let x0 = min(img.width - 1, Int(Double(xx) * sx)), x1 = min(img.width, max(x0 + 1, Int(Double(xx + 1) * sx)))
                var r = 0, g = 0, b = 0, a = 0, n = 0
                for yy2 in y0..<y1 { for xx2 in x0..<x1 {
                    let i = (yy2 * img.width + xx2) * 4
                    let aa = Int(p[i + 3])
                    r += Int(p[i]) * aa; g += Int(p[i + 1]) * aa; b += Int(p[i + 2]) * aa; a += aa; n += 1
                } }
                let light = ((xx / checker) + (yy / checker)) % 2 == 0
                let bg = light ? 255 : 204
                var A = n > 0 ? a / n : 0
                if faded { A = A * 35 / 100 }
                let R = a > 0 ? r / a : 0, G = a > 0 ? g / a : 0, B = a > 0 ? b / a : 0
                bits[dy * buf.width + dx] = bgra((R * A + bg * (255 - A)) / 255, (G * A + bg * (255 - A)) / 255, (B * A + bg * (255 - A)) / 255)
            }
        }
    }
}

func fillPixels(_ buf: BackBuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt32) {
    guard let bits = buf.bits else { return }
    let x0 = max(0, x), y0 = max(0, y), x1 = min(buf.width, x + w), y1 = min(buf.height, y + h)
    guard x1 > x0, y1 > y0 else { return }
    for yy in y0..<y1 { let row = bits + yy * buf.width; for xx in x0..<x1 { row[xx] = c } }
}
