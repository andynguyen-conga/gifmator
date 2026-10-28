import AVFoundation
import Foundation

/// Formats a CMTime as `M:SS.mmm`. Used by the transport bar and the trimmer
/// readouts; kept here so there's one copy to update when the format changes.
func formatTime(_ time: CMTime) -> String {
    let seconds = time.seconds
    guard seconds.isFinite, seconds >= 0 else { return "0:00.000" }
    let totalMs = Int((seconds * 1000).rounded())
    let minutes = totalMs / 60_000
    let secs = (totalMs / 1000) % 60
    let ms = totalMs % 1000
    return String(format: "%d:%02d.%03d", minutes, secs, ms)
}
