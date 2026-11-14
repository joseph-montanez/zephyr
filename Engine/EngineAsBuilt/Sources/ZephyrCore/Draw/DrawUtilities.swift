import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - DrawUtilities — Shared helpers for drawing command overlays
// =========================================================================

// =========================================================================
// MARK: - Dynamic Numeric Input Helper
// =========================================================================

/// Result returned by `DynamicNumericInput` event handlers.
/// The owning `FeatureCommand` maps this to `CommandResult`.
public enum DynamicInputResult {
    /// Key was not relevant (letters, modifiers, arrows, or Enter with
    /// all buffers empty — the command runs its own Enter handling).
    case ignored
    /// Key was consumed (digit, backspace, tab) but no commit occurred.
    case consumed
    /// Enter pressed with a valid numeric value in the active buffer.
    case commitValue(Double)
    /// Enter pressed in angle field with a valid angle.
    case commitAngle(Double)
    /// Esc pressed with all buffers empty — command should cancel.
    case cancel
}

/// Named fields that `DynamicNumericInput` can manage.
/// Tab cycles through the fields in `tabCycle` order.
public enum DynamicNumericField: String, CaseIterable, Hashable, Sendable {
    case distance
    case angle
    case radius
    case diameter
    case width
    case height
}

/// Inline arithmetic evaluator for CAL-style entry (`+ - * / ( )`).
/// Headless-testable; returns nil on parse failure.
public enum NumericExpressionEvaluator {
    public static func evaluate(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var parser = Parser(trimmed)
        guard let value = parser.parseExpression() else { return nil }
        parser.skipSpaces()
        guard parser.pos >= parser.chars.count else { return nil }
        return value
    }

    private struct Parser {
        var chars: [Character]
        var pos: Int = 0

        init(_ s: String) { chars = Array(s) }

        mutating func skipSpaces() { while pos < chars.count && chars[pos].isWhitespace { pos += 1 } }
        func peek() -> Character? { pos < chars.count ? chars[pos] : nil }
        mutating func consume(_ c: Character) -> Bool {
            skipSpaces()
            if pos < chars.count && chars[pos] == c { pos += 1; return true }
            return false
        }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while true {
                skipSpaces()
                if consume("+") { guard let rhs = parseTerm() else { return nil }; value += rhs }
                else if consume("-") { guard let rhs = parseTerm() else { return nil }; value -= rhs }
                else { return value }
            }
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseFactor() else { return nil }
            while true {
                skipSpaces()
                if consume("*") { guard let rhs = parseFactor() else { return nil }; value *= rhs }
                else if consume("/") { guard let rhs = parseFactor(), rhs != 0 else { return nil }; value /= rhs }
                else { return value }
            }
        }

        mutating func parseFactor() -> Double? {
            skipSpaces()
            if consume("(") {
                guard let v = parseExpression(), consume(")") else { return nil }
                return v
            }
            if consume("+") { return parseFactor() }
            if consume("-") { guard let v = parseFactor() else { return nil }; return -v }
            return parseNumber()
        }

        mutating func parseNumber() -> Double? {
            skipSpaces()
            let start = pos
            var sawDigit = false
            while pos < chars.count && chars[pos].isNumber { pos += 1; sawDigit = true }
            if pos < chars.count && chars[pos] == "." {
                pos += 1
                while pos < chars.count && chars[pos].isNumber { pos += 1; sawDigit = true }
            }
            guard sawDigit else { return nil }
            let slice = String(chars[start..<pos])
            return Double(slice)
        }
    }
}

/// Reusable dynamic input state machine for AutoCAD-style direct numeric entry.
/// Owned by drawing commands (`LineCommand`, `CircleCommand`, `RectangleCommand`, etc.).
///
/// Each command configures `tabCycle` to control which fields appear and in what order:
///
///     // LineCommand / PolylineCommand:
///     input.tabCycle = [.distance, .angle]
///
///     // CircleCommand (radius only):
///     input.tabCycle = [.distance]   // interprets .distance as radius
///
///     // RectangleCommand:
///     input.tabCycle = [.width, .height]
public struct DynamicNumericInput {

