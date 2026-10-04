import AppKit
import ObjectiveC
import UniformTypeIdentifiers

/// Headless automation mode (`LUMEN_AUTOMATION=1`, or the `--menu-fuzz` driver): every piece of blocking UI — alerts,
/// open / save panels, print panels, the colour sampler, pop-up menus — returns a scripted answer instead of waiting
/// for a person, and is recorded so tests can assert on it. When the flag is off nothing here changes behaviour.
enum Automation {
    /// The launched-app fuzz driver (`Lumen --menu-fuzz <scenario> --out <dir>`).
    static let isFuzz: Bool = CommandLine.arguments.contains { $0 == "--menu-fuzz" || $0.hasPrefix("--menu-fuzz=") }

    /// True when blocking UI must not block. Tests may flip it on for a scope with `withHeadless`.
    static var isHeadless: Bool = ProcessInfo.processInfo.environment["LUMEN_AUTOMATION"] == "1" || isFuzz {
        didSet { if isHeadless { installPanelURLHooks() } }
    }
    /// Headless for the whole process lifetime (environment / fuzz driver) rather than for one test scope.
    static let isProcessWide: Bool = ProcessInfo.processInfo.environment["LUMEN_AUTOMATION"] == "1" || isFuzz

    /// Call once at startup: installs the process-wide safety net when the process runs headless.
    static func bootstrap() {
        guard isProcessWide else { return }
        installPanelURLHooks()
        installHooks()
    }

    enum Answer: String { case cancel, ok }
    /// Scripted answer for the next blocking request (default: cancel / dismiss).
    static var answer: Answer = .cancel
    /// Folder holding fixture files handed out by open panels when `answer == .ok`.
    static var fixtureDir: URL?
    /// Folder that save panels write into when `answer == .ok`.
    static var saveDir: URL?

