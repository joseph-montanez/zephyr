import CSDL3
import Foundation
import ImGui
import SwiftSDL
import ZephyrKernel

// =========================================================================
// MARK: - UCSCommand
//
// AutoCAD-style planar UCS command (World / 3point / View / Z / Origin /
// Prev). The frame itself lives on the active document (`CADDocument.ucsState`)
// so every drawing view keeps its own UCS without extra tab plumbing; undo,
// persistence, sysvars, named UCS records, and per-pane overrides are later
// work and deliberately out of scope here.
//
// Conventions (see the approved UCS/PLAN plan):
//   * Typed Z rotations are canonical deltas: ANGDIR flips the sign,
//     ANGBASE never applies. The typed visual rotation is additionally
//     negated into the engine's Y-down world so UCS Z 45 matches AutoCAD LT.
//   * Typed points are interpreted in the current UCS and converted to WCS.
//   * Mouse picks are already WCS; their Z keeps the current origin elevation.
//   * A 3-point Y pick on the negative-Y side (or collinear) re-prompts
//     instead of silently flipping the frame.
// =========================================================================

@MainActor
public final class UCSCommand: FeatureCommand {

    public enum Phase: Equatable {
        case options
        case origin
        case threePointOrigin
        case threePointX(origin: Point3d)
        case threePointY(origin: Point3d, xPoint: Point3d)
        case zAngle
    }

    public enum Option {
        case world
        case threePoint
        case view
        case z
        case origin
        case previous
    }

    public static let optionPrompt =
        "Enter an option [World/3point/View/Z/Origin/Prev] <World>:"

    public private(set) var phase: Phase = .options

    public init() {}

    public var isSnappingEnabled: Bool { true }