    /// Ordered list of fields that Tab cycles through.
    /// Default: `[.distance, .angle]` (standard Line/Polyline setup).
    public var tabCycle: [DynamicNumericField] = [.distance, .angle]

    /// Index into `tabCycle` for the currently-active field.
    public var activeFieldIndex: Int = 0

    /// The field currently receiving keystrokes.
    public var activeField: DynamicNumericField {
        tabCycle.isEmpty ? .distance : tabCycle[activeFieldIndex]
    }

    /// Per-field string buffers.
    public var buffers: [DynamicNumericField: String] = [:]

    /// When non-nil, the next distance commit uses this angle (in radians) instead
    /// of the mouse direction. Set by committing an angle or parsing `<angle` syntax.
    public var lockedAngleRadians: Double? = nil

    public init() {}

    // MARK: - Convenience accessors

    /// Buffer for `.distance` field (most common).
    public var distanceBuffer: String {
        get { buffers[.distance, default: ""] }
        set { buffers[.distance] = newValue }
    }

    /// Buffer for `.angle` field.
    public var angleBuffer: String {
        get { buffers[.angle, default: ""] }
        set { buffers[.angle] = newValue }
    }

    /// True when any buffer has content.
    public var hasInput: Bool {
        buffers.values.contains { !$0.isEmpty }
    }

    /// Parses the active field's buffer as Double (supports CAL expressions).
    public var parsedValue: Double? {
        let raw = buffers[activeField, default: ""]
        if let v = Double(raw) { return v }
        return NumericExpressionEvaluator.evaluate(raw)
    }

    /// Parses the `.angle` buffer in degrees.
    public var parsedAngleDegrees: Double? {
        Double(buffers[.angle, default: ""])
    }

    // MARK: - Key handling

    /// Process a raw SDL scancode. Returns a `DynamicInputResult` that the owning
    /// command maps to `CommandResult`.
    public mutating func handleKey(_ scancode: SDL_Scancode) -> DynamicInputResult {
        let activeBuffer = buffers[activeField, default: ""]
        let raw = scancode.rawValue

        // --- Digit keys (main keyboard) ---
        if raw >= SDL_SCANCODE_1.rawValue && raw <= SDL_SCANCODE_9.rawValue {
            let digit = Character(UnicodeScalar(UInt8(0x31) + UInt8(raw - SDL_SCANCODE_1.rawValue)))
            appendToActive(String(digit))
            return .consumed
        }
        if scancode == SDL_SCANCODE_0 {
            appendToActive("0")
            return .consumed
        }

        // --- Numpad digits ---
        if raw >= SDL_SCANCODE_KP_1.rawValue && raw <= SDL_SCANCODE_KP_9.rawValue {
            let digit = Character(UnicodeScalar(UInt8(0x31) + UInt8(raw - SDL_SCANCODE_KP_1.rawValue)))
            appendToActive(String(digit))
            return .consumed
        }
        if scancode == SDL_SCANCODE_KP_0 {
            appendToActive("0")
            return .consumed
        }

        // --- Decimal point ---
        if scancode == SDL_SCANCODE_PERIOD || scancode == SDL_SCANCODE_KP_PERIOD {
            if !activeBuffer.contains(".") {
                appendToActive(".")
            }
            return .consumed
        }

        // --- Minus sign (negative numbers) ---
        if scancode == SDL_SCANCODE_MINUS || scancode == SDL_SCANCODE_KP_MINUS {
            if activeBuffer.isEmpty {
                appendToActive("-")
            }
            return .consumed
        }

        // --- Backspace / Delete ---
        if scancode == SDL_SCANCODE_BACKSPACE || scancode == SDL_SCANCODE_DELETE {
            popLastFromActive()
            return .consumed
        }

        // --- Tab: cycle to next field ---
        if scancode == SDL_SCANCODE_TAB {
            guard !tabCycle.isEmpty else { return .consumed }
            activeFieldIndex = (activeFieldIndex + 1) % tabCycle.count
            return .consumed
        }

        // --- Return / Enter / Space (all three commit the active field) ---
        // Space is AutoCAD's other "accept" key. `handleEnter()` returns
        // `.ignored` when no field has input, so an idle Space still falls
        // through to the caller's own Space handling.
        if scancode == SDL_SCANCODE_RETURN || scancode == SDL_SCANCODE_KP_ENTER
            || scancode == SDL_SCANCODE_SPACE {
            return handleEnter()
        }

        // --- Escape ---
        if scancode == SDL_SCANCODE_ESCAPE {
            if hasInput {
                reset()
                return .consumed
            }
            return .cancel
        }

        return .ignored
    }

