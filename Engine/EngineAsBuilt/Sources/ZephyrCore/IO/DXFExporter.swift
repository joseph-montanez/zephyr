import Foundation

// =========================================================================
// MARK: - DXFExporter
//
// Exports a Zephyr CAD document to AutoCAD DXF format (AC1021 / R2007).
// Produces a fully-structured DXF with subclass markers, handles, owner
// pointers, BLOCKS, and OBJECTS sections that AutoCAD can parse correctly.

public enum DXFExporter {

    // MARK: - Public API

    /// Export the document to a DXF file at the given URL.
    /// Delegates to libdxfrw via the CDXFRW bridge for properly structured DXF output.
    public static func export(document: CADDocument, to url: URL) throws {
        try DXFWriterBridge.export(document: document, to: url)
    }

    /// Background-save: export from a snapshot with progress and cancellation.
    public static func export(snapshot: CADDocumentSnapshot, to url: URL,
                               progress: ((Float) -> Void)? = nil) throws {
        try Task.checkCancellation()
        progress?(0.5)
        let tempDoc = CADDocument()
        tempDoc.restore(from: snapshot)
        try DXFWriterBridge.export(document: tempDoc, to: url)
        progress?(1.0)
    }

    private static func estimateDXFSize(snapshot: CADDocumentSnapshot) -> Int {
        return 2000 + snapshot.entities.count * 200 + snapshot.blocks.count * 150
    }

    private static func atomicWrite(data: Data, to targetURL: URL) throws {
        let tmpURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try data.write(to: tmpURL, options: .atomic)
#if os(Windows)
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: targetURL)
#else
        if FileManager.default.fileExists(atPath: targetURL.path) {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: targetURL)
        }
