import Foundation

/// Pure Swift DXF writer. Writes ASCII DXF files with proper section structure.
public class DXFWriter {

    public enum WriterError: Swift.Error {
        case writeError(String)
        case invalidEntity(String)
    }

    // MARK: - Configuration

    public var version: DXFVersion = .r2000
    public var codePage: String = "ANSI_1252"
    public var textCodec = DXFTextCodec()
    /// Header variables to write (populated by caller or defaults are used)
    public var headerVars: [String: Any] = [:]

    /// version >= R13 (AC1012)
    private var hasSubclassMarkers: Bool { return version.rawValue >= "AC1012" }
    /// version >= R2000 (AC1015)
    private var has24BitColor: Bool { return version.rawValue >= "AC1015" }
    /// version >= R2004 (AC1018)
    private var hasTransparency: Bool { return version.rawValue >= "AC1018" }
    /// version >= R2000
    private var hasLineWeight: Bool { return version.rawValue >= "AC1015" }
    /// version >= R14 (AC1014)
    private var hasExtendedData: Bool { return version.rawValue >= "AC1014" }
    /// version > R12 (AC1009)
    private var isModern: Bool { return version.rawValue != "AC1009" && version.rawValue != "AC1006" }

    // MARK: - Storage

    public var layers: [DXFLayerEntry] = []
    public var ltypes: [DXFLTypeEntry] = []
    public var dimstyles: [DXFDimstyleEntry] = []
    public var textstyles: [DXFStyleEntry] = []
    public var vports: [DXFVportEntry] = []
    public var appids: [DXFAppIdEntry] = []
    public var blockRecords: [DXFBlockRecordEntry] = []
    public var blocks: [DXFBlockEntity] = []
    public var entities: [DXFEntity] = []

    // Handle tracking
    private var nextHandle: UInt32 = 1
    private var writingBlock: Bool = false
    private var currentBlockHandle: String = ""
    private var blockNameToHandle: [String: String] = [:]
    /// Image defs for OBJECTS section reactors
    private var imageDefs: [DXFImageDefEntry] = []

    public init() {}

    // MARK: - Public API

    public func addEntity(_ entity: DXFEntity) {
        entities.append(entity)
    }

    public func addLayer(_ layer: DXFLayerEntry) {
        layers.append(layer)
    }

    public func addLType(_ ltype: DXFLTypeEntry) {
        ltypes.append(ltype)
    }

    public func addDimstyle(_ ds: DXFDimstyleEntry) {
        dimstyles.append(ds)
    }

    public func addTextStyle(_ ts: DXFStyleEntry) {
        textstyles.append(ts)
    }

    public func addVPort(_ vp: DXFVportEntry) {
        vports.append(vp)
    }

    public func addAppId(_ app: DXFAppIdEntry) {
        appids.append(app)
    }

    public func addBlockRecord(_ br: DXFBlockRecordEntry) {
        blockRecords.append(br)
    }

    public func addBlock(_ block: DXFBlockEntity) {
        blocks.append(block)
    }

