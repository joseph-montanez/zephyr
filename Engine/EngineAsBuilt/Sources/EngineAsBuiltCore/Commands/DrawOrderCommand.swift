import Foundation
import SwiftSDL

// =========================================================================
// MARK: - Draw Order Commands
//
// Six AutoCAD-style draw-order manipulation commands:
//   BRINGTOFRONT / BTF        — selected entities to absolute top
//   SENDTOBACK / STB          — selected entities to absolute bottom
//   BRINGABOVEOBJECTS / BAO   — selected entities above a reference
//   SENDUNDEROBJECTS / SUO    — selected entities under a reference
//   TEXTTOFRONT / TTF         — all text entities to top
//   HATCHTOBACK / HTB         — all hatch/fill entities to bottom
//
// Draw order is stored as `CADEntity.drawOrder` (first-class property, not
// xdata). Lower = drawn first (back), higher = drawn later (front).
// `Int.max` means "no explicit order" and sorts last.

// =========================================================================
// MARK: - Draw Order Helpers
// =========================================================================

/// Collect the min and max draw orders across all entities in the document,
/// excluding `Int.max` (which means "no explicit order").
private func collectDrawOrderRange(from document: CADDocument) -> (min: Int?, max: Int?) {
    var minOrder: Int?
    var maxOrder: Int?
    for entity in document.entitiesView {
        let o = entity.drawOrder
        guard o != Int.max else { continue }
        if minOrder == nil || o < minOrder! { minOrder = o }
        if maxOrder == nil || o > maxOrder! { maxOrder = o }
    }
    return (minOrder, maxOrder)
}

/// True if the entity is a text entity (has `dxf.text` in xdata).
private func isTextEntity(_ entity: CADEntity) -> Bool {
    if case .string(let s) = entity.xdata["dxf.text"], !s.isEmpty {
        return true
    }
    return false
}

/// True if the entity contains hatch/fill/gradient primitives.
private func isHatchEntity(_ entity: CADEntity, document: CADDocument) -> Bool {
    guard let geometry = document.resolvedGeometry(for: entity) else { return false }
    for prim in geometry {
        switch prim {
        case .hatch, .fillPolygon, .fillComplexPolygon, .gradient:
            return true
        default:
            break
        }
    }
    return false
}

// =========================================================================
// MARK: - BringToFrontCommand
// =========================================================================

@MainActor
final class BringToFrontCommand: FeatureCommand {
    func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        defer { processor.finishFeatureCommand(engine: engine) }

        let handles = engine.cadSelection.selectedHandles
        guard !handles.isEmpty else {
            processor.commandPrompt = "No entities selected."
            return
        }

        let doc = engine.document
        let range = collectDrawOrderRange(from: doc)
        // Place above existing max, or start at 0 if no entities have explicit orders.
        let newBase = (range.max ?? -1) + 1

        for (i, handle) in handles.enumerated() {
            doc.setDrawOrder(for: handle, to: newBase + i)
        }
        processor.commandPrompt = "\(handles.count) entity(s) brought to front."
    }

    func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    var isSnappingEnabled: Bool { false }
}

// =========================================================================
// MARK: - SendToBackCommand
// =========================================================================

@MainActor
final class SendToBackCommand: FeatureCommand {
    func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        defer { processor.finishFeatureCommand(engine: engine) }

        let handles = engine.cadSelection.selectedHandles
        guard !handles.isEmpty else {
            processor.commandPrompt = "No entities selected."
            return
        }

        let doc = engine.document
        let range = collectDrawOrderRange(from: doc)
        // Place below existing min, or start at -1 if no entities have explicit orders.
        let newBase = (range.min ?? 1) - 1

        // Assign in reverse so the first selected gets the lowest (newBase - count + 1).
        let sorted = handles.sorted { $0.uuidString < $1.uuidString }
        for (i, handle) in sorted.enumerated() {
            doc.setDrawOrder(for: handle, to: newBase - (handles.count - 1) + i)
        }
        processor.commandPrompt = "\(handles.count) entity(s) sent to back."
    }

    func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    var isSnappingEnabled: Bool { false }
}

// =========================================================================
// MARK: - TextToFrontCommand
// =========================================================================