    struct Request { let kind: String; let detail: String; let answer: String }
    /// Every blocking request answered by script since the last `reset()`.
    private(set) static var requests: [Request] = []
    /// Beeps requested while headless (counted by the interposer the fuzz runner injects; see scripts/qa/beep_interpose.c).
    static var beeps: Int {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "lumen_qa_beep_count") else { return 0 }
        return Int(unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)())
    }
    static func reset() { requests.removeAll() }
    static func record(_ kind: String, _ detail: String, _ answer: String) {
        requests.append(Request(kind: kind, detail: detail, answer: answer))
        if requests.count > 500 { requests.removeFirst(requests.count - 500) }
    }

    /// Runs `body` with headless mode forced on (self tests).
    static func withHeadless<T>(_ answer: Answer = .cancel, _ body: () throws -> T) rethrows -> T {
        let was = isHeadless, wasAnswer = Automation.answer
        isHeadless = true; Automation.answer = answer
        defer { isHeadless = was; Automation.answer = wasAnswer }
        return try body()
    }

    // MARK: Scripted answers

    static func alertResponse(_ a: NSAlert) -> NSApplication.ModalResponse {
        let titles = a.buttons.map(\.title)
        var index = 0
        if answer == .cancel, titles.count > 1 {
            index = titles.firstIndex(where: { $0 == "Cancel" }) ?? (titles.count - 1)
        }
        let r = NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index)
        record("alert", a.messageText + (a.informativeText.isEmpty ? "" : " — " + a.informativeText), titles.isEmpty ? "OK" : titles[index])
        return r
    }

    private static var saveCounter = 0

    /// Decides the scripted result of an open / save panel and stores the URL(s) the panel will report.
    static func panelResponse(_ p: NSSavePanel) -> NSApplication.ModalResponse {
        let isOpen = p is NSOpenPanel
        let what = (isOpen ? "open" : "save") + "Panel"
        let detail = [p.message, p.title, p.nameFieldStringValue, p.allowedContentTypes.map { $0.preferredFilenameExtension ?? $0.identifier }.joined(separator: ",")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
        guard answer == .ok else {
            scripted(p, nil)
            record(what, detail, "cancel")
            return .cancel
        }
        var urls: [URL] = []
        if let op = p as? NSOpenPanel {
            urls = fixtureURLs(for: op)
        } else if let dir = saveDir {
            saveCounter += 1
            var name = p.nameFieldStringValue.isEmpty ? "untitled" : p.nameFieldStringValue
            if (name as NSString).pathExtension.isEmpty, let ext = p.allowedContentTypes.first?.preferredFilenameExtension { name += "." + ext }
            urls = [dir.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)-\(saveCounter)-" + name)]
        }
        guard !urls.isEmpty else {
            scripted(p, nil)
            record(what, detail, "cancel (no fixture)")
            return .cancel
        }
        scripted(p, urls)
        record(what, detail, "ok " + urls.map(\.lastPathComponent).joined(separator: ","))
        return .OK
    }

    /// Fixture files matching an open panel's filters (a folder when it only accepts folders).
    static func fixtureURLs(for op: NSOpenPanel) -> [URL] {
        guard let dir = fixtureDir else { return [] }
        let fm = FileManager.default
        if op.canChooseDirectories && !op.canChooseFiles {
            let d = dir.appendingPathComponent("folder")
            return fm.fileExists(atPath: d.path) ? [d] : [dir]
        }
        let all = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let types = op.allowedContentTypes
        var match = all.filter { u in
            guard !types.isEmpty else { return true }
            guard let t = UTType(filenameExtension: u.pathExtension) else { return false }
            return types.contains { t.conforms(to: $0) || $0.preferredFilenameExtension?.lowercased() == u.pathExtension.lowercased() }
        }
        if match.isEmpty, let ext = types.first?.preferredFilenameExtension {
            // No fixture of that type: hand over a malformed file with the right extension (robustness of the importer).
            let g = dir.appendingPathComponent("garbage." + ext)
            if !fm.fileExists(atPath: g.path) {
                var bytes = [UInt8](repeating: 0, count: 4096)
                for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 131 &+ 7) }
                try? Data(bytes).write(to: g)
            }
            match = [g]
        }
        // Prefer plain raster images first so "choose an image" prompts get one.
        match.sort { a, b in
            let pa = a.pathExtension == "png" ? 0 : 1, pb = b.pathExtension == "png" ? 0 : 1
            return pa != pb ? pa < pb : a.lastPathComponent < b.lastPathComponent
        }
        return op.allowsMultipleSelection ? Array(match.prefix(3)) : Array(match.prefix(1))
    }

    // MARK: Hooks (installed only in headless mode)

    private static var hooksInstalled = false
    nonisolated(unsafe) private static var scriptedKey: UInt8 = 0

    /// nil urls = the panel was cancelled by script (reports no URL).
    private static func scripted(_ p: NSSavePanel, _ urls: [URL]?) {
        objc_setAssociatedObject(p, &scriptedKey, (urls ?? []) as NSArray, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    /// The URLs a scripted panel reports; nil when the panel wasn't answered by script.
    static func scriptedState(_ p: NSSavePanel) -> [URL]? {
        objc_getAssociatedObject(p, &scriptedKey) as? [URL]
    }

    @discardableResult
    private static func replace(_ cls: AnyClass, _ sel: Selector, classMethod: Bool = false, _ block: Any) -> IMP? {
        let target: AnyClass = classMethod ? object_getClass(cls)! : cls
        guard let m = class_getInstanceMethod(target, sel) else { return nil }
        let original = method_getImplementation(m)
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(target, sel, imp, method_getTypeEncoding(m)) { method_setImplementation(m, imp) }
        return original
    }

    private static var urlHooksInstalled = false

    /// Lets a panel that was answered by script report the scripted URL(s) from `url` / `urls`. Panels that really ran
    /// (no scripted value attached) keep AppKit's own implementation, so this is safe outside headless mode too.
    static func installPanelURLHooks() {
        guard !urlHooksInstalled else { return }
        urlHooksInstalled = true
        typealias URLGetter = @convention(c) (AnyObject, Selector) -> NSURL?
        typealias URLsGetter = @convention(c) (AnyObject, Selector) -> NSArray
        let urlSel = #selector(getter: NSSavePanel.url), urlsSel = #selector(getter: NSOpenPanel.urls)
        for cls in [NSSavePanel.self, NSOpenPanel.self] as [AnyClass] {
            guard let m = class_getInstanceMethod(cls, urlSel) else { continue }
            let orig = unsafeBitCast(method_getImplementation(m), to: URLGetter.self)
            replace(cls, urlSel, { (p: NSSavePanel) -> NSURL? in
                if let s = Automation.scriptedState(p) { return s.first as NSURL? }
                return orig(p, urlSel)
            } as @convention(block) (NSSavePanel) -> NSURL?)
        }
        if let m = class_getInstanceMethod(NSOpenPanel.self, urlsSel) {
            let orig = unsafeBitCast(method_getImplementation(m), to: URLsGetter.self)
            replace(NSOpenPanel.self, urlsSel, { (p: NSOpenPanel) -> NSArray in
                if let s = Automation.scriptedState(p) { return s as NSArray }
                return orig(p, urlsSel)
            } as @convention(block) (NSOpenPanel) -> NSArray)
        }
    }

    /// Safety net: even call sites that don't go through `UIBlock` can't block (or reach outside the process) when
    /// the whole process runs headless.
    static func installHooks() {
        guard !hooksInstalled else { return }
        hooksInstalled = true

        replace(NSAlert.self, #selector(NSAlert.runModal), { (a: NSAlert) -> Int in
            Automation.alertResponse(a).rawValue
        } as @convention(block) (NSAlert) -> Int)
        replace(NSAlert.self, #selector(NSAlert.beginSheetModal(for:completionHandler:)), { (a: NSAlert, _: NSWindow, h: (@convention(block) (Int) -> Void)?) in
            let r = Automation.alertResponse(a).rawValue
            DispatchQueue.main.async { h?(r) }
        } as @convention(block) (NSAlert, NSWindow, (@convention(block) (Int) -> Void)?) -> Void)

        for cls in [NSSavePanel.self, NSOpenPanel.self] as [AnyClass] {
            replace(cls, #selector(NSSavePanel.runModal), { (p: NSSavePanel) -> Int in
                Automation.panelResponse(p).rawValue
            } as @convention(block) (NSSavePanel) -> Int)
            replace(cls, #selector(NSSavePanel.begin(completionHandler:)), { (p: NSSavePanel, h: @escaping @convention(block) (Int) -> Void) in
                let r = Automation.panelResponse(p).rawValue
                DispatchQueue.main.async { h(r) }
            } as @convention(block) (NSSavePanel, @escaping @convention(block) (Int) -> Void) -> Void)
            replace(cls, #selector(NSSavePanel.beginSheetModal(for:completionHandler:)), { (p: NSSavePanel, _: NSWindow, h: @escaping @convention(block) (Int) -> Void) in
                let r = Automation.panelResponse(p).rawValue
                DispatchQueue.main.async { h(r) }
            } as @convention(block) (NSSavePanel, NSWindow, @escaping @convention(block) (Int) -> Void) -> Void)
        }

        // Printing: only "save as PDF" jobs without a panel may run (nothing goes to a printer, nothing blocks).
        let runSel = #selector(NSPrintOperation.run)
        if let m = class_getInstanceMethod(NSPrintOperation.self, runSel) {
            typealias Run = @convention(c) (NSPrintOperation, Selector) -> Bool
            let original = unsafeBitCast(method_getImplementation(m), to: Run.self)
            replace(NSPrintOperation.self, runSel, { (op: NSPrintOperation) -> Bool in
                if !op.showsPrintPanel, op.printInfo.jobDisposition == .save { return original(op, runSel) }
                Automation.record("print", op.jobTitle ?? "NSPrintOperation.run", "cancel"); return false
            } as @convention(block) (NSPrintOperation) -> Bool)
        }
        replace(NSPrintOperation.self, #selector(NSPrintOperation.runModal(for:delegate:didRun:contextInfo:)),
                { (_: NSPrintOperation, _: NSWindow, _: AnyObject?, _: Selector?, _: UnsafeMutableRawPointer?) in
            Automation.record("print", "NSPrintOperation.runModal", "cancel")
        } as @convention(block) (NSPrintOperation, NSWindow, AnyObject?, Selector?, UnsafeMutableRawPointer?) -> Void)
        replace(NSPageLayout.self, #selector(NSPageLayout.runModal as (NSPageLayout) -> () -> Int), { (_: NSPageLayout) -> Int in
            Automation.record("pageLayout", "NSPageLayout.runModal", "cancel"); return NSApplication.ModalResponse.cancel.rawValue
        } as @convention(block) (NSPageLayout) -> Int)

        // System colour sampler, character palette, pop-up menus (all would start a tracking loop / system UI)
        replace(NSColorSampler.self, #selector(NSColorSampler.show(selectionHandler:)), { (_: NSColorSampler, h: @escaping @convention(block) (NSColor?) -> Void) in
            Automation.record("colorSampler", "NSColorSampler.show", "cancel")
            DispatchQueue.main.async { h(nil) }
        } as @convention(block) (NSColorSampler, @escaping @convention(block) (NSColor?) -> Void) -> Void)
        replace(NSApplication.self, #selector(NSApplication.orderFrontCharacterPalette(_:)), { (_: NSApplication, _: AnyObject?) in
            Automation.record("characterPalette", "orderFrontCharacterPalette", "skipped")
        } as @convention(block) (NSApplication, AnyObject?) -> Void)
        replace(NSMenu.self, #selector(NSMenu.popUpContextMenu(_:with:for:)), classMethod: true, { (_: AnyObject, m: NSMenu, _: NSEvent, _: NSView) in
            Automation.record("contextMenu", m.items.map(\.title).joined(separator: ","), "skipped")
            Automation.lastPopUpMenu = m
        } as @convention(block) (AnyObject, NSMenu, NSEvent, NSView) -> Void)
        replace(NSMenu.self, #selector(NSMenu.popUp(positioning:at:in:)), { (m: NSMenu, _: NSMenuItem?, _: NSPoint, _: NSView?) -> Bool in
            Automation.record("popUpMenu", m.items.map(\.title).joined(separator: ","), "skipped")
            Automation.lastPopUpMenu = m
            return false
        } as @convention(block) (NSMenu, NSMenuItem?, NSPoint, NSView?) -> Bool)

        // Pop-up buttons (SwiftUI Picker / Menu): a click must never start menu tracking.
        replace(NSPopUpButtonCell.self, #selector(NSPopUpButtonCell.trackMouse(with:in:of:untilMouseUp:)), { (c: NSPopUpButtonCell, _: NSEvent, _: NSRect, _: NSView, _: Bool) -> Bool in
            Automation.record("popUpButton", c.title, "skipped")
            return false
        } as @convention(block) (NSPopUpButtonCell, NSEvent, NSRect, NSView, Bool) -> Bool)
        replace(NSPopUpButtonCell.self, #selector(NSPopUpButtonCell.performClick(withFrame:in:)), { (c: NSPopUpButtonCell, _: NSRect, _: NSView) in
            Automation.record("popUpButton", c.title, "skipped")
        } as @convention(block) (NSPopUpButtonCell, NSRect, NSView) -> Void)
        replace(NSPopUpButtonCell.self, #selector(NSPopUpButtonCell.attachPopUp(withFrame:in:)), { (c: NSPopUpButtonCell, _: NSRect, _: NSView) in
            Automation.record("popUpButton", c.title, "skipped")
        } as @convention(block) (NSPopUpButtonCell, NSRect, NSView) -> Void)

        // Window management and dictation would be visible to the person using the machine (Dock, Spaces, microphone).
        for name in ["miniaturize:", "performMiniaturize:", "zoom:", "performZoom:", "toggleFullScreen:"] {
            replace(NSWindow.self, NSSelectorFromString(name), { (_: NSWindow, _: AnyObject?) in
                Automation.record("window", name, "skipped")
            } as @convention(block) (NSWindow, AnyObject?) -> Void)
        }
        for name in ["startDictation:", "stopDictation:", "hide:", "hideOtherApplications:", "orderFrontStandardAboutPanel:", "showHelp:"] {
            replace(NSApplication.self, NSSelectorFromString(name), { (_: NSApplication, _: AnyObject?) in
                Automation.record("application", name, "skipped")
            } as @convention(block) (NSApplication, AnyObject?) -> Void)
        }

        // Nothing may leave the process: Finder reveals, opening URLs / other apps, beeps.
        replace(NSWorkspace.self, #selector(NSWorkspace.activateFileViewerSelecting(_:)), { (_: NSWorkspace, urls: NSArray) in
            Automation.record("finder", "reveal \(urls.count) item(s)", "skipped")
        } as @convention(block) (NSWorkspace, NSArray) -> Void)
        replace(NSWorkspace.self, #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool), { (_: NSWorkspace, u: NSURL) -> Bool in
            Automation.record("openURL", u.absoluteString ?? "", "skipped"); return true
        } as @convention(block) (NSWorkspace, NSURL) -> Bool)
        replace(NSWorkspace.self, #selector(NSWorkspace.selectFile(_:inFileViewerRootedAtPath:)), { (_: NSWorkspace, _: NSString?, _: NSString) -> Bool in
            Automation.record("finder", "selectFile", "skipped"); return true
        } as @convention(block) (NSWorkspace, NSString?, NSString) -> Bool)
        // No request may leave the machine (model downloads, generative providers): fail every non-local URL load.
        URLProtocol.registerClass(HeadlessBlockedURLProtocol.self)
        for name in ["sessionWithConfiguration:", "sessionWithConfiguration:delegate:delegateQueue:"] {
            let sel = NSSelectorFromString(name)
            guard let meta = object_getClass(URLSession.self), let m = class_getInstanceMethod(meta, sel) else { continue }
            let original = method_getImplementation(m)
            func blocked(_ c: URLSessionConfiguration) -> URLSessionConfiguration {
                c.protocolClasses = [HeadlessBlockedURLProtocol.self] + (c.protocolClasses ?? []).filter { $0 != HeadlessBlockedURLProtocol.self }
                return c
            }
            if name.hasSuffix("delegateQueue:") {
                typealias F = @convention(c) (AnyObject, Selector, URLSessionConfiguration, AnyObject?, AnyObject?) -> URLSession
                let o = unsafeBitCast(original, to: F.self)
                method_setImplementation(m, imp_implementationWithBlock({ (cls: AnyObject, c: URLSessionConfiguration, d: AnyObject?, q: AnyObject?) -> URLSession in
                    o(cls, sel, blocked(c), d, q)
                } as @convention(block) (AnyObject, URLSessionConfiguration, AnyObject?, AnyObject?) -> URLSession))
            } else {
                typealias F = @convention(c) (AnyObject, Selector, URLSessionConfiguration) -> URLSession
                let o = unsafeBitCast(original, to: F.self)
                method_setImplementation(m, imp_implementationWithBlock({ (cls: AnyObject, c: URLSessionConfiguration) -> URLSession in
                    o(cls, sel, blocked(c))
                } as @convention(block) (AnyObject, URLSessionConfiguration) -> URLSession))
            }
        }

        // The user's clipboard is theirs: copy / paste go to a private pasteboard.
        let pb = NSPasteboard(name: NSPasteboard.Name("app.lumen.qa.pasteboard.\(ProcessInfo.processInfo.processIdentifier)"))
        replace(NSPasteboard.self, #selector(getter: NSPasteboard.general), classMethod: true, { (_: AnyObject) -> NSPasteboard in pb
        } as @convention(block) (AnyObject) -> NSPasteboard)
    }

    /// The last menu a tool / view tried to pop up (so the fuzz driver can walk its items).
    static var lastPopUpMenu: NSMenu?
}

