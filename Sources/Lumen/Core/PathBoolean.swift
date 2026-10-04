import AppKit
import ImageCratCore

/// Live Boolean path operations. Each component combines with the components below it using its
/// operation (Photoshop semantics: combine / subtract front / intersect / exclude overlap).
enum PathBoolean {
    private static var cache: [(VectorPath, CGPath)] = []
    private static let lock = NSLock()

    /// True when the outline differs from the raw path (operations, or overlapping combined shapes).
    static func needsResolve(_ p: VectorPath) -> Bool {
        p.subpaths.contains { $0.operation != .combine } || p.subpaths.filter { $0.closed && $0.points.count > 2 }.count > 1
    }

    /// Outline with all component operations applied. Fill it with the even-odd rule when `evenOdd` is true.
    static func resolve(_ p: VectorPath) -> (path: CGPath, evenOdd: Bool) {
        guard needsResolve(p), p.subpaths.count <= 400 else { return (p.cgPath, false) }
        lock.lock()
        if let hit = cache.first(where: { $0.0 == p }) { lock.unlock(); return (hit.1, true) }
        lock.unlock()
        // Leading combined components are resolved together with the winding rule (keeps glyph holes).
        var acc: CGPath? = nil
        var pending = CGMutablePath()
        var started = false
        for s in p.subpaths where s.points.count > 1 {
            var closed = s
            closed.closed = true
            if s.operation == .combine && acc == nil {
                closed.appendTo(pending)
                started = true
                continue
            }
            if acc == nil {
                acc = started ? pending.normalized(using: .winding) : CGMutablePath()
                pending = CGMutablePath()
            }
            let comp = closed.cgPath
            let a = acc!
            switch s.operation {
            case .combine: acc = a.union(comp, using: .winding)
            case .subtract: acc = a.subtracting(comp, using: .winding)
            case .intersect: acc = a.intersection(comp, using: .winding)
            case .exclude: acc = a.symmetricDifference(comp, using: .winding)
            }
        }
        let out = acc ?? pending.normalized(using: .winding)
        lock.lock()
        cache.append((p, out))
        if cache.count > 24 { cache.removeFirst() }
        lock.unlock()
        return (out, true)
    }

    /// Bakes the operations into plain combined components ("Merge Shape Components").
    static func merged(_ p: VectorPath) -> VectorPath {
        VectorPath.from(cgPath: resolve(p).path)
    }
}

extension VectorPath {
    /// Fill-ready outline (Boolean operations applied).
    var resolved: (path: CGPath, evenOdd: Bool) { PathBoolean.resolve(self) }

    func withOperation(_ op: PathOperation) -> VectorPath {
        VectorPath(subpaths: subpaths.map { var s = $0; s.operation = op; return s })
    }
}

// MARK: - Custom shape library


