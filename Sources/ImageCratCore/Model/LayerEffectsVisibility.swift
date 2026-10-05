import Foundation

/// Visibility of individual layer effects, Photoshop style.
///
/// Every effect has two flags:
/// - `enabled`: the effect is drawn (and is part of the style). All rendering and export code looks at this flag only.
/// - `isHidden`: the effect is part of the style but switched off with its eye in the Layers panel. Its settings are
///   kept and it stays listed (with a closed eye) until it is shown again. Only meaningful while `enabled` is false.
///
/// So "listed in the Layers panel" = `enabled || isHidden`. Unchecking an effect in the Layer Style dialog removes it
/// from the list (both false, settings still kept in the struct); only Clear Layer Style resets the settings.
/// The layer-level `LayerEffects.enabled` is the master switch (the "Effects" eye, Hide All Effects); it leaves the
/// individual flags alone.
package protocol LayerEffectItem {
    var enabled: Bool { get set }
    var isHidden: Bool { get set }
}

extension LayerEffectItem {
    /// Part of the style (listed in the Layers panel), shown or hidden.
    package var isListed: Bool { enabled || isHidden }
    /// The eye: shows / hides a listed effect without touching its settings.
    package mutating func setShown(_ on: Bool) {
        guard isListed else { return }      // (the eye never adds an effect to the style)
        if on { enabled = true; isHidden = false } else { enabled = false; isHidden = true }
    }
    /// The Layer Style dialog's checkbox: adds the effect to / removes it from the style (settings stay in the struct).
    package mutating func setInStyle(_ on: Bool) { enabled = on; isHidden = false }
}

extension ShadowEffect: LayerEffectItem {}
extension GlowEffect: LayerEffectItem {}
extension BevelEffect: LayerEffectItem {}
extension SatinEffect: LayerEffectItem {}
extension ColorOverlayEffect: LayerEffectItem {}
extension GradientOverlayEffect: LayerEffectItem {}
extension PatternOverlayEffect: LayerEffectItem {}
extension StrokeEffect: LayerEffectItem {}

/// The effects of a layer style in Photoshop's Layers panel order (top of the stack first).
package enum EffectKind: String, CaseIterable {
    case bevel, stroke, innerShadow, innerGlow, satin, colorOverlay, gradientOverlay, patternOverlay, outerGlow, dropShadow

    /// Also the Layer Style dialog's section title (`StyleSection.rawValue`).
    package var displayName: String {
        switch self {
        case .bevel: return "Bevel & Emboss"
        case .stroke: return "Stroke"
        case .innerShadow: return "Inner Shadow"
        case .innerGlow: return "Inner Glow"
        case .satin: return "Satin"
        case .colorOverlay: return "Color Overlay"
        case .gradientOverlay: return "Gradient Overlay"
        case .patternOverlay: return "Pattern Overlay"
        case .outerGlow: return "Outer Glow"
        case .dropShadow: return "Drop Shadow"
        }
    }
}

/// One effect instance of a style: kind + instance (0 = primary, 1… = the extra instances added with "+").
package struct EffectSlot: Hashable {
    package var kind: EffectKind
    package var index: Int = 0
    package init(kind: EffectKind, index: Int = 0) {
        self.kind = kind; self.index = index
    }
}

extension LayerEffects {
    /// The layer has a style: at least one effect listed, shown or hidden (the Layers panel's "fx"). `hasAny` stays
    /// "at least one effect is drawn".
    package var hasStyle: Bool { !listedSlots.isEmpty }

    /// Instance count of a kind (the primary plus the extra instances).
    package func instanceCount(_ k: EffectKind) -> Int {
        switch k {
        case .dropShadow: return 1 + extraDropShadows.count
        case .innerShadow: return 1 + extraInnerShadows.count
        case .colorOverlay: return 1 + extraColorOverlays.count
        case .gradientOverlay: return 1 + extraGradientOverlays.count
        case .stroke: return 1 + extraStrokes.count
        default: return 1
        }
    }

