import ZephyrCore
import Foundation
import ImGui

// =========================================================================
// MARK: - RibbonIconPainter
// =========================================================================
//
// Procedural line-art icons for the ribbon. No icon font, no image assets:
// every icon is a handful of ImDrawList primitives in a normalized 0…1 box,
// so it scales with DPI, follows the theme colour, and looks identical on
// every platform.
//
// Names are validated at definition load time against `RibbonIconNames.all`
// (ZephyrCore); an unknown name draws a letter box so an AutoLISP definition
// can never produce an empty button.
//
// Note: this file is deliberately bitmap-free. If a definition wants a
// custom picture later, the painter can consult a texture cache for names it
// does not know — the call site does not change.

@MainActor
enum RibbonIconPainter {

    private typealias Painter = (UnsafeMutablePointer<ImDrawList>?, RibbonRect, ImU32) -> Void

    /// Icon name -> draw routine. Must cover `RibbonIconNames.all`
    /// (asserted by `RibbonIconNamesTests`).
    private static var painters: [String: Painter] {
        [
            // Draw
            "line": line,
            "polyline": polyline,
            "circle": circle,
            "arc": arc,
            "ellipse": ellipse,
            "rect": rect,
            "hatch": hatch,
            "spline": spline,
            "pen": pen,
            "ray": ray,
            "text": textIcon,
            "leader": leader,
            "dim": dimension,
            "table": table,
            "revcloud": revcloud,
            // Modify
            "move": move,
            "copy": copy,
            "rotate": rotate,
            "scale": scale,
            "align": align,
            "erase": erase,
            "trim": trim,
            "fillet": fillet,
            "chamfer": chamfer,
            "offset": offset,
            "array": array,
            "explode": explode,
            "join": join,
            "matchprop": matchprop,
            // Structure / document
            "layers": layers,
            "layer-cur": layerCurrent,
            "block": block,
            "insert": insert,
            "xref": xref,
            "image": image,
            "pdf": pdf,
            // View
            "zoom": zoom,
            "pan": pan,
            "view": view,
            "vport": vport,
            // App / status
            "undo": undo,
            "redo": redo,
            "new": newIcon,
            "open": open,
            "save": save,
            "print": printIcon,
            "props": props,
            "style": style,
            "units": units,
            "grid": grid,
            "ortho": ortho,
            "polar": polar,
            "osnap": osnap,
            "measure": measure,
            "theme": theme,
            "nav": nav,
            // Chrome
            "reload": reload,
            "close": close,
            "pattern": pattern,
            // Layer panel
            "plus": plusIcon,
            "search": search,
            "sort": sortIcon,
            "filter": filterIcon,
            "eye": eye,
            "eye-off": eyeOff,
            "freeze": freeze,
            "thaw": thaw,
            "lock": lock,
            "unlock": unlock,
            "no-plot": noPlot,
            "vp-freeze": vpFreeze,
            "vp-thaw": vpThaw,
            "color-drop": colorDrop,
            "linetype": linetypeIcon,
            "lineweight": lineweightIcon,
            "transparency": transparencyIcon,
            "trash": trash,
            "walk": walk,
            "select": selectIcon,
            "more": moreIcon,
            "check": checkIcon,
            "chevron-down": chevronDown,
        ]
    }

    /// Draws `name` into `rect`. Unknown names fall back to a letter box.
    static func draw(
        name: String,
        drawList: UnsafeMutablePointer<ImDrawList>?,
        rect: RibbonRect,
        color: ImVec4,
        fallbackText: String
    ) {
        let col = igGetColorU32_Vec4(color)
        if let painter = painters[name.lowercased()] {
            painter(drawList, rect, col)
        } else {
            letterBox(drawList, rect, col, fallbackText)
        }
    }

    static func isImplemented(_ name: String) -> Bool {
        painters[name.lowercased()] != nil
    }

    // MARK: - Primitives

    private static func point(_ rect: RibbonRect, _ x: Float, _ y: Float) -> ImVec2 {
        ImVec2(x: rect.x + x * rect.width, y: rect.y + y * rect.height)
    }

    private static func stroke(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        _ rect: RibbonRect,
        _ color: ImU32,
        _ points: [(Float, Float)],
        closed: Bool = false,
        thickness: Float? = nil
    ) {
        guard points.count >= 2 else { return }
        let width = thickness ?? max(rect.width * 0.075, 1.0)
        for index in 0..<(points.count - 1) {
            ImDrawListAddLine(
                drawList,
                point(rect, points[index].0, points[index].1),
                point(rect, points[index + 1].0, points[index + 1].1),
                color, width)
        }
        if closed, let first = points.first, let last = points.last {
            ImDrawListAddLine(
                drawList, point(rect, last.0, last.1),
                point(rect, first.0, first.1), color, width)
        }
    }

