import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - InquiryMath (DIST / AREA / ID / LIST shared math)
// =========================================================================

/// Pure, headless-testable math behind the inquiry commands. All area and
/// length figures follow the scripted property semantics (`AREA`/`LENGTH`
/// in LispCADHostProps) so `(getpropertyvalue)` and `LIST` agree; polygon
/// areas use the shared shoelace implementation.
public enum InquiryMath {

    /// Decimal length with live LUPREC precision (negative zero normalized
    /// after rounding, so -0.00001 at precision 4 prints "0.0000").
    public static func formatLength(_ v: Double, precision: Int) -> String {
        let p = max(0, min(8, precision))
        let factor = pow(10, Double(p))
        let rounded = (v * factor).rounded() / factor
        let clean = (rounded == 0) ? 0.0 : rounded
        return String(format: "%.\(p)f", clean)
    }

    /// Degrees in [0, 360) with live AUPREC precision.
    public static func formatAngleDeg(_ radians: Double, precision: Int) -> String {
        let p = max(0, min(8, precision))
        var deg = radians * 180 / Double.pi
        deg.formTruncatingRemainder(dividingBy: 360)
        if deg < 0 { deg += 360 }
        if deg == 0 { deg = 0 } // normalize negative zero
        return String(format: "%.\(p)f", deg)
    }

    public static func formatPoint(_ p: Vector3, precision: Int) -> String {
        "X = \(formatLength(p.x, precision: precision))  "
            + "Y = \(formatLength(p.y, precision: precision))  "
            + "Z = \(formatLength(p.z, precision: precision))"
    }