    /// Write DXF file to path
    public func write(to path: String) throws {
        let content = buildDXF()
        guard let data = content.data(using: .ascii, allowLossyConversion: true) else {
            throw WriterError.writeError("Cannot encode DXF as ASCII")
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Write DXF to string
    public func writeToString() -> String {
        return buildDXF()
    }

    // MARK: - DXF Builder

    private func buildDXF() -> String {
        var out = ""
        out.reserveCapacity(65536)

        writeHeader(&out)
        writeClasses(&out)
        writeTables(&out)
        writeBlocks(&out)
        writeEntities(&out)
        writeObjects(&out)

        // EOF
        out += "  0\r\nEOF\r\n"
        return out
    }

    // MARK: - Handles

    private func allocHandle() -> String {
        let h = nextHandle
        nextHandle += 1
        return String(format: "%X", h)
    }

    private func allocHandleU32() -> UInt32 {
        let h = nextHandle
        nextHandle += 1
        return h
    }

    // MARK: - HEADER

    private func writeHeader(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nHEADER\r\n"

        let vers: String = {
            switch version {
            case .r10: return "AC1006"
            case .r12: return "AC1009"
            case .r13: return "AC1012"
            case .r14: return "AC1014"
            case .r2000: return "AC1015"
            case .r2004: return "AC1018"
            case .r2007: return "AC1021"
            case .r2010: return "AC1024"
            case .r2013: return "AC1027"
            case .r2018: return "AC1032"
            default: return "AC1021"
            }
        }()
        textCodec.setVersion(version)
        textCodec.setCodePage(codePage)

        writeHdrStr("$ACADVER", vers, 1, &out)
        writeHdrStr("$DWGCODEPAGE", textCodec.codePage, 3, &out)
        writeHdrCoord("$INSBASE", 0, 0, 0, &out)
        writeHdrCoord("$EXTMIN", 0, 0, 0, &out)
        writeHdrCoord("$EXTMAX", 1, 1, 0, &out)
        writeHdrCoord("$LIMMIN", 0, 0, nil, &out)
        writeHdrCoord("$LIMMAX", 420, 297, nil, &out)
        writeHdrInt("$ORTHOMODE", 0, 70, &out)
        writeHdrInt("$REGENMODE", 1, 70, &out)
        writeHdrInt("$FILLMODE", 1, 70, &out)
        writeHdrInt("$QTEXTMODE", 0, 70, &out)
        writeHdrInt("$MIRRTEXT", 0, 70, &out)
        writeHdrDbl("$LTSCALE", 1.0, 40, &out)
        writeHdrInt("$ATTMODE", 1, 70, &out)
        writeHdrDbl("$TEXTSIZE", 2.5, 40, &out)
        writeHdrDbl("$TRACEWID", 0.05, 40, &out)
        writeHdrStr("$TEXTSTYLE", "Standard", 7, &out)
        writeHdrStr("$CLAYER", "0", 8, &out)
        writeHdrStr("$CELTYPE", "ByLayer", 6, &out)
        writeHdrInt("$CECOLOR", 256, 62, &out)
        writeHdrDbl("$CELTSCALE", 1.0, 40, &out)
        writeHdrInt("$DISPSILH", 0, 70, &out)
        writeHdrDbl("$DIMSCALE", 1.0, 40, &out)
        writeHdrDbl("$DIMASZ", 2.5, 40, &out)
        writeHdrDbl("$DIMEXO", 0.625, 40, &out)
        writeHdrDbl("$DIMEXE", 1.25, 40, &out)
        writeHdrDbl("$DIMDLI", 3.75, 40, &out)
        writeHdrDbl("$DIMRND", 0.0, 40, &out)
        writeHdrDbl("$DIMDLE", 0.0, 40, &out)
        writeHdrDbl("$DIMTP", 0.0, 40, &out)
        writeHdrDbl("$DIMTM", 0.0, 40, &out)
        writeHdrDbl("$DIMTXT", 2.5, 140, &out)
        writeHdrDbl("$DIMCEN", 2.5, 141, &out)
        writeHdrDbl("$DIMTSZ", 0.0, 142, &out)
        writeHdrDbl("$DIMALTF", 25.4, 143, &out)
        writeHdrDbl("$DIMLFAC", 1.0, 144, &out)
        writeHdrDbl("$DIMTVP", 0.0, 145, &out)
        writeHdrDbl("$DIMTFAC", 1.0, 146, &out)
        writeHdrDbl("$DIMGAP", 0.625, 147, &out)
        writeHdrDbl("$DIMALTRND", 0.0, 148, &out)
        writeHdrInt("$DIMTOL", 0, 71, &out)
        writeHdrInt("$DIMLIM", 0, 72, &out)
        writeHdrInt("$DIMTIH", 0, 73, &out)
        writeHdrInt("$DIMTOH", 0, 74, &out)
        writeHdrInt("$DIMSE1", 0, 75, &out)
        writeHdrInt("$DIMSE2", 0, 76, &out)
        writeHdrInt("$DIMTAD", 1, 77, &out)
        writeHdrInt("$DIMZIN", 8, 78, &out)
        writeHdrInt("$DIMAZIN", 0, 79, &out)
        writeHdrInt("$DIMALT", 0, 170, &out)
        writeHdrInt("$DIMALTD", 2, 171, &out)
        writeHdrInt("$DIMTOFL", 1, 172, &out)
        writeHdrInt("$DIMSAH", 0, 173, &out)
        writeHdrInt("$DIMTIX", 0, 174, &out)
        writeHdrInt("$DIMSOXD", 0, 175, &out)
        writeHdrInt("$DIMCLRD", 0, 176, &out)
        writeHdrInt("$DIMCLRE", 0, 177, &out)
        writeHdrInt("$DIMCLRT", 0, 178, &out)
        writeHdrInt("$DIMADEC", 0, 179, &out)
        writeHdrInt("$DIMDEC", 4, 271, &out)
        writeHdrInt("$DIMTDEC", 4, 272, &out)
        writeHdrInt("$DIMALTU", 2, 273, &out)
        writeHdrInt("$DIMALTTD", 2, 274, &out)
        writeHdrInt("$DIMAUNIT", 0, 275, &out)
        writeHdrInt("$DIMFRAC", 0, 276, &out)
        if isModern {
            writeHdrInt("$DIMLUNIT", 2, 277, &out)
        } else {
            writeHdrInt("$DIMUNIT", 2, 70, &out) // pre-2000 name
        }
        writeHdrInt("$DIMDSEP", 46, 278, &out)
        writeHdrInt("$DIMTMOVE", 0, 279, &out)
        writeHdrInt("$DIMJUST", 0, 280, &out)
        writeHdrInt("$DIMSD1", 0, 281, &out)
        writeHdrInt("$DIMSD2", 0, 282, &out)
        writeHdrInt("$DIMTOLJ", 1, 283, &out)
        writeHdrInt("$DIMTZIN", 0, 284, &out)
        writeHdrInt("$DIMALTZ", 0, 285, &out)
        writeHdrInt("$DIMALTTZ", 0, 286, &out)
        writeHdrInt("$DIMFIT", 3, 287, &out)
        writeHdrInt("$DIMUPT", 0, 288, &out)
        writeHdrInt("$DIMATFIT", 3, 289, &out)
        writeHdrInt("$DIMFXLON", 0, 290, &out)
        writeHdrDbl("$DIMFXL", 1.0, 49, &out)
        writeHdrStr("$DIMTXSTY", "Standard", 7, &out)
        writeHdrInt("$DIMLWD", -2, 371, &out)
        writeHdrInt("$DIMLWE", -2, 372, &out)
        writeHdrInt("$LUNITS", 2, 70, &out)
        writeHdrInt("$LUPREC", 4, 70, &out)
        writeHdrInt("$INSUNITS", 4, 70, &out)
        writeHdrInt("$MEASUREMENT", 1, 70, &out)
        writeHdrInt("$TILEMODE", 1, 70, &out)
        writeHdrInt("$PLINEGEN", 0, 70, &out)
        writeHdrStr("$CMLSTYLE", "Standard", 2, &out)

        // Write any custom header vars not already handled
        let written: Set<String> = [
            "$ACADVER", "$DWGCODEPAGE", "$INSBASE", "$EXTMIN", "$EXTMAX",
            "$LIMMIN", "$LIMMAX", "$ORTHOMODE", "$REGENMODE", "$FILLMODE",
            "$QTEXTMODE", "$MIRRTEXT", "$LTSCALE", "$ATTMODE", "$TEXTSIZE",
            "$TRACEWID", "$TEXTSTYLE", "$CLAYER", "$CELTYPE", "$CECOLOR",
            "$CELTSCALE", "$DISPSILH",
            "$DIMSCALE", "$DIMASZ", "$DIMEXO", "$DIMEXE", "$DIMDLI",
            "$DIMRND", "$DIMDLE", "$DIMTP", "$DIMTM", "$DIMTXT", "$DIMCEN",
            "$DIMTSZ", "$DIMALTF", "$DIMLFAC", "$DIMTVP", "$DIMTFAC", "$DIMGAP",
            "$DIMALTRND", "$DIMTOL", "$DIMLIM", "$DIMTIH", "$DIMTOH", "$DIMSE1",
            "$DIMSE2", "$DIMTAD", "$DIMZIN", "$DIMAZIN", "$DIMALT", "$DIMALTD",
            "$DIMTOFL", "$DIMSAH", "$DIMTIX", "$DIMSOXD", "$DIMCLRD", "$DIMCLRE",
            "$DIMCLRT", "$DIMADEC", "$DIMDEC", "$DIMTDEC", "$DIMALTU", "$DIMALTTD",
            "$DIMAUNIT", "$DIMFRAC", "$DIMLUNIT", "$DIMUNIT", "$DIMDSEP",
            "$DIMTMOVE", "$DIMJUST", "$DIMSD1", "$DIMSD2", "$DIMTOLJ", "$DIMTZIN",
            "$DIMALTZ", "$DIMALTTZ", "$DIMFIT", "$DIMUPT", "$DIMATFIT", "$DIMFXLON",
            "$DIMFXL", "$DIMTXSTY", "$DIMLWD", "$DIMLWE",
            "$LUNITS", "$LUPREC", "$INSUNITS", "$MEASUREMENT", "$TILEMODE",
            "$PLINEGEN", "$CMLSTYLE"
        ]
        for (key, val) in headerVars {
            if written.contains(key) { continue }
            writeHdrValue(key, val, &out)
        }

        out += "  0\r\nENDSEC\r\n"
    }

    // MARK: - Header Write Helpers

    private func writeHdrStr(_ name: String, _ defaultVal: String, _ code: Int, _ out: inout String) {
        let val = headerVars[name] as? String ?? defaultVal
        out += "  9\r\n\(name)\r\n"
        out += String(format: "%3d\r\n", code)
        let enc = textCodec.fromUtf8(val)
        out += enc + "\r\n"
    }

    private func writeHdrInt(_ name: String, _ defaultVal: Int, _ code: Int, _ out: inout String) {
        let val = headerVars[name] as? Int ?? defaultVal
        out += "  9\r\n\(name)\r\n"
        out += String(format: "%3d\r\n%d\r\n", code, val)
    }

    private func writeHdrDbl(_ name: String, _ defaultVal: Double, _ code: Int, _ out: inout String) {
        let val = headerVars[name] as? Double ?? defaultVal
        out += "  9\r\n\(name)\r\n"
        out += String(format: "%3d\r\n", code)
        out += dxfFmt(val) + "\r\n"
    }

    private func writeHdrCoord(_ name: String, _ x: Double, _ y: Double, _ z: Double?, _ out: inout String) {
        let valX = (headerVars["\(name)_x"] as? Double) ?? x
        let valY = (headerVars["\(name)_y"] as? Double) ?? y
        let valZ = z != nil ? ((headerVars["\(name)_z"] as? Double) ?? z!) : nil
        out += "  9\r\n\(name)\r\n"
        out += " 10\r\n\(dxfFmt(valX))\r\n 20\r\n\(dxfFmt(valY))\r\n"
        if let vz = valZ { out += " 30\r\n\(dxfFmt(vz))\r\n" }
    }

    private func writeHdrValue(_ name: String, _ value: Any, _ out: inout String) {
        out += "  9\r\n\(name)\r\n"
        switch value {
        case let s as String:
            out += "  1\r\n\(textCodec.fromUtf8(s))\r\n"
        case let i as Int:
            let code = i < 1000 ? 70 : 90
            out += String(format: "%3d\r\n%d\r\n", code, i)
        case let d as Double:
            out += " 40\r\n\(dxfFmt(d))\r\n"
        case let v as Vector3:
            out += " 10\r\n\(dxfFmt(v.x))\r\n 20\r\n\(dxfFmt(v.y))\r\n 30\r\n\(dxfFmt(v.z))\r\n"
        default:
            out += "  1\r\n\(String(describing: value))\r\n"
        }
    }

    // MARK: - CLASSES

    private func writeClasses(_ out: inout String) {
        if !isModern { return }  // No CLASSES in R12
        out += "  0\r\nSECTION\r\n  2\r\nCLASSES\r\n  0\r\nENDSEC\r\n"
    }

    // MARK: - TABLES

    private func writeTables(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nTABLES\r\n"

        writeVPortTable(&out)
        writeLTypeTable(&out)
        writeLayerTable(&out)
        writeStyleTable(&out)
        writeViewTable(&out)
        writeUCSTable(&out)
        writeAppIdTable(&out)
        writeDimStyleTable(&out)
        writeBlockRecordTable(&out)

        out += "  0\r\nENDSEC\r\n"
    }

    private func writeVPortTable(_ out: inout String) {
        out += "  0\r\nTABLE\r\n  2\r\nVPORT\r\n"
        out += "  5\r\n\(allocHandle())\r\n"
        out += "330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        let vpCount = max(vports.count, 1)
        out += " 70\r\n\(vpCount)\r\n"

        if vports.isEmpty {
            // Default *ACTIVE viewport
            let h = allocHandle()
            out += "  0\r\nVPORT\r\n"
            out += "  5\r\n\(h)\r\n"
            out += "330\r\n0\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbViewportTableRecord\r\n"
            out += "  2\r\n*ACTIVE\r\n"
            out += " 70\r\n0\r\n"
            out += " 10\r\n0.0\r\n 20\r\n0.0\r\n"
            out += " 11\r\n1.0\r\n 21\r\n1.0\r\n"
            out += " 12\r\n286.0\r\n 22\r\n211.0\r\n"
            out += " 13\r\n0.0\r\n 23\r\n0.0\r\n"
            out += " 14\r\n10.0\r\n 24\r\n10.0\r\n"
            out += " 15\r\n10.0\r\n 25\r\n10.0\r\n"
            out += " 16\r\n0.0\r\n 26\r\n0.0\r\n 36\r\n1.0\r\n"
            out += " 17\r\n0.0\r\n 27\r\n0.0\r\n 37\r\n0.0\r\n"
            out += " 40\r\n297.0\r\n 41\r\n1.5\r\n 42\r\n50.0\r\n"
            out += " 43\r\n0.0\r\n 44\r\n0.0\r\n"
            out += " 50\r\n0.0\r\n 51\r\n0.0\r\n"
            out += " 71\r\n0\r\n 72\r\n100\r\n 73\r\n1\r\n 74\r\n3\r\n"
            out += " 75\r\n0\r\n 76\r\n1\r\n 77\r\n0\r\n 78\r\n0\r\n"
            out += "281\r\n0\r\n 65\r\n1\r\n"
            out += "110\r\n0.0\r\n120\r\n0.0\r\n130\r\n0.0\r\n"
            out += "111\r\n1.0\r\n121\r\n0.0\r\n131\r\n0.0\r\n"
            out += "112\r\n0.0\r\n122\r\n1.0\r\n132\r\n0.0\r\n"
            out += " 79\r\n0\r\n146\r\n0\r\n"
            out += " 60\r\n7\r\n 61\r\n5\r\n292\r\n1\r\n282\r\n1\r\n"
            out += "141\r\n0.0\r\n142\r\n0.0\r\n"
            out += " 63\r\n250\r\n421\r\n3358443\r\n"
        } else {
            for vp in vports {
                writeOneVPort(vp, &out)
            }
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeOneVPort(_ vp: DXFVportEntry, _ out: inout String) {
        out += "  0\r\nVPORT\r\n  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTableRecord\r\n100\r\nAcDbViewportTableRecord\r\n"
        writeStr(2, vp.name, &out)
        writeInt(70, vp.flags, &out)
        writePoint(10, vp.lowerLeft, &out)
        writePoint(11, vp.upperRight, &out)
        writePoint(12, vp.center, &out)
        writePoint(13, vp.snapBase, &out)
        writePoint(14, vp.snapSpacing, &out)
        writePoint(15, vp.gridSpacing, &out)
        writeCoord3(16, vp.viewDir, &out)
        writeCoord3(17, vp.viewTarget, &out)
        writeDbl(40, vp.height, &out)
        writeDbl(41, vp.ratio, &out)
        writeDbl(42, vp.lensHeight, &out)
        writeDbl(43, vp.frontClip, &out)
        writeDbl(44, vp.backClip, &out)
        writeDbl(50, vp.snapAngle, &out)
        writeDbl(51, vp.twistAngle, &out)
        writeInt(71, vp.viewMode, &out)
        writeInt(72, vp.circleZoom, &out)
        writeInt(73, vp.fastZoom, &out)
        writeInt(74, vp.ucsIcon, &out)
        writeInt(75, vp.snap, &out)
        writeInt(76, vp.grid, &out)
        writeInt(77, vp.snapStyle, &out)
        writeInt(78, vp.snapIsopair, &out)
        writeInt(60, vp.gridBehavior, &out)
    }

    private func writeLTypeTable(_ out: inout String) {
        var entries: [DXFLTypeEntry] = []
        // Ensure standard linetypes exist
        let standardNames = ["ByBlock", "ByLayer", "Continuous"]
        for name in standardNames {
            if !ltypes.contains(where: { $0.name == name }) {
                let lt = DXFLTypeEntry()
                lt.name = name
                lt.desc = name == "Continuous" ? "Solid line" : ""
                entries.append(lt)
            }
        }
        entries.append(contentsOf: ltypes.filter { !standardNames.contains($0.name) })

        out += "  0\r\nTABLE\r\n  2\r\nLTYPE\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += " 70\r\n\(entries.count)\r\n"

        for lt in entries {
            out += "  0\r\nLTYPE\r\n  5\r\n\(allocHandle())\r\n"
            out += "330\r\n0\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbLinetypeTableRecord\r\n"
            writeStr(2, lt.name, &out)
            writeInt(70, lt.flags, &out)
            writeStr(3, lt.desc, &out)
            writeInt(72, 65, &out)  // alignment code 'A'
            writeInt(73, lt.size, &out)
            writeDbl(40, lt.length, &out)
            for p in lt.path {
                writeDbl(49, p, &out)
            }
            // Standard linetypes have no dashes
            if lt.name == "Continuous" && lt.path.isEmpty {
                writeInt(73, 0, &out)
            }
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeLayerTable(_ out: inout String) {
        var entries: [DXFLayerEntry] = []
        // Ensure layer 0 exists
        if !layers.contains(where: { $0.name == "0" }) {
            let l0 = DXFLayerEntry()
            l0.name = "0"
            l0.color = 7
            entries.append(l0)
        }
        entries.append(contentsOf: layers)

        out += "  0\r\nTABLE\r\n  2\r\nLAYER\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += " 70\r\n\(entries.count)\r\n"

        for layer in entries {
            out += "  0\r\nLAYER\r\n  5\r\n\(allocHandle())\r\n"
            out += "330\r\n0\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbLayerTableRecord\r\n"
            writeStr(2, layer.name, &out)
            writeInt(70, layer.flags, &out)
            writeInt(62, Int(layer.color), &out)
            if layer.color24 >= 0 {
                writeInt(420, Int(layer.color24), &out)
            }
            writeStr(6, layer.lineType, &out)
            writeInt(370, layer.lWeight.dxfInt, &out)
            writeBool(290, layer.plotFlag, &out)
            if layer.plotStyleHandle != 0 {
                writeStr(390, String(format: "%X", layer.plotStyleHandle), &out)
            }
            if layer.transparency >= 0 {
                writeInt(440, Int(layer.transparency), &out)
            }
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeStyleTable(_ out: inout String) {
        var entries: [DXFStyleEntry] = []
        if !textstyles.contains(where: { $0.name == "Standard" }) {
            let s = DXFStyleEntry()
            s.name = "Standard"
            entries.append(s)
        }
        entries.append(contentsOf: textstyles)

        out += "  0\r\nTABLE\r\n  2\r\nSTYLE\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += " 70\r\n\(entries.count)\r\n"

        for style in entries {
            out += "  0\r\nSTYLE\r\n  5\r\n\(allocHandle())\r\n"
            out += "330\r\n0\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbTextStyleTableRecord\r\n"
            writeStr(2, style.name, &out)
            writeInt(70, style.flags, &out)
            writeDbl(40, style.height, &out)
            writeDbl(41, style.width, &out)
            writeDbl(50, style.oblique, &out)
            writeInt(71, style.genFlag, &out)
            writeDbl(42, style.lastHeight, &out)
            writeStr(3, style.font, &out)
            writeStr(4, style.bigFont, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeViewTable(_ out: inout String) {
        out += "  0\r\nTABLE\r\n  2\r\nVIEW\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += " 70\r\n0\r\n"
        out += "  0\r\nENDTAB\r\n"
    }

    private func writeUCSTable(_ out: inout String) {
        out += "  0\r\nTABLE\r\n  2\r\nUCS\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += " 70\r\n0\r\n"
        out += "  0\r\nENDTAB\r\n"
    }

    private func writeAppIdTable(_ out: inout String) {
        var entries: [DXFAppIdEntry] = []
        if !appids.contains(where: { $0.name == "ACAD" }) {
            let app = DXFAppIdEntry()
            app.name = "ACAD"
            entries.append(app)
        }
        entries.append(contentsOf: appids)

        out += "  0\r\nTABLE\r\n  2\r\nAPPID\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += " 70\r\n\(entries.count)\r\n"

        for app in entries {
            out += "  0\r\nAPPID\r\n  5\r\n\(allocHandle())\r\n"
            out += "330\r\n0\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbRegAppTableRecord\r\n"
            writeStr(2, app.name, &out)
            writeInt(70, app.flags, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeDimStyleTable(_ out: inout String) {
        var entries: [DXFDimstyleEntry] = []
        if !dimstyles.contains(where: { $0.name == "Standard" }) {
            let ds = DXFDimstyleEntry()
            ds.name = "Standard"
            entries.append(ds)
        }
        entries.append(contentsOf: dimstyles)

        out += "  0\r\nTABLE\r\n  2\r\nDIMSTYLE\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += "100\r\nAcDbDimStyleTable\r\n"
        out += " 70\r\n\(entries.count)\r\n"
        out += " 71\r\n1\r\n"

        for ds in entries {
            out += "  0\r\nDIMSTYLE\r\n105\r\n\(allocHandle())\r\n"
            out += "330\r\n0\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbDimStyleTableRecord\r\n"
            writeStr(2, ds.name, &out)
            writeInt(70, ds.flags, &out)
            writeDbl(40, ds.dimscale, &out)
            writeDbl(41, ds.dimasz, &out)
            writeDbl(42, ds.dimexo, &out)
            writeDbl(43, ds.dimdli, &out)
            writeDbl(44, ds.dimexe, &out)
            writeDbl(45, ds.dimrnd, &out)
            writeDbl(46, ds.dimdle, &out)
            writeDbl(47, ds.dimtp, &out)
            writeDbl(48, ds.dimtm, &out)
            writeDbl(49, ds.dimfxl, &out)
            writeInt(71, ds.dimtol, &out)
            writeInt(72, ds.dimlim, &out)
            writeInt(73, ds.dimtih, &out)
            writeInt(74, ds.dimtoh, &out)
            writeInt(75, ds.dimse1, &out)
            writeInt(76, ds.dimse2, &out)
            writeInt(77, ds.dimtad, &out)
            writeInt(78, ds.dimzin, &out)
            writeInt(79, ds.dimazin, &out)
            writeDbl(140, ds.dimtxt, &out)
            writeDbl(141, ds.dimcen, &out)
            writeDbl(142, ds.dimtsz, &out)
            writeDbl(143, ds.dimaltf, &out)
            writeDbl(144, ds.dimlfac, &out)
            writeDbl(145, ds.dimtvp, &out)
            writeDbl(146, ds.dimtfac, &out)
            writeDbl(147, ds.dimgap, &out)
            writeDbl(148, ds.dimaltrnd, &out)
            writeInt(170, ds.dimalt, &out)
            writeInt(171, ds.dimaltd, &out)
            writeInt(172, ds.dimtofl, &out)
            writeInt(173, ds.dimsah, &out)
            writeInt(174, ds.dimtix, &out)
            writeInt(175, ds.dimsoxd, &out)
            writeInt(176, ds.dimclrd, &out)
            writeInt(177, ds.dimclre, &out)
            writeInt(178, ds.dimclrt, &out)
            writeInt(179, ds.dimadec, &out)
            writeInt(271, ds.dimdec, &out)
            writeInt(272, ds.dimtdec, &out)
            writeInt(273, ds.dimaltu, &out)
            writeInt(274, ds.dimalttd, &out)
            writeInt(275, ds.dimaunit, &out)
            writeInt(276, ds.dimfrac, &out)
            writeInt(277, ds.dimlunit, &out)
            writeInt(278, ds.dimdsep, &out)
            writeInt(279, ds.dimtmove, &out)
            writeInt(280, ds.dimjust, &out)
            writeInt(281, ds.dimsd1, &out)
            writeInt(282, ds.dimsd2, &out)
            writeInt(283, ds.dimtolj, &out)
            writeInt(284, ds.dimtzin, &out)
            writeInt(285, ds.dimaltz, &out)
            writeInt(286, ds.dimaltttz, &out)
            writeInt(287, ds.dimfit, &out)
            writeInt(288, ds.dimupt, &out)
            writeInt(289, ds.dimatfit, &out)
            writeInt(290, ds.dimfxlon, &out)
            writeStr(340, ds.dimtxsty, &out)
            writeStr(341, ds.dimldrblk, &out)
            writeInt(371, ds.dimlwd, &out)
            writeInt(372, ds.dimlwe, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    private func writeBlockRecordTable(_ out: inout String) {
        var entries: [DXFBlockRecordEntry] = []
        // Ensure *Model_Space and *Paper_Space exist
        if !blockRecords.contains(where: { $0.name == "*Model_Space" }) {
            let ms = DXFBlockRecordEntry()
            ms.name = "*Model_Space"
            entries.append(ms)
        }
        if !blockRecords.contains(where: { $0.name == "*Paper_Space" }) {
            let ps = DXFBlockRecordEntry()
            ps.name = "*Paper_Space"
            entries.append(ps)
        }
        entries.append(contentsOf: blockRecords)

        out += "  0\r\nTABLE\r\n  2\r\nBLOCK_RECORD\r\n"
        out += "  5\r\n\(allocHandle())\r\n330\r\n0\r\n"
        out += "100\r\nAcDbSymbolTable\r\n"
        out += " 70\r\n\(entries.count)\r\n"

        for br in entries {
            out += "  0\r\nBLOCK_RECORD\r\n  5\r\n\(allocHandle())\r\n"
            out += "330\r\n0\r\n"
            out += "100\r\nAcDbSymbolTableRecord\r\n"
            out += "100\r\nAcDbBlockTableRecord\r\n"
            writeStr(2, br.name, &out)
            writeInt(70, br.flags, &out)
            writeInt(280, 1, &out)
            writeInt(281, 0, &out)
        }

        out += "  0\r\nENDTAB\r\n"
    }

    // MARK: - BLOCKS Section

    private func writeBlocks(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nBLOCKS\r\n"
        writingBlock = false

        // Helper: write ENDBLK for previous block
        func closeBlock() {
            if writingBlock {
                let eh = allocHandle()
                out += "  0\r\nENDBLK\r\n  5\r\n\(eh)\r\n"
                if isModern {
                    out += "330\r\n\(currentBlockHandle)\r\n100\r\nAcDbEntity\r\n"
                }
                out += "  8\r\n0\r\n"
                if isModern { out += "100\r\nAcDbBlockEnd\r\n" }
                writingBlock = false
            }
        }

        // Helper: write BLOCK header
        func openBlock(_ name: String, _ bp: Vector3) {
            closeBlock()
            currentBlockHandle = allocHandle()
            let blockH = currentBlockHandle
            blockNameToHandle[name] = blockH
            out += "  0\r\nBLOCK\r\n  5\r\n\(blockH)\r\n"
            if isModern { out += "330\r\n0\r\n100\r\nAcDbEntity\r\n" }
            out += "  8\r\n0\r\n"
            if isModern { out += "100\r\nAcDbBlockBegin\r\n" }
            writeStr(2, name, &out)
            writeInt(70, 0, &out)
            writePoint3(10, bp, &out)
            writeStr(3, name, &out)
            writeStr(1, "", &out)
            writingBlock = true
        }

        openBlock("*Model_Space", .zero)
        openBlock("*Paper_Space", .zero)

        // User blocks
        for block in blocks {
            openBlock(block.name, block.basePoint)
        }

        closeBlock()
        out += "  0\r\nENDSEC\r\n"
    }

    // MARK: - ENTITIES Section

    private func writeEntities(_ out: inout String) {
        out += "  0\r\nSECTION\r\n  2\r\nENTITIES\r\n"

        for entity in entities {
            writeEntity(entity, &out)
        }

        out += "  0\r\nENDSEC\r\n"
    }

    private func writeEntity(_ e: DXFEntity, _ out: inout String) {
        let h = allocHandle()

        switch e.eType {
        case .pOINT:
            guard let pt = e as? DXFPointEntity else { return }
            out += "  0\r\nPOINT\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: pt.layer))\r\n"
            writeCommonEntityData(pt, &out)
            out += "100\r\nAcDbPoint\r\n"
            writePoint3(10, pt.basePoint, &out)
            writeDbl(39, pt.thickness_p, &out)

        case .lINE:
            guard let ln = e as? DXFLineEntity else { return }
            out += "  0\r\nLINE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: ln.layer))\r\n"
            writeCommonEntityData(ln, &out)
            out += "100\r\nAcDbLine\r\n"
            writePoint3(10, ln.basePoint, &out)
            writePoint3(11, ln.secPoint, &out)
            writeDbl(39, ln.thickness_p, &out)

        case .cIRCLE:
            guard let ci = e as? DXFCircleEntity else { return }
            out += "  0\r\nCIRCLE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: ci.layer))\r\n"
            writeCommonEntityData(ci, &out)
            out += "100\r\nAcDbCircle\r\n"
            writePoint3(10, ci.basePoint, &out)
            writeDbl(40, ci.radius, &out)
            writeDbl(39, ci.thickness_p, &out)

        case .aRC:
            guard let arc = e as? DXFArcEntity else { return }
            out += "  0\r\nARC\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: arc.layer))\r\n"
            writeCommonEntityData(arc, &out)
            out += "100\r\nAcDbArc\r\n"
            writePoint3(10, arc.basePoint, &out)
            writeDbl(40, arc.radius, &out)
            writeDbl(50, arc.startAngle * 180.0 / .pi, &out)  // radians → degrees
            writeDbl(51, arc.endAngle * 180.0 / .pi, &out)

        case .eLLIPSE:
            guard let el = e as? DXFEllipseEntity else { return }
            el.correctAxis()
            out += "  0\r\nELLIPSE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: el.layer))\r\n"
            writeCommonEntityData(el, &out)
            out += "100\r\nAcDbEllipse\r\n"
            writePoint3(10, el.basePoint, &out)
            writePoint3(11, el.secPoint, &out)
            writeDbl(40, el.ratio, &out)
            writeDbl(41, el.startParam, &out)
            writeDbl(42, el.endParam, &out)

        case .lWPOLYLINE:
            guard let lw = e as? DXFLWPolylineEntity else { return }
            out += "  0\r\nLWPOLYLINE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: lw.layer))\r\n"
            writeCommonEntityData(lw, &out)
            out += "100\r\nAcDbPolyline\r\n"
            writeInt(90, lw.vertices.count, &out)
            writeInt(70, lw.flags, &out)
            writeDbl(43, lw.width, &out)
            writeDbl(38, lw.elevation, &out)
            writeDbl(39, lw.thickness_p, &out)
            for v in lw.vertices {
                writeDbl(10, v.x, &out)
                writeDbl(20, v.y, &out)
                if v.startWidth != 0 { writeDbl(40, v.startWidth, &out) }
                if v.endWidth != 0 { writeDbl(41, v.endWidth, &out) }
                if v.bulge != 0 { writeDbl(42, v.bulge, &out) }
            }
            writeCoord3(210, lw.extPoint, &out)

        case .pOLYLINE:
            guard let pl = e as? DXFPolylineEntity else { return }
            out += "  0\r\nPOLYLINE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: pl.layer))\r\n"
            writeCommonEntityData(pl, &out)
            out += "100\r\nAcDb2dPolyline\r\n"
            writePoint3(10, pl.basePoint, &out)
            writeDbl(40, pl.defStartWidth, &out)
            writeDbl(41, pl.defEndWidth, &out)
            writeInt(70, pl.flags, &out)
            writeInt(71, pl.vertexCount, &out)
            writeInt(72, pl.faceCount, &out)
            writeInt(73, pl.smoothM, &out)
            writeInt(74, pl.smoothN, &out)
            writeInt(75, pl.curveType, &out)
            // Write VERTEX entities
            for v in pl.vertices {
                writeVertex(v, &out)
            }
            out += "  0\r\nSEQEND\r\n  5\r\n\(allocHandle())\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: pl.layer))\r\n"

        case .sPLINE:
            guard let sp = e as? DXFSplineEntity else { return }
            out += "  0\r\nSPLINE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: sp.layer))\r\n"
            writeCommonEntityData(sp, &out)
            out += "100\r\nAcDbSpline\r\n"
            writeCoord3(210, sp.normalVec, &out)
            writeInt(70, sp.flags, &out)
            writeInt(71, sp.degree, &out)
            writeInt(72, Int(sp.nKnots), &out)
            writeInt(73, Int(sp.nControl), &out)
            writeInt(74, Int(sp.nFit), &out)
            writeDbl(42, sp.tolKnot, &out)
            writeDbl(43, sp.tolControl, &out)
            writeDbl(44, sp.tolFit, &out)
            for k in sp.knots { writeDbl(40, k, &out) }
            for w in sp.weights { writeDbl(41, w, &out) }
            for cp in sp.controlPoints { writePoint3(10, cp, &out) }
            for fp in sp.fitPoints { writePoint3(11, fp, &out) }
            writePoint3(12, sp.tgStart, &out)
            writePoint3(13, sp.tgEnd, &out)

        case .tEXT:
            guard let tx = e as? DXFTextEntity else { return }
            out += "  0\r\nTEXT\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: tx.layer))\r\n"
            writeCommonEntityData(tx, &out)
            out += "100\r\nAcDbText\r\n"
            writePoint3(10, tx.basePoint, &out)
            writeDbl(40, tx.height, &out)
            writeStr(1, tx.text, &out)
            writeDbl(50, tx.angle_p, &out)  // degrees
            writeDbl(41, tx.widthScale, &out)
            writeDbl(51, tx.oblique, &out)
            writeStr(7, tx.style, &out)
            writeInt(71, tx.textGen, &out)
            writeInt(72, tx.alignH, &out)
            writeInt(73, tx.alignV, &out)
            if tx.alignH != 0 || tx.alignV != 0 {
                writePoint3(11, tx.secPoint, &out)  // alignment point
            }
            out += "100\r\nAcDbText\r\n"

        case .mTEXT:
            guard let mt = e as? DXFMTextEntity else { return }
            out += "  0\r\nMTEXT\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: mt.layer))\r\n"
            writeCommonEntityData(mt, &out)
            out += "100\r\nAcDbMText\r\n"
            writePoint3(10, mt.basePoint, &out)
            writeDbl(40, mt.height, &out)
            writeDbl(41, mt.widthScale, &out)
            writeDbl(44, mt.interlin, &out)
            writeDbl(50, mt.angle_p, &out)  // degrees
            writeInt(71, mt.textGen, &out)  // attachment
            writeInt(72, mt.alignH, &out)   // drawing direction
            writeMTextString(mt.text, &out)
            writeStr(7, mt.style, &out)

        case .iNSERT:
            guard let ins = e as? DXFInsertEntity else { return }
            out += "  0\r\nINSERT\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: ins.layer))\r\n"
            writeCommonEntityData(ins, &out)
            out += "100\r\nAcDbBlockReference\r\n"
            writeStr(2, ins.name, &out)
            writePoint3(10, ins.basePoint, &out)
            writeDbl(41, ins.xScale, &out)
            writeDbl(42, ins.yScale, &out)
            writeDbl(43, ins.zScale, &out)
            writeDbl(50, ins.angle * 180.0 / .pi, &out)  // radians → degrees
            writeInt(70, ins.colCount, &out)
            writeInt(71, ins.rowCount, &out)
            writeDbl(44, ins.colSpace, &out)
            writeDbl(45, ins.rowSpace, &out)

        case .sOLID:
            guard let sd = e as? DXFSolidEntity else { return }
            out += "  0\r\nSOLID\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: sd.layer))\r\n"
            writeCommonEntityData(sd, &out)
            out += "100\r\nAcDbTrace\r\n"
            writePoint3(10, sd.basePoint, &out)
            writePoint3(11, sd.secPoint, &out)
            writePoint3(12, sd.thirdPoint, &out)
            writePoint3(13, sd.fourPoint, &out)

        case .tRACE:
            guard let tr = e as? DXFTraceEntity else { return }
            out += "  0\r\nTRACE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: tr.layer))\r\n"
            writeCommonEntityData(tr, &out)
            out += "100\r\nAcDbTrace\r\n"
            writePoint3(10, tr.basePoint, &out)
            writePoint3(11, tr.secPoint, &out)
            writePoint3(12, tr.thirdPoint, &out)
            writePoint3(13, tr.fourPoint, &out)

        case .e3DFACE:
            guard let f3 = e as? DXF3DFaceEntity else { return }
            out += "  0\r\n3DFACE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: f3.layer))\r\n"
            writeCommonEntityData(f3, &out)
            out += "100\r\nAcDbFace\r\n"
            writePoint3(10, f3.basePoint, &out)
            writePoint3(11, f3.secPoint, &out)
            writePoint3(12, f3.thirdPoint, &out)
            writePoint3(13, f3.fourPoint, &out)
            writeInt(70, f3.invisibleFlag, &out)

        case .xLINE:
            guard let xl = e as? DXFXLineEntity else { return }
            out += "  0\r\nXLINE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: xl.layer))\r\n"
            writeCommonEntityData(xl, &out)
            out += "100\r\nAcDbXline\r\n"
            writePoint3(10, xl.basePoint, &out)
            let xlDir = unitize(xl.secPoint)
            writePoint3(11, xlDir, &out)

        case .rAY:
            guard let ry = e as? DXFRayEntity else { return }
            out += "  0\r\nRAY\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: ry.layer))\r\n"
            writeCommonEntityData(ry, &out)
            out += "100\r\nAcDbRay\r\n"
            writePoint3(10, ry.basePoint, &out)
            let ryDir = unitize(ry.secPoint)
            writePoint3(11, ryDir, &out)

        case .dIMENSION:
            guard let dm = e as? DXFDimensionEntity else { return }
            out += "  0\r\nDIMENSION\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: dm.layer))\r\n"
            writeCommonEntityData(dm, &out)
            out += "100\r\nAcDbDimension\r\n"
            writeStr(2, dm.name, &out)
            writeStr(3, dm.style, &out)
            writeInt(70, dm.type, &out)
            writePoint3(10, dm.defPoint, &out)
            writePoint3(11, dm.textPoint, &out)
            writeDbl(41, dm.lineFactor, &out)
            writeDbl(53, dm.rot, &out)
            writeCoord3(210, dm.extPoint, &out)
            writeStr(1, dm.text, &out)
            writeInt(71, dm.align, &out)
            writeInt(72, dm.lineStyle, &out)

        case .lEADER:
            guard let ld = e as? DXFLeaderEntity else { return }
            out += "  0\r\nLEADER\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: ld.layer))\r\n"
            writeCommonEntityData(ld, &out)
            out += "100\r\nAcDbLeader\r\n"
            writeStr(3, ld.style, &out)
            writeInt(71, ld.arrow, &out)
            writeInt(72, ld.leaderType, &out)
            writeInt(73, ld.flag, &out)
            writeInt(74, ld.hookLine, &out)
            writeInt(75, ld.hookFlag, &out)
            writeDbl(40, ld.textHeight, &out)
            writeDbl(41, ld.textWidth, &out)
            writeInt(76, ld.vertices.count, &out)
            writeInt(77, ld.colorUse, &out)
            for v in ld.vertices { writePoint3(10, v, &out) }
            writeCoord3(210, ld.extrusionPoint, &out)

        case .hATCH:
            guard let ht = e as? DXFHatchEntity else { return }
            out += "  0\r\nHATCH\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: ht.layer))\r\n"
            writeCommonEntityData(ht, &out)
            out += "100\r\nAcDbHatch\r\n"
            writePoint3(10, ht.basePoint, &out)
            writeCoord3(210, ht.extrusion, &out)
            writeStr(2, ht.name, &out)
            writeInt(70, ht.solid, &out)
            writeInt(71, ht.associative, &out)
            writeInt(91, ht.loops.count, &out)

            for loop in ht.loops {
                writeInt(92, loop.type, &out)

                if (loop.type & 2) != 0,
                   let polyline = loop.entities.compactMap({ $0 as? DXFLWPolylineEntity }).first {
                    let hasBulge = polyline.vertices.contains { abs($0.bulge) > 1e-12 }
                    writeInt(72, hasBulge ? 1 : 0, &out)
                    writeInt(73, (polyline.flags & 1) != 0 ? 1 : 0, &out)
                    writeInt(93, polyline.vertices.count, &out)
                    for vertex in polyline.vertices {
                        writeDbl(10, vertex.x, &out)
                        writeDbl(20, vertex.y, &out)
                        if hasBulge { writeDbl(42, vertex.bulge, &out) }
                    }
                    continue
                }

                writeInt(93, loop.entities.count, &out)
                for boundary in loop.entities {
                    if let line = boundary as? DXFLineEntity {
                        writeInt(72, 1, &out)
                        writePoint(10, line.basePoint, &out)
                        writePoint(11, line.secPoint, &out)
                    } else if let arc = boundary as? DXFArcEntity {
                        writeInt(72, 2, &out)
                        writePoint(10, arc.basePoint, &out)
                        writeDbl(40, arc.radius, &out)
                        writeDbl(50, arc.startAngle * 180.0 / .pi, &out)
                        writeDbl(51, arc.endAngle * 180.0 / .pi, &out)
                        writeInt(73, arc.isCCW != 0 ? 1 : 0, &out)
                    } else if let ellipse = boundary as? DXFEllipseEntity {
                        writeInt(72, 3, &out)
                        writePoint(10, ellipse.basePoint, &out)
                        writePoint(11, ellipse.secPoint, &out)
                        writeDbl(40, ellipse.ratio, &out)
                        writeDbl(50, ellipse.startParam * 180.0 / .pi, &out)
                        writeDbl(51, ellipse.endParam * 180.0 / .pi, &out)
                        writeInt(73, ellipse.isCCW != 0 ? 1 : 0, &out)
                    } else if let spline = boundary as? DXFSplineEntity {
                        writeInt(72, 4, &out)
                        writeInt(94, spline.degree, &out)
                        writeInt(73, (spline.flags & 4) != 0 ? 1 : 0, &out)
                        writeInt(74, (spline.flags & 2) != 0 ? 1 : 0, &out)
                        writeInt(95, spline.knots.count, &out)
                        writeInt(96, spline.controlPoints.count, &out)
                        for knot in spline.knots { writeDbl(40, knot, &out) }
                        if (spline.flags & 4) != 0 {
                            for weight in spline.weights { writeDbl(42, weight, &out) }
                        }
                        for point in spline.controlPoints { writePoint(10, point, &out) }
                        writeInt(97, spline.fitPoints.count, &out)
                        for point in spline.fitPoints { writePoint(11, point, &out) }
                        if !spline.fitPoints.isEmpty {
                            writePoint(12, spline.tgStart, &out)
                            writePoint(13, spline.tgEnd, &out)
                        }
                    }
                }
            }

            writeInt(75, ht.hStyle, &out)
            writeInt(76, ht.hPattern, &out)
            writeInt(77, ht.doubleFlag, &out)

            if ht.solid == 0 {
                writeDbl(52, ht.angle_p, &out)
                writeDbl(41, ht.scale, &out)
                let patternLines = ht.patternLines
                writeInt(78, patternLines.count, &out)
                for line in patternLines {
                    writeDbl(53, line.angle, &out)
                    writeDbl(43, line.base.x, &out)
                    writeDbl(44, line.base.y, &out)
                    writeDbl(45, line.offset.x, &out)
                    writeDbl(46, line.offset.y, &out)
                    writeInt(79, line.dashes.count, &out)
                    for dash in line.dashes { writeDbl(49, dash, &out) }
                }
            }

            if ht.isGradient == 0, ht.bgColor >= 0 {
                writeInt(63, Int(ht.bgColor), &out)
            }
            writeDbl(47, 1.0, &out)
            writeInt(98, 0, &out)

            writeInt(450, ht.isGradient, &out)
            if ht.isGradient != 0 {
                writeInt(451, 0, &out)
                writeDbl(460, ht.gradientAngle * .pi / 180.0, &out)
                writeDbl(461, ht.gradientShift, &out)
                writeInt(452, ht.singleColorGrad, &out)
                writeDbl(462, ht.gradientTint, &out)
                writeInt(453, ht.gradientColors.count, &out)
                for stop in ht.gradientColors {
                    writeDbl(463, stop.position, &out)
                    writeInt(63, Int(stop.aci), &out)
                    if stop.rgb >= 0 { writeInt(421, Int(stop.rgb), &out) }
                }
                writeStr(470, ht.gradientName, &out)
            }

        case .iMAGE:
            guard let im = e as? DXFImageEntity else { return }
            out += "  0\r\nIMAGE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: im.layer))\r\n"
            writeCommonEntityData(im, &out)
            out += "100\r\nAcDbRasterImage\r\n"
            writeInt(340, Int(im.ref), &out)
            writePoint3(10, im.basePoint, &out)
            writePoint3(11, im.secPoint, &out)     // U-vector
            writePoint3(12, im.vVector, &out)       // V-vector
            writeDbl(13, im.sizeU, &out)
            writeDbl(23, im.sizeV, &out)
            writeDbl(33, im.dz, &out)
            writeInt(280, im.clip, &out)
            writeInt(281, im.brightness, &out)
            writeInt(282, im.contrast, &out)
            writeInt(283, im.fade, &out)

        case .vIEWPORT:
            guard let vp = e as? DXFViewportEntity else { return }
            out += "  0\r\nVIEWPORT\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n\(esc(layer: vp.layer))\r\n"
            writeCommonEntityData(vp, &out)
            out += "100\r\nAcDbViewport\r\n"
            writePoint3(10, vp.basePoint, &out)
            writeDbl(40, vp.psHeight, &out)
            writeDbl(41, vp.psWidth, &out)
            writeInt(68, vp.vpStatus, &out)
            writeInt(69, vp.vpID, &out)
            writeDbl(12, vp.centerPX, &out)
            writeDbl(22, vp.centerPY, &out)

        case .tABLE:
            out += "  0\r\nACAD_TABLE\r\n  5\r\n\(h)\r\n"
            out += "100\r\nAcDbEntity\r\n  8\r\n0\r\n"
            writeCommonEntityData(e, &out)
            out += "100\r\nAcDbTable\r\n"

        default:
            break
        }
    }

    private func writeVertex(_ v: DXFVertexEntity, _ out: inout String) {
        out += "  0\r\nVERTEX\r\n  5\r\n\(allocHandle())\r\n"
        out += "100\r\nAcDbEntity\r\n  8\r\n0\r\n"
        out += "100\r\nAcDbVertex\r\n"
        out += "100\r\nAcDb2dVertex\r\n"
        writePoint3(10, v.basePoint, &out)
        writeDbl(40, v.startWidth, &out)
        writeDbl(41, v.endWidth, &out)
        writeDbl(42, v.bulge, &out)
        writeInt(70, v.flags, &out)
        writeDbl(50, v.tangentDir, &out)
        writeInt(71, v.vIndex1, &out)
        writeInt(72, v.vIndex2, &out)
        writeInt(73, v.vIndex3, &out)
        writeInt(74, v.vIndex4, &out)
        writeInt(91, v.identifier, &out)
    }

    private func writeCommonEntityData(_ e: DXFEntity, _ out: inout String) {
        if e.color != 256 { writeInt(62, Int(e.color), &out) }
        if e.color24 >= 0 { writeInt(420, Int(e.color24), &out) }
        if e.lineType != "BYLAYER" { writeStr(6, e.lineType, &out) }
        if e.ltypeScale != 1.0 { writeDbl(48, e.ltypeScale, &out) }
        if !e.visible { writeInt(60, 0, &out) }
        if e.space != 0 { writeInt(67, e.space, &out) }
        if e.lWeight != .byLayer { writeInt(370, e.lWeight.dxfInt, &out) }
        if e.plotStyleHandle != 0 {
            writeStr(390, String(format: "%X", e.plotStyleHandle), &out)
        }
        if !e.colorName.isEmpty { writeStr(430, e.colorName, &out) }
        if e.transparency >= 0 { writeInt(440, Int(e.transparency), &out) }
        if e.haveExtrusion || e.extrusion != Vector3(x: 0, y: 0, z: 1) {
            writeCoord3(210, e.extrusion, &out)
        }
        if e.handle != 0 { writeStr(5, String(format: "%X", e.handle), &out) }
        if e.parentHandle != 0 { writeStr(330, String(format: "%X", e.parentHandle), &out) }
    }

    // MARK: - OBJECTS

        private func writeObjects(_ out: inout String) {
        if !isModern { return }

        // Collect image defs from IMAGE entities
        var imageDefs: [DXFImageDefEntry] = []
        for entity in entities {
            if let img = entity as? DXFImageEntity {
                let defName = img.handle != 0 ? String(format: "Img_%X", img.handle) : "Image_0"
                if !imageDefs.contains(where: { $0.name == defName }) {
                    let def = DXFImageDefEntry()
                    def.name = defName
                    def.handle = img.ref != 0 ? img.ref : allocHandleU32()
                    def.u = img.sizeU
                    def.v = img.sizeV
                    def.up = 1.0
                    def.vp = 1.0
                    imageDefs.append(def)
                }
            }
        }

        out += "  0\r\nSECTION\r\n  2\r\nOBJECTS\r\n"

        // Root DICTIONARY (fixed handle C)
        var imgDictH = ""
        out += "  0\r\nDICTIONARY\r\n  5\r\nC\r\n"
        out += "330\r\n0\r\n100\r\nAcDbDictionary\r\n"
        out += "281\r\n1\r\n"
        out += "  3\r\nACAD_GROUP\r\n350\r\nD\r\n"
        if !imageDefs.isEmpty {
            imgDictH = allocHandle()
            out += "  3\r\nACAD_IMAGE_DICT\r\n350\r\n\(imgDictH)\r\n"
        }

        // ACAD_GROUP DICTIONARY (fixed handle D)
        out += "  0\r\nDICTIONARY\r\n  5\r\nD\r\n"
        out += "330\r\nC\r\n100\r\nAcDbDictionary\r\n"
        out += "281\r\n1\r\n"

        if !imageDefs.isEmpty {
            // IMAGEDEF_REACTOR for each image def
            for def in imageDefs {
                if def.reactors.isEmpty {
                    let reactorH = allocHandle()
                    let entityH = String(format: "%X", def.handle)
                    def.reactors[reactorH] = entityH
                }
                for (reactorH, entityH) in def.reactors {
                    out += "  0\r\nIMAGEDEF_REACTOR\r\n"
                    out += "  5\r\n\(reactorH)\r\n"
                    out += "330\r\n\(entityH)\r\n"
                    out += "100\r\nAcDbRasterImageDefReactor\r\n"
                    out += " 90\r\n2\r\n"
                    out += "330\r\n\(entityH)\r\n"
                }
            }

            // IMAGE_DICT dictionary
            out += "  0\r\nDICTIONARY\r\n  5\r\n\(imgDictH)\r\n"
            out += "330\r\nC\r\n100\r\nAcDbDictionary\r\n"
            out += "281\r\n1\r\n"
            for def in imageDefs {
                let dictName = (def.name as NSString).lastPathComponent
                let nameNoExt = (dictName as NSString).deletingPathExtension
                let entryName = nameNoExt.isEmpty ? def.name : nameNoExt
                out += "  3\r\n\(entryName)\r\n"
                out += "350\r\n\(String(format: "%X", def.handle))\r\n"
            }

            // IMAGEDEF entries
            for def in imageDefs {
                out += "  0\r\nIMAGEDEF\r\n"
                out += "  5\r\n\(String(format: "%X", def.handle))\r\n"
                out += "102\r\n{ACAD_REACTORS\r\n"
                for (reactorH, _) in def.reactors {
                    out += "330\r\n\(reactorH)\r\n"
                }
                out += "102\r\n}\r\n"
                out += "100\r\nAcDbRasterImageDef\r\n"
                out += " 90\r\n\(def.imgVersion)\r\n"
                writeStr(1, def.name_p.isEmpty ? def.name : def.name_p, &out)
                writeDbl(10, def.u, &out)
                writeDbl(20, def.v, &out)
                writeDbl(11, def.up, &out)
                writeDbl(21, def.vp, &out)
                writeInt(280, def.loaded, &out)
                writeInt(281, def.resolution, &out)
            }
        }

        out += "  0\r\nENDSEC\r\n"
    }

    // MARK: - Write Helpers

    private func writeStr(_ code: Int, _ val: String, _ out: inout String) {
        if val.isEmpty { return }
        let encoded = textCodec.fromUtf8(val)
        out += String(format: "%3d\r\n", code)
        out += encoded + "\r\n"
    }

    private func writeInt(_ code: Int, _ val: Int, _ out: inout String) {
        out += String(format: "%3d\r\n%d\r\n", code, val)
    }

    private func writeDbl(_ code: Int, _ val: Double, _ out: inout String) {
        out += String(format: "%3d\r\n", code)
        out += dxfFmt(val) + "\r\n"
    }

    private func writeBool(_ code: Int, _ val: Bool, _ out: inout String) {
        writeInt(code, val ? 1 : 0, &out)
    }

    /// Write MText string, chunking >250 chars into code 3 segments
    private func writeMTextString(_ text: String, _ out: inout String) {
        let maxChunk = 250
        var remaining = text
        while remaining.utf8.count > maxChunk {
            let byteView = Data(remaining.utf8)
            let chunk = String(data: byteView[0..<maxChunk], encoding: .utf8) ?? String(remaining.prefix(maxChunk))
            writeStr(3, chunk, &out)
            remaining = String(remaining.dropFirst(chunk.count))
        }
        writeStr(1, remaining, &out)
    }

    /// Unitize a direction vector
    private func unitize(_ v: Vector3) -> Vector3 {
        let dist = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        if dist > 0 { return Vector3(x: v.x / dist, y: v.y / dist, z: v.z / dist) }
        return v
    }

    private func writePoint(_ code: Int, _ p: Vector3, _ out: inout String) {
        writeDbl(code, p.x, &out)
        writeDbl(code + 10, p.y, &out)
    }

    private func writePoint3(_ code: Int, _ p: Vector3, _ out: inout String) {
        writeDbl(code, p.x, &out)
        writeDbl(code + 10, p.y, &out)
        writeDbl(code + 20, p.z, &out)
    }

    private func writeCoord3(_ code: Int, _ p: Vector3, _ out: inout String) {
        writeDbl(code, p.x, &out)
        writeDbl(code + 10, p.y, &out)
        writeDbl(code + 20, p.z, &out)
    }

    private func esc(layer name: String) -> String {
        return name.isEmpty ? "0" : name
    }

    /// Format double for DXF: trim trailing zeros, use '.0' for integers
    private func dxfFmt(_ val: Double) -> String {
        if val.isNaN || val.isInfinite { return "0.0" }
        // Use 6 decimal places max, trim trailing zeros
        let s = String(format: "%.6f", val)
        if s.contains(".") {
            var trimmed = s
            while trimmed.hasSuffix("0") { trimmed = String(trimmed.dropLast()) }
            if trimmed.hasSuffix(".") { trimmed = String(trimmed.dropLast()) + ".0" }
            return trimmed
        }
        return s
    }
}
