import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - PeditCommand
// =========================================================================

/// PEDIT (alias PE) — AutoCAD-style polyline editing.
///
/// Flow: select a polyline (or a line/arc offered for conversion), then a
/// prompt-driven option loop: Close/Open, Join, Width, Edit vertex, Fit,
/// Spline, Decurve, Ltype gen, Reverse, Taper, Undo, eXit, plus Multiple
/// mode which gathers several polylines and applies each option to all of
/// them in one undo batch.
///
/// Geometry lives in `PeditGeometryEngine`; this class is the interactive
/// shell (prompts, picking, selection, undo bookkeeping). PR2 implements
/// the shell plus Close/Open/Width/Taper/Reverse/Ltype gen/Undo/Multiple;
/// Join (PR4), Edit vertex (PR3), and Fit/Spline/Decurve (PR5) are present
/// in the menu and report honestly until their PR lands.
@MainActor
public final class PeditCommand: FeatureCommand {

    private struct Target {
        let handle: UUID
        let primIndex: Int
        /// Document state at menu entry; session Undo restores these.
        let baseline: CADEntity
    }

    private enum Step {
        case selectTarget
        case confirmConvert(handle: UUID, primIndex: Int, convertToPolyline: () -> CADPolyline?)
        case gatherMultiple([Target])
        case mainMenu
        case awaitWidth
        case awaitTaperFirst
        case awaitTaperSecond(first: Double)
        case vertexMode(index: Int)
        case vertexAwaitMove(index: Int)
        case vertexAwaitInsert(index: Int)
        case vertexAwaitTangent(index: Int)
        case vertexAwaitWidthFirst(index: Int)
        case vertexAwaitWidthSecond(index: Int, first: Double)
        case vertexStraightenMark(first: Int, second: Int)
        case joinPicking([(handle: UUID, primIndex: Int)])
    }

    private var step: Step = .selectTarget
    private var targets: [Target] = []
    private var isMultiple: Bool = false
    /// Selection as it was when the command started (noun-verb pickfirst).
    /// Cancel/finish restores exactly this, so preselected objects are never
    /// lost and fresh sessions end unselected.
    private var initialSelection: [UUID] = []
    /// Handles created by Break (second halves); session Undo removes these.
    private var spawnedHandles: [UUID] = []
    /// Source entities consumed by Join; session Undo restores these.
    private var consumedEntities: [CADEntity] = []

    public init() {}

    // MARK: - FeatureCommand

    public var isSnappingEnabled: Bool {
        switch step {
        case .selectTarget, .confirmConvert, .gatherMultiple, .joinPicking:
            return false
        default:
            return true
        }
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        step = .selectTarget
        targets = []
        spawnedHandles = []
        consumedEntities = []
        isMultiple = false
        initialSelection = engine.cadSelection.selectedHandles.sorted { $0.uuidString < $1.uuidString }
        if adoptPreselection(engine: engine, processor: processor) {
            return
        }
        openInput(processor, prompt: "Select polyline or [Multiple]:")
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        // Restore the entry selection: fresh sessions end unselected,
        // noun-verb sessions keep the user's original picks.
        engine.cadSelection.clearSelection()
        for handle in initialSelection {
            engine.cadSelection.addToSelection(handle)
        }
        step = .selectTarget
        targets = []
        spawnedHandles = []
        consumedEntities = []
        initialSelection = []
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .selectTarget:
            guard let picked = pickTarget(
                worldX: worldX, worldY: worldY, engine: engine, processor: processor)
            else { return .handled }
            switch picked {
            case .polyline(let target):
                enterMenu(targets: [target], engine: engine, processor: processor)
            case .convertible(let handle, let primIndex, let makePath):
                offerConversion(
                    handle: handle, primIndex: primIndex, makePath: makePath,
                    engine: engine, processor: processor)
            case .rejected(let message):
                openInput(processor, prompt: "\(message) Select polyline or [Multiple]:")
            }
            return .handled
        case .gatherMultiple(var gathered):
            guard let picked = pickTarget(
                worldX: worldX, worldY: worldY, engine: engine, processor: processor)
            else { return .handled }
            switch picked {
            case .polyline(let target):
                gathered.append(target)
                step = .gatherMultiple(gathered)
                engine.cadSelection.addToSelection(target.handle)
                processor.commandPrompt =
                    "Select objects: \(gathered.count) found. Press Enter when done or [Undo]:"
            case .convertible(let handle, let primIndex, let makePath):
                // Multiple mode never interrogates per object: convert only
                // when PEDITACCEPT says so, otherwise skip with a message.
                guard peditAccept(engine: engine, processor: processor) else {
                    processor.commandPrompt =
                        "Skipped: not a polyline (set PEDITACCEPT=1 to convert). " +
                        "Select objects: \(gathered.count) found. Press Enter when done or [Undo]:"
                    return .handled
                }
                var updated = gathered
                if convertAndStage(
                    handle: handle, primIndex: primIndex, makePath: makePath,
                    engine: engine, processor: processor),
                   let staged = targets.popLast() {
                    updated.append(staged)
                }
                step = .gatherMultiple(updated)
                processor.commandPrompt =
                    "Select objects: \(updated.count) found. Press Enter when done or [Undo]:"
            case .rejected(let message):
                processor.commandPrompt =
                    "\(message) Select objects: \(gathered.count) found. Press Enter when done or [Undo]:"
            }
            return .handled
        case .confirmConvert, .mainMenu, .awaitWidth, .awaitTaperFirst, .awaitTaperSecond:
            return .handled
        case .vertexAwaitMove(let index):
            if let context = vertexContext(engine: engine) {
                let aim = context.entity.transform.inverse().transformPoint(
                    Vector3(x: worldX, y: worldY, z: 0))
                applyVertexPath(PeditGeometryEngine.moved(
                    context.path, index: index, to: aim),
                    index: index, what: "Vertex moved.", engine: engine, processor: processor)
            }
            return .handled
        case .vertexAwaitInsert(let index):
            if let context = vertexContext(engine: engine) {
                let point = context.entity.transform.inverse().transformPoint(
                    Vector3(x: worldX, y: worldY, z: 0))
                if let inserted = PeditGeometryEngine.inserted(
                    context.path, after: index, position: point) {
                    applyVertexPath(inserted.path, index: inserted.index,
                                    what: "Vertex inserted.", engine: engine, processor: processor)
                } else {
                    showVertexPrompt(index: index, engine: engine, processor: processor,
                                     lead: "Cannot insert here. ")
                }
            }
            return .handled
        case .vertexAwaitTangent(let index):
            if let context = vertexContext(engine: engine),
               context.path.vertices.indices.contains(index) {
                let vertex = context.path.vertices[index].position
                let aim = context.entity.transform.inverse().transformPoint(
                    Vector3(x: worldX, y: worldY, z: 0))
                let dx = aim.x - vertex.x
                let dy = aim.y - vertex.y
                guard hypot(dx, dy) > 1e-9 else {
                    processor.commandPrompt = "Aim away from the vertex. Specify tangent direction:"
                    return .handled
                }
                applyVertexPath(PeditGeometryEngine.withTangent(
                    context.path, index: index, angle: atan2(dy, dx)),
                    index: index, what: "Tangent set.", engine: engine, processor: processor)
            }
            return .handled
        case .vertexMode, .vertexAwaitWidthFirst, .vertexAwaitWidthSecond, .vertexStraightenMark:
            return .handled
        case .joinPicking(let picked):
            guard let source = pickJoinSource(
                worldX: worldX, worldY: worldY, engine: engine, processor: processor,
                excluding: targets)
            else { return .handled }
            var updated = picked
            updated.append(source)
            step = .joinPicking(updated)
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt = joinPrompt(count: updated.count)
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let marks: [(position: Vector3, primary: Bool)]
        switch step {
        case .vertexMode(let index),
             .vertexAwaitMove(let index),
             .vertexAwaitInsert(let index),
             .vertexAwaitTangent(let index),
             .vertexAwaitWidthFirst(let index),
             .vertexAwaitWidthSecond(let index, _):
            guard let world = vertexWorldPosition(index: index, engine: engine) else { return }
            marks = [(world, true)]
        case .vertexStraightenMark(let first, let second):
            guard let a = vertexWorldPosition(index: first, engine: engine),
                  let b = vertexWorldPosition(index: second, engine: engine)
            else { return }
            marks = [(a, true), (b, false)]
        default:
            return
        }
        guard let drawList = igGetForegroundDrawList_ViewportPtr(nil) else { return }
        func screen(_ point: Vector3) -> ImVec2 {
            let s = EngineCameraManager.worldToScreen(worldX: point.x, worldY: point.y, cam: cam)
            return ImVec2(x: s.x, y: s.y)
        }
        if marks.count == 2 {
            ImDrawListAddLine(drawList, screen(marks[0].position), screen(marks[1].position),
                              makeCol32(0, 220, 255, 230), 1.5)
        }
        for mark in marks {
            let c = screen(mark.position)
            let r: Float = 7
            let col = mark.primary ? makeCol32(255, 200, 0, 255) : makeCol32(0, 220, 255, 255)
            ImDrawListAddLine(drawList, ImVec2(x: c.x - r, y: c.y - r),
                              ImVec2(x: c.x + r, y: c.y + r), col, 2.0)
            ImDrawListAddLine(drawList, ImVec2(x: c.x - r, y: c.y + r),
                              ImVec2(x: c.x + r, y: c.y - r), col, 2.0)
        }
    }

