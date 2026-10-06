import AppKit
import SwiftUI
import ImageCratCore

/// All dockable panels, by id.
enum PanelRegistry {
    struct Def {
        let id: String
        let title: String
        let make: () -> AnyView
    }

    static var defs: [Def] = [
        Def(id: "color", title: "Color") { AnyView(ColorPanel()) },
        Def(id: "swatches", title: "Swatches") { AnyView(SwatchesPanel()) },
        Def(id: "gradients", title: "Gradients") { AnyView(GradientsPanel()) },
        Def(id: "patterns", title: "Patterns") { AnyView(PatternsPanel()) },
        Def(id: "properties", title: "Properties") { AnyView(PropertiesPanel()) },
        Def(id: "adjustments", title: "Adjustments") { AnyView(AdjustmentsPanel()) },
        Def(id: "character", title: "Character") { AnyView(CharacterPanel()) },
        Def(id: "paragraph", title: "Paragraph") { AnyView(ParagraphPanel()) },
        Def(id: "layers", title: "Layers") { AnyView(LayersPanel()) },
        Def(id: "channels", title: "Channels") { AnyView(ChannelsPanel()) },
        Def(id: "paths", title: "Paths") { AnyView(PathsPanel()) },
        Def(id: "layerComps", title: "Layer Comps") { AnyView(LayerCompsPanel()) },
        Def(id: "navigator", title: "Navigator") { AnyView(NavigatorPanel()) },
        Def(id: "histogram", title: "Histogram") { AnyView(HistogramPanel()) },
        Def(id: "info", title: "Info") { AnyView(InfoPanel()) },
        Def(id: "history", title: "History") { AnyView(HistoryPanel()) },
        Def(id: "brushes", title: "Brushes") { AnyView(BrushesPanel()) },
        Def(id: "brushSettings", title: "Brush Settings") { AnyView(BrushSettingsPanel()) },
        Def(id: "actions", title: "Actions") { AnyView(ActionsPanel()) },
        Def(id: "toolPresets", title: "Tool Presets") { AnyView(ToolPresetsPanel()) },
    ]

    static func def(_ id: String) -> Def? { defs.first { $0.id == id } }
    static func register(_ d: Def) { if def(d.id) == nil { defs.append(d) } }
}

// MARK: - Layout model
//
// A workspace is a row of docked columns (left → right; the last one is the main column) holding tab groups, plus
// floating groups in their own utility windows. Everything here is a plain value: the views and windows are rebuilt
// from it, it is what gets saved, and every arrangement step (dock, tab, reorder, split, float, resize, collapse) is a
// pure function on it. Layout changes never touch a document (no history step, no dirty flag).

/// Sizes of the dock chrome, in points.
enum DockMetrics {
    static let tabBarHeight: CGFloat = 26
    static let columnHeaderHeight: CGFloat = 16
    /// The strip left of every column (drag it to resize that column).
    static let columnGap: CGFloat = 4
    /// The strip between two groups of a column (drag it to share their height).
    static let groupGap: CGFloat = 3
    static let iconColumnWidth: CGFloat = 38
    static let minColumnWidth: CGFloat = 190
    static let maxColumnWidth: CGFloat = 640
    static let minGroupHeight: CGFloat = tabBarHeight + 64
    /// The canvas keeps at least this much width when columns are widened.
    static let minCanvasWidth: CGFloat = 320
    /// Tools palette + its border, left of the canvas.
    static let toolsWidth: CGFloat = 47
    static let defaultFloatSize = CGSize(width: 280, height: 380)
    static let minFloatSize = CGSize(width: 200, height: tabBarHeight + 80)
}

enum DockID {
    static func make() -> String { "g" + UUID().uuidString.prefix(8).lowercased() }
}

/// A tab group: one or more panels sharing a tab bar.
struct DockGroup: Codable, Equatable, Identifiable {
    var id: String
    var panels: [String]
    /// The selected tab; nil = the first one.
    var active: String?
    /// Collapsed to its tab bar (double-click the tab bar).
    var collapsed: Bool
    /// Preferred height in points; a column scales its expanded groups to fill the height it has.
    var height: CGFloat

    init(_ panels: [String], id: String = DockID.make(), height: CGFloat = 240, active: String? = nil, collapsed: Bool = false) {
        self.id = id; self.panels = panels; self.active = active; self.collapsed = collapsed; self.height = height
        normalize()
    }

    var selected: String? {
        if let a = active, panels.contains(a) { return a }
        return panels.first
    }

    mutating func select(_ p: String) {
        guard panels.contains(p) else { return }
        active = p
        normalize()
    }

    /// "First tab" is stored as nil, so selecting the first tab of a stock layout leaves it equal to the stock layout.
    mutating func normalize() {
        if let a = active, a == panels.first || !panels.contains(a) { active = nil }
    }

    private enum K: String, CodingKey { case id, panels, active, collapsed, height }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? DockID.make()
        panels = (try? c.decodeIfPresent([String].self, forKey: .panels)) ?? []
        active = try? c.decodeIfPresent(String.self, forKey: .active)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        height = (try? c.decodeIfPresent(CGFloat.self, forKey: .height)) ?? 240
        normalize()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(panels, forKey: .panels)
        try c.encodeIfPresent(active, forKey: .active); try c.encode(collapsed, forKey: .collapsed); try c.encode(height, forKey: .height)
    }
}

/// A docked column of tab groups, or (iconic) a strip of panel icons.
struct DockColumn: Codable, Equatable, Identifiable {
    var id: String
    var groups: [DockGroup]
    var width: CGFloat
    var iconic: Bool

    init(_ groups: [DockGroup], id: String = DockID.make(), width: CGFloat = 260, iconic: Bool = false) {
        self.id = id; self.groups = groups; self.width = width; self.iconic = iconic
    }

    var displayWidth: CGFloat { iconic ? DockMetrics.iconColumnWidth : width }

    private enum K: String, CodingKey { case id, groups, width, iconic }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? DockID.make()
        groups = (try? c.decodeIfPresent([DockGroup].self, forKey: .groups)) ?? []
        width = (try? c.decodeIfPresent(CGFloat.self, forKey: .width)) ?? 260
        iconic = (try? c.decodeIfPresent(Bool.self, forKey: .iconic)) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(groups, forKey: .groups); try c.encode(width, forKey: .width); try c.encode(iconic, forKey: .iconic)
    }
}

/// A tab group in its own utility window. `frame` is the window frame in screen coordinates (nil: not placed yet).
struct FloatingGroup: Codable, Equatable, Identifiable {
    var group: DockGroup
    var frame: CGRect?
    var id: String { group.id }
}