@MainActor
final class TextToFrontCommand: FeatureCommand {
    func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        defer { processor.finishFeatureCommand(engine: engine) }

        let doc = engine.document
        let textEntities = doc.entitiesView.filter { isTextEntity($0) }
        guard !textEntities.isEmpty else {
            processor.commandPrompt = "No text entities found."
            return
        }

        let range = collectDrawOrderRange(from: doc)
        let newBase = (range.max ?? -1) + 1

        // Sort by current draw order (stable) then assign new sequential orders.
        let sorted = textEntities.sorted { $0.drawOrder < $1.drawOrder }
        for (i, entity) in sorted.enumerated() {
            doc.setDrawOrder(for: entity.handle, to: newBase + i)
        }
        processor.commandPrompt = "\(textEntities.count) text entity(s) brought to front."
    }

    func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    var isSnappingEnabled: Bool { false }
}

// =========================================================================
// MARK: - HatchToBackCommand
// =========================================================================

@MainActor
final class HatchToBackCommand: FeatureCommand {
    func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        defer { processor.finishFeatureCommand(engine: engine) }

        let doc = engine.document
        let hatchEntities = doc.entitiesView.filter { isHatchEntity($0, document: doc) }
        guard !hatchEntities.isEmpty else {
            processor.commandPrompt = "No hatch entities found."
            return
        }

        let range = collectDrawOrderRange(from: doc)
        let newBase = (range.min ?? 1) - 1

        // Sort by current draw order (stable) then assign new sequential orders.
        let sorted = hatchEntities.sorted { $0.drawOrder < $1.drawOrder }
        // Assign from highest-to-lowest so the first sorted gets the highest of the low block.
        for (i, entity) in sorted.enumerated() {
            doc.setDrawOrder(for: entity.handle, to: newBase - (hatchEntities.count - 1) + i)
        }
        processor.commandPrompt = "\(hatchEntities.count) hatch entity(s) sent to back."
    }

    func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    var isSnappingEnabled: Bool { false }
}

// =========================================================================
// MARK: - DrawOrderReferenceCommand (Bring Above / Send Under)
// =========================================================================

/// Two-step interactive command for BRINGABOVEOBJECTS and SENDUNDEROBJECTS.
///
/// Step 1: Selected entities become the subjects. Prompt asks user to click a
///         reference entity. Left-click triggers Step 2.
/// Step 2: Hit-test the click point to find the reference entity, then apply
///         the reorder (bring selection above or send selection under the
///         reference), shifting other entities' draw orders as needed.
///
/// Escape cancels at any time.
@MainActor
final class DrawOrderReferenceCommand: FeatureCommand {
    enum Mode {
        case bringAbove
        case sendUnder
    }

    let mode: Mode
    private var selectionHandles: Set<UUID> = []

    init(mode: Mode) {
        self.mode = mode
    }

    func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        selectionHandles = engine.cadSelection.selectedHandles
        guard !selectionHandles.isEmpty else {
            processor.commandPrompt = "No entities selected. Select entities first, then run the command."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        let verb = (mode == .bringAbove) ? "above" : "under"
        processor.commandPrompt = "Select reference entity to place selection \(verb)"
    }