    private static func outline(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        _ rect: RibbonRect,
        _ color: ImU32,
        x0: Float, y0: Float, x1: Float, y1: Float,
        filled: Bool = false,
        rounding: Float = 0
    ) {
        let minimum = point(rect, x0, y0)
        let maximum = point(rect, x1, y1)
        let thickness = Swift.max(rect.width * 0.075, 1.0)
        if filled {
            ImDrawListAddRectFilled(
                drawList, minimum, maximum, color, rounding, 0)
        } else {
            ImDrawListAddRect(
                drawList, minimum, maximum, color, rounding, thickness, 0)
        }
    }

    private static func dot(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        _ rect: RibbonRect,
        _ color: ImU32,
        x: Float, y: Float, radius: Float = 0.055
    ) {
        ImDrawListAddCircleFilled(
            drawList, point(rect, x, y),
            max(radius * rect.width, 1.0), color, 8)
    }

    private static func circlePath(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        _ rect: RibbonRect,
        _ color: ImU32,
        centerX: Float, centerY: Float, radius: Float,
        filled: Bool = false, thickness: Float? = nil
    ) {
        let center = point(rect, centerX, centerY)
        let r = radius * min(rect.width, rect.height)
        let width = thickness ?? max(rect.width * 0.075, 1.0)
        if filled {
            ImDrawListAddCircleFilled(drawList, center, r, color, 0)
        } else {
            ImDrawListAddCircle(drawList, center, r, color, 0, width)
        }
    }

    private static func arcPath(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        _ rect: RibbonRect,
        _ color: ImU32,
        centerX: Float, centerY: Float, radius: Float,
        from: Float, to: Float
    ) {
        let center = point(rect, centerX, centerY)
        let r = radius * min(rect.width, rect.height)
        ImDrawListPathArcTo(drawList, center, r, from, to, 0)
        ImDrawListPathStroke(
            drawList, color, max(rect.width * 0.075, 1.0), 0)
    }

    private static func arrowHead(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        _ rect: RibbonRect,
        _ color: ImU32,
        tipX: Float, tipY: Float,
        directionX: Float, directionY: Float,
        size: Float = 0.14
    ) {
        // Two short strokes from the tip, rotated +/- 25 degrees off the
        // incoming direction.
        let length = sqrt(directionX * directionX + directionY * directionY)
        guard length > 0 else { return }
        let ux = directionX / length
        let uy = directionY / length
        let angle = atan2(uy, ux)
        for delta in [Float.pi * 0.78, -Float.pi * 0.78] {
            let ax = cos(angle + delta) * size
            let ay = sin(angle + delta) * size
            ImDrawListAddLine(
                drawList, point(rect, tipX, tipY),
                point(rect, tipX + ax, tipY + ay),
                color, max(rect.width * 0.075, 1.0))
        }
    }

    private static func letterBox(
        _ drawList: UnsafeMutablePointer<ImDrawList>?,
        _ rect: RibbonRect,
        _ color: ImU32,
        _ text: String
    ) {
        outline(
            drawList, rect, color, x0: 0.12, y0: 0.12, x1: 0.88, y1: 0.88,
            rounding: 2)
        guard let letter = text.first(where: { $0.isLetter || $0.isNumber })
        else { return }
        let text = String(letter).uppercased()
        let size = ImGuiCalcTextSize(text, nil, false, -1)
        ImDrawListAddText(
            drawList,
            ImVec2(
                x: rect.x + (rect.width - size.x) * 0.5,
                y: rect.y + (rect.height - size.y) * 0.5),
            color, text)
    }

    // MARK: - Draw icons