/// Where a dragged panel (or tab group) lands.
enum DockDropTarget: Equatable {
    /// Into a group's tab bar at `index` (docked or floating group).
    case tab(group: String, index: Int)
    /// A new group just above / below a docked group.
    case split(group: String, below: Bool)
    /// A new column inserted at `index` of `Workspace.columns` (0 = leftmost, columns.count = right of the main column).
    case column(index: Int)
    /// A new group at the bottom of a column (its empty space, or an icon column).
    case columnEnd(column: String)
}

/// Panel arrangement: docked columns of tab groups plus floating groups.
struct Workspace: Codable, Equatable {
    var name: String
    var columns: [DockColumn]
    var floating: [FloatingGroup] = []
    var showSecondary = true

    init(name: String, columns: [DockColumn], floating: [FloatingGroup] = [], showSecondary: Bool = true) {
        self.name = name; self.columns = columns; self.floating = floating; self.showSecondary = showSecondary
    }

    /// The classic two-column arrangement (secondary column left of the main one).
    init(name: String, primary: [[String]], secondary: [[String]], showSecondary: Bool = true, floating: [String] = []) {
        var cols: [DockColumn] = []
        if !secondary.isEmpty { cols.append(DockColumn(secondary.map { DockGroup($0) }, width: 230)) }
        if !primary.isEmpty { cols.append(DockColumn(primary.map { DockGroup($0) }, width: 300)) }
        self.init(name: name, columns: cols, floating: floating.map { FloatingGroup(group: DockGroup([$0]), frame: nil) }, showSecondary: showSecondary)
    }

    // MARK: Codable (reads the old `primary` / `secondary` / `floating: [String]` format too)

    private enum K: String, CodingKey { case name, columns, floating, showSecondary, primary, secondary }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Essentials"
        let show = (try? c.decodeIfPresent(Bool.self, forKey: .showSecondary)) ?? true
        if let cols = try? c.decode([DockColumn].self, forKey: .columns) {
            let fl = (try? c.decodeIfPresent([FloatingGroup].self, forKey: .floating)) ?? []
            self.init(name: name, columns: cols, floating: fl, showSecondary: show)
        } else {
            let p = (try? c.decodeIfPresent([[String]].self, forKey: .primary)) ?? []
            let s = (try? c.decodeIfPresent([[String]].self, forKey: .secondary)) ?? []
            let f = (try? c.decodeIfPresent([String].self, forKey: .floating)) ?? []
            self.init(name: name, primary: p, secondary: s, showSecondary: show, floating: f)
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(name, forKey: .name); try c.encode(columns, forKey: .columns)
        try c.encode(floating, forKey: .floating); try c.encode(showSecondary, forKey: .showSecondary)
    }

    // MARK: Compatibility views

    /// Groups of the main (rightmost) column.
    var primary: [[String]] { columns.last?.groups.map(\.panels) ?? [] }
    /// Groups of the other columns.
    var secondary: [[String]] { columns.dropLast().flatMap { $0.groups.map(\.panels) } }
    var floatingIDs: [String] { floating.flatMap(\.group.panels) }
    var allDocked: [String] { columns.flatMap { $0.groups.flatMap(\.panels) } }
    var allPanels: [String] { allDocked + floatingIDs }
    func contains(_ id: String) -> Bool { allPanels.contains(id) }

    // MARK: Lookup

    enum GroupPath: Equatable {
        case docked(column: Int, group: Int)
        case floating(Int)
    }

    func path(ofGroup gid: String) -> GroupPath? {
        for (ci, c) in columns.enumerated() { if let gi = c.groups.firstIndex(where: { $0.id == gid }) { return .docked(column: ci, group: gi) } }
        if let fi = floating.firstIndex(where: { $0.group.id == gid }) { return .floating(fi) }
        return nil
    }

    func path(ofPanel id: String) -> GroupPath? {
        for (ci, c) in columns.enumerated() { if let gi = c.groups.firstIndex(where: { $0.panels.contains(id) }) { return .docked(column: ci, group: gi) } }
        if let fi = floating.firstIndex(where: { $0.group.panels.contains(id) }) { return .floating(fi) }
        return nil
    }

    subscript(path: GroupPath) -> DockGroup {
        get {
            switch path {
            case .docked(let c, let g): return columns[c].groups[g]
            case .floating(let f): return floating[f].group
            }
        }
        set {
            switch path {
            case .docked(let c, let g): columns[c].groups[g] = newValue
            case .floating(let f): floating[f].group = newValue
            }
        }
    }

    func group(_ gid: String) -> DockGroup? { path(ofGroup: gid).map { self[$0] } }
    func group(containing id: String) -> DockGroup? { path(ofPanel: id).map { self[$0] } }
    func columnIndex(_ cid: String) -> Int? { columns.firstIndex { $0.id == cid } }
    func isFloating(_ id: String) -> Bool { floating.contains { $0.group.panels.contains(id) } }

    // MARK: Editing

    /// Removes a panel wherever it is (and any group / column / window left empty).
    mutating func remove(_ id: String) {
        detach([id])
        prune()
    }

    /// Removes panels without dropping the groups they leave empty (so drop targets naming those groups stay valid).
    mutating func detach(_ ids: [String]) {
        for ci in columns.indices {
            for gi in columns[ci].groups.indices {
                columns[ci].groups[gi].panels.removeAll { ids.contains($0) }
                columns[ci].groups[gi].normalize()
            }
        }
        for fi in floating.indices {
            floating[fi].group.panels.removeAll { ids.contains($0) }
            floating[fi].group.normalize()
        }
    }

    /// Drops empty groups, columns and windows and duplicate panels (the first place a panel appears wins).
    mutating func prune() {
        var seen = Set<String>()
        func dedupe(_ g: inout DockGroup) {
            g.panels = g.panels.filter { seen.insert($0).inserted }
            g.normalize()
        }
        for ci in columns.indices {
            for gi in columns[ci].groups.indices { dedupe(&columns[ci].groups[gi]) }
            columns[ci].groups.removeAll { $0.panels.isEmpty }
        }
        columns.removeAll { $0.groups.isEmpty }
        for fi in floating.indices { dedupe(&floating[fi].group) }
        floating.removeAll { $0.group.panels.isEmpty }
    }

