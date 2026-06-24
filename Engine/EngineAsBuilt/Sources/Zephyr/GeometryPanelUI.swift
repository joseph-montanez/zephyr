import ZephyrCore
import Foundation
import ImGui

// MARK: - GeometryPanelUI
//
// Renders an expandable "Geometry" section inside the Properties panel
// showing resolved CAD primitives for a selected entity. Displays:
//   - Total primitive count and breakdown by type
//   - Tree view of individual primitives (up to 100 shown)
//   - Detailed coordinates, dimensions, colors, and angles for each primitive
//
// This is an inspector/debugging panel for understanding the low-level
// rendering data behind complex DXF entities like hatches, splines, and blocks.

@MainActor
struct GeometryPanelUI {
    /// Renders the geometry breakdown for a list of resolved CAD primitives.
    /// Shows counts by type, and a tree of individual primitives with details.
    /// - Parameter geometry: Array of CADPrimitive enums from entity resolution.
    static func render(geometry: [CADPrimitive]) {
        guard ImGuiCollapsingHeader("Geometry", Int32(ImGuiTreeNodeFlags_DefaultOpen.rawValue)) else {
            return
        }

        ImGuiTextV("Primitives: \(geometry.count)")

        // Build a summary like "Line: 5, Circle: 2, Arc: 1"
        var typeCounts: [String: Int] = [:]
        for prim in geometry {
            typeCounts[typeName(for: prim), default: 0] += 1
        }

        let summary = typeCounts.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        ImGuiTextV(summary)

        // Cap at 100 primitives to avoid overwhelming the UI with huge lists.
        let maxDetails = min(geometry.count, 100)
        if maxDetails < geometry.count {
            ImGuiTextV("(showing first \(maxDetails) of \(geometry.count) primitives)")
        }

        for i in 0..<maxDetails {
            let prim = geometry[i]
            let item = detail(for: prim, index: i)

            if ImGuiTreeNodeEx(item.label, Int32(ImGuiTreeNodeFlags_Leaf.rawValue)) {
                ImGuiTextV(item.detail)
                ImGuiTreePop()
            }
        }

        igSeparator()
    }

    /// Returns a human-readable type name for a CADPrimitive case.
    private static func typeName(for prim: CADPrimitive) -> String {
        switch prim {
        case .point: return "Point"
        case .line: return "Line"
        case .rect: return "Rect"
        case .fillRect: return "FillRect"
        case .polygon: return "Polygon"
        case .polyline: return "Polyline"
        case .fillPolygon: return "FillPolygon"
        case .fillComplexPolygon: return "ComplexPoly"
        case .gradient: return "Gradient"
        case .circle: return "Circle"
        case .arc: return "Arc"
        case .spline: return "Spline"
        case .text: return "Text"
        case .ellipse: return "Ellipse"
        case .hatch: return "Hatch"
        case .ray: return "Ray"
        case .image: return "Image"
        }
    }

