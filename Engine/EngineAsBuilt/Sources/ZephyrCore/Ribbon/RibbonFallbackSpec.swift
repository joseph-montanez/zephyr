import Foundation

// =========================================================================
// MARK: - Ribbon fallback spec
// =========================================================================
//
// The ribbon is never empty: this built-in model renders before the first
// AutoLISP load completes, when no definition file exists at all, and while
// a broken definition is being fixed (the loader keeps the last good model,
// and falls back to this one when there has never been a good load).
//
// It is deliberately tiny — the shipped `lisp/ribbon.lsp` is the real
// default, and whoever wants more edits that file, not this one.

public enum RibbonFallbackSpec {
    public static func make() -> RibbonSpec {
        RibbonSpec(
            menus: [
                RibbonMenu(
                    title: "File",
                    items: [
                        command("NEW", "New", "new"),
                        command("OPEN", "Open...", "open"),
                        .separator,
                        command("SAVE", "Save", "save"),
                        command("SAVEAS", "Save As...", "save"),
                    ]),
                RibbonMenu(
                    title: "Edit",
                    items: [
                        command("UNDO", "Undo", "undo", enabled: [.undoAvailable]),
                        command("REDO", "Redo", "redo", enabled: [.redoAvailable]),
                        .separator,
                        command(
                            "ERASE", "Erase", "erase",
                            enabled: [.selectionAtLeast(1)]),
                    ]),
                RibbonMenu(
                    title: "View",
                    items: [
                        command("ZOOMEXTENTS", "Zoom Extents", "zoom"),
                        command(
                            "GRID", "Grid: %GRIDMODE%", "grid",
                            checked: [.variableEquals(name: "GRIDMODE", value: .int(1))]),
                    ]),
            ],
            tabs: [
                RibbonTab(
                    title: "Home",
                    panels: [
                        RibbonPanel(
                            title: "Draw",
                            items: [
                                command("LINE", "Line", "line", size: .large),
                                command("POLYLINE", "Polyline", "polyline", size: .large),
                                command("CIRCLE", "Circle", "circle", size: .small),
                                command("ARC", "Arc", "arc", size: .small),
                                command("RECTANGLE", "Rectangle", "rect", size: .small),
                                command("ELLIPSE", "Ellipse", "ellipse", size: .small),
                                command("HATCH", "Hatch", "hatch", size: .small),
                                command("PATTERN", "Pattern", "pattern", size: .small),
                            ]),
                        RibbonPanel(
                            title: "Modify",
                            items: [
                                command(
                                    "MOVE", "Move", "move", size: .large),
                                command(
                                    "ERASE", "Erase", "erase", size: .large),
                                command(
                                    "TRIM", "Trim", "trim"),
                                command("OFFSET", "Offset", "offset"),
                                command("ARRAY", "Array", "array"),
                            ]),
                    ]),
            ])
    }

    private static func command(
        _ name: String,
        _ label: String,
        _ icon: String,
        size: RibbonCommand.Size = .small,
        enabled: [RibbonPredicate] = [],
        checked: [RibbonPredicate] = []
    ) -> RibbonItem {
        .command(
            RibbonCommand(
                command: name,
                label: label,
                icon: icon,
                size: size,
                enabled: enabled,
                checked: checked))
    }
}
