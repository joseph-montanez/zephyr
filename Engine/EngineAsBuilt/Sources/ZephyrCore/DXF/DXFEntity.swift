import Foundation

// MARK: - DXFVersion (single canonical definition)

/// AutoCAD DXF format versions, matching libdxfrw DRW::Version
public enum DXFVersion: String, Sendable {
    case unknown     = "UNKNOWN"
    case r10         = "AC1006"
    case r12         = "AC1009"
    case r13         = "AC1012"
    case r14         = "AC1014"
    case r2000       = "AC1015"
    case r2004       = "AC1018"
    case r2007       = "AC1021"
    case r2010       = "AC1024"
    case r2013       = "AC1027"
    case r2018       = "AC1032"

    public static let defaultExport: DXFVersion = .r2018
}

// MARK: - Line Width

/// Line weight enum matching DRW_LW_Conv::lineWidth
public enum DXFLineWidth: Int, Sendable {
    case w00    = 0
    case w01    = 1
    case w02    = 2
    case w03    = 3
    case w04    = 4
    case w05    = 5
    case w06    = 6
    case w07    = 7
    case w08    = 8
    case w09    = 9
    case w10    = 10
    case w11    = 11
    case w12    = 12
    case w13    = 13
    case w14    = 14
    case w15    = 15
    case w16    = 16
    case w17    = 17
    case w18    = 18
    case w19    = 19
    case w20    = 20
    case w21    = 21
    case w22    = 22
    case w23    = 23
    case byLayer   = 29
    case byBlock   = 30
    case byDefault = 31

    public static func fromDXF(_ i: Int) -> DXFLineWidth {
        if i < 0 {
            if i == -1 { return .byLayer }
            else if i == -2 { return .byBlock }
            else { return .byDefault }
        }
        // map DXF integer codes (5, 9, 13, ...) back to enum
        let map: [(Int, DXFLineWidth)] = [
            (0, .w00), (5, .w01), (9, .w02), (13, .w03), (15, .w04),
            (18, .w05), (20, .w06), (25, .w07), (30, .w08), (35, .w09),
            (40, .w10), (50, .w11), (53, .w12), (60, .w13), (70, .w14),
            (80, .w15), (90, .w16), (100, .w17), (106, .w18), (120, .w19),
            (140, .w20), (158, .w21), (200, .w22), (211, .w23)
        ]
        for (code, _) in map where i <= code {
            // simple range matching like libdxfrw
            if i <= 3 { return .w00 }
            if i <= 7 { return .w01 }
            if i <= 11 { return .w02 }
            if i <= 14 { return .w03 }
            if i <= 16 { return .w04 }
            if i <= 19 { return .w05 }
            if i <= 22 { return .w06 }
            if i <= 27 { return .w07 }
            if i <= 32 { return .w08 }
            if i <= 37 { return .w09 }
            if i <= 45 { return .w10 }
            if i <= 52 { return .w11 }
            if i <= 57 { return .w12 }
            if i <= 65 { return .w13 }
            if i <= 75 { return .w14 }
            if i <= 85 { return .w15 }
            if i <= 95 { return .w16 }
            if i <= 103 { return .w17 }
            if i <= 112 { return .w18 }
            if i <= 130 { return .w19 }
            if i <= 149 { return .w20 }
            if i <= 180 { return .w21 }
            if i <= 205 { return .w22 }
            return .w23
        }
        return .byDefault
    }

    public var dxfInt: Int {
        switch self {
        case .byLayer:   return -1
        case .byBlock:   return -2
        case .byDefault: return -3
        case .w00: return 0;  case .w01: return 5
        case .w02: return 9;  case .w03: return 13
        case .w04: return 15; case .w05: return 18
        case .w06: return 20; case .w07: return 25
        case .w08: return 30; case .w09: return 35
        case .w10: return 40; case .w11: return 50
        case .w12: return 53; case .w13: return 60
        case .w14: return 70; case .w15: return 80
        case .w16: return 90; case .w17: return 100
        case .w18: return 106; case .w19: return 120
        case .w20: return 140; case .w21: return 158
        case .w22: return 200; case .w23: return 211
        }
    }
}

// MARK: - Entity Types (matching libdxfrw DRW::ETYPE)

/// DXF entity type enum, matching DRW::ETYPE
public enum DXFEType: String, Sendable {
    case e3DFACE       = "3DFACE"
    case aRC           = "ARC"
    case bLOCK         = "BLOCK"
    case cIRCLE        = "CIRCLE"
    case dIMENSION     = "DIMENSION"
    case dIMALIGNED    = "DIMALIGNED"
    case dIMLINEAR     = "DIMLINEAR"
    case dIMRADIAL     = "DIMRADIAL"
    case dIMDIAMETRIC  = "DIMDIAMETRIC"
    case dIMANGULAR    = "DIMANGULAR"
    case dIMANGULAR3P  = "DIMANGULAR3P"
    case dIMORDINATE   = "DIMORDINATE"
    case eLLIPSE       = "ELLIPSE"
    case hATCH         = "HATCH"
    case iMAGE         = "IMAGE"
    case iNSERT        = "INSERT"
    case lEADER        = "LEADER"
    case mLEADER       = "MULTILEADER"
    case lINE          = "LINE"
    case lWPOLYLINE    = "LWPOLYLINE"
    case mTEXT         = "MTEXT"
    case pOINT         = "POINT"
    case pOLYLINE      = "POLYLINE"
    case rAY           = "RAY"
    case sOLID         = "SOLID"
    case sPLINE        = "SPLINE"
    case tABLE         = "ACAD_TABLE"
    case tEXT          = "TEXT"
    case tRACE         = "TRACE"
    case vIEWPORT      = "VIEWPORT"
    case xLINE         = "XLINE"
    case vERTEX        = "VERTEX"
    case sEQEND        = "SEQEND"
    case aTTDEF        = "ATTDEF"
    case aTTRIB        = "ATTRIB"
    case uNKNOWN       = "UNKNOWN"
}

// MARK: - Table Entry Types (matching DRW::TTYPE)

