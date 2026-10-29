import ZephyrCore
import ZephyrLisp
import Foundation
import ImGui

// =========================================================================
// MARK: - RibbonUI
// =========================================================================
//
// Renders the AutoLISP-defined ribbon as a dockable window (same docking
// pattern as the Layers/Properties/Draw palettes: `_isDocked` static, a
// `FirstUseEver` position, and `AppLayout.reportCurrentDockedPanel` so the
// canvas picking region ignores it).
//
// Three presentations of the same model (`RibbonDisplayMode`):
//   .menu   — classic menu bar (File/Edit/View…), from the spec's `menus`
//             section (derived from tabs when that section is absent);
//   .labels — every panel item in one horizontal run of text buttons;
//   .full   — AutoCAD-style panels: large icon buttons + stacks of three
//             small buttons, panel titles underneath.
//
// The window never mutates documents: clicks are collected as `Action`s and
// dispatched after `igEnd()`, so a command can never run mid-render.
//
// Icons are drawn procedurally (`RibbonIconPainter`) so they scale with DPI
// and follow the theme without shipping an icon font.

@MainActor
struct RibbonUI {

    /// Tracks docking state so the window can drop its title bar when docked
    /// (identical to the panel pattern in DrawPaletteUI).
    static var _isDocked = false

    /// Window padding pushed for the ribbon window in `render`. Kept as
    /// constants so the sizing math uses the padding actually in
    /// effect, not the global style's.
    private static let windowPaddingX: Float = 4
    private static let windowPaddingY: Float = 3

    /// What the docked node was last sized for, so the node is resized
    /// exactly once per change (a user-dragged splitter is never fought
    /// with while nothing changed). The top inset is part of the key:
    /// the dock tab bar appearing (a second window joins the node) or
    /// auto-hiding (back to solo) changes the height the node needs by
    /// exactly the tab bar's height.
    private struct DockedSizingKey: Equatable {
        var mode: RibbonDisplayMode
        var topInset: Float
    }
    private static var _sizedDockedKey: DockedSizingKey?

    /// Top inset (title bar + top padding) measured last frame while
    /// floating. The floating size constraint must be set *before*
    /// `igBegin`, so it uses last frame's measurement (the title bar
    /// height does not change with the display mode).
    private static var _floatingTopInset: Float?

    // MARK: - Actions

    private enum Action {
        case runCommand(String)
        case selectTab(String)
        case setMode(RibbonDisplayMode)
        case reload
        case hide
        /// Undock into a floating window. Handled in `render`, which
        /// holds the ImGui window pointer `igSetWindowDock` needs.
        case popOut
    }

    // MARK: - Per-frame pump

    /// Drives the definition loader. Called every frame regardless of the
    /// ribbon's visibility, so `RIBBONRELOAD` finishes and auto-reload keeps
    /// working while the ribbon is closed.
    static func poll(engine: PhrostEngine) {
        engine.ribbonLoader?.poll()
    }

    // MARK: - Render