    private static func line(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.15, 0.8), (0.85, 0.2)])
        dot(dl, r, c, x: 0.15, y: 0.8, radius: 0.07)
        dot(dl, r, c, x: 0.85, y: 0.2, radius: 0.07)
    }

    private static func polyline(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        let points: [(Float, Float)] = [
            (0.1, 0.75), (0.4, 0.25), (0.65, 0.7), (0.9, 0.3),
        ]
        stroke(dl, r, c, points)
        for point in points { dot(dl, r, c, x: point.0, y: point.1, radius: 0.05) }
    }

    private static func circle(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        circlePath(dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.34)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.05)
    }

    private static func arc(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        arcPath(
            dl, r, c, centerX: 0.5, centerY: 0.72, radius: 0.42,
            from: Float.pi, to: Float.pi * 2)
        dot(dl, r, c, x: 0.5, y: 0.72, radius: 0.05)
    }

    private static func ellipse(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        ImDrawListAddEllipse(
            dl, point(r, 0.5, 0.5),
            ImVec2(x: r.width * 0.42, y: r.height * 0.26),
            c, 0, 32, max(r.width * 0.075, 1.0))
    }

    private static func rect(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.14, y0: 0.22, x1: 0.86, y1: 0.78)
        dot(dl, r, c, x: 0.14, y: 0.22, radius: 0.05)
        dot(dl, r, c, x: 0.86, y: 0.78, radius: 0.05)
    }

    private static func hatch(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.12, y0: 0.14, x1: 0.88, y1: 0.86)
        stroke(dl, r, c, [(0.2, 0.8), (0.8, 0.2)], thickness: 0.9)
        stroke(dl, r, c, [(0.2, 0.55), (0.55, 0.2)], thickness: 0.9)
        stroke(dl, r, c, [(0.45, 0.8), (0.8, 0.45)], thickness: 0.9)
    }

    private static func pattern(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.12, y0: 0.14, x1: 0.88, y1: 0.86)
        stroke(dl, r, c, [(0.12, 0.5), (0.88, 0.5)], thickness: 0.9)
        stroke(dl, r, c, [(0.5, 0.14), (0.5, 0.86)], thickness: 0.9)
        stroke(dl, r, c, [(0.2, 0.8), (0.8, 0.2)], thickness: 0.9)
    }

    private static func spline(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        ImDrawListAddBezierCubic(
            dl, point(r, 0.1, 0.75), point(r, 0.3, 0.1),
            point(r, 0.7, 0.95), point(r, 0.9, 0.3),
            c, max(r.width * 0.075, 1.0), 0)
        dot(dl, r, c, x: 0.1, y: 0.75, radius: 0.05)
        dot(dl, r, c, x: 0.9, y: 0.3, radius: 0.05)
    }

    private static func pen(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [
            (0.28, 0.78), (0.3, 0.44), (0.56, 0.18), (0.68, 0.3),
            (0.42, 0.56), (0.28, 0.78),
        ])
        stroke(dl, r, c, [(0.3, 0.44), (0.42, 0.56)])
    }

    private static func ray(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        dot(dl, r, c, x: 0.18, y: 0.7, radius: 0.07)
        stroke(dl, r, c, [(0.18, 0.7), (0.9, 0.28)])
        arrowHead(dl, r, c, tipX: 0.9, tipY: 0.28, directionX: 1, directionY: -0.58)
    }

    private static func textIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.18, 0.82), (0.5, 0.16)])
        stroke(dl, r, c, [(0.5, 0.16), (0.82, 0.82)])
        stroke(dl, r, c, [(0.32, 0.56), (0.68, 0.56)])
    }

    private static func leader(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.16, 0.3), (0.4, 0.62), (0.86, 0.46)])
        arrowHead(dl, r, c, tipX: 0.16, tipY: 0.3, directionX: -1, directionY: -1.3)
        stroke(dl, r, c, [(0.4, 0.62), (0.86, 0.78)])
    }

    private static func dimension(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.14, 0.5), (0.86, 0.5)])
        arrowHead(dl, r, c, tipX: 0.14, tipY: 0.5, directionX: 1, directionY: 0)
        arrowHead(dl, r, c, tipX: 0.86, tipY: 0.5, directionX: -1, directionY: 0)
        stroke(dl, r, c, [(0.14, 0.24), (0.14, 0.76)], thickness: 0.9)
        stroke(dl, r, c, [(0.86, 0.24), (0.86, 0.76)], thickness: 0.9)
    }

    private static func table(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.12, y0: 0.18, x1: 0.88, y1: 0.82)
        stroke(dl, r, c, [(0.12, 0.39), (0.88, 0.39)], thickness: 0.9)
        stroke(dl, r, c, [(0.12, 0.61), (0.88, 0.61)], thickness: 0.9)
        stroke(dl, r, c, [(0.39, 0.18), (0.39, 0.82)], thickness: 0.9)
        stroke(dl, r, c, [(0.63, 0.18), (0.63, 0.82)], thickness: 0.9)
    }

    private static func revcloud(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        let bumps: [(Float, Float)] = [
            (0.3, 0.3), (0.5, 0.22), (0.7, 0.3), (0.8, 0.5),
            (0.7, 0.7), (0.5, 0.78), (0.3, 0.7), (0.2, 0.5),
        ]
        for (index, bump) in bumps.enumerated() {
            ImDrawListAddCircle(
                dl, point(r, bump.0, bump.1),
                r.width * 0.13, c, 0, max(r.width * 0.06, 0.9))
            if index == 0 {
                dot(dl, r, c, x: 0.2, y: 0.5, radius: 0.03)
            }
        }
    }

    // MARK: - Modify icons

    private static func move(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.5, 0.12), (0.5, 0.88)])
        stroke(dl, r, c, [(0.12, 0.5), (0.88, 0.5)])
        arrowHead(dl, r, c, tipX: 0.5, tipY: 0.12, directionX: 0, directionY: -1)
        arrowHead(dl, r, c, tipX: 0.5, tipY: 0.88, directionX: 0, directionY: 1)
        arrowHead(dl, r, c, tipX: 0.12, tipY: 0.5, directionX: -1, directionY: 0)
        arrowHead(dl, r, c, tipX: 0.88, tipY: 0.5, directionX: 1, directionY: 0)
    }

    private static func copy(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.12, y0: 0.12, x1: 0.6, y1: 0.6)
        outline(dl, r, c, x0: 0.4, y0: 0.4, x1: 0.88, y1: 0.88)
    }

    private static func rotate(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        arcPath(
            dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.34,
            from: -Float.pi * 0.35, to: Float.pi * 1.15)
        arrowHead(
            dl, r, c, tipX: 0.79, tipY: 0.3,
            directionX: 0.9, directionY: -0.5)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.05)
    }

    private static func scale(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.14, y0: 0.54, x1: 0.46, y1: 0.86)
        outline(dl, r, c, x0: 0.5, y0: 0.14, x1: 0.86, y1: 0.5)
        stroke(dl, r, c, [(0.36, 0.64), (0.64, 0.36)])
        arrowHead(dl, r, c, tipX: 0.64, tipY: 0.36, directionX: 1, directionY: -1)
    }

    private static func align(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.14, 0.14), (0.14, 0.86)])
        outline(dl, r, c, x0: 0.3, y0: 0.22, x1: 0.86, y1: 0.44)
        outline(dl, r, c, x0: 0.3, y0: 0.56, x1: 0.7, y1: 0.78)
    }

    private static func erase(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.2, 0.62), (0.56, 0.24), (0.82, 0.46), (0.46, 0.84), (0.2, 0.62)])
        stroke(dl, r, c, [(0.38, 0.44), (0.64, 0.66)])
        stroke(dl, r, c, [(0.62, 0.84), (0.9, 0.84)])
    }

    private static func trim(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.1, 0.72), (0.72, 0.34)])
        stroke(dl, r, c, [(0.5, 0.16), (0.5, 0.84)], thickness: 0.9)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.06)
        dot(dl, r, c, x: 0.72, y: 0.34, radius: 0.05)
    }

    private static func fillet(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.16, 0.18), (0.16, 0.62)])
        arcPath(
            dl, r, c, centerX: 0.5, centerY: 0.62, radius: 0.34,
            from: Float.pi, to: Float.pi * 1.5)
        stroke(dl, r, c, [(0.5, 0.96), (0.86, 0.96)])
    }

    private static func chamfer(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.16, 0.18), (0.16, 0.62), (0.5, 0.9), (0.86, 0.9)])
        stroke(dl, r, c, [(0.52, 0.42), (0.84, 0.42)], thickness: 0.8)
    }

    private static func offset(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.14, y0: 0.24, x1: 0.7, y1: 0.76, rounding: 2)
        outline(dl, r, c, x0: 0.26, y0: 0.36, x1: 0.86, y1: 0.88, rounding: 2)
    }

    private static func array(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        for row in 0..<2 {
            for column in 0..<3 {
                let x = 0.12 + Float(column) * 0.28
                let y = 0.16 + Float(row) * 0.38
                outline(dl, r, c, x0: x, y0: y, x1: x + 0.18, y1: y + 0.24)
            }
        }
    }

    private static func explode(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.38, y0: 0.38, x1: 0.62, y1: 0.62)
        let directions: [(Float, Float)] = [
            (0.1, 0.1), (0.9, 0.1), (0.1, 0.9), (0.9, 0.9),
        ]
        for direction in directions {
            let sx: Float = direction.0 < 0.5 ? 0.38 : 0.62
            let sy: Float = direction.1 < 0.5 ? 0.38 : 0.62
            stroke(dl, r, c, [(sx, sy), direction], thickness: 0.9)
        }
    }

    private static func join(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.1, 0.28), (0.5, 0.7)])
        stroke(dl, r, c, [(0.9, 0.28), (0.5, 0.7)])
        dot(dl, r, c, x: 0.5, y: 0.7, radius: 0.07)
        stroke(dl, r, c, [(0.5, 0.7), (0.5, 0.92)])
    }

    private static func matchprop(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.42, y0: 0.44, x1: 0.86, y1: 0.68, rounding: 2)
        stroke(dl, r, c, [(0.42, 0.56), (0.14, 0.56)])
        stroke(dl, r, c, [(0.24, 0.16), (0.24, 0.56)])
        dot(dl, r, c, x: 0.24, y: 0.14, radius: 0.06)
    }

    // MARK: - Structure icons

    private static func layers(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.5, 0.12), (0.88, 0.32), (0.5, 0.52), (0.12, 0.32)], closed: true)
        stroke(dl, r, c, [(0.12, 0.5), (0.5, 0.7), (0.88, 0.5)], thickness: 0.9)
        stroke(dl, r, c, [(0.12, 0.68), (0.5, 0.88), (0.88, 0.68)], thickness: 0.9)
    }

    private static func layerCurrent(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.5, 0.1), (0.85, 0.3), (0.5, 0.5), (0.15, 0.3)], closed: true)
        stroke(dl, r, c, [(0.15, 0.52), (0.5, 0.72), (0.85, 0.52)], thickness: 0.9)
        dot(dl, r, c, x: 0.5, y: 0.88, radius: 0.08)
    }

    private static func block(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        // Isometric cube.
        stroke(dl, r, c, [(0.5, 0.12), (0.88, 0.34), (0.88, 0.7), (0.5, 0.92), (0.12, 0.7), (0.12, 0.34)], closed: true)
        stroke(dl, r, c, [(0.12, 0.34), (0.5, 0.56), (0.88, 0.34)], thickness: 0.9)
        stroke(dl, r, c, [(0.5, 0.56), (0.5, 0.92)], thickness: 0.9)
    }

    private static func insert(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.44, 0.1), (0.78, 0.3), (0.78, 0.62), (0.44, 0.82), (0.1, 0.62), (0.1, 0.3)], closed: true)
        stroke(dl, r, c, [(0.1, 0.3), (0.44, 0.48), (0.78, 0.3)], thickness: 0.9)
        stroke(dl, r, c, [(0.44, 0.48), (0.44, 0.82)], thickness: 0.9)
        stroke(dl, r, c, [(0.62, 0.72), (0.94, 0.72)])
        stroke(dl, r, c, [(0.78, 0.56), (0.78, 0.88)])
    }

    private static func xref(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.1, y0: 0.3, x1: 0.48, y1: 0.72)
        outline(dl, r, c, x0: 0.52, y0: 0.16, x1: 0.9, y1: 0.5)
        stroke(dl, r, c, [(0.48, 0.5), (0.62, 0.56)])
        arrowHead(dl, r, c, tipX: 0.62, tipY: 0.56, directionX: 1, directionY: 0.3)
    }

    private static func image(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.1, y0: 0.2, x1: 0.9, y1: 0.8)
        stroke(dl, r, c, [(0.1, 0.7), (0.36, 0.44), (0.56, 0.64)], thickness: 0.9)
        stroke(dl, r, c, [(0.46, 0.54), (0.62, 0.38), (0.9, 0.66)], thickness: 0.9)
        dot(dl, r, c, x: 0.7, y: 0.34, radius: 0.055)
    }

    private static func pdf(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.2, 0.1), (0.6, 0.1), (0.8, 0.3), (0.8, 0.9), (0.2, 0.9)], closed: true)
        stroke(dl, r, c, [(0.6, 0.1), (0.6, 0.3), (0.8, 0.3)], thickness: 0.9)
        stroke(dl, r, c, [(0.32, 0.6), (0.68, 0.6)], thickness: 0.9)
        stroke(dl, r, c, [(0.32, 0.74), (0.6, 0.74)], thickness: 0.9)
    }

    // MARK: - View icons

    private static func zoom(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        circlePath(dl, r, c, centerX: 0.44, centerY: 0.42, radius: 0.28)
        stroke(dl, r, c, [(0.64, 0.62), (0.9, 0.88)])
        stroke(dl, r, c, [(0.32, 0.42), (0.56, 0.42)], thickness: 0.9)
        stroke(dl, r, c, [(0.44, 0.3), (0.44, 0.54)], thickness: 0.9)
    }

    private static func pan(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.24, y0: 0.42, x1: 0.76, y1: 0.88, rounding: 3)
        for index in 0..<3 {
            let x = 0.34 + Float(index) * 0.16
            stroke(dl, r, c, [(x, 0.42), (x, 0.16)], thickness: 0.9)
        }
        stroke(dl, r, c, [(0.24, 0.52), (0.1, 0.42)], thickness: 0.9)
    }

    private static func view(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.5, 0.12), (0.88, 0.34), (0.88, 0.68), (0.5, 0.9), (0.12, 0.68), (0.12, 0.34)], closed: true)
        stroke(dl, r, c, [(0.12, 0.34), (0.5, 0.55), (0.88, 0.34)], thickness: 0.9)
    }

    private static func vport(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.1, y0: 0.16, x1: 0.9, y1: 0.84)
        stroke(dl, r, c, [(0.5, 0.16), (0.5, 0.84)], thickness: 0.9)
        stroke(dl, r, c, [(0.1, 0.5), (0.9, 0.5)], thickness: 0.9)
    }

    // MARK: - App icons

    private static func undo(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        arcPath(
            dl, r, c, centerX: 0.52, centerY: 0.56, radius: 0.3,
            from: -Float.pi * 0.9, to: Float.pi * 0.35)
        arrowHead(dl, r, c, tipX: 0.52, tipY: 0.26, directionX: -1, directionY: 0.5)
        stroke(dl, r, c, [(0.5, 0.86), (0.74, 0.86)], thickness: 0.9)
    }

    private static func redo(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        arcPath(
            dl, r, c, centerX: 0.48, centerY: 0.56, radius: 0.3,
            from: -Float.pi * 0.35, to: Float.pi * 0.9)
        arrowHead(dl, r, c, tipX: 0.48, tipY: 0.26, directionX: 1, directionY: 0.5)
        stroke(dl, r, c, [(0.26, 0.86), (0.5, 0.86)], thickness: 0.9)
    }

    private static func newIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.16, 0.1), (0.56, 0.1), (0.72, 0.28), (0.72, 0.9), (0.16, 0.9)], closed: true)
        stroke(dl, r, c, [(0.56, 0.1), (0.56, 0.28), (0.72, 0.28)], thickness: 0.9)
        stroke(dl, r, c, [(0.78, 0.62), (0.98, 0.62)], thickness: 0.9)
        stroke(dl, r, c, [(0.88, 0.52), (0.88, 0.72)], thickness: 0.9)
    }

    private static func open(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.1, 0.82), (0.1, 0.24), (0.4, 0.24), (0.48, 0.36), (0.86, 0.36), (0.86, 0.82)], closed: true)
        stroke(dl, r, c, [(0.24, 0.82), (0.44, 0.5), (0.96, 0.5)], thickness: 0.9)
    }

    private static func save(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.14, y0: 0.14, x1: 0.86, y1: 0.86)
        outline(dl, r, c, x0: 0.32, y0: 0.14, x1: 0.68, y1: 0.4, filled: false)
        outline(dl, r, c, x0: 0.28, y0: 0.56, x1: 0.72, y1: 0.86)
    }

    private static func printIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.28, y0: 0.12, x1: 0.72, y1: 0.36)
        outline(dl, r, c, x0: 0.12, y0: 0.36, x1: 0.88, y1: 0.66)
        outline(dl, r, c, x0: 0.3, y0: 0.58, x1: 0.7, y1: 0.88)
        dot(dl, r, c, x: 0.76, y: 0.46, radius: 0.04)
    }

    private static func props(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        for index in 0..<3 {
            let y = 0.26 + Float(index) * 0.24
            stroke(dl, r, c, [(0.14, y), (0.86, y)], thickness: 0.9)
            let knobX: Float = index == 0 ? 0.36 : (index == 1 ? 0.66 : 0.48)
            dot(dl, r, c, x: knobX, y: y, radius: 0.075)
        }
    }

    private static func style(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.16, 0.74), (0.44, 0.16)])
        stroke(dl, r, c, [(0.44, 0.16), (0.72, 0.74)])
        stroke(dl, r, c, [(0.28, 0.5), (0.6, 0.5)])
        stroke(dl, r, c, [(0.78, 0.5), (0.94, 0.5)], thickness: 0.9)
        stroke(dl, r, c, [(0.86, 0.26), (0.86, 0.74)], thickness: 0.9)
    }

    private static func units(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.08, y0: 0.8, x1: 0.92, y1: 0.92)
        for index in 0..<5 {
            let x = 0.18 + Float(index) * 0.16
            stroke(dl, r, c, [(x, 0.8), (x, 0.62)], thickness: 0.9)
        }
        stroke(dl, r, c, [(0.3, 0.8), (0.3, 0.44)], thickness: 0.9)
        stroke(dl, r, c, [(0.38, 0.8), (0.38, 0.5)], thickness: 0.9)
    }

    private static func grid(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.1, y0: 0.16, x1: 0.9, y1: 0.84)
        for index in 1..<3 {
            let x = 0.1 + Float(index) * 0.266
            let y = 0.16 + Float(index) * 0.226
            stroke(dl, r, c, [(x, 0.16), (x, 0.84)], thickness: 0.7)
            stroke(dl, r, c, [(0.1, y), (0.9, y)], thickness: 0.7)
        }
    }

    private static func ortho(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.16, 0.84), (0.16, 0.28), (0.84, 0.28)])
        ImDrawListAddRect(
            dl, point(r, 0.16, 0.44), point(r, 0.3, 0.58), c, 0, 0.7, 0)
    }

    private static func polar(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        circlePath(dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.34)
        for angle in stride(from: Float(0), to: Float.pi * 2, by: Float.pi / 4) {
            let x = 0.5 + cos(angle) * 0.34
            let y = 0.5 + sin(angle) * 0.34
            dot(dl, r, c, x: x, y: y, radius: 0.04)
        }
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.06)
    }

    private static func osnap(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.32, y0: 0.32, x1: 0.68, y1: 0.68)
        stroke(dl, r, c, [(0.5, 0.1), (0.5, 0.32)], thickness: 0.9)
        stroke(dl, r, c, [(0.5, 0.68), (0.5, 0.9)], thickness: 0.9)
        stroke(dl, r, c, [(0.1, 0.5), (0.32, 0.5)], thickness: 0.9)
        stroke(dl, r, c, [(0.68, 0.5), (0.9, 0.5)], thickness: 0.9)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.07)
    }

    private static func measure(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.12, 0.78), (0.78, 0.12), (0.88, 0.22), (0.22, 0.88)], closed: true)
        for index in 1..<4 {
            let t = Float(index) * 0.2
            let sx = 0.12 + (0.78 - 0.12) * t
            let sy = 0.78 + (0.12 - 0.78) * t
            stroke(dl, r, c, [(sx, sy), (sx + 0.07, sy + 0.07)], thickness: 0.7)
        }
    }

    private static func theme(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        circlePath(dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.34)
        // Half-filled disc: sun/moon contrast.
        ImDrawListPathArcTo(dl, point(r, 0.5, 0.5), r.width * 0.34, -Float.pi / 2, Float.pi / 2, 0)
        ImDrawListPathStroke(dl, c, max(r.width * 0.14, 1.4), 0)
    }

    private static func reload(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        arcPath(
            dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.32,
            from: -Float.pi * 0.4, to: Float.pi * 1.4)
        arrowHead(
            dl, r, c, tipX: 0.76, tipY: 0.36,
            directionX: 0.8, directionY: 0.6)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.045)
    }

    private static func close(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.24, 0.24), (0.76, 0.76)])
        stroke(dl, r, c, [(0.76, 0.24), (0.24, 0.76)])
    }

    private static func nav(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        circlePath(dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.36)
        stroke(dl, r, c, [(0.34, 0.66), (0.62, 0.4)])
        arrowHead(dl, r, c, tipX: 0.66, tipY: 0.34, directionX: 1, directionY: -1)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.045)
    }

    // MARK: - Layer panel icons

    private static func plusIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.5, 0.16), (0.5, 0.84)])
        stroke(dl, r, c, [(0.16, 0.5), (0.84, 0.5)])
    }

    private static func search(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        circlePath(dl, r, c, centerX: 0.42, centerY: 0.42, radius: 0.26)
        stroke(dl, r, c, [(0.62, 0.62), (0.88, 0.88)])
    }

    private static func sortIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.12, 0.24), (0.62, 0.24)], thickness: 0.9)
        stroke(dl, r, c, [(0.12, 0.5), (0.5, 0.5)], thickness: 0.9)
        stroke(dl, r, c, [(0.12, 0.76), (0.38, 0.76)], thickness: 0.9)
        stroke(dl, r, c, [(0.8, 0.18), (0.8, 0.7)])
        arrowHead(dl, r, c, tipX: 0.8, tipY: 0.84, directionX: 0, directionY: 1)
    }

    private static func filterIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.14, 0.16), (0.86, 0.16), (0.62, 0.46), (0.62, 0.82), (0.42, 0.72), (0.42, 0.46)], closed: true)
    }

    private static func eye(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        ImDrawListAddEllipse(
            dl, point(r, 0.5, 0.5),
            ImVec2(x: r.width * 0.4, y: r.height * 0.24),
            c, 0, 24, max(r.width * 0.075, 1.0))
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.1)
    }

    private static func eyeOff(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        eye(dl, r, c)
        stroke(dl, r, c, [(0.16, 0.84), (0.84, 0.16)])
    }

    private static func freeze(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.5, 0.1), (0.5, 0.9)], thickness: 0.9)
        stroke(dl, r, c, [(0.16, 0.3), (0.84, 0.7)], thickness: 0.9)
        stroke(dl, r, c, [(0.84, 0.3), (0.16, 0.7)], thickness: 0.9)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.05)
    }

    private static func thaw(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        circlePath(dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.18)
        for angle in stride(from: Float(0), to: Float.pi * 2, by: Float.pi / 4) {
            let x0 = 0.5 + cos(angle) * 0.28
            let y0 = 0.5 + sin(angle) * 0.28
            let x1 = 0.5 + cos(angle) * 0.4
            let y1 = 0.5 + sin(angle) * 0.4
            stroke(dl, r, c, [(x0, y0), (x1, y1)], thickness: 0.9)
        }
    }

    private static func lock(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.2, y0: 0.46, x1: 0.8, y1: 0.88, rounding: 2)
        arcPath(dl, r, c, centerX: 0.5, centerY: 0.46, radius: 0.2,
                from: Float.pi, to: Float.pi * 2)
        dot(dl, r, c, x: 0.5, y: 0.66, radius: 0.07)
    }

    private static func unlock(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.2, y0: 0.46, x1: 0.8, y1: 0.88, rounding: 2)
        arcPath(dl, r, c, centerX: 0.44, centerY: 0.46, radius: 0.2,
                from: Float.pi, to: Float.pi * 1.6)
        dot(dl, r, c, x: 0.5, y: 0.66, radius: 0.07)
    }

    private static func noPlot(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        printIcon(dl, r, c)
        stroke(dl, r, c, [(0.14, 0.88), (0.86, 0.12)])
    }

    private static func vpFreeze(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.12, y0: 0.16, x1: 0.88, y1: 0.84)
        stroke(dl, r, c, [(0.5, 0.28), (0.5, 0.72)], thickness: 0.8)
        stroke(dl, r, c, [(0.32, 0.4), (0.68, 0.6)], thickness: 0.8)
        stroke(dl, r, c, [(0.68, 0.4), (0.32, 0.6)], thickness: 0.8)
    }

    private static func vpThaw(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.12, y0: 0.16, x1: 0.88, y1: 0.84)
        circlePath(dl, r, c, centerX: 0.5, centerY: 0.5, radius: 0.14)
        dot(dl, r, c, x: 0.5, y: 0.32, radius: 0.035)
        dot(dl, r, c, x: 0.5, y: 0.68, radius: 0.035)
    }

    private static func colorDrop(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.5, 0.1), (0.28, 0.52)], thickness: 0.9)
        stroke(dl, r, c, [(0.5, 0.1), (0.72, 0.52)], thickness: 0.9)
        arcPath(dl, r, c, centerX: 0.5, centerY: 0.54, radius: 0.25,
                from: Float.pi * 0.05, to: Float.pi * 0.95)
        dot(dl, r, c, x: 0.44, y: 0.62, radius: 0.05)
    }

    private static func linetypeIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.1, 0.3), (0.9, 0.3)])
        stroke(dl, r, c, [(0.1, 0.56), (0.34, 0.56)])
        stroke(dl, r, c, [(0.5, 0.56), (0.74, 0.56)])
        dot(dl, r, c, x: 0.84, y: 0.56, radius: 0.045)
        dot(dl, r, c, x: 0.18, y: 0.8, radius: 0.045)
        dot(dl, r, c, x: 0.42, y: 0.8, radius: 0.045)
        stroke(dl, r, c, [(0.58, 0.8), (0.9, 0.8)])
    }

    private static func lineweightIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.12, 0.24), (0.88, 0.24)], thickness: max(r.width * 0.04, 0.8))
        stroke(dl, r, c, [(0.12, 0.5), (0.88, 0.5)], thickness: max(r.width * 0.1, 1.2))
        stroke(dl, r, c, [(0.12, 0.78), (0.88, 0.78)], thickness: max(r.width * 0.18, 1.8))
    }

    private static func transparencyIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        outline(dl, r, c, x0: 0.16, y0: 0.16, x1: 0.5, y1: 0.84, filled: true)
        outline(dl, r, c, x0: 0.5, y0: 0.16, x1: 0.84, y1: 0.84)
        stroke(dl, r, c, [(0.5, 0.5), (0.84, 0.5)], thickness: 0.7)
        stroke(dl, r, c, [(0.67, 0.16), (0.67, 0.84)], thickness: 0.7)
    }

    private static func trash(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.14, 0.24), (0.86, 0.24)])
        stroke(dl, r, c, [(0.4, 0.24), (0.42, 0.12), (0.58, 0.12), (0.6, 0.24)], thickness: 0.9)
        stroke(dl, r, c, [(0.22, 0.24), (0.28, 0.88), (0.72, 0.88), (0.78, 0.24)])
        stroke(dl, r, c, [(0.42, 0.4), (0.44, 0.72)], thickness: 0.8)
        stroke(dl, r, c, [(0.58, 0.4), (0.56, 0.72)], thickness: 0.8)
    }

    private static func walk(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        dot(dl, r, c, x: 0.18, y: 0.8, radius: 0.05)
        dot(dl, r, c, x: 0.36, y: 0.64, radius: 0.05)
        dot(dl, r, c, x: 0.52, y: 0.5, radius: 0.05)
        circlePath(dl, r, c, centerX: 0.72, centerY: 0.3, radius: 0.16)
        dot(dl, r, c, x: 0.72, y: 0.3, radius: 0.045)
    }

    private static func selectIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.34, 0.22), (0.88, 0.22)], thickness: 0.9)
        stroke(dl, r, c, [(0.34, 0.5), (0.88, 0.5)], thickness: 0.9)
        stroke(dl, r, c, [(0.34, 0.78), (0.74, 0.78)], thickness: 0.9)
        stroke(dl, r, c, [(0.1, 0.22), (0.16, 0.3), (0.26, 0.14)])
        stroke(dl, r, c, [(0.1, 0.5), (0.16, 0.58), (0.26, 0.42)])
    }

    private static func moreIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        dot(dl, r, c, x: 0.24, y: 0.5, radius: 0.08)
        dot(dl, r, c, x: 0.5, y: 0.5, radius: 0.08)
        dot(dl, r, c, x: 0.76, y: 0.5, radius: 0.08)
    }

    private static func checkIcon(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.14, 0.54), (0.4, 0.8), (0.86, 0.2)])
    }

    private static func chevronDown(
        _ dl: UnsafeMutablePointer<ImDrawList>?, _ r: RibbonRect, _ c: ImU32
    ) {
        stroke(dl, r, c, [(0.18, 0.34), (0.5, 0.68), (0.82, 0.34)])
    }
}