/// Blocking-UI entry points. Identical to calling AppKit directly unless `Automation.isHeadless` is set, in which
/// case they return the scripted answer immediately (see `Automation`).
enum UIBlock {
    /// `alert.runModal()`.
    @discardableResult
    static func run(_ a: NSAlert) -> NSApplication.ModalResponse {
        if Automation.isHeadless { return Automation.alertResponse(a) }
        return a.runModal()
    }

    /// `alert.beginSheetModal(for:)`.
    static func beginSheet(_ a: NSAlert, for w: NSWindow, _ handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if Automation.isHeadless {
            let r = Automation.alertResponse(a)
            DispatchQueue.main.async { handler(r) }
            return
        }
        a.beginSheetModal(for: w, completionHandler: handler)
    }

    /// `panel.runModal()` for open and save panels; read `panel.url` / `panel.urls` afterwards as usual.
    static func run(_ p: NSSavePanel) -> NSApplication.ModalResponse {
        if Automation.isHeadless { Automation.installPanelURLHooks(); return Automation.panelResponse(p) }
        return p.runModal()
    }

    /// `panel.begin { response in … }`.
    static func begin(_ p: NSSavePanel, _ handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if Automation.isHeadless {
            Automation.installPanelURLHooks()
            let r = Automation.panelResponse(p)
            DispatchQueue.main.async { handler(r) }
            return
        }
        p.begin(completionHandler: handler)
    }