public enum DXFTableType: String, Sendable {
    case unknown      = "UNKNOWNT"
    case ltype        = "LTYPE"
    case layer        = "LAYER"
    case style        = "STYLE"
    case dimstyle     = "DIMSTYLE"
    case vport        = "VPORT"
    case blockRecord  = "BLOCK_RECORD"
    case appid        = "APPID"
    case imagedef     = "IMAGEDEF"
}

// MARK: - Layout object

public struct DXFLayoutEntry: Sendable {
    public var name: String
    public var tabOrder: Int
    public var blockRecordHandle: UInt32
    public var minimumLimits: Vector3
    public var maximumLimits: Vector3

    public init(
        name: String = "",
        tabOrder: Int = Int.max,
        blockRecordHandle: UInt32 = 0,
        minimumLimits: Vector3 = .zero,
        maximumLimits: Vector3 = Vector3(x: 12, y: 9, z: 0)
    ) {
        self.name = name
        self.tabOrder = tabOrder
        self.blockRecordHandle = blockRecordHandle
        self.minimumLimits = minimumLimits
        self.maximumLimits = maximumLimits
    }
}

// MARK: - DRW_Coord equivalent

/// 2D vertex with bulge (for LWPolyline)
public class DXFVertex2D {
    public var x: Double
    public var y: Double
    public var startWidth: Double
    public var endWidth: Double
    public var bulge: Double

    public init(x: Double = 0, y: Double = 0, startWidth: Double = 0, endWidth: Double = 0, bulge: Double = 0) {
        self.x = x; self.y = y; self.startWidth = startWidth; self.endWidth = endWidth; self.bulge = bulge
    }
}

// MARK: - Base Entity (DRW_Entity)

/// Base class for all DXF entities. Mirrors DRW_Entity in libdxfrw.
open class DXFEntity {
    public var eType: DXFEType
    public var handle: UInt32
    public var parentHandle: UInt32
    public var layer: String
    public var lineType: String
    public var color: Int32     // ACI color, 256=BYLAYER, 0=BYBLOCK
    public var color24: Int32   // 24-bit color, -1=not set
    public var colorName: String // named color, group 430
    public var transparency: Int32 // entity transparency, group 440; -1=not set
    public var plotStyleHandle: UInt32 // hard-pointer handle, group 390
    public var lWeight: DXFLineWidth
    public var ltypeScale: Double
    public var visible: Bool
    public var space: Int       // 0=model, 1=paper
    public var thickness: Double
    public var extrusion: Vector3  // normal vector (210,220,230)
    public var haveExtrusion: Bool

    /// Extended data (XDATA) groups 1000-1071
    public var extendedData: [(code: Int, value: Any)] = []

    /// Application-defined data (group 102). Outer array = each {appId...} block.
    /// Inner array = group code/value pairs within that block.
    public var appData: [[(code: Int, value: Any)]] = []

    // MARK: - Extrusion (OCS → WCS)

    /// Calculate arbitrary axis for extrusion (OCS to WCS).
    /// Mirrors DRW_Entity::calculateAxis().
    public func calculateAxis(_ ext: Vector3) -> (axisX: Vector3, axisY: Vector3) {
        let axisX: Vector3
        if abs(ext.x) < 0.015625 && abs(ext.y) < 0.015625 {
            axisX = Vector3(x: ext.z, y: 0, z: -ext.x)
        } else {
            axisX = Vector3(x: -ext.y, y: ext.x, z: 0)
        }
        let unitX = axisX.normalized
        let axisY = Vector3(
            x: ext.y * unitX.z - unitX.y * ext.z,
            y: ext.z * unitX.x - unitX.z * ext.x,
            z: ext.x * unitX.y - unitX.x * ext.y
        ).normalized
        return (unitX, axisY)
    }

    /// Extrude a point from OCS to WCS using calculated axes.
    /// Mirrors DRW_Entity::extrudePoint().
    public func extrudePoint(extrusion e: Vector3, axisX ax: Vector3, axisY ay: Vector3, point p: inout Vector3) {
        let px = ax.x * p.x + ay.x * p.y + e.x * p.z
        let py = ax.y * p.x + ay.y * p.y + e.y * p.z
        let pz = ax.z * p.x + ay.z * p.y + e.z * p.z
        p.x = px; p.y = py; p.z = pz
    }

    /// Apply extrusion to this entity's coordinates (if haveExtrusion is true).
    open func applyExtrusion() { }

    public init(eType: DXFEType = .uNKNOWN) {
        self.eType = eType
        self.handle = 0
        self.parentHandle = 0
        self.layer = "0"
        self.lineType = "BYLAYER"
        self.color = 256       // BYLAYER
        self.color24 = -1
        self.colorName = ""
        self.transparency = -1
        self.plotStyleHandle = 0
        self.lWeight = .byLayer
        self.ltypeScale = 1.0
        self.visible = true
        self.space = 0
        self.thickness = 0
        self.extrusion = Vector3(x: 0, y: 0, z: 1)
        self.haveExtrusion = false
    }
}

// MARK: - Point (DRW_Point)

open class DXFPointEntity: DXFEntity {
    public var basePoint: Vector3  // 10,20,30
    public var thickness_p: Double // 39

    public override init(eType: DXFEType = .pOINT) {
        self.basePoint = .zero
        self.thickness_p = 0
        super.init(eType: eType)
    }
}

// MARK: - Line (DRW_Line)

open class DXFLineEntity: DXFPointEntity {
    public var secPoint: Vector3  // 11,21,31

    public override init(eType: DXFEType = .lINE) {
        self.secPoint = .zero
        super.init(eType: eType)
    }
}

// MARK: - Ray (DRW_Ray)

public class DXFRayEntity: DXFLineEntity {
    public override init(eType: DXFEType = .rAY) {
        super.init(eType: eType)
    }
}

// MARK: - XLine (DRW_Xline)

public class DXFXLineEntity: DXFRayEntity {
    public override init(eType: DXFEType = .xLINE) {
        super.init(eType: eType)
    }
}

// MARK: - Circle (DRW_Circle)

open class DXFCircleEntity: DXFPointEntity {
    public var radius: Double  // 40

