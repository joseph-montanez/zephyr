import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Lisp System Variable Store (getvar/setvar)
// =========================================================================
//
// Three variable kinds:
//
// * LIVE reads reflect the drawing/command state on every getvar (CLAYER,
//   UNDOCTL, CMDNAMES). CLAYER is also live on write (switches the active
//   layer, erroring on unknown names like AutoCAD).
// * READONLY variables reject setvar (ACADVER, DATE, UNDOCTL, ...).
// * MEMORY variables persist per host instance with AutoCAD-compatible
//   defaults and light validation (ranges, known names).
//
// The store is a reference type owned by the CAD host. UNISOLATED by
// design (see LispCADHost): the memory dict serializes on a lock, live
// reads consult the document directly, and CMDNAMES arrives as a snapshot
// string because the processor is MainActor-bound. Values cross threads
// as LispValue.

final class LispVarStore: @unchecked Sendable {
    private let lock = NSLock()
    private var memory: [String: LispValue] = LispVarStore.defaults

    // MARK: - Defaults

    private static let defaults: [String: LispValue] = [
        "ACADVER": .string("24.0 (Zephyr)"),
        "ANGBASE": .real(0),
        "ANGDIR": .int(0),
        "APERTURE": .int(10),
        "AUNITS": .int(0),
        "AUPREC": .int(0),
        "AUTOCONTRAST": .int(1),
        "BLIPMODE": .int(0),
        "CECOLOR": .string("BYLAYER"),
        "CELTSCALE": .real(1),
        "CELTYPE": .string("BYLAYER"),
        "CHAMFERA": .real(0),
        "CHAMFERB": .real(0),
        "CMDECHO": .int(1),
        "CURSORSIZE": .int(5),
        "DATE": .real(2460600.5),
        "DIMSCALE": .real(1),
        "DWGNAME": .string("Drawing1.dxf"),
        "DWGPREFIX": .string(""),
        "DWGTITLED": .int(0),
        "ERRNO": .int(0),
        "EXPERT": .int(0),
        "EXTMAX": LispEntityAdapter.lispList([.real(1e12), .real(1e12), .real(0)]),
        "EXTMIN": LispEntityAdapter.lispList([.real(-1e12), .real(-1e12), .real(0)]),
        "FILEDIA": .int(1),
        "FILLETRAD": .real(0),
        "FILLMODE": .int(1),
        "GFANG": .real(0),
        "GFCLR1": .string(""),
        "GFCLR2": .string(""),
        "GFCLRLUM": .real(1),
        "GFCLRSTATE": .int(0),
        "GFNAME": .int(0),
        "GFSHIFT": .real(0),
        "GRIDMODE": .int(0),
        "HIGHLIGHT": .int(1),
        "HPANG": .real(0),
        "HPNAME": .string("SOLID"),
        "HPSCALE": .real(1),
        "INSUNITS": .int(0),
        "LASTANGLE": .real(0),
        "LOGINNAME": .string("zephyr"),
        "LTSCALE": .real(1),
        "LUNITS": .int(2),
        "LUPREC": .int(4),
        "LWDISPLAY": .int(0),
        "MEASUREMENT": .int(1),
        "MENUECHO": .int(0),
        "MIRRTEXT": .int(1),
        "NOMUTT": .int(0),
        "OFFSETDIST": .real(-1),
        "OFFSETGAPTYPE": .int(0),
        "ORTHOMODE": .int(0),
        "POLARMODE": .int(0),
        "OSMODE": .int(0),
        "PDMODE": .int(0),
        "PDSIZE": .real(0),
        "PICKADD": .int(1),
        "PICKAUTO": .int(1),
        "PICKBOX": .int(3),
        "PICKDRAG": .int(0),
        "PICKFIRST": .int(1),
        "PLATFORM": .string("Zephyr"),
        "QTEXTMODE": .int(0),
        "REGENMODE": .int(1),
        "SKETCHINC": .real(0.1),
        "SNAPMODE": .int(0),
        "SPLINESEGS": .int(8),
        "TEXTSTYLE": .string("Standard"),
        "BINDTYPE": .int(0),
        "REFPATHTYPE": .int(1),
        "VISRETAIN": .int(1),
        "XDWGFADECTL": .int(50),
        "XLOADCTL": .int(2),
        "XREFNOTIFY": .int(1),
    ]

