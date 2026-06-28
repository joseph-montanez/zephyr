// Sources/ZephyrCore/CAD/CADDimensionMetadata.swift

public enum CADDimensionType: Int, Sendable, Hashable, Codable {
    case linearOrRotated = 0
    case aligned = 1
    case angular = 2
    case diameter = 3
    case radius = 4
    case angular3Point = 5
    case ordinate = 6
    case arcLength = 7
    case jogged = 8
}

public struct CADDimensionMetadata: Sendable, Hashable, Codable {
    public let styleName: String
    public let type: CADDimensionType
    public let measurement: Double
    
    // Group 10,20,30 — definition point (varies by type)
    public let defPoint: Vector3
    // Group 13,23,33 — first extension line origin / arc point
    public let defPoint2: Vector3
    // Group 14,24,34 — second extension line origin / jog point (optional)
    public let defPoint3: Vector3?
    // Group 15,25,35 — optional point (vertex/center)
    public let defPoint4: Vector3?
    // Group 16,26,36 — optional point (arc endpoint)
    public let defPoint5: Vector3?
    // Group 11,21,31 — text midpoint
    public let textMidpoint: Vector3
    
    public let textOverride: String?
    public let rotationAngle: Double   // radians
    
    // Group 70 flags (bit 6 = ordinate X-type, bit 7 = text is user-positioned, etc.)
    public let flags: Int
    
    public var styleOverrides: CADDimensionStyle?
    
    public init(
        styleName: String = "STANDARD",
        type: CADDimensionType,
        measurement: Double,
        defPoint: Vector3,
        defPoint2: Vector3,
        defPoint3: Vector3? = nil,
        defPoint4: Vector3? = nil,
        defPoint5: Vector3? = nil,
        textMidpoint: Vector3,
        textOverride: String? = nil,
        rotationAngle: Double = 0,
        flags: Int = 0,
        styleOverrides: CADDimensionStyle? = nil
    ) {
        self.styleName = styleName
        self.type = type
        self.measurement = measurement
        self.defPoint = defPoint
        self.defPoint2 = defPoint2
        self.defPoint3 = defPoint3
        self.defPoint4 = defPoint4
        self.defPoint5 = defPoint5
        self.textMidpoint = textMidpoint
        self.textOverride = textOverride
        self.rotationAngle = rotationAngle
        self.flags = flags
        self.styleOverrides = styleOverrides
    }
}

/// Lightweight heap-allocated box so non-dimension entities only pay
/// the cost of an 8-byte optional pointer instead of inflating every
/// CADEntity struct stride by ~120+ bytes.
public final class CADDimensionMetadataBox: Sendable, Hashable, Codable {
    public let value: CADDimensionMetadata
    public init(_ value: CADDimensionMetadata) { self.value = value }
    
    public static func == (lhs: CADDimensionMetadataBox, rhs: CADDimensionMetadataBox) -> Bool {
        return lhs.value == rhs.value
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(value)
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.value = try container.decode(CADDimensionMetadata.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