    public static func polygonPerimeter(_ pts: [Vector3], closed: Bool) -> Double {
        guard pts.count >= 2 else { return 0 }
        var sum = 0.0
        for i in 0..<(pts.count - 1) {
            sum += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y)
        }
        if closed, pts.count >= 3 {
            sum += hypot(pts[0].x - pts.last!.x, pts[0].y - pts.last!.y)
        }
        return sum
    }

    /// Closed-polyline area (chords; bulge arcs are linearized, matching the
    /// scripted AREA property). Returns nil for open polylines.
    public static func polylineArea(_ path: CADPolyline, transform t: Transform3D) -> Double? {
        guard path.isClosed else { return nil }
        let pts = path.vertices.map { t.transformPoint($0.position) }
        return CADBoundaryDetector.shoelaceArea(polygon: pts)
    }

    public static func polylineLength(_ path: CADPolyline, transform t: Transform3D) -> Double {
        let pts = path.vertices.map { t.transformPoint($0.position) }
        return polygonPerimeter(pts, closed: path.isClosed)
    }

    /// Area of one entity, or nil when the type has no area (lines, text,
    /// points, images, tables, splines, rays).
    public static func entityArea(_ entity: CADEntity) -> Double? {
        guard let prim = entity.localGeometry?.first else { return nil }
        let t = entity.transform
        let sx = t.scale.x, sy = t.scale.y
        switch prim {
        case let .circle(_, radius, _):
            return Double.pi * radius * radius * sx * sy
        case let .arc(_, radius, startAngle, endAngle, _):
            return 0.5 * radius * radius * abs(endAngle - startAngle) * sx * sy
        case let .ellipse(_, majorAxis, minorRatio, _):
            let a = hypot(majorAxis.x, majorAxis.y) * sx
            return Double.pi * a * a * minorRatio * sy
        case let .polyline(path, _):
            return polylineArea(path, transform: t)
        case let .polygon(points, _),
            let .fillPolygon(points, _),
            let .hatch(points, _, _, _, _, _):
            return CADBoundaryDetector.shoelaceArea(
                polygon: points.map { t.transformPoint($0) })
        case let .fillComplexPolygon(outer, holes, _),
            let .gradient(outer, holes, _, _, _, _):
            let gross = CADBoundaryDetector.shoelaceArea(
                polygon: outer.map { t.transformPoint($0) })
            let cut = holes.reduce(0.0) { acc, h in
                acc + CADBoundaryDetector.shoelaceArea(
                    polygon: h.map { t.transformPoint($0) })
            }
            return max(0, gross - cut)
        case let .rect(_, size, _), let .fillRect(_, size, _):
            return abs(size.x * sx * size.y * sy)
        case let .hatchPath(boundary, holes, _, _, _, _, _):
            let gross = polylineArea(boundary, transform: t) ?? 0
            let cut = holes.reduce(0.0) {
                acc, h in acc + (polylineArea(h, transform: t) ?? 0)
            }
            return max(0, gross - cut)
        default:
            return nil
        }
    }

    /// Length of one entity, or nil when the type has no length.
    public static func entityLength(_ entity: CADEntity) -> Double? {
        guard let prim = entity.localGeometry?.first else { return nil }
        let t = entity.transform
        switch prim {
        case let .line(start, end, _):
            let a = t.transformPoint(start), b = t.transformPoint(end)
            return hypot(b.x - a.x, b.y - a.y)
        case let .polyline(path, _):
            return polylineLength(path, transform: t)
        case let .arc(_, radius, startAngle, endAngle, _):
            return abs(endAngle - startAngle) * radius * t.scale.x
        case let .circle(_, radius, _):
            return 2 * Double.pi * radius * t.scale.x
        case let .polygon(points, _):
            return polygonPerimeter(points.map { t.transformPoint($0) }, closed: true)
        default:
            return nil
        }
    }

    /// DXF-flavored type name for LIST output.
    public static func typeName(of entity: CADEntity) -> String {
        if entity.blockID != nil { return "INSERT" }
        guard let prim = entity.localGeometry?.first else { return "ENTITY" }
        switch prim {
        case .point: return "POINT"
        case .line: return "LINE"
        case .rect, .polygon, .polyline, .penStroke: return "LWPOLYLINE"
        case .fillRect, .fillPolygon, .fillComplexPolygon,
            .hatch, .hatchPath, .gradient:
            return "HATCH"
        case .circle: return "CIRCLE"
        case .arc: return "ARC"
        case .spline: return "SPLINE"
        case .text: return "TEXT"
        case .ellipse: return "ELLIPSE"
        case .ray: return "RAY"
        case .xline: return "XLINE"
        case .image: return "IMAGE"
        case .table: return "TABLE"
        }
    }

    public static func shortHandle(_ h: UUID) -> String {
        String(h.uuidString.prefix(8))
    }
}

// =========================================================================
// MARK: - DistanceCommand (DIST)
// =========================================================================

/// AutoCAD `DIST`: two snapped picks, then the LT report block (distance,
/// XY angle, from-XY angle, deltas). Sets LASTPOINT to the second pick.
/// Creates nothing, pushes no undo.
@MainActor
public final class DistanceCommand: FeatureCommand {

    private var pointA: Vector3?

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        pointA = nil
        processor.commandPrompt = "Specify first point:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let p = Vector3(x: worldX, y: worldY, z: 0)
        if pointA == nil {
            pointA = p
            processor.commandPrompt = "Specify second point:"
            return .handled
        }
        report(from: pointA!, to: p, engine: engine, processor: processor)
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func getDrawingSnapPoints() -> [Vector3] {
        if let a = pointA { return [a] }
        return []
    }

    private func report(
        from a: Vector3, to b: Vector3,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let doc = engine.document
        let luprec = doc.lengthPrecision, auprec = doc.anglePrecision
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
        let xyAngle = InquiryMath.formatAngleDeg(atan2(dy, dx), precision: auprec)
        let flat = hypot(dx, dy)
        let zAngle = InquiryMath.formatAngleDeg(atan2(dz, flat), precision: auprec)
        print(
            "[CAD] Distance = \(InquiryMath.formatLength(dist, precision: luprec)),"
                + "  Angle in XY Plane = \(xyAngle),"
                + "  Angle from XY Plane = \(zAngle)")
        print(
            "[CAD] Delta X = \(InquiryMath.formatLength(dx, precision: luprec)),"
                + "  Delta Y = \(InquiryMath.formatLength(dy, precision: luprec)),"
                + "  Delta Z = \(InquiryMath.formatLength(dz, precision: luprec))")
        doc.lastPoint = b
        processor.commandPrompt = "Distance = \(InquiryMath.formatLength(dist, precision: luprec))."
    }
}

