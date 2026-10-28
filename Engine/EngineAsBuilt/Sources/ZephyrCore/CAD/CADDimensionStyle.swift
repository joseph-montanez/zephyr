// Sources/ZephyrCore/CAD/CADDimensionStyle.swift

public enum DimUnitsFormat: Int, Sendable, Hashable, Codable {
    case scientific = 1
    case decimal = 2
    case engineering = 3
    case architectural = 4
    case fractional = 5
    case windowsDesktop = 6
}

public enum DimAngleFormat: Int, Sendable, Hashable, Codable {
    case decimalDegrees = 0
    case degMinSec = 1
    case gradians = 2
    case radians = 3
}

public struct CADDimensionStyle: Sendable, Hashable, Codable {
    /// Table key (case-insensitive match). Mirrors CADTextStyle.name: the
    /// document dictionary is keyed by name and helpers rewrite references
    /// on rename, so this stays in sync with the key.
    public var name: String = "Standard"
    /// Overall scale factor (AutoCAD DIMSCALE sysvar, DXF group 40).
    /// Stored raw per style; geometry builders apply it via scaled() so
    /// imported raw values (DIMASZ etc.) round-trip instead of being
    /// baked at import time.
    public var overallScale: Double = 1.0
    public var arrowSize: Double = 2.5
    public var textHeight: Double = 2.5
    public var textOffset: Double = 0.625
    public var extensionLineOffset: Double = 0.625
    public var extensionLineExtend: Double = 1.25
    public var dimLineOffset: Double = 5.0
    public var tickSize: Double = 0.0
    public var unitsFormat: DimUnitsFormat = .decimal
    public var unitsPrecision: Int = 2
    public var angleFormat: DimAngleFormat = .decimalDegrees
    public var anglePrecision: Int = 1
    public var textStyle: String? = nil
    public var suppressFirstExtension: Bool = false
    public var suppressSecondExtension: Bool = false
    public var suppressFirstDimLine: Bool = false
    public var suppressSecondDimLine: Bool = false

    public var firstArrowhead: CADDimensionArrowhead? = nil
    public var secondArrowhead: CADDimensionArrowhead? = nil
    public var firstArrowBlockName: String? = nil
    public var secondArrowBlockName: String? = nil
    public var linearScaleFactor: Double? = nil
    public var dimensionPrefix: String? = nil
    public var dimensionSuffix: String? = nil
    public var zeroSuppression: Int? = nil
    public var textBackgroundScale: Double? = nil
    public var textBackgroundColor: ColorRGBA? = nil
    public var textBackgroundUsesViewportColor: Bool = false
    public static let `default` = CADDimensionStyle()
    
    public init() {}

    /// Copy with raw metric fields multiplied by overallScale (the exact
    /// fold the DXF importer used to bake at import time), resetting
    /// overallScale to 1 so the factor can never apply twice. Geometry
    /// builders and regen paths consume styles through here; the stored
    /// table keeps raw values so DIMSCALE/DIMASZ round-trip.
    public func scaled() -> CADDimensionStyle {
        guard overallScale != 1.0 else { return self }
        var copy = self
        copy.arrowSize *= overallScale
        copy.textHeight *= overallScale
        copy.textOffset *= overallScale
        copy.extensionLineOffset *= overallScale
        copy.extensionLineExtend *= overallScale
        copy.dimLineOffset *= overallScale
        copy.tickSize *= overallScale
        copy.overallScale = 1.0
        return copy
    }

