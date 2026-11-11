import Foundation

// =========================================================================
// MARK: - Ribbon icon names
// =========================================================================
//
// The set of icon names the procedural painter (`Sources/Zephyr/RibbonIcon.swift`)
// can draw. It lives in ZephyrCore so the parser can validate an AutoLISP
// definition without importing the app target: an explicit `(zr-big … "x" …)`
// that names an unknown icon still renders (letter-box fallback) but produces
// a load-time warning naming it.
//
// Adding an icon: add the name here and its draw routine to `RibbonIconPainter`
// (the two lists must match exactly — RibbonShippedDefinitionTests covers the
// names a definition actually references).

public enum RibbonIconNames {
    /// Every drawable icon name, lowercase.
    public static let all: Set<String> = [
        // Draw
        "line", "polyline", "circle", "arc", "ellipse", "rect", "hatch", "pattern",
        "spline", "pen", "ray", "text", "leader", "dim", "table", "revcloud",
        // Modify
        "move", "copy", "rotate", "scale", "align", "erase", "trim",
        "fillet", "chamfer", "offset", "array", "explode", "join", "matchprop",
        // Structure / document
        "layers", "layer-cur", "block", "insert", "xref", "image", "pdf",
        // View
        "zoom", "pan", "view", "vport",
        // App / status
        "undo", "redo", "new", "open", "save", "print",
        "props", "style", "units", "grid", "ortho", "polar", "osnap",
        "measure", "theme", "nav",
        // Chrome
        "reload", "close",
        // Layer panel
        "plus", "search", "sort", "filter", "eye", "eye-off",
        "freeze", "thaw", "lock", "unlock", "no-plot",
        "vp-freeze", "vp-thaw", "color-drop", "linetype", "lineweight",
        "transparency", "trash", "walk", "select", "more", "check",
        "chevron-down",
        // Blocks palette
        "pin",
    ]

    /// Icon names that only exist as aliases of a canvas name, so a
    /// command-derived icon (`POLYLINE` -> `polyline`) always resolves.
    public static func isKnown(_ name: String) -> Bool {
        all.contains(name.lowercased())
    }
}
