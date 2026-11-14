import Foundation
import CSDL3
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - CircleCommand
// =========================================================================

/// Interactive circle drawing with AutoCAD parity:
/// - center point then radius (default) / diameter via `D` (and `R` back)
/// - `2P`: two diameter endpoints
/// - `3P`: three points on circumference
/// - `T` / `Ttr`: tangent-tangent-radius (two objects + radius)
/// - `TTT`: tangent-tangent-tangent (three objects, no radius)
/// Enter with no numeric input reuses `CIRCLERAD`.
@MainActor
public final class CircleCommand: FeatureCommand {

    private enum State {
        case initial
        case awaitingRadius(center: Vector3, isDiameter: Bool)
        case awaiting2PFirst
        case awaiting2PSecond(first: Vector3)
        case awaiting3PFirst
        case awaiting3PSecond(first: Vector3)
        case awaiting3PThird(first: Vector3, second: Vector3)
        case awaitingTTRFirst
        case awaitingTTRSecond(first: FiniteTangentSupport, pick: Vector3)
        case awaitingTTRRadius(first: FiniteTangentSupport, second: FiniteTangentSupport, firstPick: Vector3, secondPick: Vector3)
        case awaitingTTTFirst
        case awaitingTTTSecond(first: FiniteTangentSupport, pick: Vector3)
        case awaitingTTTThird(first: FiniteTangentSupport, second: FiniteTangentSupport, firstPick: Vector3, secondPick: Vector3)
    }

    private var state: State = .initial
    private var currentMouseWorldX: Double = 0
    private var currentMouseWorldY: Double = 0
    private var input = DynamicNumericInput()
    private var pendingKeyword: String? = nil

    public init() {}

    public var isSnappingEnabled: Bool {
        switch state {
        case .awaitingTTRFirst, .awaitingTTRSecond, .awaitingTTTFirst, .awaitingTTTSecond, .awaitingTTTThird:
            return false
        default:
            return true
        }
    }

    public func getDrawingSnapPoints() -> [Vector3] {
        switch state {
        case .awaiting2PSecond(let f): return [f]
        case .awaiting3PSecond(let f): return [f]
        case .awaiting3PThird(let f, let s): return [f, s]
        case .awaitingRadius(let c, _): return [c]
        default: return []
        }
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .initial
        pendingKeyword = nil
        input.reset()
        input.tabCycle = [.radius]
        processor.commandPrompt = initialPrompt()
        // Do not pop the command window; prompt is shown without forcing the input field active.
        processor.commandLineActive = false
        processor.commandBuffer = ""
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .initial
        pendingKeyword = nil
        input.reset()
        // Finish/cancel must dismiss the command window (see finishFeatureCommand clearing prompt).
        // Setting active here would re-show it after a successful circle.
        processor.commandLineActive = false
        processor.commandBuffer = ""
        processor.commandPrompt = nil
    }

    private func initialPrompt() -> String {
        "Specify center point for circle or [3P/2P/Ttr (tan tan radius)]:"
    }

    private func radiusPrompt(isDiameter: Bool) -> String {
        if let last = CircleSettings.lastRadius {
            if isDiameter {
                return "Specify diameter of circle or [Radius] <\(String(format: "%.4f", last*2))>:"
            } else {
                return "Specify radius of circle or [Diameter] <\(String(format: "%.4f", last))>:"
            }
        } else {
            return isDiameter ? "Specify diameter of circle or [Radius]:" : "Specify radius of circle or [Diameter]:"
        }
    }

    // MARK: - Geometry helpers

    func radiusFromTyped(_ value: Double, isDiameter: Bool) -> Double {
        CircleMath.radiusFromDiameter(value)
    }

    // Finite validation for TTR/TTT candidates
    func validTTRCandidates(
        radius: Double,
        with first: FiniteTangentSupport,
        second: FiniteTangentSupport,
        nearPicks: [Vector3]
    ) -> [Vector3] {
        let centers = TangentCircleSolver.circlesTangentTo(radius: radius, first: first.infinite, second: second.infinite, nearPicks: nearPicks)
        return centers.filter { c in
            guard let t1 = TangentCircleSolver.tangentPointPublic(on: first.infinite, center: c, radius: radius),
                  let t2 = TangentCircleSolver.tangentPointPublic(on: second.infinite, center: c, radius: radius) else { return false }
            return first.containsTangentPoint(t1) && second.containsTangentPoint(t2)
        }
    }

