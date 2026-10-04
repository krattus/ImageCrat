import Foundation

// MARK: - Custom shape library

package struct LibraryShape: Identifiable {
    package let id: String
    package let name: String
    package let category: String
    /// Builds the shape in the unit square (0...1, y-down).
    package let build: () -> VectorPath

    package func path(in r: CGRect) -> VectorPath {
        build().applying(CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: r.width, y: r.height))
    }
    package init(id: String, name: String, category: String, build: @escaping () -> VectorPath) {
        self.id = id; self.name = name; self.category = category; self.build = build
    }
}
package enum ShapeLibrary {
    package static func shape(_ id: String) -> LibraryShape? { all.first { $0.id == id } }
    package static var categories: [String] { var seen: [String] = []; for s in all where !seen.contains(s.category) { seen.append(s.category) }; return seen }

    private static func poly(_ pts: [(CGFloat, CGFloat)]) -> VectorPath {
        VectorPath(subpaths: [Subpath(points: pts.map { PathPoint(CGPoint(x: $0.0, y: $0.1)) }, closed: true)])
    }

    /// Path built with CGMutablePath-style calls (same result as building a CGPath and converting it).
    private static func cg(_ build: (inout VectorPathBuilder) -> Void) -> VectorPath {
        var p = VectorPathBuilder()
        build(&p)
        return p.path
    }

    private static func withOps(_ parts: [(VectorPath, PathOperation)]) -> VectorPath {
        VectorPath(subpaths: parts.flatMap { part in part.0.subpaths.map { var s = $0; s.operation = part.1; return s } })
    }

    package static let all: [LibraryShape] = [
        LibraryShape(id: "heart", name: "Heart", category: "Symbols") {
            cg { p in
                p.move(to: CGPoint(x: 0.5, y: 0.95))
                p.addCurve(to: CGPoint(x: 0.02, y: 0.32), control1: CGPoint(x: 0.3, y: 0.78), control2: CGPoint(x: 0.02, y: 0.58))
                p.addCurve(to: CGPoint(x: 0.5, y: 0.2), control1: CGPoint(x: 0.02, y: 0.02), control2: CGPoint(x: 0.42, y: 0.0))
                p.addCurve(to: CGPoint(x: 0.98, y: 0.32), control1: CGPoint(x: 0.58, y: 0.0), control2: CGPoint(x: 0.98, y: 0.02))
                p.addCurve(to: CGPoint(x: 0.5, y: 0.95), control1: CGPoint(x: 0.98, y: 0.58), control2: CGPoint(x: 0.7, y: 0.78))
                p.closeSubpath()
            }
        },
        LibraryShape(id: "star5", name: "Star", category: "Symbols") { .polygon(in: CGRect(x: 0, y: 0, width: 1, height: 1), sides: 5, starRatio: 0.45) },
        LibraryShape(id: "burst", name: "Burst", category: "Symbols") { .polygon(in: CGRect(x: 0, y: 0, width: 1, height: 1), sides: 16, starRatio: 0.75) },
        LibraryShape(id: "check", name: "Checkmark", category: "Symbols") {
            poly([(0.05, 0.55), (0.18, 0.42), (0.38, 0.62), (0.82, 0.12), (0.95, 0.25), (0.38, 0.88)])
        },
        LibraryShape(id: "cross", name: "Cross", category: "Symbols") {
            poly([(0.35, 0), (0.65, 0), (0.65, 0.35), (1, 0.35), (1, 0.65), (0.65, 0.65), (0.65, 1), (0.35, 1), (0.35, 0.65), (0, 0.65), (0, 0.35), (0.35, 0.35)])
        },
        LibraryShape(id: "xmark", name: "X Mark", category: "Symbols") {
            poly([(0.15, 0), (0.5, 0.35), (0.85, 0), (1, 0.15), (0.65, 0.5), (1, 0.85), (0.85, 1), (0.5, 0.65), (0.15, 1), (0, 0.85), (0.35, 0.5), (0, 0.15)])
        },
        LibraryShape(id: "ring", name: "Ring", category: "Symbols") {
            withOps([(.ellipse(CGRect(x: 0, y: 0, width: 1, height: 1)), .combine), (.ellipse(CGRect(x: 0.22, y: 0.22, width: 0.56, height: 0.56)), .subtract)])
        },
        LibraryShape(id: "target", name: "Target", category: "Symbols") {
            withOps([(.ellipse(CGRect(x: 0, y: 0, width: 1, height: 1)), .combine), (.ellipse(CGRect(x: 0.15, y: 0.15, width: 0.7, height: 0.7)), .subtract),
                     (.ellipse(CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)), .combine)])
        },
        LibraryShape(id: "arrowR", name: "Arrow Right", category: "Arrows") {
            poly([(0, 0.35), (0.55, 0.35), (0.55, 0.1), (1, 0.5), (0.55, 0.9), (0.55, 0.65), (0, 0.65)])
        },
        LibraryShape(id: "arrowL", name: "Arrow Left", category: "Arrows") {
            poly([(1, 0.35), (0.45, 0.35), (0.45, 0.1), (0, 0.5), (0.45, 0.9), (0.45, 0.65), (1, 0.65)])
        },
        LibraryShape(id: "arrowU", name: "Arrow Up", category: "Arrows") {
            poly([(0.35, 1), (0.35, 0.45), (0.1, 0.45), (0.5, 0), (0.9, 0.45), (0.65, 0.45), (0.65, 1)])
        },
        LibraryShape(id: "arrowDouble", name: "Double Arrow", category: "Arrows") {
            poly([(0, 0.5), (0.3, 0.1), (0.3, 0.35), (0.7, 0.35), (0.7, 0.1), (1, 0.5), (0.7, 0.9), (0.7, 0.65), (0.3, 0.65), (0.3, 0.9)])
        },
        LibraryShape(id: "chevron", name: "Chevron", category: "Arrows") {
            poly([(0, 0), (0.55, 0), (1, 0.5), (0.55, 1), (0, 1), (0.45, 0.5)])
        },
        LibraryShape(id: "curvedArrow", name: "Curved Arrow", category: "Arrows") {
            cg { p in
                p.move(to: CGPoint(x: 0.05, y: 1))
                p.addCurve(to: CGPoint(x: 0.65, y: 0.25), control1: CGPoint(x: 0.05, y: 0.5), control2: CGPoint(x: 0.3, y: 0.25))
                p.addLine(to: CGPoint(x: 0.65, y: 0))
                p.addLine(to: CGPoint(x: 1, y: 0.4))
                p.addLine(to: CGPoint(x: 0.65, y: 0.8))
                p.addLine(to: CGPoint(x: 0.65, y: 0.55))
                p.addCurve(to: CGPoint(x: 0.3, y: 1), control1: CGPoint(x: 0.45, y: 0.55), control2: CGPoint(x: 0.3, y: 0.7))
                p.closeSubpath()
            }
        },
        LibraryShape(id: "bubble", name: "Speech Bubble", category: "Banners") {
            withOps([(.rect(CGRect(x: 0, y: 0, width: 1, height: 0.72), radius: 0.12), .combine), (poly([(0.2, 0.6), (0.45, 0.6), (0.15, 1)]), .combine)])
        },
        LibraryShape(id: "thought", name: "Thought Bubble", category: "Banners") {
            withOps([(.ellipse(CGRect(x: 0, y: 0, width: 1, height: 0.7)), .combine), (.ellipse(CGRect(x: 0.12, y: 0.74, width: 0.14, height: 0.12)), .combine),
                     (.ellipse(CGRect(x: 0.03, y: 0.9, width: 0.08, height: 0.08)), .combine)])
        },
        LibraryShape(id: "ribbon", name: "Ribbon", category: "Banners") {
            poly([(0, 0.2), (0.15, 0.2), (0.15, 0.05), (0.85, 0.05), (0.85, 0.2), (1, 0.2), (0.92, 0.45), (1, 0.7), (0.85, 0.7), (0.85, 0.55), (0.15, 0.55), (0.15, 0.7), (0, 0.7), (0.08, 0.45)])
        },
        LibraryShape(id: "tag", name: "Tag", category: "Banners") {
            withOps([(poly([(0.3, 0), (1, 0), (1, 1), (0.3, 1), (0, 0.5)]), .combine), (.ellipse(CGRect(x: 0.2, y: 0.42, width: 0.12, height: 0.16)), .subtract)])
        },
        LibraryShape(id: "seal", name: "Seal", category: "Banners") { .polygon(in: CGRect(x: 0, y: 0, width: 1, height: 1), sides: 24, starRatio: 0.88) },
        LibraryShape(id: "raindrop", name: "Raindrop", category: "Nature") {
            cg { p in
                p.move(to: CGPoint(x: 0.5, y: 0))
                p.addCurve(to: CGPoint(x: 0.9, y: 0.65), control1: CGPoint(x: 0.6, y: 0.2), control2: CGPoint(x: 0.9, y: 0.4))
                p.addCurve(to: CGPoint(x: 0.1, y: 0.65), control1: CGPoint(x: 0.9, y: 1.12), control2: CGPoint(x: 0.1, y: 1.12))
                p.addCurve(to: CGPoint(x: 0.5, y: 0), control1: CGPoint(x: 0.1, y: 0.4), control2: CGPoint(x: 0.4, y: 0.2))
                p.closeSubpath()
            }
        },
        LibraryShape(id: "leaf", name: "Leaf", category: "Nature") {
            cg { p in
                p.move(to: CGPoint(x: 0.05, y: 0.95))
                p.addCurve(to: CGPoint(x: 0.95, y: 0.05), control1: CGPoint(x: 0.0, y: 0.3), control2: CGPoint(x: 0.4, y: 0.05))
                p.addCurve(to: CGPoint(x: 0.05, y: 0.95), control1: CGPoint(x: 0.95, y: 0.6), control2: CGPoint(x: 0.7, y: 1.0))
                p.closeSubpath()
            }
        },
        LibraryShape(id: "moon", name: "Crescent", category: "Nature") {
            withOps([(.ellipse(CGRect(x: 0, y: 0, width: 1, height: 1)), .combine), (.ellipse(CGRect(x: 0.28, y: -0.05, width: 0.9, height: 0.9)), .subtract)])
        },
        LibraryShape(id: "sun", name: "Sun", category: "Nature") {
            withOps([(.polygon(in: CGRect(x: 0, y: 0, width: 1, height: 1), sides: 12, starRatio: 0.62), .combine), (.ellipse(CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)), .exclude)])
        },
        LibraryShape(id: "cloud", name: "Cloud", category: "Nature") {
            withOps([(.ellipse(CGRect(x: 0, y: 0.4, width: 0.4, height: 0.45)), .combine), (.ellipse(CGRect(x: 0.2, y: 0.1, width: 0.5, height: 0.6)), .combine),
                     (.ellipse(CGRect(x: 0.55, y: 0.3, width: 0.45, height: 0.5)), .combine), (.rect(CGRect(x: 0.2, y: 0.55, width: 0.6, height: 0.3)), .combine)])
        },
        LibraryShape(id: "lightning", name: "Lightning", category: "Nature") {
            poly([(0.55, 0), (0.15, 0.55), (0.45, 0.55), (0.35, 1), (0.85, 0.4), (0.55, 0.4), (0.7, 0)])
        },
        LibraryShape(id: "hexFrame", name: "Hexagon Frame", category: "Frames") {
            withOps([(.polygon(in: CGRect(x: 0, y: 0, width: 1, height: 1), sides: 6, starRatio: 1), .combine),
                     (.polygon(in: CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.76), sides: 6, starRatio: 1), .subtract)])
        },
        LibraryShape(id: "squareFrame", name: "Square Frame", category: "Frames") {
            withOps([(.rect(CGRect(x: 0, y: 0, width: 1, height: 1), radius: 0.08), .combine), (.rect(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), radius: 0.04), .subtract)])
        },
        LibraryShape(id: "puzzle", name: "Puzzle Piece", category: "Objects") {
            withOps([(.rect(CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.7)), .combine), (.ellipse(CGRect(x: 0.33, y: 0.02, width: 0.24, height: 0.24)), .combine),
                     (.ellipse(CGRect(x: 0.68, y: 0.43, width: 0.24, height: 0.24)), .combine), (.ellipse(CGRect(x: 0.0, y: 0.43, width: 0.22, height: 0.24)), .subtract)])
        },
        LibraryShape(id: "key", name: "Key", category: "Objects") {
            withOps([(.ellipse(CGRect(x: 0, y: 0.25, width: 0.45, height: 0.5)), .combine), (.ellipse(CGRect(x: 0.12, y: 0.4, width: 0.18, height: 0.2)), .subtract),
                     (poly([(0.4, 0.44), (1, 0.44), (1, 0.66), (0.9, 0.66), (0.9, 0.56), (0.8, 0.56), (0.8, 0.66), (0.7, 0.66), (0.7, 0.56), (0.4, 0.56)]), .combine)])
        },
        LibraryShape(id: "house", name: "House", category: "Objects") {
            withOps([(poly([(0.5, 0), (1, 0.45), (0.88, 0.45), (0.88, 1), (0.12, 1), (0.12, 0.45), (0, 0.45)]), .combine),
                     (.rect(CGRect(x: 0.4, y: 0.62, width: 0.2, height: 0.38)), .subtract)])
        },
        LibraryShape(id: "pin", name: "Map Pin", category: "Objects") {
            withOps([(cg { p in
                p.move(to: CGPoint(x: 0.5, y: 1))
                p.addCurve(to: CGPoint(x: 0.1, y: 0.38), control1: CGPoint(x: 0.35, y: 0.75), control2: CGPoint(x: 0.1, y: 0.6))
                p.addCurve(to: CGPoint(x: 0.9, y: 0.38), control1: CGPoint(x: 0.1, y: -0.1), control2: CGPoint(x: 0.9, y: -0.1))
                p.addCurve(to: CGPoint(x: 0.5, y: 1), control1: CGPoint(x: 0.9, y: 0.6), control2: CGPoint(x: 0.65, y: 0.75))
                p.closeSubpath()
            }, .combine), (.ellipse(CGRect(x: 0.35, y: 0.24, width: 0.3, height: 0.3)), .subtract)])
        },
    ]
}