    // MARK: - Text handling (command line fallback)

    /// Parse text from the command line. Supports:
    /// - Plain number: `20` → commitValue
    /// - Angle-only: `<45` → commitAngle, switches to distance
    /// - Combined: `20<45` → commitValue + stores angle
    /// - Relative combined: `@20<45` → same as combined
    public mutating func handleText(_ text: String) -> DynamicInputResult {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .ignored }

        // Remove leading @ (relative coordinate marker — same behavior for now)
        var working = trimmed
        if working.hasPrefix("@") {
            working = String(working.dropFirst())
        }

        // Check for `<angle` suffix
        if let ltIndex = working.firstIndex(of: "<") {
            let distPart = String(working[..<ltIndex])
            let anglePart = String(working[working.index(after: ltIndex)...])

            if let angleDeg = Double(anglePart) {
                lockedAngleRadians = angleDeg * .pi / 180.0
                // Switch to distance field
                if let distIdx = tabCycle.firstIndex(of: .distance) {
                    activeFieldIndex = distIdx
                }
                buffers[.angle] = ""
            }

            if let dist = Double(distPart), dist != 0 {
                buffers[.distance] = ""
                return .commitValue(dist)
            } else if distPart.isEmpty {
                // Just angle: `<45`
                return .consumed
            }
            return .consumed
        }

        // Plain number — commit as value for the active field's purpose
        if let val = Double(working), val != 0 {
            return .commitValue(val)
        }
        // CAL-style inline arithmetic (e.g. "2*3", "(10+2)/2")
        if let val = NumericExpressionEvaluator.evaluate(working), val != 0 {
            return .commitValue(val)
        }

        return .ignored
    }

    // MARK: - Render

    /// Draw the dynamic input pill near the given world cursor position.
    public func renderOverlay(cam: CameraTransform, worldX: Double, worldY: Double) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        guard let drawList = drawList else { return }

        let screen = EngineCameraManager.worldToScreen(worldX: worldX, worldY: worldY, cam: cam)
        let pillX = screen.x + 16
        let pillY = screen.y - 32

        if hasInput {
            let label: String
            switch activeField {
            case .angle:
                label = "<" + (buffers[.angle, default: ""]) + "|"
            default:
                let prefix: String
                switch activeField {
                case .distance: prefix = ""
                case .radius:   prefix = "R "
                case .diameter: prefix = "D "
                case .width:    prefix = "W "
                case .height:   prefix = "H "
                default:        prefix = ""
                }
                label = prefix + (buffers[activeField, default: ""]) + "|"
            }

            if !label.isEmpty {
                let fontSize = ImGuiGetFontSize()
                let textSize = ImGuiCalcTextSize(label, nil, false, -1.0)
                let textW = textSize.x
                let pad: Float = 6.0
                let bgMin = ImVec2(x: pillX - pad, y: pillY - pad)
                let bgMax = ImVec2(x: pillX + textW + pad, y: pillY + fontSize + pad)

                ImDrawListAddRectFilled(
                    drawList, bgMin, bgMax,
                    makeCol32(30, 30, 30, 200), 4.0, 0)
                ImDrawListAddRect(
                    drawList, bgMin, bgMax,
                    makeCol32(100, 100, 100, 200), 4.0, 1.5, 0)
                ImDrawListAddText(
                    drawList, ImVec2(x: pillX, y: pillY),
                    makeCol32(255, 255, 255, 255),
                    label, nil)
            }
        }
    }

    // MARK: - Helpers

    /// Clear all buffers and reset to first field in the tab cycle.
    public mutating func reset() {
        buffers.removeAll()
        lockedAngleRadians = nil
        activeFieldIndex = 0
    }

    // MARK: Private

    private mutating func appendToActive(_ char: String) {
        let field = activeField
        var buf = buffers[field, default: ""]
        buf.append(char)
        buffers[field] = buf
    }

    @discardableResult
    private mutating func popLastFromActive() -> Bool {
        let field = activeField
        guard var buf = buffers[field], !buf.isEmpty else { return false }
        buf.removeLast()
        buffers[field] = buf
        return true
    }

    private mutating func handleEnter() -> DynamicInputResult {
        // No input anywhere: not ours — let the owning command run its own
        // Enter handling (e.g. Line/Polyline finalize their segments).
        // Partial input stays `.consumed` so Enter never discards keystrokes.
        guard hasInput else { return .ignored }
        switch activeField {
        case .angle:
            guard let angleDeg = parsedAngleDegrees else { return .consumed }
            lockedAngleRadians = angleDeg * .pi / 180.0
            // Switch to distance field
            if let distIdx = tabCycle.firstIndex(of: .distance) {
                activeFieldIndex = distIdx
            }
            buffers[.angle] = ""
            return .commitAngle(angleDeg)
        default:
            guard let val = parsedValue, val != 0 else { return .consumed }
            buffers[activeField] = ""
            return .commitValue(val)
        }
    }
}