    public override func applyExtrusion() {
        if haveExtrusion {
            let (ax, ay) = calculateAxis(extrusion)
            extrudePoint(extrusion: extrusion, axisX: ax, axisY: ay, point: &basePoint)
        }
    }

    public override init(eType: DXFEType = .cIRCLE) {
        self.radius = 0
        super.init(eType: eType)
    }
}

// MARK: - Arc (DRW_Arc)

open class DXFArcEntity: DXFCircleEntity {
    public override func applyExtrusion() {
        if haveExtrusion {
            let (ax, ay) = calculateAxis(extrusion)
            extrudePoint(extrusion: extrusion, axisX: ax, axisY: ay, point: &basePoint)
            // Arc angles may need adjustment based on extrusion direction
            if extrusion.z < 0 {
                let tmp = startAngle; startAngle = endAngle; endAngle = tmp
            }
        }
    }

    public var startAngle: Double  // 50 (radians)
    public var endAngle: Double    // 51 (radians)
    public var isCCW: Int          // 73

    public override init(eType: DXFEType = .aRC) {
        self.startAngle = 0
        self.endAngle = 0
        self.isCCW = 1
        super.init(eType: eType)
    }
}

// MARK: - Ellipse (DRW_Ellipse)

public class DXFEllipseEntity: DXFLineEntity {
    public var ratio: Double       // 40
    public var startParam: Double  // 41 (radians)
    public var endParam: Double    // 42 (radians)
    public var isCCW: Int          // 73

    public override init(eType: DXFEType = .eLLIPSE) {
        self.ratio = 1
        self.startParam = 0
        self.endParam = 2 * .pi
        self.isCCW = 1
        super.init(eType: eType)
    }

    /// Normalize axis/ratio/params for writing. Mirrors DRW_Ellipse::correctAxis().
    public func correctAxis() {
        let complete: Bool
        if startParam == endParam {
            startParam = 0.0
            endParam = 2.0 * .pi
            complete = true
        } else {
            complete = abs(endParam - startParam - 2.0 * .pi) < 1.0e-10
        }
        if ratio > 1 {
            let incX = secPoint.x
            secPoint.x = -(secPoint.y * ratio)
            secPoint.y = incX * ratio
            ratio = 1.0 / ratio
            if !complete {
                let halfPi = .pi / 2.0
                if startParam < halfPi { startParam += 2.0 * .pi }
                if endParam < halfPi { endParam += 2.0 * .pi }
                endParam -= halfPi
                startParam -= halfPi
            }
        }
    }

    /// Convert ellipse to polyline approximation (R12 fallback).
    /// Mirrors DRW_Ellipse::toPolyline(). Parts = number of segments.
    public func toPolyline(parts: Int = 128) -> DXFPolylineEntity {
        let pol = DXFPolylineEntity()
        let radMajor = sqrt(secPoint.x * secPoint.x + secPoint.y * secPoint.y)
        let radMinor = radMajor * ratio
        let incAngle = atan2(secPoint.y, secPoint.x)
        let cosRot = cos(incAngle)
        let sinRot = sin(incAngle)
        let step = 2.0 * .pi / Double(parts)
        var curAngle = startParam
        var i = Int(curAngle / step)
        while i < parts {
            if curAngle > endParam { curAngle = endParam; i = parts + 2 }
            let cosCurr = cos(curAngle)
            let sinCurr = sin(curAngle)
            let x = basePoint.x + (cosCurr * cosRot * radMajor) - (sinCurr * sinRot * radMinor)
            let y = basePoint.y + (cosCurr * sinRot * radMajor) + (sinCurr * cosRot * radMinor)
            let v = DXFVertexEntity()
            v.basePoint = Vector3(x: x, y: y, z: 0)
            pol.vertices.append(v)
            i += 1
            curAngle = Double(i) * step
        }
        if abs(endParam - startParam - 2.0 * .pi) < 1.0e-10 {
            pol.flags = 1  // closed
        }
        pol.layer = layer
        pol.lineType = lineType
        pol.color = color
        pol.lWeight = lWeight
        pol.extrusion = extrusion
        return pol
    }
}

// MARK: - Trace (DRW_Trace)

open class DXFTraceEntity: DXFLineEntity {
    public var thirdPoint: Vector3  // 12,22,32
    public var fourPoint: Vector3   // 13,23,33

    public override init(eType: DXFEType = .tRACE) {
        self.thirdPoint = .zero
        self.fourPoint = .zero
        super.init(eType: eType)
    }
}

// MARK: - Solid (DRW_Solid)

public class DXFSolidEntity: DXFTraceEntity {
    public override init(eType: DXFEType = .sOLID) {
        super.init(eType: eType)
    }
}

// MARK: - 3DFace (DRW_3Dface)

public class DXF3DFaceEntity: DXFTraceEntity {
    public var invisibleFlag: Int  // 70

    public override init(eType: DXFEType = .e3DFACE) {
        self.invisibleFlag = 0
        super.init(eType: eType)
    }
}

// MARK: - Block (DRW_Block)

public class DXFBlockEntity: DXFPointEntity {
    public var name: String    // 2
    public var flags: Int      // 70
    public var entities: [DXFEntity] = []

    public override init(eType: DXFEType = .bLOCK) {
        self.name = ""
        self.flags = 0
        super.init(eType: eType)
    }
}

// MARK: - Insert (DRW_Insert)

public class DXFInsertEntity: DXFPointEntity {
    public var name: String    // 2
    public var xScale: Double  // 41
    public var yScale: Double  // 42
    public var zScale: Double  // 43
    public var angle: Double   // 50 (radians)
    public var colCount: Int   // 70
    public var rowCount: Int   // 71
    public var colSpace: Double // 44
    public var rowSpace: Double // 45
    public var attributesFollow: Bool // 66
    public var attributes: [DXFTextEntity]

    public override init(eType: DXFEType = .iNSERT) {
        self.name = ""
        self.xScale = 1
        self.yScale = 1
        self.zScale = 1
        self.angle = 0
        self.colCount = 1
        self.rowCount = 1
        self.colSpace = 0
        self.rowSpace = 0
        self.attributesFollow = false
        self.attributes = []
        super.init(eType: eType)
    }
}

