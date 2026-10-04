import SwiftUI
import UniformTypeIdentifiers

struct PanelTab: Identifiable {
    let id: String
    let title: String
    let content: AnyView
    init<V: View>(_ title: String, @ViewBuilder content: () -> V) {
        self.id = title
        self.title = title
        self.content = AnyView(content())
    }
    init<V: View>(id: String, title: String, @ViewBuilder content: () -> V) {
        self.id = id
        self.title = title
        self.content = AnyView(content())
    }
}

struct PanelGroup: View {
    let tabs: [PanelTab]
    var groupIndex = 0
    var secondary = false
    @State private var selected: String = ""
    @State private var collapsed = false
    @Bindable private var ws = WorkspaceManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tabs) { t in
                    let active = (selected.isEmpty ? tabs.first?.id : selected) == t.id
                    Text(t.title)
                        .font(active ? Theme.fontBold : Theme.font)
                        .foregroundStyle(active ? Theme.text : Theme.textDim)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(active ? Theme.panelBG : Color.clear)
                        .overlay(Rectangle().fill(active ? Theme.accent : .clear).frame(height: 2), alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = t.id; collapsed = false }
                        .contextMenu {
                            Button("Float “\(t.title)” in Window") { ws.float(t.id) }
                            Button("Move to \(secondary ? "Main" : "Secondary") Column") { ws.dock(t.id, secondary: !secondary) }
                            if groupIndex > 0 { Button("Move to Group Above") { ws.move(t.id, toGroup: groupIndex - 1, secondary: secondary) } }
                            Button("Move to Group Below") { ws.move(t.id, toGroup: groupIndex + 1, secondary: secondary) }
                            Divider()
                            Button("Close") { ws.close(t.id) }
                        }
                        .onDrag { NSItemProvider(object: ("panel:" + t.id) as NSString) }
                }
                Spacer()
                Button { withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.textFaint)
                        .frame(width: 22, height: 22)
                }.buttonStyle(.plain)
            }
            .background(Theme.panelHeader)
            if !collapsed {
                let cur = tabs.first { $0.id == (selected.isEmpty ? tabs.first?.id : selected) }
                cur?.content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxHeight: collapsed ? 26 : .infinity)
        .onChange(of: ws.focusRequest.tick) { _, _ in
            if tabs.contains(where: { $0.id == ws.focusRequest.id }) { selected = ws.focusRequest.id; collapsed = false }
        }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                guard let s = obj as? String, s.hasPrefix("panel:") else { return }
                let id = String(s.dropFirst(6))
                DispatchQueue.main.async {
                    if !tabs.contains(where: { $0.id == id }) { ws.move(id, toGroup: groupIndex, secondary: secondary); selected = id }
                }
            }
            return true
        }
    }
}

