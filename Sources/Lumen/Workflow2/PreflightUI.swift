import AppKit
import SwiftUI
import Observation
import ImageCratCore

/// Holds the last scan per document for the Preflight panel and the Clean Up dialog.
@Observable
final class PreflightModel {
    static let shared = PreflightModel()
    private(set) var reports: [UUID: PreflightReport] = [:]
    @ObservationIgnored private var scannedRevision: [UUID: Int] = [:]
    var expanded: Set<PreflightKind> = Set(PreflightKind.allCases)
    var showAllSizes = false

    func report(_ d: Document) -> PreflightReport? { reports[d.id] }

    @discardableResult
    func scan(_ d: Document, force: Bool = false) -> PreflightReport {
        if !force, let r = reports[d.id], scannedRevision[d.id] == d.revision { return r }
        var extras: [(String, Int)] = []
        let versions = VersionStore.shared.versions(d).count
        if versions > 0 { extras.append(("Saved Versions (\(versions))", VersionStore.shared.estimatedBytes(d))) }
        let r = Preflight.scan(d.committedState, proof: AppModel.shared.proof, extras: extras)
        reports[d.id] = r
        scannedRevision[d.id] = d.revision
        return r
    }

    func forget(_ id: UUID) { reports[id] = nil; scannedRevision[id] = nil }

    /// File ▸ Clean Up Document…: scan first so the dialog opens with current findings.
    static func showCleanUp() {
        guard let d = AppActions.doc else { return }
        AppActions.canvas?.commitCurrentTool()
        shared.scan(d)
        DialogRegistry.show("w2.cleanup")
    }
    var trackedDocuments: [UUID] { Array(reports.keys) }
}

/// Window ▸ Panels ▸ Preflight: document health with one-click fixes and the file-size breakdown.
struct PreflightPanel: View {
    @Bindable var app = AppModel.shared
    @Bindable var model = PreflightModel.shared
    var docOverride: Document? = nil