    /// Repairs a layout read from disk: duplicates, empty containers, out-of-range sizes.
    mutating func sanitize() {
        prune()
        for ci in columns.indices {
            if !columns[ci].width.isFinite { columns[ci].width = 260 }
            columns[ci].width = min(max(columns[ci].width, DockMetrics.minColumnWidth), DockMetrics.maxColumnWidth)
            for gi in columns[ci].groups.indices {
                let h = columns[ci].groups[gi].height
                columns[ci].groups[gi].height = h.isFinite ? min(max(h, DockMetrics.minGroupHeight), 4000) : 240
            }
        }
        for fi in floating.indices {
            if let f = floating[fi].frame, !(f.origin.x.isFinite && f.origin.y.isFinite && f.width.isFinite && f.height.isFinite) || f.width < 1 || f.height < 1 {
                floating[fi].frame = nil
            }
        }
    }

    /// Moves `panels` (from wherever they are, or from closed) to `target`. `active` becomes the selected tab there.
    /// Returns false (and changes nothing) when the move would be a no-op, e.g. a whole group dropped onto itself.
    @discardableResult
    mutating func move(_ panels: [String], to target: DockDropTarget, active: String? = nil, height: CGFloat? = nil) -> Bool {
        var ids: [String] = []
        for p in panels where !ids.contains(p) { ids.append(p) }
        guard !ids.isEmpty else { return false }
        let sel = active.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        switch target {
        case .split(let g, _):
            guard let gp = path(ofGroup: g) else { return false }
            if Set(self[gp].panels) == Set(ids) { return false }               // a group split next to itself
            if case .floating = gp { return move(ids, to: .tab(group: g, index: self[gp].panels.count), active: sel) }
        case .tab(let g, _):
            guard path(ofGroup: g) != nil else { return false }
        case .columnEnd(let c):
            guard columnIndex(c) != nil else { return false }
            if let ci = columnIndex(c), columns[ci].groups.count == 1, Set(columns[ci].groups[0].panels) == Set(ids) { return false }
        case .column:
            break
        }
        let before = self
        // insertion index in the target tab bar, counted without the moved panels
        var tabIndex = 0
        if case .tab(let g, let idx) = target, let gp = path(ofGroup: g) {
            let tabs = self[gp].panels
            let i = min(max(0, idx), tabs.count)
            tabIndex = i - tabs.prefix(i).filter { ids.contains($0) }.count
        }
        let sourceHeight = ids.first.flatMap { group(containing: $0)?.height }
        detach(ids)
        switch target {
        case .tab(let g, _):
            guard let gp = path(ofGroup: g) else { self = before; return false }
            var grp = self[gp]
            grp.panels.insert(contentsOf: ids, at: min(tabIndex, grp.panels.count))
            grp.collapsed = false
            if let s = sel { grp.select(s) }
            self[gp] = grp
        case .split(let g, let below):
            guard case .docked(let ci, let gi)? = path(ofGroup: g) else { self = before; return false }
            let h = height ?? sourceHeight ?? columns[ci].groups[gi].height
            columns[ci].groups.insert(DockGroup(ids, height: max(h, DockMetrics.minGroupHeight), active: sel), at: below ? gi + 1 : gi)
        case .column(let index):
            let col = DockColumn([DockGroup(ids, height: 400, active: sel)], width: 260)
            columns.insert(col, at: min(max(0, index), columns.count))
        case .columnEnd(let c):
            guard let ci = columnIndex(c) else { self = before; return false }
            columns[ci].groups.append(DockGroup(ids, height: max(height ?? sourceHeight ?? 260, DockMetrics.minGroupHeight), active: sel))
        }
        prune()
        return self != before
    }

    /// Takes `panels` out of the dock into a new floating window.
    mutating func float(_ panels: [String], frame: CGRect?, active: String? = nil) {
        var ids: [String] = []
        for p in panels where !ids.contains(p) { ids.append(p) }
        guard !ids.isEmpty else { return }
        // already alone in a floating window: just move it
        if case .floating(let fi)? = path(ofPanel: ids[0]), Set(floating[fi].group.panels) == Set(ids) {
            if let frame { floating[fi].frame = frame }
            return
        }
        detach(ids)
        floating.append(FloatingGroup(group: DockGroup(ids, active: active), frame: frame))
        prune()
    }

    /// Docks a panel where Photoshop puts a newly shown one: the last group of the main column (secondary: of the column
    /// left of it).
    mutating func dockAtDefault(_ id: String, secondary: Bool = false) {
        detach([id])
        if secondary {
            if columns.count >= 2 { columns[columns.count - 2].groups.append(DockGroup([id])) }
            else { columns.insert(DockColumn([DockGroup([id])], width: 230), at: 0) }
        } else if columns.isEmpty {
            columns.append(DockColumn([DockGroup([id], height: 400)], width: 300))
        } else {
            let ci = columns.count - 1
            if columns[ci].groups.isEmpty { columns[ci].groups = [DockGroup([id])] } else { columns[ci].groups[columns[ci].groups.count - 1].panels.append(id) }
        }
        prune()
    }

    /// Selects a panel's tab (and expands its group).
    mutating func select(_ id: String, expand: Bool = true) {
        guard let gp = path(ofPanel: id) else { return }
        var g = self[gp]
        g.select(id)
        if expand { g.collapsed = false }
        self[gp] = g
    }

    mutating func setCollapsed(_ gid: String, _ on: Bool) {
        guard let gp = path(ofGroup: gid) else { return }
        self[gp].collapsed = on
    }

    mutating func setIconic(_ cid: String, _ on: Bool) {
        guard let ci = columnIndex(cid) else { return }
        columns[ci].iconic = on
    }

    mutating func setWidth(_ cid: String, _ w: CGFloat) {
        guard let ci = columnIndex(cid) else { return }
        columns[ci].width = min(max(w.rounded(), DockMetrics.minColumnWidth), DockMetrics.maxColumnWidth)
    }

    /// Moves the divider below group `gi` of a column by `delta` points. `actual` are the groups' laid-out heights; the
    /// nearest expanded groups above and below the divider trade height (each keeps at least `minGroupHeight`), and every
    /// expanded group's preferred height becomes its laid-out one.
    @discardableResult
    mutating func resizeGroups(column cid: String, divider gi: Int, delta: CGFloat, actual: [CGFloat]) -> Bool {
        guard let ci = columnIndex(cid), actual.count == columns[ci].groups.count else { return false }
        let gs = columns[ci].groups
        guard let a = (0...min(gi, gs.count - 1)).reversed().first(where: { !gs[$0].collapsed }),
              let b = (min(gi + 1, gs.count)..<gs.count).first(where: { !gs[$0].collapsed }) else { return false }
        var h = actual
        let total = h[a] + h[b]
        let m = DockMetrics.minGroupHeight
        guard total >= 2 * m else { return false }
        let na = min(max(h[a] + delta, m), total - m)
        h[a] = na; h[b] = total - na
        for i in gs.indices where !gs[i].collapsed { columns[ci].groups[i].height = h[i].rounded() }
        return true
    }

