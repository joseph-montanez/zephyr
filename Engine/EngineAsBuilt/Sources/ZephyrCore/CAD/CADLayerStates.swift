import Foundation

// =========================================================================
// MARK: - Layer parity Phase 4: states, filters, previous, reconcile
//
// Persistent named layer states with AutoCAD-compatible LAS import/export,
// property/group layer filters with invert, a layer-previous settings
// history (LAYERP), and reconciled-layer baseline tracking with
// notifications.
//
// Storage model:
//   - `CADDocument.layerStates` / `layerFilters` are drawing-global data,
//     snapshotted for undo/redo and persisted to EAB (`layerStates`
//     section, additive like `viewportOverrides`). LAS files carry single
//     states between drawings.
//   - `layerPreviousHistory` and `reconciledBaseline` are session state:
//     never snapshotted, never persisted. The LAYERP stack records full
//     layer-table copies before each layer mutation; the reconcile
//     baseline tracks which unreconciled layers have already been reported.
//   - `LayerTransactionService` (Phase 4 extension below) is the single
//     funnel for state save/restore, isolation (moved here from the
//     `CADDocument` prototype), previous-restore, and reconcile-all, with
//     the same exactly-one-undo plus render-only sibling propagation
//     contract as the Phase 1 service.
// =========================================================================

// =========================================================================
// MARK: - LayerStatePropertyMask
// =========================================================================

/// Which per-layer settings a `LayerState` captures and restores. Matches
/// the AutoCAD LAYERSTATE property set: visibility, frozen, lock, plot,
/// color, linetype, lineweight, transparency, and plot style, plus the
/// layer description carried by DXF group 3.
public struct LayerStatePropertyMask: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let onOff        = LayerStatePropertyMask(rawValue: 1 << 0)
    public static let frozen       = LayerStatePropertyMask(rawValue: 1 << 1)
    public static let locked       = LayerStatePropertyMask(rawValue: 1 << 2)
    public static let plottable    = LayerStatePropertyMask(rawValue: 1 << 3)
    public static let color        = LayerStatePropertyMask(rawValue: 1 << 4)
    public static let lineType     = LayerStatePropertyMask(rawValue: 1 << 5)
    public static let lineWeight   = LayerStatePropertyMask(rawValue: 1 << 6)
    public static let transparency = LayerStatePropertyMask(rawValue: 1 << 7)
    public static let plotStyle    = LayerStatePropertyMask(rawValue: 1 << 8)
    public static let description  = LayerStatePropertyMask(rawValue: 1 << 9)

    public static let all: LayerStatePropertyMask = [
        .onOff, .frozen, .locked, .plottable, .color, .lineType,
        .lineWeight, .transparency, .plotStyle, .description,
    ]
}

// =========================================================================
// MARK: - LayerStateEntry
// =========================================================================

/// The captured settings for one layer inside a `LayerState`. Keyed by
/// uppercased layer name so restores stay case-insensitive like the
/// layer table itself.
public struct LayerStateEntry: Hashable, Sendable {
    public var layerName: String
    public var isVisible: Bool
    public var isFrozen: Bool
    public var freezeInNewViewports: Bool
    public var isLocked: Bool
    public var isPlottable: Bool
    public var color: ColorRGBA
    public var colorSource: LayerColorSource
    public var lineType: String
    public var lineWeight: Double
    public var transparency: Int
    public var plotStyleName: String
    public var layerDescription: String

    public init(layer: Layer) {
        layerName = layer.name
        isVisible = layer.isVisible
        isFrozen = layer.isFrozen
        freezeInNewViewports = layer.freezeInNewViewports
        isLocked = layer.isLocked
        isPlottable = layer.isPlottable
        color = layer.color
        colorSource = layer.colorSource
        lineType = layer.lineType
        lineWeight = layer.lineWeight
        transparency = layer.transparency
        plotStyleName = layer.plotStyleName
        layerDescription = layer.layerDescription
    }

    public init(
        layerName: String,
        isVisible: Bool = true,
        isFrozen: Bool = false,
        freezeInNewViewports: Bool = false,
        isLocked: Bool = false,
        isPlottable: Bool = true,
        color: ColorRGBA = .white,
        colorSource: LayerColorSource = .default,
        lineType: String = "CONTINUOUS",
        lineWeight: Double = 0.25,
        transparency: Int = 0,
        plotStyleName: String = "Normal",
        layerDescription: String = ""
    ) {
        self.layerName = layerName
        self.isVisible = isVisible
        self.isFrozen = isFrozen
        self.freezeInNewViewports = freezeInNewViewports
        self.isLocked = isLocked
        self.isPlottable = isPlottable
        self.color = color
        self.colorSource = colorSource
        self.lineType = lineType
        self.lineWeight = Layer.nearestFixedLineWeight(lineWeight)
        self.transparency = Layer.clampedTransparency(transparency)
        self.plotStyleName = plotStyleName
        self.layerDescription = layerDescription
    }

