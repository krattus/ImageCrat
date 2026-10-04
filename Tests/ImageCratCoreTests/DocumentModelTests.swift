import Foundation
import XCTest
import ImageCratCore

/// DocumentState / Layer round trip through the property-list coding the native document format uses
/// (`DocumentIO.saveNative` writes a binary plist of the state).
final class DocumentModelTests: XCTestCase {
    private func sampleState() -> DocumentState {
        var st = DocumentState(width: 64, height: 48, resolution: 144)
        let bg = PixelBuffer(width: 64, height: 48)
        let p = bg.data.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: bg.bytesPerRow * 48, by: 4) where i % bg.bytesPerRow < 64 * 4 { p[i] = 200; p[i + 1] = 100; p[i + 2] = 50; p[i + 3] = 255 }
        var raster = Layer.raster(name: "Background", buffer: bg)
        raster.mask = LayerMask(buffer: PixelBuffer(width: 10, height: 8, gray: 128), origin: IPoint(x: 3, y: 4), outsideValue: 0, feather: 2)
        raster.blendMode = .multiply
        raster.opacity = 0.75

        var text = TextContent(text: "Hello portable core", fontSize: 24, color: RGBA(hex: "336699")!)
        text.applyStyle(CharacterStyle(fontSize: 30, fauxBold: true), to: NSRange(location: 0, length: 5))
        var textLayer = Layer(name: "Title", content: .text(text))
        textLayer.translate(dx: 5, dy: -2)