// =========================================================================
// MARK: - IdCommand (ID)
// =========================================================================

/// AutoCAD `ID`: one snapped pick reporting X/Y/Z. Sets LASTPOINT.
/// Creates nothing, pushes no undo.
@MainActor
public final class IdCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Specify point:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let p = Vector3(x: worldX, y: worldY, z: 0)
        engine.document.lastPoint = p
        let line = InquiryMath.formatPoint(p, precision: engine.document.lengthPrecision)
        print("[CAD] \(line)")
        processor.commandPrompt = line
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}


// =========================================================================
// MARK: - AreaTally (AREA Add/Subtract accumulation)
// =========================================================================

/// Running area/perimeter total for AREA's Add/Subtract modes. Pure value
/// type so the accumulation math is headless-testable; the command owns one.
public struct AreaTally: Sendable {
    public private(set) var area: Double = 0
    public private(set) var perimeter: Double = 0
    public private(set) var picks: Int = 0

    public init() {}

    public mutating func add(area: Double, perimeter: Double) {
        self.area += area
        self.perimeter += perimeter
        picks += 1
    }

    public mutating func subtract(area: Double, perimeter: Double) {
        self.area -= area
        self.perimeter -= perimeter
        picks += 1
    }

    public mutating func reset() {
        area = 0
        perimeter = 0
        picks = 0
    }
}

// =========================================================================
// MARK: - AreaCommand (AREA)
// =========================================================================

/// AutoCAD `AREA`: pick-point polygons, Object measurement, and
/// Add/Subtract tallies. Every report writes the AREA/PERIMETER sysvars
/// (live document fields). Creates nothing, pushes no undo.
///
/// Pick mode: clicks add vertices (Enter reports, Esc cancels silently).
/// Object mode: click an entity for its area/perimeter; unmeasurable types
/// report honestly instead of zero. Add/Subtract accumulate a running total
/// printed on every pick; eXit finishes with the grand total when tallying.
@MainActor
public final class AreaCommand: FeatureCommand {

    private enum Mode {
        case pick
        case object
    }