    var body: some View {
        if let d = docOverride ?? app.activeDocument {
            let rep = model.report(d)
            VStack(spacing: 0) {
                header(d, rep)
                Rectangle().fill(Theme.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let rep {
                            if rep.issues.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.green)
                                    Text("No issues found").foregroundStyle(Theme.text)
                                }.padding(10)
                            }
                            ForEach(rep.kinds) { k in kindSection(d, k, rep.issues(k)) }
                            sizeSection(d, rep)
                        } else {
                            Text("Scanning…").foregroundStyle(Theme.textFaint).padding(10)
                        }
                    }
                }
            }
            .font(Theme.font)
            .task(id: "\(d.id)-\(d.revision)") {
                try? await Task.sleep(nanoseconds: model.report(d) == nil ? 50_000_000 : 600_000_000)
                if !Task.isCancelled { model.scan(d) }
            }
        } else {
            Text("No document").foregroundStyle(Theme.textFaint).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    func header(_ d: Document, _ rep: PreflightReport?) -> some View {
        let n = rep?.issues.count ?? 0
        let worst = rep?.issues.map(\.kind.severity).max() ?? -1
        return HStack(spacing: 6) {
            Image(systemName: worst >= 2 ? "exclamationmark.octagon.fill" : (worst == 1 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                .foregroundStyle(PreflightPanel.color(worst))
            VStack(alignment: .leading, spacing: 0) {
                Text(n == 0 ? "Healthy" : "\(n) issue\(n == 1 ? "" : "s")").font(Theme.fontBold)
                Text("≈ \(Workflow2Util.byteString(rep?.totalBytes ?? 0)) on disk").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            Spacer()
            Button("Clean Up…") { PreflightModel.showCleanUp() }.buttonStyle(PanelButtonStyle())
                .disabled(!(rep?.issues.contains { $0.kind.fixTitle != nil } ?? false))
            IconButton(symbol: "arrow.clockwise", help: "Scan again", size: 20) { model.scan(d, force: true) }
        }
        .padding(.horizontal, 8).frame(height: 34)
    }

    static func color(_ severity: Int) -> Color {
        switch severity {
        case 2: return Color(red: 0.95, green: 0.35, blue: 0.3)
        case 1: return Color.orange
        case 0: return Color(red: 0.45, green: 0.65, blue: 0.95)
        default: return Color.green
        }
    }

    func kindSection(_ d: Document, _ k: PreflightKind, _ issues: [PreflightIssue]) -> some View {
        let open = model.expanded.contains(k)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textDim).frame(width: 10)
                Image(systemName: k.symbol).font(.system(size: 10)).foregroundStyle(PreflightPanel.color(k.severity)).frame(width: 14)
                Text(k.title).font(Theme.fontBold).lineLimit(1)
                Text("\(issues.reduce(0) { $0 + max(1, $1.layerIDs.count) })").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Spacer()
                if let f = k.fixTitle, issues.count > 1 {
                    Button("\(f) All") { fix(d, issues, k) }.buttonStyle(.plain).font(Theme.fontSmall).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(Theme.panelHeader)
            .contentShape(Rectangle())
            .onTapGesture { if open { model.expanded.remove(k) } else { model.expanded.insert(k) } }
            if open { ForEach(issues) { i in issueRow(d, i) } }
        }
    }

    func issueRow(_ d: Document, _ i: PreflightIssue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(i.title).foregroundStyle(Theme.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(i.detail + (i.saves > 50_000 ? "  ·  saves ≈ \(Workflow2Util.byteString(i.saves))" : ""))
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                if let f = i.kind.fixTitle {
                    Button(f) { fix(d, [i], i.kind) }.buttonStyle(PanelButtonStyle(prominent: true))
                }
                switch i.kind {
                case .defaultName: Button("Rename…") { select(d, i); DialogRegistry.show("batchRename") }.buttonStyle(PanelButtonStyle())
                case .largeEmbedded: Button("Link…") { select(d, i); AppActions.convertToLinked(); model.scan(d, force: true) }.buttonStyle(PanelButtonStyle(prominent: true))
                case .linkedMissing: Button("Relink…") { select(d, i); AppActions.relinkToFile(); model.scan(d, force: true) }.buttonStyle(PanelButtonStyle())
                case .outOfGamut: Button("Show") { d.gamutWarning = true; d.setNeedsRender() }.buttonStyle(PanelButtonStyle())
                default: EmptyView()
                }
            }
            .controlSize(.small)
        }
        .padding(.leading, 30).padding(.trailing, 8).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { select(d, i) }
        .overlay(Rectangle().fill(Theme.border.opacity(0.6)).frame(height: 0.5), alignment: .bottom)
    }

    func select(_ d: Document, _ i: PreflightIssue) {
        let ids = i.layerIDs.filter { d.state.layer($0) != nil }
        guard let first = ids.first else { return }
        d.selectLayer(first)
        d.selectedLayerIDs = Set(ids)
        d.setNeedsOverlay()
    }

    func fix(_ d: Document, _ issues: [PreflightIssue], _ k: PreflightKind) {
        let n = Preflight.fix(issues, in: d, name: issues.count == 1 ? "\(k.fixTitle ?? "Fix"): \(k.title)" : "Fix \(k.title)")
        if n == 0 { Workflow2Util.beep() }
        model.scan(d, force: true)
    }

    func sizeSection(_ d: Document, _ rep: PreflightReport) -> some View {
        let rows = model.showAllSizes ? rep.sizes : Array(rep.sizes.prefix(8))
        let top = max(1, rep.sizes.first?.bytes ?? 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 10)).foregroundStyle(Theme.textDim).frame(width: 14)
                Text("What makes this file big").font(Theme.fontBold)
                Spacer()
                Text("≈ \(Workflow2Util.byteString(rep.totalBytes))").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 8).frame(height: 24).background(Theme.panelHeader)
            ForEach(rows) { r in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(r.name).lineLimit(1).truncationMode(.middle)
                        Text(r.kind).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
                        Spacer()
                        Text(Workflow2Util.byteString(r.bytes)).font(Theme.mono).foregroundStyle(Theme.textDim)
                        Text(String(format: "%2.0f%%", 100 * Double(r.bytes) / Double(max(1, rep.totalBytes)))).font(Theme.mono).foregroundStyle(Theme.textFaint).frame(width: 32, alignment: .trailing)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.fieldBG)
                            RoundedRectangle(cornerRadius: 2).fill(r.layerID == nil ? Color(white: 0.55) : Theme.accent)
                                .frame(width: max(2, g.size.width * CGFloat(r.bytes) / CGFloat(top)))
                        }
                    }
                    .frame(height: 5)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture { if let id = r.layerID, d.state.layer(id) != nil { d.selectLayer(id) } }
            }
            if rep.sizes.count > 8 {
                Button(model.showAllSizes ? "Show fewer" : "Show all \(rep.sizes.count)") { model.showAllSizes.toggle() }
                    .buttonStyle(.plain).font(Theme.fontSmall).foregroundStyle(Theme.accent).padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
    }
}