    private static let readOnly: Set<String> = [
        "ACADVER", "AREA", "CMDNAMES", "DATE", "DWGNAME", "DWGPREFIX", "DWGTITLED",
        "ERRNO", "EXTMAX", "EXTMIN", "LASTANGLE", "LOGINNAME", "MILLISECS",
        "PERIMETER", "PLATFORM", "UNDOCTL", "VERSION",
    ]

    // MARK: - Access

    /// Reads a variable. Live variables consult the document directly;
    /// CMDNAMES arrives pre-snapshotted (the processor is MainActor-bound).
    /// Everything else comes from memory. Returns nil for unknown names.
    func get(
        _ name: String, document: CADDocument, activeCommand: String?
    ) -> LispValue? {
        switch name {
        case "AUTOCONTRAST":
            return .int(document.autoContrastTrueColor ? 1 : 0)
        case "LTSCALE":
            return .real(document.globalLineTypeScale)
        case "CLAYER":
            guard let id = document.activeLayerID,
                  let layer = document.layer(for: id)
            else { return .string("0") }
            return .string(layer.name)
        case "UNDOCTL":
            return .int(document.undoManager.undoControlFlags)
        case "CMDNAMES":
            // Feature commands carry no registry name; legacy commands do.
            return .string(activeCommand ?? "")
        case "MILLISECS":
            return .int(Int(Date().timeIntervalSince1970 * 1000))
        case "OFFSETDIST":
            // Live: shared with the OFFSET command (-1 = Through default).
            return .real(OffsetSettings.lastDistance ?? -1)
        case "OFFSETGAPTYPE":
            return .int(OffsetSettings.gapType.rawValue)
        case "LASTPOINT":
            if let p = document.lastPoint {
                return LispEntityAdapter.pointValue(p)
            }
            return lock.withLock { memory["LASTPOINT"] ?? .nilValue }
        case "AREA":
            return .real(document.lastArea)
        case "PERIMETER":
            return .real(document.lastPerimeter)
        case "LUPREC":
            return .int(document.lengthPrecision)
        case "AUPREC":
            return .int(document.anglePrecision)
        case "BINDTYPE":
            return .int(XrefSysvars.bindType)
        case "REFPATHTYPE":
            return .int(XrefSysvars.refPathType)
        case "VISRETAIN":
            return .int(XrefSysvars.visRetain)
        case "XDWGFADECTL":
            return .int(document.xrefFadePercent)
        case "XLOADCTL":
            return .int(XrefSysvars.xloadCtl)
        case "XREFNOTIFY":
            return .int(XrefSysvars.xrefNotify)
        default:
            return lock.withLock { memory[name] }
        }
    }