    /// Floating windows that are off every screen (or bigger than it) come back. Returns the ids of the groups moved.
    @discardableResult
    mutating func recoverFloating(screens: [CGRect], anchor: CGRect?) -> [String] {
        guard let first = screens.first else { return [] }
        var moved: [String] = []
        var k = 0
        for fi in floating.indices {
            let size = floating[fi].frame?.size ?? DockMetrics.defaultFloatSize
            if let f = floating[fi].frame, WorkspaceGeometry.isReachable(f, screens: screens) {
                // too large for its screen: shrink to fit
                if let s = screens.max(by: { WorkspaceGeometry.area($0.intersection(f)) < WorkspaceGeometry.area($1.intersection(f)) }), f.width > s.width || f.height > s.height {
                    floating[fi].frame = WorkspaceGeometry.clamp(CGRect(origin: f.origin, size: CGSize(width: min(f.width, s.width), height: min(f.height, s.height))), into: s)
                    moved.append(floating[fi].id)
                }
                continue
            }
            let base = anchor.flatMap { a in screens.first { $0.intersects(a) } != nil ? a : nil } ?? first
            let screen = screens.first { $0.intersects(base) } ?? first
            let w = min(size.width, screen.width), h = min(size.height, screen.height)
            let origin = CGPoint(x: base.maxX - w - 340 - CGFloat(k) * 24, y: base.maxY - h - 90 - CGFloat(k) * 24)
            floating[fi].frame = WorkspaceGeometry.clamp(CGRect(origin: origin, size: CGSize(width: w, height: h)), into: screen)
            moved.append(floating[fi].id)
            k += 1
        }
        return moved
    }

    // MARK: Stock workspaces

    private static func col(_ id: String, _ width: CGFloat, iconic: Bool = false, _ groups: [(String, [String], CGFloat)]) -> DockColumn {
        DockColumn(groups.map { DockGroup($0.1, id: id + "." + $0.0, height: $0.2) }, id: id, width: width, iconic: iconic)
    }

    static let essentials = Workspace(name: "Essentials", columns: [
        col("ess.c1", 230, [("g1", ["navigator", "histogram", "info"], 220), ("g2", ["history", "brushes", "brushSettings", "actions", "layerComps"], 380)]),
        col("ess.c2", 300, [("g1", ["color", "swatches", "gradients", "patterns"], 210), ("g2", ["properties", "adjustments", "character", "paragraph"], 300),
                            ("g3", ["layers", "channels", "paths"], 380)]),
    ])
    static let photography = Workspace(name: "Photography", columns: [
        col("pho.c1", 230, iconic: true, [("g1", ["history", "actions"], 300), ("g2", ["info", "color"], 220), ("g3", ["layerComps"], 200)]),
        col("pho.c2", 300, [("g1", ["histogram", "navigator"], 210), ("g2", ["adjustments", "properties"], 320), ("g3", ["layers", "channels", "paths"], 380)]),
    ])
    static let painting = Workspace(name: "Painting", columns: [
        col("pai.c1", 230, [("g1", ["brushes", "toolPresets"], 320), ("g2", ["navigator", "info"], 200), ("g3", ["history"], 220)]),
        col("pai.c2", 300, [("g1", ["color", "swatches"], 230), ("g2", ["brushSettings"], 330), ("g3", ["layers", "channels"], 320)]),
    ])
    static let typography = Workspace(name: "Typography", columns: [
        col("typ.c1", 240, [("g1", ["glyphs"], 340), ("g2", ["history", "info"], 240)]),
        col("typ.c2", 300, [("g1", ["character", "paragraph"], 330), ("g2", ["properties", "swatches"], 240), ("g3", ["layers", "paths"], 330)]),
    ])
    static let webUI = Workspace(name: "Web/UI", columns: [
        col("web.c1", 240, [("g1", ["components", "clipboardHistory"], 300), ("g2", ["navigator", "history"], 260)]),
        col("web.c2", 300, [("g1", ["properties", "info"], 280), ("g2", ["swatches", "color", "gradients"], 220), ("g3", ["layers", "layerComps"], 360)]),
    ])
    static let builtIn = [essentials, photography, painting, typography, webUI]
    /// Names of earlier stock workspaces → their replacement.
    static let renamed = ["Graphic and Web": "Web/UI"]
}

// MARK: - Geometry helpers

enum WorkspaceGeometry {
    /// Laid-out heights of a column's groups: collapsed groups keep their tab bar, expanded ones share the rest in
    /// proportion to their preferred heights.
    static func groupHeights(_ groups: [DockGroup], available: CGFloat) -> [CGFloat] {
        guard !groups.isEmpty else { return [] }
        let gaps = CGFloat(groups.count - 1) * DockMetrics.groupGap
        let collapsedSum = CGFloat(groups.filter(\.collapsed).count) * DockMetrics.tabBarHeight
        let rest = max(0, available - gaps - collapsedSum)
        let weights = groups.map { $0.collapsed ? 0 : max($0.height, 1) }
        let sum = weights.reduce(0, +)
        var out = groups.map { $0.collapsed ? DockMetrics.tabBarHeight : 0 }
        guard sum > 0 else { return out }
        var used: CGFloat = 0
        let last = groups.lastIndex { !$0.collapsed }!
        for i in groups.indices where !groups[i].collapsed {
            if i == last { out[i] = max(0, rest - used) } else {
                out[i] = (rest * weights[i] / sum).rounded(.down)
                used += out[i]
            }
        }
        return out
    }

    /// Total width of the docked columns shown (each with its divider strip).
    static func dockWidth(_ w: Workspace, showSecondary: Bool) -> CGFloat {
        let cols = showSecondary ? w.columns : Array(w.columns.suffix(1))
        return cols.reduce(0) { $0 + $1.displayWidth + DockMetrics.columnGap }
    }

