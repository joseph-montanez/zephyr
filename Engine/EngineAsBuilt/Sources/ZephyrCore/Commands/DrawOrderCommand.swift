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

/// Current visual order of every entity in the document: the same
/// `(drawOrder, handle)` comparator the renderers and PDF export sort by.
/// Lower draws first (back); `Int.max` (no explicit order) sorts last.
func visualEntityOrder(in document: CADDocument) -> [CADEntity] {
    document.entitiesView.sorted {
        if $0.drawOrder != $1.drawOrder { return $0.drawOrder < $1.drawOrder }
        return $0.handle.uuidString < $1.handle.uuidString
    }
}

/// Relocate `movers` to the absolute front (`toFront == true`) or back,
/// preserving their current relative order. Fresh entities default to
/// `Int.max`, which no finite value can overtake, so the whole document is
/// first materialized into a compact 0..<n sequence in current visual order —
/// the picture does not change, but the moved block truly lands at the end.
/// Exactly one undo entry via `setDrawOrders`. Returns the placed count.
@discardableResult
func placeDrawOrder(movers: [CADEntity], toFront: Bool, in document: CADDocument) -> Int {
    guard !movers.isEmpty else { return 0 }
    let visual = visualEntityOrder(in: document)
    let moverIDs = Set(movers.map(\.handle))
    let orderedMovers = visual.filter { moverIDs.contains($0.handle) }
    guard !orderedMovers.isEmpty else { return 0 }
    let staying = visual.filter { !moverIDs.contains($0.handle) }
    var map: [UUID: Int] = [:]
    map.reserveCapacity(visual.count)
    if toFront {
        for (i, entity) in staying.enumerated() { map[entity.handle] = i }
        for (j, entity) in orderedMovers.enumerated() { map[entity.handle] = staying.count + j }
    } else {
        for (j, entity) in orderedMovers.enumerated() { map[entity.handle] = j }
        for (i, entity) in staying.enumerated() { map[entity.handle] = orderedMovers.count + i }
    }
    document.setDrawOrders(map)
    return orderedMovers.count
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
        case .hatch, .hatchPath, .fillPolygon, .fillComplexPolygon, .gradient:
            return true
        default:
            break
        }
    }
    return false
}

/// Shared bring-to-front reorder used by `BringToFrontCommand` and the
/// `DRAWORDER` umbrella's Front option. Returns the placed count.
@discardableResult
func applyBringToFront(handles: Set<UUID>, document: CADDocument) -> Int {
    guard !handles.isEmpty else { return 0 }
    let movers = document.entitiesView.filter { handles.contains($0.handle) }
    return placeDrawOrder(movers: movers, toFront: true, in: document)
}