#endif
    }

    // MARK: - ExportContext (handle tracking)

    /// Tracks pre-assigned handles and generates sequential entity handles.
    private final class ExportContext {
        let document: CADDocument

        // Pre-assigned fixed handles for infrastructure objects
        static let handleBlockRecordTable   = "1"
        static let handleLayerTable         = "2"
        static let handleStyleTable         = "3"
        static let handleLtypeTable         = "5"
        static let handleViewTable          = "6"
        static let handleUcsTable           = "7"
        static let handleVportTable         = "8"
        static let handleAppidTable         = "9"
        static let handleDimstyleTable      = "A"
        static let handleDictionary         = "C"
        static let handleAcadGroupDict      = "D"
        static let handlePlotSettings       = "E"

        // Records
        static let handleLayer0             = "10"
        static let handleLtypeByBlock       = "11"
        static let handleLtypeByLayer       = "12"
        static let handleLtypeContinuous    = "13"
        static let handleVportActive        = "14"
        static let handleAppidAcad          = "15"
        static let handleStyleStandard      = "16"
        static let handleDimstyleStandard   = "17"
        static let handleBlockRecModel      = "18"
        static let handleBlockRecPaper      = "19"

        // Blocks
        static let handleBlockModel         = "20"
        static let handleEndblkModel        = "21"
        static let handleBlockPaper         = "22"
        static let handleEndblkPaper        = "23"

        // PlotStyleName object for layer 0
        static let handlePlotStyleName      = "F"

        // First entity handle
        private static let firstEntityHandle = 0x24

        private var _nextEntityHandle: Int = firstEntityHandle

        var nextEntityHandleValue: Int { _nextEntityHandle }

        /// Maps layer UUID → hex handle string
        var layerHandles: [UUID: String] = [:]

        init(document: CADDocument) {
            self.document = document
            // Assign handles to user layers starting from 0x30
            var nextLayerHandle = 0x30
            for layer in document.allLayers where layer.name.lowercased() != "0" {
                layerHandles[layer.handle] = String(format: "%X", nextLayerHandle)
                nextLayerHandle += 1
            }
        }

        func nextHandle() -> String {
            let h = String(format: "%X", _nextEntityHandle)
            _nextEntityHandle += 1
            return h
        }

        func layerHandle(for id: UUID) -> String {
            layerHandles[id] ?? ExportContext.handleLayer0
        }
    }

    // MARK: - HEADER Section

    private static func writeHeader(_ ctx: ExportContext, into output: inout String) {
        let doc = ctx.document

        // Compute extents from entity world bounding boxes
        var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0
        var hasExtents = false
        for entity in doc.allEntities {
            guard let bb = entity.worldBoundingBox else { continue }
            if !hasExtents {
                minX = bb.min.x; maxX = bb.max.x; minY = bb.min.y; maxY = bb.max.y
                hasExtents = true
            } else {
                minX = min(minX, bb.min.x); maxX = max(maxX, bb.max.x)
                minY = min(minY, bb.min.y); maxY = max(maxY, bb.max.y)
            }
        }

        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nHEADER\r\n"
        output += "  9\r\n$ACADVER\r\n"
        output += "  1\r\nAC1021\r\n"
        output += "  9\r\n$DWGCODEPAGE\r\n"
        output += "  3\r\nANSI_1252\r\n"
        output += "  9\r\n$INSBASE\r\n"
        output += " 10\r\n0.0\r\n 20\r\n0.0\r\n 30\r\n0.0\r\n"
        output += "  9\r\n$EXTMIN\r\n"
        output += " 10\r\n\(dxfDouble(minX))\r\n 20\r\n\(dxfDouble(-maxY))\r\n 30\r\n0.0\r\n"
        output += "  9\r\n$EXTMAX\r\n"
        output += " 10\r\n\(dxfDouble(maxX))\r\n 20\r\n\(dxfDouble(-minY))\r\n 30\r\n0.0\r\n"
        output += "  9\r\n$LIMMIN\r\n"
        output += " 10\r\n0.0\r\n 20\r\n0.0\r\n"
        output += "  9\r\n$LIMMAX\r\n"
        output += " 10\r\n420.0\r\n 20\r\n297.0\r\n"
        output += "  9\r\n$LUNITS\r\n"
        output += " 70\r\n2\r\n"
        output += "  9\r\n$LUPREC\r\n"
        output += " 70\r\n4\r\n"
        output += "  9\r\n$AUNITS\r\n"
        output += " 70\r\n0\r\n"
        output += "  9\r\n$AUPREC\r\n"
        output += " 70\r\n2\r\n"
        output += "  9\r\n$INSUNITS\r\n"
        output += " 70\r\n\(doc.unit.dxfINSUNITS)\r\n"
        output += "  9\r\n$MEASUREMENT\r\n"
        let isMetric = doc.unit == .millimeter || doc.unit == .centimeter || doc.unit == .meter
        output += " 70\r\n\(isMetric ? 1 : 0)\r\n"
        output += "  9\r\n$CELWEIGHT\r\n"
        output += "370\r\n-1\r\n"
        output += "  9\r\n$ENDCAPS\r\n"
        output += "280\r\n0\r\n"
        output += "  9\r\n$JOINSTYLE\r\n"
        output += "280\r\n0\r\n"
        output += "  9\r\n$LWDISPLAY\r\n"
        output += "290\r\n0\r\n"
        output += "  9\r\n$CLAYER\r\n"
        output += "  8\r\n0\r\n"
        output += "  9\r\n$CELTYPE\r\n"
        output += "  6\r\nByLayer\r\n"
        output += "  9\r\n$CECOLOR\r\n"
        output += " 62\r\n256\r\n"
        output += "  9\r\n$CELTSCALE\r\n"
        output += " 40\r\n1.0\r\n"
        output += "  9\r\n$LTSCALE\r\n"
        output += " 40\r\n1.0\r\n"
        output += "  9\r\n$TEXTSIZE\r\n"
        output += " 40\r\n2.5\r\n"
        output += "  9\r\n$TEXTSTYLE\r\n"
        output += "  7\r\nStandard\r\n"
        output += "  9\r\n$DIMSCALE\r\n"
        output += " 40\r\n1.0\r\n"
        output += "  9\r\n$DIMASZ\r\n"
        output += " 40\r\n2.5\r\n"
        output += "  9\r\n$DIMEXO\r\n"
        output += " 40\r\n0.625\r\n"
        output += "  9\r\n$DIMEXE\r\n"
        output += " 40\r\n1.25\r\n"
        output += "  9\r\n$DIMTXT\r\n"
        output += " 40\r\n2.5\r\n"
        output += "  9\r\n$DIMTAD\r\n"
        output += " 70\r\n1\r\n"
        output += "  9\r\n$DIMZIN\r\n"
        output += " 70\r\n8\r\n"
        output += "  9\r\n$DIMTOFL\r\n"
        output += " 70\r\n1\r\n"
        output += "  9\r\n$DIMLUNIT\r\n"
        output += " 70\r\n2\r\n"
        output += "  9\r\n$DIMLWD\r\n"
        output += " 70\r\n-2\r\n"
        output += "  9\r\n$DIMLWE\r\n"
        output += " 70\r\n-2\r\n"
        output += "  9\r\n$DIMASSOC\r\n"
        output += "280\r\n1\r\n"
        output += "  9\r\n$PSTYLEMODE\r\n"
        output += "290\r\n1\r\n"
        output += "  9\r\n$HANDSEED\r\n"
        output += "  5\r\n\(String(format: "%X", ctx.nextEntityHandleValue + 100))\r\n"
        output += "  9\r\n$TILEMODE\r\n"
        output += " 70\r\n1\r\n"
        output += "  9\r\n$PLINEGEN\r\n"
        output += " 70\r\n0\r\n"
        output += "  0\r\nENDSEC\r\n"
    }

    // MARK: - CLASSES Section

    private static func writeClasses(into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nCLASSES\r\n"
        output += "  0\r\nENDSEC\r\n"
    }

    // MARK: - TABLES Section

    private static func writeTables(_ ctx: ExportContext, into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nTABLES\r\n"

        writeVportTable(into: &output)
        writeLtypeTable(into: &output)
        writeLayerTable(ctx, into: &output)
        writeStyleTable(into: &output)
        writeViewTable(into: &output)
        writeUcsTable(into: &output)
        writeAppidTable(into: &output)
        writeDimstyleTable(into: &output)
        writeBlockRecordTable(into: &output)

        output += "  0\r\nENDSEC\r\n"
    }

    private static func writeVportTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nVPORT\r\n"
        output += "  5\r\n\(ExportContext.handleVportTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n1\r\n"
        output += "  0\r\nVPORT\r\n"
        output += "  5\r\n\(ExportContext.handleVportActive)\r\n"
        output += "330\r\n\(ExportContext.handleVportTable)\r\n"
        output += "100\r\nAcDbSymbolTableRecord\r\n"
        output += "100\r\nAcDbViewportTableRecord\r\n"
        output += "  2\r\n*ACTIVE\r\n"
        output += " 70\r\n0\r\n"
        output += " 10\r\n0.0\r\n 20\r\n0.0\r\n"
        output += " 11\r\n1.0\r\n 21\r\n1.0\r\n"
        output += " 12\r\n286.0\r\n 22\r\n211.0\r\n"
        output += " 13\r\n0.0\r\n 23\r\n0.0\r\n"
        output += " 14\r\n10.0\r\n 24\r\n10.0\r\n"
        output += " 15\r\n10.0\r\n 25\r\n10.0\r\n"
        output += " 16\r\n0.0\r\n 26\r\n0.0\r\n 36\r\n1.0\r\n"
        output += " 17\r\n0.0\r\n 27\r\n0.0\r\n 37\r\n0.0\r\n"
        output += " 40\r\n297.0\r\n"
        output += " 41\r\n1.5\r\n"
        output += " 42\r\n50.0\r\n"
        output += " 43\r\n0.0\r\n 44\r\n0.0\r\n"
        output += " 50\r\n0.0\r\n 51\r\n0.0\r\n"
        output += " 71\r\n0\r\n 72\r\n100\r\n 73\r\n1\r\n 74\r\n3\r\n 75\r\n0\r\n 76\r\n1\r\n 77\r\n0\r\n 78\r\n0\r\n"
        output += "281\r\n0\r\n 65\r\n1\r\n"
        output += "110\r\n0.0\r\n120\r\n0.0\r\n130\r\n0.0\r\n"
        output += "111\r\n1.0\r\n121\r\n0.0\r\n131\r\n0.0\r\n"
        output += "112\r\n0.0\r\n122\r\n1.0\r\n132\r\n0.0\r\n"
        output += " 79\r\n0\r\n146\r\n0\r\n"
        output += "348\r\n\(ExportContext.handleVportActive)\r\n"
        output += " 60\r\n7\r\n 61\r\n5\r\n292\r\n1\r\n282\r\n1\r\n141\r\n0.0\r\n142\r\n0.0\r\n 63\r\n250\r\n421\r\n3358443\r\n"
        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeLtypeTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nLTYPE\r\n"
        output += "  5\r\n\(ExportContext.handleLtypeTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n3\r\n"

        for (name, handle, desc) in [("ByBlock", ExportContext.handleLtypeByBlock, ""),
                                      ("ByLayer", ExportContext.handleLtypeByLayer, ""),
                                      ("Continuous", ExportContext.handleLtypeContinuous, "Solid line")] {
            output += "  0\r\nLTYPE\r\n"
            output += "  5\r\n\(handle)\r\n"
            output += "330\r\n\(ExportContext.handleLtypeTable)\r\n"
            output += "100\r\nAcDbSymbolTableRecord\r\n"
            output += "100\r\nAcDbLinetypeTableRecord\r\n"
            output += "  2\r\n\(name)\r\n"
            output += " 70\r\n0\r\n"
            output += "  3\r\n\(desc)\r\n"
            output += " 72\r\n65\r\n"
            output += " 73\r\n0\r\n"
            output += " 40\r\n0.0\r\n"
        }

        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeLayerTable(_ ctx: ExportContext, into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nLAYER\r\n"
        output += "  5\r\n\(ExportContext.handleLayerTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n\(ctx.document.allLayers.count)\r\n"

        // Layer "0" is always present
        let layer0 = ctx.document.allLayers.first(where: { $0.name == "0" })
            ?? Layer(name: "0")
        writeLayerRecord(name: "0", handle: ExportContext.handleLayer0,
                         color: layer0.color, lw: layer0.lineWeight,
                         opacity: layer0.opacity, into: &output)

        // User layers
        for layer in ctx.document.allLayers where layer.name.lowercased() != "0" {
            writeLayerRecord(name: layer.name, handle: ctx.layerHandle(for: layer.handle),
                             color: layer.color, lw: layer.lineWeight,
                             opacity: layer.opacity, into: &output)
        }

        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeLayerRecord(name: String, handle: String,
                                          color: ColorRGBA, lw: Double,
                                          opacity: Double, into output: inout String) {
        output += "  0\r\nLAYER\r\n"
        output += "  5\r\n\(handle)\r\n"
        output += "330\r\n\(ExportContext.handleLayerTable)\r\n"
        output += "100\r\nAcDbSymbolTableRecord\r\n"
        output += "100\r\nAcDbLayerTableRecord\r\n"
        output += "  2\r\n\(dxfEscape(name))\r\n"
        output += " 70\r\n0\r\n"
        output += " 62\r\n\(rgbaToACI(color))\r\n"
        if let tc = rgbaToTrueColor(color) {
            output += "420\r\n\(tc)\r\n"
        }
        output += "  6\r\nCONTINUOUS\r\n"
        output += "370\r\n\(lineWeightToDXF(lw))\r\n"
        output += "390\r\n\(ExportContext.handlePlotStyleName)\r\n"
        if opacity < 1.0 {
            output += "440\r\n\(opacityToDXF(opacity))\r\n"
        }
    }

    private static func writeStyleTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nSTYLE\r\n"
        output += "  5\r\n\(ExportContext.handleStyleTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n1\r\n"
        output += "  0\r\nSTYLE\r\n"
        output += "  5\r\n\(ExportContext.handleStyleStandard)\r\n"
        output += "330\r\n\(ExportContext.handleStyleTable)\r\n"
        output += "100\r\nAcDbSymbolTableRecord\r\n"
        output += "100\r\nAcDbTextStyleTableRecord\r\n"
        output += "  2\r\nStandard\r\n"
        output += " 70\r\n0\r\n"
        output += " 40\r\n0.0\r\n"
        output += " 41\r\n1.0\r\n"
        output += " 50\r\n0.0\r\n"
        output += " 71\r\n0\r\n"
        output += " 42\r\n2.5\r\n"
        output += "  3\r\ntxt\r\n"
        output += "  4\r\n\r\n"
        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeViewTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nVIEW\r\n"
        output += "  5\r\n\(ExportContext.handleViewTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n0\r\n"
        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeUcsTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nUCS\r\n"
        output += "  5\r\n\(ExportContext.handleUcsTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n0\r\n"
        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeAppidTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nAPPID\r\n"
        output += "  5\r\n\(ExportContext.handleAppidTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n1\r\n"
        output += "  0\r\nAPPID\r\n"
        output += "  5\r\n\(ExportContext.handleAppidAcad)\r\n"
        output += "330\r\n\(ExportContext.handleAppidTable)\r\n"
        output += "100\r\nAcDbSymbolTableRecord\r\n"
        output += "100\r\nAcDbRegAppTableRecord\r\n"
        output += "  2\r\nACAD\r\n"
        output += " 70\r\n0\r\n"
        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeDimstyleTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nDIMSTYLE\r\n"
        output += "  5\r\n\(ExportContext.handleDimstyleTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += "100\r\nAcDbDimStyleTable\r\n"
        output += " 70\r\n1\r\n"
        output += " 71\r\n1\r\n"
        output += "  0\r\nDIMSTYLE\r\n"
        output += "105\r\n\(ExportContext.handleDimstyleStandard)\r\n"
        output += "330\r\n\(ExportContext.handleDimstyleTable)\r\n"
        output += "100\r\nAcDbSymbolTableRecord\r\n"
        output += "100\r\nAcDbDimStyleTableRecord\r\n"
        output += "  2\r\nStandard\r\n"
        output += " 70\r\n0\r\n"
        output += " 40\r\n1.0\r\n 41\r\n2.5\r\n 42\r\n0.625\r\n 43\r\n3.75\r\n 44\r\n1.25\r\n"
        output += " 73\r\n0\r\n 74\r\n0\r\n 77\r\n1\r\n 78\r\n8\r\n"
        output += "140\r\n2.5\r\n141\r\n2.5\r\n143\r\n25.4\r\n"
        output += "147\r\n0.625\r\n"
        output += "170\r\n0\r\n171\r\n2\r\n172\r\n0\r\n173\r\n0\r\n174\r\n0\r\n175\r\n0\r\n176\r\n0\r\n177\r\n0\r\n178\r\n0\r\n179\r\n0\r\n"
        output += "271\r\n2\r\n272\r\n2\r\n273\r\n2\r\n274\r\n2\r\n"
        output += "275\r\n0\r\n276\r\n0\r\n277\r\n2\r\n278\r\n0\r\n279\r\n0\r\n"
        output += "280\r\n0\r\n281\r\n0\r\n282\r\n0\r\n283\r\n1\r\n284\r\n0\r\n285\r\n0\r\n286\r\n0\r\n288\r\n0\r\n289\r\n3\r\n"
        output += "340\r\n\(ExportContext.handleStyleStandard)\r\n"
        output += "  0\r\nENDTAB\r\n"
    }

    private static func writeBlockRecordTable(into output: inout String) {
        output += "  0\r\nTABLE\r\n"
        output += "  2\r\nBLOCK_RECORD\r\n"
        output += "  5\r\n\(ExportContext.handleBlockRecordTable)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbSymbolTable\r\n"
        output += " 70\r\n2\r\n"

        for (name, handle) in [("*Model_Space", ExportContext.handleBlockRecModel),
                                ("*Paper_Space", ExportContext.handleBlockRecPaper)] {
            output += "  0\r\nBLOCK_RECORD\r\n"
            output += "  5\r\n\(handle)\r\n"
            output += "330\r\n\(ExportContext.handleBlockRecordTable)\r\n"
            output += "100\r\nAcDbSymbolTableRecord\r\n"
            output += "100\r\nAcDbBlockTableRecord\r\n"
            output += "  2\r\n\(name)\r\n"
            output += " 70\r\n0\r\n"
            output += "280\r\n1\r\n"
            output += "281\r\n0\r\n"
        }

        output += "  0\r\nENDTAB\r\n"
    }

    // MARK: - BLOCKS Section

    private static func writeBlocks(_ ctx: ExportContext, into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nBLOCKS\r\n"

        // *Model_Space
        output += "  0\r\nBLOCK\r\n"
        output += "  5\r\n\(ExportContext.handleBlockModel)\r\n"
        output += "330\r\n\(ExportContext.handleBlockRecModel)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n0\r\n"
        output += "100\r\nAcDbBlockBegin\r\n"
        output += "  2\r\n*Model_Space\r\n"
        output += " 70\r\n0\r\n"
        output += " 10\r\n0.0\r\n 20\r\n0.0\r\n 30\r\n0.0\r\n"
        output += "  3\r\n*Model_Space\r\n"
        output += "  1\r\n\r\n"
        output += "  0\r\nENDBLK\r\n"
        output += "  5\r\n\(ExportContext.handleEndblkModel)\r\n"
        output += "330\r\n\(ExportContext.handleBlockRecModel)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n0\r\n"
        output += "100\r\nAcDbBlockEnd\r\n"

        // *Paper_Space
        output += "  0\r\nBLOCK\r\n"
        output += "  5\r\n\(ExportContext.handleBlockPaper)\r\n"
        output += "330\r\n\(ExportContext.handleBlockRecPaper)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n0\r\n"
        output += "100\r\nAcDbBlockBegin\r\n"
        output += "  2\r\n*Paper_Space\r\n"
        output += " 70\r\n0\r\n"
        output += " 10\r\n0.0\r\n 20\r\n0.0\r\n 30\r\n0.0\r\n"
        output += "  3\r\n*Paper_Space\r\n"
        output += "  1\r\n\r\n"
        output += "  0\r\nENDBLK\r\n"
        output += "  5\r\n\(ExportContext.handleEndblkPaper)\r\n"
        output += "330\r\n\(ExportContext.handleBlockRecPaper)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n0\r\n"
        output += "100\r\nAcDbBlockEnd\r\n"

        // User blocks
        for block in ctx.document.allBlocks {
            let bh = ctx.nextHandle()
            let eh = ctx.nextHandle()
            output += "  0\r\nBLOCK\r\n"
            output += "  5\r\n\(bh)\r\n"
            output += "330\r\n\(ExportContext.handleBlockRecModel)\r\n"
            output += "100\r\nAcDbEntity\r\n"
            output += "  8\r\n0\r\n"
            output += "100\r\nAcDbBlockBegin\r\n"
            output += "  2\r\n\(dxfEscape(block.name))\r\n"
            output += " 70\r\n0\r\n"
            output += " 10\r\n0.0\r\n 20\r\n0.0\r\n 30\r\n0.0\r\n"
            output += "  3\r\n\(dxfEscape(block.name))\r\n"
            output += "  1\r\n\r\n"
            for prim in block.geometry {
                writePrimitive(prim, ctx: ctx, layerName: "0", into: &output)
            }
            output += "  0\r\nENDBLK\r\n"
            output += "  5\r\n\(eh)\r\n"
            output += "330\r\n\(bh)\r\n"
            output += "100\r\nAcDbEntity\r\n"
            output += "  8\r\n0\r\n"
            output += "100\r\nAcDbBlockEnd\r\n"
        }

        output += "  0\r\nENDSEC\r\n"
    }

    // MARK: - ENTITIES Section

    private static func writeEntities(_ ctx: ExportContext, into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nENTITIES\r\n"

        for entity in ctx.document.allEntities {
            writeEntity(entity, ctx: ctx, into: &output)
        }

        output += "  0\r\nENDSEC\r\n"
    }

    private static func writeEntity(_ entity: CADEntity, ctx: ExportContext,
                                    into output: inout String) {
        let layerName = ctx.document.layer(for: entity.layerID)?.name ?? "0"
        let handle = ctx.nextHandle()

        // Dimension entities
        if entity.dimensionMetadata != nil {
            writeDimension(entity: entity, handle: handle, layerName: layerName, into: &output)
            return
        }

        // Block instances (INSERT)
        if let blockID = entity.blockID, let block = ctx.document.block(for: blockID) {
            writeInsert(entity: entity, handle: handle, blockName: block.name,
                        layerName: layerName, into: &output)
            return
        }

        // Raw geometry
        guard let geometry = entity.localGeometry, !geometry.isEmpty else { return }

        // Text with xdata: special round-trip handling
        if let _ = entity.xdata["dxf.text"],
           let prim = geometry.first,
           case .text(let pos, _, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, let color) = prim {
            let formattedJSON: String? = entity.xdata["dxf.formattedText"].flatMap {
                if case .string(let s) = $0 { return s }; return nil
            }
            let rawMText: String? = entity.xdata["dxf.mtextRaw"].flatMap {
                if case .string(let s) = $0 { return s }; return nil
            }
            let plainText: String? = entity.xdata["dxf.text"].flatMap {
                if case .string(let s) = $0 { return s }; return nil
            }
            let wrote = resolveTextForExport(
                formattedJSON: formattedJSON, rawMText: rawMText,
                plainText: plainText,
                position: pos, height: height, rotation: rotation,
                style: style, alignH: alignH, alignV: alignV,
                mtextWidth: mtextWidth, color: color,
                transform: entity.transform, handle: handle,
                layerName: layerName, ctx: ctx, into: &output
            )
            if !wrote {
                writePrimitive(prim, ctx: ctx, transform: entity.transform,
                               layerName: layerName, into: &output)
            }
            return
        }

        for primitive in geometry {
            writePrimitive(primitive, ctx: ctx, transform: entity.transform,
                           layerName: layerName, into: &output)
        }
    }

    // MARK: - DIMENSION Entity

    private static func writeDimension(entity: CADEntity, handle: String,
                                        layerName: String, into output: inout String) {
        guard let box = entity.dimensionMetadata else { return }
        let dim = box.value

        output += "  0\r\nDIMENSION\r\n"
        output += "  5\r\n\(handle)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n\(dxfEscape(layerName))\r\n"
        output += "100\r\nAcDbDimension\r\n"

        if entity.blockID != nil {
            output += "  2\r\n*D\(handle)\r\n"
        }
        output += "  3\r\n\(dxfEscape(dim.styleName))\r\n"
        output += " 70\r\n\(dim.type.rawValue + 32 + dim.flags)\r\n"

        let p1 = dim.defPoint
        output += " 10\r\n\(dxfDouble(p1.x))\r\n 20\r\n\(dxfDouble(-p1.y))\r\n 30\r\n\(dxfDouble(p1.z))\r\n"

        let p2 = dim.defPoint2
        output += " 13\r\n\(dxfDouble(p2.x))\r\n 23\r\n\(dxfDouble(-p2.y))\r\n 33\r\n\(dxfDouble(p2.z))\r\n"

        if let p3 = dim.defPoint3 {
            output += " 14\r\n\(dxfDouble(p3.x))\r\n 24\r\n\(dxfDouble(-p3.y))\r\n 34\r\n\(dxfDouble(p3.z))\r\n"
        }

        let tp = dim.textMidpoint
        output += " 11\r\n\(dxfDouble(tp.x))\r\n 21\r\n\(dxfDouble(-tp.y))\r\n 31\r\n\(dxfDouble(tp.z))\r\n"
        output += " 42\r\n\(dxfDouble(dim.measurement))\r\n"

        if let override = dim.textOverride {
            output += "  1\r\n\(dxfEscape(override))\r\n"
        }
        if dim.rotationAngle != 0 {
            output += " 50\r\n\(dxfDouble(-dim.rotationAngle * 180.0 / .pi))\r\n"
        }
    }

    // MARK: - INSERT Entity

    private static func writeInsert(entity: CADEntity, handle: String,
                                     blockName: String, layerName: String,
                                     into output: inout String) {
        output += "  0\r\nINSERT\r\n"
        output += "  5\r\n\(handle)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n\(dxfEscape(layerName))\r\n"
        output += "100\r\nAcDbBlockReference\r\n"
        output += "  2\r\n\(dxfEscape(blockName))\r\n"

        let pos = entity.transform.position
        output += " 10\r\n\(dxfDouble(pos.x))\r\n"
        output += " 20\r\n\(dxfDouble(-pos.y))\r\n"
        output += " 30\r\n\(dxfDouble(pos.z))\r\n"

        let scale = entity.transform.scale
        if scale.x != 1.0 { output += " 41\r\n\(dxfDouble(scale.x))\r\n" }
        if scale.y != 1.0 { output += " 42\r\n\(dxfDouble(scale.y))\r\n" }
        if scale.z != 1.0 { output += " 43\r\n\(dxfDouble(scale.z))\r\n" }

        let rotDeg = entity.transform.rotation * 180.0 / .pi
        if rotDeg != 0.0 { output += " 50\r\n\(dxfDouble(-rotDeg))\r\n" }
    }

    // MARK: - Entity header helper

    /// Writes the common entity header (handle, subclass, layer, etc.)
    /// Omits group 330 (owner) as AutoCAD 2007+ opens fine without it on entities.
    private static func writeEntityHeader(entityType: String, subclass: String,
                                           handle: String, layerName: String,
                                           into output: inout String) {
        output += "  0\r\n\(entityType)\r\n"
        output += "  5\r\n\(handle)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n\(layerName)\r\n"
        output += "  6\r\nByLayer\r\n"
        output += " 62\r\n256\r\n"
        output += "370\r\n-1\r\n"
        output += "100\r\n\(subclass)\r\n"
    }

    /// Writes the common entity header with color override.
    /// Omits group 330 (owner).
    private static func writeEntityHeaderWithColor(entityType: String, subclass: String,
                                                    handle: String, layerName: String,
                                                    color: ColorRGBA?,
                                                    into output: inout String) {
        output += "  0\r\n\(entityType)\r\n"
        output += "  5\r\n\(handle)\r\n"
        output += "100\r\nAcDbEntity\r\n"
        output += "  8\r\n\(layerName)\r\n"
        output += "  6\r\nByLayer\r\n"

        if let c = color, c.a > 0 {
            output += " 62\r\n\(rgbaToACI(c))\r\n"
            if let tc = rgbaToTrueColor(c) {
                output += "420\r\n\(tc)\r\n"
            }
        } else {
            output += " 62\r\n256\r\n"
        }

        output += "370\r\n-1\r\n"
        output += "100\r\n\(subclass)\r\n"
    }

    // MARK: - Primitive Writers

    private static func writePrimitive(_ p: CADPrimitive, ctx: ExportContext,
                                       transform: Transform3D? = nil,
                                       layerName: String = "0",
                                       into output: inout String) {
        let t = transform ?? .identity
        let layer = layerName
        let handle = ctx.nextHandle()

        let primColor: ColorRGBA?
        switch p {
        case .point(_, let c): primColor = c
        case .line(_, _, let c): primColor = c
        case .rect(_, _, let c): primColor = c
        case .fillRect(_, _, let c): primColor = c
        case .polygon(_, let c): primColor = c
        case .polyline(_, let c): primColor = c
        case .fillPolygon(_, let c): primColor = c
        case .fillComplexPolygon(_, _, let c): primColor = c
        case .gradient(_, _, _, _, _, _): primColor = nil
        case .circle(_, _, let c): primColor = c
        case .arc(_, _, _, _, let c): primColor = c
        case .spline(_, _, _, _, let c): primColor = c
        case .text(_, _, _, _, _, _, _, _, let c): primColor = c
        case .ellipse(_, _, _, let c): primColor = c
        case .hatch(_, _, _, _, let c, _): primColor = c
        case .ray(_, _, let c): primColor = c
        case .image(_, _, _, _, _, let c): primColor = c
        case .table(_, _, let c): primColor = c
        }

        // Skip fully transparent primitives
        if let c = primColor, c.a == 0 { return }

        switch p {
        case .point(let pos, _):
            let wp = t.transformPoint(pos)
            writeEntityHeaderWithColor(entityType: "POINT", subclass: "AcDbPoint",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(wp.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
            output += " 30\r\n\(dxfDouble(wp.z))\r\n"

        case .line(let start, let end, _):
            let ws = t.transformPoint(start)
            let we = t.transformPoint(end)
            writeEntityHeaderWithColor(entityType: "LINE", subclass: "AcDbLine",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(ws.x))\r\n"
            output += " 20\r\n\(dxfDouble(-ws.y))\r\n"
            output += " 30\r\n\(dxfDouble(ws.z))\r\n"
            output += " 11\r\n\(dxfDouble(we.x))\r\n"
            output += " 21\r\n\(dxfDouble(-we.y))\r\n"
            output += " 31\r\n\(dxfDouble(we.z))\r\n"

        case .rect(let origin, let size, _):
            let o = t.transformPoint(origin)
            let sx = size.x * t.scale.x
            let sy = size.y * t.scale.y

            let cx = o.x + sx * 0.5
            let cy = o.y + sy * 0.5
            let cr = cos(t.rotation)
            let sr = sin(t.rotation)

            let rverts: [(Double, Double)] = [
                (o.x, o.y),
                (o.x + sx, o.y),
                (o.x + sx, o.y + sy),
                (o.x, o.y + sy),
            ].map { (vx, vy) in
                let rx = vx - cx, ry = vy - cy
                return (cx + rx * cr - ry * sr, cy + rx * sr + ry * cr)
            }

            writeEntityHeaderWithColor(entityType: "LWPOLYLINE", subclass: "AcDbPolyline",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 90\r\n4\r\n"
            output += " 70\r\n1\r\n"
            output += " 43\r\n0.0\r\n"
            for (vx, vy) in rverts {
                output += " 10\r\n\(dxfDouble(vx))\r\n"
                output += " 20\r\n\(dxfDouble(-vy))\r\n"
            }

        case .fillRect(let origin, let size, _):
            let o = t.transformPoint(origin)
            let sx = size.x * t.scale.x
            let sy = size.y * t.scale.y

            let cx = o.x + sx * 0.5
            let cy = o.y + sy * 0.5
            let cr = cos(t.rotation)
            let sr = sin(t.rotation)

            let rverts: [(Double, Double)] = [
                (o.x, o.y),
                (o.x + sx, o.y),
                (o.x + sx, o.y + sy),
                (o.x, o.y + sy),
            ].map { (vx, vy) in
                let rx = vx - cx, ry = vy - cy
                return (cx + rx * cr - ry * sr, cy + rx * sr + ry * cr)
            }

            writeEntityHeaderWithColor(entityType: "SOLID", subclass: "AcDbTrace",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(rverts[0].0))\r\n"
            output += " 20\r\n\(dxfDouble(-rverts[0].1))\r\n"
            output += " 30\r\n0.0\r\n"
            output += " 11\r\n\(dxfDouble(rverts[1].0))\r\n"
            output += " 21\r\n\(dxfDouble(-rverts[1].1))\r\n"
            output += " 31\r\n0.0\r\n"
            output += " 12\r\n\(dxfDouble(rverts[2].0))\r\n"
            output += " 22\r\n\(dxfDouble(-rverts[2].1))\r\n"
            output += " 32\r\n0.0\r\n"
            output += " 13\r\n\(dxfDouble(rverts[3].0))\r\n"
            output += " 23\r\n\(dxfDouble(-rverts[3].1))\r\n"
            output += " 33\r\n0.0\r\n"

        case .polygon(let points, _):
            let wp = points.map { t.transformPoint($0) }
            let closed = points.count > 2
            writeEntityHeaderWithColor(entityType: "LWPOLYLINE", subclass: "AcDbPolyline",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 90\r\n\(wp.count)\r\n"
            output += " 70\r\n\(closed ? 1 : 0)\r\n"
            output += " 43\r\n0.0\r\n"
            for pt in wp {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }

        case .polyline(let path, _):
            let nonUniformScale = abs(abs(t.scale.x) - abs(t.scale.y)) > 1e-9
            let exportPath: CADPolyline
            if path.hasBulges && nonUniformScale {
                var points = path.tessellatedPoints().map { t.transformPoint($0) }
                if path.isClosed, points.count > 1 { points.removeLast() }
                exportPath = CADPolyline(
                    points: points, isClosed: path.isClosed,
                    lineTypeGenerationEnabled: path.lineTypeGenerationEnabled)
            } else {
                exportPath = path.transformed(by: t)
            }
            guard exportPath.vertices.count >= 2 else { break }

            writeEntityHeaderWithColor(entityType: "LWPOLYLINE", subclass: "AcDbPolyline",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 90\r\n\(exportPath.vertices.count)\r\n"
            let flags = (exportPath.isClosed ? 1 : 0)
                | (exportPath.lineTypeGenerationEnabled ? 128 : 0)
            output += " 70\r\n\(flags)\r\n"
            output += " 43\r\n0.0\r\n"
            for vertex in exportPath.vertices {
                output += " 10\r\n\(dxfDouble(vertex.position.x))\r\n"
                output += " 20\r\n\(dxfDouble(-vertex.position.y))\r\n"
                if vertex.startWidth != 0 {
                    output += " 40\r\n\(dxfDouble(vertex.startWidth))\r\n"
                }
                if vertex.endWidth != 0 {
                    output += " 41\r\n\(dxfDouble(vertex.endWidth))\r\n"
                }
                if vertex.bulge != 0 {
                    output += " 42\r\n\(dxfDouble(-vertex.bulge))\r\n"
                }
            }

        case .fillPolygon(let points, _):
            let wp = points.map { t.transformPoint($0) }
            guard wp.count >= 3 else { break }
            let p3 = wp[2]
            let p4 = wp.count >= 4 ? wp[3] : p3
            writeEntityHeaderWithColor(entityType: "SOLID", subclass: "AcDbTrace",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(wp[0].x))\r\n"
            output += " 20\r\n\(dxfDouble(-wp[0].y))\r\n"
            output += " 30\r\n0.0\r\n"
            output += " 11\r\n\(dxfDouble(wp[1].x))\r\n"
            output += " 21\r\n\(dxfDouble(-wp[1].y))\r\n"
            output += " 31\r\n0.0\r\n"
            output += " 12\r\n\(dxfDouble(p3.x))\r\n"
            output += " 22\r\n\(dxfDouble(-p3.y))\r\n"
            output += " 32\r\n0.0\r\n"
            output += " 13\r\n\(dxfDouble(p4.x))\r\n"
            output += " 23\r\n\(dxfDouble(-p4.y))\r\n"
            output += " 33\r\n0.0\r\n"

        case .fillComplexPolygon(let outer, let holes, _):
            let wOuter = outer.map { t.transformPoint($0) }
            guard wOuter.count >= 3 else { break }
            writeEntityHeaderWithColor(entityType: "HATCH", subclass: "AcDbHatch",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += "  2\r\nSOLID\r\n"
            output += " 70\r\n1\r\n"
            output += " 71\r\n0\r\n"
            output += " 91\r\n\(1 + holes.count)\r\n"
            output += " 92\r\n1\r\n"
            output += " 93\r\n\(wOuter.count)\r\n"
            for pt in wOuter {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }
            for hole in holes {
                let wHole = hole.map { t.transformPoint($0) }
                output += " 92\r\n0\r\n"
                output += " 93\r\n\(wHole.count)\r\n"
                for pt in wHole {
                    output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                    output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
                }
            }
            output += " 75\r\n0\r\n"
            output += " 76\r\n1\r\n"
            output += " 47\r\n1.0\r\n"
            output += " 98\r\n0\r\n"

        case .gradient(let outer, let holes, let name, let angle, let color1, let color2):
            let wOuter = outer.map { t.transformPoint($0) }
            guard wOuter.count >= 3 else { break }
            writeEntityHeaderWithColor(entityType: "HATCH", subclass: "AcDbHatch",
                                        handle: handle, layerName: layer, color: color1,
                                        into: &output)
            output += "  2\r\nSOLID\r\n"
            output += " 70\r\n1\r\n"
            output += " 71\r\n0\r\n"
            output += "450\r\n1\r\n"
            output += "452\r\n\(dxfDouble(angle * 180.0 / .pi))\r\n"
            output += "453\r\n0.0\r\n"
            output += "460\r\n0\r\n"
            output += "462\r\n0.0\r\n"
            output += "470\r\n\(name)\r\n"
            output += " 63\r\n\(rgbaToACI(color2))\r\n"
            if let tc2 = rgbaToTrueColor(color2) {
                output += "421\r\n\(tc2)\r\n"
            }
            output += " 91\r\n\(1 + holes.count)\r\n"
            output += " 92\r\n1\r\n"
            output += " 93\r\n\(wOuter.count)\r\n"
            for pt in wOuter {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }
            for hole in holes {
                let wHole = hole.map { t.transformPoint($0) }
                output += " 92\r\n0\r\n"
                output += " 93\r\n\(wHole.count)\r\n"
                for pt in wHole {
                    output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                    output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
                }
            }
            output += " 75\r\n0\r\n"
            output += " 76\r\n1\r\n"
            output += " 47\r\n1.0\r\n"
            output += " 98\r\n0\r\n"

        case .circle(let center, let radius, _):
            let wc = t.transformPoint(center)
            let scaledRadius = radius * max(t.scale.x, t.scale.y)
            writeEntityHeaderWithColor(entityType: "CIRCLE", subclass: "AcDbCircle",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(wc.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wc.y))\r\n"
            output += " 30\r\n\(dxfDouble(wc.z))\r\n"
            output += " 40\r\n\(dxfDouble(scaledRadius))\r\n"

        case .arc(let center, let radius, let startAngle, let endAngle, _):
            let wc = t.transformPoint(center)
            let scaledRadius = radius * max(t.scale.x, t.scale.y)
            writeEntityHeaderWithColor(entityType: "ARC", subclass: "AcDbArc",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(wc.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wc.y))\r\n"
            output += " 30\r\n\(dxfDouble(wc.z))\r\n"
            output += " 40\r\n\(dxfDouble(scaledRadius))\r\n"
            output += " 50\r\n\(dxfDouble(-endAngle * 180.0 / .pi))\r\n"
            output += " 51\r\n\(dxfDouble(-startAngle * 180.0 / .pi))\r\n"

        case .spline(let controlPoints, let knots, let degree, let weights, _):
            let nCtrl = controlPoints.count
            let nKnots = knots.count
            writeEntityHeaderWithColor(entityType: "SPLINE", subclass: "AcDbSpline",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 70\r\n\(degree == 3 ? 8 : 4)\r\n"
            output += " 71\r\n\(degree)\r\n"
            output += " 72\r\n\(nKnots)\r\n"
            output += " 73\r\n\(nCtrl)\r\n"
            output += " 74\r\n0\r\n"
            for k in knots {
                output += " 40\r\n\(dxfDouble(k))\r\n"
            }
            for cp in controlPoints {
                let wp = t.transformPoint(cp)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
            }
            if let w = weights {
                for weight in w {
                    output += " 41\r\n\(dxfDouble(weight))\r\n"
                }
            }

        case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, _):
            let wp = t.transformPoint(pos)
            let rotDeg = (rotation + t.rotation) * 180.0 / .pi
            let isMText = mtextWidth != nil || text.contains("\\P") || text.contains("\n")
            if isMText {
                writeEntityHeaderWithColor(entityType: "MTEXT", subclass: "AcDbMText",
                                            handle: handle, layerName: layer, color: primColor,
                                            into: &output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                if let mw = mtextWidth {
                    output += " 41\r\n\(dxfDouble(mw))\r\n"
                }
                output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if let s = style { output += "  7\r\n\(dxfEscape(s))\r\n" }
            } else {
                writeEntityHeaderWithColor(entityType: "TEXT", subclass: "AcDbText",
                                            handle: handle, layerName: layer, color: primColor,
                                            into: &output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if rotDeg != 0.0 { output += " 50\r\n\(dxfDouble(-rotDeg))\r\n" }
                if let s = style { output += "  7\r\n\(dxfEscape(s))\r\n" }
                if alignH != 0 || alignV != 0 {
                    output += " 72\r\n\(alignH)\r\n"
                    output += " 73\r\n\(alignV)\r\n"
                    output += " 11\r\n\(dxfDouble(wp.x))\r\n"
                    output += " 21\r\n\(dxfDouble(-wp.y))\r\n"
                    output += " 31\r\n\(dxfDouble(wp.z))\r\n"
                }
            }

        case .ellipse(let center, let majorAxis, let minorRatio, _):
            let wc = t.transformPoint(center)
            let majorEnd = t.transformPoint(Vector3(x: center.x + majorAxis.x, y: center.y + majorAxis.y, z: center.z))
            writeEntityHeaderWithColor(entityType: "ELLIPSE", subclass: "AcDbEllipse",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(wc.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wc.y))\r\n"
            output += " 30\r\n\(dxfDouble(wc.z))\r\n"
            output += " 11\r\n\(dxfDouble(majorEnd.x - wc.x))\r\n"
            output += " 21\r\n\(dxfDouble(-(majorEnd.y - wc.y)))\r\n"
            output += " 31\r\n\(dxfDouble(majorEnd.z - wc.z))\r\n"
            output += " 40\r\n\(dxfDouble(minorRatio))\r\n"
            output += " 41\r\n0.0\r\n"
            output += " 42\r\n\(dxfDouble(2.0 * .pi))\r\n"

        case .hatch(let boundary, let pattern, let hatchScale, let hatchAngle, _, let backgroundColor):
            let wBoundary = boundary.map { t.transformPoint($0) }
            guard wBoundary.count >= 3 else { break }
            writeEntityHeaderWithColor(entityType: "HATCH", subclass: "AcDbHatch",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            if pattern.uppercased() == "SOLID" || pattern.isEmpty {
                output += "  2\r\nSOLID\r\n"
                output += " 70\r\n1\r\n"
            } else {
                output += "  2\r\n\(pattern)\r\n"
                output += " 70\r\n0\r\n"
            }
            output += " 71\r\n0\r\n"
            output += " 91\r\n1\r\n"
            output += " 92\r\n1\r\n"
            output += " 93\r\n\(wBoundary.count)\r\n"
            for pt in wBoundary {
                output += " 10\r\n\(dxfDouble(pt.x))\r\n"
                output += " 20\r\n\(dxfDouble(-pt.y))\r\n"
            }
            output += " 75\r\n0\r\n"
            let hatchPatternType = DXFHatchGenerator.predefinedPatterns[pattern.uppercased()] == nil ? 0 : 1
            output += " 76\r\n\(hatchPatternType)\r\n"
            if hatchScale > 0 {
                output += " 41\r\n\(dxfDouble(hatchScale))\r\n"
            }
            if hatchAngle != 0 {
                output += " 52\r\n\(dxfDouble(hatchAngle * 180.0 / .pi))\r\n"
            }
            if let bg = backgroundColor {
                let rgb24 = Int32((Int32(bg.r) << 16) | (Int32(bg.g) << 8) | Int32(bg.b))
                output += " 63\r\n\(-rgb24)\r\n"
            }
            output += " 98\r\n0\r\n"

        case .ray(let start, let direction, _):
            let ws = t.transformPoint(start)
            let wd = t.transformPoint(Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z))
            writeEntityHeaderWithColor(entityType: "XLINE", subclass: "AcDbXline",
                                        handle: handle, layerName: layer, color: primColor,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(ws.x))\r\n"
            output += " 20\r\n\(dxfDouble(-ws.y))\r\n"
            output += " 30\r\n\(dxfDouble(ws.z))\r\n"
            output += " 11\r\n\(dxfDouble(wd.x))\r\n"
            output += " 21\r\n\(dxfDouble(-wd.y))\r\n"
            output += " 31\r\n\(dxfDouble(wd.z))\r\n"

        case .image:
            break
        case .table: break
        }
    }

    // MARK: - Text Export Resolution

    private static func resolveTextForExport(
        formattedJSON: String?, rawMText: String?, plainText: String?,
        position: Vector3, height: Double, rotation: Double,
        style: String?, alignH: Int, alignV: Int,
        mtextWidth: Double?, color: ColorRGBA?,
        transform: Transform3D, handle: String, layerName: String,
        ctx: ExportContext, into output: inout String
    ) -> Bool {
        let wp = transform.transformPoint(position)
        let rotDeg = (rotation + transform.rotation) * 180.0 / .pi
        let layer = layerName

        // Case 1: Raw MTEXT preserved (unedited)
        if let raw = rawMText, formattedJSON == nil, !raw.isEmpty {
            writeEntityHeaderWithColor(entityType: "MTEXT", subclass: "AcDbMText",
                                        handle: handle, layerName: layer, color: color,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(wp.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
            output += " 30\r\n\(dxfDouble(wp.z))\r\n"
            output += " 40\r\n\(dxfDouble(height))\r\n"
            if let mw = mtextWidth, mw > 0 { output += " 41\r\n\(dxfDouble(mw))\r\n" }
            output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
            output += "  1\r\n\(raw)\r\n"
            if let s = style { output += "  7\r\n\(dxfEscape(s))\r\n" }
            return true
        }

        // Case 2: Structured formatted text
        if let jsonStr = formattedJSON,
           let jsonData = jsonStr.data(using: .utf8),
           let formatted = try? JSONDecoder().decode(FormattedText.self, from: jsonData) {
            let mtextStr = MTEXTFormatter.serialize(formatted)
            writeEntityHeaderWithColor(entityType: "MTEXT", subclass: "AcDbMText",
                                        handle: handle, layerName: layer, color: color,
                                        into: &output)
            output += " 10\r\n\(dxfDouble(wp.x))\r\n"
            output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
            output += " 30\r\n\(dxfDouble(wp.z))\r\n"
            output += " 40\r\n\(dxfDouble(height))\r\n"
            if let mw = mtextWidth, mw > 0 { output += " 41\r\n\(dxfDouble(mw))\r\n" }
            output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
            output += "  1\r\n\(mtextStr)\r\n"
            if let s = style { output += "  7\r\n\(dxfEscape(s))\r\n" }
            return true
        }

        // Case 3: Plain TEXT fallback
        if let text = plainText, !text.isEmpty {
            let isMText = mtextWidth != nil || text.contains("\\P") || text.contains("\n")
            if isMText {
                writeEntityHeaderWithColor(entityType: "MTEXT", subclass: "AcDbMText",
                                            handle: handle, layerName: layer, color: color,
                                            into: &output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                if let mw = mtextWidth { output += " 41\r\n\(dxfDouble(mw))\r\n" }
                output += " 50\r\n\(dxfDouble(-rotDeg))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if let s = style { output += "  7\r\n\(dxfEscape(s))\r\n" }
            } else {
                writeEntityHeaderWithColor(entityType: "TEXT", subclass: "AcDbText",
                                            handle: handle, layerName: layer, color: color,
                                            into: &output)
                output += " 10\r\n\(dxfDouble(wp.x))\r\n"
                output += " 20\r\n\(dxfDouble(-wp.y))\r\n"
                output += " 30\r\n\(dxfDouble(wp.z))\r\n"
                output += " 40\r\n\(dxfDouble(height))\r\n"
                output += "  1\r\n\(dxfEscape(text))\r\n"
                if rotDeg != 0.0 { output += " 50\r\n\(dxfDouble(-rotDeg))\r\n" }
                if let s = style { output += "  7\r\n\(dxfEscape(s))\r\n" }
                if alignH != 0 || alignV != 0 {
                    output += " 72\r\n\(alignH)\r\n"
                    output += " 73\r\n\(alignV)\r\n"
                    output += " 11\r\n\(dxfDouble(wp.x))\r\n"
                    output += " 21\r\n\(dxfDouble(-wp.y))\r\n"
                    output += " 31\r\n\(dxfDouble(wp.z))\r\n"
                }
            }
            return true
        }

        return false
    }

    // MARK: - OBJECTS Section

    private static func writeObjects(_ ctx: ExportContext, into output: inout String) {
        output += "  0\r\nSECTION\r\n"
        output += "  2\r\nOBJECTS\r\n"

        // Main dictionary — only ACAD_GROUP (matches LibreCAD output)
        output += "  0\r\nDICTIONARY\r\n"
        output += "  5\r\n\(ExportContext.handleDictionary)\r\n"
        output += "330\r\n0\r\n"
        output += "100\r\nAcDbDictionary\r\n"
        output += "281\r\n1\r\n"
        output += "  3\r\nACAD_GROUP\r\n"
        output += "350\r\n\(ExportContext.handleAcadGroupDict)\r\n"

        // ACAD_GROUP dictionary (empty — no groups in the document)
        output += "  0\r\nDICTIONARY\r\n"
        output += "  5\r\n\(ExportContext.handleAcadGroupDict)\r\n"
        output += "330\r\n\(ExportContext.handleDictionary)\r\n"
        output += "100\r\nAcDbDictionary\r\n"
        output += "281\r\n1\r\n"

        // PLOTSETTINGS — standalone object (no owner 330, matching LibreCAD)
        output += "  0\r\nPLOTSETTINGS\r\n"
        output += "  5\r\n\(ExportContext.handlePlotSettings)\r\n"
        output += "100\r\nAcDbPlotSettings\r\n"
        output += "  6\r\n1x1\r\n"
        output += " 40\r\n0.0\r\n 41\r\n0.0\r\n 42\r\n0.0\r\n 43\r\n0.0\r\n"

        output += "  0\r\nENDSEC\r\n"
    }

    // MARK: - EOF

    private static func writeEOF(into output: inout String) {
        output += "  0\r\nEOF\r\n"
    }

    // MARK: - Helpers

    private static func dxfDouble(_ value: Double) -> String {
        let str = String(format: "%.6f", value)
        var result = str
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result.isEmpty ? "0" : result
    }

    private static func dxfEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: "")
         .replacingOccurrences(of: "\n", with: "\\P")
    }

    private static func rgbaToACI(_ color: ColorRGBA) -> Int {
        let (r, g, b) = (color.r, color.g, color.b)
        switch (r, g, b) {
        case (255, 0,   0):   return 1
        case (255, 255, 0):   return 2
        case (0,   255, 0):   return 3
        case (0,   255, 255): return 4
        case (0,   0,   255): return 5
        case (255, 0,   255): return 6
        case (255, 255, 255): return 7
        case (0,   0,   0):   return 250
        default:              return 256
        }
    }

    private static func rgbaToTrueColor(_ color: ColorRGBA) -> Int? {
        let (r, g, b) = (color.r, color.g, color.b)
        switch (r, g, b) {
        case (255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255),
             (0, 0, 255), (255, 0, 255), (255, 255, 255), (0, 0, 0):
            return nil
        default:
            return (Int(r) << 16) | (Int(g) << 8) | Int(b)
        }
    }

    private static func lineWeightToDXF(_ lw: Double) -> Int {
        if lw <= 0 { return -3 }
        return Int(lw * 100.0)
    }

    private static func opacityToDXF(_ opacity: Double) -> Int {
        let pct = Int(((1.0 - opacity) * 100.0).rounded())
        return max(0, min(90, pct))
    }
}

// =========================================================================
// MARK: - DXFExportError
// =========================================================================

public enum DXFExportError: Error {
    case writeFailed(String)
}
