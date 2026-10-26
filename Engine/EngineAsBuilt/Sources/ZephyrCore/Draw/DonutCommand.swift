import Foundation
import CSDL3
import SwiftSDL

// =========================================================================
// MARK: - DonutMath
// =========================================================================

/// Donut ring construction (headless-testable): a closed 2-vertex
/// polyline of two semicircular bulge arcs at the mid radius, carrying
/// the ring width. Bulge 1.0 = semicircle (tan(π/4)).
public enum DonutMath {

    /// - Parameters:
    ///   - center: ring center (world).
    ///   - innerRadius: hole radius (0 = filled disc).
    ///   - outerRadius: outer radius.
    ///   - fill: FILLMODE — zero widths when false (outline only).
    public static func ring(
        center: Vector3, innerRadius: Double, outerRadius: Double, fill: Bool
    ) -> CADPolyline {
        let mid = (innerRadius + outerRadius) * 0.5
        let width = fill ? (outerRadius - innerRadius) : 0
        let a = CADPolylineVertex(
            position: Vector3(x: center.x + mid, y: center.y, z: center.z),
            bulge: 1.0, startWidth: width, endWidth: width)
        let b = CADPolylineVertex(
            position: Vector3(x: center.x - mid, y: center.y, z: center.z),
            bulge: 1.0, startWidth: width, endWidth: width)
        return CADPolyline(vertices: [a, b], isClosed: true)
    }
}

// =========================================================================
// MARK: - DonutCommand (DONUT / DO)
// =========================================================================

/// Draw a filled ring: inside diameter → outside diameter → center(s).
/// Emits the plan's wide 2-arc closed polyline; FILLMODE off yields a
/// zero-width outline. Repeats until Esc.
@MainActor
public final class DonutCommand: FeatureCommand {

    private enum State {
        case insideDiameter
        case outsideDiameter(inner: Double)
        case center(inner: Double, outer: Double)
    }

    private var state: State = .insideDiameter

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        state = .insideDiameter
        processor.commandPrompt = "Specify inside diameter of donut <0>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .finished }
        guard let d = Double(trimmed), d.isFinite, d >= 0 else {
            switch state {
            case .insideDiameter:
                processor.commandPrompt = "Specify inside diameter of donut <0>:"
            case .outsideDiameter:
                processor.commandPrompt = "Specify outside diameter of donut:"
            case .center:
                return .continue
            }
            return .handled
        }
        switch state {
        case .insideDiameter:
            state = .outsideDiameter(inner: d / 2.0)
            processor.commandPrompt = "Specify outside diameter of donut:"
            return .handled
        case .outsideDiameter(let inner):
            guard d / 2.0 > inner, d > 1e-9 else {
                processor.commandPrompt =
                    "Outside diameter must exceed inside diameter:"
                return .handled
            }
            state = .center(inner: inner, outer: d / 2.0)
            processor.commandPrompt = "Specify center of donut (Esc to finish):"
            return .handled
        case .center:
            return .continue
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard case .center(let inner, let outer) = state else {
            return .handled
        }
        let ring = DonutMath.ring(
            center: Vector3(x: worldX, y: worldY, z: 0),
            innerRadius: inner, outerRadius: outer,
            fill: engine.document.fillMode)
        let entity = CADEntity(
            layerID: engine.document.activeLayerID ?? UUID(),
            localGeometry: [.polyline(path: ring)])
        engine.document.addEntity(entity)
        engine.tabManager.markActiveDirty()
        processor.commandPrompt = "Specify center of donut (Esc to finish):"
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        if scancode == SDL_SCANCODE_ESCAPE { return .finished }
        return .continue
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}
