import SwiftUI
import ImageCratCore

struct ToolsPalette: View {
    @Bindable var app = AppModel.shared

    var body: some View {
        VStack(spacing: 1) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(Array(ToolKind.groups.enumerated()), id: \.offset) { i, group in
                        ToolGroupButton(index: i, group: group)
                        if ToolbarConfig.dividerAfter(group) {
                            Rectangle().fill(Theme.divider).frame(width: 26, height: 1).padding(.vertical, 3)
                        }
                    }
                    ExtraToolsSlot()
                }
                .padding(.top, 6)
            }
            Spacer(minLength: 4)
            ColorSwatchesControl()
                .padding(.bottom, 6)
            Button { AppActions.toggleQuickMask() } label: {
                Image(systemName: app.activeDocument?.quickMask == true ? "circle.dashed.inset.filled" : "circle.dashed")
                    .font(.system(size: 13))
                    .foregroundStyle(app.activeDocument?.quickMask == true ? Color.red.opacity(0.9) : Theme.textDim)
                    .frame(width: 30, height: 24)
            }
            .buttonStyle(.plain)
            .help("Edit in Quick Mask Mode (Q)")
            .padding(.bottom, 8)
        }
    }
}

struct ToolGroupButton: View {
    let index: Int
    let group: [ToolKind]
    @Bindable var app = AppModel.shared
    @State private var hover = false
    @State private var flyout = false

    var shown: ToolKind { group.contains(app.tool) ? app.tool : (app.groupSelection[index] ?? group[0]) }
    var active: Bool { group.contains(app.tool) }
    var hasMore: Bool { group.count > 1 }

    /// Bottom-right corner of the 32×28 button (the triangle) opens the flyout.
    private func inCorner(_ p: CGPoint) -> Bool { p.x >= 20 && p.y >= 15 }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: shown.symbol)
                .font(.system(size: 14))
                .frame(width: 32, height: 28)
                .foregroundStyle(active ? Color.white : Theme.text)
                .background(RoundedRectangle(cornerRadius: 5).fill(active ? Theme.toolActive : (hover ? Theme.hover : .clear)))
            if hasMore {
                Path { p in
                    p.move(to: CGPoint(x: 6, y: 0)); p.addLine(to: CGPoint(x: 6, y: 6)); p.addLine(to: CGPoint(x: 0, y: 6)); p.closeSubpath()
                }
                .fill(flyout ? Theme.accent : Theme.textDim)
                .frame(width: 6, height: 6)
                .padding(2)
            }
        }
        .frame(width: 32, height: 28)
        .contentShape(Rectangle())
        .onTapGesture(count: 1, coordinateSpace: .local) { p in
            if hasMore && inCorner(p) { flyout = true } else {
                app.tool = shown
                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { ZoomController.toolDoubleClicked(shown) }   // Hand: fit, Zoom: 100%
            }
        }
        .onLongPressGesture(minimumDuration: 0.35) { if hasMore { flyout = true } }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(shown.displayName)
        .accessibilityAction { app.tool = shown }
        .accessibilityAction(named: "Show More Tools") { if hasMore { flyout = true } }
        .help("\(shown.displayName) (\(shown.shortcut))" + (hasMore ? " — click the corner or hold for more tools" : ""))
        .onHover { hover = $0 }
        .popover(isPresented: $flyout, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(group) { t in
                    ToolFlyoutRow(tool: t, selected: t == shown) {
                        app.tool = t
                        app.groupSelection[index] = t
                        flyout = false
                    }
                }
            }
            .padding(5)
            .frame(minWidth: 230)
        }
        .contextMenu {
            ForEach(group) { t in
                Button { app.tool = t; app.groupSelection[index] = t } label: {
                    Label("\(t.displayName)   \(t.shortcut)", systemImage: t.symbol)
                }
            }
        }
    }
}

struct ToolFlyoutRow: View {
    let tool: ToolKind
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    // A button rather than a tap gesture: the row is then an accessible, pressable element (VoiceOver and UI automation
    // only saw static text and could not choose a tool from the flyout).
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Rectangle().fill(selected ? Theme.text : .clear).frame(width: 3, height: 14)
                Image(systemName: tool.symbol).frame(width: 18)
                Text(tool.displayName)
                Spacer(minLength: 16)
                Text(tool.shortcut).foregroundStyle(Theme.textDim)
            }
            .font(Theme.font)
            .foregroundStyle(hover ? Color.white : Theme.text)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? Theme.accent : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.displayName)
        .onHover { hover = $0 }
    }
}