// MARK: - LWPolyline (DRW_LWPolyline)

public class DXFLWPolylineEntity: DXFEntity {
    public var vertexCount: Int      // 90
    public var flags: Int            // 70
    public var width: Double         // 43
    public var elevation: Double     // 38
    public var thickness_p: Double   // 39
    public var extPoint: Vector3     // 210,220,230

    public var vertices: [DXFVertex2D] = []

    public override func applyExtrusion() {
        if haveExtrusion {
            let (ax, ay) = calculateAxis(extPoint)
            for v in vertices {
                var pt = Vector3(x: v.x, y: v.y, z: elevation)
                extrudePoint(extrusion: extPoint, axisX: ax, axisY: ay, point: &pt)
                v.x = pt.x; v.y = pt.y
            }
        }
    }

    public override init(eType: DXFEType = .lWPOLYLINE) {
        self.vertexCount = 0
        self.flags = 0
        self.width = 0
        self.elevation = 0
        self.thickness_p = 0
        self.extPoint = Vector3(x: 0, y: 0, z: 1)
        super.init(eType: eType)
    }
}

// MARK: - Text (DRW_Text)

open class DXFTextEntity: DXFLineEntity {
    public var height: Double        // 40
    public var text: String          // 1
    public var angle_p: Double       // 50 (degrees)
    public var widthScale: Double    // 41
    public var oblique: Double       // 51
    public var hasExplicitHeight: Bool
    public var hasExplicitWidthScale: Bool
    public var hasExplicitOblique: Bool
    public var style: String         // 7
    public var textGen: Int          // 71
    public var alignH: Int           // 72  (0=left,1=center,2=right,3=aligned,4=middle,5=fit)
    public var alignV: Int           // 73  (0=baseline,1=bottom,2=middle,3=top)
    public var isAttribute: Bool
    public var isAttributeDefinition: Bool
    public var attributeTag: String
    public var attributeFlags: Int

    public override init(eType: DXFEType = .tEXT) {
        self.height = 0
        self.text = ""
        self.angle_p = 0
        self.widthScale = 1
        self.oblique = 0
        self.hasExplicitHeight = false
        self.hasExplicitWidthScale = false
        self.hasExplicitOblique = false
        self.style = "STANDARD"
        self.textGen = 0
        self.alignH = 0
        self.alignV = 0
        self.isAttribute = false
        self.isAttributeDefinition = false
        self.attributeTag = ""
        self.attributeFlags = 0
        super.init(eType: eType)
    }
}

// MARK: - MText (DRW_MText)

public class DXFMTextEntity: DXFTextEntity {
    public var interlin: Double   // 44
    public var lineSpacingStyle: Int   // 73: 1 = at least, 2 = exact
    public var backgroundFillFlags: Int   // 90
    public var backgroundScale: Double    // 45
    public var backgroundColor: Int       // 63
    public var backgroundColor24: Int     // 421
    public var backgroundTransparency: Int // 441

    public override init(eType: DXFEType = .mTEXT) {
        self.interlin = 1
        self.lineSpacingStyle = 1
        self.backgroundFillFlags = 0
        self.backgroundScale = 1.5
        self.backgroundColor = -1
        self.backgroundColor24 = -1
        self.backgroundTransparency = -1
        super.init(eType: eType)
        self.alignH = 0
        self.alignV = 3
        self.textGen = 1
    }
}

// MARK: - Vertex (DRW_Vertex)

public class DXFVertexEntity: DXFPointEntity {
    public var startWidth: Double   // 40
    public var endWidth: Double     // 41
    public var bulge: Double        // 42
    public var flags: Int           // 70
    public var tangentDir: Double   // 50
    public var vIndex1: Int         // 71
    public var vIndex2: Int         // 72
    public var vIndex3: Int         // 73
    public var vIndex4: Int         // 74
    public var identifier: Int      // 91

    public override init(eType: DXFEType = .vERTEX) {
        self.startWidth = 0
        self.endWidth = 0
        self.bulge = 0
        self.flags = 0
        self.tangentDir = 0
        self.vIndex1 = 0
        self.vIndex2 = 0
        self.vIndex3 = 0
        self.vIndex4 = 0
        self.identifier = 0
        super.init(eType: eType)
    }
}

// MARK: - Polyline (DRW_Polyline)

public class DXFPolylineEntity: DXFPointEntity {
    public var flags: Int             // 70
    public var defStartWidth: Double  // 40
    public var defEndWidth: Double    // 41
    public var vertexCount: Int       // 71
    public var faceCount: Int         // 72
    public var smoothM: Int           // 73
    public var smoothN: Int           // 74
    public var curveType: Int         // 75

    public var vertices: [DXFVertexEntity] = []

    public override init(eType: DXFEType = .pOLYLINE) {
        self.flags = 0
        self.defStartWidth = 0
        self.defEndWidth = 0
        self.vertexCount = 0
        self.faceCount = 0
        self.smoothM = 0
        self.smoothN = 0
        self.curveType = 0
        super.init(eType: eType)
    }
}

// MARK: - Spline (DRW_Spline)

public class DXFSplineEntity: DXFEntity {
    public var normalVec: Vector3    // 210,220,230
    public var tgStart: Vector3      // 12,22,32
    public var tgEnd: Vector3        // 13,23,33
    public var flags: Int            // 70
    public var degree: Int           // 71
    public var nKnots: Int32         // 72
    public var nControl: Int32       // 73
    public var nFit: Int32           // 74
    public var tolKnot: Double       // 42
    public var tolControl: Double    // 43
    public var tolFit: Double        // 44

    public var knots: [Double] = []
    public var weights: [Double] = []
    public var controlPoints: [Vector3] = []
    public var fitPoints: [Vector3] = []

    public override init(eType: DXFEType = .sPLINE) {
        self.normalVec = Vector3(x: 0, y: 0, z: 1)
        self.tgStart = .zero
        self.tgEnd = .zero
        self.flags = 0
        self.degree = 3
        self.nKnots = 0
        self.nControl = 0
        self.nFit = 0
        self.tolKnot = 0.0000001
        self.tolControl = 0.0000001
        self.tolFit = 0.0000001
        super.init(eType: eType)
    }
}