    /// Simple message alert.
    static func alert(_ title: String, _ info: String = "") {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        run(a)
    }

    /// OK / Cancel question.
    static func confirm(_ title: String, _ info: String, ok: String) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Cancel")
        return run(a) == .alertFirstButtonReturn
    }

    static func openPanel() -> NSOpenPanel { NSOpenPanel() }
    static func savePanel() -> NSSavePanel { NSSavePanel() }

    /// `NSPageLayout().runModal()`.
    @discardableResult
    static func runPageLayout() -> NSApplication.ModalResponse {
        if Automation.isHeadless { Automation.record("pageLayout", "Page Setup", "cancel"); return .cancel }
        return NSApplication.ModalResponse(rawValue: NSPageLayout().runModal())
    }

    /// `op.runModal(for:)` / `op.run()` of a print operation.
    static func runPrint(_ op: NSPrintOperation, window: NSWindow?) {
        if Automation.isHeadless { Automation.record("print", op.jobTitle ?? "Print", "cancel"); return }
        if let w = window {
            op.runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            op.run()
        }
    }
}


/// Fails every URL load that would leave the machine while the process runs headless (localhost stays reachable for
/// mock servers). Installed by `Automation.installHooks()`.
final class HeadlessBlockedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let u = request.url, let scheme = u.scheme?.lowercased(), ["http", "https", "ws", "wss", "ftp"].contains(scheme) else { return false }
        let host = (u.host ?? "").lowercased()
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? "?"
        DispatchQueue.main.async { Automation.record("network", host, "blocked") }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
