import XCTest
@testable import ImageCratCore

final class BrushLibraryIndexTests: XCTestCase {
    func rec(_ id: String, _ name: String) -> BrushRecord { BrushRecord(id: id, name: name, tipID: "round", params: BrushParams(size: 10)) }

    func sample() -> (BrushLibraryIndex, String, String, String) {
        var ix = BrushLibraryIndex()
        let general = ix.createFolder("General")
        let dry = ix.createFolder("Dry Media")
        let pencils = ix.createFolder("Pencils", in: dry)
        ix.add(rec("a", "Hard Round"), to: general)
        ix.add(rec("b", "Soft Round"), to: general)
        ix.add(rec("c", "Charcoal Stick"), to: dry)
        ix.add(rec("d", "HB Pencil"), to: pencils)
        ix.add(rec("e", "Smudgy Pastel"), to: dry)
        return (ix, general, dry, pencils)
    }

    func testFoldersOrderAndPaths() {
        let (ix, _, dry, pencils) = sample()
        XCTAssertEqual(ix.orderedBrushIDs, ["a", "b", "d", "c", "e"])
        XCTAssertEqual(ix.path(ofFolder: pencils), ["Dry Media", "Pencils"])
        XCTAssertEqual(ix.brushIDs(inFolder: dry), ["d", "c", "e"])
        XCTAssertEqual(ix.brushIDs(inFolder: dry, recursive: false), ["c", "e"])
        XCTAssertEqual(ix.folderID(ofBrush: "d"), pencils)
        XCTAssertEqual(ix.allFolders.map(\.path), [["General"], ["Dry Media"], ["Dry Media", "Pencils"]])
    }

    func testMoveBrushesAndFolders() {
        var (ix, general, dry, pencils) = sample()
        XCTAssertTrue(ix.moveBrushes(["e"], to: general, at: 1))
        XCTAssertEqual(ix.brushIDs(inFolder: general), ["a", "e", "b"])
        // reorder inside a folder: moving "a" below "b"
        XCTAssertTrue(ix.moveBrushes(["a"], to: general, at: 3))
        XCTAssertEqual(ix.brushIDs(inFolder: general), ["e", "b", "a"])
        // a folder can't go into itself or its own child
        XCTAssertFalse(ix.moveFolder(dry, to: pencils))
        XCTAssertFalse(ix.moveFolder(dry, to: dry))
        XCTAssertTrue(ix.moveFolder(pencils, to: general, at: 0))
        XCTAssertEqual(ix.path(ofFolder: pencils), ["General", "Pencils"])
        XCTAssertEqual(ix.brushIDs(inFolder: dry), ["c"])
    }

    func testRenameDuplicateDelete() {
        var (ix, general, dry, _) = sample()
        ix.rename("a", to: "  Hard Round Pressure ")
        XCTAssertEqual(ix.brushes["a"]?.name, "Hard Round Pressure")
        ix.rename("a", to: "   ")
        XCTAssertEqual(ix.brushes["a"]?.name, "Hard Round Pressure")
        let copy = ix.duplicate("a", newID: "a2")
        XCTAssertEqual(copy, "a2")
        XCTAssertEqual(ix.brushes["a2"]?.name, "Hard Round Pressure copy")
        XCTAssertEqual(ix.brushIDs(inFolder: general), ["a", "a2", "b"])
        _ = ix.duplicate("a", newID: "a3")
        XCTAssertEqual(ix.brushes["a3"]?.name, "Hard Round Pressure copy 2")
        ix.setFavorite("c", true)
        ix.noteUsed("c")
        let removed = ix.deleteFolder(dry)
        XCTAssertEqual(Set(removed), ["c", "d", "e"])
        XCTAssertNil(ix.brushes["c"])
        XCTAssertTrue(ix.favorites.isEmpty)
        XCTAssertTrue(ix.recent.isEmpty)
        XCTAssertNil(ix.folder(dry))
    }

    func testFavoritesRecentSearch() {
        var (ix, general, dry, _) = sample()
        ix.setFavorite("b", true); ix.setFavorite("d", true); ix.setFavorite("b", true)
        XCTAssertEqual(ix.favorites, ["d", "b"])
        ix.setFavorite("d", false)
        XCTAssertEqual(ix.favorites, ["b"])
        for id in ["a", "b", "c", "d", "e", "a"] { ix.noteUsed(id) }
        XCTAssertEqual(ix.recent, ["a", "e", "d", "c", "b"])
        for i in 0..<20 { ix.add(rec("x\(i)", "X \(i)"), to: general); ix.noteUsed("x\(i)") }
        XCTAssertEqual(ix.recent.count, 10)
        XCTAssertEqual(ix.recent.first, "x19")
        XCTAssertEqual(ix.search("round"), ["a", "b"])
        XCTAssertEqual(ix.search("ROUND soft"), ["b"])
        XCTAssertEqual(ix.search("pencil"), ["d"])
        XCTAssertEqual(ix.search("dry"), ["d", "c", "e"])        // folder names match too
        XCTAssertEqual(ix.search("", inFolder: dry), ["d", "c", "e"])
        XCTAssertEqual(ix.search("pastel", inFolder: general), [])
    }

    func testPersistenceAndRepair() throws {
        var (ix, general, _, _) = sample()
        ix.setFavorite("a", true)
        ix.noteUsed("b")
        ix.tips["t1"] = BrushTipRecord(id: "t1", files: ["t1.png"])
        let data = try ix.encoded()
        let back = try BrushLibraryIndex.decode(data)
        XCTAssertEqual(back, ix)
        // Damaged JSON: a broken record is dropped, unknown ids are cleaned, records outside the tree are re-attached.
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var brushes = try XCTUnwrap(obj["brushes"] as? [String: Any])
        brushes["b"] = ["name": 5]                // no id → dropped
        brushes["z"] = ["id": "z", "name": "Loose"]
        obj["brushes"] = brushes
        obj["favorites"] = ["a", "nope"]
        let damaged = try JSONSerialization.data(withJSONObject: obj)
        let fixed = try BrushLibraryIndex.decode(damaged)
        XCTAssertNil(fixed.brushes["b"])
        XCTAssertEqual(fixed.favorites, ["a"])
        XCTAssertTrue(fixed.recent.isEmpty)
        XCTAssertEqual(fixed.root.brushes, ["z"])
        XCTAssertFalse(fixed.brushIDs(inFolder: general).contains("b"))
        XCTAssertEqual(fixed.unreferencedTips, ["t1"])
        // Unknown future keys and a missing params block are tolerated.
        let minimal = #"{"version": 9, "brushes": {"q": {"id": "q", "params": {"size": 77, "fancyNewThing": true}}}}"#
        let m = try BrushLibraryIndex.decode(Data(minimal.utf8))
        XCTAssertEqual(m.brushes["q"]?.params.size, 77)
        XCTAssertEqual(m.root.brushes, ["q"])
    }

    func testParamsSanitize() {
        var p = BrushParams()
        p.size = .nan; p.spacing = -3; p.count = 99; p.sizeControl.fadeSteps = .infinity; p.purity = 4
        p.sanitize()
        XCTAssertEqual(p.size, 30); XCTAssertEqual(p.spacing, 0.01); XCTAssertEqual(p.count, 16); XCTAssertEqual(p.sizeControl.fadeSteps, 25); XCTAssertEqual(p.purity, 1)
    }
}
