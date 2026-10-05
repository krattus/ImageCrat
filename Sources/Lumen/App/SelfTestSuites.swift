import AppKit

/// Runs one self-test suite and then releases what it left behind, so a whole `--selftest` run stays bounded:
/// the tool robots' off-screen canvases and windows (`ToolRobot.keepAlive`), snapshot windows, other off-screen windows
/// the suite opened (their hosting views and SwiftUI graphs), panel-measuring probes and the documents it opened.
/// State that existed before the suite (windows, documents, the tool hook) is left as it was. Each suite runs in its own
/// autorelease pool. After every suite a `suite-end` line reports the process footprint.
///
/// `LUMEN_SELFTEST_KEEP=1` skips the teardown (everything stays alive for the whole run, as before) to compare.
enum SelfTestSuites {
    static let keepState = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_KEEP"] == "1"
    private static var peakWindows = 0

    static func run(_ name: String, _ body: () -> Void) {
        let app = AppModel.shared
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        let docsBefore = app.documents
        let activeBefore = app.activeDocumentID
        let hookBefore = app.toolChanged
        let canvasBefore = AppActions.canvas
        let start = CFAbsoluteTimeGetCurrent()
        autoreleasepool { body() }
        let seconds = CFAbsoluteTimeGetCurrent() - start
        let liveWindows = NSApp.windows.count
        peakWindows = max(peakWindows, liveWindows)
        var released = (robots: 0, windows: 0, docs: 0)
        if !keepState {
            autoreleasepool {
                released = teardown(windowsBefore: windowsBefore, docsBefore: docsBefore, activeBefore: activeBefore,
                                    hookBefore: hookBefore, canvasBefore: canvasBefore)
            }
            // let AppKit / SwiftUI finish deferred work for the released views (display cycle, observation callbacks)
            RunLoop.current.run(until: Date())
        }
        let f = MemorySoak.footprint()
        print(String(format: "suite-end %@: %.1f s, footprint %.0f MB (peak %.0f MB), windows %d → %d, released %d robots, %d windows, %d documents",
                     name, seconds, f.current, f.peak, liveWindows, NSApp.windows.count, released.robots, released.windows, released.docs))
    }

    static func summary() {
        let f = MemorySoak.footprint()
        print(String(format: "suite-summary: footprint %.0f MB, peak %.0f MB, most windows alive at a suite end %d%@",
                     f.current, f.peak, peakWindows, keepState ? " (LUMEN_SELFTEST_KEEP: no teardown)" : ""))
    }

    private static func teardown(windowsBefore: Set<ObjectIdentifier>, docsBefore: [Document], activeBefore: UUID?,
                                 hookBefore: ((ToolKind, ToolKind) -> Void)?, canvasBefore: CanvasView?) -> (robots: Int, windows: Int, docs: Int) {
        let app = AppModel.shared
        var windows = 0

        // Other windows this suite opened go off screen, so AppKit stops holding them: the ones only the suite referenced
        // are freed with their hosting views. Their content stays (an app-owned window may be shown again later).
        // Floating panels belong to the workspace, which keeps and places them, so they are left alone.
        for w in NSApp.windows where !windowsBefore.contains(ObjectIdentifier(w)) && w.isVisible && !(w is FloatingPanel) {
            w.orderOut(nil)
            windows += 1
        }

        // Tool robots: their canvas, window and document go with the suite.
        let robots = ToolRobot.keepAlive
        for r in robots {
            r.canvas.document = nil
            release(r.window)
        }
        ToolRobot.keepAlive.removeAll()

        // Snapshot windows and panel probes kept for the length of a suite.
        for w in AssistSelfTest.snapshotWindows { release(w) }
        AssistSelfTest.snapshotWindows.removeAll()
        PanelMetrics.resetProbes()

        // Documents the suite opened (and left open) close; the ones open before stay.
        let keep = Set(docsBefore.map(\.id))
        let closed = app.documents.filter { !keep.contains($0.id) }
        if !closed.isEmpty || app.documents.count != docsBefore.count { app.documents = docsBefore }
        if app.activeDocumentID != activeBefore { app.activeDocumentID = activeBefore }
        app.toolChanged = hookBefore
        AppActions.canvas = canvasBefore

        // What closing those documents releases in the app (history snapshots, versions, renderer state), then the caches
        // a memory warning drops: the self test runs before `MemoryHygiene.install()`, so nothing else ever does. Everything
        // dropped is a cache, rebuilt on demand (an on-device model reloads when a later suite uses it).
        for d in closed { MemoryHygiene.documentClosed(d) }
        purgeCaches()
        return (robots.count, windows, closed.count)
    }

    private static func purgeCaches() {
        let open = MemoryHygiene.openIDs()
        Compositor.shared.prune(keeping: open)
        RecipeRuntime.shared.prune(keeping: open)
        CanvasRenderer.forget(nil)
        if ParticleEditor.current == nil { ParticleRenderer.releaseTargets() }
        RenderEngine.context.clearCaches()
        RenderEngine.readbackContext.clearCaches()
        MemoryHygiene.unloadModels()
    }

    /// Takes a test-owned window (a robot's or a snapshot's: no delegate) off screen, drops its content (hosting views and
    /// their SwiftUI graphs go with it) and closes it. A self test never quits when its last window closes.
    private static func release(_ w: NSWindow) {
        w.isReleasedWhenClosed = false
        if w.isVisible { w.orderOut(nil) }
        if w.contentViewController != nil { w.contentViewController = nil }
        w.contentView = nil
        w.close()   // AppKit keeps every window it has created a device for in `NSApp.windows` until it closes
    }
}