    private var mode: Mode = .pick
    private var points: [Vector3] = []
    private var tally = AreaTally()
    private var tallySign: Double = 0 // 0 = off, +1 = add, -1 = subtract

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        mode = .pick
        points = []
        tally.reset()
        tallySign = 0
        processor.commandPrompt = "Specify first corner point or [Object/Add/Subtract/eXit]:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        [
            .init(value: "O", title: "Object", aliases: ["OBJECT"]),
            .init(value: "A", title: "Add", aliases: ["ADD"]),
            .init(value: "S", title: "Subtract", aliases: ["SUBTRACT"]),
            .init(value: "X", title: "eXit", aliases: ["EXIT"]),
        ]
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "O", "OBJECT":
            mode = .object
            processor.commandPrompt = "Select object for area (Esc to finish):"
            return .handled
        case "A", "ADD":
            tallySign = 1
            mode = .object
            processor.commandPrompt = "Select object to ADD (Esc for total):"
            return .handled
        case "S", "SUBTRACT":
            tallySign = -1
            mode = .object
            processor.commandPrompt = "Select object to SUBTRACT (Esc for total):"
            return .handled
        case "X", "EXIT":
            finishTally(engine: engine, processor: processor)
            return .finished
        default:
            return .continue
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let p = Vector3(x: worldX, y: worldY, z: 0)
        switch mode {
        case .pick:
            points.append(p)
            processor.commandPrompt =
                "Specify next point (\(points.count) picked) or [Object/Add/Subtract/eXit]:"
            return .handled
        case .object:
            measureObject(at: p, engine: engine, processor: processor)
            return .handled
        }
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            reportPicks(engine: engine, processor: processor)
            return .finished
        default:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func getDrawingSnapPoints() -> [Vector3] {
        points
    }

    // MARK: - Reporting

    private func reportPicks(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        let doc = engine.document
        guard points.count >= 3 else {
            processor.commandPrompt = "AREA needs at least 3 points."
            return
        }
        let area = CADBoundaryDetector.shoelaceArea(polygon: points)
        let perimeter = InquiryMath.polygonPerimeter(points, closed: true)
        doc.lastArea = area
        doc.lastPerimeter = perimeter
        let line = "Area = \(InquiryMath.formatLength(area, precision: doc.lengthPrecision)),"
            + "  Perimeter = \(InquiryMath.formatLength(perimeter, precision: doc.lengthPrecision))"
        print("[CAD] \(line)")
        processor.commandPrompt = line + "."
    }

    private func measureObject(
        at p: Vector3,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        let doc = engine.document
        guard let handle = CADHitTesting.hitTest(
            worldX: p.x, worldY: p.y,
            document: doc,
            threshold: 12.0 / engine.camera.zoom,
            simplifyComplexBlocks: false
        ), let entity = doc.entity(for: handle), entity.blockID == nil else {
            processor.commandPrompt = "No measurable object there. Select object (Esc to finish):"
            return
        }
        guard let area = InquiryMath.entityArea(entity) else {
            let kind = InquiryMath.typeName(of: entity)
            processor.commandPrompt = "\(kind) has no measurable area. Select object (Esc to finish):"
            return
        }
        let perimeter = InquiryMath.entityLength(entity) ?? 0
        doc.lastArea = area
        doc.lastPerimeter = perimeter
        let luprec = doc.lengthPrecision
        if tallySign == 0 {
            let line = "Area = \(InquiryMath.formatLength(area, precision: luprec)),"
                + "  Perimeter = \(InquiryMath.formatLength(perimeter, precision: luprec))"
            print("[CAD] \(line)")
            processor.commandPrompt = line + "."
        } else if tallySign > 0 {
            tally.add(area: area, perimeter: perimeter)
            print(
                "[CAD] Added: Area = \(InquiryMath.formatLength(area, precision: luprec))  "
                    + "Running total = \(InquiryMath.formatLength(tally.area, precision: luprec))")
            processor.commandPrompt = "Select object to ADD (Esc for total):"
        } else {
            tally.subtract(area: area, perimeter: perimeter)
            print(
                "[CAD] Subtracted: Area = \(InquiryMath.formatLength(area, precision: luprec))  "
                    + "Running total = \(InquiryMath.formatLength(tally.area, precision: luprec))")
            processor.commandPrompt = "Select object to SUBTRACT (Esc for total):"
        }
    }

    private func finishTally(
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        guard tally.picks > 0 else { return }
        let luprec = engine.document.lengthPrecision
        let line = "Total area = \(InquiryMath.formatLength(tally.area, precision: luprec)),"
            + "  Total perimeter = \(InquiryMath.formatLength(tally.perimeter, precision: luprec))"
        print("[CAD] \(line)")
        processor.commandPrompt = line + "."
    }
}

// =========================================================================
// MARK: - ListCommand (LIST)
// =========================================================================

/// AutoCAD `LIST`: prints type, layer, handle, key geometry, and applicable
/// length/area for every selected entity. Requires a pre-selection (noun);
/// with nothing selected it says so instead of starting a picker.
/// Creates nothing, pushes no undo.
@MainActor
public final class ListCommand: FeatureCommand {

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let handles = engine.cadSelection.selectedHandles
        guard !handles.isEmpty else {
            processor.commandPrompt = "No entities selected. Select entities first, then run LIST."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        let doc = engine.document
        let luprec = doc.lengthPrecision, auprec = doc.anglePrecision
        var order = 0
        for handle in handles.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entity = doc.entity(for: handle) else { continue }
            order += 1
            print("[CAD] --- (\(order)) \(InquiryMath.typeName(of: entity)) ---")
            for line in Self.describe(entity, document: doc, luprec: luprec, auprec: auprec) {
                print("[CAD] \(line)")
            }
        }
        processor.commandPrompt = "\(order) entit\(order == 1 ? "y" : "ies") listed."
        processor.finishFeatureCommand(engine: engine)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    // MARK: - Description

