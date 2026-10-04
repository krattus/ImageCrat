import AppKit

/// In-process view of the app's accessibility tree. Nothing here posts events or needs system permissions: the fuzz
/// driver asks the views of its own process for their accessibility elements and performs their actions directly.
enum FuzzAX {
    struct Node {
        let element: NSObject
        let role: String
        let label: String
        let depth: Int
        var id: ObjectIdentifier { ObjectIdentifier(element) }
    }

    private static var enabled = false
    /// SwiftUI only builds its accessibility tree once an assistive client announced itself.
    static func enable() {
        guard !enabled else { return }
        enabled = true
        let sel = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        guard NSApp.responds(to: sel) else { return }
        for attr in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = NSApp.perform(sel, with: NSNumber(value: true), with: attr as NSString)
        }
    }

    private static func object(_ o: NSObject, _ name: String) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel)?.takeUnretainedValue()
    }

    private static func legacy(_ o: NSObject, _ attribute: String) -> AnyObject? {
        let sel = NSSelectorFromString("accessibilityAttributeValue:")
        guard o.responds(to: sel) else { return nil }
        return o.perform(sel, with: attribute as NSString)?.takeUnretainedValue()
    }

    static func role(_ o: NSObject) -> String {
        if let r = object(o, "accessibilityRole") as? String { return r }
        return (legacy(o, "AXRole") as? String) ?? "?"
    }

    static func subrole(_ o: NSObject) -> String {
        (object(o, "accessibilitySubrole") as? String) ?? (legacy(o, "AXSubrole") as? String) ?? ""
    }

    static func label(_ o: NSObject) -> String {
        for k in ["accessibilityLabel", "accessibilityTitle"] {
            if let s = object(o, k) as? String, !s.isEmpty { return s }
        }
        for k in ["AXDescription", "AXTitle"] {
            if let s = legacy(o, k) as? String, !s.isEmpty { return s }
        }
        if let s = object(o, "accessibilityValue") as? String, !s.isEmpty { return s }
        if let s = legacy(o, "AXValue") as? String, !s.isEmpty { return s }
        return ""
    }

    static func identifier(_ o: NSObject) -> String {
        (object(o, "accessibilityIdentifier") as? String) ?? (legacy(o, "AXIdentifier") as? String) ?? ""
    }

    static func value(_ o: NSObject) -> AnyObject? {
        object(o, "accessibilityValue") ?? legacy(o, "AXValue")
    }

    static func children(_ o: NSObject) -> [NSObject] {
        if let c = object(o, "accessibilityChildren") as? [NSObject], !c.isEmpty { return c }
        return (legacy(o, "AXChildren") as? [NSObject]) ?? []
    }

    /// Screen-space frame.
    static func frame(_ o: NSObject) -> NSRect? {
        if o.responds(to: NSSelectorFromString("accessibilityFrame")), let v = o.value(forKey: "accessibilityFrame") as? NSValue {
            let r = v.rectValue
            if r.width > 0 && r.height > 0 { return r }
        }
        if let p = legacy(o, "AXPosition") as? NSValue, let s = legacy(o, "AXSize") as? NSValue {
            // legacy position is top-left in flipped screen space
            let size = s.sizeValue, pos = p.pointValue
            let H = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: pos.x, y: H - pos.y - size.height, width: size.width, height: size.height)
        }
        return nil
    }

    static func actions(_ o: NSObject) -> [String] {
        let sel = NSSelectorFromString("accessibilityActionNames")
        if o.responds(to: sel), let a = o.perform(sel)?.takeUnretainedValue() as? [String] { return a }
        return []
    }

    static func isEnabled(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("isAccessibilityEnabled")
        if o.responds(to: sel), let v = o.value(forKey: "accessibilityEnabled") as? NSNumber { return v.boolValue }
        if let v = legacy(o, "AXEnabled") as? NSNumber { return v.boolValue }
        return true
    }

    @discardableResult
    static func press(_ o: NSObject) -> Bool {
        let sel = NSSelectorFromString("accessibilityPerformPress")
        if o.responds(to: sel) { return o.perform(sel) != nil }
        let legacySel = NSSelectorFromString("accessibilityPerformAction:")
        if o.responds(to: legacySel), actions(o).contains("AXPress") { _ = o.perform(legacySel, with: "AXPress" as NSString); return true }
        return false
    }

    static func perform(_ o: NSObject, _ action: String) {
        let modern = ["AXIncrement": "accessibilityPerformIncrement", "AXDecrement": "accessibilityPerformDecrement", "AXPress": "accessibilityPerformPress"]
        if let m = modern[action], o.responds(to: NSSelectorFromString(m)) { _ = o.perform(NSSelectorFromString(m)); return }
        let legacySel = NSSelectorFromString("accessibilityPerformAction:")
        if o.responds(to: legacySel) { _ = o.perform(legacySel, with: action as NSString) }
    }

    static func setValue(_ o: NSObject, _ v: AnyObject) {
        let sel = NSSelectorFromString("setAccessibilityValue:")
        if o.responds(to: sel) { _ = o.perform(sel, with: v); return }
        let legacySel = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        if o.responds(to: legacySel) { _ = o.perform(legacySel, with: v, with: "AXValue" as NSString) }
    }

    static func tree(_ root: NSObject, maxDepth: Int = 60, limit: Int = 8000) -> [Node] {
        var out: [Node] = []
        var seen = Set<ObjectIdentifier>()
        func walk(_ e: NSObject, _ d: Int) {
            guard d < maxDepth, out.count < limit, seen.insert(ObjectIdentifier(e)).inserted else { return }
            out.append(Node(element: e, role: role(e), label: label(e), depth: d))
            for c in children(e) { walk(c, d + 1) }
        }
        walk(root, 0)
        return out
    }

    static func dump(_ nodes: [Node]) -> String {
        var t = ""
        for n in nodes {
            let f = frame(n.element).map { "(\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height)))" } ?? ""
            t += String(repeating: "  ", count: n.depth) + "\(n.role)\(subrole(n.element).isEmpty ? "" : "/" + subrole(n.element)) [\(n.label)] \(f) \(actions(n.element).joined(separator: ",")) <\(type(of: n.element))>\n"
        }
        return t
    }
}
