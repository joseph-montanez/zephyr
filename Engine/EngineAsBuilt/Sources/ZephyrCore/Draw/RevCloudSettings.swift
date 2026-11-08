import Foundation

public enum RevCloudCreationMode: Int, Sendable {
    case freehand = 0
    case rectangular = 1
    case polygonal = 2

    var displayName: String {
        switch self {
        case .freehand: return "Freehand"
        case .rectangular: return "Rectangular"
        case .polygonal: return "Polygonal"
        }
    }
}

public enum RevCloudStyle: String, Sendable {
    case normal = "Normal"
    case calligraphy = "Calligraphy"
}

public enum RevCloudSettings {
    private static let prefix = "Zephyr.RevCloud."

    private static func key(_ name: String) -> String { prefix + name }

    private static func store(_ value: Double, _ name: String) {
        UserDefaults.standard.set(value, forKey: key(name))
    }

    private static func store(_ value: Bool, _ name: String) {
        UserDefaults.standard.set(value, forKey: key(name))
    }

    private static func store(_ value: Int, _ name: String) {
        UserDefaults.standard.set(value, forKey: key(name))
    }

    private static func store(_ value: String, _ name: String) {
        UserDefaults.standard.set(value, forKey: key(name))
    }

    private static func double(_ name: String, default defaultValue: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key(name)) != nil else { return defaultValue }
        return UserDefaults.standard.double(forKey: key(name))
    }

    private static func bool(_ name: String, default defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key(name)) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key(name))
    }

    private static func string(_ name: String, default defaultValue: String = "") -> String {
        UserDefaults.standard.string(forKey: key(name)) ?? defaultValue
    }

    public static var minimumArcLength: Double {
        get { double("MinimumArcLength", default: 0) }
        set { store(max(0, newValue), "MinimumArcLength") }
    }

    public static var maximumArcLength: Double {
        get { double("MaximumArcLength", default: 0) }
        set { store(max(0, newValue), "MaximumArcLength") }
    }

    public static var approximateArcLength: Double {
        get {
            let explicit = double("ApproximateArcLength", default: 0)
            if explicit > 0 { return explicit }
            let minLength = minimumArcLength
            let maxLength = maximumArcLength
            return minLength > 0 && maxLength > 0 ? (minLength + maxLength) * 0.5 : 0
        }
        set {
            let value = max(0, newValue)
            store(value, "ApproximateArcLength")
            if value > 0 {
                minimumArcLength = value * (2.0 / 3.0)
                maximumArcLength = value * (4.0 / 3.0)
            }
        }
    }

    public static var arcVarianceEnabled: Bool {
        get { bool("ArcVariance", default: true) }
        set { store(newValue, "ArcVariance") }
    }

    public static var gripsEnabled: Bool {
        get { bool("Grips", default: true) }
        set { store(newValue, "Grips") }
    }

    public static var deleteSourceObject: Bool {
        get { bool("DeleteSourceObject", default: true) }
        set { store(newValue, "DeleteSourceObject") }
    }

    public static var creationMode: RevCloudCreationMode {
        get {
            guard UserDefaults.standard.object(forKey: key("CreationMode")) != nil else {
                return .rectangular
            }
            return RevCloudCreationMode(
                rawValue: UserDefaults.standard.integer(forKey: key("CreationMode"))) ?? .rectangular
        }
        set { store(newValue.rawValue, "CreationMode") }
    }

    public static var style: RevCloudStyle {
        get { RevCloudStyle(rawValue: string("Style")) ?? .normal }
        set { store(newValue.rawValue, "Style") }
    }

    public static var layerName: String {
        get { string("Layer") }
        set { store(newValue, "Layer") }
    }

    /// Stores the approximate arc length without touching min/max.
    /// Used by flows that already set both bounds explicitly.
    static func recordApproximateArcLength(_ value: Double) {
        store(value, "ApproximateArcLength")
    }

    @MainActor
    public static func ensureArcLengths(engine: PhrostEngine) {
        if minimumArcLength > 0, maximumArcLength >= minimumArcLength { return }
        let viewport = engine.camera.worldViewportRect(
            windowWidth: engine.windowWidth,
            windowHeight: engine.windowHeight)
        let diagonal = hypot(viewport.maxX - viewport.minX, viewport.maxY - viewport.minY)
        let approximate = max(diagonal * 0.0075, 1e-6)
        minimumArcLength = approximate * (2.0 / 3.0)
        maximumArcLength = approximate * (4.0 / 3.0)
        store(approximate, "ApproximateArcLength")
    }
}