    /// Effect instance `s`, nil if there is no such instance.
    package func item(_ s: EffectSlot) -> (any LayerEffectItem)? {
        func pick<T: LayerEffectItem>(_ primary: T, _ extras: [T]) -> T? {
            s.index == 0 ? primary : (extras.indices.contains(s.index - 1) ? extras[s.index - 1] : nil)
        }
        switch s.kind {
        case .bevel: return s.index == 0 ? bevel : nil
        case .stroke: return pick(stroke, extraStrokes)
        case .innerShadow: return pick(innerShadow, extraInnerShadows)
        case .innerGlow: return s.index == 0 ? innerGlow : nil
        case .satin: return s.index == 0 ? satin : nil
        case .colorOverlay: return pick(colorOverlay, extraColorOverlays)
        case .gradientOverlay: return pick(gradientOverlay, extraGradientOverlays)
        case .patternOverlay: return s.index == 0 ? patternOverlay : nil
        case .outerGlow: return s.index == 0 ? outerGlow : nil
        case .dropShadow: return pick(dropShadow, extraDropShadows)
        }
    }

    /// Edits effect instance `s` (no-op if there is no such instance).
    package mutating func modify(_ s: EffectSlot, _ body: (inout any LayerEffectItem) -> Void) {
        func edit<T: LayerEffectItem>(_ primary: WritableKeyPath<LayerEffects, T>, _ extras: WritableKeyPath<LayerEffects, [T]>?) {
            if s.index == 0 {
                var v: any LayerEffectItem = self[keyPath: primary]
                body(&v)
                if let t = v as? T { self[keyPath: primary] = t }
            } else if let x = extras, self[keyPath: x].indices.contains(s.index - 1) {
                var v: any LayerEffectItem = self[keyPath: x][s.index - 1]
                body(&v)
                if let t = v as? T { self[keyPath: x][s.index - 1] = t }
            }
        }
        switch s.kind {
        case .bevel: edit(\.bevel, nil)
        case .stroke: edit(\.stroke, \.extraStrokes)
        case .innerShadow: edit(\.innerShadow, \.extraInnerShadows)
        case .innerGlow: edit(\.innerGlow, nil)
        case .satin: edit(\.satin, nil)
        case .colorOverlay: edit(\.colorOverlay, \.extraColorOverlays)
        case .gradientOverlay: edit(\.gradientOverlay, \.extraGradientOverlays)
        case .patternOverlay: edit(\.patternOverlay, nil)
        case .outerGlow: edit(\.outerGlow, nil)
        case .dropShadow: edit(\.dropShadow, \.extraDropShadows)
        }
    }

    /// Every instance of every kind, panel order.
    package var allSlots: [EffectSlot] { EffectKind.allCases.flatMap { k in (0..<instanceCount(k)).map { EffectSlot(kind: k, index: $0) } } }

    /// The effects the Layers panel lists under the layer (shown or hidden), panel order.
    package var listedSlots: [EffectSlot] { allSlots.filter { item($0)?.isListed == true } }

    /// Whether listed effect `s` is drawn (its own eye; the master switch is separate).
    package func isShown(_ s: EffectSlot) -> Bool { item(s)?.enabled == true }

    /// The eye of one effect: hides / shows it, keeping its settings.
    package mutating func setShown(_ s: EffectSlot, _ on: Bool) { modify(s) { $0.setShown(on) } }

    /// Every listed effect hidden / shown (the individual eyes; the master switch is separate).
    package mutating func setAllShown(_ on: Bool) { for s in listedSlots { setShown(s, on) } }

    /// Listed effects that are drawn when the master switch is on.
    package var shownCount: Int { listedSlots.filter { isShown($0) }.count }
}

// MARK: - Adding effects to an existing style

