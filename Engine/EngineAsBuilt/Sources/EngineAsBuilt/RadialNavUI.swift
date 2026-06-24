import EngineAsBuiltCore
import Foundation
import ImGui
import SwiftSDL

// MARK: - RadialNavUI
//
// A floating, borderless radial navigation tool (Artrage style).
// Provides easy laptop/trackpad access to pan, zoom, and rotate functions.
//
// Zones:
//   1. Center: Close button (X)
//   2. Inner Quadrants:
//      - Right: Zoom In (Click or Drag right/up)
//      - Left: Zoom Out (Click or Drag left/down)
//      - Bottom: Pan (Drag)
//      - Top: Extents (Click)
//   3. Outer Ring: Rotate (Drag)

@MainActor
struct RadialNavUI {
    static var lastRotationMouseAngle: Double? = nil
    static var activeZone: Int? = nil
    static var wasDragged: Bool = false
    static var wasActive: Bool = false
    static var openRotationPopup: Bool = false
    static var targetRotationDeg: Float = 0
    static var isDoubleClicked: Bool = false
    static var popupRotationDeg: Float = 0.0
    static var windowPos: ImVec2? = nil
    static var dragStartMousePos: ImVec2? = nil

    static func render(engine: PhrostEngine, dw: Float, dh: Float) {
        guard engine.ui.radialNavVisible else { return }

        let size: Float = 320
        let padding: Float = 20
        // Position at bottom right, above the status bar by default
        if let pos = windowPos {
            ImGuiSetNextWindowPos(pos, Int32(ImGuiCond_Always.rawValue), ImVec2(x: 0, y: 0))
        } else {
            ImGuiSetNextWindowPos(
                ImVec2(x: dw - size - padding, y: dh - size - padding - AppLayout.statusBarHeight),
                Int32(ImGuiCond_Always.rawValue),
                ImVec2(x: 0, y: 0))
        }
        ImGuiSetNextWindowSize(ImVec2(x: size, y: size), Int32(ImGuiCond_Always.rawValue))
        
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowPadding.rawValue), ImVec2(x: 0, y: 0))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowRounding.rawValue), Float(0))
        ImGuiPushStyleVar(Int32(ImGuiStyleVar_WindowBorderSize.rawValue), Float(0))

        let flags: Int32 =
            Int32(ImGuiWindowFlags_NoBackground.rawValue) |
            Int32(ImGuiWindowFlags_NoTitleBar.rawValue) |
            Int32(ImGuiWindowFlags_NoResize.rawValue) |
            Int32(ImGuiWindowFlags_NoMove.rawValue) |
            Int32(ImGuiWindowFlags_NoScrollbar.rawValue) |
            Int32(ImGuiWindowFlags_NoSavedSettings.rawValue)

        var open = true
        if igBegin("RadialNavUI", &open, flags) {
            let drawList = ImGuiGetWindowDrawList()!
            let winPos = ImGuiGetWindowPos()
            let center = ImVec2(x: winPos.x + size / 2, y: winPos.y + size / 2)
            
            let io = ImGuiGetIO()!
            let mousePos = io.pointee.MousePos

            igInvisibleButton("RadialNavArea", ImVec2(x: size, y: size), 0)
            
            let dx = Double(mousePos.x - center.x)
            let dy = Double(mousePos.y - center.y)
            let dist = sqrt(dx*dx + dy*dy)
            let angle = atan2(dy, dx)
            
            let isHovered = ImGuiIsItemHovered(0)
            let isActive = ImGuiIsItemActive()
            isDoubleClicked = isHovered && ImGuiIsMouseDoubleClicked(0)
            
            // Check interaction
            var hoveredZone = 0 // 0: None, 1: Center, 2: Right, 3: Bottom, 4: Left, 5: Top, 6: Outer Ring
            
            let rCenter: Float = 34
            let rInner: Float = 102
            let rOuter: Float = 150
            let rText: Float = 126
            let rIcon: Float = 68

            if isHovered || isActive {
                if dist < Double(rCenter) {
                    hoveredZone = 1 // Center (Close)
                } else if dist < Double(rInner) {
                    // Quadrants (-pi/4 to pi/4 is Right)
                    let deg = angle * 180 / .pi
                    if deg >= -45 && deg < 45 {
                        hoveredZone = 2 // Right (Zoom In)
                    } else if deg >= 45 && deg < 135 {
                        hoveredZone = 3 // Bottom (Pan)
                    } else if deg >= -135 && deg < -45 {
                        hoveredZone = 5 // Top (Extents)
                    } else {
                        hoveredZone = 4 // Left (Zoom Out)
                    }
                } else if dist < Double(rOuter) {
                    hoveredZone = 6 // Outer Ring (Rotate)
                }
            }
            
            if isActive && activeZone == nil {
                activeZone = hoveredZone
            }
            
            let currentZone = activeZone ?? hoveredZone

            // Colors (using explicit engine theme)
            let bgVec = engine.ui.theme.panelBg
            let bgCol = igGetColorU32_Vec4(ImVec4(x: bgVec.x, y: bgVec.y, z: bgVec.z, w: 0.95))
            let lineCol = igGetColorU32_Vec4(engine.ui.theme.border)
            var hoverVec = engine.ui.theme.hoverBg
            hoverVec.w = 0.5 // Ensure some opacity
            let hoverCol = igGetColorU32_Vec4(hoverVec)
            let activeCol = igGetColorU32_Vec4(engine.ui.theme.activeBg)
            let textCol = igGetColorU32_Vec4(engine.ui.theme.textPrimary)
            let markerCol = igGetColorU32_Vec4(engine.ui.theme.brandGold)

            // Draw base shapes (using 64 segments for smooth circles and avoiding artifacts)
            ImDrawListAddCircleFilled(drawList, center, rOuter, bgCol, 64)
            
            ImDrawListAddCircle(drawList, center, rOuter - 0.5, markerCol, 64, 2)
            ImDrawListAddCircle(drawList, center, rInner - 0.5, lineCol, 64, 2)
            ImDrawListAddCircle(drawList, center, rCenter - 0.5, lineCol, 64, 2)
            
            // Draw lines for quadrants between inner and center radius
            for i in 0..<4 {
                let a = Double(i) * .pi / 2.0 + .pi / 4.0
                let p1 = ImVec2(x: center.x + Float(cos(a) * Double(rCenter)), y: center.y + Float(sin(a) * Double(rCenter)))
                let p2 = ImVec2(x: center.x + Float(cos(a) * Double(rInner)), y: center.y + Float(sin(a) * Double(rInner)))
                ImDrawListAddLine(drawList, p1, p2, lineCol, 2)
            }
            
            // Highlight hovered zone
            func highlightArc(rMin: Float, rMax: Float, aMin: Float, aMax: Float) {
                let rMid = (rMin + rMax) / 2
                let thick = rMax - rMin
                ImDrawListPathArcTo(drawList, center, rMid, aMin, aMax, 32)
                ImDrawListPathStroke(drawList, isActive ? activeCol : hoverCol, thick, 0)
            }
            
            if currentZone == 1 {
                ImDrawListAddCircleFilled(drawList, center, rCenter, isActive ? activeCol : hoverCol, 64)
            } else if currentZone == 2 { highlightArc(rMin: rCenter, rMax: rInner, aMin: -.pi/4, aMax: .pi/4) }
            else if currentZone == 3 { highlightArc(rMin: rCenter, rMax: rInner, aMin: .pi/4, aMax: 3 * .pi/4) }
            else if currentZone == 4 { highlightArc(rMin: rCenter, rMax: rInner, aMin: 3 * .pi/4, aMax: 5 * .pi/4) }
            else if currentZone == 5 { highlightArc(rMin: rCenter, rMax: rInner, aMin: -3 * .pi/4, aMax: -.pi/4) }
            else if currentZone == 6 {
                // Highlight entire outer ring
                let rMid = (rInner + rOuter) / 2
                let thick = rOuter - rInner
                ImDrawListAddCircle(drawList, center, rMid, isActive ? activeCol : hoverCol, 64, thick)
            }

            // Draw Icons (Text)
            func drawTextCentered(_ text: String, _ r: Float, _ angle: Double) {
                let p = ImVec2(x: center.x + Float(cos(angle) * Double(r)), y: center.y + Float(sin(angle) * Double(r)))
                let tSize = ImGuiCalcTextSize(text, nil, false, 0)
                ImDrawListAddText(drawList, ImVec2(x: p.x - tSize.x / 2, y: p.y - tSize.y / 2), textCol, text, nil)
            }

            drawTextCentered("X", 0, 0)
            drawTextCentered("Fit", rIcon, -.pi/2)
            drawTextCentered("Z+", rIcon, 0)
            drawTextCentered("Pan", rIcon, .pi/2)
            drawTextCentered("Z-", rIcon, .pi)
            
            // Outer ring marks (fixed rotation dial texts)
            drawTextCentered("0", rText, -.pi/2)       // Top
            drawTextCentered("90", rText, 0)          // Right
            drawTextCentered("180", rText, .pi/2)     // Bottom
            drawTextCentered("270", rText, .pi)       // Left

            // Tick marks on the outer ring
            // Dial degrees: 0° at top, clockwise. mathAngle = -π/2 + deg * π/180
            for deg in stride(from: 0, to: 360, by: 5) {
                let isLarge = deg % 15 == 0
                let mathAngle = -.pi / 2 + Double(deg) * .pi / 180.0
                let cosA = Float(cos(mathAngle))
                let sinA = Float(sin(mathAngle))
                let innerR: Float = isLarge ? rOuter - 18 : rOuter - 7
                let thick: Float = isLarge ? 2.5 : 1.0
                let p1 = ImVec2(x: center.x + cosA * innerR, y: center.y + sinA * innerR)
                let p2 = ImVec2(x: center.x + cosA * rOuter, y: center.y + sinA * rOuter)
                ImDrawListAddLine(drawList, p1, p2, lineCol, thick)
            }

            // Current Rotation Indicator (thin triangle pointing outward)
            let tickAngle = -.pi/2 - engine.camera.rotation
            let cosA = Float(cos(tickAngle))
            let sinA = Float(sin(tickAngle))
            // Tip at outer ring, base at inner ring
            let tip = ImVec2(x: center.x + cosA * rOuter, y: center.y + sinA * rOuter)
            let halfBase: Float = 4
            let perpX = -sinA * halfBase
            let perpY = cosA * halfBase
            let baseCenter = ImVec2(x: center.x + cosA * (rInner + 4), y: center.y + sinA * (rInner + 4))
            let base1 = ImVec2(x: baseCenter.x + perpX, y: baseCenter.y + perpY)
            let base2 = ImVec2(x: baseCenter.x - perpX, y: baseCenter.y - perpY)
            ImDrawListAddTriangleFilled(drawList, tip, base1, base2, markerCol)

            // Interaction logic
            engine.interaction.radialPanActive = isActive && currentZone == 3
            if isActive {
                if !wasActive {
                    wasDragged = false
                    dragStartMousePos = mousePos
                    _ = SDL_SetWindowRelativeMouseMode(engine.window, true)
                }
                
                var relX: Float = 0
                var relY: Float = 0
                _ = SDL_GetRelativeMouseState(&relX, &relY)
                let dx = Double(relX)
                let dy = Double(relY)

                if dx != 0 || dy != 0 { wasDragged = true }
                wasActive = true
                
                engine.interaction.forceHideOSCursor = true
                igSetMouseCursor(Int32(ImGuiMouseCursor_None.rawValue))

                let isHugeDelta = abs(dx) > 100 || abs(dy) > 100

                if currentZone == 6 {
                    // Rotate
                    if !isHugeDelta && wasDragged {
                        let rotSensitivity: Double = 0.005
                        engine.camera.rotation -= dx * rotSensitivity
                    }
                } else if currentZone == 3 {
                    // Pan
                    if !isHugeDelta && wasDragged {
                        let worldPanX = dx / engine.camera.zoom
                        let worldPanY = dy / engine.camera.zoom
                        let rot = -engine.camera.rotation
                        let dx_rot = worldPanX * cos(rot) - worldPanY * sin(rot)
                        let dy_rot = worldPanX * sin(rot) + worldPanY * cos(rot)
                        engine.camera.move(dx: -dx_rot, dy: -dy_rot)
                    }
                } else if currentZone == 2 {
                    // Right - Zoom In
                    if !isHugeDelta && wasDragged {
                        let zoomFactor = 1.0 - dy * 0.01 + dx * 0.01
                        engine.camera.zoomViewCentered(factor: zoomFactor)
                    }
                } else if currentZone == 4 {
                    // Left - Zoom Out
                    if !isHugeDelta && wasDragged {
                        let zoomFactor = 1.0 + dy * 0.01 - dx * 0.01
                        engine.camera.zoomViewCentered(factor: zoomFactor)
                    }
                } else if currentZone == 1 {
                    if !isHugeDelta && wasDragged {
                        if windowPos == nil { windowPos = winPos }
                        windowPos = ImVec2(x: windowPos!.x + Float(dx), y: windowPos!.y + Float(dy))
                    }
                }
            } else {
                if wasActive {
                    engine.interaction.forceHideOSCursor = false
                    _ = SDL_SetWindowRelativeMouseMode(engine.window, false)
                    
                    if let startPos = dragStartMousePos {
                        // When dragging the nav itself (zone 1), keep the mouse at the new position.
                        // For all other zones (pan/zoom/rotate), warp back so the user can continue.
                        if activeZone != 1 || !wasDragged {
                            SDL_WarpMouseInWindow(engine.window, startPos.x, startPos.y)
                        }
                        dragStartMousePos = nil
                    }
                    if !wasDragged {
                        if currentZone == 1 {
                            engine.ui.radialNavVisible = false
                        } else if currentZone == 5 {
                            engine.zoomExtents()
                        }
                    }
                }
                wasActive = false
                activeZone = nil
                lastRotationMouseAngle = nil
            }

            // Click actions (for other zones)
            if igIsItemClicked(0) {
                if hoveredZone == 5 {
                    engine.zoomExtents()
                } else if hoveredZone == 2 {
                    engine.camera.zoomViewCentered(factor: 1.2)
                } else if hoveredZone == 4 {
                    engine.camera.zoomViewCentered(factor: 1.0 / 1.2)
                } else if hoveredZone == 6 {
                    // Snapping to 0, 90, 180, 270 if clicked near the text
                    // Our text locations: Top(-pi/2)->0, Right(0)->90, Bottom(pi/2)->180, Left(pi)->270
                    // We check which axis the click angle is closest to (within 15 degrees)
                    let deg = angle * 180 / .pi
                    func normAngleDeg(_ d: Double) -> Double {
                        var d = d.truncatingRemainder(dividingBy: 360)
                        if d < 0 { d += 360 }
                        return d
                    }
                    let degNorm = normAngleDeg(deg)
                    let tolerance: Double = 15.0
                    
                    if abs(degNorm - 270) < tolerance || abs(degNorm - (-90)) < tolerance { // Top -> 0 rot
                        engine.camera.rotation = 0
                    } else if abs(degNorm - 0) < tolerance || abs(degNorm - 360) < tolerance { // Right -> -pi/2 rot (90)
                        engine.camera.rotation = -.pi / 2
                    } else if abs(degNorm - 90) < tolerance { // Bottom -> -pi rot (180)
                        engine.camera.rotation = -.pi
                    } else if abs(degNorm - 180) < tolerance { // Left -> -3pi/2 rot (270)
                        engine.camera.rotation = -3 * .pi / 2
                    }
                }
            }

            // Double click for precise rotation
            if isHovered && hoveredZone == 6 && ImGuiIsMouseDoubleClicked(ImGuiMouseButton(ImGuiMouseButton_Left.rawValue)) {
                popupRotationDeg = Float(-engine.camera.rotation * 180 / .pi)
                igOpenPopup_Str("SetRotationPopup", 0)
            }

            if igBeginPopup("SetRotationPopup", 0) {
                igTextUnformatted("Set Precise Rotation", nil)
                if igInputFloat("Degrees", &popupRotationDeg, 0, 0, "%.2f", Int32(ImGuiInputTextFlags_EnterReturnsTrue.rawValue)) {
                    engine.camera.rotation = Double(-popupRotationDeg) * .pi / 180.0
                    igCloseCurrentPopup()
                }
                igEndPopup()
            }
        }
        igEnd()

        ImGuiPopStyleVar(3)
    }
}
