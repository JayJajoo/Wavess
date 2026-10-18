import Foundation

enum Formatting {

    /// Formats a duration in seconds as `m:ss` (or `h:mm:ss` past an hour).
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// A short, friendly duration like "1.4s" for small numbers.
    static func shortDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        return timecode(seconds)
    }
}