    /// Uppercase lookup key for the entry.
    public var key: String {
        layerName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Apply the masked settings onto a live layer record.
    public func apply(to layer: inout Layer, mask: LayerStatePropertyMask) {
        if mask.contains(.onOff) { layer.isVisible = isVisible }
        if mask.contains(.frozen) {
            layer.isFrozen = isFrozen
            layer.freezeInNewViewports = freezeInNewViewports
        }
        if mask.contains(.locked) { layer.isLocked = isLocked }
        if mask.contains(.plottable) { layer.isPlottable = isPlottable }
        if mask.contains(.color) {
            layer.color = color
            layer.colorSource = colorSource
        }
        if mask.contains(.lineType) { layer.lineType = lineType }
        if mask.contains(.lineWeight) {
            layer.lineWeight = Layer.nearestFixedLineWeight(lineWeight)
        }
        if mask.contains(.transparency) {
            layer.transparency = Layer.clampedTransparency(transparency)
        }
        if mask.contains(.plotStyle) { layer.plotStyleName = plotStyleName }
        if mask.contains(.description) { layer.layerDescription = layerDescription }
    }
}

// =========================================================================
// MARK: - LayerState
// =========================================================================

/// A named snapshot of layer settings (AutoCAD LAYERSTATE equivalent).
/// `entries` is keyed by uppercased layer name. `turnOffLayersNotInState`
/// mirrors the AutoCAD restore option that turns off layers missing from
/// the state instead of leaving them alone.
public struct LayerState: Hashable, Sendable {
    public var name: String
    public var stateDescription: String
    public var mask: LayerStatePropertyMask
    public var turnOffLayersNotInState: Bool
    public var entries: [String: LayerStateEntry]

    public init(
        name: String,
        stateDescription: String = "",
        mask: LayerStatePropertyMask = .all,
        turnOffLayersNotInState: Bool = false,
        entries: [String: LayerStateEntry] = [:]
    ) {
        self.name = name
        self.stateDescription = stateDescription
        self.mask = mask
        self.turnOffLayersNotInState = turnOffLayersNotInState
        self.entries = entries
    }

    /// Capture every layer of a document under one mask.
    public static func capture(
        from document: CADDocument,
        name: String,
        stateDescription: String = "",
        mask: LayerStatePropertyMask = .all,
        turnOffLayersNotInState: Bool = false
    ) -> LayerState {
        var entries: [String: LayerStateEntry] = [:]
        for layer in document.allLayers {
            let entry = LayerStateEntry(layer: layer)
            entries[entry.key] = entry
        }
        return LayerState(
            name: name, stateDescription: stateDescription,
            mask: mask, turnOffLayersNotInState: turnOffLayersNotInState,
            entries: entries)
    }

    /// Uppercase lookup key for the state.
    public var key: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

// =========================================================================
// MARK: - LayerStateError
// =========================================================================

/// Validation / IO failure for a layer-state operation. No state changes
/// when one of these is returned: validation runs before any undo
/// snapshot is pushed.
public enum LayerStateError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownState(String)
    case duplicateName(String)
    case blankName
    case invalidValue(String)
    case parseError(String)

    public var description: String {
        switch self {
        case .unknownState(let name):
            return "Layer state '\(name)' not found."
        case .duplicateName(let name):
            return "A layer state named '\(name)' already exists."
        case .blankName:
            return "Layer state name must not be blank."
        case .invalidValue(let reason):
            return reason
        case .parseError(let reason):
            return "Could not parse layer state: \(reason)"
        }
    }
}

// =========================================================================
// MARK: - Layer filters (property / group, with invert)
// =========================================================================

/// Tri-state helper for property-filter criteria: nil means "don't care".
/// Serialized as -1/0/1 in EAB (nil/-1, false/0, true/1).
private func triStateCode(_ value: Bool?) -> Int32 {
    switch value {
    case .none: return -1
    case .some(false): return 0
    case .some(true): return 1
    }
}

private func triStateFromCode(_ code: Int32) -> Bool? {
    switch code {
    case 0: return false
    case 1: return true
    default: return nil
    }
}

/// Property criteria for a layer filter (AutoCAD property-filter
/// equivalent). Every nil criterion is ignored. `namePattern` supports
/// `*` (any run) and `?` (one character), matched case-insensitively.
public struct LayerPropertyFilter: Hashable, Sendable {
    public var namePattern: String?
    public var wantOn: Bool?
    public var wantFrozen: Bool?
    public var wantLocked: Bool?
    public var wantPlottable: Bool?
    public var aciColor: Int?
    public var lineType: String?
    public var minLineWeight: Double?
    public var maxLineWeight: Double?
    public var transparency: Int?
    public var descriptionContains: String?

