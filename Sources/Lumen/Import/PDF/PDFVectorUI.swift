import SwiftUI
import AppKit

/// File ▸ Import ▸ PDF Import Report…: what the last PDF / Illustrator imports kept editable, what was rasterized
/// and which fonts were not available. Informational only; nothing here blocks an import.
struct PDFVectorReportDialog: View {
    private let entries = PDFVectorImport.reports

    var body: some View {
        DialogFrame(title: "PDF / Illustrator Import Report", width: 520, okTitle: "Done", onOK: {}, extraButtons: AnyView(
            Button("Copy") {
                let pb = AppActions.pasteboard
                pb.clearContents()
                pb.setString(PDFVectorReportDialog.text(entries), forType: .string)
            }.buttonStyle(PanelButtonStyle())
        )) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty { Text("No PDF or Illustrator file has been imported as editable layers in this session.").foregroundStyle(Theme.textFaint) }
                    ForEach(entries) { e in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.report.file.isEmpty ? "Pasted artwork" : e.report.file).font(Theme.fontBold)
                            Text(e.report.text).font(Theme.font).foregroundStyle(Theme.textDim).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 320)
        }
    }

    static func text(_ entries: [PDFVectorImport.Entry]) -> String {
        entries.map { ($0.report.file.isEmpty ? "Pasted artwork" : $0.report.file) + "\n" + $0.report.text }.joined(separator: "\n\n")
    }
}