    /// A window can be grabbed again when a usable part of its title strip is on some screen.
    static func isReachable(_ f: CGRect, screens: [CGRect]) -> Bool {
        let title = CGRect(x: f.minX, y: f.maxY - 24, width: f.width, height: 24)
        return screens.contains { s in
            let i = s.intersection(title)
            return !i.isNull && i.width >= min(60, f.width) && i.height >= 8
        }
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    static func clamp(_ f: CGRect, into s: CGRect) -> CGRect {
        var r = f
        r.size.width = min(r.width, s.width); r.size.height = min(r.height, s.height)
        r.origin.x = min(max(r.minX, s.minX), s.maxX - r.width)
        r.origin.y = min(max(r.minY, s.minY), s.maxY - r.height)
        return r
    }

    /// Magnetic edges: a floating window's edges snap to the edges of the screens' visible frames and to the edges of
    /// other windows (outside and aligned) when they come within `threshold` points.
    static func snap(_ f: CGRect, screens: [CGRect], windows: [CGRect], threshold: CGFloat = 10) -> CGRect {
        var dx: CGFloat? = nil, dy: CGFloat? = nil
        func consider(_ mine: [CGFloat], _ lines: [CGFloat], _ best: inout CGFloat?) {
            for m in mine { for l in lines { let d = l - m; if abs(d) <= threshold, abs(d) < abs(best ?? .infinity) { best = d } } }
        }
        for s in screens {
            consider([f.minX, f.maxX], [s.minX, s.maxX], &dx)
            consider([f.minY, f.maxY], [s.minY, s.maxY], &dy)
        }
        for w in windows {
            // only windows beside / above / below this one (their ranges overlap on the other axis)
            if f.maxY + threshold >= w.minY && f.minY - threshold <= w.maxY { consider([f.minX, f.maxX], [w.minX, w.maxX], &dx) }
            if f.maxX + threshold >= w.minX && f.minX - threshold <= w.maxX { consider([f.minY, f.maxY], [w.minY, w.maxY], &dy) }
        }
        return f.offsetBy(dx: dx ?? 0, dy: dy ?? 0)
    }
}

// MARK: - Persistence

/// Where workspaces are saved. The app uses the standard defaults; self tests use memory or a temporary suite, so a test
/// run never writes the user's saved layout.
protocol WorkspaceStore: AnyObject {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

final class DefaultsWorkspaceStore: WorkspaceStore {
    let defaults: UserDefaults
    init(_ d: UserDefaults) { defaults = d }
    func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    func set(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

final class MemoryWorkspaceStore: WorkspaceStore {
    var values: [String: Data] = [:]
    func data(forKey key: String) -> Data? { values[key] }
    func set(_ data: Data?, forKey key: String) { values[key] = data }
}

// MARK: - Manager

/// Owns the live arrangement: persists it, keeps the docked columns (`DockAreaView`) and floating windows in step with
/// it, and runs panel drags. None of this is document state: nothing here records history or marks a document dirty.
@Observable
final class WorkspaceManager {
    static let isSelfTest = CommandLine.arguments.contains("--selftest")
    static let shared = WorkspaceManager(store: isSelfTest ? MemoryWorkspaceStore() : DefaultsWorkspaceStore(.standard), managesWindows: true)
    /// Screens used for placing and recovering floating windows. Self tests use a screen far off the real ones, so no
    /// test window ever appears on the user's display.
    static var screensOverride: [CGRect]? = isSelfTest ? [CGRect(x: -30000, y: -30000, width: 2560, height: 1600)] : nil

    static let currentKey = "Lumen.Workspace"
    static let savedKey = "Lumen.SavedWorkspaces"
    static let editsKey = "Lumen.WorkspaceEdits"

    var current: Workspace { didSet { if current != oldValue { layoutChanged() } } }
    var saved: [Workspace] { didSet { if !restoring { persist(saved, Self.savedKey) } } }
    /// Bumped to make a tab group select a given panel.
    var focusRequest: (id: String, tick: Int) = ("", 0)
    /// Width of the docked columns with / without the secondary columns (the main window lays out the canvas with it).
    private(set) var dockWidthAll: CGFloat = 0
    private(set) var dockWidthPrimary: CGFloat = 0

    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored private(set) var store: WorkspaceStore
    @ObservationIgnored let managesWindows: Bool
    /// Changes made to each workspace since it was last chosen (Photoshop keeps them until Reset).
    @ObservationIgnored private var edits: [String: Workspace] = [:]
    @ObservationIgnored private var liveDepth = 0
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private(set) var windows: [String: FloatingPanel] = [:]
    @ObservationIgnored private var hosts: [String: NSView] = [:]
    @ObservationIgnored private let docks = NSHashTable<DockAreaView>.weakObjects()
    @ObservationIgnored private var started = false
    @ObservationIgnored var flyout: DockFlyout?
    @ObservationIgnored var drag: DockDragSession?

    init(store: WorkspaceStore, managesWindows: Bool) {
        self.store = store
        self.managesWindows = managesWindows
        let l = Self.load(store)
        current = l.current
        saved = l.saved
        edits = l.edits
        updateWidths()
        if managesWindows { DispatchQueue.main.async { [weak self] in self?.start() } }
    }

    private static func load(_ store: WorkspaceStore) -> (current: Workspace, saved: [Workspace], edits: [String: Workspace]) {
        let dec = JSONDecoder()
        var cur = store.data(forKey: currentKey).flatMap { try? dec.decode(Workspace.self, from: $0) } ?? .essentials
        if let n = Workspace.renamed[cur.name] { cur.name = n }
        cur.sanitize()
        var sv = store.data(forKey: savedKey).flatMap { try? dec.decode([Workspace].self, from: $0) } ?? []
        for i in sv.indices { sv[i].sanitize() }
        let ed = store.data(forKey: editsKey).flatMap { try? dec.decode([String: Workspace].self, from: $0) } ?? [:]
        return (cur, sv, ed)
    }

    private func persist<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { store.set(d, forKey: key) }
    }

    /// Writes the current layout now (otherwise it is written after each change, or once a live drag ends).
    func saveNow() {
        saveScheduled = false
        persist(current, Self.currentKey)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in if self?.saveScheduled == true { self?.saveNow() } }
    }

    private func layoutChanged() {
        revision += 1
        updateWidths()
        if let f = flyout, !current.contains(f.panelID) { closeFlyout() }
        for d in docks.allObjects { d.reload() }
        syncWindows()
        for id in hosts.keys where !current.contains(id) && flyout?.panelID != id { evictHost(id) }
        if !restoring && liveDepth == 0 { saveNow() }
    }

    private func updateWidths() {
        let a = WorkspaceGeometry.dockWidth(current, showSecondary: true), p = WorkspaceGeometry.dockWidth(current, showSecondary: false)
        if dockWidthAll != a { dockWidthAll = a }
        if dockWidthPrimary != p { dockWidthPrimary = p }
    }

    /// Live changes (dragging a divider or a window): applied at once, written to disk when the gesture ends.
    func beginLive() { liveDepth += 1 }
    func endLive() {
        liveDepth = max(0, liveDepth - 1)
        if liveDepth == 0 && !restoring { saveNow() }
    }