    public init(
        namePattern: String? = nil,
        wantOn: Bool? = nil,
        wantFrozen: Bool? = nil,
        wantLocked: Bool? = nil,
        wantPlottable: Bool? = nil,
        aciColor: Int? = nil,
        lineType: String? = nil,
        minLineWeight: Double? = nil,
        maxLineWeight: Double? = nil,
        transparency: Int? = nil,
        descriptionContains: String? = nil
    ) {
        self.namePattern = namePattern
        self.wantOn = wantOn
        self.wantFrozen = wantFrozen
        self.wantLocked = wantLocked
        self.wantPlottable = wantPlottable
        self.aciColor = aciColor
        self.lineType = lineType
        self.minLineWeight = minLineWeight
        self.maxLineWeight = maxLineWeight
        self.transparency = transparency
        self.descriptionContains = descriptionContains
    }

    public func matches(_ layer: Layer) -> Bool {
        if let pattern = namePattern, !pattern.isEmpty,
           !LayerPropertyFilter.wildcardMatch(pattern, layer.name) { return false }
        if let wantOn, layer.isVisible != wantOn { return false }
        if let wantFrozen, layer.isFrozen != wantFrozen { return false }
        if let wantLocked, layer.isLocked != wantLocked { return false }
        if let wantPlottable, layer.isPlottable != wantPlottable { return false }
        if let aciColor, layer.colorSource.aciIndex != aciColor { return false }
        if let lineType, !lineType.isEmpty,
           layer.lineType.caseInsensitiveCompare(lineType) != .orderedSame { return false }
        if let minLineWeight, layer.lineWeight < minLineWeight - 1e-9 { return false }
        if let maxLineWeight, layer.lineWeight > maxLineWeight + 1e-9 { return false }
        if let transparency, layer.transparency != transparency { return false }
        if let fragment = descriptionContains, !fragment.isEmpty,
           layer.layerDescription.range(
               of: fragment, options: .caseInsensitive) == nil { return false }
        return true
    }

    /// Case-insensitive `*`/`?` wildcard match.
    public static func wildcardMatch(_ pattern: String, _ value: String) -> Bool {
        wildcardMatchImpl(Array(pattern.uppercased()), Array(value.uppercased()))
    }

    private static func wildcardMatchImpl(
        _ pattern: [Character], _ value: [Character]
    ) -> Bool {
        var px = 0
        var vx = 0
        var star = -1
        var starVx = 0
        while vx < value.count {
            if px < pattern.count
                && (pattern[px] == "?" || pattern[px] == value[vx]) {
                px += 1
                vx += 1
            } else if px < pattern.count && pattern[px] == "*" {
                star = px
                starVx = vx
                px += 1
            } else if star != -1 {
                px = star + 1
                starVx += 1
                vx = starVx
            } else {
                return false
            }
        }
        while px < pattern.count && pattern[px] == "*" { px += 1 }
        return px == pattern.count
    }

    // MARK: EAB field access for the additive layerStates section

    func writeFields(to w: BinaryWriter) {
        w.writeString(namePattern ?? "")
        w.writeInt32(triStateCode(wantOn))
        w.writeInt32(triStateCode(wantFrozen))
        w.writeInt32(triStateCode(wantLocked))
        w.writeInt32(triStateCode(wantPlottable))
        w.writeInt32(Int32(aciColor ?? -1))
        w.writeString(lineType ?? "")
        w.writeUInt8(minLineWeight == nil ? 0 : 1)
        w.writeFloat64(minLineWeight ?? 0)
        w.writeUInt8(maxLineWeight == nil ? 0 : 1)
        w.writeFloat64(maxLineWeight ?? 0)
        w.writeInt32(Int32(transparency ?? -1))
        w.writeString(descriptionContains ?? "")
    }

    static func readFields(from r: BinaryReader) -> LayerPropertyFilter {
        let pattern = r.readString()
        let on = triStateFromCode(r.readInt32())
        let frozen = triStateFromCode(r.readInt32())
        let locked = triStateFromCode(r.readInt32())
        let plottable = triStateFromCode(r.readInt32())
        let aci = Int(r.readInt32())
        let linetype = r.readString()
        let hasMin = r.readUInt8() != 0
        let minW = r.readFloat64()
        let hasMax = r.readUInt8() != 0
        let maxW = r.readFloat64()
        let transparency = Int(r.readInt32())
        let fragment = r.readString()
        return LayerPropertyFilter(
            namePattern: pattern.isEmpty ? nil : pattern,
            wantOn: on, wantFrozen: frozen, wantLocked: locked,
            wantPlottable: plottable,
            aciColor: aci < 0 ? nil : aci,
            lineType: linetype.isEmpty ? nil : linetype,
            minLineWeight: hasMin ? minW : nil,
            maxLineWeight: hasMax ? maxW : nil,
            transparency: transparency < 0 ? nil : transparency,
            descriptionContains: fragment.isEmpty ? nil : fragment)
    }
}

/// A named layer filter (AutoCAD LAYERFILTER equivalent). `.group` holds
/// an explicit member list of uppercased layer names; `.property` holds
/// match criteria. `inverted` mirrors the AutoCAD "Invert filter"
/// checkbox: the final result is negated.
public struct LayerFilter: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case all
        case property(LayerPropertyFilter)
        case group(members: Set<String>)
    }

    public var name: String
    public var kind: Kind
    public var inverted: Bool

    public init(
        name: String, kind: Kind = .all, inverted: Bool = false
    ) {
        self.name = name
        switch kind {
        case .group(let members):
            // Group membership is case-insensitive everywhere: store the
            // canonical uppercased keys so direct construction matches the
            // add/remove APIs.
            self.kind = .group(members: Set(members.map(Self.memberKey)))
        default:
            self.kind = kind
        }
        self.inverted = inverted
    }

    /// Uppercase lookup key for the filter.
    public var key: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Uppercase a raw member name for `.group` storage.
    public static func memberKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    public func matches(_ layer: Layer) -> Bool {
        let base: Bool
        switch kind {
        case .all:
            base = true
        case .property(let criteria):
            base = criteria.matches(layer)
        case .group(let members):
            base = members.contains(
                layer.name.trimmingCharacters(
                    in: .whitespacesAndNewlines).uppercased())
        }
        return inverted ? !base : base
    }
}

