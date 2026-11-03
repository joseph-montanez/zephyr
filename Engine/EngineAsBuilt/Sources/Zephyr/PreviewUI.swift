import ZephyrCore
import Foundation
import ImGui

/// Live plot preview (`PREVIEW`, step 23): full-window WYSIWYG sheet using
/// the same `PaperSheetGeometry` as the canvas overlay and the Page Setup
/// Partial Preview — no PDFium rasterization. Fit/zoom buttons, drag to
/// pan, Esc to return.
@MainActor
struct PreviewUI {
    private static var settings = CADPlotSettings()
    private static var zoom: Float = 1
    private static var panX: Double = 0
    private static var panY: Double = 0
    private static var lastMouse: ImVec2? = nil
    private static var message = ""

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        if let snapshot = engine.ui.previewSettings {
            if snapshot != settings {
                settings = snapshot
                zoom = 1
                panX = 0
                panY = 0
                lastMouse = nil
                message = ""
            }
        } else {
            message = "PREVIEW needs an active view with paper size."
        }
        let width: Float = min(900, dw - 60)
        let height: Float = min(700, dh - 60)
        ImGuiSetNextWindowPos(
            ImVec2(x: (dw - width) * 0.5, y: (dh - height) * 0.5),
            Int32(ImGuiCond_Always.rawValue),
            ImVec2(x: 0, y: 0))
        ImGuiSetNextWindowSize(ImVec2(x: width, y: height), Int32(ImGuiCond_Always.rawValue))

