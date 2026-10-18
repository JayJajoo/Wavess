import Foundation

/// A color-grading preset the user can apply to a clip or reel.
enum Look: String, CaseIterable, Identifiable {
    case none = "Original"
    case vivid = "Vivid"
    case warm = "Warm"
    case cool = "Cool"
    case cinematic = "Cinematic"
    case noir = "B&W"
    case vintage = "Vintage"

    var id: String { rawValue }

    /// SF Symbol used in pickers.
    var symbol: String {
        switch self {
        case .none:      return "circle.slash"
        case .vivid:     return "sun.max"
        case .warm:      return "flame"
        case .cool:      return "snowflake"
        case .cinematic: return "film"
        case .noir:      return "circle.lefthalf.filled"
        case .vintage:   return "camera.filters"
        }
    }
}