struct ColorSwatchesControl: View {
    @Bindable var app = AppModel.shared
    @State private var editFG = false
    @State private var editBG = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: app.background.nsColor))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.8), lineWidth: 1))
                .frame(width: 20, height: 20)
                .offset(x: 12, y: 12)
                .onTapGesture { editBG = true }
                .popover(isPresented: $editBG) { ColorPickerView(color: $app.background, title: "Background Color").colorPopoverContent() }
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: app.foreground.nsColor))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.white.opacity(0.8), lineWidth: 1))
                .frame(width: 20, height: 20)
                .onTapGesture { editFG = true }
                .popover(isPresented: $editFG) { ColorPickerView(color: $app.foreground, title: "Foreground Color").colorPopoverContent() }
            Button { app.swapColors() } label: {
                Image(systemName: "arrow.up.left.arrow.down.right").font(.system(size: 7)).foregroundStyle(Theme.textDim)
            }.buttonStyle(.plain).offset(x: 24, y: -2).help("Switch Colors (X)")
            Button { app.resetColors() } label: {
                ZStack {
                    Rectangle().fill(.white).frame(width: 6, height: 6).offset(x: 2, y: 2)
                    Rectangle().fill(.black).frame(width: 6, height: 6).overlay(Rectangle().stroke(.white, lineWidth: 0.5))
                }
            }.buttonStyle(.plain).offset(x: -2, y: 26).help("Default Colors (D)")
        }
        .frame(width: 34, height: 36)
    }
}

// MARK: - Color picker

struct ColorPickerView: View {
    @Binding var color: RGBA
    var title: String = "Color Picker"
    var showAlpha = false
    @State private var hue: Double = 0
    @State private var sat: Double = 0
    @State private var bri: Double = 0
    @State private var hexText = ""
    @State private var original: RGBA = .black
    @Environment(\.panelWidth) private var panelWidth

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.fontBold).foregroundStyle(Theme.text)
            if panelWidth < 360 {
                // in a panel (Properties of a fill layer): the square sized to the column, the values under it
                let side = max(110, min(200, panelWidth - 20 - 10 - 18))
                HStack(alignment: .top, spacing: 10) {
                    SBSquare(hue: hue, sat: $sat, bri: $bri) { update() }
                        .frame(width: side, height: side)
                    HueStrip(hue: $hue) { update() }
                        .frame(width: 18, height: side)
                }
                WrappingHStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) { swatches; hexField; sampleButton }
                    VStack(alignment: .leading, spacing: 6) { hsbFields }
                    VStack(alignment: .leading, spacing: 6) { rgbFields }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    SBSquare(hue: hue, sat: $sat, bri: $bri) { update() }
                        .frame(width: 200, height: 200)
                    HueStrip(hue: $hue) { update() }
                        .frame(width: 18, height: 200)
                    VStack(alignment: .leading, spacing: 6) {
                        swatches
                        Group {
                            hsbFields
                            rgbFields
                        }
                        hexField
                        sampleButton
                    }
                }
            }
            if showAlpha {
                ValueSlider(label: "Opacity", value: Binding(get: { color.a * 100 }, set: { color.a = $0 / 100 }), range: 0...100, unit: "%")
            }
            let recents = AppModel.shared.recentColors
            if !recents.isEmpty {
                WrappingHStack(spacing: 3, lineSpacing: 3) {
                    ForEach(Array(recents.prefix(14).enumerated()), id: \.offset) { _, c in
                        Rectangle().fill(Color(nsColor: c.nsColor)).frame(width: 16, height: 16)
                            .overlay(Rectangle().stroke(Color(white: 0.3), lineWidth: 0.5))
                            .onTapGesture { color = c; syncFromColor() }
                    }
                }
            }
        }
        .onAppear { original = color; syncFromColor() }
        // a colour set from outside (sampled from the image, undo) moves the square, strip and fields along
        .onChange(of: color) { _, c in if RGBA(h: hue, s: sat, v: bri, a: c.a) != c { syncFromColor() } }
        .onDisappear { AppModel.shared.pushRecent(color) }
    }

    /// New colour over the original (click it to go back).
    private var swatches: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: color.nsColor)).frame(width: 60, height: 30)
            Rectangle().fill(Color(nsColor: original.nsColor)).frame(width: 60, height: 30)
                .onTapGesture { color = original; syncFromColor() }
        }.overlay(Rectangle().stroke(Color(white: 0.4), lineWidth: 0.5))
    }

    @ViewBuilder private var hsbFields: some View {
        channelField("H", Binding(get: { hue * 360 }, set: { hue = clamp($0, 0, 360) / 360; update() }), "°")
        channelField("S", Binding(get: { sat * 100 }, set: { sat = clamp($0, 0, 100) / 100; update() }), "%")
        channelField("B", Binding(get: { bri * 100 }, set: { bri = clamp($0, 0, 100) / 100; update() }), "%")
    }

    @ViewBuilder private var rgbFields: some View {
        channelField("R", Binding(get: { Double(color.r8) }, set: { color.r = clamp($0, 0, 255) / 255; syncFromColor() }), "")
        channelField("G", Binding(get: { Double(color.g8) }, set: { color.g = clamp($0, 0, 255) / 255; syncFromColor() }), "")
        channelField("B", Binding(get: { Double(color.b8) }, set: { color.b = clamp($0, 0, 255) / 255; syncFromColor() }), "")
    }

    private var hexField: some View {
        HStack(spacing: 3) {
            Text("#").font(Theme.font).foregroundStyle(Theme.textDim)
            TextField("", text: $hexText)
                .textFieldStyle(.plain).font(Theme.mono)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .frame(width: 60)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
                .onSubmit { if let c = RGBA(hex: hexText) { color = c.withAlpha(color.a); syncFromColor() } }
        }
    }

    private var sampleButton: some View {
        Button {
            NSColorSampler().show { c in
                if let c { color = RGBA(nsColor: c); syncFromColor() }
            }
        } label: { Label("Sample", systemImage: "eyedropper") }
            .buttonStyle(PanelButtonStyle())
    }

    private func channelField(_ l: String, _ b: Binding<Double>, _ unit: String) -> some View {
        HStack(spacing: 3) {
            Text(l).font(Theme.font).foregroundStyle(Theme.textDim).frame(width: 12)
            NumberField(label: "", value: b, width: 38)
            Text(unit).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).frame(width: 12, alignment: .leading)
        }
    }

    private func update() {
        let c = RGBA(h: hue, s: sat, v: bri, a: color.a)
        color = c
        hexText = c.hex
    }

    private func syncFromColor() {
        let h = color.hsb
        if h.s > 0.001 && h.b > 0.001 { hue = h.h }
        sat = h.s
        bri = h.b
        hexText = color.hex
    }
}

