import Foundation

// MARK: - Document data (persisted in DocumentState.toolData)

extension KeyedDecodingContainer {
    /// Tolerant decode: missing or malformed values fall back to `def`.
    package func tdValue<T: Decodable>(_ key: Key, _ def: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? def }
}

package struct DocSlice: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var rect: CGRect
    package var name: String = ""

    package init(rect: CGRect, name: String = "") { self.rect = rect; self.name = name }

    private enum K: String, CodingKey { case id, rect, name }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.tdValue(.id, UUID()); rect = c.tdValue(.rect, .zero); name = c.tdValue(.name, "")
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(rect, forKey: .rect); try c.encode(name, forKey: .name)
    }
}

package struct DocNote: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var position: CGPoint
    package var text: String = ""
    package var author: String = ""
    package var color: RGBA = RGBA(r: 1, g: 0.85, b: 0.25, a: 1)
    package var date = Date()

    package init(position: CGPoint, author: String, color: RGBA) { self.position = position; self.author = author; self.color = color }

    private enum K: String, CodingKey { case id, position, text, author, color, date }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.tdValue(.id, UUID()); position = c.tdValue(.position, .zero); text = c.tdValue(.text, "")
        author = c.tdValue(.author, ""); color = c.tdValue(.color, RGBA(r: 1, g: 0.85, b: 0.25, a: 1)); date = c.tdValue(.date, Date())
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(position, forKey: .position); try c.encode(text, forKey: .text)
        try c.encode(author, forKey: .author); try c.encode(color, forKey: .color); try c.encode(date, forKey: .date)
    }
}

package struct CountGroup: Codable, Identifiable, Equatable {
    package var id = UUID()
    package var name: String
    package var color: RGBA
    package var visible = true
    package var markerSize: Double = 4
    package var labelSize: Double = 10
    package var points: [CGPoint] = []

    package init(name: String, color: RGBA) { self.name = name; self.color = color }

    package static let palette = ["E53935", "1E88E5", "43A047", "FB8C00", "8E24AA", "00ACC1", "FDD835", "6D4C41"]

    private enum K: String, CodingKey { case id, name, color, visible, markerSize, labelSize, points }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.tdValue(.id, UUID()); name = c.tdValue(.name, "Count Group"); color = c.tdValue(.color, RGBA(r: 0.9, g: 0.2, b: 0.2, a: 1))
        visible = c.tdValue(.visible, true); markerSize = c.tdValue(.markerSize, 4); labelSize = c.tdValue(.labelSize, 10)
        points = c.tdValue(.points, [])
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(color, forKey: .color)
        try c.encode(visible, forKey: .visible); try c.encode(markerSize, forKey: .markerSize); try c.encode(labelSize, forKey: .labelSize)
        try c.encode(points, forKey: .points)
    }
}

package struct FrameInfo: Codable, Equatable {
    package var id: UUID
    package var ellipse = false

    package init(id: UUID, ellipse: Bool) { self.id = id; self.ellipse = ellipse }
    private enum K: String, CodingKey { case id, ellipse }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = c.tdValue(.id, UUID()); ellipse = c.tdValue(.ellipse, false)
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(id, forKey: .id); try c.encode(ellipse, forKey: .ellipse)
    }
}

/// Analysis ▸ Set Measurement Scale: `pixels` pixels correspond to `length` `units`.
package struct MeasurementScale: Codable, Equatable {
    package var pixels: Double = 1
    package var length: Double = 1
    package var units: String = "pixels"

    package init() {}
    package init(pixels: Double, length: Double, units: String) { self.pixels = pixels; self.length = length; self.units = units }
    package var unitsPerPixel: Double { pixels > 0 ? length / pixels : 1 }
    package var isDefault: Bool { units == "pixels" && pixels == length }

    private enum K: String, CodingKey { case pixels, length, units }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        pixels = c.tdValue(.pixels, 1); length = c.tdValue(.length, 1); units = c.tdValue(.units, "pixels")
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(pixels, forKey: .pixels); try c.encode(length, forKey: .length); try c.encode(units, forKey: .units)
    }
}

package struct ToolDocData: Codable {
    package var slices: [DocSlice] = []
    package var notes: [DocNote] = []
    package var countGroups: [CountGroup] = []
    package var colorSamplers: [CGPoint] = []
    package var frames: [FrameInfo] = []
    package var measurementScale = MeasurementScale()

    package init() {}

    package var isEmpty: Bool {
        slices.isEmpty && notes.isEmpty && countGroups.allSatisfy { $0.points.isEmpty } && colorSamplers.isEmpty && frames.isEmpty && measurementScale.isDefault
    }

    /// The same marks after the canvas geometry changed (crop, canvas / image size, rotate, flip…): slices, notes,
    /// count marks and colour samplers stay on the image content they were placed on.
    package func mapped(_ f: (CGPoint) -> CGPoint) -> ToolDocData {
        var t = self
        t.slices = slices.map { s in
            var n = s
            let r = s.rect
            n.rect = CGRect.bounding([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(f)).integral
            return n
        }
        t.notes = notes.map { var n = $0; n.position = f($0.position).rounded; return n }
        t.countGroups = countGroups.map { var g = $0; g.points = $0.points.map { f($0).rounded }; return g }
        t.colorSamplers = colorSamplers.map { p in let q = f(p); return CGPoint(x: floor(q.x) + 0.5, y: floor(q.y) + 0.5) }
        return t
    }

    private enum K: String, CodingKey { case slices, notes, countGroups, colorSamplers, frames, measurementScale }
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        slices = c.tdValue(.slices, []); notes = c.tdValue(.notes, []); countGroups = c.tdValue(.countGroups, [])
        colorSamplers = c.tdValue(.colorSamplers, []); frames = c.tdValue(.frames, [])
        measurementScale = c.tdValue(.measurementScale, MeasurementScale())
    }
    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(slices, forKey: .slices); try c.encode(notes, forKey: .notes); try c.encode(countGroups, forKey: .countGroups)
        try c.encode(colorSamplers, forKey: .colorSamplers); try c.encode(frames, forKey: .frames)
        try c.encode(measurementScale, forKey: .measurementScale)
    }
}
