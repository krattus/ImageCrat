import Foundation

// MARK: - Arrange selected layers on a shape

package struct ArrangeSettings: Equatable {
    package enum Shape: String, CaseIterable, Identifiable {
        case circle = "Circle", ellipse = "Ellipse", square = "Square", rectangle = "Rectangle", triangle = "Triangle", polygon = "Polygon", star = "Star"
        case line = "Line", arc = "Arc", spiral = "Spiral", wave = "Wave", grid = "Grid", custom = "Custom Shape", path = "Active Path"
        package var id: String { rawValue }
    }
    package enum Order: String, CaseIterable, Identifiable { case stack = "Layer order", reverse = "Reverse layer order", position = "Left to right", random = "Random"
        package var id: String { rawValue } }
    package enum Facing: String, CaseIterable, Identifiable { case upright = "Keep upright", tangent = "Follow the path", outward = "Face outward", inward = "Face inward"
        package var id: String { rawValue } }

    package var shape: Shape = .circle
    package var width: Double = 400
    package var height: Double = 400
    package var centerX: Double = 0
    package var centerY: Double = 0
    package var rotation: Double = 0          // rotates the whole shape, degrees
    package var startOffset: Double = 0       // 0…100 % along the outline
    package var clockwise = true
    package var sides = 6                     // polygon / star points
    package var starInset: Double = 0.5
    package var arcAngle: Double = 180
    package var turns: Double = 2             // spiral
    package var waves: Double = 2
    package var columns = 3                   // grid
    package var customID = "heart"
    package var atCorners = false             // polygons: put layers on the corners first
    package var order: Order = .stack
    package var facing: Facing = .upright
    package var extraRotation: Double = 0
    package var scaleEnd: Double = 100        // % size of the last layer (progression)
    package var jitterPosition: Double = 0
    package var jitterRotation: Double = 0
    package var seed = 1
    package init(shape: Shape = .circle, width: Double = 400, height: Double = 400, centerX: Double = 0, centerY: Double = 0, rotation: Double = 0, startOffset: Double = 0, clockwise: Bool = true, sides: Int = 6, starInset: Double = 0.5, arcAngle: Double = 180, turns: Double = 2, waves: Double = 2, columns: Int = 3, customID: String = "heart", atCorners: Bool = false, order: Order = .stack, facing: Facing = .upright, extraRotation: Double = 0, scaleEnd: Double = 100, jitterPosition: Double = 0, jitterRotation: Double = 0, seed: Int = 1) {
        self.shape = shape; self.width = width; self.height = height; self.centerX = centerX; self.centerY = centerY; self.rotation = rotation; self.startOffset = startOffset; self.clockwise = clockwise; self.sides = sides; self.starInset = starInset; self.arcAngle = arcAngle; self.turns = turns; self.waves = waves; self.columns = columns; self.customID = customID; self.atCorners = atCorners; self.order = order; self.facing = facing; self.extraRotation = extraRotation; self.scaleEnd = scaleEnd; self.jitterPosition = jitterPosition; self.jitterRotation = jitterRotation; self.seed = seed
    }
}
