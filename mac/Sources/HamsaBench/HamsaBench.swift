import HamsaKit

/// Shared helpers for the bench-* executables.
public enum HamsaBench {
    public static func banner(_ name: String) -> String { "\(name) (hamsa \(Hamsa.version))" }
}
