import Foundation

package enum DocumentIOError: LocalizedError {
    case unreadable, unsupported, encodeFailed
    package var errorDescription: String? {
        switch self {
        case .unreadable: return "The file could not be read."
        case .unsupported: return "The file format is not supported."
        case .encodeFailed: return "The image could not be encoded."
        }
    }
}
