import AppKit
import ImageCratCore

/// Window ▸ Arrange ▸ Match Zoom / Location / Rotation / All: applies the active document's view state to every
/// other open document. Location matches the relative position shown at the centre of the view.
enum WindowSync {
    static func match(zoom: Bool = false, location: Bool = false, rotation: Bool = false) {
        let app = AppModel.shared
        guard let src = app.activeDocument else { return }
        let size = AppActions.canvas?.bounds.size ?? CGSize(width: 1200, height: 800)
        match(from: src, to: app.documents.filter { $0 !== src }, viewSize: size, zoom: zoom, location: location, rotation: rotation)
        AppActions.canvas?.setNeedsRender()
    }

    static func docToView(_ d: Document) -> CGAffineTransform {
        let r = CGFloat(d.viewRotation), z = CGFloat(d.zoom)
        return CGAffineTransform(a: cos(r) * z, b: sin(r) * z, c: -sin(r) * z, d: cos(r) * z, tx: d.viewOffset.x, ty: d.viewOffset.y)
    }

    static func match(from src: Document, to targets: [Document], viewSize: CGSize, zoom: Bool, location: Bool, rotation: Bool) {
        let vc = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let srcCenter = vc.applying(docToView(src).inverted())
        let f = CGPoint(x: srcCenter.x / CGFloat(max(1, src.state.width)), y: srcCenter.y / CGFloat(max(1, src.state.height)))
        for t in targets {
            // keep the target's current centre unless the location is matched
            let keep = vc.applying(docToView(t).inverted())
            if zoom { t.zoom = src.zoom }
            if rotation { t.viewRotation = src.viewRotation }
            let centre = location ? CGPoint(x: f.x * CGFloat(t.state.width), y: f.y * CGFloat(t.state.height)) : keep
            let r = CGFloat(t.viewRotation), z = CGFloat(t.zoom)
            let lin = CGPoint(x: (centre.x * cos(r) - centre.y * sin(r)) * z, y: (centre.x * sin(r) + centre.y * cos(r)) * z)
            t.viewOffset = vc - lin
            t.needsFitOnScreen = false
        }
    }
}