// =========================================================================
// MARK: - Shared helpers
// =========================================================================

/// Compute an ImGui packed colour (0xAABBGGRR) from 0–255 components.
public func makeCol32(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> UInt32 {
    return (UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(g) << 8) | UInt32(r)
}

/// Generate world-space points for an ellipse outline.
public func generateEllipsePoints(
    center: Vector3,
    majorAxis: Vector3,
    minorRatio: Double,
    segments: Int = 64
) -> [Vector3] {
    let majorLen = majorAxis.magnitude
    let minorLen = majorLen * minorRatio
    let rot = atan2(majorAxis.y, majorAxis.x)
    let cosRot = cos(rot)
    let sinRot = sin(rot)

    var points: [Vector3] = []
    for i in 0...segments {
        let t = Double(i) * 2.0 * .pi / Double(segments)
        let px = majorLen * cos(t)
        let py = minorLen * sin(t)
        let rx = px * cosRot - py * sinRot + center.x
        let ry = px * sinRot + py * cosRot + center.y
        points.append(Vector3(x: rx, y: ry, z: center.z))
    }
    return points
}

/// Compute the distance from a point to a line segment (world-space).
public func pointToSegmentDistance(_ point: Vector3, _ a: Vector3, _ b: Vector3) -> Double {
    let dx = b.x - a.x
    let dy = b.y - a.y
    let lenSq = dx * dx + dy * dy
    if lenSq < 1e-12 { return point.distance(to: a) }

    var t = ((point.x - a.x) * dx + (point.y - a.y) * dy) / lenSq
    t = max(0, min(1, t))
    let proj = Vector3(x: a.x + t * dx, y: a.y + t * dy, z: 0)
    return point.distance(to: proj)
}

/// Generate uniform clamped knot vector for a spline of given degree and control point count.
public func generateUniformKnots(controlPointCount: Int, degree: Int) -> [Double] {
    let n = controlPointCount - 1
    let knotCount = n + degree + 2
    var knots: [Double] = []
    for i in 0..<knotCount {
        if i <= degree {
            knots.append(0.0)
        } else if i >= knotCount - degree - 1 {
            knots.append(1.0)
        } else {
            let internalCount = knotCount - 2 * (degree + 1)
            if internalCount > 0 {
                knots.append(Double(i - degree) / Double(internalCount + 1))
            } else {
                knots.append(0.5)
            }
        }
    }
    return knots
}
