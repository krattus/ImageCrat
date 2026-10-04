import ImageCratCore

// Core types whose names also exist in SwiftUI. Before the core was split out, the app's own declarations shadowed
// SwiftUI's; these module-level aliases keep every unqualified use in the app pointing at the core types.
typealias BlendMode = ImageCratCore.BlendMode
typealias StrokeStyle = ImageCratCore.StrokeStyle
typealias Animation = ImageCratCore.Animation