    // MARK: - FeatureCommand conformance

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        start(processor: processor)
    }

    /// Headless entry point for unit tests (no SDL engine required).
    public func start(processor: CADCommandProcessor) {
        phase = .options
        openPrompt(Self.optionPrompt, processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        phase = .options
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        handleMouseClick(worldX: worldX, worldY: worldY, document: engine.document, processor: processor)
    }

    /// Headless mouse handling for unit tests.
    @discardableResult
    public func handleMouseClick(
        worldX: Double, worldY: Double,
        document: CADDocument, processor: CADCommandProcessor
    ) -> CommandResult {
        let picked = Point3d(
            x: worldX, y: worldY,
            z: document.ucsState.definition.origin.z)
        switch phase {
        case .options, .zAngle:
            // Canvas clicks never choose options; use option keys or typed text.
            return .handled
        case .origin:
            commit(
                document: document,
                definition: UCSDefinition(
                    origin: picked,
                    angle: document.ucsState.definition.angle),
                name: "UNNAMED",
                message: "UCS origin set to (\(format(picked.x)), \(format(picked.y)), \(format(picked.z))).")
            return .finished
        case .threePointOrigin:
            phase = .threePointX(origin: picked)
            openPrompt("Specify point on positive portion of X-axis:", processor: processor)
            return .continue
        case .threePointX(let origin):
            phase = .threePointY(origin: origin, xPoint: picked)
            openPrompt(
                "Specify point on positive-Y portion of the UCS XY plane:",
                processor: processor)
            return .continue
        case .threePointY(let origin, let xPoint):
            return finishThreePoint(
                origin: origin, xPoint: xPoint, yPoint: picked,
                document: document, processor: processor)
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE {
            return .finished
        }
        guard phase == .options else {
            return .continue
        }
        switch scancode {
        case SDL_SCANCODE_W:
            return applyOption(
                .world, remainder: "",
                document: engine.document,
                cameraRotation: engine.camera.rotation,
                processor: processor)
        case SDL_SCANCODE_3, SDL_SCANCODE_KP_3:
            return applyOption(
                .threePoint, remainder: "",
                document: engine.document,
                cameraRotation: engine.camera.rotation,
                processor: processor)
        case SDL_SCANCODE_V:
            return applyOption(
                .view, remainder: "",
                document: engine.document,
                cameraRotation: engine.camera.rotation,
                processor: processor)
        case SDL_SCANCODE_Z:
            return applyOption(
                .z, remainder: "",
                document: engine.document,
                cameraRotation: engine.camera.rotation,
                processor: processor)
        case SDL_SCANCODE_O:
            return applyOption(
                .origin, remainder: "",
                document: engine.document,
                cameraRotation: engine.camera.rotation,
                processor: processor)
        case SDL_SCANCODE_P:
            return applyOption(
                .previous, remainder: "",
                document: engine.document,
                cameraRotation: engine.camera.rotation,
                processor: processor)
        default:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Context-sensitive command-line options

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        guard phase == .options else { return [] }
        let options: [FeatureCommandTextOption] = [
            .init(value: "W", title: "World", aliases: ["WORLD"], description: "Reset to the world coordinate system"),
            .init(value: "3", title: "3point", aliases: ["3POINT"], description: "Define the UCS from origin, X-axis, and XY-plane points"),
            .init(value: "V", title: "View", aliases: ["VIEW"], description: "Align the UCS XY plane with the current view"),
            .init(value: "Z", title: "Z", aliases: [], description: "Rotate the UCS about its Z axis"),
            .init(value: "O", title: "Origin", aliases: ["ORIGIN"], description: "Move the UCS origin"),
            .init(value: "P", title: "Prev", aliases: ["PREV", "PREVIOUS"], description: "Restore the previous UCS"),
        ]
        return options.filter { $0.matches(input) }
    }

    // MARK: - Command text handling

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        handleCommandText(
            text,
            document: engine.document,
            cameraRotation: engine.camera.rotation,
            processor: processor)
    }

    /// Headless text handling for unit tests.
    @discardableResult
    public func handleCommandText(
        _ text: String,
        document: CADDocument,
        cameraRotation: Double,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let rawInput = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = rawInput.isEmpty ? Self.defaultInput(for: phase) : rawInput
        switch phase {
        case .options:
            guard let (option, remainder) = Self.parseOption(input) else {
                openPrompt("Unknown UCS option '\(input)'. \(Self.optionPrompt)", processor: processor)
                return .continue
            }
            return applyOption(
                option, remainder: remainder,
                document: document,
                cameraRotation: cameraRotation,
                processor: processor)
        case .origin:
            guard let point = parsePoint(input, document: document) else {
                openPrompt("Invalid point. Specify new origin point <0,0,0>:", processor: processor)
                return .continue
            }
            commit(
                document: document,
                definition: UCSDefinition(origin: point, angle: document.ucsState.definition.angle),
                name: "UNNAMED",
                message: "UCS origin set to (\(format(point.x)), \(format(point.y)), \(format(point.z))).")
            return .finished
        case .threePointOrigin:
            guard let point = parsePoint(input, document: document) else {
                openPrompt("Invalid point. Specify new origin point <0,0,0>:", processor: processor)
                return .continue
            }
            phase = .threePointX(origin: point)
            openPrompt("Specify point on positive portion of X-axis:", processor: processor)
            return .continue
        case .threePointX(let origin):
            guard let point = parsePoint(input, document: document) else {
                openPrompt("Invalid point. Specify point on positive portion of X-axis:", processor: processor)
                return .continue
            }
            phase = .threePointY(origin: origin, xPoint: point)
            openPrompt(
                "Specify point on positive-Y portion of the UCS XY plane:",
                processor: processor)
            return .continue
        case .threePointY(let origin, let xPoint):
            guard let point = parsePoint(input, document: document) else {
                openPrompt(
                    "Invalid point. Specify point on positive-Y portion of the UCS XY plane:",
                    processor: processor)
                return .continue
            }
            return finishThreePoint(
                origin: origin, xPoint: xPoint, yPoint: point,
                document: document, processor: processor)
        case .zAngle:
            guard let degrees = Self.parseDegrees(input) else {
                openPrompt("Invalid angle. Specify rotation angle about Z axis <0>:", processor: processor)
                return .continue
            }
            applyZRotation(degrees: degrees, document: document)
            return .finished
        }
    }

    // MARK: - Options

    /// Split an option line into its head keyword and remainder.
    /// Bare input selects the `<World>` default.
    static func parseOption(_ text: String) -> (option: Option, remainder: String)? {
        let parts = text
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
            .map { String($0) }
        guard let rawHead = parts.first, !rawHead.isEmpty else {
            return (.world, "")
        }
        let head = rawHead.uppercased()
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch head {
        case "WORLD", "W":
            return (.world, "")
        case "3", "3POINT":
            return (.threePoint, "")
        case "VIEW", "V":
            return (.view, "")
        case "Z":
            return (.z, rest)
        case "ORIGIN", "O":
            return (.origin, rest)
        case "PREV", "PREVIOUS", "P":
            return (.previous, "")
        default:
            return nil
        }
    }

    @discardableResult
    func applyOption(
        _ option: Option,
        remainder: String,
        document: CADDocument,
        cameraRotation: Double,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch option {
        case .world:
            commit(
                document: document,
                definition: .identity,
                name: "*WORLD*",
                message: "UCS = World (*WORLD*).")
            return .finished
        case .previous:
            var state = document.ucsState
            if state.restorePrevious() {
                document.ucsState = state
                print("[CAD] Restored previous UCS (\(state.name)).")
            } else {
                print("[CAD] No previous UCS to restore.")
            }
            return .finished
        case .view:
            // Screen-right in world coordinates is the camera rotation
            // applied to +X, so adopting it keeps UCS X screen-horizontal.
            let current = document.ucsState.definition
            commit(
                document: document,
                definition: UCSDefinition(
                    origin: current.origin,
                    angle: AngleConvention.normalize(cameraRotation)),
                name: "UNNAMED",
                message: "UCS aligned to current view.")
            return .finished
        case .z:
            if let degrees = Self.parseDegrees(remainder) {
                applyZRotation(degrees: degrees, document: document)
                return .finished
            }
            phase = .zAngle
            openPrompt("Specify rotation angle about Z axis <0>:", processor: processor)
            return .continue
        case .origin:
            if let point = parsePoint(remainder, document: document) {
                commit(
                    document: document,
                    definition: UCSDefinition(
                        origin: point,
                        angle: document.ucsState.definition.angle),
                    name: "UNNAMED",
                    message: "UCS origin set to (\(format(point.x)), \(format(point.y)), \(format(point.z))).")
                return .finished
            }
            guard !remainder.isEmpty else {
                phase = .origin
                openPrompt("Specify new origin point <0,0,0>:", processor: processor)
                return .continue
            }
            openPrompt("Invalid point. Specify new origin point <0,0,0>:", processor: processor)
            phase = .origin
            return .continue
        case .threePoint:
            phase = .threePointOrigin
            openPrompt("Specify new origin point <0,0,0>:", processor: processor)
            return .continue
        }
    }

    // MARK: - Helpers

    /// Bare-Enter default for each prompt, matching the bracketed default
    /// shown to the user. Three-point picks have no default and re-prompt.
    static func defaultInput(for phase: Phase) -> String {
        switch phase {
        case .options:
            return ""
        case .origin:
            return "0,0,0"
        case .threePointOrigin, .threePointX, .threePointY:
            return ""
        case .zAngle:
            return "0"
        }
    }

    private func parsePoint(_ text: String, document: CADDocument) -> Point3d? {
        guard let input = UserPointParser.parse(text) else { return nil }
        return document.ucsState.worldOrigin(from: input)
    }

    static func parseDegrees(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else {
            return nil
        }
        return value
    }

    /// AutoCAD parity note: this engine stores world Y pointing down the
    /// screen (DXF import negates Y and export flips it back), so a typed
    /// visual CCW rotation is a negative canonical delta. Negate once here;
    /// future ANGBASE/ANGDIR wiring must compose with this display mapping,
    /// not duplicate it.
    private func applyZRotation(degrees: Double, document: CADDocument) {
        // Z entries are deltas: ANGDIR flips the sign, ANGBASE never applies.
        // The extra negation maps the typed visual rotation into this
        // engine's Y-down world (see the note above): a typed visual CCW
        // turn is a negative canonical delta. PLAN (rotation = ucsAngle)
        // then levels exactly this frame, matching AutoCAD LT.
        let delta = -AngleConvention.default.canonicalDelta(
            fromUserDelta: degrees * .pi / 180.0)
        let rotated = document.ucsState.definition.rotated(by: delta)
        commit(
            document: document,
            definition: rotated,
            name: "UNNAMED",
            message: "UCS rotated \(format(degrees)) degrees about Z.")
    }

    @discardableResult
    private func finishThreePoint(
        origin: Point3d,
        xPoint: Point3d,
        yPoint: Point3d,
        document: CADDocument,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard UCSViewState.acceptsThreePoints(origin: origin, xPoint: xPoint, yPoint: yPoint),
              let definition = UCSDefinition.fromThreePoints(
                origin: origin, xPoint: xPoint, yPoint: yPoint) else {
            openPrompt(
                "Point must be on positive-Y side of UCS XY plane. Specify point on positive-Y portion of the UCS XY plane:",
                processor: processor)
            return .continue
        }
        commit(
            document: document,
            definition: definition,
            name: "UNNAMED",
            message: "UCS defined by three points.")
        return .finished
    }

    private func commit(
        document: CADDocument,
        definition: UCSDefinition,
        name: String,
        message: String
    ) {
        var state = document.ucsState
        state.commit(definition: definition, name: name)
        document.ucsState = state
        print("[CAD] \(message)")
    }

    private func openPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
        print("[CAD] \(prompt)")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }
}