// MARK: - Hatch Loop (DRW_HatchLoop)

public class DXFHatchLoop {
    public var type: Int        // 92: polyline=2, default=0
    public var numEdges: Int    // 93
    public var entities: [DXFEntity] = []
    public var sourceBoundaryHandles: [UInt32] = []
    public var sourceBoundaryEntities: [DXFEntity] = []

    public init(type: Int = 0) {
        self.type = type
        self.numEdges = 0
    }
}

public struct DXFHatchPatternLineData: Equatable, Sendable {
    public var angle: Double
    public var base: Vector3
    public var offset: Vector3
    public var dashes: [Double]

    public init(angle: Double = 0.0, base: Vector3 = .zero, offset: Vector3 = .zero, dashes: [Double] = []) {
        self.angle = angle
        self.base = base
        self.offset = offset
        self.dashes = dashes
    }
}

// MARK: - Hatch (DRW_Hatch)

public class DXFHatchEntity: DXFPointEntity {
    public var name: String            // 2 pattern name
    public var solid: Int              // 70: solid=1, pattern=0
    public var associative: Int        // 71
    public var hStyle: Int             // 75
    public var hPattern: Int           // 76
    public var bgColor: Int32          // 63 (-1 if not set)
    public var doubleFlag: Int         // 77
    public var loopsNum: Int           // 91
    public var angle_p: Double         // 52 (degrees)
    public var scale: Double           // 41
    public var defLines: Int           // 78

    // Gradient (codes 450-470)
    public var isGradient: Int         // 450
    public var gradientName: String    // 470
    public var gradientAngle: Double   // 460 (degrees)
    public var gradientShift: Double   // 461
    public var singleColorGrad: Int    // 452
    public var gradientTint: Double    // 462

    public var gradientColors: [(position: Double, aci: UInt16, rgb: Int32)] = []
    public var patternLines: [DXFHatchPatternLineData] = []

    public var loops: [DXFHatchLoop] = []

    // Hatch boundary tracking (matching libdxfrw internal pointers)
    public var pt: DXFPointEntity?
    public var line: DXFLineEntity?
    public var arc: DXFArcEntity?
    public var ellipse: DXFEllipseEntity?
    public var spline: DXFSplineEntity?
    public var pline: DXFLWPolylineEntity?
    public var plvert: DXFVertex2D?

    public func clearEntities() {
        pt = nil; line = nil; pline = nil
        arc = nil; ellipse = nil; spline = nil
        plvert = nil
    }

    public func addLine() {
        clearEntities()
        let l = DXFLineEntity()
        line = l; pt = l
        loops.last?.entities.append(l)
    }

    public func addArc() {
        clearEntities()
        let a = DXFArcEntity()
        arc = a; pt = a
        loops.last?.entities.append(a)
    }

    public func addEllipse() {
        clearEntities()
        let e2 = DXFEllipseEntity()
        ellipse = e2; pt = e2
        loops.last?.entities.append(e2)
    }

    public func addSpline() {
        clearEntities()
        pt = nil
        let s = DXFSplineEntity()
        spline = s
        loops.last?.entities.append(s)
    }

    public override init(eType: DXFEType = .hATCH) {
        self.name = ""
        self.solid = 1
        self.associative = 0
        self.hStyle = 0
        self.hPattern = 1
        self.bgColor = -1
        self.doubleFlag = 0
        self.loopsNum = 0
        self.angle_p = 0
        self.scale = 1
        self.defLines = 0
        self.isGradient = 0
        self.gradientName = ""
        self.gradientAngle = 0
        self.gradientShift = 0
        self.singleColorGrad = 0
        self.gradientTint = 0
        super.init(eType: eType)
    }
}

// MARK: - Image (DRW_Image)

public class DXFImageEntity: DXFLineEntity {
    public var ref: UInt32             // 340
    public var imageFilePath: String   // resolved IMAGEDEF path/name
    public var vVector: Vector3        // 12,22,32
    public var sizeU: Double           // 13
    public var sizeV: Double           // 23
    public var dz: Double              // 33
    public var clip: Int               // 280
    public var brightness: Int         // 281
    public var contrast: Int           // 282
    public var fade: Int               // 283

    public override init(eType: DXFEType = .iMAGE) {
        self.ref = 0
        self.imageFilePath = ""
        self.vVector = .zero
        self.sizeU = 0
        self.sizeV = 0
        self.dz = 0
        self.clip = 0
        self.brightness = 50
        self.contrast = 50
        self.fade = 0
        super.init(eType: eType)
    }
}

// MARK: - Dimension (DRW_Dimension)

open class DXFDimensionEntity: DXFEntity {
    public var type: Int               // 70
    public var name: String            // 2 block name
    public var defPoint: Vector3       // 10,20,30 (WCS)
    public var textPoint: Vector3      // 11,21,31 (OCS)
    public var text: String            // 1
    public var style: String           // 3
    public var align: Int              // 71
    public var lineStyle: Int          // 72
    public var lineFactor: Double      // 41
    public var rot: Double             // 53
    public var hasTextRotation: Bool
    public var extPoint: Vector3       // 210,220,230

    // dimension subtype specific (DRW_Dimension internals)
    public var clonePoint: Vector3     // 12,22,32
    public var def1: Vector3           // 13,23,33
    public var def2: Vector3           // 14,24,34
    public var angle_p: Double         // 50
    public var oblique: Double         // 52
    public var circlePoint: Vector3    // 15,25,35
    public var arcPoint: Vector3       // 16,26,36
    public var length: Double          // 40
    public var measurement: Double     // 42 actual measurement