        var shape = Layer(name: "Shape", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 4, y: 4, width: 20, height: 10), cornerRadius: 3),
                                                                      fill: .color(.red), stroke: StrokeStyle(paint: .color(.black), width: 2))))
        shape.effects.dropShadow.enabled = true
        shape.vectorMask = .ellipse(CGRect(x: 0, y: 0, width: 30, height: 30))

        let adj = Layer(name: "Levels", content: .adjustment(AdjustmentSettings(kind: .levels)))
        let group = Layer(name: "Group", content: .group(GroupContent(children: [textLayer, shape])))
        st.layers = [raster, group, adj]
        st.selection = PixelBuffer(width: 64, height: 48, gray: 255)
        st.guides = [Guide(isVertical: true, position: 12)]
        st.paths = [NamedPath(name: "Path 1", path: .rect(CGRect(x: 1, y: 2, width: 3, height: 4)))]
        st.frames = [AnimationFrame(delay: 0.5)]
        return st
    }

    func testDocumentStatePlistRoundTrip() throws {
        let st = sampleState()
        let enc = PropertyListEncoder()
        enc.outputFormat = .binary
        let data = try enc.encode(st)
        let back = try PropertyListDecoder().decode(DocumentState.self, from: data)

        XCTAssertEqual(back.width, 64); XCTAssertEqual(back.height, 48); XCTAssertEqual(back.resolution, 144)
        XCTAssertEqual(back.profileName, "kCGColorSpaceSRGB")
        XCTAssertEqual(back.layers.map(\.name), ["Background", "Group", "Levels"])
        XCTAssertEqual(back.layers.map(\.id), st.layers.map(\.id))
        XCTAssertEqual(back.allLayers.count, 5)

        let r = try XCTUnwrap(back.layers[0].raster)
        XCTAssertEqual(back.layers[0].blendMode, .multiply)
        XCTAssertEqual(back.layers[0].opacity, 0.75)
        XCTAssertTrue(r.buffer.pixel(10, 10) == (200, 100, 50, 255))
        let m = try XCTUnwrap(back.layers[0].mask)
        XCTAssertEqual(m.origin, IPoint(x: 3, y: 4)); XCTAssertEqual(m.outsideValue, 0); XCTAssertEqual(m.feather, 2)
        XCTAssertEqual(m.buffer.alpha(5, 5), 128)

        XCTAssertTrue(back.layers[1].isGroup)
        XCTAssertEqual(back.layers[1].blendMode, .passThrough, "groups default to pass through")
        let t = try XCTUnwrap(back.layers[1].children[0].text)
        XCTAssertEqual(t.text, "Hello portable core")
        XCTAssertEqual(t.runs.count, 1)
        XCTAssertEqual(t.style(at: 2).fontSize, 30)
        XCTAssertEqual(t.transform.tx, 5); XCTAssertEqual(t.transform.ty, -2)

        let s = try XCTUnwrap(back.layers[1].children[1].shape)
        XCTAssertEqual(s, st.layers[1].children[1].shape)
        XCTAssertTrue(back.layers[1].children[1].effects.dropShadow.enabled)
        XCTAssertEqual(back.layers[1].children[1].vectorMask, st.layers[1].children[1].vectorMask)
        XCTAssertEqual(back.layers[2].adjustment?.kind, .levels)

        XCTAssertEqual(back.selection?.alpha(63, 47), 255)
        XCTAssertEqual(back.guides, st.guides)
        XCTAssertEqual(back.paths, st.paths)
        XCTAssertEqual(back.frames, st.frames)
    }

    func testLayerTreeEditing() {
        var st = sampleState()
        let textID = st.layers[1].children[0].id
        XCTAssertEqual(st.parentID(of: textID), st.layers[1].id)
        XCTAssertEqual(st.siblings(of: textID).count, 2)
        st.updateLayer(textID) { $0.name = "Renamed" }
        XCTAssertEqual(st.layer(textID)?.name, "Renamed")
        let dup = st.layers[0].duplicated(newName: "Copy")
        XCTAssertNotEqual(dup.id, st.layers[0].id)
        XCTAssertFalse(dup.raster!.buffer === st.layers[0].raster!.buffer, "duplicates clone their pixels")
        st.insertLayer(dup, above: st.layers[0].id)
        XCTAssertEqual(st.layers.map(\.name), ["Background", "Copy", "Group", "Levels"])
        XCTAssertEqual(st.removeLayer(textID)?.name, "Renamed")
        XCTAssertNil(st.layer(textID))
        XCTAssertEqual(st.allLayers.count, 5)
    }

    func testGeometryValueTypes() {
        let a = IRect(x: 0, y: 0, width: 10, height: 10), b = IRect(x: 5, y: 5, width: 10, height: 10)
        XCTAssertEqual(a.intersection(b), IRect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertEqual(a.union(b), IRect(x: 0, y: 0, width: 15, height: 15))
        XCTAssertEqual(IRect(enclosing: CGRect(x: 0.5, y: -0.5, width: 2, height: 1)), IRect(x: 0, y: -1, width: 3, height: 2))
        XCTAssertEqual(IRect(enclosing: CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)), .zero)
        let q = Quad(rect: CGRect(x: 0, y: 0, width: 100, height: 50))
        let to = Quad(tl: CGPoint(x: 10, y: 10), tr: CGPoint(x: 120, y: 0), br: CGPoint(x: 110, y: 70), bl: CGPoint(x: 0, y: 60))
        let h = Homography(from: q, to: to)!
        for p in q.points + [CGPoint(x: 25, y: 30)] {
            let back = h.inverted!.apply(h.apply(p))
            XCTAssertEqual(back.x, p.x, accuracy: 1e-6); XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
        }
        let t = CGAffineTransform(translationX: 3, y: 4).concatenating(CGAffineTransform(scaleX: 2, y: 2))
        XCTAssertEqual(CGPoint(x: 1, y: 1).applying(t), CGPoint(x: 8, y: 10))
        XCTAssertEqual(Homography(affine: t).apply(CGPoint(x: 1, y: 1)), CGPoint(x: 8, y: 10))
        XCTAssertEqual(clamp(Double.nan, 0, 1), 0)
    }

    func testVectorPathBuilderMatchesShapeLibrary() {
        var b = VectorPathBuilder()
        b.move(to: CGPoint(x: 0, y: 0))
        b.addLine(to: CGPoint(x: 1, y: 0))
        b.addCurve(to: CGPoint(x: 0, y: 0), control1: CGPoint(x: 1, y: 1), control2: CGPoint(x: 0, y: 1))
        b.closeSubpath()
        let p = b.path
        XCTAssertEqual(p.subpaths.count, 1)
        XCTAssertTrue(p.subpaths[0].closed)
        XCTAssertEqual(p.subpaths[0].points.count, 2, "a closing point on the start anchor merges into it")
        XCTAssertEqual(p.subpaths[0].points[0].inControl, CGPoint(x: 0, y: 1))
        XCTAssertEqual(ShapeLibrary.all.count, Set(ShapeLibrary.all.map(\.id)).count)
        let heart = ShapeLibrary.shape("heart")!.path(in: CGRect(x: 10, y: 10, width: 100, height: 100))
        XCTAssertFalse(heart.isEmpty)
        XCTAssertTrue(heart.subpaths.allSatisfy(\.closed))
    }
}