struct SBSquare: View {
    let hue: Double
    @Binding var sat: Double
    @Binding var bri: Double
    var onChange: () -> Void

    var body: some View {
        GeometryReader { g in
            ZStack {
                Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
                LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                Circle().stroke(Color.white, lineWidth: 1.5).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 0.5).frame(width: 12, height: 12))
                    .position(x: sat * g.size.width, y: (1 - bri) * g.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                sat = clamp(v.location.x / g.size.width, 0, 1)
                bri = clamp(1 - v.location.y / g.size.height, 0, 1)
                onChange()
            })
        }
        .clipShape(Rectangle())
    }
}

struct HueStrip: View {
    @Binding var hue: Double
    var onChange: () -> Void

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                LinearGradient(colors: stride(from: 1.0, through: 0, by: -1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) }, startPoint: .top, endPoint: .bottom)
                Rectangle().stroke(Color.white, lineWidth: 1.5).frame(height: 4)
                    .offset(y: (1 - hue) * g.size.height - 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hue = clamp(1 - v.location.y / g.size.height, 0, 0.9999)
                onChange()
            })
        }
    }
}

/// Small swatch that opens a color picker popover.
struct ColorWell: View {
    @Binding var color: RGBA
    var size: CGFloat = 22
    var showAlpha = false
    var onCommit: (() -> Void)? = nil
    @State private var open = false

    var body: some View {
        ZStack {
            CheckerBackground(size: 4)
            Rectangle().fill(Color(nsColor: color.nsColor))
        }
        .frame(width: size * 1.6, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(white: 0.45), lineWidth: 0.5))
        .onTapGesture { open = true }
        .popover(isPresented: $open) {
            ColorPickerView(color: $color, showAlpha: showAlpha).colorPopoverContent()
                .onDisappear { onCommit?() }
        }
    }
}