    /// Self tests: runs `body` with workspaces read from and written to `s`, then puts the previous store and layout back.
    func withStore<T>(_ s: WorkspaceStore, _ body: () throws -> T) rethrows -> T {
        let prev = (store: store, current: current, saved: saved, edits: edits, secondary: AppModel.shared.showSecondaryPanels)
        restoring = true
        store = s
        let l = Self.load(s)
        current = l.current; saved = l.saved; edits = l.edits
        restoring = false
        defer {
            restoring = true
            store = prev.store
            current = prev.current; saved = prev.saved; edits = prev.edits
            AppModel.shared.showSecondaryPanels = prev.secondary
            restoring = false
        }
        return try body()
    }

    /// Re-reads everything from the store (what a new launch would see).
    func reloadFromStore() {
        restoring = true
        let l = Self.load(store)
        current = l.current; saved = l.saved; edits = l.edits
        restoring = false
    }

    // MARK: Workspaces

    var allWorkspaces: [Workspace] { Workspace.builtIn + saved }

    /// The saved (pristine) arrangement called `name`.
    func definition(_ name: String) -> Workspace? {
        let n = Workspace.renamed[name] ?? name
        return saved.first { $0.name == n } ?? Workspace.builtIn.first { $0.name == n }
    }

    /// True when the current arrangement differs from its saved definition.
    var isModified: Bool { definition(current.name).map { $0.columns != current.columns || $0.floating != current.floating } ?? true }

    /// Shows exactly this arrangement.
    func apply(_ w: Workspace) {
        closeFlyout()
        var w = w
        w.sanitize()
        current = w
        AppModel.shared.showSecondaryPanels = w.showSecondary
        recoverLostPanels()
    }

    /// Window ▸ Workspace ▸ <name>: keeps the changes made to the workspace being left (until Reset) and shows `name`
    /// as it was last left.
    func switchTo(_ name: String) {
        guard name != current.name else { return }
        var cur = current
        cur.showSecondary = AppModel.shared.showSecondaryPanels
        if let def = definition(cur.name), def.columns == cur.columns, def.floating == cur.floating, def.showSecondary == cur.showSecondary {
            edits[cur.name] = nil
        } else {
            edits[cur.name] = cur
        }
        persist(edits, Self.editsKey)
        apply(edits[name] ?? definition(name) ?? .essentials)
    }

    /// Puts the current workspace back as saved (every panel, column and window where the definition has it).
    func reset() {
        edits[current.name] = nil
        persist(edits, Self.editsKey)
        apply(definition(current.name) ?? .essentials)
    }

    func saveCurrent(as name: String) {
        var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if Workspace.builtIn.contains(where: { $0.name == n }) { n += " (Custom)" }
        var w = current
        w.name = n
        w.showSecondary = AppModel.shared.showSecondaryPanels
        saved.removeAll { $0.name == n }
        saved.append(w)
        edits[n] = nil
        persist(edits, Self.editsKey)
        current = w
    }

    func deleteSaved(_ name: String) {
        saved.removeAll { $0.name == name }
        edits[name] = nil
        persist(edits, Self.editsKey)
    }

    // MARK: Panels

    func isVisible(_ id: String) -> Bool { current.contains(id) }

    /// Visible and in front: its tab selected, its group expanded, its column shown and not collapsed to icons.
    func isFrontmost(_ id: String) -> Bool {
        guard AppModel.shared.showPanels, let gp = current.path(ofPanel: id) else { return false }
        let g = current[gp]
        guard g.selected == id, !g.collapsed else { return false }
        if case .docked(let ci, _) = gp {
            if current.columns[ci].iconic { return false }
            if ci < current.columns.count - 1 && !AppModel.shared.showSecondaryPanels { return false }
        }
        return true
    }

    /// Shows and focuses a panel (never hides one). Kept for callers of the old Window-menu toggle.
    func toggle(_ id: String) { reveal(id) }

    /// Window ▸ Panels ▸ <panel>: hides a panel that is in front, otherwise brings it forward.
    func menuToggle(_ id: String) {
        if isFrontmost(id) { close(id); return }
        if !AppModel.shared.showPanels { AppModel.shared.showPanels = true }
        reveal(id)
    }

    /// Makes a panel visible without ever hiding it: floating → its window comes to the front; docked → its tab is
    /// selected (and its group expanded); closed → it is docked (last group of the main column) and selected.
    func reveal(_ id: String) {
        guard PanelRegistry.def(id) != nil else { return }
        var w = current
        if !w.contains(id) { w.dockAtDefault(id) }
        w.select(id)
        current = w
        switch current.path(ofPanel: id) {
        case .docked(let ci, _)?:
            if ci < current.columns.count - 1, !AppModel.shared.showSecondaryPanels { AppModel.shared.showSecondaryPanels = true }
            if current.columns[ci].iconic { DispatchQueue.main.async { [weak self] in self?.showFlyout(id) } }
        case .floating(let fi)?:
            if let win = windows[current.floating[fi].id], AppModel.shared.showPanels { win.orderFront(nil) }
        case nil:
            break
        }
        focusRequest = (id, focusRequest.tick + 1)
    }

    func select(_ id: String) {
        var w = current
        w.select(id)
        current = w
    }

    func close(_ id: String) {
        var w = current
        w.remove(id)
        current = w
        if flyout?.panelID == id { closeFlyout() }
        evictHost(id)
    }

    func closeGroup(_ gid: String) {
        guard let g = current.group(gid) else { return }
        var w = current
        for p in g.panels { w.remove(p) }
        current = w
        for p in g.panels { evictHost(p) }
    }

    /// Floats a panel in its own window (at `frame`, or beside the main window).
    func float(_ id: String, frame: CGRect? = nil) {
        floatPanels([id], frame: frame)
    }

    func floatPanels(_ ids: [String], frame: CGRect? = nil, active: String? = nil) {
        let size = frame == nil ? floatingSize(for: ids) : DockMetrics.defaultFloatSize
        var w = current
        w.float(ids, frame: frame ?? defaultFloatFrame(size: size), active: active)
        current = w
        if let gid = ids.first.flatMap({ current.group(containing: $0)?.id }), let win = windows[gid], AppModel.shared.showPanels { win.orderFront(nil) }
    }

    func dock(_ id: String, secondary: Bool = false) {
        var w = current
        w.dockAtDefault(id, secondary: secondary)
        w.select(id)
        current = w
    }

    func move(_ id: String, toGroup gi: Int, secondary: Bool) {
        var w = current
        let ci = secondary ? w.columns.count - 2 : w.columns.count - 1
        if ci >= 0, gi < w.columns[ci].groups.count, gi >= 0 {
            w.move([id], to: .tab(group: w.columns[ci].groups[gi].id, index: .max))
        } else if ci >= 0 {
            w.move([id], to: .columnEnd(column: w.columns[ci].id))
        } else {
            w.dockAtDefault(id, secondary: secondary)
        }
        current = w
    }

