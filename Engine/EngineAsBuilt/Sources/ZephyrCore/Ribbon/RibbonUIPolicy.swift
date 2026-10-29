import Foundation
import ZephyrLisp

// =========================================================================
// MARK: - Ribbon UI policy
// =========================================================================
//
// Pure layout/state rules for the ribbon: display-mode cycle, per-mode
// metrics, panel/column geometry, overflow splitting, live-state predicate
// resolution and `%SYSVAR%` label interpolation.
//
// Everything here is ImGui-free and deterministic so the parts that are
// painful to test by eye (pixel math, threshold behaviour, which panel falls
// into the overflow popup, when an item greys out) are unit-testable — the
// same convention as StatusBarUIPolicy / PropertiesPanelUIPolicy.

// MARK: - Display modes

/// The three presentations cycled by the ribbon's mode control.
/// Persisted by raw value in `UserSettings`.
public enum RibbonDisplayMode: String, Sendable, Equatable, CaseIterable {
    /// Classic menu bar (`File Edit View …`).
    case menu
    /// Ribbon with text-only buttons.
    case labels
    /// Ribbon with icons and labels.
    case full

    /// Cycle order: menu -> labels -> full -> menu (the order the user sees
    /// when clicking the control repeatedly).
    public var next: RibbonDisplayMode {
        switch self {
        case .menu: return .labels
        case .labels: return .full
        case .full: return .menu
        }
    }

    public static func next(after mode: RibbonDisplayMode) -> RibbonDisplayMode {
        mode.next
    }

    /// Menu-bar-only mode: no tab strip, no panels.
    public var isMenuBar: Bool { self == .menu }
    /// Ribbon modes (tab strip + panels).
    public var isRibbon: Bool { self != .menu }
    /// Icons are drawn only in `.full`.
    public var showsIcons: Bool { self == .full }
}

// MARK: - Metrics

/// All pixel sizes the renderer needs for one mode, derived from ImGui's
/// current frame height so UI scale / DPI changes propagate.
public struct RibbonMetrics: Sendable, Equatable {
    public var mode: RibbonDisplayMode
    public var frameHeight: Float
    /// Font-scale factor relative to the 22 px baseline this policy was
    /// tuned against (`ImGuiGetFrameHeight()` with the 16 px UI font).
    public var scale: Float

    public var showsIcons: Bool
    /// Height of the tab strip (`.labels` / `.full`) or menu row (`.menu`).
    public var tabStripHeight: Float
    public var largeButtonWidth: Float
    public var largeButtonHeight: Float
    public var smallButtonWidth: Float
    public var smallButtonHeight: Float
    public var largeIconSize: Float
    public var smallIconSize: Float
    public var panelPadding: Float
    public var panelTitleHeight: Float
    public var itemGap: Float
    public var panelGap: Float
    public var separatorWidth: Float
    /// Height of one menu entry row / top-level menu button.
    public var menuRowHeight: Float
    /// Width reserved for the `»` overflow button when panels do not fit.
    public var overflowButtonWidth: Float
    /// Vertical rows of small items per column (AutoCAD uses 3).
    public var smallRowsPerColumn: Int
    /// `.labels` packs every panel item into a single horizontal row of
    /// text buttons — the compact "ribbon with labels" presentation. `.full`
    /// stacks small items 3 high next to a row of large icon buttons.
    public var singleRowLayout: Bool

    public static let baselineFrameHeight: Float = 22

    public init(mode: RibbonDisplayMode, frameHeight: Float) {
        let fh = max(frameHeight, 8)
        let s = max(fh / Self.baselineFrameHeight, 0.5)
        self.mode = mode
        self.frameHeight = fh
        self.scale = s
        self.showsIcons = mode.showsIcons
        self.tabStripHeight = (fh + 8 * s).rounded()
        self.largeIconSize = (26 * s).rounded()
        self.smallIconSize = (14 * s).rounded()

        if mode.showsIcons {
            self.largeButtonWidth = (62 * s).rounded()
            self.largeButtonHeight = (60 * s).rounded()
            self.smallButtonWidth = (132 * s).rounded()
        } else {
            // Text-only: wide enough for the label, one row high.
            self.largeButtonWidth = (88 * s).rounded()
            self.largeButtonHeight = (fh + 4 * s).rounded()
            self.smallButtonWidth = (124 * s).rounded()
        }
        self.smallButtonHeight = (fh + 4 * s).rounded()
        self.panelPadding = (6 * s).rounded()
        self.panelTitleHeight = (18 * s).rounded()
        self.itemGap = max((2 * s).rounded(), 1)
        self.panelGap = (6 * s).rounded()
        self.separatorWidth = (9 * s).rounded()
        self.menuRowHeight = (fh + 4 * s).rounded()
        self.overflowButtonWidth = (24 * s).rounded()
        self.smallRowsPerColumn = 3
        self.singleRowLayout = mode == .labels
    }