    // MARK: - Mouse

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let pt = Vector3(x: worldX, y: worldY, z: 0)
        switch state {
        case .initial:
            // In initial state a click is a center point.
            processor.commandLineActive = false
            processor.commandBuffer = ""
            let dMode = pendingKeyword == "D"
            pendingKeyword = nil
            state = .awaitingRadius(center: pt, isDiameter: dMode)
            input.reset()
            input.tabCycle = [dMode ? .diameter : .radius]
            processor.commandPrompt = radiusPrompt(isDiameter: dMode)
            return .continue
        case .awaitingRadius(let c, _):
            let r = CircleMath.radiusFromPick(center: c, pick: pt)
            guard r > 1e-9 else {
                processor.commandPrompt = "Radius too small. Try again."
                return .continue
            }
            return commitCircle(center: c, radius: r, engine: engine, processor: processor)
        case .awaiting2PFirst:
            state = .awaiting2PSecond(first: pt)
            processor.commandPrompt = "Specify second end point of circle's diameter:"
            processor.commandLineActive = false
            return .continue
        case .awaiting2PSecond(let first):
            guard first.distance(to: pt) > 1e-9 else {
                processor.commandPrompt = "Points are coincident. Specify second end point of circle's diameter:"
                return .handled
            }
            let solved = CircleMath.circleFromTwoPoints(first, pt)
            return commitCircle(center: solved.center, radius: solved.radius, engine: engine, processor: processor)
        case .awaiting3PFirst:
            state = .awaiting3PSecond(first: pt)
            processor.commandPrompt = "Specify second point:"
            processor.commandLineActive = false
            return .continue
        case .awaiting3PSecond(let f):
            guard f.distance(to: pt) > 1e-9 else {
                processor.commandPrompt = "Points are coincident. Specify second point:"
                return .handled
            }
            state = .awaiting3PThird(first: f, second: pt)
            processor.commandPrompt = "Specify third point:"
            return .continue
        case .awaiting3PThird(let a, let b):
            guard a.distance(to: pt) > 1e-9, b.distance(to: pt) > 1e-9 else {
                processor.commandPrompt = "Duplicate point. Specify third point:"
                return .handled
            }
            guard let solved = CADGeometryMath.circleThroughThreePoints(a, b, pt) else {
                processor.commandPrompt = "Points are collinear. Specify third point off the chord:"
                return .continue
            }
            return commitCircle(center: solved.center, radius: solved.radius, engine: engine, processor: processor)
        case .awaitingTTRFirst:
            guard let picked = pickTangentSupport(engine: engine, worldPoint: pt) else {
                processor.commandPrompt = "Cannot create tangent circle for that object. Specify object to draw the circle tangent to:"
                return .handled
            }
            state = .awaitingTTRSecond(first: picked.support, pick: pt)
            processor.commandPrompt = "Specify second object to draw the circle tangent to:"
            return .handled
        case .awaitingTTRSecond(let first, let firstPick):
            guard let picked = pickTangentSupport(engine: engine, worldPoint: pt) else {
                processor.commandPrompt = "Cannot create tangent circle for that object. Specify second object to draw the circle tangent to:"
                return .handled
            }
            state = .awaitingTTRRadius(first: first, second: picked.support, firstPick: firstPick, secondPick: pt)
            input.reset()
            input.tabCycle = [.radius]
            let defaultStr = CircleSettings.lastRadius.map { " <\(String(format: "%.4f", $0))>" } ?? ""
            processor.commandPrompt = "Specify radius of circle\(defaultStr):"
            processor.commandLineActive = true
            processor.commandBuffer = ""
            return .handled
        case .awaitingTTRRadius:
            // Click does not define TTR radius; typed radius or Enter default is required.
            processor.commandPrompt = "Specify radius of circle:"
            input.reset()
            return .handled
        case .awaitingTTTFirst:
            guard let picked = pickTangentSupport(engine: engine, worldPoint: pt) else {
                processor.commandPrompt = "Cannot create tangent circle for that object. Specify first object to draw the circle tangent to:"
                return .handled
            }
            state = .awaitingTTTSecond(first: picked.support, pick: pt)
            processor.commandPrompt = "Specify second object to draw the circle tangent to:"
            return .handled
        case .awaitingTTTSecond(let first, let firstPick):
            guard let picked = pickTangentSupport(engine: engine, worldPoint: pt) else {
                processor.commandPrompt = "Cannot create tangent circle for that object. Specify second object to draw the circle tangent to:"
                return .handled
            }
            state = .awaitingTTTThird(first: first, second: picked.support, firstPick: firstPick, secondPick: pt)
            processor.commandPrompt = "Specify third object to draw the circle tangent to:"
            return .handled
        case .awaitingTTTThird(let f1, let f2, let fp1, let fp2):
            guard let picked = pickTangentSupport(engine: engine, worldPoint: pt) else {
                processor.commandPrompt = "Cannot create tangent circle for that object. Specify third object to draw the circle tangent to:"
                return .handled
            }
            let near = [fp1, fp2, pt]
            guard let solved = TangentCircleSolver.circleTangentToThree(f1.infinite, f2.infinite, picked.support.infinite, nearPicks: near) else {
                processor.commandPrompt = "Cannot create tangent circle for those objects. Specify third object to draw the circle tangent to:"
                return .handled
            }
            // finite validation
            guard let t1 = TangentCircleSolver.tangentPointPublic(on: f1.infinite, center: solved.center, radius: solved.radius),
                  let t2 = TangentCircleSolver.tangentPointPublic(on: f2.infinite, center: solved.center, radius: solved.radius),
                  let t3 = TangentCircleSolver.tangentPointPublic(on: picked.support.infinite, center: solved.center, radius: solved.radius),
                  f1.containsTangentPoint(t1), f2.containsTangentPoint(t2), picked.support.containsTangentPoint(t3) else {
                processor.commandPrompt = "Cannot create tangent circle for those objects. Specify third object to draw the circle tangent to:"
                return .handled
            }
            return commitCircle(center: solved.center, radius: solved.radius, engine: engine, processor: processor)
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        currentMouseWorldX = worldX
        currentMouseWorldY = worldY
    }