    public override init(eType: DXFEType = .dIMENSION) {
        self.type = 0
        self.name = ""
        self.defPoint = .zero
        self.textPoint = .zero
        self.text = ""
        self.style = "STANDARD"
        self.align = 5
        self.lineStyle = 1
        self.lineFactor = 1
        self.rot = 0
        self.hasTextRotation = false
        self.extPoint = Vector3(x: 0, y: 0, z: 1)
        self.clonePoint = .zero
        self.def1 = .zero
        self.def2 = .zero
        self.angle_p = 0
        self.oblique = 0
        self.circlePoint = .zero
        self.arcPoint = .zero
        self.length = 0
        self.measurement = .nan
        super.init(eType: eType)
    }
}

// MARK: - Leader (DRW_Leader)

public class DXFLeaderEntity: DXFEntity {
    public var style: String           // 3
    public var arrow: Int              // 71
    public var leaderType: Int         // 72
    public var flag: Int               // 73
    public var hookLine: Int           // 74
    public var hookFlag: Int           // 75
    public var textHeight: Double      // 40
    public var textWidth: Double       // 41
    public var vertNum: Int            // 76
    public var colorUse: Int           // 77
    public var annotHandle: UInt32     // 340
    public var annotation: DXFEntity?
    public var extrusionPoint: Vector3 // 210,220,230
    public var horizDir: Vector3       // 211,221,231
    public var offsetBlock: Vector3    // 212,222,232
    public var offsetText: Vector3     // 213,223,233
    public var vertices: [Vector3] = []

    public override init(eType: DXFEType = .lEADER) {
        self.style = ""
        self.arrow = 1
        self.leaderType = 0
        self.flag = 3
        self.hookLine = 0
        self.hookFlag = 0
        self.textHeight = 0
        self.textWidth = 0
        self.vertNum = 0
        self.colorUse = 0
        self.annotHandle = 0
        self.annotation = nil
        self.extrusionPoint = Vector3(x: 0, y: 0, z: 1)
        self.horizDir = .zero
        self.offsetBlock = .zero
        self.offsetText = .zero
        super.init(eType: eType)
    }
}

// MARK: - Multileader

public struct DXFMLeaderStyleEntry: Sendable {
    public var handle: UInt32 = 0
    public var name: String = "Standard"
    public var pathType: Int = 1
    public var contentType: Int = 2
    public var maxLeaderPoints: Int = 2
    public var arrowSize: Double = 2.5
    public var landingGap: Double = 1.25
    public var doglegLength: Double = 8
    public var textHeight: Double = 2.5
    public var textStyleHandle: UInt32 = 0
    public var arrowheadHandle: UInt32 = 0
    public var arrowheadName: String = ""
    public var leftAttachment: Int = 1
    public var rightAttachment: Int = 1
    public var textAngleType: Int = 0
    public var textAlignment: Int = 0
    public var alwaysLeftJustify: Bool = false
    public var attachmentDirection: Int = 0
    public var bottomAttachment: Int = 9
    public var topAttachment: Int = 9
    public var landingEnabled: Bool = true
    public var doglegEnabled: Bool = true
    public var textFrameEnabled: Bool = false
    public var blockScale: Double = 1
    public var blockRotation: Double = 0

    public init() {}
}

public struct DXFMLeaderBlockAttribute: Sendable {
    public var definitionHandle: UInt32
    public var tag: String
    public var index: Int
    public var width: Double
    public var text: String

    public init(
        definitionHandle: UInt32 = 0,
        tag: String = "",
        index: Int = 0,
        width: Double = 0,
        text: String = ""
    ) {
        self.definitionHandle = definitionHandle
        self.tag = tag
        self.index = index
        self.width = width
        self.text = text
    }
}

public struct DXFMLeaderBranch: Sendable {
    public var vertices: [Vector3]
    public var doglegDirection: Vector3?
    public var doglegLength: Double?
    public var leaderLineIndex: Int?
    public var arrowheadHandle: UInt32
    public var arrowheadName: String

    public init(
        vertices: [Vector3] = [],
        doglegDirection: Vector3? = nil,
        doglegLength: Double? = nil,
        leaderLineIndex: Int? = nil,
        arrowheadHandle: UInt32 = 0,
        arrowheadName: String = ""
    ) {
        self.vertices = vertices
        self.doglegDirection = doglegDirection
        self.doglegLength = doglegLength
        self.leaderLineIndex = leaderLineIndex
        self.arrowheadHandle = arrowheadHandle
        self.arrowheadName = arrowheadName
    }
}

public class DXFMLeaderEntity: DXFEntity {
    public var styleHandle: UInt32 = 0
    public var styleName: String = "Standard"
    public var textStyleHandle: UInt32 = 0
    public var blockContentHandle: UInt32 = 0
    public var arrowheadHandle: UInt32 = 0
    public var arrowheadName: String = ""
    public var arrowheadOverrides: [Int: UInt32] = [:]
    public var contentScale: Double = 1
    public var hasContextScale: Bool = false
    public var contentType: Int = 2
    public var pathType: Int = 1
    public var text: String = ""
    public var contentBasePosition: Vector3?
    public var textPosition: Vector3 = .zero
    public var textDirection: Vector3 = Vector3(x: 1, y: 0, z: 0)
    public var textRotation: Double = 0
    public var textAttachment: Int = 1
    public var textFlowDirection: Int = 5
    public var textDirectionNegative: Bool = false
    public var textAlignInIPE: Int = 0
    public var textAttachmentPoint: Int = 1
    public var leftAttachment: Int = 1
    public var rightAttachment: Int = 1
    public var textAngleType: Int = 0
    public var textAlignment: Int = 0
    public var alwaysLeftJustify: Bool = false
    public var attachmentDirection: Int = 0
    public var bottomAttachment: Int = 9
    public var topAttachment: Int = 9
    public var textHeight: Double = 2.5
    public var hasContextTextHeight: Bool = false
    public var textWidth: Double = 0
    public var textStyleName: String = "Standard"
    public var textFrameEnabled: Bool = false
    public var maxLeaderPoints: Int = 2
    public var blockScale: Double = 1
    public var blockRotation: Double = 0
    public var arrowSize: Double = 2.5
    public var hasContextArrowSize: Bool = false
    public var landingGap: Double = 1.25
    public var hasContextLandingGap: Bool = false
    public var doglegLength: Double = 8
    public var landingEnabled: Bool = true
    public var doglegEnabled: Bool = true
    public var blockName: String = ""
    public var blockAttributes: [DXFMLeaderBlockAttribute] = []
    public var branches: [DXFMLeaderBranch] = []