    /// Height of one stacked column of small items.
    public var smallStackHeight: Float {
        Float(smallRowsPerColumn) * smallButtonHeight
            + Float(smallRowsPerColumn - 1) * itemGap
    }

    /// Body height of a panel: the taller of one large row and a full small
    /// stack (the layout packs large items in a row, smalls in stacks of 3).
    public var panelBodyHeight: Float {
        if singleRowLayout {
            return max(largeButtonHeight, smallButtonHeight)
        }
        return max(largeButtonHeight, smallStackHeight)
    }

    /// Intrinsic content height of the whole ribbon in this mode, excluding
    /// the ImGui window padding.
    public var contentHeight: Float {
        switch mode {
        case .menu:
            return menuRowHeight
        case .labels, .full:
            return tabStripHeight
                + panelPadding * 2
                + panelBodyHeight
                + panelTitleHeight
        }
    }

    /// Window height to request when the ribbon is not docked (a docked
    /// window's size is owned by its dock node).
    public func windowHeight(windowPaddingY: Float) -> Float {
        fittedHeight(topInset: windowPaddingY, bottomPaddingY: windowPaddingY)
    }

    /// Total outer height — window rect when floating, dock-node rect
    /// when docked — needed to show `contentHeight` without clipping.
    ///
    /// `topInset` is measured at runtime as the distance from the
    /// window's top edge to the first content position. A visible dock
    /// tab bar and a floating window's title bar both live inside the
    /// outer rect *above* the content (the top window padding is
    /// included in the inset), so sizing to `content + 2 * padding`
    /// was short by exactly that bar and clipped the bottom row —
    /// the panel titles, or half the single row in `.menu`. With no
    /// bar showing, the inset equals the top padding.
    public func fittedHeight(topInset: Float, bottomPaddingY: Float) -> Float {
        (contentHeight + max(topInset, 0) + max(bottomPaddingY, 0)).rounded()
    }
}

// MARK: - Geometry

public struct RibbonRect: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Float { x + width }
    public var maxY: Float { y + height }
}

/// One item placed inside a panel column (coordinates are relative to the
/// panel-body origin, i.e. after padding).
public struct RibbonPlacement: Sendable, Equatable {
    public var item: RibbonItem
    public var rect: RibbonRect

    public init(item: RibbonItem, rect: RibbonRect) {
        self.item = item
        self.rect = rect
    }
}

/// A vertical column of a panel body.
public struct RibbonColumn: Sendable, Equatable {
    public var rect: RibbonRect
    public var placements: [RibbonPlacement]

    public init(rect: RibbonRect, placements: [RibbonPlacement]) {
        self.rect = rect
        self.placements = placements
    }
}

/// Laid-out panel. All rects are relative to the panel's top-left corner.
public struct RibbonPanelLayout: Sendable, Equatable {
    public var panel: RibbonPanel
    public var width: Float
    public var bodyHeight: Float
    public var height: Float
    public var columns: [RibbonColumn]
    /// Title bar under the body (AutoCAD puts panel titles at the bottom).
    public var titleRect: RibbonRect

    public init(
        panel: RibbonPanel,
        width: Float,
        bodyHeight: Float,
        height: Float,
        columns: [RibbonColumn],
        titleRect: RibbonRect
    ) {
        self.panel = panel
        self.width = width
        self.bodyHeight = bodyHeight
        self.height = height
        self.columns = columns
        self.titleRect = titleRect
    }
}

/// Result of fitting panels into the available width.
public struct RibbonOverflow: Sendable, Equatable {
    public var visible: [RibbonPanelLayout]
    public var hidden: [RibbonPanelLayout]
    public var usedWidth: Float
    public var showsOverflowButton: Bool

    public init(
        visible: [RibbonPanelLayout],
        hidden: [RibbonPanelLayout],
        usedWidth: Float,
        showsOverflowButton: Bool
    ) {
        self.visible = visible
        self.hidden = hidden
        self.usedWidth = usedWidth
        self.showsOverflowButton = showsOverflowButton
    }
}

// MARK: - Live state