    /// Moves panels to a drop target. Returns false if nothing changed.
    @discardableResult
    func perform(_ ids: [String], to target: DockDropTarget, active: String? = nil, height: CGFloat? = nil) -> Bool {
        var w = current
        guard w.move(ids, to: target, active: active, height: height) else { return false }
        current = w
        return true
    }

    func setCollapsed(group gid: String, _ on: Bool) {
        var w = current
        w.setCollapsed(gid, on)
        current = w
    }

    func toggleCollapsed(group gid: String) {
        guard let g = current.group(gid) else { return }
        setCollapsed(group: gid, !g.collapsed)
    }

    func setIconic(column cid: String, _ on: Bool) {
        closeFlyout()
        var w = current
        w.setIconic(cid, on)
        current = w
    }

    func setColumnWidth(column cid: String, _ width: CGFloat) {
        var w = current
        w.setWidth(cid, width)
        current = w
    }

    func resizeGroups(column cid: String, divider gi: Int, delta: CGFloat, actual: [CGFloat]) {
        var w = current
        if w.resizeGroups(column: cid, divider: gi, delta: delta, actual: actual) { current = w }
    }

    // MARK: Floating windows

    var screens: [CGRect] { Self.screensOverride ?? NSScreen.screens.map(\.visibleFrame) }
    private var anchorFrame: CGRect? { AppActions.canvas?.window?.frame ?? NSApp.mainWindow?.frame }

    /// Brings floating windows that are off every screen (unplugged display, changed resolution) back on screen.
    func recoverLostPanels() {
        var w = current
        let moved = w.recoverFloating(screens: screens, anchor: anchorFrame)
        if !moved.isEmpty { current = w }
    }

    /// Window size for panels floated out of the dock: their column's width (240…420 pt; 280 for a panel that isn't
    /// docked), wider if a panel needs it, and as tall as the tallest panel's content (380 pt for panels that scroll their
    /// own lists), within the screen.
    func floatingSize(for ids: [String]) -> CGSize {
        guard let first = ids.first else { return DockMetrics.defaultFloatSize }
        var width = DockMetrics.defaultFloatSize.width
        if case .docked(let ci, _)? = current.path(ofPanel: first) { width = min(max(current.columns[ci].width, 240), 420) }
        let chrome = FloatingPanel.frameHeight(forContentHeight: 0)
        let base = CGSize(width: width, height: DockMetrics.defaultFloatSize.height - chrome)
        let maxHeight = min(640, (screens.first?.height ?? 900) * 0.8) - chrome
        var size = CGSize(width: 0, height: DockMetrics.minFloatSize.height)
        for id in ids.prefix(8) {
            let s = PanelSizing.windowSize(id, base: base, minHeight: DockMetrics.minFloatSize.height, maxHeight: maxHeight)
            size = CGSize(width: max(size.width, s.width), height: max(size.height, s.height))
        }
        return CGSize(width: size.width, height: size.height + chrome)
    }

    func defaultFloatFrame(size: CGSize) -> CGRect {
        let scr = screens
        let anchor = anchorFrame.flatMap { a in scr.contains { $0.intersects(a) } ? a : nil } ?? scr.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screen = scr.first { $0.intersects(anchor) } ?? anchor
        let k = CGFloat(current.floating.count % 6) * 24
        let f = CGRect(x: anchor.maxX - size.width - 340 - k, y: anchor.maxY - size.height - 90 - k, width: size.width, height: size.height)
        return WorkspaceGeometry.clamp(f, into: screen)
    }

    /// The window frame a floating group is shown with (a collapsed group keeps its top edge and shows only its tab bar).
    func displayFrame(_ fg: FloatingGroup) -> CGRect {
        let f = fg.frame ?? defaultFloatFrame(size: DockMetrics.defaultFloatSize)
        guard fg.group.collapsed else { return f }
        let h = FloatingPanel.frameHeight(forContentHeight: DockMetrics.tabBarHeight)
        return CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h)
    }

    func syncWindows() {
        guard managesWindows else { return }
        let show = AppModel.shared.showPanels
        var live = Set<String>()
        for fg in current.floating {
            live.insert(fg.id)
            let win: FloatingPanel
            if let w = windows[fg.id] { win = w } else {
                win = FloatingPanel(groupID: fg.id)
                windows[fg.id] = win
            }
            win.update(fg.group)
            let frame = displayFrame(fg)
            if !win.isUserMoving, !win.frame.equalTo(frame, tolerance: 0.5) { win.setFrameSilently(frame) }
            if show { if !win.isVisible { win.orderFront(nil) } } else if win.isVisible { win.orderOut(nil) }
        }
        for (id, w) in windows where !live.contains(id) {
            windows[id] = nil
            w.dismiss()
        }
    }

    /// A floating window was moved or resized by the user.
    func floatingWindowChanged(_ gid: String, frame: CGRect) {
        guard let fi = current.floating.firstIndex(where: { $0.id == gid }) else { return }
        var f = frame
        if current.floating[fi].group.collapsed, let old = current.floating[fi].frame {
            f = CGRect(x: frame.minX, y: frame.maxY - old.height, width: frame.width, height: old.height)
        }
        guard current.floating[fi].frame != f else { return }
        liveDepth += 1
        var w = current
        w.floating[fi].frame = f
        current = w
        liveDepth -= 1
        scheduleSave()
    }

    func floatingWindow(containing id: String) -> FloatingPanel? {
        current.floating.first { $0.group.panels.contains(id) }.flatMap { windows[$0.id] }
    }

    // MARK: Panel content

    /// The hosting view of a panel's SwiftUI content. One per panel, kept while the panel is open, so switching tabs or
    /// moving a panel keeps its state (scroll position, expanded sections).
    func host(_ id: String) -> NSView {
        if let h = hosts[id] { return h }
        let h = NSHostingView(rootView: PanelContentRoot(id: id))
        h.sizingOptions = []
        h.setAccessibilityLabel(tr(PanelRegistry.def(id)?.title ?? id))
        hosts[id] = h
        return h
    }

    func hasHost(_ id: String) -> Bool { hosts[id] != nil }

    private func evictHost(_ id: String) {
        guard let h = hosts[id] else { return }
        if current.contains(id) { return }
        h.removeFromSuperview()
        hosts[id] = nil
    }

    // MARK: Docked columns

    /// The dock that shows the columns (the most recently attached one: there is one main window; tests add their own).
    @ObservationIgnored private(set) weak var activeDock: DockAreaView?