// MARK: - Command-line dispatch

/// Start (or continue) the interactive UCS command for command-line input.
/// Kept as a free function so the S2 dispatch table gains UCS support without
/// restructuring the legacy switch.
@MainActor internal func startUCSFeatureCommand(
    text: String,
    engine: PhrostEngine?,
    processor: CADCommandProcessor
) {
    guard let engine else {
        processor.clearCommand()
        return
    }
    // A keyboard-driven command never inherits a centered cursor: drop any
    // stray relative capture (missed mouse-up elsewhere) on entry.
    RadialNavCapture.releaseAllRelativeMouseModes(windows: engine.windowManager.windows)
    let upper = text.uppercased()
    let argument: String
    if upper == "UCS" {
        argument = ""
    } else if upper.hasPrefix("UCS ") {
        argument = String(text.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        argument = text
    }
    if let active = processor.activeFeatureCommand as? UCSCommand {
        let result = active.handleCommandText(argument, engine: engine, processor: processor)
        if result == .finished {
            processor.finishFeatureCommand(engine: engine)
        }
        return
    }
    let command = UCSCommand()
    processor.activeFeatureCommand = command
    command.start(engine: engine, processor: processor)
    guard !argument.isEmpty else { return }
    let result = command.handleCommandText(argument, engine: engine, processor: processor)
    if result == .finished {
        processor.finishFeatureCommand(engine: engine)
    }
}
