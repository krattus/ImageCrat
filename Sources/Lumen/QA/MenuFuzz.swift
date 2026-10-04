import AppKit
import SwiftUI
import ObjectiveC
import Darwin

/// Launched-app fuzz driver. The app runs for real (SwiftUI scene, main menu, canvas, panels) but invisibly: every
/// window is fully transparent and ignores the mouse, the app is an accessory that never activates, and all blocking
/// UI is answered by `Automation`. One process runs one scenario; progress is journaled so an outer runner can restart
/// after a crash or hang and continue with the next item.
enum MenuFuzz {
    static var scenarioName = "probe"
    static var outDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lumen-menu-fuzz")

    static func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        for (i, a) in args.enumerated() {
            if a.hasPrefix(name + "=") { return String(a.dropFirst(name.count + 1)) }
            if a == name, i + 1 < args.count, !args[i + 1].hasPrefix("--") { return args[i + 1] }
        }
        return nil
    }

    /// Called from module registration (before any window exists).
    static func prepareLaunch() {
        scenarioName = argument("--menu-fuzz") ?? "probe"
        // Start from factory settings (the runner gives every scenario its own "LumenFuzz-…" executable name and
        // therefore its own preferences domain; never wipe the domain of a normally named build).
        let domain = ProcessInfo.processInfo.processName
        if domain.hasPrefix("LumenFuzz") { UserDefaults.standard.removePersistentDomain(forName: domain) }
        if let o = argument("--out") { outDir = URL(fileURLWithPath: o) }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if scenarioName == "list" {
            try? FuzzScenarios.names.joined(separator: "\n").write(to: outDir.appendingPathComponent("scenarios.txt"), atomically: true, encoding: .utf8)
            FuzzFixtures.ensure()
            exit(0)
        }
        FuzzCrash.install()
        hideWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            waitForUI(attempt: 0)
        }
    }

    private static func waitForUI(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let ready = (NSApp.mainMenu?.items.count ?? 0) > 3 && AppActions.canvas != nil
            if !ready && attempt < 50 { waitForUI(attempt: attempt + 1); return }
            // a modest window: less for the window server to composite while the user works in other apps
            if let w = Fuzz.mainWindow { w.setFrame(NSRect(x: 0, y: 0, width: 1360, height: 860), display: false) }
            FuzzLog.note("ui ready after \(attempt) polls: menu items \(NSApp.mainMenu?.items.count ?? 0), canvas \(AppActions.canvas != nil), windows \(NSApp.windows.count)")
            FuzzDriver.run()
            FuzzLog.note("DONE")
            FuzzLog.done()
            exit(0)
        }
    }

    // MARK: Invisible windows

    nonisolated(unsafe) private static var hidden = false
    /// Makes every window of this process invisible and click-through before it is ordered in.
    private static func hideWindows() {
        guard !hidden else { return }
        hidden = true
        func mute(_ w: NSWindow) {
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.hasShadow = false
        }
        let sels: [Selector] = [#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.makeKeyAndOrderFront(_:)),
                                #selector(NSWindow.orderFront(_:)), #selector(NSWindow.orderFrontRegardless)]
        guard let m0 = class_getInstanceMethod(NSWindow.self, sels[0]), let m1 = class_getInstanceMethod(NSWindow.self, sels[1]),
              let m2 = class_getInstanceMethod(NSWindow.self, sels[2]), let m3 = class_getInstanceMethod(NSWindow.self, sels[3]) else { return }
        typealias F0 = @convention(c) (NSWindow, Selector, Int, Int) -> Void
        typealias F1 = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
        typealias F3 = @convention(c) (NSWindow, Selector) -> Void
        let o0 = unsafeBitCast(method_getImplementation(m0), to: F0.self)
        let o1 = unsafeBitCast(method_getImplementation(m1), to: F1.self)
        let o2 = unsafeBitCast(method_getImplementation(m2), to: F1.self)
        let o3 = unsafeBitCast(method_getImplementation(m3), to: F3.self)
        method_setImplementation(m0, imp_implementationWithBlock({ (w: NSWindow, mode: Int, rel: Int) in mute(w); o0(w, sels[0], mode, rel) } as @convention(block) (NSWindow, Int, Int) -> Void))
        method_setImplementation(m1, imp_implementationWithBlock({ (w: NSWindow, s: AnyObject?) in mute(w); o1(w, sels[1], s) } as @convention(block) (NSWindow, AnyObject?) -> Void))
        method_setImplementation(m2, imp_implementationWithBlock({ (w: NSWindow, s: AnyObject?) in mute(w); o2(w, sels[2], s) } as @convention(block) (NSWindow, AnyObject?) -> Void))
        method_setImplementation(m3, imp_implementationWithBlock({ (w: NSWindow) in mute(w); o3(w, sels[3]) } as @convention(block) (NSWindow) -> Void))
        // The app never activates, so AppKit reports no key / main window; code that asks for them (is a text field
        // being edited? which window prints?) should see the main window, as it would with the app in front.
        for name in ["keyWindow", "mainWindow"] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(NSApplication.self, sel) else { continue }
            method_setImplementation(m, imp_implementationWithBlock({ (_: NSApplication) -> NSWindow? in Fuzz.mainWindow } as @convention(block) (NSApplication) -> NSWindow?))
        }
        // child windows (popovers) and sheets are ordered in without the calls above
        let childSel = #selector(NSWindow.addChildWindow(_:ordered:))
        if let m = class_getInstanceMethod(NSWindow.self, childSel) {
            typealias F = @convention(c) (NSWindow, Selector, NSWindow, Int) -> Void
            let o = unsafeBitCast(method_getImplementation(m), to: F.self)
            method_setImplementation(m, imp_implementationWithBlock({ (w: NSWindow, child: NSWindow, place: Int) in mute(child); o(w, childSel, child, place) } as @convention(block) (NSWindow, NSWindow, Int) -> Void))
        }
        let sheetSel = #selector(NSWindow.beginSheet(_:completionHandler:))
        if let m = class_getInstanceMethod(NSWindow.self, sheetSel) {
            typealias F = @convention(c) (NSWindow, Selector, NSWindow, AnyObject?) -> Void
            let o = unsafeBitCast(method_getImplementation(m), to: F.self)
            method_setImplementation(m, imp_implementationWithBlock({ (w: NSWindow, sheet: NSWindow, h: AnyObject?) in mute(sheet); o(w, sheetSel, sheet, h) } as @convention(block) (NSWindow, NSWindow, AnyObject?) -> Void))
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            for w in NSApp?.windows ?? [] where w.alphaValue != 0 { mute(w) }
        }
    }
}