    // MARK: - Keyboard (canvas keys)

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        // When command line is active, letters go to the buffer — don't intercept.
        if processor.commandLineActive {
            let dynResult = input.handleKey(scancode)
            switch dynResult {
            case .ignored: break
            case .consumed: return .handled
            case .commitValue(let val): return handleTypedRadius(val, isDiameter: currentIsDiameter(), engine: engine, processor: processor)
            case .commitAngle: return .handled
            case .cancel:
                if case .awaitingRadius = state {
                    return .finished
                }
                return .finished
            }
        } else {
            // Canvas keys while prompt is shown (e.g. after clicking center, before typing).
            // Handle D/R/T/2/3 shortcuts where appropriate.
            switch state {
            case .initial:
                if scancode == SDL_SCANCODE_D {
                    // D at initial: center then diameter
                    // We stay in initial awaiting center but flag diameter for next radius.
                    // Simplest: show prompt to click center; next radius will be diameter.
                    // ForNow directly interpret: prompt remains, but we remember pending d.
                    pendingKeyword = "D"
                    processor.commandPrompt = "Specify center point (Diameter mode):"
                    processor.commandLineActive = false
                    processor.commandBuffer = ""
                    return .handled
                }
            case .awaitingRadius(_, let isDiameter):
                if scancode == SDL_SCANCODE_D && !isDiameter {
                    switchToDiameterMode(engine: engine, processor: processor)
                    return .handled
                }
                if scancode == SDL_SCANCODE_R && isDiameter {
                    switchToRadiusMode(engine: engine, processor: processor)
                    return .handled
                }
                if scancode == SDL_SCANCODE_T && !processor.commandLineActive {
                    // switch to TTR? Not in AutoCAD; ignore
                    break
                }
            default:
                break
            }
            // numeric input when not command-line active still works (dynamic pill)
            let dynResult = input.handleKey(scancode)
            switch dynResult {
            case .ignored: break
            case .consumed: return .handled
            case .commitValue(let val): return handleTypedRadius(val, isDiameter: currentIsDiameter(), engine: engine, processor: processor)
            case .commitAngle: return .handled
            case .cancel: return .finished
            }
        }
        // Legacy Escape
        switch scancode {
        case SDL_SCANCODE_ESCAPE:
            return .finished
        default:
            return .continue
        }
    }

    private func currentIsDiameter() -> Bool {
        if case .awaitingRadius(_, let d) = state { return d }
        if pendingKeyword == "D" { return true }
        return false
    }

    private func switchToDiameterMode(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard case .awaitingRadius(let c, _) = state else { return }
        state = .awaitingRadius(center: c, isDiameter: true)
        input.reset()
        input.tabCycle = [.diameter]
        processor.commandPrompt = radiusPrompt(isDiameter: true)
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    private func switchToRadiusMode(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard case .awaitingRadius(let c, _) = state else { return }
        state = .awaitingRadius(center: c, isDiameter: false)
        input.reset()
        input.tabCycle = [.radius]
        processor.commandPrompt = radiusPrompt(isDiameter: false)
        processor.commandLineActive = true
        processor.commandBuffer = ""
    }

    private func handleTypedRadius(_ value: Double, isDiameter: Bool, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        switch state {
        case .awaitingRadius(let c, _):
            let r = isDiameter ? CircleMath.radiusFromDiameter(value) : value
            guard r > 1e-9 else {
                processor.commandPrompt = "Radius must be positive."
                return .handled
            }
            return commitCircle(center: c, radius: r, engine: engine, processor: processor)
        case .awaitingTTRRadius(let f1, let f2, let fp1, let fp2):
            guard value > 1e-9 else {
                processor.commandPrompt = "Radius must be positive."
                return .handled
            }
            let cands = validTTRCandidates(radius: value, with: f1, second: f2, nearPicks: [fp1, fp2])
            guard let first = cands.first else {
                processor.commandPrompt = "Cannot create tangent circle with that radius. Specify radius of circle:"
                return .handled
            }
            return commitCircle(center: first, radius: value, engine: engine, processor: processor)
        default:
            processor.commandPrompt = "Click a center point first."
            return .handled
        }
    }

    // MARK: - Command-line text

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        // Empty = Enter (default)
        if trimmed.isEmpty {
            switch state {
            case .awaitingRadius(let c, let isDiameter):
                if let last = CircleSettings.lastRadius {
                    // CIRCLERAD is a radius; default display in diameter mode is last*2,
                    // but commit is always radius = last.
                    return commitCircle(center: c, radius: last, engine: engine, processor: processor)
                } else {
                    processor.commandPrompt = radiusPrompt(isDiameter: isDiameter)
                    return .handled
                }
            case .awaitingTTRRadius(let f1, let f2, let fp1, let fp2):
                if let last = CircleSettings.lastRadius {
                    let cands = validTTRCandidates(radius: last, with: f1, second: f2, nearPicks: [fp1, fp2])
                    guard let first = cands.first else {
                        processor.commandPrompt = "Cannot create tangent circle with that radius. Specify radius of circle:"
                        return .handled
                    }
                    return commitCircle(center: first, radius: last, engine: engine, processor: processor)
                } else {
                    processor.commandPrompt = "Specify radius of circle:"
                    return .handled
                }
            default:
                return .handled
            }
        }

        // Try numeric / CAL expression first for radius states
        if case .awaitingRadius(_, let isDiameter) = state {
            // Check D/R switch keywords
            if upper == "D" || upper == "DIAMETER" {
                switchToDiameterMode(engine: engine, processor: processor)
                return .handled
            }
            if upper == "R" || upper == "RADIUS" {
                switchToRadiusMode(engine: engine, processor: processor)
                return .handled
            }
            if let val = Double(trimmed), val != 0 {
                return handleTypedRadius(val, isDiameter: isDiameter, engine: engine, processor: processor)
            }
            if let val = NumericExpressionEvaluator.evaluate(trimmed), val != 0 {
                return handleTypedRadius(val, isDiameter: isDiameter, engine: engine, processor: processor)
            }
            // D/R typed as command text via DynamicNumericInput
            let dyn = input.handleText(trimmed)
            if case .commitValue(let v) = dyn {
                return handleTypedRadius(v, isDiameter: isDiameter, engine: engine, processor: processor)
            }
            // else fall through to ignored
        }
        if case .awaitingTTRRadius = state {
            if let val = Double(trimmed), val != 0 {
                return handleTypedRadius(val, isDiameter: false, engine: engine, processor: processor)
            }
            if let val = NumericExpressionEvaluator.evaluate(trimmed), val != 0 {
                return handleTypedRadius(val, isDiameter: false, engine: engine, processor: processor)
            }
            let dyn2 = input.handleText(trimmed)
            if case .commitValue(let v) = dyn2 {
                return handleTypedRadius(v, isDiameter: false, engine: engine, processor: processor)
            }
            // Switch diameter? TTR uses radius only
        }

        // Typed point entry for point-awaiting states (e.g. "10,20")
        if let pt = InsertCommand.parsePoint(trimmed) {
            switch state {
            case .initial:
                processor.commandLineActive = false
                processor.commandBuffer = ""
                if pendingKeyword == "D" {
                    pendingKeyword = nil
                    state = .awaitingRadius(center: pt, isDiameter: true)
                    input.reset(); input.tabCycle = [.diameter]
                    processor.commandPrompt = radiusPrompt(isDiameter: true)
                } else {
                    state = .awaitingRadius(center: pt, isDiameter: false)
                    input.reset(); input.tabCycle = [.radius]
                    processor.commandPrompt = radiusPrompt(isDiameter: false)
                }
                return .handled
            case .awaiting2PFirst, .awaiting2PSecond, .awaiting3PFirst, .awaiting3PSecond, .awaiting3PThird:
                // delegate to mouse handler
                return handleMouseClick(worldX: pt.x, worldY: pt.y, engine: engine, processor: processor)
            default:
                break
            }
        }

        // Keyword dispatch per state
        switch state {
        case .initial:
            switch upper {
            case "2P", "2POINT":
                state = .awaiting2PFirst
                processor.commandPrompt = "Specify first end point of circle's diameter:"
                processor.commandLineActive = false
                return .handled
            case "3P", "3POINT":
                state = .awaiting3PFirst
                processor.commandPrompt = "Specify first point on circle:"
                processor.commandLineActive = false
                return .handled
            case "T", "TTR":
                state = .awaitingTTRFirst
                processor.commandPrompt = "Specify object to draw the circle tangent to:"
                processor.commandLineActive = false
                return .handled
            case "TTT", "TANTANTAN":
                state = .awaitingTTTFirst
                processor.commandPrompt = "Specify first object to draw the circle tangent to:"
                processor.commandLineActive = false
                return .handled
            case "D", "DIAMETER":
                pendingKeyword = "D"
                processor.commandPrompt = "Specify center point (Diameter mode):"
                return .handled
            case "R", "RADIUS":
                pendingKeyword = nil
                processor.commandPrompt = initialPrompt()
                return .handled
            default:
                // Not a keyword: try to interpret as point via InsertCommand already handled; else ignore if numeric etc.
                // If it's a number while in initial, treat as error (need center first)
                // Let processor try other commands? We return continue to allow fallback.
                return .continue
            }
        case .awaitingRadius:
            // already handled D/R/numeric above; any other word is invalid
            processor.commandPrompt = radiusPrompt(isDiameter: currentIsDiameter())
            return .handled
        case .awaiting2PFirst, .awaiting2PSecond, .awaiting3PFirst, .awaiting3PSecond, .awaiting3PThird:
            // point states only accept points; reject keywords
            switch upper {
            case "2P","3P","T","TTR","TTT":
                processor.commandPrompt = "Specify point:"
                return .handled
            default:
                return .continue
            }
        case .awaitingTTRFirst, .awaitingTTRSecond:
            // object picks need clicks; typed words rejected
            return .handled
        case .awaitingTTRRadius:
            return .handled
        case .awaitingTTTFirst, .awaitingTTTSecond, .awaitingTTTThird:
            return .handled
        }
    }

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        let opts: [FeatureCommandTextOption]
        switch state {
        case .initial:
            opts = [
                .init(value: "3P", title: "3P", aliases: ["3POINT"], description: "Three points on circumference"),
                .init(value: "2P", title: "2P", aliases: ["2POINT"], description: "Two endpoints of diameter"),
                .init(value: "T", title: "Ttr", aliases: ["TTR", "TAN"], description: "Tangent, tangent, radius"),
            ]
        case .awaitingRadius(_, let isDiameter):
            if isDiameter {
                opts = [.init(value: "R", title: "Radius", aliases: ["RADIUS"], description: "Switch to radius entry")]
            } else {
                opts = [.init(value: "D", title: "Diameter", aliases: ["DIAMETER"], description: "Enter diameter instead")]
            }
        default:
            opts = []
        }
        return opts.filter { $0.matches(input) }
    }

    // MARK: - Tangent picking

    struct PickedSupport {
        let support: FiniteTangentSupport
        let handle: UUID
    }

    private func pickTangentSupport(engine: PhrostEngine, worldPoint: Vector3) -> PickedSupport? {
        let doc = engine.document
        guard let handle = CADHitTesting.hitTest(worldX: worldPoint.x, worldY: worldPoint.y, document: doc, threshold: 12.0 / max(engine.camera.zoom, 0.001), simplifyComplexBlocks: false),
              let entity = doc.entity(for: handle), entity.blockID == nil, let geometry = entity.localGeometry else { return nil }
        var best: FiniteTangentSupport? = nil
        var bestDist = Double.infinity
        for prim in geometry {
            switch prim {
            case .polyline(let path, _):
                let worldPath = path.transformed(by: entity.transform)
                for idx in 0..<worldPath.segmentCount {
                    let start = worldPath.vertices[idx].position
                    let end = worldPath.vertices[worldPath.endVertexIndex(forSegment: idx)].position
                    let dir = end - start
                    let len = hypot(dir.x, dir.y)
                    if len < 1e-8 { continue }
                    let unit = Vector3(x: dir.x/len, y: dir.y/len, z: 0)
                    // arc segment?
                    if let arc = worldPath.arcParameters(forSegment: idx) {
                        let inf: TangentSupport2 = .circle(center: arc.center, radius: arc.radius)
                        let finite = FiniteTangentSupport(infinite: inf, shape: .arc(center: arc.center, radius: arc.radius, start: arc.startAngle, sweep: arc.sweep))
                        let nearest = nearestPointOnSegment(worldPoint, start, end) // dummy; for arc use nearest on arc approx as start
                        let d = nearest.distance(to: worldPoint)
                        if d < bestDist { bestDist = d; best = finite }
                        continue
                    }
                    let inf: TangentSupport2 = .line(origin: start, directionUnit: unit)
                    let finite = FiniteTangentSupport(infinite: inf, shape: .segment(start: start, end: end))
                    let nearest = nearestPointOnSegment(worldPoint, start, end)
                    let d = nearest.distance(to: worldPoint)
                    if d < bestDist { bestDist = d; best = finite }
                }
            case .line(let s, let e, _):
                let ws = entity.transform.transformPoint(s)
                let we = entity.transform.transformPoint(e)
                let dir = we - ws
                let len = hypot(dir.x, dir.y)
                guard len > 1e-8 else { continue }
                let unit = Vector3(x: dir.x/len, y: dir.y/len, z: 0)
                let inf: TangentSupport2 = .line(origin: ws, directionUnit: unit)
                let finite = FiniteTangentSupport(infinite: inf, shape: .segment(start: ws, end: we))
                let nearest = nearestPointOnSegment(worldPoint, ws, we)
                let d = nearest.distance(to: worldPoint)
                if d < bestDist { bestDist = d; best = finite }
            case .ray(let s, let d, _):
                let ws = entity.transform.transformPoint(s)
                let wd = entity.transform.transformPoint(s + d) - ws
                let len = hypot(wd.x, wd.y)
                guard len > 1e-8 else { continue }
                let unit = Vector3(x: wd.x/len, y: wd.y/len, z: 0)
                let inf: TangentSupport2 = .line(origin: ws, directionUnit: unit)
                let finite = FiniteTangentSupport(infinite: inf, shape: .ray(origin: ws, direction: unit))
                let proj = max(0, (worldPoint - ws).x*unit.x + (worldPoint - ws).y*unit.y)
                let nearest = ws + unit * proj
                let dd = nearest.distance(to: worldPoint)
                if dd < bestDist { bestDist = dd; best = finite }
            case .circle(let c, let r, _):
                let wc = entity.transform.transformPoint(c)
                let rr = hypot((entity.transform.transformPoint(Vector3(x: c.x+r, y: c.y, z: c.z)) - wc).x, (entity.transform.transformPoint(Vector3(x: c.x+r, y: c.y, z: c.z)) - wc).y)
                guard rr > 1e-8 else { continue }
                let inf: TangentSupport2 = .circle(center: wc, radius: rr)
                let finite = FiniteTangentSupport(infinite: inf, shape: .fullCircle)
                let nearest = CADGeometryMath.nearestPointOnCircle(to: worldPoint, center: wc, radius: rr) ?? wc
                let d = nearest.distance(to: worldPoint)
                if d < bestDist { bestDist = d; best = finite }
            case .arc(let c, let r, let sa, let ea, _):
                guard let wg = worldCircular(center: c, radius: r, start: sa, end: ea, transform: entity.transform) else { continue }
                let inf: TangentSupport2 = .circle(center: wg.center, radius: wg.radius)
                let finite = FiniteTangentSupport(infinite: inf, shape: .arc(center: wg.center, radius: wg.radius, start: wg.start, sweep: wg.sweep))
                let nearest = nearestPointOnArcWrapper(to: worldPoint, center: wg.center, radius: wg.radius, start: wg.start, sweep: wg.sweep) ?? wg.center
                let d = nearest.distance(to: worldPoint)
                if d < bestDist { bestDist = d; best = finite }
            default: continue
            }
        }
        guard let b = best else { return nil }
        return PickedSupport(support: b, handle: handle)
    }
    private func nearestPointOnSegment(_ p: Vector3, _ a: Vector3, _ b: Vector3) -> Vector3 {
        let dx = b.x - a.x; let dy = b.y - a.y
        let lenSq = dx*dx + dy*dy
        if lenSq < 1e-12 { return a }
        let t = max(0, min(1, ((p.x-a.x)*dx + (p.y-a.y)*dy)/lenSq))
        return Vector3(x: a.x + dx*t, y: a.y + dy*t, z: a.z)
    }
    private func nearestPointOnArcWrapper(to p: Vector3, center: Vector3, radius: Double, start: Double, sweep: Double) -> Vector3? {
        let dx = p.x - center.x; let dy = p.y - center.y
        if hypot(dx, dy) < 1e-12 { return nil }
        let angle = atan2(dy, dx)
        let twoPi = 2*Double.pi
        func norm(_ v: Double) -> Double { var r = v.truncatingRemainder(dividingBy: twoPi); if r < 0 { r+=twoPi }; return r }
        let a = sweep >= 0 ? norm(angle - start) : norm(start - angle)
        let e = norm(abs(sweep))
        if a >= 0 && a <= e {
            return Vector3(x: center.x + cos(angle)*radius, y: center.y + sin(angle)*radius, z: center.z)
        }
        // else nearest endpoint
        let sPt = Vector3(x: center.x + cos(start)*radius, y: center.y + sin(start)*radius, z: center.z)
        let ePt = Vector3(x: center.x + cos(start+sweep)*radius, y: center.y + sin(start+sweep)*radius, z: center.z)
        return sPt.distance(to: p) <= ePt.distance(to: p) ? sPt : ePt
    }
    private func worldCircular(center: Vector3, radius: Double, start: Double, end: Double, transform: Transform3D) -> (center: Vector3, radius: Double, start: Double, sweep: Double)? {
        let wc = transform.transformPoint(center)
        let ax = transform.transformPoint(Vector3(x: center.x+radius, y: center.y, z: center.z)) - wc
        let ay = transform.transformPoint(Vector3(x: center.x, y: center.y+radius, z: center.z)) - wc
        let rx = hypot(ax.x, ax.y); let ry = hypot(ay.x, ay.y)
        guard rx > 1e-8, ry > 1e-8, abs(rx-ry) <= max(rx,ry)*1e-6 else { return nil }
        let twoPi = 2*Double.pi
        let isFull = abs(end-start) >= twoPi - 1e-8
        var span = end - start
        if !isFull && span < 0 { span += twoPi }
        if isFull { span = twoPi }
        let localStart = Vector3(x: center.x + cos(start)*radius, y: center.y + sin(start)*radius, z: center.z)
        let worldStartPt = transform.transformPoint(localStart)
        let wStart = atan2(worldStartPt.y - wc.y, worldStartPt.x - wc.x)
        let cross = ax.x*ay.y - ax.y*ay.x
        let orient = cross >= 0 ? 1.0 : -1.0
        return (wc, (rx+ry)*0.5, wStart, span*orient)
    }

    private func commitCircle(center: Vector3, radius: Double,
                               engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        guard radius > 1e-9 else {
            processor.commandPrompt = "Radius must be positive."
            return .handled
        }
        let prim: CADPrimitive = .circle(center: center, radius: radius)
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [prim])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        CircleSettings.lastRadius = radius
        processor.commandPrompt = "Circle created (r=\(String(format: "%.4f", radius)))."
        return .finished
    }

    // MARK: - Overlay

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let col = makeCol32(0, 255, 128, 200)

        func drawCircle(center: Vector3, radius: Double, color: UInt32) {
            if radius < 1e-6 { return }
            let segments = 64
            var pts: [ImVec2] = []
            pts.reserveCapacity(segments+1)
            for i in 0...segments {
                let angle = Double(i) * 2.0 * .pi / Double(segments)
                let wx = center.x + cos(angle) * radius
                let wy = center.y + sin(angle) * radius
                let sp = EngineCameraManager.worldToScreen(worldX: wx, worldY: wy, cam: cam)
                pts.append(ImVec2(x: sp.x, y: sp.y))
            }
            pts.withUnsafeBufferPointer { buf in
                ImDrawListAddPolyline(drawList, buf.baseAddress, Int32(pts.count), color, 1.5, ImDrawFlags(0))
            }
        }

        switch state {
        case .awaitingRadius(let c, let isDiameter):
            let radius = hypot(currentMouseWorldX - c.x, currentMouseWorldY - c.y)
            drawCircle(center: c, radius: radius, color: col)
            let cp = EngineCameraManager.worldToScreen(worldX: c.x, worldY: c.y, cam: cam)
            let crossCol = makeCol32(255, 255, 255, 150)
            ImDrawListAddLine(drawList, ImVec2(x: cp.x - 6, y: cp.y), ImVec2(x: cp.x + 6, y: cp.y), crossCol, 1.0)
            ImDrawListAddLine(drawList, ImVec2(x: cp.x, y: cp.y - 6), ImVec2(x: cp.x, y: cp.y + 6), crossCol, 1.0)
            let mp = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: cp.x, y: cp.y), ImVec2(x: mp.x, y: mp.y), makeCol32(0,255,128,100), 1.0)
            let midX = (c.x + currentMouseWorldX)/2
            let midY = (c.y + currentMouseWorldY)/2
            let midScreen = EngineCameraManager.worldToScreen(worldX: midX, worldY: midY, cam: cam)
            let label = isDiameter ? String(format: "D %.2f", radius*2) : String(format: "R %.2f", radius)
            ImDrawListAddText(drawList, ImVec2(x: midScreen.x, y: midScreen.y), makeCol32(255,255,255,200), label, nil)
            input.renderOverlay(cam: cam, worldX: currentMouseWorldX, worldY: currentMouseWorldY)
        case .awaiting2PSecond(let first):
            let second = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            let solved = CircleMath.circleFromTwoPoints(first, second)
            drawCircle(center: solved.center, radius: solved.radius, color: col)
            let a = EngineCameraManager.worldToScreen(worldX: first.x, worldY: first.y, cam: cam)
            let b = EngineCameraManager.worldToScreen(worldX: second.x, worldY: second.y, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), makeCol32(0,255,128,100), 1.0)
        case .awaiting3PSecond(let f):
            let s1 = EngineCameraManager.worldToScreen(worldX: f.x, worldY: f.y, cam: cam)
            let s2 = EngineCameraManager.worldToScreen(worldX: currentMouseWorldX, worldY: currentMouseWorldY, cam: cam)
            ImDrawListAddLine(drawList, ImVec2(x: s1.x, y: s1.y), ImVec2(x: s2.x, y: s2.y), makeCol32(0,255,128,100), 1.0)
        case .awaiting3PThird(let a, let b):
            let c = Vector3(x: currentMouseWorldX, y: currentMouseWorldY, z: 0)
            if let solved = CADGeometryMath.circleThroughThreePoints(a, b, c) {
                drawCircle(center: solved.center, radius: solved.radius, color: col)
            } else {
                // line preview when collinear
                let sa = EngineCameraManager.worldToScreen(worldX: a.x, worldY: a.y, cam: cam)
                let sb = EngineCameraManager.worldToScreen(worldX: b.x, worldY: b.y, cam: cam)
                ImDrawListAddLine(drawList, ImVec2(x: sa.x, y: sa.y), ImVec2(x: sb.x, y: sb.y), makeCol32(0,255,128,100), 1.0)
            }
        case .awaitingTTRFirst, .awaitingTTRSecond, .awaitingTTRRadius, .awaitingTTTFirst, .awaitingTTTSecond, .awaitingTTTThird, .initial, .awaiting2PFirst, .awaiting3PFirst:
            break
        }
    }
}