// =========================================================================
// MARK: - LayerPreviousHistory (LAYERP)
// =========================================================================

/// Bounded stack of full layer-table copies for LAYERP ("layer previous").
/// `CADDocument` pushes the pre-change table before every layer mutation;
/// restoring pops the most recent entry and applies it in one undo step.
/// Session state only: never snapshotted, never persisted.
public struct LayerPreviousHistory: Sendable {
    /// Maximum retained checkpoints (AutoCAD keeps a comparable bound).
    public static let maxDepth = 32

    public private(set) var stack: [[UUID: Layer]] = []

    public init() {}

    public var depth: Int { stack.count }
    public var isEmpty: Bool { stack.isEmpty }

    public mutating func push(_ table: [UUID: Layer]) {
        stack.append(table)
        if stack.count > Self.maxDepth {
            stack.removeFirst(stack.count - Self.maxDepth)
        }
    }

    public mutating func pop() -> [UUID: Layer]? {
        guard !stack.isEmpty else { return nil }
        return stack.removeLast()
    }

    public mutating func clear() {
        stack.removeAll()
    }
}

// =========================================================================
// MARK: - LayerStateFileCodec (LAS import/export)
// =========================================================================

/// Text import/export for single layer states (`.las`).
///
/// The framing reuses the DXF group-code vocabulary this codebase already
/// speaks for layers (2 name, 3 description, 6 linetype, 62 ACI color,
/// 70 frozen/locked state bits, 370 lineweight in hundredths of a mm,
/// 440 transparency percent, plus 290 on/off, 291
/// plottable, 391 plot-style name, 420 24-bit color, 430 color-book name,
/// 90/91 header option words). Per-layer values therefore carry the same
/// data AutoCAD stores in a layer state; unknown codes are skipped on
/// import so variant framings do not fail the whole file.
///
/// Byte-for-byte fidelity with Autodesk's proprietary LAS framing was not
/// verified against a reference file: treat this codec as data-model
/// compatible (same settings, same mask semantics), not as a clone of
/// Autodesk's exact bytes.
public enum LayerStateFileCodec {
    private static let headerMarker = "ZEPHYR_LAYERSTATE_V1"
    private static let layerMarker = "LAYER"
    private static let endMarker = "END"
    private static let formatVersion = 1

    // MARK: Export

