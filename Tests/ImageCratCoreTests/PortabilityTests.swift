import Foundation
import XCTest
import ImageCratCore

/// The CGAffineTransform stand-in used on Windows/Linux. On the Mac it is compared with the real CoreGraphics type,
/// so the shim cannot drift from the semantics the app relies on.
final class PortabilityTests: XCTestCase {
    private typealias P = PortableAffineTransform

    private func close(_ a: CGPoint, _ b: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, file: file, line: line); XCTAssertEqual(a.y, b.y, accuracy: 1e-9, file: file, line: line)
    }

    func testPortableTransformBasics() {
        let t = P(translationX: 10, y: 5).concatenating(P(scaleX: 2, y: 3))
        XCTAssertEqual(t.apply(to: CGPoint(x: 1, y: 1)), CGPoint(x: 22, y: 18))
        close(t.inverted().apply(to: CGPoint(x: 22, y: 18)), CGPoint(x: 1, y: 1))
        XCTAssertTrue(P.identity.isIdentity && P().isIdentity)
        XCTAssertEqual(P(a: 0, b: 0, c: 0, d: 0, tx: 1, ty: 2).inverted(), P(a: 0, b: 0, c: 0, d: 0, tx: 1, ty: 2), "singular: unchanged")
        let r = P(rotationAngle: .pi / 2).apply(to: CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(r.minX, -1, accuracy: 1e-9); XCTAssertEqual(r.width, 1, accuracy: 1e-9); XCTAssertEqual(r.height, 2, accuracy: 1e-9)
        XCTAssertTrue(P(scaleX: 2, y: 2).apply(to: CGRect.null).isNull)
    }

    func testPortableTransformCodableIsUnkeyedArray() throws {
        let t = P(a: 1, b: 2, c: 3, d: 4, tx: 5, ty: 6)
        let json = try JSONEncoder().encode(t)
        XCTAssertEqual(String(decoding: json, as: UTF8.self), "[1,2,3,4,5,6]")
        XCTAssertEqual(try JSONDecoder().decode(P.self, from: json), t)
    }

    #if canImport(CoreGraphics)
    private func same(_ p: P, _ c: CGAffineTransform, file: StaticString = #filePath, line: UInt = #line) {
        for (x, y) in [(p.a, c.a), (p.b, c.b), (p.c, c.c), (p.d, c.d), (p.tx, c.tx), (p.ty, c.ty)] {
            XCTAssertEqual(x, y, accuracy: 1e-9, file: file, line: line)
        }
    }

    func testPortableTransformMatchesCoreGraphics() throws {
        let cases: [(P, CGAffineTransform)] = [
            (P(translationX: 3, y: -4), CGAffineTransform(translationX: 3, y: -4)),
            (P(scaleX: 2, y: 0.5), CGAffineTransform(scaleX: 2, y: 0.5)),
            (P(rotationAngle: 0.7), CGAffineTransform(rotationAngle: 0.7)),
            (P(a: 1.5, b: 0.2, c: -0.3, d: 0.9, tx: 12, ty: -7), CGAffineTransform(a: 1.5, b: 0.2, c: -0.3, d: 0.9, tx: 12, ty: -7)),
        ]
        for (p, c) in cases {
            same(p, c)
            same(p.inverted(), c.inverted())
            same(p.translatedBy(x: 4, y: 5), c.translatedBy(x: 4, y: 5))
            same(p.scaledBy(x: -1, y: 3), c.scaledBy(x: -1, y: 3))
            same(p.rotated(by: 0.3), c.rotated(by: 0.3))
            for (q, d) in cases { same(p.concatenating(q), c.concatenating(d)) }
            close(p.apply(to: CGPoint(x: 7, y: -2)), CGPoint(x: 7, y: -2).applying(c))
            let r = CGRect(x: -3, y: 4, width: 10, height: 6)
            let pr = p.apply(to: r), cr = r.applying(c)
            close(pr.origin, cr.origin); XCTAssertEqual(pr.width, cr.width, accuracy: 1e-9); XCTAssertEqual(pr.height, cr.height, accuracy: 1e-9)
            XCTAssertEqual(p.isIdentity, c.isIdentity)
            XCTAssertEqual(try JSONEncoder().encode(p), try JSONEncoder().encode(c), "same Codable form as CoreGraphics")
        }
        same(P.identity, .identity)
    }
    #endif
}