    private static func pointLine(_ label: String, _ p: Vector3, luprec: Int) -> String {
        "\(label): \(InquiryMath.formatPoint(p, precision: luprec))"
    }

    /// One entity's LIST body lines. Pure over entity + document lookups so
    /// the formatting contract is unit-testable without a live engine.
    public static func describe(
        _ entity: CADEntity,
        document: CADDocument,
        luprec: Int,
        auprec: Int
    ) -> [String] {
        let layerName = document.layer(for: entity.layerID)?.name ?? "0"
        var lines = [
            "\(InquiryMath.typeName(of: entity))  Layer: \"\(layerName)\""
                + "  Handle = \(InquiryMath.shortHandle(entity.handle))",
        ]
        func lengthLine(_ v: Double) -> String {
            "Length = \(InquiryMath.formatLength(v, precision: luprec))"
        }
        func areaLine(_ v: Double) -> String {
            "Area = \(InquiryMath.formatLength(v, precision: luprec))"
        }
        if let blockID = entity.blockID,
           let block = document.block(for: blockID) {
            lines.append("Block: \"\(block.name)\"")
            appendOverrides(entity, to: &lines)
            return lines
        }
        guard let prim = entity.localGeometry?.first else { return lines }
        let t = entity.transform
        switch prim {
        case let .line(start, end, _):
            let a = t.transformPoint(start), b = t.transformPoint(end)
            lines.append(pointLine("from point", a, luprec: luprec))
            lines.append(pointLine("to point", b, luprec: luprec))
            if let len = InquiryMath.entityLength(entity) {
                lines.append(lengthLine(len))
                lines.append(
                    "Angle in XY Plane = \(InquiryMath.formatAngleDeg(atan2(b.y - a.y, b.x - a.x), precision: auprec))")
            }
        case let .circle(center, radius, _):
            let c = t.transformPoint(center)
            lines.append(pointLine("center point", c, luprec: luprec))
            lines.append("radius \(InquiryMath.formatLength(radius * t.scale.x, precision: luprec))")
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
            if let len = InquiryMath.entityLength(entity) {
                lines.append(
                    "Circumference = \(InquiryMath.formatLength(len, precision: luprec))")
            }
        case let .arc(center, radius, startAngle, endAngle, _):
            lines.append(pointLine("center point", t.transformPoint(center), luprec: luprec))
            lines.append("radius \(InquiryMath.formatLength(radius * t.scale.x, precision: luprec))")
            lines.append(
                "start angle \(InquiryMath.formatAngleDeg(startAngle + t.rotation, precision: auprec))")
            lines.append(
                "end angle \(InquiryMath.formatAngleDeg(endAngle + t.rotation, precision: auprec))")
            if let len = InquiryMath.entityLength(entity) { lines.append(lengthLine(len)) }
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case let .polyline(path, _):
            lines.append(
                "\(path.vertices.count) vertices  \(path.isClosed ? "closed" : "open")")
            if let len = InquiryMath.entityLength(entity) { lines.append(lengthLine(len)) }
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case let .polygon(points, _):
            lines.append("\(points.count) vertices  closed")
            if let len = InquiryMath.entityLength(entity) { lines.append(lengthLine(len)) }
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case let .text(position, text, height, rotation, style, _, _, _, _):
            lines.append(pointLine("insertion point", t.transformPoint(position), luprec: luprec))
            lines.append("height \(InquiryMath.formatLength(height * t.scale.x, precision: luprec))")
            lines.append("rotation \(InquiryMath.formatAngleDeg(rotation + t.rotation, precision: auprec))")
            lines.append("style \"\(style ?? "Standard")\"")
            lines.append("text: \(text)")
        case let .point(position, _):
            lines.append(pointLine("position", t.transformPoint(position), luprec: luprec))
        case let .ellipse(center, majorAxis, minorRatio, _):
            lines.append(pointLine("center point", t.transformPoint(center), luprec: luprec))
            let a = hypot(majorAxis.x, majorAxis.y) * t.scale.x
            lines.append("major axis \(InquiryMath.formatLength(a, precision: luprec))")
            lines.append(
                "minor axis \(InquiryMath.formatLength(a * minorRatio, precision: luprec))")
            lines.append("radius ratio \(InquiryMath.formatLength(minorRatio, precision: luprec))")
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case let .ray(start, direction, _):
            lines.append(pointLine("base point", t.transformPoint(start), luprec: luprec))
            lines.append(
                "direction \(InquiryMath.formatAngleDeg(atan2(direction.y, direction.x) + t.rotation, precision: auprec))°")
        case let .xline(point, direction, _):
            lines.append(pointLine("through point", t.transformPoint(point), luprec: luprec))
            lines.append(
                "direction \(InquiryMath.formatAngleDeg(atan2(direction.y, direction.x) + t.rotation, precision: auprec))°")
        case let .spline(controlPoints, _, degree, _, _):
            lines.append("degree \(degree)  \(controlPoints.count) control points")
        case let .hatch(boundary, pattern, scale, angle, _, _):
            lines.append("pattern \"\(pattern)\"  scale \(scale)  angle \(angle)")
            lines.append("\(boundary.count) boundary points")
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case let .hatchPath(boundary, holes, pattern, scale, angle, _, _):
            lines.append("pattern \"\(pattern)\"  scale \(scale)  angle \(angle)")
            lines.append(
                "\(boundary.vertices.count) boundary vertices  \(holes.count) holes")
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case .fillRect, .fillPolygon, .fillComplexPolygon, .gradient:
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case let .image(insertion, uAxis, vAxis, imageName, _, _):
            lines.append(pointLine("insertion point", t.transformPoint(insertion), luprec: luprec))
            lines.append(
                "size \(InquiryMath.formatLength(hypot(uAxis.x, uAxis.y), precision: luprec)) x"
                    + " \(InquiryMath.formatLength(hypot(vAxis.x, vAxis.y), precision: luprec))")
            lines.append("image: \(imageName)")
        case let .table(data, origin, _):
            lines.append(pointLine("origin", t.transformPoint(origin), luprec: luprec))
            lines.append("\(data.rows.count) rows x \(data.columns.count) columns")
        case let .rect(origin, size, _):
            lines.append(pointLine("origin", t.transformPoint(origin), luprec: luprec))
            lines.append(
                "size \(InquiryMath.formatLength(size.x * t.scale.x, precision: luprec)) x"
                    + " \(InquiryMath.formatLength(size.y * t.scale.y, precision: luprec))")
            if let area = InquiryMath.entityArea(entity) { lines.append(areaLine(area)) }
        case let .penStroke(vertices, baseLineWeight, _):
            lines.append("\(vertices.count) vertices  weight \(baseLineWeight)")
        }
        appendOverrides(entity, to: &lines)
        return lines
    }

    private static func appendOverrides(_ entity: CADEntity, to lines: inout [String]) {
        if let c = entity.xdata["dxf.colorIndex"], case .int(let aci) = c {
            lines.append("color ACI \(aci)")
        } else if entity.xdata["dxf.color24"] != nil {
            lines.append("color TrueColor")
        }
        if let lt = entity.xdata["dxf.lineType"], case .string(let name) = lt {
            lines.append("linetype \"\(name)\"")
        }
        if let lw = entity.xdata["dxf.lineWeight"], case .double(let w) = lw {
            lines.append("lineweight \(w) mm")
        }
    }
}