/// Everything the per-frame predicate evaluation needs. A plain value type
/// so predicate/checked tests need no engine, document or ImGui context.
public struct RibbonStateContext: Sendable, Equatable {
    public var selectionCount: Int
    /// Canonical name of the running command (interactive or feature).
    public var activeCommand: String?
    public var canUndo: Bool
    public var canRedo: Bool
    public var isDirty: Bool
    public var tabCount: Int
    /// Sysvar snapshot keyed by UPPERCASED name. Only the names the loaded
    /// spec references are resolved (see `referencedVariables`).
    public var variables: [String: LispValue]

    public init(
        selectionCount: Int = 0,
        activeCommand: String? = nil,
        canUndo: Bool = false,
        canRedo: Bool = false,
        isDirty: Bool = false,
        tabCount: Int = 0,
        variables: [String: LispValue] = [:]
    ) {
        self.selectionCount = selectionCount
        self.activeCommand = activeCommand
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.isDirty = isDirty
        self.tabCount = tabCount
        self.variables = variables
    }

    public static let empty = RibbonStateContext()
}

// MARK: - Policy

public enum RibbonUIPolicy {

    // MARK: Metrics

    public static func metrics(
        for mode: RibbonDisplayMode, frameHeight: Float
    ) -> RibbonMetrics {
        RibbonMetrics(mode: mode, frameHeight: frameHeight)
    }

    /// Distance from a window's top edge to its first content
    /// position, clamped at zero. Feeds `RibbonMetrics.fittedHeight`;
    /// any excess over the top window padding is a dock tab bar or a
    /// floating title bar living inside the outer rect.
    public static func topInset(contentTop: Float, windowTop: Float) -> Float {
        max(contentTop - windowTop, 0)
    }

    // MARK: Panel layout

    /// Lays one panel out into columns.
    ///
    /// Rules (mirroring AutoCAD's ribbon):
    /// * consecutive `.large` items share one column as a horizontal row;
    /// * `.small` commands and dropdowns stack up to `smallRowsPerColumn`
    ///   per column, spilling into further columns;
    /// * a separator ends the current run and becomes a thin divider column
    ///   spanning the body height.
    public static func layout(
        panel: RibbonPanel, metrics: RibbonMetrics
    ) -> RibbonPanelLayout {
        let pad = metrics.panelPadding
        let gap = metrics.itemGap
        var columns: [RibbonColumn] = []
        var columnX: Float = 0
        var index = 0
        let items = panel.items

        func pushColumn(width: Float, placements: [RibbonPlacement]) {
            let height = placements.map { $0.rect.maxY }.max() ?? 0
            columns.append(
                RibbonColumn(
                    rect: RibbonRect(
                        x: columnX, y: 0, width: width, height: height),
                    placements: placements))
            columnX += width + gap
        }

        if metrics.singleRowLayout {
            // Compact presentation: one horizontal run, no stacks.
            var placements: [RibbonPlacement] = []
            var x: Float = 0
            for item in items {
                let width: Float
                switch item {
                case let .command(command):
                    width = command.size == .large
                        ? metrics.largeButtonWidth
                        : metrics.smallButtonWidth
                case .dropdown:
                    width = metrics.smallButtonWidth
                case .separator:
                    width = metrics.separatorWidth
                }
                placements.append(
                    RibbonPlacement(
                        item: item,
                        rect: RibbonRect(
                            x: x, y: 0, width: width,
                            height: metrics.panelBodyHeight)))
                x += width + gap
            }
            if !placements.isEmpty {
                pushColumn(width: x - gap, placements: placements)
            }
            index = items.count
        }

        while index < items.count {
            switch items[index] {
            case let .command(command) where command.size == .large:
                // Row of consecutive large buttons.
                var placements: [RibbonPlacement] = []
                var x: Float = 0
                while index < items.count,
                      case let .command(next) = items[index],
                      next.size == .large {
                    placements.append(
                        RibbonPlacement(
                            item: items[index],
                            rect: RibbonRect(
                                x: x, y: 0,
                                width: metrics.largeButtonWidth,
                                height: metrics.largeButtonHeight)))
                    x += metrics.largeButtonWidth + gap
                    index += 1
                }
                let width = x - gap
                pushColumn(width: width, placements: placements)

            case .command, .dropdown:
                // Stacks of small items: collect the run, then chunk it into
                // columns of at most `smallRowsPerColumn` rows.
                var chunk: [RibbonItem] = []
                var collecting = true
                while collecting, index < items.count {
                    switch items[index] {
                    case let .command(command) where command.size == .large:
                        collecting = false
                    case .separator:
                        collecting = false
                    case .command, .dropdown:
                        chunk.append(items[index])
                        index += 1
                    }
                }
                var start = 0
                while start < chunk.count {
                    let slice = Array(
                        chunk[start..<min(start + metrics.smallRowsPerColumn, chunk.count)])
                    var placements: [RibbonPlacement] = []
                    for (row, item) in slice.enumerated() {
                        let y = Float(row) * (metrics.smallButtonHeight + gap)
                        placements.append(
                            RibbonPlacement(
                                item: item,
                                rect: RibbonRect(
                                    x: 0, y: y,
                                    width: metrics.smallButtonWidth,
                                    height: metrics.smallButtonHeight)))
                    }
                    pushColumn(width: metrics.smallButtonWidth, placements: placements)
                    start += metrics.smallRowsPerColumn
                }
                if chunk.isEmpty { index += 1 }  // Defensive: never spin.

            case .separator:
                pushColumn(
                    width: metrics.separatorWidth,
                    placements: [
                        RibbonPlacement(
                            item: .separator,
                            rect: RibbonRect(
                                x: 0, y: 0, width: metrics.separatorWidth, height: 0))
                    ])
                index += 1
            }
        }

        // Separators stretch to the final body height (their height is only
        // known once every column is measured).
        var bodyHeight: Float = metrics.panelBodyHeight
        for column in columns {
            bodyHeight = max(bodyHeight, column.rect.height)
        }
        for columnIndex in columns.indices {
            for placementIndex in columns[columnIndex].placements.indices
            where columns[columnIndex].placements[placementIndex].item == .separator {
                columns[columnIndex].placements[placementIndex].rect.height = bodyHeight
            }
        }

        let contentWidth = columns.isEmpty
            ? 0
            : (columns.last!.rect.maxX)
        let width = contentWidth + pad * 2
        let height = pad + bodyHeight + metrics.panelTitleHeight + pad
        let titleRect = RibbonRect(
            x: 0,
            y: pad + bodyHeight,
            width: width,
            height: metrics.panelTitleHeight)

        return RibbonPanelLayout(
            panel: panel,
            width: width,
            bodyHeight: bodyHeight,
            height: height,
            columns: columns,
            titleRect: titleRect)
    }

