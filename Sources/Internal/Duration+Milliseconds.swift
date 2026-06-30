import Foundation

extension Duration {
    /// The duration in whole milliseconds, clamped at zero for negative values.
    var inMilliseconds: UInt64 {
        let (seconds, attoseconds) = components
        let secondsPart = seconds < 0 ? 0 : UInt64(seconds)
        let attoPart = attoseconds < 0 ? 0 : UInt64(attoseconds)
        return secondsPart * 1_000 + attoPart / 1_000_000_000_000_000
    }
}
