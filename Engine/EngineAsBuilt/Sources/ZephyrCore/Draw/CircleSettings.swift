import Foundation

/// Persistent CIRCLE settings (UserDefaults-backed, thread-safe so the
/// Lisp sysvar store can share them). `CIRCLERAD` semantic: last used
/// radius; 0 / nil means no default (Enter shows no <value>).
public enum CircleSettings {
    private static let radiusKey = "Zephyr.Circle.Radius"

    /// Last radius used, offered as the next prompt default.
    /// `nil` means no default (AutoCAD encodes this as CIRCLERAD = 0).
    public static var lastRadius: Double? {
        get {
            guard UserDefaults.standard.object(forKey: radiusKey) != nil else { return nil }
            let value = UserDefaults.standard.double(forKey: radiusKey)
            return value > 0 && value.isFinite ? value : nil
        }
        set {
            if let newValue, newValue > 0, newValue.isFinite {
                UserDefaults.standard.set(newValue, forKey: radiusKey)
            } else {
                UserDefaults.standard.removeObject(forKey: radiusKey)
            }
        }
    }
}

/// Pure circle math behind CIRCLE (headless-testable).
public enum CircleMath {

    /// 2P mode: center is midpoint, radius is half the endpoint distance.
    public static func circleFromTwoPoints(_ a: Vector3, _ b: Vector3) -> (center: Vector3, radius: Double) {
        let center = Vector3(
            x: (a.x + b.x) / 2,
            y: (a.y + b.y) / 2,
            z: (a.z + b.z) / 2)
        let radius = a.distance(to: b) / 2
        return (center, radius)
    }

    /// Diameter entry: typed diameter value → radius.
    public static func radiusFromDiameter(_ diameter: Double) -> Double {
        diameter / 2
    }

    /// Picked circumference point: click distance is already the radius
    /// even in diameter mode (AutoCAD drag behavior).
    public static func radiusFromPick(center: Vector3, pick: Vector3) -> Double {
        center.distance(to: pick)
    }
}
