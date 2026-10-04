import Foundation

// MARK: - Model

/// Interpolation from a keyframe towards the next one.
package enum KeyInterpolation: String, Codable, CaseIterable { case linear = "Linear", hold = "Hold", ease = "Ease In/Out" }

/// Animatable layer properties of the Video Timeline.
package enum TrackProperty: String, Codable, CaseIterable, Identifiable {
    case position = "Position", opacity = "Opacity", style = "Style", transform = "Transform"
    package var id: String { rawValue }
}

package enum KeyValue: Codable, Equatable {
    /// Layer centre in document coordinates.
    case point(CGPoint)
    case number(Double)
    /// Absolute scale factor and rotation (degrees) of the layer's content transform.
    case transform(scale: Double, rotation: Double)
    case style(LayerEffects)
}

package struct Keyframe: Codable, Equatable, Identifiable {
    package var id = UUID()
    package var time: Double
    package var interpolation: KeyInterpolation = .linear
    package var value: KeyValue
    package init(id: UUID = UUID(), time: Double, interpolation: KeyInterpolation = .linear, value: KeyValue) {
        self.id = id; self.time = time; self.interpolation = interpolation; self.value = value
    }
}

/// Source of a video layer (the layer itself is a smart object showing the frame at the playhead).
package struct VideoClip: Codable, Equatable {
    package var url: URL
    /// In / out points in source seconds.
    package var inPoint: Double
    package var outPoint: Double
    package var sourceDuration: Double
    package var frameRate: Double
    package var naturalSize: CGSize
    package var length: Double { max(0, outPoint - inPoint) }
    package init(url: URL, inPoint: Double, outPoint: Double, sourceDuration: Double, frameRate: Double, naturalSize: CGSize) {
        self.url = url; self.inPoint = inPoint; self.outPoint = outPoint; self.sourceDuration = sourceDuration; self.frameRate = frameRate; self.naturalSize = naturalSize
    }
}

package struct LayerTrack: Codable, Equatable {
    package var layerID: UUID
    /// Duration bar on the timeline (seconds).
    package var start: Double = 0
    package var duration: Double
    package var keyframes: [String: [Keyframe]] = [:]   // TrackProperty.rawValue → keys sorted by time
    package var video: VideoClip? = nil

    package func keys(_ p: TrackProperty) -> [Keyframe] { keyframes[p.rawValue] ?? [] }
    package mutating func setKeys(_ p: TrackProperty, _ k: [Keyframe]) {
        keyframes[p.rawValue] = k.isEmpty ? nil : k.sorted { $0.time < $1.time }
    }
    package var end: Double { start + duration }
    package init(layerID: UUID, start: Double = 0, duration: Double, keyframes: [String: [Keyframe]] = [:], video: VideoClip? = nil) {
        self.layerID = layerID; self.start = start; self.duration = duration; self.keyframes = keyframes; self.video = video
    }
}

package struct VideoTimeline: Codable, Equatable {
    package var duration: Double = 5
    package var frameRate: Double = 30
    package var tracks: [LayerTrack] = []

    package func track(_ id: UUID) -> LayerTrack? { tracks.first { $0.layerID == id } }
    package mutating func updateTrack(_ id: UUID, _ f: (inout LayerTrack) -> Void) {
        if let i = tracks.firstIndex(where: { $0.layerID == id }) { f(&tracks[i]) }
        else { var t = LayerTrack(layerID: id, duration: duration); f(&t); tracks.append(t) }
    }
    package var frameCount: Int { max(1, Int((duration * frameRate).rounded())) }
    package func snap(_ t: Double) -> Double { (min(max(0, t), duration) * frameRate).rounded() / frameRate }
    package init(duration: Double = 5, frameRate: Double = 30, tracks: [LayerTrack] = []) {
        self.duration = duration; self.frameRate = frameRate; self.tracks = tracks
    }
}

/// Unique smart-object source revisions (the compositor caches smart objects by revision + buffer identity,
/// and buffer addresses can be reused once freed).
package enum SourceRevision {
    private static var counter = 1_000_000
    private static let lock = NSLock()
    package static func next() -> Int { lock.lock(); defer { lock.unlock() }; counter += 1; return counter }
}