    /// Writes a variable. Returns an error message for rejected writes
    /// (unknown name, read-only, validation failure), nil on success.
    /// Unknown names are rejected by the caller (setvar checks get first).
    func set(_ name: String, _ value: LispValue, document: CADDocument) -> String? {
        if Self.readOnly.contains(name) {
            return "cannot modify read-only system variable: \(name)"
        }
        switch name {
        case "AUTOCONTRAST":
            let intVal: Int?
            switch value {
            case .int(let i): intVal = i
            case .real(let r): intVal = Int(r)
            default: intVal = nil
            }
            guard let intVal, (0...1).contains(intVal) else {
                return "AUTOCONTRAST requires 0 or 1"
            }
            document.autoContrastTrueColor = (intVal != 0)
            document.markNeedsRegeneration()
            store(name, value)
            return nil
        case "LTSCALE":
            let realVal: Double?
            switch value {
            case .real(let r): realVal = r
            case .int(let i): realVal = Double(i)
            default: realVal = nil
            }
            guard let realVal, realVal > 0, realVal.isFinite else {
                return "LTSCALE requires a positive non-zero real number"
            }
            document.globalLineTypeScale = realVal
            document.markNeedsRegeneration()
            store(name, value)
            return nil
        case "CLAYER":
            guard case let .string(layerName) = value else {
                return "CLAYER requires a layer name string"
            }
            guard let layer = document.findLayer(named: layerName) else {
                return "unknown layer \"\(layerName)\""
            }
            document.activeLayerID = layer.handle
            return nil
        case "CECOLOR":
            switch value {
            case .string(let s) where ["BYLAYER", "BYBLOCK"].contains(s.uppercased()):
                store(name, .string(s.uppercased()))
                return nil
            case .int(let i) where (1...256).contains(i):
                store(name, value)
                return nil
            default:
                return "CECOLOR requires BYLAYER, BYBLOCK, or ACI 1..256"
            }
        case "LUNITS":
            guard case let .int(i) = value, (1...5).contains(i) else {
                return "LUNITS requires an integer 1..5"
            }
            store(name, value)
            return nil
        case "LUPREC":
            guard case let .int(i) = value, (0...8).contains(i) else {
                return "LUPREC requires an integer 0..8"
            }
            document.lengthPrecision = i
            store(name, value)
            return nil
        case "AUPREC":
            guard case let .int(i) = value, (0...8).contains(i) else {
                return "AUPREC requires an integer 0..8"
            }
            document.anglePrecision = i
            store(name, value)
            return nil
        case "AUNITS":
            guard case let .int(i) = value, (0...4).contains(i) else {
                return "AUNITS requires an integer 0..4"
            }
            store(name, value)
            return nil
        case "OFFSETDIST":
            let numeric: Double?
            switch value {
            case .real(let r): numeric = r
            case .int(let i): numeric = Double(i)
            default: numeric = nil
            }
            guard let numeric, numeric != 0, numeric.isFinite else {
                return "OFFSETDIST requires a positive real, or -1 for Through"
            }
            OffsetSettings.lastDistance = numeric > 0 ? numeric : nil
            return nil
        case "OFFSETGAPTYPE":
            guard case let .int(i) = value, let gapType = OffsetGapType(rawValue: i) else {
                return "OFFSETGAPTYPE requires an integer 0..2"
            }
            OffsetSettings.gapType = gapType
            return nil
        case "BINDTYPE", "REFPATHTYPE", "VISRETAIN", "XREFNOTIFY", "XLOADCTL", "XDWGFADECTL":
            let intValue: Int?
            switch value {
            case .int(let i): intValue = i
            case .real(let r): intValue = Int(r)
            default: intValue = nil
            }
            guard let intValue else { return "\(name) requires an integer value" }
            switch name {
            case "BINDTYPE":
                guard (0...1).contains(intValue) else { return "BINDTYPE requires 0 or 1" }
                XrefSysvars.bindType = intValue
            case "REFPATHTYPE":
                guard (0...2).contains(intValue) else { return "REFPATHTYPE requires 0, 1, or 2" }
                XrefSysvars.refPathType = intValue
            case "VISRETAIN":
                guard (0...1).contains(intValue) else { return "VISRETAIN requires 0 or 1" }
                XrefSysvars.visRetain = intValue
            case "XREFNOTIFY":
                guard (0...1).contains(intValue) else { return "XREFNOTIFY requires 0 or 1" }
                XrefSysvars.xrefNotify = intValue
            case "XLOADCTL":
                guard (0...2).contains(intValue) else { return "XLOADCTL requires 0, 1, or 2" }
                XrefSysvars.xloadCtl = intValue
            default:  // XDWGFADECTL
                guard (0...90).contains(intValue) else { return "XDWGFADECTL requires 0..90" }
                document.xrefFadePercent = intValue
                document.markNeedsRegeneration()
                XrefSysvars.fadePercent = intValue
            }
            return nil
        case "TEXTSTYLE":
            guard case let .string(style) = value else {
                return "TEXTSTYLE requires a style name string"
            }
            guard document.textStyles[style] != nil else {
                return "unknown text style \"\(style)\""
            }
            store(name, value)
            return nil
        default:
            let known = lock.withLock { memory[name] != nil } || name == "LASTPOINT"
            guard known else { return nil } // Caller rejects unknown names.
            store(name, value)
            return nil
        }
    }

    private func store(_ name: String, _ value: LispValue) {
        lock.withLock { memory[name] = value }
    }
}