    /// World-space position of a vertex-mode marker (local path position
    /// pushed through the entity transform).
    private func vertexWorldPosition(index: Int, engine: PhrostEngine) -> Vector3? {
        guard let context = vertexContext(engine: engine),
              context.path.vertices.indices.contains(index)
        else { return nil }
        return context.entity.transform.transformPoint(
            context.path.vertices[index].position)
    }

    // MARK: - Command-line input

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = value.uppercased()
        switch step {
        case .selectTarget:
            switch upper {
            case "M", "MULTIPLE":
                isMultiple = true
                step = .gatherMultiple([])
                openInput(processor, prompt: "Select objects: 0 found. Press Enter when done or [Undo]:")
            case "":
                return .finished
            default:
                processor.commandPrompt = "Select polyline or [Multiple]:"
            }
            return .handled
        case .confirmConvert(let handle, let primIndex, let makePath):
            switch upper {
            case "", "Y", "YES":
                if convertAndStage(
                    handle: handle, primIndex: primIndex, makePath: makePath,
                    engine: engine, processor: processor),
                   let staged = targets.popLast() {
                    enterMenu(targets: [staged], engine: engine, processor: processor)
                } else {
                    step = .selectTarget
                    openInput(processor, prompt: "Select polyline or [Multiple]:")
                }
            case "N", "NO":
                step = .selectTarget
                openInput(processor, prompt: "Select polyline or [Multiple]:")
            default:
                processor.commandPrompt =
                    "Object selected is not a polyline. Do you want to turn it into one? <Y>:"
            }
            return .handled
        case .gatherMultiple(let gathered):
            switch upper {
            case "":
                guard !gathered.isEmpty else { return .finished }
                enterMenu(targets: gathered, engine: engine, processor: processor)
            case "U", "UNDO":
                var rest = gathered
                if let removed = rest.popLast() {
                    engine.cadSelection.removeFromSelection(removed.handle)
                }
                step = .gatherMultiple(rest)
                processor.commandPrompt =
                    "Select objects: \(rest.count) found. Press Enter when done or [Undo]:"
            default:
                processor.commandPrompt =
                    "Select objects: \(gathered.count) found. Press Enter when done or [Undo]:"
            }
            return .handled
        case .mainMenu:
            return handleMenuOption(upper, engine: engine, processor: processor)
        case .awaitWidth:
            guard !value.isEmpty else {
                showMenu(engine: engine, processor: processor)
                return .handled
            }
            guard let width = Double(value), width.isFinite, width >= 0 else {
                openInput(processor, prompt: "Width must be zero or greater. Specify new width for all segments:")
                return .handled
            }
            applyToAll({ PeditGeometryEngine.withGlobalWidth($0, width: width) },
                       what: "Width set to \(format(width)).",
                       engine: engine, processor: processor)
            return .handled
        case .awaitTaperFirst:
            guard !value.isEmpty else {
                showMenu(engine: engine, processor: processor)
                return .handled
            }
            guard let first = Double(value), first.isFinite, first >= 0 else {
                openInput(processor, prompt: "Width must be zero or greater. Specify starting width:")
                return .handled
            }
            step = .awaitTaperSecond(first: first)
            openInput(processor, prompt: "Specify ending width <\(format(first))>:")
            return .handled
        case .awaitTaperSecond(let first):
            let second: Double
            if value.isEmpty {
                second = first
            } else {
                guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
                    openInput(processor, prompt: "Width must be zero or greater. Specify ending width <\(format(first))>:")
                    return .handled
                }
                second = parsed
            }
            applyToAll({ PeditGeometryEngine.tapered($0, from: first, to: second) },
                       what: "Tapered \(format(first)) to \(format(second)).",
                       engine: engine, processor: processor)
            return .handled
        case .vertexMode(let index):
            return handleVertexOption(upper, index: index, engine: engine, processor: processor)
        case .vertexAwaitMove(let index):
            processor.commandPrompt = "Specify new vertex location:"
            step = .vertexAwaitMove(index: index)
            return .handled
        case .vertexAwaitInsert(let index):
            processor.commandPrompt = "Specify new vertex location:"
            step = .vertexAwaitInsert(index: index)
            return .handled
        case .vertexAwaitTangent(let index):
            processor.commandPrompt = "Specify tangent direction:"
            step = .vertexAwaitTangent(index: index)
            return .handled
        case .vertexAwaitWidthFirst(let index):
            guard !value.isEmpty,
                  let first = Double(value), first.isFinite, first >= 0
            else {
                if value.isEmpty {
                    showVertexPrompt(index: index, engine: engine, processor: processor, lead: "")
                } else {
                    openInput(processor, prompt: "Width must be zero or greater. Specify starting width:")
                }
                return .handled
            }
            step = .vertexAwaitWidthSecond(index: index, first: first)
            openInput(processor, prompt: "Specify ending width <\(format(first))>:")
            return .handled
        case .vertexAwaitWidthSecond(let index, let first):
            let second: Double
            if value.isEmpty {
                second = first
            } else {
                guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else {
                    openInput(processor, prompt: "Width must be zero or greater. Specify ending width <\(format(first))>:")
                    return .handled
                }
                second = parsed
            }
            if let context = vertexContext(engine: engine) {
                applyVertexPath(PeditGeometryEngine.withSegmentWidth(
                    context.path, index: index, start: first, end: second),
                    index: index, what: "Segment width set.",
                    engine: engine, processor: processor)
            } else {
                showMenu(engine: engine, processor: processor)
            }
            return .handled
        case .joinPicking(let picked):
            switch upper {
            case "":
                guard !picked.isEmpty else {
                    step = .mainMenu
                    showMenu(engine: engine, processor: processor)
                    return .handled
                }
                performJoin(picked: picked, engine: engine, processor: processor)
            case "U", "UNDO":
                let rest = Array(picked.dropLast())
                step = .joinPicking(rest)
                processor.commandLineActive = true
                processor.commandBuffer = ""
                processor.commandPrompt = joinPrompt(count: rest.count)
            case "X", "EXIT":
                showMenu(engine: engine, processor: processor)
            default:
                processor.commandPrompt = joinPrompt(count: picked.count)
            }
            return .handled
        case .vertexStraightenMark(let first, let second):
            switch upper {
            case "X", "EXIT":
                showVertexPrompt(index: first, engine: engine, processor: processor, lead: "")
            case "N", "NEXT":
                if let context = vertexContext(engine: engine) {
                    let count = context.path.vertices.count
                    let next = (second + 1) % count
                    step = .vertexStraightenMark(first: first, second: next)
                    processor.commandLineActive = true
                    processor.commandBuffer = ""
                    processor.commandPrompt = straightenPrompt(first: first, second: next)
                } else {
                    showMenu(engine: engine, processor: processor)
                }
            case "P", "PREVIOUS", "PREV":
                if let context = vertexContext(engine: engine) {
                    let count = context.path.vertices.count
                    let prev = (second - 1 + count) % count
                    step = .vertexStraightenMark(first: first, second: prev)
                    processor.commandLineActive = true
                    processor.commandBuffer = ""
                    processor.commandPrompt = straightenPrompt(first: first, second: prev)
                } else {
                    showMenu(engine: engine, processor: processor)
                }
            case "", "G", "GO":
                if let context = vertexContext(engine: engine) {
                    applyVertexPath(PeditGeometryEngine.straightened(
                        context.path, from: first, to: second),
                        index: min(first, second),
                        what: "Straightened.", engine: engine, processor: processor)
                } else {
                    showMenu(engine: engine, processor: processor)
                }
            default:
                processor.commandPrompt = straightenPrompt(first: first, second: second)
            }
            return .handled
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        switch step {
        case .selectTarget:
            return [.init(value: "M", title: "Multiple", aliases: ["MULTIPLE"],
                          description: "Edit several polylines together")]
        case .confirmConvert:
            return [
                .init(value: "Y", title: "Yes", aliases: ["YES"],
                      description: "Convert to polyline"),
                .init(value: "N", title: "No", aliases: ["NO"],
                      description: "Keep the object unchanged"),
            ]
        case .gatherMultiple:
            return [.init(value: "U", title: "Undo", aliases: ["UNDO"],
                          description: "Remove the last object from the set")]
        case .mainMenu, .awaitWidth, .awaitTaperFirst, .awaitTaperSecond:
            return menuOptions()
        case .vertexMode:
            return [
                .init(value: "N", title: "Next", aliases: ["NEXT"],
                      description: "Mark the next vertex"),
                .init(value: "P", title: "Previous", aliases: ["PREVIOUS", "PREV"],
                      description: "Mark the previous vertex"),
                .init(value: "B", title: "Break", aliases: ["BREAK"],
                      description: "Split into two polylines here"),
                .init(value: "I", title: "Insert", aliases: ["INSERT"],
                      description: "Add a vertex after this one"),
                .init(value: "D", title: "Delete", aliases: ["DELETE"],
                      description: "Remove this vertex"),
                .init(value: "M", title: "Move", aliases: ["MOVE"],
                      description: "Relocate this vertex"),
                .init(value: "R", title: "Regen", aliases: ["REGEN"],
                      description: "Regenerate the display"),
                .init(value: "S", title: "Straighten", aliases: ["STRAIGHTEN"],
                      description: "Remove vertices up to a second mark"),
                .init(value: "T", title: "Tangent", aliases: ["TANGENT"],
                      description: "Set this vertex's tangent direction"),
                .init(value: "W", title: "Width", aliases: ["WIDTH"],
                      description: "Set the outgoing segment's widths"),
                .init(value: "X", title: "eXit", aliases: ["EXIT"],
                      description: "Back to the polyline options"),
            ]
        case .vertexStraightenMark:
            return [
                .init(value: "N", title: "Next", aliases: ["NEXT"],
                      description: "Move the second mark forward"),
                .init(value: "P", title: "Previous", aliases: ["PREVIOUS", "PREV"],
                      description: "Move the second mark back"),
                .init(value: "G", title: "Go", aliases: ["GO"],
                      description: "Straighten between the marks"),
                .init(value: "X", title: "eXit", aliases: ["EXIT"],
                      description: "Cancel straightening"),
            ]
        case .vertexAwaitMove, .vertexAwaitInsert, .vertexAwaitTangent,
             .vertexAwaitWidthFirst, .vertexAwaitWidthSecond:
            return []
        case .joinPicking:
            return [
                .init(value: "U", title: "Undo", aliases: ["UNDO"],
                      description: "Remove the last object from the join set"),
                .init(value: "X", title: "eXit", aliases: ["EXIT"],
                      description: "Back to the polyline options"),
            ]
        }
    }

    public func activeOptionValues(engine: PhrostEngine) -> Set<String> {
        guard case .mainMenu = step,
              let path = currentPath(engine: engine) else { return [] }
        // Marks the live LtGen state row in the option list.
        return path.lineTypeGenerationEnabled ? ["LT"] : []
    }

    // MARK: - Menu

    private func menuOptions() -> [FeatureCommandTextOption] {
        var options: [FeatureCommandTextOption] = [
            .init(value: "C", title: "Close", aliases: ["CLOSE"],
                  description: "Connect the last vertex to the first"),
            .init(value: "O", title: "Open", aliases: ["OPEN"],
                  description: "Remove the closing segment"),
            .init(value: "J", title: "Join", aliases: ["JOIN"],
                  description: "Join lines, arcs, and polylines"),
            .init(value: "W", title: "Width", aliases: ["WIDTH"],
                  description: "Set one width for all segments"),
        ]
        if !isMultiple {
            options.append(.init(value: "E", title: "Edit vertex", aliases: ["EDIT", "VERTEX"],
                                 description: "Move, insert, delete, or reshape vertices"))
        }
        options += [
            .init(value: "F", title: "Fit", aliases: ["FIT"],
                  description: "Smooth curve through every vertex"),
            .init(value: "S", title: "Spline", aliases: ["SPLINE"],
                  description: "B-spline using vertices as control points"),
            .init(value: "D", title: "Decurve", aliases: ["DECURVE"],
                  description: "Remove Fit/Spline smoothing"),
            .init(value: "LT", title: "Ltype gen", aliases: ["LTYPE", "LTGEN"],
                  description: "Continuous linetype along whole length"),
            .init(value: "R", title: "Reverse", aliases: ["REVERSE"],
                  description: "Flip start and end"),
            .init(value: "T", title: "Taper", aliases: ["TAPER"],
                  description: "Gradient width from first to last vertex"),
            .init(value: "U", title: "Undo", aliases: ["UNDO"],
                  description: "Restore the session-entry state"),
            .init(value: "X", title: "eXit", aliases: ["EXIT"],
                  description: "Finish polyline editing"),
        ]
        return options
    }

    private func handleMenuOption(
        _ upper: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        switch upper {
        case "":
            return .finished
        case "X", "EXIT":
            return .finished
        case "C", "CLOSE":
            guard requiresOpen(engine: engine, processor: processor) else { return .handled }
            applyToAll({ PeditGeometryEngine.closed($0) },
                       what: "Polyline closed.",
                       engine: engine, processor: processor)
        case "O", "OPEN":
            guard requiresClosed(engine: engine, processor: processor) else { return .handled }
            applyToAll({ PeditGeometryEngine.opened($0) },
                       what: "Polyline opened.",
                       engine: engine, processor: processor)
        case "W", "WIDTH":
            step = .awaitWidth
            openInput(processor, prompt: "Specify new width for all segments <\(format(currentUniformWidth(engine: engine)))>:")
        case "T", "TAPER":
            step = .awaitTaperFirst
            openInput(processor, prompt: "Specify starting width <0>:")
        case "LT", "LTYPE", "LTGEN", "LTYPEGEN":
            let enabled = !(currentPath(engine: engine)?.lineTypeGenerationEnabled ?? false)
            applyToAll({ PeditGeometryEngine.withLineTypeGeneration($0, enabled: enabled) },
                       what: enabled ? "Linetype generation on." : "Linetype generation off.",
                       engine: engine, processor: processor)
        case "R", "REVERSE":
            applyToAll({ PeditGeometryEngine.reversed($0) },
                       what: "Reversed.",
                       engine: engine, processor: processor)
        case "U", "UNDO":
            restoreBaselines(engine: engine, processor: processor)
        case "J", "JOIN":
            beginJoin(engine: engine, processor: processor)
        case "E", "EDIT", "VERTEX":
            if isMultiple {
                processor.commandPrompt =
                    "Edit vertex needs a single polyline; rerun PEDIT without Multiple. \(menuPrompt(engine: engine))"
                return .handled
            }
            guard vertexContext(engine: engine) != nil else {
                processor.commandPrompt = menuPrompt(engine: engine)
                return .handled
            }
            showVertexPrompt(index: 0, engine: engine, processor: processor, lead: "")
        case "F", "FIT":
            guard let current = currentPath(engine: engine) else {
                processor.commandPrompt = menuPrompt(engine: engine)
                return .handled
            }
            guard !current.hasBulges else {
                deny("Straighten arc segments before Fit.", engine: engine, processor: processor)
                return .handled
            }
            guard current.curveType == .none,
                  current.vertices.allSatisfy({ $0.kind == .normal })
            else {
                deny("Decurve first: this polyline is already smoothed.", engine: engine, processor: processor)
                return .handled
            }
            applyToAll({ PeditGeometryEngine.fitCurve($0) },
                       what: "Fit complete.",
                       engine: engine, processor: processor)
        case "S", "SPLINE":
            guard let current = currentPath(engine: engine) else {
                processor.commandPrompt = menuPrompt(engine: engine)
                return .handled
            }
            let quadratic = splineTypeIsQuadratic(engine: engine, processor: processor)
            let minimum = quadratic ? 3 : 4
            guard current.vertices.count >= minimum else {
                deny("Spline needs at least \(minimum) vertices (SPLINETYPE=\(quadratic ? 5 : 6)).",
                     engine: engine, processor: processor)
                return .handled
            }
            guard !current.hasBulges else {
                deny("Straighten arc segments before Spline.", engine: engine, processor: processor)
                return .handled
            }
            guard current.curveType == .none,
                  current.vertices.allSatisfy({ $0.kind == .normal })
            else {
                deny("Decurve first: this polyline is already smoothed.", engine: engine, processor: processor)
                return .handled
            }
            applyToAll({ PeditGeometryEngine.splineCurve($0, quadratic: quadratic) },
                       what: "Spline complete.",
                       engine: engine, processor: processor)
        case "D", "DECURVE", "DECURV":
            guard let current = currentPath(engine: engine),
                  PeditGeometryEngine.decurved(current) != nil
            else {
                deny("Nothing to decurve: this polyline is not smoothed.",
                     engine: engine, processor: processor)
                return .handled
            }
            applyToAll({ PeditGeometryEngine.decurved($0) },
                       what: "Decurved.",
                       engine: engine, processor: processor)
        default:
            processor.commandPrompt = menuPrompt(engine: engine)
        }
        return .handled
    }

    // MARK: - Vertex sub-mode (PR3)

    private func handleVertexOption(
        _ upper: String, index: Int, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let context = vertexContext(engine: engine) else {
            showMenu(engine: engine, processor: processor)
            return .handled
        }
        let count = context.path.vertices.count
        switch upper {
        case "X", "EXIT":
            showMenu(engine: engine, processor: processor)
        case "", "N", "NEXT":
            showVertexPrompt(index: (index + 1) % count, engine: engine, processor: processor, lead: "")
        case "P", "PREVIOUS", "PREV":
            showVertexPrompt(index: (index - 1 + count) % count, engine: engine, processor: processor, lead: "")
        case "M", "MOVE":
            step = .vertexAwaitMove(index: index)
            openInput(processor, prompt: "Specify new vertex location:")
        case "I", "INSERT":
            step = .vertexAwaitInsert(index: index)
            openInput(processor, prompt: "Specify new vertex location:")
        case "D", "DELETE":
            if let deleted = PeditGeometryEngine.deleted(context.path, index: index) {
                applyVertexPath(deleted, index: min(index, deleted.vertices.count - 1),
                                what: "Vertex deleted.", engine: engine, processor: processor)
            } else {
                showVertexPrompt(index: index, engine: engine, processor: processor,
                                 lead: "Cannot delete: minimum vertex count reached. ")
            }
        case "B", "BREAK":
            if let pieces = PeditGeometryEngine.breakAt(context.path, index: index) {
                applyVertexBreak(pieces, engine: engine, processor: processor)
            } else {
                showVertexPrompt(index: index, engine: engine, processor: processor,
                                 lead: "Cannot break here. ")
            }
        case "T", "TANGENT":
            step = .vertexAwaitTangent(index: index)
            openInput(processor, prompt: "Specify tangent direction:")
        case "W", "WIDTH":
            step = .vertexAwaitWidthFirst(index: index)
            openInput(processor, prompt: "Specify starting width <\(format(context.path.vertices[index].startWidth))>:")
        case "S", "STRAIGHTEN":
            let second = (index + 1) % count
            step = .vertexStraightenMark(first: index, second: second)
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt = straightenPrompt(first: index, second: second)
        case "R", "REGEN":
            showVertexPrompt(index: index, engine: engine, processor: processor,
                             lead: "Model regenerated. ")
        default:
            showVertexPrompt(index: index, engine: engine, processor: processor, lead: "")
        }
        return .handled
    }

    /// The single target under vertex edit (vertex mode is single-only),
    /// with its live path. Nil when the target vanished or stopped being
    /// a polyline.
    private func vertexContext(engine: PhrostEngine) -> (entity: CADEntity, path: CADPolyline)? {
        guard !isMultiple, let target = targets.first,
              let entity = engine.document.entity(for: target.handle),
              let geometry = entity.localGeometry,
              geometry.indices.contains(target.primIndex),
              case .polyline(let path, _) = geometry[target.primIndex]
        else { return nil }
        return (entity, path)
    }

    private func vertexPrompt(index: Int, engine: PhrostEngine) -> String {
        let count = vertexContext(engine: engine)?.path.vertices.count ?? 0
        return "Vertex \(index + 1)/\(count). Enter vertex option [Next/Previous/Break/Insert/Delete/Move/Regen/Straighten/Tangent/Width/eXit] <N>:"
    }

    private func straightenPrompt(first: Int, second: Int) -> String {
        "Straighten from vertex \(first + 1) to vertex \(second + 1). [Next/Previous/Go/eXit] <Go>:"
    }

    private func showVertexPrompt(
        index: Int, engine: PhrostEngine, processor: CADCommandProcessor, lead: String
    ) {
        guard let context = vertexContext(engine: engine) else {
            showMenu(engine: engine, processor: processor)
            return
        }
        let clamped = min(max(index, 0), context.path.vertices.count - 1)
        step = .vertexMode(index: clamped)
        processor.commandLineActive = true
        processor.commandBuffer = ""
        processor.commandPrompt = "\(lead)\(vertexPrompt(index: clamped, engine: engine))"
    }

    /// Writes an edited path back to the single target in one undo batch,
    /// then re-shows the vertex prompt at `index` (clamped).
    private func applyVertexPath(
        _ path: CADPolyline?, index: Int, what message: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let path, let target = targets.first,
              var entity = engine.document.entity(for: target.handle),
              var geometry = entity.localGeometry,
              geometry.indices.contains(target.primIndex),
              case .polyline(_, let color) = geometry[target.primIndex],
              let clean = PeditGeometryEngine.sanitized(path)
        else {
            // Vertex ops never change the primitive type, so a live target
            // means the edit itself was rejected; otherwise bail to the menu.
            if vertexContext(engine: engine) != nil {
                showVertexPrompt(index: 0, engine: engine, processor: processor,
                                 lead: "Edit rejected. ")
            } else {
                showMenu(engine: engine, processor: processor)
            }
            return
        }
        geometry[target.primIndex] = .polyline(path: clean, color: color)
        entity.localGeometry = geometry
        engine.document.replaceEntities(remove: [target.handle], add: [entity])
        showVertexPrompt(index: min(index, clean.vertices.count - 1),
                         engine: engine, processor: processor, lead: "\(message) ")
    }

    /// Writes a Break result: the first piece keeps the original handle, the
    /// second becomes a new entity (layer, transform, and xdata preserved).
    /// Continues at the main menu; session Undo removes the spawned piece.
    private func applyVertexBreak(
        _ pieces: [CADPolyline], engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let target = targets.first,
              let entity = engine.document.entity(for: target.handle),
              var geometry = entity.localGeometry,
              geometry.indices.contains(target.primIndex),
              case .polyline(_, let color) = geometry[target.primIndex],
              let first = pieces.first
        else {
            showMenu(engine: engine, processor: processor)
            return
        }
        // Earlier spawned pieces stay: each Break splits the live target,
        // so repeated breaks accumulate pieces. Session Undo removes them.
        let removals: Set<UUID> = [target.handle]
        var additions: [CADEntity] = []
        var mutated = entity
        geometry[target.primIndex] = .polyline(path: first, color: color)
        mutated.localGeometry = geometry
        additions.append(mutated)
        for piece in pieces.dropFirst() {
            let spawned = CADEntity(
                layerID: entity.layerID,
                localGeometry: [.polyline(path: piece, color: color)],
                transform: entity.transform,
                xdata: entity.xdata)
            spawnedHandles.append(spawned.handle)
            additions.append(spawned)
        }
        engine.document.replaceEntities(remove: removals, add: additions)
        processor.commandLineActive = true
        processor.commandBuffer = ""
        processor.commandPrompt = pieces.count > 1
            ? "Break created \(pieces.count) polylines. \(menuPrompt(engine: engine))"
            : "Polyline opened. \(menuPrompt(engine: engine))"
        step = .mainMenu
    }

    // MARK: - Join (PR4)

    private func joinPrompt(count: Int) -> String {
        "Select objects to join to the polyline: \(count) found. Press Enter to join or [Undo/eXit]:"
    }

    /// Enters join picking (single mode), or chains every selected target
    /// immediately in Multiple mode.
    private func beginJoin(engine: PhrostEngine, processor: CADCommandProcessor) {
        if isMultiple {
            joinMultipleTargets(engine: engine, processor: processor)
            return
        }
        guard let context = vertexContext(engine: engine) else {
            processor.commandPrompt = menuPrompt(engine: engine)
            return
        }
        guard !context.path.isClosed else {
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt =
                "Open the polyline before joining. \(menuPrompt(engine: engine))"
            return
        }
        guard context.path.curveType == .none else {
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt =
                "Decurve the polyline before joining. \(menuPrompt(engine: engine))"
            return
        }
        step = .joinPicking([])
        openInput(processor, prompt: joinPrompt(count: 0))
    }

    /// Multiple mode: the selection IS the join set — chain every target
    /// after the first into the first, in one undo batch.
    private func joinMultipleTargets(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard targets.count >= 2 else {
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt =
                "Join in Multiple mode needs at least two polylines. \(menuPrompt(engine: engine))"
            return
        }
        guard let firstEntity = engine.document.entity(for: targets[0].handle),
              let firstGeometry = firstEntity.localGeometry,
              firstGeometry.indices.contains(targets[0].primIndex),
              case .polyline(let firstPath, _) = firstGeometry[targets[0].primIndex]
        else {
            showMenu(engine: engine, processor: processor)
            return
        }
        var sources: [PeditGeometryEngine.JoinSource] = []
        var absorbed: [UUID] = []
        for target in targets.dropFirst() {
            guard let entity = engine.document.entity(for: target.handle),
                  let geometry = entity.localGeometry,
                  geometry.indices.contains(target.primIndex),
                  case .polyline(let path, _) = geometry[target.primIndex]
            else { continue }
            sources.append(PeditGeometryEngine.JoinSource(path: path, transform: entity.transform))
            absorbed.append(target.handle)
        }
        guard !sources.isEmpty,
              let joined = PeditGeometryEngine.joinPolylines(
                target: PeditGeometryEngine.JoinSource(path: firstPath, transform: firstEntity.transform),
                sources: sources),
              var mutated = engine.document.entity(for: targets[0].handle),
              var geometry = mutated.localGeometry,
              geometry.indices.contains(targets[0].primIndex),
              case .polyline(_, let color) = geometry[targets[0].primIndex]
        else {
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt =
                "No continuous chain through the selected polylines (endpoints must touch within 0.001). \(menuPrompt(engine: engine))"
            return
        }
        geometry[targets[0].primIndex] = .polyline(path: joined, color: color)
        mutated.localGeometry = geometry
        var removals = Set(absorbed)
        removals.insert(targets[0].handle)
        engine.document.replaceEntities(remove: removals, add: [mutated])
        targets = [targets[0]]
        isMultiple = false
        showMenu(engine: engine, processor: processor)
        processor.commandPrompt = "Joined \(absorbed.count + 1) polylines. \(menuPrompt(engine: engine))"
    }

    /// Picks one join source: a line, an arc, or an open plain polyline from
    /// another entity. The target itself and closed/curved polylines are
    /// rejected with a message. Returns nil on empty space.
    private func pickJoinSource(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor,
        excluding targets: [Target]
    ) -> (handle: UUID, primIndex: Int)? {
        guard let handle = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY,
            document: engine.document,
            threshold: 12.0 / max(engine.camera.zoom, 0.001),
            simplifyComplexBlocks: false),
              let entity = engine.document.entity(for: handle)
        else { return nil }
        if targets.contains(where: { $0.handle == handle }) {
            processor.commandPrompt = "That is the target polyline. " + joinPrompt(count: joinPickedCount)
            return nil
        }
        guard LayerAccess.isEditable(entity: entity, in: engine.document) else {
            processor.commandPrompt = "Object is on a locked layer. " + joinPrompt(count: joinPickedCount)
            return nil
        }
        guard entity.blockID == nil else {
            processor.commandPrompt = "Block references cannot join; explode first. " + joinPrompt(count: joinPickedCount)
            return nil
        }
        guard let geometry = entity.localGeometry else {
            processor.commandPrompt = "No joinable geometry there. " + joinPrompt(count: joinPickedCount)
            return nil
        }
        if let index = geometry.firstIndex(where: {
            if case .polyline(let path, _) = $0 {
                return !path.isHatchBoundaryCarrier && !path.isClosed && path.curveType == .none
            }
            return false
        }) {
            return (handle, index)
        }
        if geometry.contains(where: {
            if case .line = $0 { return true }
            if case .arc = $0 { return true }
            return false
        }), let index = geometry.firstIndex(where: {
            if case .line = $0 { return true }
            if case .arc = $0 { return true }
            return false
        }) {
            return (handle, index)
        }
        processor.commandPrompt =
            "Needs an open polyline, line, or arc (closed and fitted polylines cannot join). " +
            joinPrompt(count: joinPickedCount)
        return nil
    }

    private var joinPickedCount: Int {
        if case .joinPicking(let picked) = step { return picked.count }
        return 0
    }

    /// Resolves picked sources to in-memory join paths (converting lines and
    /// arcs without touching the document), joins them onto the single
    /// target, and commits target + consumed sources in one undo batch.
    private func performJoin(
        picked: [(handle: UUID, primIndex: Int)],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard let context = vertexContext(engine: engine) else {
            showMenu(engine: engine, processor: processor)
            return
        }
        var sources: [PeditGeometryEngine.JoinSource] = []
        var consumed: [CADEntity] = []
        var skipped = 0
        for pick in picked {
            guard let entity = engine.document.entity(for: pick.handle),
                  let geometry = entity.localGeometry,
                  geometry.indices.contains(pick.primIndex)
            else {
                skipped += 1
                continue
            }
            switch geometry[pick.primIndex] {
            case .polyline(let path, _)
                where !path.isClosed && path.curveType == .none
                    && !path.vertices.contains(where: { $0.kind != .normal }):
                sources.append(PeditGeometryEngine.JoinSource(path: path, transform: entity.transform))
                consumed.append(entity)
            case .line(let start, let end, _):
                guard let converted = PeditGeometryEngine.convertedFromLine(start: start, end: end)
                else {
                    skipped += 1
                    continue
                }
                sources.append(PeditGeometryEngine.JoinSource(path: converted, transform: entity.transform))
                consumed.append(entity)
            case .arc(let center, let radius, let startAngle, let endAngle, _):
                guard let converted = PeditGeometryEngine.convertedFromArc(
                    center: center, radius: radius, startAngle: startAngle, endAngle: endAngle)
                else {
                    skipped += 1
                    continue
                }
                sources.append(PeditGeometryEngine.JoinSource(path: converted, transform: entity.transform))
                consumed.append(entity)
            default:
                skipped += 1
            }
        }
        guard !sources.isEmpty,
              let joined = PeditGeometryEngine.joinPolylines(
                target: PeditGeometryEngine.JoinSource(path: context.path, transform: context.entity.transform),
                sources: sources)
        else {
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt =
                "No continuous chain through the target polyline (endpoints must touch within 0.001). " +
                joinPrompt(count: picked.count)
            step = .joinPicking(picked)
            return
        }
        guard let target = targets.first,
              var mutated = engine.document.entity(for: target.handle),
              var geometry = mutated.localGeometry,
              geometry.indices.contains(target.primIndex),
              case .polyline(_, let color) = geometry[target.primIndex]
        else {
            showMenu(engine: engine, processor: processor)
            return
        }
        geometry[target.primIndex] = .polyline(path: joined, color: color)
        mutated.localGeometry = geometry
        var removals = Set(consumed.map(\.handle))
        removals.insert(target.handle)
        engine.document.replaceEntities(remove: removals, add: [mutated])
        consumedEntities.append(contentsOf: consumed)
        let tail = skipped > 0 ? " (\(skipped) skipped.)" : ""
        step = .mainMenu
        processor.commandLineActive = true
        processor.commandBuffer = ""
        processor.commandPrompt = "Joined \(consumed.count) object(s)\(tail). \(menuPrompt(engine: engine))"
    }

    // MARK: - Targets

    private enum Picked {
        case polyline(Target)
        case convertible(handle: UUID, primIndex: Int, makePath: () -> CADPolyline?)
        case rejected(String)
    }

    private func pickTarget(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Picked? {
        guard let handle = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY,
            document: engine.document,
            threshold: 12.0 / max(engine.camera.zoom, 0.001),
            simplifyComplexBlocks: false),
              let entity = engine.document.entity(for: handle)
        else {
            // Clicked empty space: keep the current prompt.
            // (selectTarget always shows the select prompt already.)
            return nil
        }
        switch classifyEntity(entity, in: engine.document) {
        case .polyline(let primIndex):
            return .polyline(Target(handle: handle, primIndex: primIndex, baseline: entity))
        case .convertible(let primIndex, let makePath):
            return .convertible(handle: handle, primIndex: primIndex, makePath: makePath)
        case .rejected(let message):
            return .rejected(message)
        }
    }

    private enum EntityClass {
        case polyline(primIndex: Int)
        case convertible(primIndex: Int, makePath: () -> CADPolyline?)
        case rejected(String)
    }

    /// Shared target classification for click-picking and noun-verb
    /// adoption, so both paths accept and reject the same objects.
    private func classifyEntity(_ entity: CADEntity, in document: CADDocument) -> EntityClass {
        guard LayerAccess.isEditable(entity: entity, in: document) else {
            return .rejected("Object is on a locked layer.")
        }
        guard let geometry = entity.localGeometry else {
            return .rejected("Selected object has no editable geometry.")
        }
        if let index = geometry.firstIndex(where: {
            if case .polyline(let path, _) = $0 { return !path.isHatchBoundaryCarrier }
            return false
        }) {
            return .polyline(primIndex: index)
        }
        if geometry.contains(where: {
            if case .polyline(let path, _) = $0 { return path.isHatchBoundaryCarrier }
            return false
        }) {
            return .rejected("Hatch boundaries cannot be edited with PEDIT.")
        }
        if let index = geometry.firstIndex(where: {
            if case .line = $0 { return true }
            if case .arc = $0 { return true }
            return false
        }) {
            let primitive = geometry[index]
            let makePath: () -> CADPolyline?
            switch primitive {
            case .line(let start, let end, _):
                makePath = { PeditGeometryEngine.convertedFromLine(start: start, end: end) }
            case .arc(let center, let radius, let startAngle, let endAngle, _):
                makePath = {
                    PeditGeometryEngine.convertedFromArc(
                        center: center, radius: radius,
                        startAngle: startAngle, endAngle: endAngle)
                }
            default:
                return .rejected("Selected object is not a polyline.")
            }
            return .convertible(primIndex: index, makePath: makePath)
        }
        return .rejected("Selected object is not a polyline.")
    }

    /// Noun-verb: adopts the pickfirst selection made before PEDIT started.
    /// Returns true when a menu, gather, or convert state was entered (the
    /// caller must not overwrite the prompt); false leaves the select
    /// prompt to the caller.
    private func adoptPreselection(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        let preselected = initialSelection
        guard !preselected.isEmpty else { return false }
        var usable: [Target] = []
        var convertible: [(handle: UUID, primIndex: Int, makePath: () -> CADPolyline?)] = []
        var locked = 0
        var rejected = 0
        for handle in preselected {
            guard let entity = engine.document.entity(for: handle) else { continue }
            switch classifyEntity(entity, in: engine.document) {
            case .polyline(let primIndex):
                usable.append(Target(handle: handle, primIndex: primIndex, baseline: entity))
            case .convertible(let primIndex, let makePath):
                convertible.append((handle, primIndex, makePath))
            case .rejected(let message):
                if message == "Object is on a locked layer." { locked += 1 }
                else { rejected += 1 }
            }
        }
        // Convert lines/arcs in place when PEDITACCEPT allows; a lone
        // convertible without it goes through the normal Yes/No offer.
        if peditAccept(engine: engine, processor: processor) {
            for item in convertible {
                if convertAndStage(
                    handle: item.handle, primIndex: item.primIndex,
                    makePath: item.makePath, engine: engine, processor: processor),
                   let staged = targets.popLast() {
                    usable.append(staged)
                } else {
                    rejected += 1
                }
            }
            convertible = []
        } else if convertible.count == 1, usable.isEmpty, locked == 0, rejected == 0 {
            let item = convertible[0]
            offerConversion(
                handle: item.handle, primIndex: item.primIndex, makePath: item.makePath,
                engine: engine, processor: processor)
            return true
        }
        let skipped = locked + rejected + convertible.count
        guard !usable.isEmpty else {
            let reason: String
            if locked > 0, rejected == 0, convertible.isEmpty {
                reason = "Selected objects are on locked layers."
            } else if convertible.isEmpty {
                reason = "No usable polylines selected."
            } else {
                reason = "Selected lines/arcs need PEDITACCEPT=1 to convert."
            }
            openInput(processor, prompt: "\(reason) Select polyline or [Multiple]:")
            return true
        }
        isMultiple = usable.count > 1
        enterMenu(targets: usable, engine: engine, processor: processor)
        if skipped > 0 {
            processor.commandPrompt =
                "\(skipped) selected object(s) skipped (locked, non-polyline, or PEDITACCEPT=0). " +
                menuPrompt(engine: engine)
        }
        return true
    }

    private func peditAccept(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        if case .int(let value) = processor.lispVars.get(
            "PEDITACCEPT", document: engine.document, activeCommand: nil) {
            return value != 0
        }
        return false
    }

    private func offerConversion(
        handle: UUID, primIndex: Int, makePath: @escaping () -> CADPolyline?,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        if peditAccept(engine: engine, processor: processor) {
            if convertAndStage(
                handle: handle, primIndex: primIndex, makePath: makePath,
                engine: engine, processor: processor),
               let staged = targets.popLast() {
                enterMenu(targets: [staged], engine: engine, processor: processor)
            } else {
                step = .selectTarget
                openInput(processor, prompt: "Select polyline or [Multiple]:")
            }
            return
        }
        step = .confirmConvert(handle: handle, primIndex: primIndex, convertToPolyline: makePath)
        openInput(processor, prompt:
            "Object selected is not a polyline. Do you want to turn it into one? <Y>:")
    }

    /// Converts a line/arc primitive in place (handle, layer, and transform
    /// preserved) and stages the result. Returns false when conversion fails.
    @discardableResult
    private func convertAndStage(
        handle: UUID, primIndex: Int, makePath: () -> CADPolyline?,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        guard let entity = engine.document.entity(for: handle),
              var geometry = entity.localGeometry,
              geometry.indices.contains(primIndex),
              let path = makePath(),
              let clean = PeditGeometryEngine.sanitized(path) else {
            processor.commandPrompt = "Cannot convert that object to a polyline."
            return false
        }
        var staged = entity
        geometry[primIndex] = .polyline(path: clean, color: primitiveColor(of: geometry[primIndex]))
        staged.localGeometry = geometry
        engine.document.replaceEntities(remove: [handle], add: [staged])
        targets.append(Target(handle: handle, primIndex: primIndex, baseline: entity))
        // Additive: `select` would drop other gathered targets.
        engine.cadSelection.addToSelection(handle)
        return true
    }

    private func primitiveColor(of primitive: CADPrimitive) -> ColorRGBA? {
        switch primitive {
        case .line(_, _, let c): return c
        case .arc(_, _, _, _, let c): return c
        case .polyline(_, let c): return c
        default: return nil
        }
    }

    private func enterMenu(
        targets newTargets: [Target],
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        targets = newTargets
        spawnedHandles = []
        consumedEntities = []
        // Additive: never drop preselected or previously gathered objects.
        // Cancel restores `initialSelection` exactly.
        for target in newTargets {
            engine.cadSelection.addToSelection(target.handle)
        }
        step = .mainMenu
        showMenu(engine: engine, processor: processor)
    }

    private func showMenu(engine: PhrostEngine, processor: CADCommandProcessor) {
        step = .mainMenu
        processor.commandLineActive = true
        processor.commandBuffer = ""
        processor.commandPrompt = menuPrompt(engine: engine)
    }

    private func menuPrompt(engine: PhrostEngine) -> String {
        let closeOpen = (currentPath(engine: engine)?.isClosed ?? false) ? "Open" : "Close"
        let scope = isMultiple ? "\(targets.count) polylines. " : ""
        return "\(scope)Enter polyline option [\(closeOpen)/Join/Width/Edit vertex/Fit/Spline/Decurve/Ltype gen/Reverse/Taper/Undo/eXit] <X>:"
    }

    private func currentPath(engine: PhrostEngine) -> CADPolyline? {
        guard let first = targets.first,
              let entity = engine.document.entity(for: first.handle),
              let geometry = entity.localGeometry,
              geometry.indices.contains(first.primIndex),
              case .polyline(let path, _) = geometry[first.primIndex]
        else { return nil }
        return path
    }

    private func currentUniformWidth(engine: PhrostEngine) -> Double {
        guard let path = currentPath(engine: engine) else { return 0 }
        let widths = path.vertices.flatMap { [$0.startWidth, $0.endWidth] }
        guard let first = widths.first, widths.allSatisfy({ $0 == first }) else { return 0 }
        return first
    }

    private func requiresOpen(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        guard let path = currentPath(engine: engine) else {
            processor.commandPrompt = menuPrompt(engine: engine)
            return false
        }
        guard !path.isClosed else {
            processor.commandPrompt = "Polyline is already closed. \(menuPrompt(engine: engine))"
            return false
        }
        return true
    }

    private func requiresClosed(engine: PhrostEngine, processor: CADCommandProcessor) -> Bool {
        guard let path = currentPath(engine: engine) else {
            processor.commandPrompt = menuPrompt(engine: engine)
            return false
        }
        guard path.isClosed else {
            processor.commandPrompt = "Polyline is already open. \(menuPrompt(engine: engine))"
            return false
        }
        return true
    }

    /// Applies `transform` to every target's polyline in one `replaceEntities`
    /// batch (one undo entry, also in Multiple mode), then re-shows the menu.
    private func applyToAll(
        _ transform: (CADPolyline) -> CADPolyline?,
        what message: String,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        var removals: Set<UUID> = []
        var additions: [CADEntity] = []
        var failures = 0
        for target in targets {
            guard let entity = engine.document.entity(for: target.handle),
                  var geometry = entity.localGeometry,
                  geometry.indices.contains(target.primIndex),
                  case .polyline(let path, let color) = geometry[target.primIndex],
                  let updated = transform(path),
                  let clean = PeditGeometryEngine.sanitized(updated)
            else {
                failures += 1
                continue
            }
            var mutated = entity
            geometry[target.primIndex] = .polyline(path: clean, color: color)
            mutated.localGeometry = geometry
            removals.insert(target.handle)
            additions.append(mutated)
        }
        if !additions.isEmpty {
            engine.document.replaceEntities(remove: removals, add: additions)
        }
        let tail = failures > 0 ? " (\(failures) skipped.)" : ""
        // The menu prompt is shown: the state must match it, or the next
        // keystroke routes to the stale await-state instead of the menu.
        step = .mainMenu
        processor.commandLineActive = true
        processor.commandBuffer = ""
        processor.commandPrompt = "\(message)\(tail) \(menuPrompt(engine: engine))"
    }

    /// Restores every target to its session-entry state in one undo batch.
    private func restoreBaselines(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        var removals: Set<UUID> = Set(spawnedHandles)
        spawnedHandles = []
        var additions: [CADEntity] = []
        for target in targets {
            removals.insert(target.handle)
            additions.append(target.baseline)
        }
        // Re-add join-consumed sources; baselines cover absorbed targets.
        additions.append(contentsOf: consumedEntities)
        consumedEntities = []
        engine.document.replaceEntities(remove: removals, add: additions)
        // Drop targets that are no longer polylines (e.g. Undo of a
        // conversion restores the original line/arc).
        targets = targets.filter { target in
            guard let entity = engine.document.entity(for: target.handle),
                  let geometry = entity.localGeometry,
                  geometry.indices.contains(target.primIndex),
                  case .polyline = geometry[target.primIndex]
            else { return false }
            return true
        }
        if targets.isEmpty, !isMultiple {
            step = .selectTarget
            processor.commandLineActive = true
            processor.commandBuffer = ""
            processor.commandPrompt = "Restored. Select polyline or [Multiple]:"
            return
        }
        processor.commandLineActive = true
        processor.commandBuffer = ""
        processor.commandPrompt = "Restored. \(menuPrompt(engine: engine))"
    }

    // MARK: - Prompts

    private func openInput(_ processor: CADCommandProcessor, prompt: String) {
        processor.commandPrompt = prompt
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func deny(
        _ message: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        processor.commandLineActive = true
        processor.commandBuffer = ""
        processor.commandPrompt = "\(message) \(menuPrompt(engine: engine))"
    }

    /// SPLINETYPE system variable: 5 = quadratic, anything else = cubic (6).
    private func splineTypeIsQuadratic(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> Bool {
        if case .int(let value) = processor.lispVars.get(
            "SPLINETYPE", document: engine.document, activeCommand: nil) {
            return value == 5
        }
        return false
    }
}