/// File ▸ Clean Up Document…: batch-apply the chosen fixes as one undo step.
struct CleanUpDialog: View {
    /// nil = the defaults (fixes that don't change the look).
    @State private var picked: Set<PreflightKind>? = nil
    var docOverride: Document? = nil

    var body: some View {
        let d = docOverride ?? AppActions.doc
        let rep = d.flatMap { PreflightModel.shared.report($0) }
        let kinds = (rep?.kinds ?? []).filter { $0.fixTitle != nil }
        let chosen = picked ?? Set(kinds.filter(\.cleanupDefault))
        return DialogFrame(title: "Clean Up Document", width: 420, okTitle: "Clean Up", onOK: {
            guard let d, let rep else { return }
            let n = Preflight.cleanUp(d, kinds: chosen, report: rep)
            PreflightModel.shared.scan(d, force: true)
            AppModel.shared.setStatus(n == 0 ? "Nothing to clean up." : "Cleaned up \(n) issue\(n == 1 ? "" : "s") (one undo step).")
        }) {
            if kinds.isEmpty {
                Text("Nothing to clean up — the document is tidy.").foregroundStyle(Theme.textDim)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(kinds) { k in
                        let issues = rep?.issues(k) ?? []
                        let count = issues.reduce(0) { $0 + max(1, $1.layerIDs.count) }
                        let saves = issues.reduce(0) { $0 + $1.saves }
                        HStack(spacing: 8) {
                            Image(systemName: chosen.contains(k) ? "checkmark.square.fill" : "square").font(.system(size: 12))
                                .foregroundStyle(chosen.contains(k) ? Theme.accent : Theme.textDim)
                            Image(systemName: k.symbol).font(.system(size: 10)).foregroundStyle(PreflightPanel.color(k.severity)).frame(width: 14)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(k.fixTitle ?? "Fix") — \(k.title.lowercased()) (\(count))")
                                Text(k.cleanupDefault ? "Does not change how the document looks" + (saves > 50_000 ? " · saves ≈ \(Workflow2Util.byteString(saves))" : "")
                                     : "May change the document" + (saves > 50_000 ? " · saves ≈ \(Workflow2Util.byteString(saves))" : ""))
                                    .font(Theme.fontSmall).foregroundStyle(k.cleanupDefault ? Theme.textFaint : Color.orange.opacity(0.9))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { var c = chosen; if c.contains(k) { c.remove(k) } else { c.insert(k) }; picked = c }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fieldBG))
                Text("Everything is applied as a single history step — one Undo brings it all back.")
                    .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
        .onAppear { if let d, PreflightModel.shared.report(d) == nil { PreflightModel.shared.scan(d) } }
    }
}
