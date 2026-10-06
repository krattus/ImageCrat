import AppKit
import ImageCratCore

/// Print settings edited in the print panel accessory.
final class PrintSettings: NSObject {
    @objc dynamic var scaleToFit = true
    @objc dynamic var scalePercent: Double = 100
    @objc dynamic var centered = true
}

/// One-page view that draws the flattened image on the page's imageable area.
final class PrintImageView: NSView {
    let image: CGImage
    /// Physical size of the image at 100% in points (pixels / ppi × 72).
    let naturalSize: CGSize
    let settings: PrintSettings

    init(image: CGImage, resolution: Double, settings: PrintSettings, printInfo: NSPrintInfo) {
        self.image = image
        let ppi = resolution > 0 ? resolution : 72
        naturalSize = CGSize(width: Double(image.width) / ppi * 72, height: Double(image.height) / ppi * 72)
        self.settings = settings
        super.init(frame: NSRect(origin: .zero, size: printInfo.paperSize))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        if let info = NSPrintOperation.current?.printInfo, frame.size != info.paperSize { setFrameSize(info.paperSize) }
        return bounds
    }

    /// Where the image goes on a page with the given imageable rect.
    func imageRect(in area: NSRect) -> NSRect {
        var size = naturalSize
        if settings.scaleToFit {
            let s = min(area.width / max(1, size.width), area.height / max(1, size.height))
            size = CGSize(width: size.width * s, height: size.height * s)
        } else {
            let s = max(1, settings.scalePercent) / 100
            size = CGSize(width: size.width * s, height: size.height * s)
        }
        if settings.centered || settings.scaleToFit {
            return NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        }
        return NSRect(x: area.minX, y: area.maxY - size.height, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        var area = info.imageablePageBounds
        if area.isEmpty || area.width > bounds.width || area.height > bounds.height {
            area = NSRect(x: info.leftMargin, y: info.bottomMargin,
                          width: bounds.width - info.leftMargin - info.rightMargin,
                          height: bounds.height - info.topMargin - info.bottomMargin)
        }
        ctx.saveGState()
        ctx.clip(to: area)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: imageRect(in: area))
        ctx.restoreGState()
    }
}

/// Print panel accessory: Scale to Fit Media, Scale %, Center Image.
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    let settings: PrintSettings
    private var fitBox: NSButton!
    private var scaleField: NSTextField!
    private var centerBox: NSButton!

    init(settings: PrintSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = Brand.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        fitBox = NSButton(checkboxWithTitle: tr("Scale to Fit Media"), target: self, action: #selector(changed))
        fitBox.frame = NSRect(x: 20, y: 60, width: 280, height: 20)
        let l = NSTextField(labelWithString: tr("Scale:"))
        l.frame = NSRect(x: 20, y: 33, width: 50, height: 18)
        scaleField = NSTextField(string: String(format: "%g", settings.scalePercent))
        scaleField.frame = NSRect(x: 72, y: 31, width: 60, height: 22)
        scaleField.target = self; scaleField.action = #selector(changed)
        let pct = NSTextField(labelWithString: tr("%"))
        pct.frame = NSRect(x: 136, y: 33, width: 20, height: 18)
        centerBox = NSButton(checkboxWithTitle: tr("Center Image"), target: self, action: #selector(changed))
        centerBox.frame = NSRect(x: 20, y: 4, width: 280, height: 20)
        for s in [fitBox, l, scaleField, pct, centerBox] as [NSView] { v.addSubview(s) }
        view = v
        sync()
    }

    private func sync() {
        fitBox.state = settings.scaleToFit ? .on : .off
        scaleField.isEnabled = !settings.scaleToFit
        centerBox.isEnabled = !settings.scaleToFit
        centerBox.state = settings.centered ? .on : .off
    }

    @objc private func changed() {
        willChangeValue(forKey: "previewKey")
        settings.scaleToFit = fitBox.state == .on
        if let v = Double(scaleField.stringValue.replacingOccurrences(of: ",", with: ".")) { settings.scalePercent = min(1000, max(1, v)) }
        scaleField.stringValue = String(format: "%g", settings.scalePercent)
        settings.centered = centerBox.state == .on
        didChangeValue(forKey: "previewKey")
        sync()
    }

    @objc dynamic var previewKey: Int { 0 }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Scale", .itemDescription: settings.scaleToFit ? "Fit to media" : "\(Int(settings.scalePercent))%"]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["previewKey"] }
}

enum Printing {
    static let settings = PrintSettings()

    static func makeOperation(_ st: DocumentState, printInfo: NSPrintInfo = NSPrintInfo.shared) -> NSPrintOperation? {
        guard let cg = Compositor.shared.flatten(st, background: .white) else { return nil }
        let info = (printInfo.copy() as? NSPrintInfo) ?? printInfo
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        if cg.width > cg.height, info.orientation == .portrait, settings.scaleToFit { info.orientation = .landscape }
        let view = PrintImageView(image: cg, resolution: st.resolution, settings: settings, printInfo: info)
        let op = NSPrintOperation(view: view, printInfo: info)
        op.jobTitle = AppActions.doc?.name ?? Brand.name
        return op
    }

    /// File > Print… (⌘P)
    static func print() {
        guard let d = AppActions.doc, let op = makeOperation(d.state) else { Beep.play(); return }
        TimelineController.shared.stop()
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        op.printPanel.addAccessoryController(PrintAccessoryController(settings: settings))
        UIBlock.runPrint(op, window: NSApp.keyWindow ?? NSApp.mainWindow)
    }

    /// File > Print One Copy (⌥⇧⌘P): prints with the current settings, no dialog.
    static func printOneCopy() {
        guard let d = AppActions.doc, let op = makeOperation(d.state) else { Beep.play(); return }
        op.printInfo.dictionary()[NSPrintInfo.AttributeKey.copies] = 1
        op.showsPrintPanel = false
        op.showsProgressPanel = true
        UIBlock.runPrint(op, window: nil)
    }

    /// Writes what would be printed to a PDF (used by the self test).
    static func writePDF(_ st: DocumentState, to url: URL) -> Bool {
        let info = NSPrintInfo(dictionary: [NSPrintInfo.AttributeKey.jobDisposition: NSPrintInfo.JobDisposition.save,
                                            NSPrintInfo.AttributeKey.jobSavingURL: url])
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 36; info.bottomMargin = 36; info.leftMargin = 36; info.rightMargin = 36
        guard let op = makeOperation(st, printInfo: info) else { return false }
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        return op.run()
    }

    static func pageSetup() {
        UIBlock.runPageLayout()
    }
}
