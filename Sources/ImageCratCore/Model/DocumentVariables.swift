import Foundation

// MARK: - Model (data-driven graphics)

package enum VariableKind: String, Codable, CaseIterable { case visibility = "Visibility", text = "Text Replacement", pixel = "Pixel Replacement" }
package enum PixelFit: String, Codable, CaseIterable { case fit = "Fit", fill = "Fill", asIs = "As Is", conform = "Conform" }

package struct LayerVariable: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name: String
    package var kind: VariableKind
    package var layerID: UUID
    package var fit: PixelFit = .fit
    /// Bounding box pixel replacements are placed into (captured when defined).
    package var box: CGRect? = nil
    package init(id: UUID = UUID(), name: String, kind: VariableKind, layerID: UUID, fit: PixelFit = .fit, box: CGRect? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.layerID = layerID; self.fit = fit; self.box = box
    }
}

package struct DataSet: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var name: String
    package var values: [String: String] = [:]
    package init(id: UUID = UUID(), name: String, values: [String: String] = [:]) {
        self.id = id; self.name = name; self.values = values
    }
}

package struct DocumentVariables: Codable, Equatable {
    package var variables: [LayerVariable] = []
    package var dataSets: [DataSet] = []
    /// Folder relative pixel-replacement paths are resolved against (the imported text file's folder).
    package var baseFolder: URL? = nil
    package init(variables: [LayerVariable] = [], dataSets: [DataSet] = [], baseFolder: URL? = nil) {
        self.variables = variables; self.dataSets = dataSets; self.baseFolder = baseFolder
    }
}
