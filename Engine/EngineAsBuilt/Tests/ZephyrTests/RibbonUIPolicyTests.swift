import XCTest
import ZephyrLisp
@testable import ZephyrCore

private extension RibbonItem {
    /// Command name for assertions (nil for separators/dropdowns).
    var commandName: String? {
        if case let .command(command) = self { return command.command }
        return nil
    }
}

/// Layout and live-state policy tests: the pixel math and predicate rules
/// that are painful to check by eye, pinned headlessly.
final class RibbonUIPolicyTests: XCTestCase {

    // MARK: - Display mode cycle

    func testModeCycleOrder() {
        XCTAssertEqual(RibbonDisplayMode.menu.next, .labels)
        XCTAssertEqual(RibbonDisplayMode.labels.next, .full)
        XCTAssertEqual(RibbonDisplayMode.full.next, .menu)
        XCTAssertEqual(
            RibbonDisplayMode.next(after: .full), .menu,
            "the cycle must close: full -> menu")
    }

    func testThreeCyclesReturnToStart() {
        var mode = RibbonDisplayMode.menu
        for _ in 0..<3 { mode = mode.next }
        XCTAssertEqual(mode, .menu)
    }

    func testModeFlags() {
        XCTAssertTrue(RibbonDisplayMode.menu.isMenuBar)
        XCTAssertFalse(RibbonDisplayMode.menu.isRibbon)
        XCTAssertFalse(RibbonDisplayMode.menu.showsIcons)

        XCTAssertTrue(RibbonDisplayMode.labels.isRibbon)
        XCTAssertFalse(RibbonDisplayMode.labels.showsIcons)

        XCTAssertTrue(RibbonDisplayMode.full.isRibbon)
        XCTAssertTrue(RibbonDisplayMode.full.showsIcons)
    }

    func testModeRawValuesRoundTripThroughSettings() {
        for mode in RibbonDisplayMode.allCases {
            XCTAssertEqual(
                RibbonDisplayMode(rawValue: mode.rawValue), mode)
        }
        XCTAssertNil(RibbonDisplayMode(rawValue: "gigantic"))
    }

    // MARK: - Metrics

    func testFullModeIsTallestAndMenuShortest() {
        let menu = RibbonMetrics(mode: .menu, frameHeight: 22)
        let labels = RibbonMetrics(mode: .labels, frameHeight: 22)
        let full = RibbonMetrics(mode: .full, frameHeight: 22)

        XCTAssertLessThan(menu.contentHeight, labels.contentHeight)
        XCTAssertLessThan(labels.contentHeight, full.contentHeight)
        XCTAssertEqual(menu.contentHeight, menu.menuRowHeight, accuracy: 0.001)
    }

    func testLabelsModePacksAPanelIntoASingleRow() {
        let metrics = RibbonMetrics(mode: .labels, frameHeight: 22)
        let panel = RibbonPanel(
            title: "Draw",
            items: [
                command("LINE", .large),
                command("POLYLINE", .large),
                command("CIRCLE", .small),
                command("ARC", .small),
                command("RECTANGLE", .small),
                .separator,
                command("ELLIPSE", .small),
            ])
        let layout = RibbonUIPolicy.layout(panel: panel, metrics: metrics)
        XCTAssertEqual(layout.columns.count, 1, "labels mode is one horizontal run")
        XCTAssertEqual(layout.columns[0].placements.count, 7)
        XCTAssertEqual(layout.bodyHeight, metrics.panelBodyHeight, accuracy: 0.001)
        // Placed strictly left to right, in authored order.
        let xs = layout.columns[0].placements.map(\.rect.x)
        XCTAssertEqual(xs, xs.sorted())
        XCTAssertEqual(layout.columns[0].placements.map(\.item.commandName),
                       ["LINE", "POLYLINE", "CIRCLE", "ARC", "RECTANGLE", nil, "ELLIPSE"])
    }