    /// Returns a (label, detail) tuple describing a single primitive.
    /// Detail includes formatted coordinates, dimensions, angles, and colors.
    private static func detail(for prim: CADPrimitive, index i: Int) -> (label: String, detail: String) {
        switch prim {
        case .point(let pos, let color):
            return (
                "Point #\(i)",
                "(\(String(format: "%.2f", pos.x)), \(String(format: "%.2f", pos.y)))  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .line(let start, let end, let color):
            return (
                "Line #\(i)",
                "(\(String(format: "%.2f", start.x)), \(String(format: "%.2f", start.y))) \u{2192} (\(String(format: "%.2f", end.x)), \(String(format: "%.2f", end.y)))  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .rect(let origin, let size, let color):
            return (
                "Rect #\(i)",
                "origin (\(String(format: "%.2f", origin.x)), \(String(format: "%.2f", origin.y)))  \(String(format: "%.2f", size.x))\u{00D7}\(String(format: "%.2f", size.y))  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .fillRect(let origin, let size, let color):
            return (
                "FillRect #\(i)",
                "origin (\(String(format: "%.2f", origin.x)), \(String(format: "%.2f", origin.y)))  \(String(format: "%.2f", size.x))\u{00D7}\(String(format: "%.2f", size.y))  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .polygon(let pts, let color):
            return ("Polygon #\(i)", "\(pts.count) vertices  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")")

        case .polyline(let pts, let color):
            return ("Polyline #\(i)", "\(pts.count) vertices  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")")

        case .fillPolygon(let pts, let color):
            return ("FillPolygon #\(i)", "\(pts.count) vertices  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")")

        case .fillComplexPolygon(let outer, let holes, let color):
            return (
                "ComplexPoly #\(i)",
                "outer: \(outer.count) vertices, holes: \(holes.count)  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .gradient(let outer, let holes, let gradName, let angle, let c1, let c2):
            return (
                "Gradient #\(i)",
                "\(gradName)  \(String(format: "%.1f", angle * 180 / .pi))\u{00B0}  \(UIFormatting.colorStr(c1)) \u{2192} \(UIFormatting.colorStr(c2))  outer: \(outer.count) verts, holes: \(holes.count)"
            )

        case .circle(let center, let radius, let color):
            return (
                "Circle #\(i)",
                "center (\(String(format: "%.2f", center.x)), \(String(format: "%.2f", center.y)))  r=\(String(format: "%.2f", radius))  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .arc(let center, let radius, let startAngle, let endAngle, let color):
            let sa = startAngle * 180.0 / .pi
            let ea = endAngle * 180.0 / .pi
            return (
                "Arc #\(i)",
                "center (\(String(format: "%.2f", center.x)), \(String(format: "%.2f", center.y)))  r=\(String(format: "%.2f", radius))  \(String(format: "%.1f", sa))\u{00B0}\u{2013}\(String(format: "%.1f", ea))\u{00B0}  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .spline(let controlPoints, _, let degree, let weights, let color):
            let wLabel = weights != nil ? "rational" : "non-rational"
            return (
                "Spline #\(i)",
                "degree=\(degree)  \(wLabel)  \(controlPoints.count) control pts  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .text(_, let text, let height, let rotation, let style, let alignH, let alignV, _, let color):
            let preview = text.count > 40 ? String(text.prefix(40)) + "..." : text
            let styleStr = style ?? "\u{2014}"
            return (
                "Text #\(i)",
                "\"\(preview)\"  h=\(String(format: "%.2f", height))  rot=\(String(format: "%.1f", rotation * 180 / .pi))\u{00B0}  style=\(styleStr)  align=(\(alignH),\(alignV))  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .ellipse(let center, let majorAxis, let minorRatio, let color):
            let majorLen = majorAxis.magnitude
            let rot = atan2(majorAxis.y, majorAxis.x) * 180.0 / .pi
            return (
                "Ellipse #\(i)",
                "center (\(String(format: "%.2f", center.x)), \(String(format: "%.2f", center.y)))  major=\(String(format: "%.2f", majorLen))  ratio=\(String(format: "%.3f", minorRatio))  rot=\(String(format: "%.1f", rot))\u{00B0}  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .hatch(let boundary, let pattern, let scale, let angle, let color):
            return (
                "Hatch #\(i)",
                "boundary: \(boundary.count) pts  pattern=\(pattern.isEmpty ? "SOLID" : pattern)  scale=\(String(format: "%.2f", scale))  angle=\(String(format: "%.1f", angle))\u{00B0}  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )

        case .ray(let start, let direction, let color):
            let angle = atan2(direction.y, direction.x) * 180.0 / .pi
            return (
                "Ray #\(i)",
                "start (\(String(format: "%.2f", start.x)), \(String(format: "%.2f", start.y)))  dir=\(String(format: "%.1f", angle))\u{00B0}  \(color.map { UIFormatting.colorStr($0) } ?? "\u{2014}")"
            )
        case .image(_, let uAxis, let vAxis, let imageName, _, _):
            let w = uAxis.magnitude
            let h = vAxis.magnitude
            return (
                "Image #\(i)",
                "name=\(imageName.prefix(16))...  (\(String(format: "%.2f", w))×\(String(format: "%.2f", h)))"
            )
        }
    }
}
