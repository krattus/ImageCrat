import AppKit
import ImageCratCore

/// "Ask each time" for filters / adjustments opened while a layer mask is selected (MaskTargetPrompt).
///
///     LUMEN_SELFTEST_ONLY=masktarget .build/debug/Lumen --selftest <dir>
enum MaskTargetSelfTest {
    static func register() { FeatureModules.selfTests.append(("masktarget", { _ in run() })) }

    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") masktarget: \(name)\(d.isEmpty ? "" : " — " + d)")
    }

    static func run() {
        failures = 0; passes = 0
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, dialog: app.dialog, answer: MaskTargetPrompt.testAnswer)
        defer {
            MaskTargetPrompt.testAnswer = saved.answer
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active; app.dialog = saved.dialog
        }
        app.dialog = nil
        func masked() -> Document {
            var st = SelfTest.baseState(120, 80)
            st.layers[0].mask = LayerMask(buffer: PixelBuffer(width: 120, height: 80, format: .gray), origin: IPoint(x: 0, y: 0))
            let d = Document(state: st, name: "mask target")
            app.documents = [d]; app.activeDocumentID = d.id
            d.activeLayerID = d.state.layers[0].id
            d.editTarget = .mask
            return d
        }

        // answer "Image": the target switches to the picture, the dialog opens
        var d = masked()
        MaskTargetPrompt.testAnswer = .image
        app.dialog = .adjustment(.levels)
        check(d.editTarget == .content && app.dialog?.id == ActiveDialog.adjustment(.levels).id, "adjustment, answer Image: edits the picture, dialog opens")
        app.dialog = nil

        // answer "Layer Mask": stays on the mask
        d = masked()
        MaskTargetPrompt.testAnswer = .mask
        app.dialog = .adjustment(.curves)
        check(d.editTarget == .mask && app.dialog != nil, "adjustment, answer Layer Mask: keeps editing the mask")
        app.dialog = nil

        // filters ask through FilterLauncher
        d = masked()
        MaskTargetPrompt.testAnswer = .image
        FilterLauncher.launch(.gaussianBlur)
        check(d.editTarget == .content, "Filter ▸ Gaussian Blur, answer Image: edits the picture")
        app.dialog = nil

        // no question without a selected mask
        d = masked(); d.editTarget = .content
        MaskTargetPrompt.testAnswer = .mask
        app.dialog = .adjustment(.levels)
        check(d.editTarget == .content && app.dialog != nil, "picture selected: no question, nothing changes")
        app.dialog = nil

        print("masktarget: \(passes) passed, \(failures) failed")
    }
}
