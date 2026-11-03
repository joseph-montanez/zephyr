import Foundation

// =========================================================================
// MARK: - UserPointParser
//
// Pure (stateless, dependency-free) parser for CAD user point strings.
//
// Accepted forms (surrounding/inner whitespace is tolerated):
//   * "x,y" or "x,y,z"        — absolute coordinates.
//   * "@dx,dy" or "@dx,dy,dz" — relative displacement from a base point.
//   * "dist<angle"             — relative polar displacement; distance in
//     drawing units and angle in user degrees (AutoCAD convention).
//
// The parser never applies ANGBASE/ANGDIR itself: the polar case keeps the
// raw user angle (degrees), and the caller injects the orientation mapping
// at resolve time via `userAngleToCanonical` (user radians -> canonical
// radians), typically `AngleConvention.canonicalOrientation(fromUser:)`.
// A missing z in an absolute input resolves to the base elevation; a
// missing dz in a relative input resolves to 0.
// =========================================================================

/// Parsed (still frame-free) user point input.
public enum UserPointInput: Hashable, Sendable {
    /// Absolute coordinates; `z` is nil when omitted.
    case absolute(x: Double, y: Double, z: Double?)
    /// Relative displacement; `dz` is nil when omitted (resolves to 0).
    case relative(dx: Double, dy: Double, dz: Double?)
    /// Relative polar displacement; angle in raw user degrees.
    case polar(distance: Double, userAngleDegrees: Double)
}

public enum UserPointParser: Sendable {

    /// Parses one user point string. Returns nil for empty, malformed, or
    /// non-finite input.
    public static func parse(_ text: String) -> UserPointInput? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("@") {
            return parseRelative(String(trimmed.dropFirst()))
        }
        if let bracket = trimmed.firstIndex(of: "<") {
            return parsePolar(before: String(trimmed[..<bracket]),
                              after: String(trimmed[trimmed.index(after: bracket)...]))
        }
        return parseAbsolute(trimmed)
    }

    /// Resolves parsed input to an absolute 3D point from a base point.
    /// `userAngleToCanonical` maps a user-convention angle in radians to a
    /// canonical angle in radians (inject `AngleConvention` conversion).
    public static func resolve(
        _ input: UserPointInput,
        from base: Point3d,
        userAngleToCanonical: (Double) -> Double
    ) -> Point3d {
        switch input {
        case .absolute(let x, let y, let z):
            return Point3d(x: x, y: y, z: z ?? base.z)
        case .relative(let dx, let dy, let dz):
            return Point3d(x: base.x + dx, y: base.y + dy, z: base.z + (dz ?? 0))
        case .polar(let distance, let userDegrees):
            let canonical = userAngleToCanonical(userDegrees * .pi / 180.0)
            return Point3d(
                x: base.x + distance * cos(canonical),
                y: base.y + distance * sin(canonical),
                z: base.z
            )
        }
    }

    // MARK: - Private

    private static func parseAbsolute(_ s: String) -> UserPointInput? {
        let parts = splitComponents(s)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let x = finiteDouble(parts[0]), let y = finiteDouble(parts[1]) else {
            return nil
        }
        if parts.count == 3 {
            guard let z = finiteDouble(parts[2]) else { return nil }
            return .absolute(x: x, y: y, z: z)
        }
        return .absolute(x: x, y: y, z: nil)
    }

    private static func parseRelative(_ s: String) -> UserPointInput? {
        // "@" must appear exactly once, as the original prefix.
        guard !s.contains("@"), !s.contains("<") else { return nil }
        let parts = splitComponents(s)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let dx = finiteDouble(parts[0]), let dy = finiteDouble(parts[1]) else {
            return nil
        }
        if parts.count == 3 {
            guard let dz = finiteDouble(parts[2]) else { return nil }
            return .relative(dx: dx, dy: dy, dz: dz)
        }
        return .relative(dx: dx, dy: dy, dz: nil)
    }

    private static func parsePolar(before: String, after: String) -> UserPointInput? {
        // Exactly one "<", and neither side may carry list/"@" syntax.
        guard !after.contains("<"), !before.contains(","),
              !before.contains("@"), !after.contains("@"),
              !after.contains(",") else { return nil }
        guard let dist = finiteDouble(before.trimmingCharacters(in: .whitespaces)),
              let deg = finiteDouble(after.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return .polar(distance: dist, userAngleDegrees: deg)
    }

    private static func splitComponents(_ s: String) -> [String] {
        // Preserve empties so "1,,2" and trailing commas fail cleanly.
        s.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func finiteDouble(_ s: String) -> Double? {
        guard !s.isEmpty, let v = Double(s), v.isFinite else { return nil }
        return v
    }
}