/// Journal + results written by the fuzz process.
enum FuzzLog {
    private static var progress: FileHandle?
    private static var notes: FileHandle?

    private static func handle(_ name: String) -> FileHandle? {
        let u = MenuFuzz.outDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: u)
        h?.seekToEndOfFile()
        return h
    }

    static var progressURL: URL { MenuFuzz.outDir.appendingPathComponent(MenuFuzz.scenarioName + ".progress") }

    /// Keys already finished (END / CRASH) in earlier runs of this scenario, and the ones that were begun but never
    /// finished — those crashed or hung the process and are skipped from now on.
    static func loadProgress() -> (done: Set<String>, crashed: [String]) {
        guard let s = try? String(contentsOf: progressURL, encoding: .utf8) else { return ([], []) }
        var done = Set<String>(), open: [String] = []
        for line in s.split(separator: "\n") {
            let p = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 2 else { continue }
            switch p[0] {
            case "BEGIN": open.append(p[1])
            case "END", "CRASH": done.insert(p[1]); open.removeAll { $0 == p[1] }
            default: break
            }
        }
        for k in open { done.insert(k) }
        return (done, open)
    }

    private static func write(_ h: inout FileHandle?, _ name: String, _ line: String) {
        if h == nil { h = handle(name) }
        h?.write((line + "\n").data(using: .utf8)!)
        try? h?.synchronize()
    }

    static func begin(_ key: String) { write(&progress, MenuFuzz.scenarioName + ".progress", "BEGIN\t\(key)") }
    static func end(_ key: String, _ result: String) { write(&progress, MenuFuzz.scenarioName + ".progress", "END\t\(key)\t\(result.replacingOccurrences(of: "\n", with: " ⏎ "))") }
    static func crashed(_ key: String) { write(&progress, MenuFuzz.scenarioName + ".progress", "CRASH\t\(key)") }
    static func done() { write(&progress, MenuFuzz.scenarioName + ".progress", "DONE") }
    static func note(_ s: String) { write(&notes, MenuFuzz.scenarioName + ".notes", s) }
    /// A finding: something that looks wrong (not a crash).
    static func finding(_ key: String, _ s: String) { write(&notes, MenuFuzz.scenarioName + ".notes", "FINDING\t\(key)\t\(s.replacingOccurrences(of: "\n", with: " ⏎ "))") }
}

/// Turns traps into an immediate stack dump + exit (no system crash dialog, no waiting for ReportCrash).
enum FuzzCrash {
    static func install() {
        let slide = _dyld_get_image_vmaddr_slide(0)
        fputs("FUZZ image slide 0x\(String(slide, radix: 16)) load 0x\(String(UInt(bitPattern: slide) &+ 0x1_0000_0000, radix: 16))\n", stderr)
        for sig in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
            signal(sig) { s in
                var msg = Array("FUZZ CRASH signal \(s)\n".utf8)
                write(2, &msg, msg.count)
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let n = backtrace(&frames, 64)
                backtrace_symbols_fd(&frames, n, 2)
                _exit(99)
            }
        }
    }
}