    static func render(engine: PhrostEngine, dw: Float) {
        guard !engine.ui.isFloatFrame,
              engine.ui.ribbonVisible,
              let loader = engine.ribbonLoader
        else { return }

        let mode = engine.ui.ribbonMode
        let theme = engine.ui.theme
        let metrics = RibbonUIPolicy.metrics(
            for: mode, frameHeight: ImGuiGetFrameHeight())
        let isDocked = _isDocked
        // Outer height that fits the content. The top inset accounts
        // for whatever bar lives above the content inside the outer
        // rect: nothing but padding when docked solo (the tab bar
        // auto-hides), the title bar when floating. Sizing without it
        // clipped the bottom row — panel titles, or half the menu row.
        let estimatedTopInset: Float = isDocked
            ? windowPaddingY
            : (_floatingTopInset ?? (ImGuiGetFrameHeight() + windowPaddingY))
        let fittedHeight = metrics.fittedHeight(
            topInset: estimatedTopInset, bottomPaddingY: windowPaddingY)

        // Position/size/dock state is saved in imgui.ini like every other
        // panel, so the ribbon comes back where the user put it.
        var flags = Int32(ImGuiWindowFlags_NoScrollbar.rawValue)
            | Int32(ImGuiWindowFlags_NoScrollWithMouse.rawValue)
        if isDocked {
            flags |= Int32(ImGuiWindowFlags_NoTitleBar.rawValue)
        }

        ImGuiSetNextWindowPos(
            ImVec2(x: 0, y: AppLayout.belowTabBarY),
            Int32(ImGuiCond_FirstUseEver.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(
            ImVec2(x: min(dw * 0.85, 1100), y: fittedHeight),
            Int32(ImGuiCond_FirstUseEver.rawValue))
        // A floating ribbon is fitted to the mode's content height; the
        // width stays free so it can be widened. A *docked* ribbon is sized
        // by its dock node instead (see updateDockedNodeSize), so constraining
        // it here would leave the window shorter than the node.
        if !isDocked {
            ImGuiSetNextWindowSizeConstraints(
                ImVec2(x: 260, y: fittedHeight),
                ImVec2(x: 100_000, y: fittedHeight),
                { _ in }, nil)
        }

        ImGuiPushStyleVarX(
            Int32(ImGuiStyleVar_WindowPadding.rawValue), windowPaddingX)
        ImGuiPushStyleVarY(
            Int32(ImGuiStyleVar_WindowPadding.rawValue), windowPaddingY)
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), 0)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_WindowBg.rawValue), theme.panelBgDim)

        if let smallFont = engine.ui.smallFont {
            ImGuiPushFont(smallFont, 0.0)
        }

        let context = makeStateContext(engine: engine, spec: loader.spec)
        var actions: [Action] = []
        var opened = true
        var dockedNodeID: ImGuiID = 0
        var measuredTopInset: Float = 0
        var windowPointer: UnsafeMutablePointer<ImGuiWindow>?

        if igBegin("Ribbon", &opened, flags) {
            _isDocked = ImGuiIsWindowDocked()
            AppLayout.reportCurrentDockedPanel(engine: engine)
            // The window draw list only exists inside a window.
            let drawList = igGetWindowDrawList()
            // A docked window's size belongs to its dock node; remember the
            // node so the mode change can resize it after the window closes.
            dockedNodeID = _isDocked ? ImGuiGetWindowDockID() : 0
            windowPointer = ImGuiGetCurrentWindow()
            // Measure the bar above the content (dock tab bar when
            // visible, title bar when floating) from the first content
            // position — before anything is submitted, the cursor sits
            // exactly there. The measured inset drives the sizing
            // below; for a floating window it also feeds next frame's
            // constraint, which must be set before Begin.
            measuredTopInset = RibbonUIPolicy.topInset(
                contentTop: ImGuiGetCursorScreenPos().y,
                windowTop: ImGuiGetWindowPos().y)
            if !_isDocked {
                _floatingTopInset = measuredTopInset
            }

            switch mode {
            case .menu:
                renderMenuBar(
                    engine: engine, spec: loader.spec, metrics: metrics,
                    context: context, theme: theme, isDocked: _isDocked,
                    drawList: drawList, actions: &actions)
            case .labels, .full:
                renderRibbon(
                    engine: engine, spec: loader.spec, metrics: metrics,
                    context: context, theme: theme, isDocked: _isDocked,
                    drawList: drawList, actions: &actions)
            }
            renderStatusHint(
                loader: loader, metrics: metrics, theme: theme,
                drawList: drawList)
        } else {
            _isDocked = ImGuiIsWindowDocked()
            dockedNodeID = 0
        }
        ImGuiEnd()

        updateDockedNodeSize(
            mode: mode, metrics: metrics, nodeID: dockedNodeID,
            topInset: measuredTopInset)

        if let smallFont = engine.ui.smallFont {
            _ = smallFont
            ImGuiPopFont()
        }
        ImGuiPopStyleColor(1)
        ImGuiPopStyleVar(3)

        if !opened {
            engine.ui.ribbonVisible = false
        }
        for action in actions {
            if case .popOut = action {
                // Undock in place; the floating path fits the height
                // next frame and the title bar returns for dragging.
                if let windowPointer {
                    igSetWindowDock(
                        windowPointer, 0,
                        Int32(ImGuiCond_Always.rawValue))
                }
                _isDocked = false
                _sizedDockedKey = nil
            } else {
                apply(action, engine: engine)
            }
        }
    }

    // MARK: - Dock node sizing

    /// Keeps a *docked* ribbon the exact height of the current presentation.
    ///
    /// A docked ImGui window's size is owned by its dock node, so collapsing
    /// to labels or the menu bar would otherwise leave a tall empty strip.
    /// The node is resized only when the mode or the measured top inset
    /// changes (and on the first docked frame), so a splitter the user
    /// dragged is left alone while both stay put. The target is the
    /// *fitted* height: content between the top inset (dock tab bar +
    /// top padding when the tab bar shows, padding alone when it is
    /// auto-hidden for a solo window) and the bottom padding — sizing
    /// to the content alone clipped the bottom row by the tab bar.
    /// `ImGuiDockBuilderSetNodeSize` also propagates the new size to
    /// the parent split, which makes the canvas reclaim the space in
    /// the same frame.
    private static func updateDockedNodeSize(
        mode: RibbonDisplayMode,
        metrics: RibbonMetrics,
        nodeID: ImGuiID,
        topInset: Float
    ) {
        guard nodeID != 0 else {
            // Floating (or hidden): nothing owns our size, and the floating
            // path already fits the window to the content.
            _sizedDockedKey = nil
            return
        }
        let key = DockedSizingKey(mode: mode, topInset: topInset.rounded())
        guard _sizedDockedKey != key else { return }

        let target = metrics.fittedHeight(
            topInset: topInset, bottomPaddingY: windowPaddingY)
        guard let node = ImGuiDockBuilderGetNode(nodeID) else {
            // The dockspace has not materialised yet; retry next frame.
            return
        }
        // ImGui asserts if a resized node has a zero-sized ancestor (a
        // dockspace that has not been laid out). Check the root first and
        // retry next frame instead of tripping the assertion.
        let rootRect = ImGuiDockNodeRect(ImGuiDockNodeGetRootNode(node))
        guard rootRect.Max.x - rootRect.Min.x > 1,
              rootRect.Max.y - rootRect.Min.y > 1
        else { return }

        let rect = ImGuiDockNodeRect(node)
        let width = rect.Max.x - rect.Min.x
        let height = rect.Max.y - rect.Min.y
        if width > 1, abs(height - target) > 1 {
            ImGuiDockBuilderSetNodeSize(nodeID, ImVec2(x: width, y: target))
        }
        _sizedDockedKey = key
    }

    // MARK: - Action dispatch
    private static func apply(_ action: Action, engine: PhrostEngine) {
        switch action {
        case let .runCommand(name):
            engine.commandProcessor.executeCommand(name)
        case let .selectTab(id):
            engine.ui.activeRibbonTab = id
        case let .setMode(mode):
            engine.ui.ribbonMode = mode
        case .reload:
            engine.ribbonLoader?.reload()
        case .hide:
            engine.ui.ribbonVisible = false
        case .popOut:
            break  // Handled in `render` (needs the window pointer).
        }
    }

    // MARK: - Live state

    /// Resolves exactly the sysvars the current definition references, plus
    /// the engine facts the predicates need. One pass per frame.
    private static func makeStateContext(
        engine: PhrostEngine, spec: RibbonSpec
    ) -> RibbonStateContext {
        var variables: [String: LispValue] = [:]
        for name in RibbonUIPolicy.referencedVariables(in: spec) {
            if let value = engine.commandProcessor.systemVariable(name) {
                variables[name] = value
            }
        }
        return RibbonStateContext(
            selectionCount: engine.cadSelection.selectedCount,
            activeCommand: engine.commandProcessor.activeCommandDisplayName,
            canUndo: engine.document.undoManager.canUndo,
            canRedo: engine.document.undoManager.canRedo,
            isDirty: engine.tabManager.activeTab?.hasUnsavedChanges ?? false,
            tabCount: engine.tabManager.tabs.count,
            variables: variables)
    }

    // MARK: - Ribbon modes (labels + full)

    private static func renderRibbon(
        engine: PhrostEngine,
        spec: RibbonSpec,
        metrics: RibbonMetrics,
        context: RibbonStateContext,
        theme: AppTheme,
        isDocked: Bool,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        actions: inout [Action]
    ) {
        let origin = ImGuiGetCursorScreenPos()
        let windowPos = ImGuiGetWindowPos()
        let windowSize = ImGuiGetWindowSize()
        let innerLeft = windowPos.x + 4
        let innerRight = windowPos.x + windowSize.x - 4

        // --- Tab strip -------------------------------------------------
        var x = innerLeft
        let activeTabID = spec.resolvedTabID(
            requested: engine.ui.activeRibbonTab)
        for tab in spec.tabs {
            let labelWidth = ImGuiCalcTextSize(tab.title, nil, false, -1).x
            let width = labelWidth + 20 * metrics.scale
            let rect = RibbonRect(
                x: x, y: origin.y, width: width,
                height: metrics.tabStripHeight)
            let isActive = tab.id == activeTabID
            if RibbonWidgets.tabButton(
                id: "ribbon-tab-\(tab.id)", label: tab.title, rect: rect,
                active: isActive, theme: theme, drawList: drawList) {
                actions.append(.selectTab(tab.id))
            }
            x += width
        }

        // Right-aligned chrome controls.
        var controlsX = innerRight
        controlsX = renderChromeControls(
            engine: engine, metrics: metrics, theme: theme,
            isDocked: isDocked,
            drawList: drawList, rightY: origin.y,
            rightEdge: controlsX, actions: &actions)

        // --- Panels ----------------------------------------------------
        let panelRowY = origin.y + metrics.tabStripHeight
        guard let tab = spec.tab(id: activeTabID) else {
            drawEmptyState(
                engine: engine, metrics: metrics, theme: theme,
                drawList: drawList, at: ImVec2(x: innerLeft, y: panelRowY),
                width: innerRight - innerLeft)
            return
        }

        let layouts = RibbonUIPolicy.layout(tab: tab, metrics: metrics)
        let available = max(innerRight - innerLeft, 80)
        let overflow = RibbonUIPolicy.split(
            panels: layouts, availableWidth: available, metrics: metrics)

        var panelX = innerLeft
        for layout in overflow.visible {
            renderPanel(
                layout: layout,
                origin: ImVec2(x: panelX, y: panelRowY),
                metrics: metrics,
                context: context,
                theme: theme,
                drawList: drawList,
                actions: &actions)
            panelX += layout.width + metrics.panelGap
        }

        if overflow.showsOverflowButton {
            let rect = RibbonRect(
                x: panelX, y: panelRowY + metrics.panelPadding,
                width: metrics.overflowButtonWidth,
                height: metrics.smallButtonHeight)
            var spec = RibbonWidgets.ButtonSpec(
                id: "ribbon-overflow", label: ">>", rect: rect)
            spec.tooltip = "\(overflow.hidden.count) panel(s) do not fit"
            if RibbonWidgets.button(
                spec: spec, theme: theme, drawList: drawList) {
                ImGuiOpenPopup("##ribbon-overflow-popup", 0)
            }
            if ImGuiBeginPopup("##ribbon-overflow-popup", 0) {
                for layout in overflow.hidden {
                    if ImGuiBeginMenu(layout.panel.title, true) {
                        drawMenuItems(
                            layout.panel.items, context: context,
                            actions: &actions)
                        ImGuiEndMenu()
                    }
                }
                ImGuiEndPopup()
            }
        }
    }

    private static func renderPanel(
        layout: RibbonPanelLayout,
        origin: ImVec2,
        metrics: RibbonMetrics,
        context: RibbonStateContext,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        actions: inout [Action]
    ) {
        let min = origin
        let max = ImVec2(
            x: origin.x + layout.width, y: origin.y + layout.height)

        ImDrawListAddRectFilled(
            drawList, min, max,
            igGetColorU32_Vec4(theme.panelBg), 3.0, 0)

        // Title bar at the bottom (AutoCAD's panel titles).
        let titleMin = ImVec2(
            x: origin.x + layout.titleRect.x,
            y: origin.y + layout.titleRect.y)
        let titleMax = ImVec2(
            x: origin.x + layout.titleRect.maxX,
            y: origin.y + layout.titleRect.maxY)
        ImDrawListAddRectFilled(
            drawList, titleMin, titleMax,
            igGetColorU32_Vec4(theme.tabBarBg), 0.0, 0)
        let titleSize = ImGuiCalcTextSize(layout.panel.title, nil, false, -1)
        let titleTextPos = ImVec2(
            x: titleMin.x + (layout.titleRect.width - titleSize.x) * 0.5,
            y: titleMin.y + (metrics.panelTitleHeight - titleSize.y) * 0.5)
        ImDrawListAddText(
            drawList, titleTextPos, igGetColorU32_Vec4(theme.textDim),
            layout.panel.title)

        let bodyX = origin.x + metrics.panelPadding
        let bodyY = origin.y + metrics.panelPadding

        for (columnIndex, column) in layout.columns.enumerated() {
            for (itemIndex, placement) in column.placements.enumerated() {
                let rect = RibbonRect(
                    x: bodyX + column.rect.x + placement.rect.x,
                    y: bodyY + column.rect.y + placement.rect.y,
                    width: placement.rect.width,
                    height: placement.rect.height)
                let id = "ribbon-\(layout.panel.title)-\(columnIndex)-\(itemIndex)"

                switch placement.item {
                case .separator:
                    let lineX = rect.x + rect.width * 0.5
                    ImDrawListAddLine(
                        drawList,
                        ImVec2(x: lineX, y: rect.y + 2),
                        ImVec2(x: lineX, y: rect.y + rect.height - 2),
                        igGetColorU32_Vec4(theme.hoverBg), 1.0)
                case let .command(command):
                    renderCommandButton(
                        command: command, id: id, rect: rect,
                        metrics: metrics, context: context, theme: theme,
                        drawList: drawList, actions: &actions)
                case let .dropdown(dropdown):
                    renderDropdownButton(
                        dropdown: dropdown, id: id, rect: rect,
                        metrics: metrics, context: context, theme: theme,
                        drawList: drawList, actions: &actions)
                }
            }
        }
    }

    private static func renderCommandButton(
        command: RibbonCommand,
        id: String,
        rect: RibbonRect,
        metrics: RibbonMetrics,
        context: RibbonStateContext,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        actions: inout [Action]
    ) {
        let label = RibbonText.interpolate(command.label, in: context)
        var spec = RibbonWidgets.ButtonSpec(
            id: id,
            label: label,
            rect: rect,
            enabled: RibbonUIPolicy.isEnabled(command, in: context),
            checked: RibbonUIPolicy.isChecked(command, in: context),
            isLarge: command.size == .large,
            showIcon: metrics.showsIcons,
            icon: metrics.showsIcons ? command.resolvedIconName : nil,
            iconSize: command.size == .large
                ? metrics.largeIconSize : metrics.smallIconSize)
        spec.tooltip = command.tooltip ?? command.command
        if RibbonWidgets.button(spec: spec, theme: theme, drawList: drawList) {
            actions.append(.runCommand(command.command))
        }
    }

    private static func renderDropdownButton(
        dropdown: RibbonDropdown,
        id: String,
        rect: RibbonRect,
        metrics: RibbonMetrics,
        context: RibbonStateContext,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        actions: inout [Action]
    ) {
        var spec = RibbonWidgets.ButtonSpec(
            id: id,
            label: RibbonText.interpolate(dropdown.label, in: context),
            rect: rect,
            isLarge: false,
            showIcon: metrics.showsIcons,
            icon: metrics.showsIcons ? dropdown.icon : nil,
            iconSize: metrics.smallIconSize,
            drawChevron: true)
        spec.tooltip = dropdown.tooltip ?? dropdown.label
        // OpenPopup and BeginPopup must both be evaluated on EVERY frame:
        // ImGui only creates the popup window in frames where BeginPopup
        // runs, so returning early when the button was not clicked this
        // frame opened a popup that could never draw anything.
        let popupID = "##ribbon-drop-\(id)"
        if RibbonWidgets.button(
            spec: spec, theme: theme, drawList: drawList) {
            ImGuiOpenPopup(popupID, 0)
        }
        if ImGuiBeginPopup(popupID, 0) {
            drawMenuItems(dropdown.items, context: context, actions: &actions)
            ImGuiEndPopup()
        }
    }

    // MARK: - Menu mode

    private static func renderMenuBar(
        engine: PhrostEngine,
        spec: RibbonSpec,
        metrics: RibbonMetrics,
        context: RibbonStateContext,
        theme: AppTheme,
        isDocked: Bool,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        actions: inout [Action]
    ) {
        let menus = spec.menus.isEmpty
            ? RibbonUIPolicy.derivedMenus(from: spec.tabs)
            : spec.menus
        let origin = ImGuiGetCursorScreenPos()
        let windowPos = ImGuiGetWindowPos()
        let windowSize = ImGuiGetWindowSize()

        var x = windowPos.x + 4
        for menu in menus {
            let labelWidth = ImGuiCalcTextSize(menu.title, nil, false, -1).x
            let width = labelWidth + 18 * metrics.scale
            let rect = RibbonRect(
                x: x, y: origin.y, width: width,
                height: metrics.menuRowHeight)
            let popupID = "##ribbon-menu-\(menu.title)"
            if RibbonWidgets.flatButton(
                id: "ribbon-menu-\(menu.title)", label: menu.title,
                rect: rect, active: ImGuiIsPopupOpen(popupID, 0),
                theme: theme, drawList: drawList) {
                ImGuiOpenPopup(popupID, 0)
            }
            if ImGuiBeginPopup(popupID, 0) {
                drawMenuItems(menu.items, context: context, actions: &actions)
                ImGuiEndPopup()
            }
            x += width
        }

        _ = renderChromeControls(
            engine: engine, metrics: metrics, theme: theme,
            isDocked: isDocked,
            drawList: drawList, rightY: origin.y,
            rightEdge: windowPos.x + windowSize.x - 4,
            actions: &actions)

        if menus.isEmpty {
            drawEmptyState(
                engine: engine, metrics: metrics, theme: theme,
                drawList: drawList,
                at: ImVec2(x: origin.x, y: origin.y),
                width: windowSize.x - 8)
        }
    }

    /// One menu/submenu level. Menus reuse the ribbon item vocabulary.
    private static func drawMenuItems(
        _ items: [RibbonItem],
        context: RibbonStateContext,
        actions: inout [Action]
    ) {
        for item in items {
            switch item {
            case .separator:
                igSeparator()
            case let .command(command):
                let label = RibbonText.interpolate(command.label, in: context)
                let enabled = RibbonUIPolicy.isEnabled(command, in: context)
                let checked = RibbonUIPolicy.isChecked(command, in: context)
                if igMenuItem_Bool(label, nil, checked, enabled) {
                    actions.append(.runCommand(command.command))
                }
                if enabled, ImGuiIsItemHovered(0),
                   let tooltip = command.tooltip {
                    ImGuiBeginTooltip()
                    ImGuiTextV(tooltip)
                    ImGuiEndTooltip()
                }
            case let .dropdown(dropdown):
                let label = RibbonText.interpolate(dropdown.label, in: context)
                if ImGuiBeginMenu(label, true) {
                    drawMenuItems(
                        dropdown.items, context: context, actions: &actions)
                    ImGuiEndMenu()
                }
            }
        }
    }

    // MARK: - Chrome controls (pop-out + reload + display-mode cycle)

    /// Draws the right-aligned pop-out (docked only), reload and
    /// mode-cycle buttons and returns the x coordinate of their left
    /// edge. Pop-out replaces the solo dock tab as the way to undock:
    /// with the tab bar auto-hidden there is no tab to drag, and
    /// ImGui's corner unhide triangle is too small to rely on.
    @discardableResult
    private static func renderChromeControls(
        engine: PhrostEngine,
        metrics: RibbonMetrics,
        theme: AppTheme,
        isDocked: Bool,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        rightY: Float,
        rightEdge: Float,
        actions: inout [Action]
    ) -> Float {
        let failed = engine.ribbonLoader?.status == .failed
        let modeLabel = displayModeButtonLabel(engine.ui.ribbonMode)
        let reloadLabel = failed ? "Reload *" : "Reload"

        func width(_ text: String) -> Float {
            ImGuiCalcTextSize(text, nil, false, -1).x + 14 * metrics.scale
        }

        var right = rightEdge
        let modeWidth = width(modeLabel)
        var modeSpec = RibbonWidgets.ButtonSpec(
            id: "ribbon-cycle-mode",
            label: modeLabel,
            rect: RibbonRect(
                x: right - modeWidth, y: rightY, width: modeWidth,
                height: metrics.tabStripHeight),
            isLarge: true,
            showIcon: false)
        modeSpec.tooltip =
            "Ribbon display: menu bar, labels, or icons + labels "
            + "(now: \(engine.ui.ribbonMode.rawValue))"
        if RibbonWidgets.button(
            spec: modeSpec, theme: theme, drawList: drawList) {
            actions.append(.setMode(engine.ui.ribbonMode.next))
        }
        right -= modeWidth

        let reloadWidth = width(reloadLabel)
        var reloadSpec = RibbonWidgets.ButtonSpec(
            id: "ribbon-reload",
            label: reloadLabel,
            rect: RibbonRect(
                x: right - reloadWidth, y: rightY, width: reloadWidth,
                height: metrics.tabStripHeight),
            isLarge: true,
            showIcon: false)
        reloadSpec.tooltip = reloadTooltip(engine: engine)
        if RibbonWidgets.button(
            spec: reloadSpec, theme: theme, drawList: drawList) {
            actions.append(.reload)
        }
        right -= reloadWidth

        if isDocked {
            let popOutLabel = "Pop-out"
            let popOutWidth = width(popOutLabel)
            var popOutSpec = RibbonWidgets.ButtonSpec(
                id: "ribbon-pop-out",
                label: popOutLabel,
                rect: RibbonRect(
                    x: right - popOutWidth, y: rightY, width: popOutWidth,
                    height: metrics.tabStripHeight),
                isLarge: true,
                showIcon: false)
            popOutSpec.tooltip =
                "Undock the ribbon into a floating window "
                + "(drag it back onto an edge to re-dock)"
            if RibbonWidgets.button(
                spec: popOutSpec, theme: theme, drawList: drawList) {
                actions.append(.popOut)
            }
            right -= popOutWidth
        }
        return right
    }

    private static func displayModeButtonLabel(
        _ mode: RibbonDisplayMode
    ) -> String {
        switch mode.next {
        case .menu: return "Menu"
        case .labels: return "Labels"
        case .full: return "Icons"
        }
    }

    private static func reloadTooltip(engine: PhrostEngine) -> String {
        guard let loader = engine.ribbonLoader else {
            return "Ribbon definitions are unavailable"
        }
        var lines = [
            "Re-read the AutoLISP ribbon definition",
            loader.sourcePath ?? "(no file loaded)",
        ]
        if let error = loader.errorMessage {
            lines.append("Error: \(error)")
        }
        if !loader.warnings.isEmpty {
            lines.append(contentsOf: loader.warnings.map { "• \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Empty / status states

    private static func drawEmptyState(
        engine: PhrostEngine,
        metrics: RibbonMetrics,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        at position: ImVec2,
        width: Float
    ) {
        let message = engine.ribbonLoader?.errorMessage
            ?? "No ribbon tabs in the definition — edit lisp/ribbon.lsp "
                + "and press Reload."
        ImGuiSetCursorScreenPos(position)
        ImGuiPushStyleColor(Int32(ImGuiCol_Text.rawValue), theme.textDim)
        ImGuiTextV(message)
        ImGuiPopStyleColor(1)
        _ = width
    }

    /// A one-line hint at the very bottom of the window while the definition
    /// has problems (kept out of the way otherwise).
    private static func renderStatusHint(
        loader: RibbonSpecLoader,
        metrics: RibbonMetrics,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) {
        guard loader.status == .failed || !loader.warnings.isEmpty else {
            return
        }
        let text = loader.status == .failed
            ? "Ribbon definition failed to load — previous definition kept "
                + "(hover Reload for details)"
            : "\(loader.warnings.count) ribbon warning(s) — hover Reload"
        let size = ImGuiCalcTextSize(text, nil, false, -1)
        let windowPos = ImGuiGetWindowPos()
        let windowSize = ImGuiGetWindowSize()
        let position = ImVec2(
            x: windowPos.x + windowSize.x - size.x - 6,
            y: windowPos.y + windowSize.y - size.y - 2)
        ImGuiSetCursorScreenPos(position)
        ImGuiPushStyleColor(
            Int32(ImGuiCol_Text.rawValue),
            loader.status == .failed ? theme.dangerBg : theme.textDim)
        ImGuiTextV(text)
        ImGuiPopStyleColor(1)
        _ = metrics
        _ = drawList
    }
}

// =========================================================================
// MARK: - RibbonWidgets
// =========================================================================
//
// Hand-drawn buttons: an `InvisibleButton` for hit-testing plus draw-list
// primitives for the background, icon and label. Using ImGui's own button
// widgets would not give icon-above-label layout, pressed/checked states, or
// per-mode sizing, so the chrome draws itself (same approach as TopChromeUI's
// window controls).

@MainActor
enum RibbonWidgets {

    struct ButtonSpec {
        var id: String
        var label: String
        var rect: RibbonRect
        var enabled: Bool = true
        var checked: Bool = false
        var isLarge: Bool = false
        var showIcon: Bool = false
        var icon: String? = nil
        var iconSize: Float = 0
        var tooltip: String? = nil
        /// Draws a small chevron at the right edge (dropdown/split buttons).
        var drawChevron: Bool = false
    }

    /// Returns true when clicked (and enabled).
    static func button(
        spec: ButtonSpec,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) -> Bool {
        ImGuiSetCursorScreenPos(ImVec2(x: spec.rect.x, y: spec.rect.y))
        let clicked = igInvisibleButton(
            "##\(spec.id)", ImVec2(x: spec.rect.width, y: spec.rect.height), 0)
        let hovered = ImGuiIsItemHovered(0)
        let active = ImGuiIsItemActive()

        let radius: Float = 3
        let min = ImVec2(x: spec.rect.x, y: spec.rect.y)
        let max = ImVec2(
            x: spec.rect.x + spec.rect.width, y: spec.rect.y + spec.rect.height)

        if spec.checked {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(gold(theme.brandGold, alpha: 0.28)),
                radius, 0)
        } else if hovered && spec.enabled {
            ImDrawListAddRectFilled(
                drawList, min, max,
                igGetColorU32_Vec4(theme.hoverBg), radius, 0)
        }
        if active && spec.enabled {
            ImDrawListAddRect(
                drawList, min, max,
                igGetColorU32_Vec4(gold(theme.brandGold, alpha: 0.65)),
                radius, 1.0, 0)
        }

        let color = spec.enabled ? theme.textPrimary : dim(theme.textDim)
        let iconColor = spec.checked
            ? theme.brandGold
            : color

        if spec.showIcon, let iconName = spec.icon, spec.iconSize > 0 {
            if spec.isLarge {
                let iconX = spec.rect.x
                    + (spec.rect.width - spec.iconSize) * 0.5
                let iconY = spec.rect.y + 5
                RibbonIconPainter.draw(
                    name: iconName, drawList: drawList,
                    rect: RibbonRect(
                        x: iconX, y: iconY, width: spec.iconSize,
                        height: spec.iconSize),
                    color: iconColor, fallbackText: spec.label)
                drawCenteredLabel(
                    spec.label, rect: RibbonRect(
                        x: spec.rect.x,
                        y: spec.rect.y + 5 + spec.iconSize + 2,
                        width: spec.rect.width,
                        height: spec.rect.height
                            - spec.iconSize - 9),
                    color: color, drawList: drawList)
            } else {
                RibbonIconPainter.draw(
                    name: iconName, drawList: drawList,
                    rect: RibbonRect(
                        x: spec.rect.x + 6,
                        y: spec.rect.y + (spec.rect.height - spec.iconSize) * 0.5,
                        width: spec.iconSize, height: spec.iconSize),
                    color: iconColor, fallbackText: spec.label)
                drawLeftLabel(
                    spec.label,
                    at: ImVec2(
                        x: spec.rect.x + 6 + spec.iconSize + 6,
                        y: spec.rect.y + (spec.rect.height
                            - ImGuiGetTextLineHeight()) * 0.5),
                    maxWidth: spec.rect.width - spec.iconSize - 18,
                    color: color, drawList: drawList)
            }
        } else {
            drawCenteredLabel(
                spec.label, rect: spec.rect, color: color,
                drawList: drawList)
        }

        if spec.drawChevron {
            let cx = spec.rect.x + spec.rect.width - 8
            let cy = spec.rect.y + spec.rect.height * 0.5
            ImDrawListAddTriangleFilled(
                drawList,
                ImVec2(x: cx - 3, y: cy - 1.5),
                ImVec2(x: cx + 3, y: cy - 1.5),
                ImVec2(x: cx, y: cy + 2.5),
                igGetColorU32_Vec4(color))
        }

        if hovered, let tooltip = spec.tooltip, !tooltip.isEmpty {
            ImGuiBeginTooltip()
            ImGuiTextV(tooltip)
            ImGuiEndTooltip()
        }
        return clicked && spec.enabled
    }

    /// A flat text button with an active underline — used for ribbon tabs and
    /// top-level menu names.
    static func tabButton(
        id: String,
        label: String,
        rect: RibbonRect,
        active: Bool,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) -> Bool {
        flatButton(
            id: id, label: label, rect: rect, active: active, theme: theme,
            drawList: drawList, underline: true)
    }

    static func flatButton(
        id: String,
        label: String,
        rect: RibbonRect,
        active: Bool,
        theme: AppTheme,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        underline: Bool = false
    ) -> Bool {
        ImGuiSetCursorScreenPos(ImVec2(x: rect.x, y: rect.y))
        let clicked = igInvisibleButton(
            "##\(id)", ImVec2(x: rect.width, y: rect.height), 0)
        let hovered = ImGuiIsItemHovered(0)

        if hovered {
            ImDrawListAddRectFilled(
                drawList,
                ImVec2(x: rect.x, y: rect.y),
                ImVec2(x: rect.maxX, y: rect.maxY),
                igGetColorU32_Vec4(theme.hoverBg), 3.0, 0)
        }
        if active && underline {
            ImDrawListAddRectFilled(
                drawList,
                ImVec2(x: rect.x + 4, y: rect.maxY - 2),
                ImVec2(x: rect.maxX - 4, y: rect.maxY),
                igGetColorU32_Vec4(theme.brandGold), 0.0, 0)
        }
        drawCenteredLabel(
            label, rect: rect,
            color: active ? theme.textPrimary : theme.textDim,
            drawList: drawList)
        return clicked
    }

    // MARK: - Drawing helpers

    private static func drawCenteredLabel(
        _ text: String,
        rect: RibbonRect,
        color: ImVec4,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) {
        let size = ImGuiCalcTextSize(text, nil, false, -1)
        let position = ImVec2(
            x: rect.x + (rect.width - size.x) * 0.5,
            y: rect.y + (rect.height - size.y) * 0.5)
        ImDrawListAddText(
            drawList, position, igGetColorU32_Vec4(color), text)
    }

    private static func drawLeftLabel(
        _ text: String,
        at position: ImVec2,
        maxWidth: Float,
        color: ImVec4,
        drawList: UnsafeMutablePointer<ImDrawList>?
    ) {
        var label = text
        if maxWidth > 8, ImGuiCalcTextSize(label, nil, false, -1).x > maxWidth {
            // Trim with an ellipsis rather than spilling into the next button.
            while !label.isEmpty,
                  ImGuiCalcTextSize(label + "...", nil, false, -1).x > maxWidth {
                label.removeLast()
            }
            label += "..."
        }
        ImDrawListAddText(
            drawList, position, igGetColorU32_Vec4(color), label)
    }

    private static func gold(_ color: ImVec4, alpha: Float) -> ImVec4 {
        ImVec4(x: color.x, y: color.y, z: color.z, w: alpha)
    }

    private static func dim(_ color: ImVec4) -> ImVec4 {
        ImVec4(x: color.x, y: color.y, z: color.z, w: color.w * 0.45)
    }
}