    public static func export(_ state: LayerState) -> String {
        var lines: [String] = []
        func pair(_ code: Int, _ value: String) {
            lines.append(String(code))
            lines.append(value)
        }
        pair(0, headerMarker)
        pair(1, state.name)
        pair(3, state.stateDescription)
        pair(91, String(state.mask.rawValue))
        pair(90, state.turnOffLayersNotInState ? "1" : "0")
        pair(70, String(formatVersion))
        for entry in state.entries.values.sorted(by: { $0.key < $1.key }) {
            pair(0, layerMarker)
            pair(2, entry.layerName)
            pair(290, entry.isVisible ? "1" : "0")
            var bits = 0
            if entry.isFrozen { bits |= LayerDXFFlagBits.frozen }
            if entry.freezeInNewViewports { bits |= LayerDXFFlagBits.freezeInNewViewports }
            if entry.isLocked { bits |= LayerDXFFlagBits.locked }
            pair(70, String(bits))
            pair(291, entry.isPlottable ? "1" : "0")
            switch entry.colorSource {
            case .aci(let index):
                pair(62, String(index))
                pair(420, "0")
                pair(430, "")
            case .trueColor:
                pair(62, "0")
                pair(420, String(
                    (Int(entry.color.r) << 16)
                        | (Int(entry.color.g) << 8)
                        | Int(entry.color.b)))
                pair(430, "")
            case .colorBook(let bookName):
                pair(62, "0")
                pair(420, "0")
                pair(430, bookName)
            }
            pair(6, entry.lineType)
            pair(370, String(Int((entry.lineWeight * 100.0).rounded())))
            pair(440, String(entry.transparency))
            pair(391, entry.plotStyleName)
            pair(3, entry.layerDescription)
        }
        pair(0, endMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Import

    public static func `import`(from text: String) throws -> LayerState {
        let rawLines = text.components(separatedBy: .newlines)
        // Keep empty value lines (codes always pair with a value line);
        // drop a single trailing empty line from the final newline.
        var lines = rawLines
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.count >= 2,
              lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "0",
              lines[1].trimmingCharacters(in: .whitespacesAndNewlines) == headerMarker
        else {
            throw LayerStateError.parseError("missing \(headerMarker) header")
        }
        var index = 2
        var name: String?
        var stateDescription = ""
        var mask = LayerStatePropertyMask.all
        var turnOffMissing = false
        var entries: [String: LayerStateEntry] = [:]

        func nextPair() throws -> (code: String, value: String) {
            guard index + 1 < lines.count else {
                throw LayerStateError.parseError("truncated group-code pair")
            }
            let code = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            index += 2
            return (code, value)
        }

        while index < lines.count {
            let (code, value) = try nextPair()
            // Skip non-marker pairs (unknown variant codes) instead of
            // failing the whole file; truncation still throws in nextPair.
            if code != "0" { continue }
            if value == endMarker { break }
            if value == layerMarker {
                let entry = try parseEntry(lines: lines, index: &index)
                entries[entry.key] = entry
                continue
            }
            // Unknown section marker: skip (forward compatibility).
            continue
        }
        // Header fields arrive as code/value pairs before the first LAYER.
        // Re-scan the header region for them.
        var headerPairs: [(String, String)] = []
        var scan = 2
        while scan + 1 < lines.count {
            let code = lines[scan].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = lines[scan + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if code == "0" { break }
            headerPairs.append((code, value))
            scan += 2
        }
        for (code, value) in headerPairs {
            switch code {
            case "1": name = value
            case "3": stateDescription = value
            case "91":
                if let bits = UInt32(value) { mask = LayerStatePropertyMask(rawValue: bits) }
            case "90": turnOffMissing = value == "1"
            default: break // tolerate variant header codes
            }
        }
        guard let stateName = name,
              !stateName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LayerStateError.parseError("missing state name (code 1)")
        }
        return LayerState(
            name: stateName, stateDescription: stateDescription,
            mask: mask, turnOffLayersNotInState: turnOffMissing,
            entries: entries)
    }

    private static func parseEntry(
        lines: [String], index: inout Int
    ) throws -> LayerStateEntry {
        var name = ""
        var isVisible = true
        var bits = 0
        var plottable = true
        var aci = 7
        var hasACI = false
        var rgb = 0
        var bookName = ""
        var lineType = "CONTINUOUS"
        var weightHundredths = 25
        var transparency = 0
        var plotStyle = "Normal"
        var layerDescription = ""
        while index + 1 < lines.count {
            let code = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if code == "0" { break } // next marker or END; do not consume
            index += 2
            switch code {
            case "2": name = value
            case "290": isVisible = value != "0"
            case "70": bits = Int(value) ?? 0
            case "291": plottable = value != "0"
            case "62":
                if let parsed = Int(value), parsed != 0 {
                    aci = abs(parsed)
                    hasACI = true
                }
            case "420": rgb = Int(value) ?? 0
            case "430": bookName = value
            case "6": if !value.isEmpty { lineType = value }
            case "370": weightHundredths = Int(value) ?? weightHundredths
            case "440": transparency = Layer.clampedTransparency(Int(value) ?? 0)
            case "391": if !value.isEmpty { plotStyle = value }
            case "3": layerDescription = value
            default: break // tolerate variant per-layer codes
            }
        }
        let color: ColorRGBA
        let source: LayerColorSource
        if !bookName.isEmpty {
            source = .colorBook(name: bookName)
            color = DXFColorTable.aciToRGBA(7, color24: -1)
        } else if !hasACI && rgb != 0 {
            source = .trueColor
            color = ColorRGBA(
                r: UInt8((rgb >> 16) & 0xFF),
                g: UInt8((rgb >> 8) & 0xFF),
                b: UInt8(rgb & 0xFF))
        } else {
            let clamped = max(1, min(255, aci))
            source = .aci(clamped)
            color = DXFColorTable.aciToRGBA(Int32(clamped), color24: -1)
        }
        return LayerStateEntry(
            layerName: name,
            isVisible: isVisible,
            isFrozen: (bits & LayerDXFFlagBits.frozen) != 0,
            freezeInNewViewports: (bits & LayerDXFFlagBits.freezeInNewViewports) != 0,
            isLocked: (bits & LayerDXFFlagBits.locked) != 0,
            isPlottable: plottable,
            color: color,
            colorSource: source,
            lineType: lineType,
            lineWeight: Double(weightHundredths) / 100.0,
            transparency: transparency,
            plotStyleName: plotStyle,
            layerDescription: layerDescription)
    }
}

// =========================================================================
// MARK: - LayerTransactionService Phase 4: states, filters, isolation
//
// The Phase 1 service contract extended: validate first, checkpoint the
// LAYERP history, push exactly one undo on the primary document, and
// propagate render-only to siblings via `adoptLayers`. Isolation
// (LAYISO/LAYUNISO/`-LAYER` visibility) moved here from the
// `CADDocument` prototype so all layer mutations share one funnel.
// =========================================================================

public extension LayerTransactionService {
    // MARK: Layer states

    /// Restore options overriding the stored state flags for one restore.
    struct LayerStateRestoreOptions: Equatable, Sendable {
        public var maskOverride: LayerStatePropertyMask?
        public var turnOffMissing: Bool?

        public init(
            maskOverride: LayerStatePropertyMask? = nil,
            turnOffMissing: Bool? = nil
        ) {
            self.maskOverride = maskOverride
            self.turnOffMissing = turnOffMissing
        }
    }

    /// Outcome of a state restore: layers updated, layers turned off by
    /// the missing-layer option, and state entries with no live layer.
    struct LayerStateRestoreReport: Equatable, Sendable {
        public let applied: Int
        public let turnedOff: Int
        public let missing: Int
    }

    /// Uppercase lookup key shared by states and filters.
    static func settingsKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func state(
        in primary: CADDocument, named name: String
    ) -> LayerState? {
        primary.layerStates[Self.settingsKey(name)]
    }

    /// Capture the current table as a named state (one undo step).
    func saveLayerState(
        in primary: CADDocument,
        name: String,
        stateDescription: String = "",
        mask: LayerStatePropertyMask = .all,
        turnOffLayersNotInState: Bool = false
    ) -> Result<LayerState, LayerStateError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankName) }
        let key = Self.settingsKey(trimmed)
        guard primary.layerStates[key] == nil else {
            return .failure(.duplicateName(trimmed))
        }
        let state = LayerState.capture(
            from: primary, name: trimmed,
            stateDescription: stateDescription, mask: mask,
            turnOffLayersNotInState: turnOffLayersNotInState)
        primary.pushUndo()
        primary.layerStates[key] = state
        primary.markEdited(regenerate: true)
        return .success(state)
    }

    /// Restore a named state onto the live table (one undo step).
    /// Unknown state names fail with no state change. State entries
    /// without a live layer are counted as missing and ignored.
    func restoreLayerState(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        named name: String,
        options: LayerStateRestoreOptions = LayerStateRestoreOptions()
    ) -> Result<LayerStateRestoreReport, LayerStateError> {
        guard let stored = state(in: primary, named: name) else {
            return .failure(.unknownState(name))
        }
        let mask = options.maskOverride ?? stored.mask
        let turnOff = options.turnOffMissing ?? stored.turnOffLayersNotInState
        primary.checkpointLayerPrevious()
        primary.pushUndo()
        var table = Dictionary(
            uniqueKeysWithValues: primary.allLayers.map { ($0.handle, $0) })
        let byName = Dictionary(
            table.values.map { (Self.settingsKey($0.name), $0.handle) },
            uniquingKeysWith: { first, _ in first })
        var applied = 0
        var missing = 0
        for entry in stored.entries.values {
            guard let handle = byName[entry.key],
                  var layer = table[handle] else {
                missing += 1
                continue
            }
            entry.apply(to: &layer, mask: mask)
            table[handle] = layer
            applied += 1
        }
        var turnedOff = 0
        if turnOff {
            let known = Set(stored.entries.keys)
            for (handle, var layer) in table
                where !known.contains(Self.settingsKey(layer.name))
                    && layer.isVisible {
                layer.isVisible = false
                table[handle] = layer
                turnedOff += 1
            }
        }
        primary.storeLayerTable(table)
        propagateLayers(from: primary, to: siblings)
        return .success(LayerStateRestoreReport(
            applied: applied, turnedOff: turnedOff, missing: missing))
    }

    /// Delete a named state (one undo step).
    func deleteLayerState(
        in primary: CADDocument, named name: String
    ) -> Result<Void, LayerStateError> {
        let key = Self.settingsKey(name)
        guard primary.layerStates[key] != nil else {
            return .failure(.unknownState(name))
        }
        primary.pushUndo()
        primary.layerStates.removeValue(forKey: key)
        primary.markEdited(regenerate: false)
        return .success(())
    }

    /// Rename a state, keeping its entries (one undo step).
    func renameLayerState(
        in primary: CADDocument, from oldName: String, to newName: String
    ) -> Result<LayerState, LayerStateError> {
        let oldKey = Self.settingsKey(oldName)
        guard var stored = primary.layerStates[oldKey] else {
            return .failure(.unknownState(oldName))
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankName) }
        let newKey = Self.settingsKey(trimmed)
        if newKey != oldKey, primary.layerStates[newKey] != nil {
            return .failure(.duplicateName(trimmed))
        }
        primary.pushUndo()
        primary.layerStates.removeValue(forKey: oldKey)
        stored.name = trimmed
        primary.layerStates[newKey] = stored
        primary.markEdited(regenerate: false)
        return .success(stored)
    }

    /// Sorted state names for UI / LIST output.
    func layerStateNames(in primary: CADDocument) -> [String] {
        primary.layerStates.values.map(\.name).sorted {
            $0.caseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Export a named state to LAS text. Read-only: no undo, no edits.
    func exportLayerState(
        in primary: CADDocument, named name: String
    ) -> Result<String, LayerStateError> {
        guard let stored = state(in: primary, named: name) else {
            return .failure(.unknownState(name))
        }
        return .success(LayerStateFileCodec.export(stored))
    }

    /// Import LAS text as a stored state (one undo step on success).
    /// A state with the imported name must not already exist unless
    /// `overwrite` is set.
    func importLayerState(
        in primary: CADDocument,
        from text: String,
        overwrite: Bool = false
    ) -> Result<LayerState, LayerStateError> {
        let parsed: LayerState
        do {
            parsed = try LayerStateFileCodec.import(from: text)
        } catch let error as LayerStateError {
            return .failure(error)
        } catch {
            return .failure(.parseError(error.localizedDescription))
        }
        let key = parsed.key
        guard !key.isEmpty else { return .failure(.blankName) }
        if primary.layerStates[key] != nil, !overwrite {
            return .failure(.duplicateName(parsed.name))
        }
        primary.pushUndo()
        primary.layerStates[key] = parsed
        primary.markEdited(regenerate: false)
        return .success(parsed)
    }

    // MARK: Filters

    private func filter(
        in primary: CADDocument, named name: String
    ) -> LayerFilter? {
        primary.layerFilters[Self.settingsKey(name)]
    }

    /// Store a named filter (one undo step). Blank names and duplicates fail.
    func saveFilter(
        in primary: CADDocument, filter: LayerFilter
    ) -> Result<LayerFilter, LayerStateError> {
        let trimmed = filter.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.blankName) }
        let key = Self.settingsKey(trimmed)
        guard primary.layerFilters[key] == nil else {
            return .failure(.duplicateName(trimmed))
        }
        var stored = filter
        stored.name = trimmed
        primary.pushUndo()
        primary.layerFilters[key] = stored
        primary.markEdited(regenerate: false)
        return .success(stored)
    }

    /// Replace a stored filter's kind/invert flags (one undo step).
    func updateFilter(
        in primary: CADDocument, named name: String, kind: LayerFilter.Kind,
        inverted: Bool
    ) -> Result<LayerFilter, LayerStateError> {
        let key = Self.settingsKey(name)
        guard var stored = primary.layerFilters[key] else {
            return .failure(.unknownState(name))
        }
        primary.pushUndo()
        switch kind {
        case .group(let members):
            stored.kind = .group(members: Set(members.map(LayerFilter.memberKey)))
        default:
            stored.kind = kind
        }
        stored.inverted = inverted
        primary.layerFilters[key] = stored
        primary.markEdited(regenerate: false)
        return .success(stored)
    }

    /// Delete a named filter (one undo step).
    func deleteFilter(
        in primary: CADDocument, named name: String
    ) -> Result<Void, LayerStateError> {
        let key = Self.settingsKey(name)
        guard primary.layerFilters[key] != nil else {
            return .failure(.unknownState(name))
        }
        primary.pushUndo()
        primary.layerFilters.removeValue(forKey: key)
        primary.markEdited(regenerate: false)
        return .success(())
    }

    /// Sorted filter names for UI / LIST output.
    func filterNames(in primary: CADDocument) -> [String] {
        primary.layerFilters.values.map(\.name).sorted {
            $0.caseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Add layer names to a group filter (one undo step, case-insensitive).
    /// Returns the member count after the change.
    func addLayersToGroupFilter(
        in primary: CADDocument, filter name: String, layers: [String]
    ) -> Result<Int, LayerStateError> {
        let key = Self.settingsKey(name)
        guard var stored = primary.layerFilters[key] else {
            return .failure(.unknownState(name))
        }
        guard case .group(var members) = stored.kind else {
            return .failure(.invalidValue(
                "Filter '\(stored.name)' is not a group filter."))
        }
        primary.pushUndo()
        for layer in layers {
            members.insert(LayerFilter.memberKey(layer))
        }
        stored.kind = .group(members: members)
        primary.layerFilters[key] = stored
        primary.markEdited(regenerate: false)
        return .success(members.count)
    }

    /// Remove layer names from a group filter (one undo step).
    func removeLayersFromGroupFilter(
        in primary: CADDocument, filter name: String, layers: [String]
    ) -> Result<Int, LayerStateError> {
        let key = Self.settingsKey(name)
        guard var stored = primary.layerFilters[key] else {
            return .failure(.unknownState(name))
        }
        guard case .group(var members) = stored.kind else {
            return .failure(.invalidValue(
                "Filter '\(stored.name)' is not a group filter."))
        }
        primary.pushUndo()
        for layer in layers {
            members.remove(LayerFilter.memberKey(layer))
        }
        stored.kind = .group(members: members)
        primary.layerFilters[key] = stored
        primary.markEdited(regenerate: false)
        return .success(members.count)
    }

    /// Layers of a document passing a named filter. Read-only.
    func layers(
        in primary: CADDocument, matching name: String
    ) -> Result<[Layer], LayerStateError> {
        guard let stored = filter(in: primary, named: name) else {
            return .failure(.unknownState(name))
        }
        return .success(primary.allLayers.filter { stored.matches($0) })
    }

    // MARK: Isolation (moved from the CADDocument prototype)

    /// Set visibility on many layers in exactly one undo step, with
    /// LAYERP checkpoint and sibling propagation.
    func setLayersVisible(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        handles: [UUID],
        visible: Bool
    ) {
        primary.checkpointLayerPrevious()
        primary.pushUndo()
        var table = Dictionary(
            uniqueKeysWithValues: primary.allLayers.map { ($0.handle, $0) })
        for handle in handles where table[handle] != nil {
            table[handle]!.isVisible = visible
        }
        primary.storeLayerTable(table)
        propagateLayers(from: primary, to: siblings)
    }

    /// Isolate: kept layers are forced visible; every other layer is
    /// hidden (or faded to 0.3 opacity when `layisoFadeOthers`). Pushes
    /// the prior table for LAYUNISO plus a LAYERP checkpoint. One undo.
    func isolateLayers(
        in primary: CADDocument,
        siblings: [CADDocument] = [],
        keeping: Set<UUID>
    ) {
        primary.checkpointLayerPrevious()
        primary.pushUndo()
        var table = Dictionary(
            uniqueKeysWithValues: primary.allLayers.map { ($0.handle, $0) })
        var saved: [UUID: Layer] = [:]
        for (handle, var layer) in table {
            saved[handle] = layer
            if keeping.contains(handle) {
                layer.isVisible = true
            } else if primary.layisoFadeOthers {
                layer.opacity = 0.3
            } else {
                layer.isVisible = false
            }
            table[handle] = layer
        }
        primary.layerIsolationStack.append(saved)
        primary.storeLayerTable(table)
        propagateLayers(from: primary, to: siblings)
    }

    /// Restore the most recent isolation. False (and no undo) when empty.
    @discardableResult
    func unisolateLayers(
        in primary: CADDocument,
        siblings: [CADDocument] = []
    ) -> Bool {
        guard let saved = primary.layerIsolationStack.popLast() else {
            return false
        }
        primary.checkpointLayerPrevious()
        primary.pushUndo()
        var table = Dictionary(
            uniqueKeysWithValues: primary.allLayers.map { ($0.handle, $0) })
        for (handle, layer) in saved where table[handle] != nil {
            table[handle] = layer
        }
        primary.storeLayerTable(table)
        propagateLayers(from: primary, to: siblings)
        return true
    }

    // MARK: Layer previous (LAYERP)

    /// Restore the most recent LAYERP checkpoint in one undo step.
    /// False (and no undo) when the stack is empty.
    @discardableResult
    func restoreLayerPrevious(
        in primary: CADDocument,
        siblings: [CADDocument] = []
    ) -> Bool {
        guard let table = primary.layerPreviousHistory.pop() else {
            return false
        }
        primary.pushUndo()
        // Drop handles deleted since the checkpoint; keep layers added
        // since (AutoCAD LAYERP never deletes layers).
        var current = Dictionary(
            uniqueKeysWithValues: primary.allLayers.map { ($0.handle, $0) })
        for (handle, layer) in table where current[handle] != nil {
            current[handle] = layer
        }
        primary.storeLayerTable(current)
        propagateLayers(from: primary, to: siblings)
        return true
    }

    // MARK: Reconciled layers

    /// Mark every layer reconciled in one undo step and refresh the
    /// notification baseline. Returns the reconciled count.
    @discardableResult
    func reconcileAllLayers(
        in primary: CADDocument,
        siblings: [CADDocument] = []
    ) -> Int {
        primary.checkpointLayerPrevious()
        primary.pushUndo()
        var table = Dictionary(
            uniqueKeysWithValues: primary.allLayers.map { ($0.handle, $0) })
        var count = 0
        for (handle, var layer) in table where !layer.isReconciled {
            layer.isReconciled = true
            table[handle] = layer
            count += 1
        }
        primary.storeLayerTable(table)
        _ = primary.updateReconcileBaseline()
        propagateLayers(from: primary, to: siblings)
        return count
    }

    // MARK: Shared propagation

    /// Render-only sibling propagation reused from the Phase 1 contract:
    /// no undo, no dirty flag on siblings.
    private func propagateLayers(
        from primary: CADDocument, to siblings: [CADDocument]
    ) {
        for sibling in siblings where sibling !== primary {
            _ = sibling.adoptLayers(from: primary)
        }
    }
}
