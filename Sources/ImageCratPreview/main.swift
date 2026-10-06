import Foundation
import WinSDK
import ImageCratWinSupport

// ImageCrat Preview: technical preview of ImageCrat for Windows (Win32 GUI in Swift).
//   ImageCratPreview.exe [file]
// Hidden test flags: --snapshot <out.png> [--select N] [--preview-layer N] [--eye-off N] [--zoom PCT] [--about]
//                    [--selfcheck] [--size WxH]

let app = App.shared
app.hInstance = GetModuleHandleW(nil)

var fileArg: String? = nil
var initialSize: (Int, Int)? = nil
var args = Array(CommandLine.arguments.dropFirst())
var snap: SnapshotRequest? = nil
var i = 0
func nextArg() -> String? { i += 1; return i < args.count ? args[i] : nil }
while i < args.count {
    let a = args[i]
    switch a {
    case "--snapshot": if let v = nextArg() { snap = SnapshotRequest(output: v) }
    case "--select": if let v = nextArg().flatMap(Int.init) { snap?.select = v }
    case "--preview-layer": if let v = nextArg().flatMap(Int.init) { snap?.previewLayer = v }
    case "--eye-off": if let v = nextArg().flatMap(Int.init) { snap?.eyeOff.append(v) }
    case "--zoom": if let v = nextArg().flatMap(Double.init) { snap?.zoom = v / 100 }
    case "--about": snap?.about = true
    case "--selfcheck": snap?.selfCheck = true
    case "--size":
        if let v = nextArg() {
            let p = v.lowercased().split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { initialSize = (p[0], p[1]) }
        }
    case "--version":
        print(BuildInfo.versionLine)
        exit(0)
    default:
        if !a.hasPrefix("--") { fileArg = a }
    }
    i += 1
}
app.snapshot = snap
app.headless = snap != nil

CrashReport.install()

var icc = INITCOMMONCONTROLSEX()
icc.dwSize = DWORD(MemoryLayout<INITCOMMONCONTROLSEX>.size)
icc.dwICC = W32.ICC_WIN95_CLASSES | W32.ICC_LINK_CLASS | W32.ICC_BAR_CLASSES
InitCommonControlsEx(&icc)

app.loadIcons()
app.registerClasses()
app.createMainWindow(initialSize: initialSize)
guard let mainWindow = app.main else {
    messageBox(nil, "The main window could not be created.")
    exit(1)
}
ShowWindow(mainWindow, app.headless ? W32.SW_SHOWNOACTIVATE : W32.SW_SHOWNORMAL)
UpdateWindow(mainWindow)

if let f = fileArg {
    Snapshot.waitingForFile = true
    app.open(f)
}
Snapshot.start()

var msg = MSG()
while GetMessageW(&msg, nil, 0, 0) {
    if let d = app.dialog, IsDialogMessageW(d, &msg) { continue }
    if let accel = app.accel, msg.hwnd == mainWindow || IsChild(mainWindow, msg.hwnd) {
        if TranslateAcceleratorW(mainWindow, accel, &msg) != 0 { continue }
    }
    TranslateMessage(&msg)
    DispatchMessageW(&msg)
}
exit(app.exitCode)