    func testMetricsScaleWithFrameHeight() {
        let small = RibbonMetrics(mode: .full, frameHeight: 22)
        let large = RibbonMetrics(mode: .full, frameHeight: 44)
        XCTAssertGreaterThan(large.largeButtonWidth, small.largeButtonWidth)
        XCTAssertGreaterThan(large.contentHeight, small.contentHeight)
        XCTAssertLessThan(large.scale, 2.1)
        XCTAssertGreaterThan(large.scale, 1.9)
    }

    func testLabelsModeButtonsAreShorterThanFullMode() {
        let labels = RibbonMetrics(mode: .labels, frameHeight: 22)
        let full = RibbonMetrics(mode: .full, frameHeight: 22)
        XCTAssertGreaterThan(full.largeButtonHeight, labels.largeButtonHeight)
        XCTAssertFalse(labels.showsIcons)
        XCTAssertTrue(full.showsIcons)
    }

    func testPanelBodyAccommodatesASmallStack() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        XCTAssertGreaterThanOrEqual(metrics.panelBodyHeight, metrics.smallStackHeight)
        XCTAssertGreaterThanOrEqual(metrics.panelBodyHeight, metrics.largeButtonHeight)
    }

    // MARK: - Fitted outer height (dock tab bar / title bar)

    func testFittedHeightAddsTopInsetAndBottomPadding() {
        // The regression: a visible dock tab bar (or floating title
        // bar) lives inside the outer rect above the content, so the
        // outer height must grow by that bar or the bottom row clips.
        let metrics = RibbonMetrics(mode: .menu, frameHeight: 22)
        let padding: Float = 3
        let tabBar: Float = 24
        XCTAssertEqual(
            metrics.fittedHeight(
                topInset: padding + tabBar, bottomPaddingY: padding),
            metrics.contentHeight + tabBar + padding * 2,
            accuracy: 0.001)
        // No bar showing: the inset is just the top padding and the
        // fitted height collapses to the classic content + 2×padding.
        XCTAssertEqual(
            metrics.fittedHeight(
                topInset: padding, bottomPaddingY: padding),
            metrics.windowHeight(windowPaddingY: padding),
            accuracy: 0.001)
    }

    func testFittedHeightForMenuModeKeepsTheWholeRow() {
        // Menu mode is a single row: with a tab bar on top, the old
        // content+padding sizing left roughly half the row visible.
        let metrics = RibbonMetrics(mode: .menu, frameHeight: 22)
        let fitted = metrics.fittedHeight(
            topInset: 27, bottomPaddingY: 3)
        XCTAssertGreaterThanOrEqual(
            fitted - 27 - 3, metrics.menuRowHeight,
            "the space between inset and bottom padding must fit the row")
    }

    func testFittedHeightClampsNegativeInsets() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        XCTAssertEqual(
            metrics.fittedHeight(topInset: -10, bottomPaddingY: -4),
            metrics.contentHeight, accuracy: 0.001)
    }

    func testTopInsetClampsAtZero() {
        XCTAssertEqual(
            RibbonUIPolicy.topInset(contentTop: 130, windowTop: 100),
            30, accuracy: 0.001)
        XCTAssertEqual(
            RibbonUIPolicy.topInset(contentTop: 90, windowTop: 100),
            0, accuracy: 0.001)
    }

    // MARK: - Panel layout

    private func command(
        _ name: String, _ size: RibbonCommand.Size
    ) -> RibbonItem {
        .command(RibbonCommand(command: name, label: name, size: size))
    }

    func testLargeItemsShareOneRowAndSmallsStackInThrees() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let panel = RibbonPanel(
            title: "Draw",
            items: [
                command("LINE", .large),
                command("POLYLINE", .large),
                command("CIRCLE", .small),
                command("ARC", .small),
                command("RECTANGLE", .small),
                command("ELLIPSE", .small),
            ])
        let layout = RibbonUIPolicy.layout(panel: panel, metrics: metrics)

        // 1 large row + 3 smalls + 1 remaining small = 3 columns.
        XCTAssertEqual(layout.columns.count, 3)
        XCTAssertEqual(
            layout.columns[0].placements.count, 2, "large items share a row")
        XCTAssertEqual(layout.columns[1].placements.count, 3)
        XCTAssertEqual(layout.columns[2].placements.count, 1)

        // Large row width = 2 buttons + 1 gap.
        let expected = metrics.largeButtonWidth * 2 + metrics.itemGap
        XCTAssertEqual(layout.columns[0].rect.width, expected, accuracy: 0.001)
        XCTAssertEqual(layout.columns[0].rect.height, metrics.largeButtonHeight,
                       accuracy: 0.001)

        // Panels of one tab share a body height.
        XCTAssertEqual(layout.bodyHeight, metrics.panelBodyHeight, accuracy: 0.001)
        // Title sits under the body, full panel width.
        XCTAssertEqual(layout.titleRect.width, layout.width, accuracy: 0.001)
        XCTAssertEqual(
            layout.titleRect.y, metrics.panelPadding + layout.bodyHeight,
            accuracy: 0.001)
        XCTAssertEqual(
            layout.height,
            metrics.panelPadding * 2 + layout.bodyHeight + metrics.panelTitleHeight,
            accuracy: 0.001)
    }

    func testSeparatorBecomesAFullHeightDividerColumn() throws {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let panel = RibbonPanel(
            title: "Mixed",
            items: [
                command("LINE", .large),
                .separator,
                command("MOVE", .large),
            ])
        let layout = RibbonUIPolicy.layout(panel: panel, metrics: metrics)
        XCTAssertEqual(layout.columns.count, 3)
        let divider = layout.columns[1]
        XCTAssertEqual(divider.rect.width, metrics.separatorWidth, accuracy: 0.001)
        XCTAssertEqual(divider.placements.first?.item, .separator)
        let dividerHeight = try XCTUnwrap(divider.placements.first?.rect.height)
        XCTAssertEqual(dividerHeight, layout.bodyHeight, accuracy: 0.001)
    }

    func testDropdownOccupiesASmallSlot() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let panel = RibbonPanel(
            title: "Draw",
            items: [
                .dropdown(
                    RibbonDropdown(
                        label: "More", items: [command("HATCH", .small)])),
                command("LINE", .small),
                command("ARC", .small),
                command("JOIN", .small),
            ])
        let layout = RibbonUIPolicy.layout(panel: panel, metrics: metrics)
        // Dropdown + 2 smalls fill the first stack, JOIN spills to a second.
        XCTAssertEqual(layout.columns.count, 2)
        XCTAssertEqual(layout.columns[0].placements.count, 3)
        XCTAssertEqual(layout.columns[1].placements.count, 1)
        guard case .dropdown = layout.columns[0].placements[0].item else {
            return XCTFail("dropdown must be placed as the first item")
        }
    }

    func testPanelWidthIsSumOfColumnsPlusPadding() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let panel = RibbonPanel(
            title: "P",
            items: [command("LINE", .large), command("MOVE", .large)])
        let layout = RibbonUIPolicy.layout(panel: panel, metrics: metrics)
        XCTAssertEqual(
            layout.width,
            metrics.largeButtonWidth * 2 + metrics.itemGap
                + metrics.panelPadding * 2,
            accuracy: 0.001)
    }

    func testEmptyPanelStillHasValidGeometry() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let layout = RibbonUIPolicy.layout(
            panel: RibbonPanel(title: "Empty", items: []), metrics: metrics)
        XCTAssertEqual(layout.columns.count, 0)
        XCTAssertEqual(layout.width, metrics.panelPadding * 2, accuracy: 0.001)
        XCTAssertGreaterThan(layout.height, 0)
    }

    // MARK: - Overflow

    func testOverflowHidesPanelsThatDoNotFit() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let panels = (0..<3).map { index in
            RibbonUIPolicy.layout(
                panel: RibbonPanel(
                    title: "P\(index)",
                    items: [command("LINE", .large)]),
                metrics: metrics)
        }
        let onePanel = panels[0].width
        // Room for two panels plus the overflow button's reserved gutter.
        let available = onePanel * 2 + metrics.panelGap * 2
            + metrics.overflowButtonWidth + 2
        let overflow = RibbonUIPolicy.split(
            panels: panels, availableWidth: available, metrics: metrics)

        XCTAssertEqual(overflow.visible.count, 2)
        XCTAssertEqual(overflow.hidden.count, 1)
        XCTAssertTrue(overflow.showsOverflowButton)
        XCTAssertLessThanOrEqual(overflow.usedWidth, available)
    }

    func testOverflowKeepsEverythingWhenItFits() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let panels = (0..<2).map { index in
            RibbonUIPolicy.layout(
                panel: RibbonPanel(
                    title: "P\(index)", items: [command("LINE", .large)]),
                metrics: metrics)
        }
        let overflow = RibbonUIPolicy.split(
            panels: panels, availableWidth: 10_000, metrics: metrics)
        XCTAssertEqual(overflow.visible.count, 2)
        XCTAssertTrue(overflow.hidden.isEmpty)
        XCTAssertFalse(overflow.showsOverflowButton)
    }

    func testOverflowDegradesToNothingWhenWidthIsTiny() {
        let metrics = RibbonMetrics(mode: .full, frameHeight: 22)
        let panels = [
            RibbonUIPolicy.layout(
                panel: RibbonPanel(title: "P", items: [command("LINE", .large)]),
                metrics: metrics)
        ]
        let overflow = RibbonUIPolicy.split(
            panels: panels, availableWidth: 20, metrics: metrics)
        XCTAssertTrue(overflow.visible.isEmpty)
        XCTAssertEqual(overflow.hidden.count, 1)
    }

    // MARK: - Predicates

    private func context(
        selection: Int = 0,
        command: String? = nil,
        undo: Bool = false,
        redo: Bool = false,
        dirty: Bool = false,
        tabs: Int = 1,
        vars: [String: LispValue] = [:]
    ) -> RibbonStateContext {
        RibbonStateContext(
            selectionCount: selection,
            activeCommand: command,
            canUndo: undo,
            canRedo: redo,
            isDirty: dirty,
            tabCount: tabs,
            variables: vars)
    }

    func testSelectionPredicate() {
        XCTAssertFalse(
            RibbonUIPolicy.evaluate(.selectionAtLeast(1), in: context()))
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(.selectionAtLeast(1), in: context(selection: 1)))
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(.selectionAtLeast(3), in: context(selection: 5)))
    }

    func testCommandPredicates() {
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(.noActiveCommand, in: context()))
        XCTAssertFalse(
            RibbonUIPolicy.evaluate(.noActiveCommand, in: context(command: "TRIM")))
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(
                .activeCommand("TRIM"), in: context(command: "TRIM")))
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(
                .activeCommand("trim"), in: context(command: "TRIM")),
            "command comparison must be case-insensitive")
        XCTAssertFalse(
            RibbonUIPolicy.evaluate(
                .activeCommand("MOVE"), in: context(command: "TRIM")))
    }

    func testHistoryAndDocumentPredicates() {
        XCTAssertTrue(RibbonUIPolicy.evaluate(.undoAvailable, in: context(undo: true)))
        XCTAssertFalse(RibbonUIPolicy.evaluate(.redoAvailable, in: context(undo: true)))
        XCTAssertTrue(RibbonUIPolicy.evaluate(.redoAvailable, in: context(redo: true)))
        XCTAssertTrue(RibbonUIPolicy.evaluate(.documentDirty, in: context(dirty: true)))
        XCTAssertTrue(RibbonUIPolicy.evaluate(.tabCountAtLeast(2), in: context(tabs: 2)))
        XCTAssertFalse(RibbonUIPolicy.evaluate(.tabCountAtLeast(2), in: context(tabs: 1)))
    }

    func testVariablePredicateCoercesNumbers() {
        let vars = ["GRIDMODE": LispValue.int(1)]
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(
                .variableEquals(name: "GRIDMODE", value: .int(1)),
                in: context(vars: vars)))
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(
                .variableEquals(name: "GRIDMODE", value: .real(1.0)),
                in: context(vars: vars)),
            "an AutoLISP expression may produce a real where the file says 1")
        XCTAssertFalse(
            RibbonUIPolicy.evaluate(
                .variableEquals(name: "GRIDMODE", value: .int(0)),
                in: context(vars: vars)))
        // Unknown sysvar: never true (a typo must not read as "on").
        XCTAssertFalse(
            RibbonUIPolicy.evaluate(
                .variableEquals(name: "NOPE", value: .int(1)),
                in: context(vars: vars)))
    }

    func testVariablePredicateComparesStringsCaseInsensitively() {
        let vars = ["CLAYER": LispValue.string("Walls")]
        XCTAssertTrue(
            RibbonUIPolicy.evaluate(
                .variableEquals(name: "CLAYER", value: .string("walls")),
                in: context(vars: vars)))
        XCTAssertFalse(
            RibbonUIPolicy.evaluate(
                .variableEquals(name: "CLAYER", value: .string("Doors")),
                in: context(vars: vars)))
    }

    func testEnabledRequiresAllPredicates() {
        let command = RibbonCommand(
            command: "MOVE",
            enabled: [.selectionAtLeast(1), .noActiveCommand])
        XCTAssertFalse(RibbonUIPolicy.isEnabled(command, in: context()))
        XCTAssertTrue(
            RibbonUIPolicy.isEnabled(command, in: context(selection: 2)))
        XCTAssertFalse(
            RibbonUIPolicy.isEnabled(
                command, in: context(selection: 2, command: "TRIM")))
        // No predicates: always enabled.
        XCTAssertTrue(
            RibbonUIPolicy.isEnabled(
                RibbonCommand(command: "LINE"), in: context()))
    }

    func testCheckedRequiresAPredicateAndAllHolding() {
        let toggle = RibbonCommand(
            command: "GRID",
            checked: [.variableEquals(name: "GRIDMODE", value: .int(1))])
        XCTAssertTrue(
            RibbonUIPolicy.isChecked(
                toggle, in: context(vars: ["GRIDMODE": .int(1)])))
        XCTAssertFalse(
            RibbonUIPolicy.isChecked(
                toggle, in: context(vars: ["GRIDMODE": .int(0)])))
        // A command with no `check` option is never rendered pressed.
        XCTAssertFalse(
            RibbonUIPolicy.isChecked(
                RibbonCommand(command: "LINE"), in: context()))
    }

    func testItemEnabledHelper() {
        let item = RibbonItem.command(
            RibbonCommand(command: "ERASE", enabled: [.selectionAtLeast(1)]))
        XCTAssertFalse(RibbonUIPolicy.isEnabled(item, in: context()))
        XCTAssertTrue(RibbonUIPolicy.isEnabled(item, in: context(selection: 1)))
        // Non-command items are always "enabled" (dropdowns open either way).
        XCTAssertTrue(
            RibbonUIPolicy.isEnabled(
                .dropdown(RibbonDropdown(label: "More", items: [])),
                in: context()))
    }

    // MARK: - Interpolation

    func testInterpolateSubstitutesKnownVariables() {
        let ctx = context(vars: [
            "CLAYER": .string("Walls"),
            "GRIDMODE": .int(1),
        ])
        XCTAssertEqual(
            RibbonText.interpolate("Layer: %CLAYER%", in: ctx), "Layer: Walls")
        XCTAssertEqual(
            RibbonText.interpolate("%GRIDMODE%", in: ctx), "1")
        XCTAssertEqual(
            RibbonText.interpolate("%CLAYER% - %GRIDMODE%", in: ctx),
            "Walls - 1")
    }

    func testInterpolateIsCaseInsensitiveForNames() {
        let ctx = context(vars: ["CLAYER": .string("Walls")])
        XCTAssertEqual(
            RibbonText.interpolate("%clayer%", in: ctx), "Walls")
    }

    func testInterpolateLeavesUnknownTokensVisible() {
        // A typo must be obvious in the UI, not silently blank.
        XCTAssertEqual(
            RibbonText.interpolate("Layer: %CLAYERR%", in: context()),
            "Layer: %CLAYERR%")
    }

    func testInterpolatePassesPlainLabelsThrough() {
        XCTAssertEqual(
            RibbonText.interpolate("Polyline", in: context()), "Polyline")
        XCTAssertEqual(RibbonText.interpolate("100% sure", in: context()),
                       "100% sure")
        XCTAssertEqual(RibbonText.interpolate("50%", in: context()), "50%")
    }

    func testTokensListsNamesUppercased() {
        XCTAssertEqual(
            RibbonText.tokens(in: "Layer: %clayer% of %DWGNAME%"),
            ["CLAYER", "DWGNAME"])
        XCTAssertEqual(RibbonText.tokens(in: "no tokens"), [])
        XCTAssertEqual(RibbonText.tokens(in: "trailing %"), [])
    }

    // MARK: - Referenced variables

    func testReferencedVariablesCollectsLabelsAndPredicates() {
        let spec = RibbonSpec(
            menus: [
                RibbonMenu(
                    title: "View",
                    items: [
                        .command(
                            RibbonCommand(
                                command: "GRID",
                                label: "Grid: %GRIDMODE%",
                                checked: [
                                    .variableEquals(name: "GRIDMODE", value: .int(1))
                                ]))
                    ])
            ],
            tabs: [
                RibbonTab(
                    title: "Home",
                    panels: [
                        RibbonPanel(
                            title: "Layers",
                            items: [
                                .command(
                                    RibbonCommand(
                                        command: "LA",
                                        label: "Layer: %CLAYER%"))
                            ])
                    ])
            ])

        XCTAssertEqual(
            RibbonUIPolicy.referencedVariables(in: spec),
            ["CLAYER", "GRIDMODE"])
    }

    func testReferencedVariablesIncludesDropdownLabels() {
        let spec = RibbonSpec(tabs: [
            RibbonTab(
                title: "Home",
                panels: [
                    RibbonPanel(
                        title: "P",
                        items: [
                            .dropdown(
                                RibbonDropdown(
                                    label: "Mode: %CLAYER%",
                                    items: [
                                        .command(RibbonCommand(command: "LINE"))
                                    ]))
                        ])
                ])
        ])
        XCTAssertEqual(
            RibbonUIPolicy.referencedVariables(in: spec), ["CLAYER"])
    }

    // MARK: - Spec helpers

    func testResolvedTabIDFallsBackToFirstTab() {
        let spec = RibbonFallbackSpec.make()
        XCTAssertEqual(spec.resolvedTabID(requested: nil), "Home")
        XCTAssertEqual(spec.resolvedTabID(requested: "Nope"), "Home")
        XCTAssertEqual(spec.resolvedTabID(requested: "Home"), "Home")
        XCTAssertNil(RibbonSpec().resolvedTabID(requested: nil))
    }

    func testFallbackSpecIsRenderableAndReferencesKnownIcons() {
        let spec = RibbonFallbackSpec.make()
        XCTAssertFalse(spec.isEmpty)
        XCTAssertFalse(spec.tabs.isEmpty)
        XCTAssertFalse(spec.menus.isEmpty)
        for tab in spec.tabs {
            for panel in tab.panels {
                for item in panel.items {
                    guard case let .command(command) = item else { continue }
                    XCTAssertTrue(
                        RibbonIconNames.isKnown(command.resolvedIconName),
                        "fallback uses unknown icon \(command.resolvedIconName)")
                }
            }
        }
    }
}