    public static func layout(
        tab: RibbonTab, metrics: RibbonMetrics
    ) -> [RibbonPanelLayout] {
        tab.panels.map { layout(panel: $0, metrics: metrics) }
    }

    /// Fits laid-out panels into `availableWidth`, hiding the tail when it
    /// does not fit and reserving room for the overflow button.
    public static func split(
        panels: [RibbonPanelLayout],
        availableWidth: Float,
        metrics: RibbonMetrics
    ) -> RibbonOverflow {
        func totalWidth(_ count: Int) -> Float {
            guard count > 0 else { return 0 }
            let panelsWidth = panels.prefix(count).reduce(Float(0)) {
                $0 + $1.width
            }
            return panelsWidth + Float(count - 1) * metrics.panelGap
        }

        let all = totalWidth(panels.count)
        if all <= availableWidth {
            return RibbonOverflow(
                visible: panels, hidden: [], usedWidth: all,
                showsOverflowButton: false)
        }
        let budget = availableWidth - metrics.overflowButtonWidth - metrics.panelGap
        var fit = 0
        var used: Float = 0
        for (index, panel) in panels.enumerated() {
            let next = used + (index == 0 ? 0 : metrics.panelGap) + panel.width
            if next > budget { break }
            used = next
            fit = index + 1
        }
        return RibbonOverflow(
            visible: Array(panels.prefix(fit)),
            hidden: Array(panels.dropFirst(fit)),
            usedWidth: used,
            showsOverflowButton: fit < panels.count)
    }

    // MARK: Predicates

    public static func evaluate(
        _ predicate: RibbonPredicate, in context: RibbonStateContext
    ) -> Bool {
        switch predicate {
        case let .selectionAtLeast(count):
            return context.selectionCount >= count
        case .noActiveCommand:
            return context.activeCommand == nil
        case let .activeCommand(name):
            return context.activeCommand?.uppercased() == name.uppercased()
        case .undoAvailable:
            return context.canUndo
        case .redoAvailable:
            return context.canRedo
        case .documentDirty:
            return context.isDirty
        case let .variableEquals(name, expected):
            guard let actual = context.variables[name.uppercased()] else {
                return false
            }
            return valuesEqual(actual, expected)
        case let .tabCountAtLeast(count):
            return context.tabCount >= count
        }
    }

    /// All predicates must hold (an empty list means "always").
    public static func allHold(
        _ predicates: [RibbonPredicate], in context: RibbonStateContext
    ) -> Bool {
        predicates.allSatisfy { evaluate($0, in: context) }
    }

