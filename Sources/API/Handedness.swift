import Foundation

/// Which hand a controller belongs to, parsed from its advertised name
/// ("Surreal Touch L" / "Surreal Touch R").
public enum Handedness: Sendable, Equatable {
    case left
    case right
    case unspecified

    init(name: String) {
        // Names look like "Surreal Touch L D5A8" / "Surreal Touch R C07E" — the
        // L/R token can be followed by a device-id suffix, so scan all tokens for
        // a standalone side marker rather than assuming it's last.
        let tokens = name.split(separator: " ").map { $0.uppercased() }
        if tokens.contains("L") || tokens.contains("LEFT") {
            self = .left
        } else if tokens.contains("R") || tokens.contains("RIGHT") {
            self = .right
        } else {
            self = .unspecified
        }
    }
}