/// Shared send-to-back reorder used by `SendToBackCommand` and the
/// `DRAWORDER` umbrella's Back option. Returns the placed count.
@discardableResult
func applySendToBack(handles: Set<UUID>, document: CADDocument) -> Int {
    guard !handles.isEmpty else { return 0 }
    let movers = document.entitiesView.filter { handles.contains($0.handle) }
    return placeDrawOrder(movers: movers, toFront: false, in: document)
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

        let count = applyBringToFront(handles: handles, document: engine.document)
        processor.commandPrompt = "\(count) entity(s) brought to front."
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

        let count = applySendToBack(handles: handles, document: engine.document)
        processor.commandPrompt = "\(count) entity(s) sent to back."
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

        let count = placeDrawOrder(movers: textEntities, toFront: true, in: doc)
        processor.commandPrompt = "\(count) text entity(s) brought to front."
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

        let count = placeDrawOrder(movers: hatchEntities, toFront: false, in: doc)
        processor.commandPrompt = "\(count) hatch entity(s) sent to back."
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

        guard doc.entity(for: refHandle) != nil else {
            processor.commandPrompt = "Reference entity not found."
            processor.finishFeatureCommand(engine: engine)
            return .finished
        }

        // Work in current visual order so unordered references and neighbors
        // sort exactly as drawn; the result is a compact 0..<n sequence with
        // the selection inserted above (after) or under (before) the
        // reference. One undo entry.
        let visual = visualEntityOrder(in: doc)
        let orderedSelection = visual.filter { selectionHandles.contains($0.handle) }
        let ordered = visual.filter { !selectionHandles.contains($0.handle) }
        guard let refIndex = ordered.firstIndex(where: { $0.handle == refHandle }) else {
            processor.commandPrompt = "Reference entity not found."
            processor.finishFeatureCommand(engine: engine)
            return .finished
        }
        let insertAt = (mode == .bringAbove) ? refIndex + 1 : refIndex
        var sequence: [CADEntity] = []
        sequence.reserveCapacity(ordered.count + orderedSelection.count)
        sequence.append(contentsOf: ordered.prefix(insertAt))
        sequence.append(contentsOf: orderedSelection)
        sequence.append(contentsOf: ordered.suffix(ordered.count - insertAt))
        var map: [UUID: Int] = [:]
        map.reserveCapacity(sequence.count)
        for (i, entity) in sequence.enumerated() { map[entity.handle] = i }
        doc.setDrawOrders(map)

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

    static let drawOrder = CommandDescriptor(
        canonicalName: "DRAWORDER",
        aliases: ["DR"],
        category: .modify,
        syntax: "[Above/Under/Front/Back]",
        description: "Change the draw order of selected entities"
    )
}

// =========================================================================
// MARK: - DrawOrderUmbrellaCommand (DRAWORDER)
// =========================================================================

/// AutoCAD `DRAWORDER` umbrella: one command with Above/Under/Front/Back
/// options over the current selection. Front/Back reuse the shared
/// `applyBringToFront`/`applySendToBack` reorder (same math as BTF/STB);
/// Above/Under hand off to `DrawOrderReferenceCommand` for the reference
/// pick, so no reorder logic is duplicated.
@MainActor
final class DrawOrderUmbrellaCommand: FeatureCommand {

    func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard engine.cadSelection.hasSelection else {
            processor.commandPrompt = "No entities selected. Select entities first, then run DRAWORDER."
            processor.finishFeatureCommand(engine: engine)
            return
        }
        processor.commandPrompt = "DRAWORDER [Above/Under/Front/Back]:"
    }

    func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}

    func commandTextOptions(for input: String) -> [FeatureCommandTextOption] {
        [
            .init(value: "A", title: "Above", aliases: ["ABOVE"], description: "Place selection above a reference entity"),
            .init(value: "U", title: "Under", aliases: ["UNDER"], description: "Place selection under a reference entity"),
            .init(value: "F", title: "Front", aliases: ["FRONT"], description: "Bring selection to the front"),
            .init(value: "B", title: "Back", aliases: ["BACK"], description: "Send selection to the back"),
        ]
    }

    func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let upper = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let handles = engine.cadSelection.selectedHandles
        switch upper {
        case "F", "FRONT":
            let count = applyBringToFront(handles: handles, document: engine.document)
            processor.commandPrompt = "\(count) entity(s) brought to front."
            return .finished
        case "B", "BACK":
            let count = applySendToBack(handles: handles, document: engine.document)
            processor.commandPrompt = "\(count) entity(s) sent to back."
            return .finished
        case "A", "ABOVE":
            chainReferenceCommand(mode: .bringAbove, engine: engine, processor: processor)
            return .finished
        case "U", "UNDER":
            chainReferenceCommand(mode: .sendUnder, engine: engine, processor: processor)
            return .finished
        default:
            processor.commandPrompt = "Unknown option. DRAWORDER [Above/Under/Front/Back]:"
            return .handled
        }
    }

    private func chainReferenceCommand(
        mode: DrawOrderReferenceCommand.Mode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {
        processor.finishFeatureCommand(engine: engine)
        let ref = DrawOrderReferenceCommand(mode: mode)
        processor.activeFeatureCommand = ref
        ref.start(engine: engine, processor: processor)
    }

    func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }
    func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {}
    func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    var isSnappingEnabled: Bool { false }
}