    public override init(eType: DXFEType = .mLEADER) {
        super.init(eType: eType)
    }
}

// MARK: - Viewport (DRW_Viewport)

public class DXFViewportEntity: DXFPointEntity {
    public var vpStatus: Int          // 68
    public var vpID: Int              // 69
    public var psWidth: Double        // 40
    public var psHeight: Double       // 41
    public var centerPX: Double       // 12
    public var centerPY: Double       // 22
    public var viewTarget: Vector3    // 17,27,37
    public var viewHeight: Double     // 45
    public var twistAngle: Double     // 51

    public override init(eType: DXFEType = .vIEWPORT) {
        self.vpStatus = 0
        self.vpID = 0
        self.psWidth = 205
        self.psHeight = 156
        self.centerPX = 128.5
        self.centerPY = 97.5
        self.viewTarget = .zero
        self.viewHeight = 0
        self.twistAngle = 0
        super.init(eType: eType)
    }
}

// MARK: - Table (ACAD_TABLE)

public class DXFTableEntity: DXFEntity {
    public var blockName: String
    public var insertion: Vector3
    public var horizontal: Vector3
    public var data: DataTableData

    public override init(eType: DXFEType = .tABLE) {
        self.blockName = ""
        self.insertion = .zero
        self.horizontal = Vector3(x: 1, y: 0, z: 0)
        self.data = DataTableData()
        super.init(eType: eType)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// MARK: - Table Entries (matching DRW_TableEntry hierarchy)
// ═════════════════════════════════════════════════════════════════════════════

open class DXFTableEntry {
    public var tType: DXFTableType
    public var handle: UInt32
    public var parentHandle: UInt32
    public var name: String
    public var flags: Int

    public init(tType: DXFTableType = .unknown) {
        self.tType = tType
        self.handle = 0
        self.parentHandle = 0
        self.name = ""
        self.flags = 0
    }

    public init() {
        self.tType = .unknown
        self.handle = 0
        self.parentHandle = 0
        self.name = ""
        self.flags = 0
    }
}

// MARK: - Layer (DRW_Layer)

public class DXFLayerEntry: DXFTableEntry {
    public var lineType: String       // 6
    public var color: Int32           // 62
    public var color24: Int32         // 420
    public var plotFlag: Bool         // 290
    public var plotStyleHandle: UInt32 // 390
    public var lWeight: DXFLineWidth  // 370
    public var transparency: Int32    // 440

    public override init() {
        self.lineType = "CONTINUOUS"
        self.color = 7
        self.color24 = -1
        self.plotFlag = true
        self.plotStyleHandle = 0
        self.lWeight = .byDefault
        self.transparency = -1
        super.init(tType: .layer)
    }
}

// MARK: - Linetype (DRW_LType)

public class DXFLTypeEntry: DXFTableEntry {
    public var desc: String           // 3
    public var size: Int              // 73
    public var length: Double          // 40
    public var path: [Double] = []    // 49

    public override init() {
        self.desc = ""
        self.size = 0
        self.length = 0
        super.init(tType: .ltype)
    }
}

// MARK: - Dimstyle (DRW_Dimstyle)

public class DXFDimstyleEntry: DXFTableEntry {
    public var dimpost: String    // 3
    public var dimapost: String   // 4
    public var dimblk: String     // 5
    public var dimblk1: String    // 6
    public var dimblk2: String    // 7
    public var dimscale: Double   // 40
    public var dimasz: Double     // 41
    public var dimexo: Double     // 42
    public var dimdli: Double     // 43
    public var dimexe: Double     // 44
    public var dimrnd: Double     // 45
    public var dimdle: Double     // 46
    public var dimtp: Double      // 47
    public var dimtm: Double      // 48
    public var dimfxl: Double     // 49
    public var dimtxt: Double     // 140
    public var dimcen: Double     // 141
    public var dimtsz: Double     // 142
    public var dimaltf: Double    // 143
    public var dimlfac: Double    // 144
    public var dimtvp: Double     // 145
    public var dimtfac: Double    // 146
    public var dimgap: Double     // 147
    public var dimaltrnd: Double  // 148
    public var dimtol: Int        // 71
    public var dimlim: Int        // 72
    public var dimtih: Int        // 73
    public var dimtoh: Int        // 74
    public var dimse1: Int        // 75
    public var dimse2: Int        // 76
    public var dimtad: Int        // 77
    public var dimzin: Int        // 78
    public var dimazin: Int       // 79
    public var dimalt: Int        // 170
    public var dimaltd: Int       // 171
    public var dimtofl: Int       // 172
    public var dimsah: Int        // 173
    public var dimtix: Int        // 174
    public var dimsoxd: Int       // 175
    public var dimclrd: Int       // 176
    public var dimclre: Int       // 177
    public var dimclrt: Int       // 178
    public var dimadec: Int       // 179
    public var dimdec: Int        // 271
    public var dimtdec: Int       // 272
    public var dimaltu: Int       // 273
    public var dimalttd: Int      // 274
    public var dimaunit: Int      // 275
    public var dimfrac: Int       // 276
    public var dimlunit: Int      // 277
    public var dimdsep: Int       // 278
    public var dimtmove: Int      // 279
    public var dimjust: Int       // 280
    public var dimsd1: Int        // 281
    public var dimsd2: Int        // 282
    public var dimtolj: Int       // 283
    public var dimtzin: Int       // 284
    public var dimaltz: Int       // 285
    public var dimaltttz: Int     // 286
    public var dimfit: Int        // 287
    public var dimupt: Int        // 288
    public var dimatfit: Int      // 289
    public var dimfxlon: Int      // 290
    public var dimtxsty: String   // legacy text style name
    public var dimldrblk: String  // legacy leader arrow block name
    public var dimtxstyHandle: UInt32  // 340
    public var dimldrblkHandle: UInt32 // 341
    public var dimblkHandle: UInt32    // 342
    public var dimblk1Handle: UInt32   // 343
    public var dimblk2Handle: UInt32   // 344
    public var dimlwd: Int        // 371
    public var dimlwe: Int        // 372

    public override init() {
        self.dimpost = ""
        self.dimapost = ""
        self.dimblk = ""
        self.dimblk1 = ""
        self.dimblk2 = ""
        self.dimasz = 0.18
        self.dimtxt = 0.18
        self.dimexe = 0.18
        self.dimexo = 0.0625
        self.dimgap = 0.09
        self.dimcen = 0.09
        self.dimtxsty = "Standard"
        self.dimscale = 1.0
        self.dimlfac = 1.0
        self.dimtfac = 1.0
        self.dimfxl = 1.0
        self.dimdli = 0.38
        self.dimrnd = 0; self.dimdle = 0; self.dimtp = 0; self.dimtm = 0
        self.dimtsz = 0; self.dimtvp = 0
        self.dimaltf = 25.4
        self.dimtol = 0; self.dimlim = 0; self.dimse1 = 0; self.dimse2 = 0
        self.dimtad = 0; self.dimzin = 0
        self.dimtoh = 1; self.dimtolj = 1
        self.dimalt = 0; self.dimtofl = 0; self.dimsah = 0; self.dimtix = 0
        self.dimsoxd = 0; self.dimfxlon = 0
        self.dimaltd = 2; self.dimaltu = 2; self.dimalttd = 2; self.dimlunit = 2
        self.dimclrd = 0; self.dimclre = 0; self.dimclrt = 0; self.dimjust = 0
        self.dimupt = 0
        self.dimazin = 0; self.dimaltz = 0; self.dimaltttz = 0; self.dimtzin = 0; self.dimfrac = 0
        self.dimtih = 0; self.dimadec = 0; self.dimaunit = 0; self.dimsd1 = 0; self.dimsd2 = 0; self.dimtmove = 0
        self.dimaltrnd = 0
        self.dimdec = 4; self.dimtdec = 4
        self.dimfit = 3; self.dimatfit = 3
        self.dimdsep = 46  // '.' ascii
        self.dimlwd = -2; self.dimlwe = -2
        self.dimldrblk = ""
        self.dimtxstyHandle = 0
        self.dimldrblkHandle = 0
        self.dimblkHandle = 0
        self.dimblk1Handle = 0
        self.dimblk2Handle = 0
        super.init(tType: .dimstyle)
    }
}

// MARK: - TextStyle (DRW_Textstyle)

public class DXFStyleEntry: DXFTableEntry {
    public var height: Double         // 40
    public var width: Double          // 41
    public var oblique: Double        // 50
    public var genFlag: Int           // 71
    public var lastHeight: Double     // 42
    public var font: String           // 3
    public var bigFont: String        // 4
    public var fontFamily: Int        // 1071

    public override init() {
        self.height = 0
        self.width = 1
        self.oblique = 0
        self.genFlag = 0
        self.lastHeight = 1
        self.font = "txt"
        self.bigFont = ""
        self.fontFamily = 0
        super.init(tType: .style)
    }
}

// MARK: - Vport (DRW_Vport)

public class DXFVportEntry: DXFTableEntry {
    public var lowerLeft: Vector3
    public var upperRight: Vector3
    public var center: Vector3
    public var snapBase: Vector3
    public var snapSpacing: Vector3
    public var gridSpacing: Vector3
    public var viewDir: Vector3
    public var viewTarget: Vector3
    public var height: Double
    public var ratio: Double
    public var lensHeight: Double
    public var frontClip: Double
    public var backClip: Double
    public var snapAngle: Double
    public var twistAngle: Double
    public var viewMode: Int
    public var circleZoom: Int
    public var fastZoom: Int
    public var ucsIcon: Int
    public var snap: Int
    public var grid: Int
    public var snapStyle: Int
    public var snapIsopair: Int
    public var gridBehavior: Int

    public override init() {
        self.lowerLeft = .zero
        self.upperRight = Vector3(x: 1, y: 1)
        self.center = Vector3(x: 0.651828, y: -0.16)
        self.snapBase = .zero
        self.snapSpacing = Vector3(x: 10, y: 10)
        self.gridSpacing = Vector3(x: 10, y: 10)
        self.viewDir = Vector3(x: 0, y: 0, z: 1)
        self.viewTarget = .zero
        self.height = 5.13732
        self.ratio = 2.4426877
        self.lensHeight = 50
        self.frontClip = 0
        self.backClip = 0
        self.snapAngle = 0
        self.twistAngle = 0
        self.viewMode = 0
        self.circleZoom = 100
        self.fastZoom = 1
        self.ucsIcon = 3
        self.snap = 0
        self.grid = 0
        self.snapStyle = 0
        self.snapIsopair = 0
        self.gridBehavior = 7
        super.init(tType: .vport)
    }
}

// MARK: - AppId (DRW_AppId)

public class DXFAppIdEntry: DXFTableEntry {
    public override init() {
        super.init(tType: .appid)
    }
}

// MARK: - ImageDef (DRW_ImageDef)

public class DXFImageDefEntry: DXFTableEntry {
    public var name_p: String      // 1
    public var imgVersion: Int     // 90
    public var u: Double           // 10
    public var v: Double           // 20
    public var up: Double          // 11
    public var vp: Double          // 21
    public var loaded: Int         // 280
    public var resolution: Int     // 281
    /// Reactors map: reactorHandle -> entityHandle (for OBJECTS section)
    public var reactors: [String: String] = [:]

    public override init() {
        self.name_p = ""
        self.imgVersion = 0
        self.u = 0; self.v = 0
        self.up = 0; self.vp = 0
        self.loaded = 1
        self.resolution = 0
        super.init(tType: .imagedef)
    }
}

// MARK: - BlockRecord (DRW_Block_Record)

public class DXFBlockRecordEntry: DXFTableEntry {
    public var insUnits: Int
    public var basePoint: Vector3

    public override init() {
        self.insUnits = 0
        self.basePoint = .zero
        super.init(tType: .blockRecord)
    }
}