    private enum CodingKeys: String, CodingKey {
        case name, overallScale, arrowSize, textHeight, textOffset,
             extensionLineOffset, extensionLineExtend, dimLineOffset, tickSize,
             unitsFormat, unitsPrecision, angleFormat, anglePrecision, textStyle,
             suppressFirstExtension, suppressSecondExtension,
             suppressFirstDimLine, suppressSecondDimLine,
             firstArrowhead, secondArrowhead,
             firstArrowBlockName, secondArrowBlockName,
             linearScaleFactor, dimensionPrefix, dimensionSuffix,
             zeroSuppression, textBackgroundScale, textBackgroundColor,
             textBackgroundUsesViewportColor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // New keys tolerate archives written before they existed.
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Standard"
        overallScale = try c.decodeIfPresent(Double.self, forKey: .overallScale) ?? 1.0
        arrowSize = try c.decode(Double.self, forKey: .arrowSize)
        textHeight = try c.decode(Double.self, forKey: .textHeight)
        textOffset = try c.decode(Double.self, forKey: .textOffset)
        extensionLineOffset = try c.decode(Double.self, forKey: .extensionLineOffset)
        extensionLineExtend = try c.decode(Double.self, forKey: .extensionLineExtend)
        dimLineOffset = try c.decode(Double.self, forKey: .dimLineOffset)
        tickSize = try c.decode(Double.self, forKey: .tickSize)
        unitsFormat = try c.decode(DimUnitsFormat.self, forKey: .unitsFormat)
        unitsPrecision = try c.decode(Int.self, forKey: .unitsPrecision)
        angleFormat = try c.decode(DimAngleFormat.self, forKey: .angleFormat)
        anglePrecision = try c.decode(Int.self, forKey: .anglePrecision)
        textStyle = try c.decodeIfPresent(String.self, forKey: .textStyle)
        suppressFirstExtension = try c.decode(Bool.self, forKey: .suppressFirstExtension)
        suppressSecondExtension = try c.decode(Bool.self, forKey: .suppressSecondExtension)
        suppressFirstDimLine = try c.decode(Bool.self, forKey: .suppressFirstDimLine)
        suppressSecondDimLine = try c.decode(Bool.self, forKey: .suppressSecondDimLine)
        firstArrowhead = try c.decodeIfPresent(CADDimensionArrowhead.self, forKey: .firstArrowhead)
        secondArrowhead = try c.decodeIfPresent(CADDimensionArrowhead.self, forKey: .secondArrowhead)
        firstArrowBlockName = try c.decodeIfPresent(String.self, forKey: .firstArrowBlockName)
        secondArrowBlockName = try c.decodeIfPresent(String.self, forKey: .secondArrowBlockName)
        linearScaleFactor = try c.decodeIfPresent(Double.self, forKey: .linearScaleFactor)
        dimensionPrefix = try c.decodeIfPresent(String.self, forKey: .dimensionPrefix)
        dimensionSuffix = try c.decodeIfPresent(String.self, forKey: .dimensionSuffix)
        zeroSuppression = try c.decodeIfPresent(Int.self, forKey: .zeroSuppression)
        textBackgroundScale = try c.decodeIfPresent(Double.self, forKey: .textBackgroundScale)
        textBackgroundColor = try c.decodeIfPresent(ColorRGBA.self, forKey: .textBackgroundColor)
        textBackgroundUsesViewportColor = try c.decode(Bool.self, forKey: .textBackgroundUsesViewportColor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(overallScale, forKey: .overallScale)
        try c.encode(arrowSize, forKey: .arrowSize)
        try c.encode(textHeight, forKey: .textHeight)
        try c.encode(textOffset, forKey: .textOffset)
        try c.encode(extensionLineOffset, forKey: .extensionLineOffset)
        try c.encode(extensionLineExtend, forKey: .extensionLineExtend)
        try c.encode(dimLineOffset, forKey: .dimLineOffset)
        try c.encode(tickSize, forKey: .tickSize)
        try c.encode(unitsFormat, forKey: .unitsFormat)
        try c.encode(unitsPrecision, forKey: .unitsPrecision)
        try c.encode(angleFormat, forKey: .angleFormat)
        try c.encode(anglePrecision, forKey: .anglePrecision)
        try c.encodeIfPresent(textStyle, forKey: .textStyle)
        try c.encode(suppressFirstExtension, forKey: .suppressFirstExtension)
        try c.encode(suppressSecondExtension, forKey: .suppressSecondExtension)
        try c.encode(suppressFirstDimLine, forKey: .suppressFirstDimLine)
        try c.encode(suppressSecondDimLine, forKey: .suppressSecondDimLine)
        try c.encodeIfPresent(firstArrowhead, forKey: .firstArrowhead)
        try c.encodeIfPresent(secondArrowhead, forKey: .secondArrowhead)
        try c.encodeIfPresent(firstArrowBlockName, forKey: .firstArrowBlockName)
        try c.encodeIfPresent(secondArrowBlockName, forKey: .secondArrowBlockName)
        try c.encodeIfPresent(linearScaleFactor, forKey: .linearScaleFactor)
        try c.encodeIfPresent(dimensionPrefix, forKey: .dimensionPrefix)
        try c.encodeIfPresent(dimensionSuffix, forKey: .dimensionSuffix)
        try c.encodeIfPresent(zeroSuppression, forKey: .zeroSuppression)
        try c.encodeIfPresent(textBackgroundScale, forKey: .textBackgroundScale)
        try c.encodeIfPresent(textBackgroundColor, forKey: .textBackgroundColor)
        try c.encode(textBackgroundUsesViewportColor, forKey: .textBackgroundUsesViewportColor)
    }
    
    public func formatMeasurement(_ value: Double, prefix: String = "", suffix: String = "") -> String {
        formatDXFMeasurement(value, prefix: prefix, suffix: suffix)
    }
    
    public func formatAngle(_ radians: Double) -> String {
        formatDXFAngle(radians)
    }
}