    func register(_ d: DockAreaView) {
        docks.add(d)
        if activeDock !== d {
            let old = activeDock
            activeDock = d
            old?.teardownColumns()
        }
        if managesWindows && !started { start() }
    }

    func unregister(_ d: DockAreaView) {
        docks.remove(d)
        if activeDock === d {
            activeDock = docks.allObjects.last { $0.window != nil }
            activeDock?.reload()
        }
    }

    var dockViews: [DockAreaView] { docks.allObjects }

    /// Opens the panel of an icon column in a pop-over beside its icon.
    func showFlyout(_ id: String) {
        for d in docks.allObjects where d.window != nil {
            if let b = d.iconButton(for: id) { DockFlyout.show(id, from: b); return }
        }
    }

    func closeFlyout() {
        flyout?.close()
        flyout = nil
    }

    // MARK: Windows that hold panels (PendingEdits)

    /// True for floating panel windows and the pop-over of an icon column.
    static func isPanelWindow(_ w: NSWindow) -> Bool {
        if w is FloatingPanel { return true }
        if let f = shared.flyout, f.window === w { return true }
        return false
    }

    /// True when `p` (window coordinates) is on dock chrome — a tab bar, column header, divider or panel icon. Clicks there
    /// arrange panels; they are not clicks in a panel's content.
    static func isDockChrome(_ w: NSWindow, _ p: CGPoint) -> Bool {
        guard let cv = w.contentView else { return false }
        let q = cv.superview.map { $0.convert(p, from: nil) } ?? p
        var v = cv.hitTest(q)
        while let x = v {
            if x is DockChrome { return true }
            v = x.superview
        }
        return false
    }

    /// After arranging panels (or finishing a text entry in a floating panel) the canvas gets keyboard focus back, so
    /// single-key tool shortcuts and ⌘Z act on the document again.
    func returnFocusToCanvas() {
        guard AppModel.shared.dialog == nil, let c = AppActions.canvas, let w = c.window else { return }
        if let k = NSApp.keyWindow, k is FloatingPanel, k !== w { w.makeKey() }
        if w.firstResponder !== c { w.makeFirstResponder(c) }
    }

    // MARK: Observers

    private func start() {
        guard !started else { return }
        started = true
        recoverLostPanels()
        syncWindows()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.recoverLostPanels()
        }
        // a text entry in a floating panel ends (Return, Tab out, click elsewhere): keys go back to the canvas
        nc.addObserver(forName: NSControl.textDidEndEditingNotification, object: nil, queue: .main) { [weak self] n in
            guard let win = (n.object as? NSView)?.window as? FloatingPanel else { return }
            DispatchQueue.main.async {
                if NSApp.keyWindow === win, !(win.firstResponder is NSText) { self?.returnFocusToCanvas() }
            }
        }
        track({ AppModel.shared.showPanels }) { [weak self] in self?.syncWindows() }
        track({ AppModel.shared.prefs.theme }) { [weak self] in self?.refreshChrome() }
        // interface language: tab titles, tool tips and floating-panel titles in the new language
        nc.addObserver(forName: L10n.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshLanguage() }
    }

    /// The language changed: chrome is drawn / labelled again (panel content is SwiftUI and follows by itself).
    func refreshLanguage() {
        for d in docks.allObjects { d.reload(); d.refreshTheme(); d.layoutSubtreeIfNeeded() }
        for w in windows.values { w.refreshTitle(); w.refreshTheme() }
    }

    private func track<T>(_ read: @escaping () -> T, _ changed: @escaping () -> Void) {
        withObservationTracking { _ = read() } onChange: {
            DispatchQueue.main.async { [weak self] in
                changed()
                self?.track(read, changed)
            }
        }
    }

    /// Theme changed: redraw the chrome.
    func refreshChrome() {
        for d in docks.allObjects { d.refreshTheme() }
        for w in windows.values { w.refreshTheme() }
    }
}

/// A panel's SwiftUI content, themed like the rest of the window.
struct PanelContentRoot: View {
    let id: String
    var body: some View {
        let scheme = Theme.colorScheme
        PanelScroller {
            Self.panel(id)
        }
        .background(Theme.panelBG)
        .environment(\.colorScheme, scheme)
        .font(Theme.font)
        .l10nRoot()   // literal Texts follow a language switch
    }

    /// Every panel sits in a `PanelScroller` (the self tests look for it).
    static let scrolls = true

    /// The panel's own view (what `PanelScroller` sizes and, when it doesn't fit, scrolls).
    @ViewBuilder static func panel(_ id: String) -> some View {
        if let d = PanelRegistry.def(id) { d.make() } else { Text("Panel not available").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
    }
}

// MARK: - Window menu

struct PanelVisibilityMenu: View {
    @Bindable var ws = WorkspaceManager.shared
    var body: some View {
        ForEach(PanelRegistry.defs.sorted { $0.title < $1.title }, id: \.id) { d in
            Toggle(d.title, isOn: Binding(get: { ws.isVisible(d.id) }, set: { _ in ws.menuToggle(d.id) }))
        }
    }
}

struct WorkspaceMenu: View {
    @Bindable var ws = WorkspaceManager.shared
    var body: some View {
        ForEach(Workspace.builtIn, id: \.name) { w in row(w.name) }
        if !ws.saved.isEmpty {
            Divider()
            ForEach(ws.saved, id: \.name) { w in row(w.name) }
        }
        Divider()
        Button("Reset \(ws.current.name)") { ws.reset() }
        Button("New Workspace…") { WorkspaceMenu.newWorkspace() }
        Menu("Delete Workspace") {
            ForEach(ws.saved, id: \.name) { w in Button(tr(w.name)) { ws.deleteSaved(w.name) } }
        }.disabled(ws.saved.isEmpty)
        Divider()
        Button("Bring Panels Back On Screen") { ws.recoverLostPanels(); ws.syncWindows() }
    }

    private func row(_ name: String) -> some View {
        Toggle(tr(name), isOn: Binding(get: { ws.current.name == name }, set: { _ in ws.switchTo(name) }))
    }

    static func newWorkspace() {
        let a = NSAlert()
        a.messageText = tr("New Workspace")
        a.informativeText = tr("Saves the current arrangement of panels, columns and floating windows.")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        f.stringValue = "My Workspace"
        a.accessoryView = f
        a.addButton(withTitle: tr("Save")); a.addButton(withTitle: tr("Cancel"))
        if UIBlock.run(a) == .alertFirstButtonReturn, !f.stringValue.isEmpty { WorkspaceManager.shared.saveCurrent(as: f.stringValue) }
    }
}