    public static func isEnabled(
        _ command: RibbonCommand, in context: RibbonStateContext
    ) -> Bool {
        allHold(command.enabled, in: context)
    }

    public static func isChecked(
        _ command: RibbonCommand, in context: RibbonStateContext
    ) -> Bool {
        !command.checked.isEmpty && allHold(command.checked, in: context)
    }

    public static func isEnabled(
        _ item: RibbonItem, in context: RibbonStateContext
    ) -> Bool {
        if case let .command(command) = item {
            return isEnabled(command, in: context)
        }
        return true
    }

    /// Int/real comparisons are numeric so `(zr-var "GRIDMODE" 1)` matches
    /// both the int 1 and the real 1.0 an AutoLISP expression may produce.
    static func valuesEqual(_ lhs: LispValue, _ rhs: LispValue) -> Bool {
        if let a = lhs.asDouble, let b = rhs.asDouble {
            return abs(a - b) < 1e-9
        }
        switch (lhs, rhs) {
        case let (.string(a), .string(b)):
            return a.caseInsensitiveCompare(b) == .orderedSame
        case let (.symbol(a), .symbol(b)):
            return a.uppercased() == b.uppercased()
        case (.nilValue, .nilValue):
            return true
        default:
            return lhs == rhs
        }
    }

    // MARK: Referenced sysvars

    /// Sysvar names a spec reads, so the renderer can resolve exactly those
    /// into the per-frame context instead of copying the whole store.
    public static func referencedVariables(in spec: RibbonSpec) -> [String] {
        var names = Set<String>()
        func collect(_ items: [RibbonItem]) {
            for item in items {
                switch item {
                case let .command(command):
                    for predicate in command.enabled + command.checked {
                        collectPredicate(predicate, into: &names)
                    }
                    collectLabelVariables(command.label, into: &names)
                case let .dropdown(dropdown):
                    collectLabelVariables(dropdown.label, into: &names)
                    collect(dropdown.items)
                case .separator:
                    break
                }
            }
        }
        for menu in spec.menus { collect(menu.items) }
        for tab in spec.tabs {
            for panel in tab.panels {
                collectLabelVariables(panel.title, into: &names)
                collect(panel.items)
            }
        }
        return names.sorted()
    }

    private static func collectPredicate(
        _ predicate: RibbonPredicate, into names: inout Set<String>
    ) {
        if case let .variableEquals(name, _) = predicate {
            names.insert(name.uppercased())
        }
    }

    private static func collectLabelVariables(
        _ label: String, into names: inout Set<String>
    ) {
        for token in RibbonText.tokens(in: label) {
            names.insert(token)
        }
    }
}

// MARK: - Label interpolation

/// `%SYSVAR%` substitution for labels and panel titles.
///
/// Unknown names are left verbatim (`Layer: %CLAYERR%` stays visible) so a
/// typo is obvious in the UI instead of silently rendering an empty label.
public enum RibbonText {
    /// Uppercased `%NAME%` tokens in the order they appear (deduplicated by
    /// the caller when collecting sysvars).
    public static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "%" else {
                index = text.index(after: index)
                continue
            }
            let afterOpen = text.index(after: index)
            guard let close = text[afterOpen...].firstIndex(of: "%") else { break }
            let name = String(text[afterOpen..<close])
            if !name.isEmpty { out.append(name.uppercased()) }
            index = text.index(after: close)
        }
        return out
    }

    public static func interpolate(
        _ text: String, in context: RibbonStateContext
    ) -> String {
        guard text.contains("%") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "%" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            let afterOpen = text.index(after: index)
            guard let close = text[afterOpen...].firstIndex(of: "%") else {
                out.append(contentsOf: text[index...])
                break
            }
            let name = String(text[afterOpen..<close]).uppercased()
            if let value = context.variables[name] {
                out += value.displayString
            } else {
                out += "%" + String(text[afterOpen..<close]) + "%"
            }
            index = text.index(after: close)
        }
        return out
    }
}

// MARK: - Derived menus

extension RibbonUIPolicy {
    /// Menus for a definition that has no explicit `menubar` section: each
    /// tab becomes a menu, each panel a submenu. Keeps a minimal definition
    /// (tabs only) usable in `.menu` display mode.
    public static func derivedMenus(from tabs: [RibbonTab]) -> [RibbonMenu] {
        tabs.map { tab in
            RibbonMenu(
                title: tab.title,
                items: tab.panels.map { panel in
                    .dropdown(
                        RibbonDropdown(
                            label: panel.title, items: panel.items))
                })
        }
    }
}