        var opened = true
        let flags = Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)
            | Int32(ImGuiWindowFlags_NoCollapse.rawValue)
        guard igBegin("Preview##PlotPreview", &opened, flags) else {
            ImGuiEnd()
            return
        }
        defer { ImGuiEnd() }
        if !opened {
            engine.ui.previewActive = false
            return
        }

        if igButton("Zoom In", ImVec2(x: 80, y: 0)) { zoom = min(zoom * 1.25, 32) }
        ImGuiSameLine(0, 8)
        if igButton("Zoom Out", ImVec2(x: 80, y: 0)) { zoom = max(zoom / 1.25, 0.1) }
        ImGuiSameLine(0, 8)
        if igButton("Fit", ImVec2(x: 60, y: 0)) { zoom = 1; panX = 0; panY = 0 }
        ImGuiSameLine(0, 8)
        ImGuiTextV(String(format: "%.0f%%", zoom * 100))
        ImGuiSameLine(0, 8)
        if igButton("Close", ImVec2(x: 80, y: 0)) {
            engine.ui.previewActive = false
            return
        }
        if !message.isEmpty {
            ImGuiTextWrappedV(message)
            if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
                engine.ui.previewActive = false
            }
            return
        }

        if igBeginChild_Str("##PreviewCanvas", ImVec2(x: -1, y: -1), 1, 0) {
            renderCanvas()
        }
        igEndChild()

        if ImGuiIsKeyPressed(ImGuiKey_Escape, false) {
            engine.ui.previewActive = false
        }
    }

    private static func renderCanvas() {
        guard let rects = PaperSheetGeometry.overlayRects(for: settings) else {
            ImGuiTextV("No paper size in these plot settings.")
            return
        }
        let avail = ImGuiGetContentRegionAvail()
        let origin = ImGuiGetCursorScreenPos()
        let sheetW = rects.paper.maxX - rects.paper.minX
        let sheetH = rects.paper.maxY - rects.paper.minY
        guard sheetW > 0, sheetH > 0 else { return }
        let fit = min((Double(avail.x) - 40) / sheetW, (Double(avail.y) - 40) / sheetH)
        let s = fit * Double(zoom)
        // Center + pan (pan stored in paper units, converted at draw time).
        let cx = Double(origin.x) + Double(avail.x) / 2
        let cy = Double(origin.y) + Double(avail.y) / 2
        func pt(_ wx: Double, _ wy: Double) -> ImVec2 {
            // Paper space is Y-up relative to the sheet; screen is Y-down.
            ImVec2(x: Float(cx + ((wx - (rects.paper.minX + rects.paper.maxX) / 2) + panX) * s),
                   y: Float(cy - ((wy - (rects.paper.minY + rects.paper.maxY) / 2) + panY) * s))
        }
        // Drag to pan (track mouse while the canvas button is active).
        _ = igInvisibleButton("##PreviewPan", ImVec2(x: avail.x, y: avail.y), 0)
        if igIsItemActive() {
            let mouse = ImGuiGetMousePos()
            if let last = lastMouse {
                panX -= Double(mouse.x - last.x) / s
                panY += Double(mouse.y - last.y) / s
            }
            lastMouse = mouse
        } else {
            lastMouse = nil
        }
        if ImGuiIsItemHovered(0) {
            ImGuiBeginTooltip()
            ImGuiTextV("Paper: \(PlotDeviceCatalog.displayName(forCanonical: settings.canonicalMediaName))")
            ImGuiTextV(String(format: "Printable: %.1f x %.1f %@",
                rects.printable.maxX - rects.printable.minX,
                rects.printable.maxY - rects.printable.minY,
                settings.plotPaperUnits == 0 ? "in" : "mm"))
            ImGuiEndTooltip()
        }

        let dl = ImGuiGetWindowDrawList()!
        let pMin = pt(rects.paper.minX, rects.paper.minY)
        let pMax = pt(rects.paper.maxX, rects.paper.maxY)
        // Canvas backdrop + drop shadow + paper.
        ImDrawListAddRectFilled(dl, ImVec2(x: origin.x, y: origin.y),
            ImVec2(x: origin.x + avail.x, y: origin.y + avail.y),
            col(42, 42, 46, 255), 0.0, 0)
        ImDrawListAddRectFilled(dl,
            ImVec2(x: pMin.x + 8, y: pMin.y + 8), ImVec2(x: pMax.x + 8, y: pMax.y + 8),
            col(0, 0, 0, 90), 0.0, 0)
        ImDrawListAddRectFilled(dl, pMin, pMax, col(255, 255, 255, 255), 0.0, 0)
        ImDrawListAddRect(dl, pMin, pMax, col(150, 150, 150, 255), 0.0, 1.0, 0)
        // Printable dashed boundary.
        let dMin = pt(rects.printable.minX, rects.printable.minY)
        let dMax = pt(rects.printable.maxX, rects.printable.maxY)
        dashedRect(dl, dMin, dMax, col(110, 110, 110, 255))
        // Effective plot area: translucent fill + clip warning.
        if let area = PaperSheetGeometry.staticPlotAreaRect(for: settings) {
            let aMin = pt(area.minX, area.minY)
            let aMax = pt(area.maxX, area.maxY)
            ImDrawListAddRectFilled(dl, aMin, aMax, col(90, 140, 250, 60), 0.0, 0)
            let clipped = area.minX < rects.printable.minX - 1e-9
                || area.minY < rects.printable.minY - 1e-9
                || area.maxX > rects.printable.maxX + 1e-9
                || area.maxY > rects.printable.maxY + 1e-9
            if clipped {
                ImDrawListAddRect(dl, aMin, aMax, col(220, 40, 40, 255), 0.0, 2.0, 0)
            }
        }
        // Caption: paper size + effective scale.
        let factor = settings.effectiveScaleFactor
        let scaleLabel: String
        if settings.standardScaleType == 0 {
            scaleLabel = "Fit to paper"
        } else if factor.isFinite {
            scaleLabel = "1:\(String(format: "%.4g", 1 / factor))"
        } else {
            scaleLabel = "1:1"
        }
        ImDrawListAddText(dl, ImVec2(x: origin.x + 10, y: origin.y + avail.y - 24),
            col(235, 235, 235, 255),
            "\(PlotDeviceCatalog.displayName(forCanonical: settings.canonicalMediaName))  •  \(scaleLabel)", nil)
    }

    private static func col(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> ImU32 {
        igGetColorU32_Vec4(ImVec4(x: Float(r) / 255, y: Float(g) / 255,
                                  z: Float(b) / 255, w: Float(a) / 255))
    }

    private static func dashedRect(_ dl: UnsafeMutablePointer<ImDrawList>!,
                                   _ a: ImVec2, _ b: ImVec2, _ col: ImU32) {
        let dash: Float = 6, gap: Float = 5
        func dashLine(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) {
            let dx = bx - ax, dy = by - ay
            let total = (dx * dx + dy * dy).squareRoot()
            guard total > 0.001 else { return }
            var t: Float = 0
            var guardCount = 0
            while t < total, guardCount < 400 {
                let t1 = min(t + dash, total)
                ImDrawListAddLine(dl,
                    ImVec2(x: ax + dx * (t / total), y: ay + dy * (t / total)),
                    ImVec2(x: ax + dx * (t1 / total), y: ay + dy * (t1 / total)), col, 1.0)
                t += dash + gap
                guardCount += 1
            }
        }
        dashLine(a.x, a.y, b.x, a.y)
        dashLine(b.x, a.y, b.x, b.y)
        dashLine(b.x, b.y, a.x, b.y)
        dashLine(a.x, b.y, a.x, a.y)
    }
}