extension LayerEffects {
    /// Adds effect `s` to the style (the Layer Style dialog's checkbox, the fx menu): it is listed and shown, and the
    /// Effects of the layer are shown too, as in Photoshop: a style imported with its Effects hidden would otherwise
    /// swallow the new effect. An effect that was not in the style yet and uses Global Light starts with the light's
    /// direction as its own angle, so unchecking Use Global Light later keeps it pointing the same way.
    package mutating func addToStyle(_ s: EffectSlot, light: GlobalLight) {
        let wasListed = item(s)?.isListed == true
        modify(s) { $0.setInStyle(true) }
        enabled = true
        if !wasListed { adoptGlobalLight(s, light) }
    }

    /// Copies the Global Light into the own angle (and altitude) of effect `s` if it uses Global Light.
    package mutating func adoptGlobalLight(_ s: EffectSlot, _ light: GlobalLight) {
        guard light.angle.isFinite, light.altitude.isFinite else { return }
        modify(s) { e in
            if var x = e as? ShadowEffect, x.useGlobalLight { x.angle = light.angle; e = x }
            if var b = e as? BevelEffect, b.useGlobalLight { b.angle = light.angle; b.altitude = light.altitude; e = b }
        }
    }

    /// Removes effect instance `s` from the style: an extra instance goes away, a primary instance with extras is
    /// replaced by the first extra, any other effect is taken out of the style (settings kept, as the dialog's checkbox).
    package mutating func removeFromStyle(_ s: EffectSlot) {
        func drop<T: LayerEffectItem>(_ primary: WritableKeyPath<LayerEffects, T>, _ extras: WritableKeyPath<LayerEffects, [T]>) {
            if s.index > 0 {
                if self[keyPath: extras].indices.contains(s.index - 1) { self[keyPath: extras].remove(at: s.index - 1) }
            } else if !self[keyPath: extras].isEmpty {
                self[keyPath: primary] = self[keyPath: extras].removeFirst()
            } else {
                self[keyPath: primary].setInStyle(false)
            }
        }
        switch s.kind {
        case .dropShadow: drop(\.dropShadow, \.extraDropShadows)
        case .innerShadow: drop(\.innerShadow, \.extraInnerShadows)
        case .colorOverlay: drop(\.colorOverlay, \.extraColorOverlays)
        case .gradientOverlay: drop(\.gradientOverlay, \.extraGradientOverlays)
        case .stroke: drop(\.stroke, \.extraStrokes)
        default: modify(s) { $0.setInStyle(false) }
        }
    }

    /// Adds instance `s` of `other` to this style, keeping what is there: a kind that allows several instances gets one
    /// more (or fills its unused primary), any other kind is replaced. Shown or hidden as it was in `other`. Returns the
    /// slot the effect landed in.
    @discardableResult
    package mutating func insert(_ s: EffectSlot, from other: LayerEffects) -> EffectSlot? {
        guard other.item(s) != nil else { return nil }
        func put<T: LayerEffectItem>(_ primary: WritableKeyPath<LayerEffects, T>, _ extras: WritableKeyPath<LayerEffects, [T]>) -> EffectSlot {
            let v = s.index == 0 ? other[keyPath: primary] : other[keyPath: extras][s.index - 1]
            if !self[keyPath: primary].isListed { self[keyPath: primary] = v; return EffectSlot(kind: s.kind) }
            self[keyPath: extras].append(v)
            return EffectSlot(kind: s.kind, index: self[keyPath: extras].count)
        }
        switch s.kind {
        case .dropShadow: return put(\.dropShadow, \.extraDropShadows)
        case .innerShadow: return put(\.innerShadow, \.extraInnerShadows)
        case .colorOverlay: return put(\.colorOverlay, \.extraColorOverlays)
        case .gradientOverlay: return put(\.gradientOverlay, \.extraGradientOverlays)
        case .stroke: return put(\.stroke, \.extraStrokes)
        case .bevel: bevel = other.bevel
        case .innerGlow: innerGlow = other.innerGlow
        case .satin: satin = other.satin
        case .patternOverlay: patternOverlay = other.patternOverlay
        case .outerGlow: outerGlow = other.outerGlow
        }
        return EffectSlot(kind: s.kind)
    }
}
