import Foundation

// swift-corelibs-foundation (Windows, Linux) provides CGFloat, CGPoint, CGSize and CGRect but not CGAffineTransform.
// `PortableAffineTransform` is a source-compatible stand-in with the API subset the core uses (CoreGraphics
// semantics, including the Codable form). Only where CoreGraphics is missing does it become `CGAffineTransform`
// (and add `applying(_:)` to the geometry types), so on Apple platforms the real CoreGraphics type is used and Mac code
// is unchanged. The struct itself is compiled everywhere so the Mac unit tests can check it against CoreGraphics.

/// Affine transform with CoreGraphics semantics: maps (x, y) to (a·x + c·y + tx, b·x + d·y + ty).
package struct PortableAffineTransform: Equatable, Hashable, Codable {
    package var a: CGFloat
    package var b: CGFloat
    package var c: CGFloat
    package var d: CGFloat
    package var tx: CGFloat
    package var ty: CGFloat

    @inlinable package init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
    /// The identity (CoreGraphics' `CGAffineTransform()` is identity as well).
    @inlinable package init() { self.init(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }

    package static let identity = PortableAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    @inlinable package init(translationX tx: CGFloat, y ty: CGFloat) { self.init(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty) }
    @inlinable package init(scaleX sx: CGFloat, y sy: CGFloat) { self.init(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0) }
    @inlinable package init(rotationAngle angle: CGFloat) {
        let cs = CGFloat(cos(Double(angle))), sn = CGFloat(sin(Double(angle)))
        self.init(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }

    @inlinable package var isIdentity: Bool { a == 1 && b == 0 && c == 0 && d == 1 && tx == 0 && ty == 0 }

    /// `self` followed by `t` (CoreGraphics order: t1.concatenating(t2) applies t1 first).
    @inlinable package func concatenating(_ t: PortableAffineTransform) -> PortableAffineTransform {
        PortableAffineTransform(a: a * t.a + b * t.c, b: a * t.b + b * t.d,
                                c: c * t.a + d * t.c, d: c * t.b + d * t.d,
                                tx: tx * t.a + ty * t.c + t.tx, ty: tx * t.b + ty * t.d + t.ty)
    }

    /// The inverse; a non-invertible transform is returned unchanged (as CoreGraphics does).
    @inlinable package func inverted() -> PortableAffineTransform {
        let det = a * d - b * c
        if det == 0 { return self }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return PortableAffineTransform(a: ia, b: ib, c: ic, d: id, tx: -(tx * ia + ty * ic), ty: -(tx * ib + ty * id))
    }

    /// Translation applied before `self` (CoreGraphics `translatedBy`).
    @inlinable package func translatedBy(x: CGFloat, y: CGFloat) -> PortableAffineTransform {
        PortableAffineTransform(translationX: x, y: y).concatenating(self)
    }
    @inlinable package func scaledBy(x: CGFloat, y: CGFloat) -> PortableAffineTransform {
        PortableAffineTransform(scaleX: x, y: y).concatenating(self)
    }
    @inlinable package func rotated(by angle: CGFloat) -> PortableAffineTransform {
        PortableAffineTransform(rotationAngle: angle).concatenating(self)
    }

    @inlinable package func apply(to p: CGPoint) -> CGPoint {
        CGPoint(x: a * p.x + c * p.y + tx, y: b * p.x + d * p.y + ty)
    }
    @inlinable package func apply(to s: CGSize) -> CGSize {
        CGSize(width: a * s.width + c * s.height, height: b * s.width + d * s.height)
    }
    /// Bounding box of the transformed rect (CoreGraphics `CGRect.applying`); the null rect stays null.
    package func apply(to r: CGRect) -> CGRect {
        if r.isNull { return r }
        let s = r.standardized
        let pts = [CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.maxX, y: s.minY), CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX, y: s.maxY)].map { apply(to: $0) }
        var x0 = pts[0].x, y0 = pts[0].y, x1 = x0, y1 = y0
        for p in pts { x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // CoreGraphics' Codable form: an unkeyed container [a, b, c, d, tx, ty] (documents stay interchangeable).
    package init(from decoder: Decoder) throws {
        var u = try decoder.unkeyedContainer()
        a = try u.decode(CGFloat.self); b = try u.decode(CGFloat.self); c = try u.decode(CGFloat.self)
        d = try u.decode(CGFloat.self); tx = try u.decode(CGFloat.self); ty = try u.decode(CGFloat.self)
    }
    package func encode(to encoder: Encoder) throws {
        var u = encoder.unkeyedContainer()
        try u.encode(a); try u.encode(b); try u.encode(c); try u.encode(d); try u.encode(tx); try u.encode(ty)
    }
}

#if !canImport(CoreGraphics)

package typealias CGAffineTransform = PortableAffineTransform

extension CGPoint {
    @inlinable package func applying(_ t: CGAffineTransform) -> CGPoint { t.apply(to: self) }
}

extension CGSize {
    @inlinable package func applying(_ t: CGAffineTransform) -> CGSize { t.apply(to: self) }
}

extension CGRect {
    package func applying(_ t: CGAffineTransform) -> CGRect { t.apply(to: self) }
}

#endif