    func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        selectionHandles = []
    }

    func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let doc = engine.document
        let threshold = 12.0 / engine.camera.zoom

        // Hit-test for entity under click
        guard let refHandle = CADHitTesting.hitTest(
            worldX: worldX, worldY: worldY,
            document: doc,
            threshold: threshold,
            simplifyComplexBlocks: false
        ) else {
            processor.commandPrompt = "No entity found at click point. Try again or press Escape to cancel."
            return .continue
        }

        // Don't allow the reference to be one of the selected entities
        guard !selectionHandles.contains(refHandle) else {
            processor.commandPrompt = "Reference entity cannot be one of the selected entities. Try again."
            return .continue
        }

        guard let refEntity = doc.entity(for: refHandle) else {
            processor.commandPrompt = "Reference entity not found."
            processor.finishFeatureCommand(engine: engine)
            return .finished
        }

        let refOrder = refEntity.drawOrder

        // Collect all entities that need shifting
        let allEntities = doc.entitiesView
        var affected: [(handle: UUID, currentOrder: Int)] = []

        if refOrder == Int.max {
            // Reference has no explicit order. Treat it as if it's at the end.
            // Bring Above: place selection at max+1 (above everything, including reference)
            // Send Under: place selection at max, shift reference up
            let range = collectDrawOrderRange(from: doc)
            let effectiveMax = range.max ?? -1

            if mode == .bringAbove {
                for (i, handle) in selectionHandles.enumerated() {
                    doc.setDrawOrder(for: handle, to: effectiveMax + 1 + i)
                }
                // Give the reference an explicit order too so future operations work
                doc.setDrawOrder(for: refHandle, to: effectiveMax)
            } else {
                // Send under the reference: place selection at effectiveMax+1, reference at effectiveMax+1+count
                for (i, handle) in selectionHandles.enumerated() {
                    doc.setDrawOrder(for: handle, to: effectiveMax + 1 + i)
                }
                doc.setDrawOrder(for: refHandle, to: effectiveMax + 1 + selectionHandles.count)
            }
        } else {
            // Reference has an explicit order.
            // Find all entities at or above the reference slot (for bringAbove)
            // or at/above reference slot (for sendUnder).
            for entity in allEntities {
                let o = entity.drawOrder
                guard o != Int.max else { continue }
                if mode == .bringAbove {
                    if o > refOrder { affected.append((entity.handle, o)) }
                } else {
                    if o >= refOrder { affected.append((entity.handle, o)) }
                }
            }

            // Shift affected entities up by selection count
            let count = selectionHandles.count
            for a in affected {
                doc.setDrawOrder(for: a.handle, to: a.currentOrder + count)
            }

            // Place selection entities
            if mode == .bringAbove {
                let start = refOrder + 1
                for (i, handle) in selectionHandles.enumerated() {
                    doc.setDrawOrder(for: handle, to: start + i)
                }
            } else {
                // Send under: place selection starting at refOrder
                for (i, handle) in selectionHandles.enumerated() {
                    doc.setDrawOrder(for: handle, to: refOrder + i)
                }
            }
        }

        let verb = (mode == .bringAbove) ? "above" : "under"
        processor.commandPrompt = "\(selectionHandles.count) entity(s) placed \(verb) reference."
        selectionHandles = []
        processor.finishFeatureCommand(engine: engine)
        return .finished
    }

    func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .continue }
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    var isSnappingEnabled: Bool { false }
}

// =========================================================================
// MARK: - Command Descriptors
// =========================================================================

/// Command descriptors for all six draw-order commands.
/// Use these when registering with `CADCommandProcessor.registerFeatureCommand`.
enum DrawOrderDescriptors {
    static let bringToFront = CommandDescriptor(
        canonicalName: "BRINGTOFRONT",
        aliases: ["BTF", "BRINGABOVE"],
        category: .modify,
        syntax: "",
        description: "Bring selected entities to the front of the draw order"
    )

    static let sendToBack = CommandDescriptor(
        canonicalName: "SENDTOBACK",
        aliases: ["STB", "SENDBELOW"],
        category: .modify,
        syntax: "",
        description: "Send selected entities to the back of the draw order"
    )

    static let bringAboveObjects = CommandDescriptor(
        canonicalName: "BRINGABOVEOBJECTS",
        aliases: ["BAO"],
        category: .modify,
        syntax: "",
        description: "Place selected entities above a reference entity"
    )

    static let sendUnderObjects = CommandDescriptor(
        canonicalName: "SENDUNDEROBJECTS",
        aliases: ["SUO"],
        category: .modify,
        syntax: "",
        description: "Place selected entities under a reference entity"
    )

    static let textToFront = CommandDescriptor(
        canonicalName: "TEXTTOFRONT",
        aliases: ["TTF"],
        category: .modify,
        syntax: "",
        description: "Bring all text, dimensions, and leaders to the front"
    )

    static let hatchToBack = CommandDescriptor(
        canonicalName: "HATCHTOBACK",
        aliases: ["HTB"],
        category: .modify,
        syntax: "",
        description: "Send all hatches and solid fills to the back"
    )
}
