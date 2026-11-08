import Foundation

// =========================================================================
// MARK: - WindowSlotID
//
// Stable identity for one OS window's paneling information. The main window
// is always `.main`; auxiliary (float) windows occupy `.float(1...N)` in
// creation order, bounded by `PhrostEngine.maxFloatWindows`.
//
// SDL window IDs are runtime-ephemeral and tab IDs follow documents, so
// neither is suitable: a slot survives tab switches and is reused when a
// new float window takes the lowest free number, carrying that slot's
// persisted layout with it.
// =========================================================================

public enum WindowSlotID: Hashable, Sendable, Equatable {
    case main
    case float(Int)

    /// Stable persistence key: "main", "float-1", ...
    public var key: String {
        switch self {
        case .main: return "main"
        case .float(let n): return "float-\(n)"
        }
    }

    public static func from(key: String) -> WindowSlotID? {
        if key == "main" { return .main }
        if key.hasPrefix("float-"), let n = Int(key.dropFirst("float-".count)) {
            return .float(n)
        }
        return nil
    }

    /// 0 for main, N for float-N. Useful for ini filenames and ordering.
    public var floatIndex: Int? {
        if case .float(let n) = self { return n }
        return nil
    }

    public var isMain: Bool {
        if case .main = self { return true }
        return false
    }
}

extension WindowSlotID: Codable {
    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        let key = try box.decode(String.self)
        guard let slot = Self.from(key: key) else {
            throw DecodingError.dataCorruptedError(
                in: box, debugDescription: "Unknown window slot key: \(key)")
        }
        self = slot
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        try box.encode(key)
    }
}

// =========================================================================
// MARK: - WindowPanelLayout
//
// Per-window panel visibility. Value type so copies are cheap and the
// seed-from-main rule is an explicit copy, never aliasing.
// =========================================================================

public struct WindowPanelLayout: Codable, Sendable, Equatable {
    public var layersPanelVisible: Bool
    public var drawPaletteVisible: Bool
    public var blockPanelVisible: Bool
    public var dataTablePanelVisible: Bool
    public var showPropertiesPanel: Bool
    public var xrefPanelVisible: Bool
    public var sheetSetManagerActive: Bool

    public init(
        layersPanelVisible: Bool = false,
        drawPaletteVisible: Bool = false,
        blockPanelVisible: Bool = false,
        dataTablePanelVisible: Bool = false,
        showPropertiesPanel: Bool = false,
        xrefPanelVisible: Bool = false,
        sheetSetManagerActive: Bool = false
    ) {
        self.layersPanelVisible = layersPanelVisible
        self.drawPaletteVisible = drawPaletteVisible
        self.blockPanelVisible = blockPanelVisible
        self.dataTablePanelVisible = dataTablePanelVisible
        self.showPropertiesPanel = showPropertiesPanel
        self.xrefPanelVisible = xrefPanelVisible
        self.sheetSetManagerActive = sheetSetManagerActive
    }
}

// =========================================================================
// MARK: - WindowPanelLayoutStore
//
// Slot-keyed panel layouts with lazy seed-from-main: the first access for
// a slot with no entry copies the main slot's current layout (or the
// default when main itself is empty), then diverges independently.
// Pure value type with no engine references so it stays unit-testable.
// =========================================================================

public struct WindowPanelLayoutStore: Codable, Sendable {
    /// Keyed by `WindowSlotID.key` so the whole store is Codable with a
    /// plain JSON dictionary.
    public var layouts: [String: WindowPanelLayout]

    public init(layouts: [String: WindowPanelLayout] = [:]) {
        self.layouts = layouts
    }

    public func peek(_ slot: WindowSlotID) -> WindowPanelLayout? {
        layouts[slot.key]
    }
    public func hasLayout(for slot: WindowSlotID) -> Bool {
        layouts[slot.key] != nil
    }

    /// The slot's layout, seeding from main on first access.
    public mutating func layout(for slot: WindowSlotID) -> WindowPanelLayout {
        if let existing = layouts[slot.key] {
            return existing
        }
        let seed: WindowPanelLayout
        if slot.isMain {
            seed = WindowPanelLayout()
        } else if let main = layouts[WindowSlotID.main.key] {
            seed = main
        } else {
            seed = WindowPanelLayout()
        }
        layouts[slot.key] = seed
        return seed
    }

    public mutating func set(_ layout: WindowPanelLayout, for slot: WindowSlotID) {
        layouts[slot.key] = layout
    }

    public mutating func update(slot: WindowSlotID, _ body: (inout WindowPanelLayout) -> Void) {
        var current = layout(for: slot)
        body(&current)
        layouts[slot.key] = current
    }

    /// Drop a slot's entry (layout returns to seed-from-main on next access).
    public mutating func remove(slot: WindowSlotID) {
        layouts.removeValue(forKey: slot.key)
    }

    public var count: Int { layouts.count }
}
