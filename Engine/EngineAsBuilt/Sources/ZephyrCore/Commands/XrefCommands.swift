import Foundation
import CSDL3
import ImGui

// =========================================================================
// XATTACH — pick a drawing, choose Attachment/Overlay, place it.
// -XREF — command-line xref management (list/attach/detach/reload/
// unload/load/repath; Bind is wired in the bind unit).
// =========================================================================

@MainActor
enum XrefCommandSupport {
    @MainActor
    static func tabContext(engine: PhrostEngine) -> (
        store: XrefRuntimeStore, documents: [CADDocument],
        active: CADDocument, hostFolder: String?
    )? {
        guard let tab = engine.tabManager.activeTab else { return nil }
        return (
            tab.xrefStore,
            tab.drawingViews.map(\.document),
            engine.document,
            tab.fileURL?.deletingLastPathComponent().path)
    }

    static func openTextPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = true
    }

    static func showCanvasPrompt(_ prompt: String, processor: CADCommandProcessor) {
        processor.commandPrompt = prompt
        processor.commandBuffer = ""
        processor.commandSelectionIndex = 0
        processor.commandLineActive = false
    }

    static func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

public final class XAttachCommand: FeatureCommand {
    public var name: String { "XATTACH" }

    private enum Stage {
        case awaitingFile, awaitingType, awaitingPoint
        case awaitingScaleX, awaitingScaleY, awaitingRotation, done
    }

    private var stage: Stage = .awaitingFile
    private var pickedURL: URL?
    private var blockID: UUID?
    private var blockName: String = ""
    private var insertionPoint: Vector3 = .zero
    private var defaultScale: Double = 1
    private var scaleX: Double = 1
    private var scaleY: Double = 1
    private var mouseWorldX: Double = 0
    private var mouseWorldY: Double = 0

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Select drawing file to attach (Esc to cancel)…"
        processor.commandLineActive = false
        NativeFileDialog.showOpenDialog(
            window: engine.dialogParentWindow,
            filters: [NativeFileDialog.Filter(label: "Drawings", extensions: ["dxf", "dwg"])]
        ) { [weak self, weak processor] urls in
            guard let self, let processor else { return }
            MainActor.assumeIsolated {
                guard let url = urls.first else {
                    self.stage = .done
                    processor.activeFeatureCommand = nil
                    return
                }
                self.pickedURL = url
                self.stage = .awaitingType
                XrefCommandSupport.openTextPrompt(
                    "Attach as [Attachment/Overlay] <Attachment>:", processor: processor)
            }
        }
    }

    /// Entry for ATTACH/-ATTACH routing: file already chosen.
    public func startWithPickedFile(
        _ url: URL, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        pickedURL = url
        stage = .awaitingType
        XrefCommandSupport.openTextPrompt(
            "Attach as [Attachment/Overlay] <Attachment>:", processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        stage = .done
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stage {
        case .awaitingType:
            let overlay = ["O", "OVERLAY"].contains(input.uppercased())
            return attachPicked(overlay: overlay, engine: engine, processor: processor)
        case .awaitingScaleX:
            scaleX = Double(input) ?? defaultScale
            stage = .awaitingScaleY
            XrefCommandSupport.openTextPrompt(
                "Specify Y scale factor <\(XrefCommandSupport.fmt(scaleX))>:", processor: processor)
            return .continue
        case .awaitingScaleY:
            scaleY = Double(input) ?? scaleX
            stage = .awaitingRotation
            XrefCommandSupport.openTextPrompt("Specify rotation angle <0>:", processor: processor)
            return .continue
        case .awaitingRotation:
            place(rotationDegrees: Double(input) ?? 0, engine: engine)
            return .finished
        default:
            return stage == .done ? .finished : .continue
        }
    }

    private func attachPicked(
        overlay: Bool, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard let url = pickedURL,
              let ctx = XrefCommandSupport.tabContext(engine: engine) else {
            return .finished
        }
        do {
            let (block, scale, _) = try XrefManager.attach(
                store: ctx.store, documents: ctx.documents,
                activeDocument: ctx.active, fileURL: url,
                isOverlay: overlay, pathType: XrefSysvars.refPathType,
                hostFolder: ctx.hostFolder)
            blockID = block.handle
            blockName = block.name
            defaultScale = scale
            stage = .awaitingPoint
            XrefCommandSupport.showCanvasPrompt(
                "Specify insertion point for \"\(block.name)\":", processor: processor)
            return .continue
        } catch {
            print("[Xref] Attach failed: \(error)")
            return .finished
        }
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        guard stage == .awaitingPoint else { return stage == .done ? .finished : .continue }
        insertionPoint = Vector3(x: worldX, y: worldY, z: 0)
        stage = .awaitingScaleX
        XrefCommandSupport.openTextPrompt(
            "Specify X scale factor <\(XrefCommandSupport.fmt(defaultScale))>:",
            processor: processor)
        return .continue
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {
        mouseWorldX = worldX
        mouseWorldY = worldY
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
        guard stage == .awaitingPoint, let blockID,
              let block = engine.document.effectiveBlock(for: blockID) else { return }
        let prims = block.geometry.isEmpty
            ? CADRendererBridge.unresolvedXrefPlaceholder(blockName: block.name)
            : nil
        let box = prims.map { CADBlock.computeBoundingBox(from: $0) } ?? block.localBoundingBox
        let drawList = igGetForegroundDrawList_ViewportPtr(nil)
        let color = makeCol32(255, 217, 51, 230)
        let corners = [
            (box.min.x, box.min.y), (box.max.x, box.min.y),
            (box.max.x, box.max.y), (box.min.x, box.max.y),
        ]
        let screen = corners.map { c in
            EngineCameraManager.worldToScreen(
                worldX: mouseWorldX + c.0 * defaultScale,
                worldY: mouseWorldY + c.1 * defaultScale, cam: cam)
        }
        for i in screen.indices {
            let a = screen[i]
            let b = screen[(i + 1) % screen.count]
            ImDrawListAddLine(
                drawList, ImVec2(x: a.x, y: a.y), ImVec2(x: b.x, y: b.y), color, 1.5)
        }
    }

    private func place(rotationDegrees: Double, engine: PhrostEngine) {
        guard let blockID else { stage = .done; return }
        let layerID = engine.document.activeLayerID
            ?? engine.document.allLayers.first?.handle ?? UUID()
        engine.document.addEntity(CADEntity(
            layerID: layerID, blockID: blockID,
            transform: DrawingFileInsert.insertionTransform(
                point: insertionPoint, scaleX: scaleX, scaleY: scaleY,
                rotationDegrees: rotationDegrees)))
        print("[Xref] Attached '\(blockName)' at (\(insertionPoint.x), \(insertionPoint.y))")
        stage = .done
    }
}

// MARK: - -XREF

public final class MinusXrefCommand: FeatureCommand {
    public var name: String { "-XREF" }

    private enum Stage {
        case awaitingOption
        case awaitingName(option: String)
        case awaitingPath(blockHandle: UUID)
        case awaitingAttachPath
        case done
    }

    private var stage: Stage = .awaitingOption

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        XrefCommandSupport.openTextPrompt(
            "Enter xref option [?/Bind/Attach/Detach/Reload/Unload/Load/Path] <Attach>:",
            processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        stage = .done
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ctx = XrefCommandSupport.tabContext(engine: engine) else { return .finished }
        switch stage {
        case .awaitingOption:
            switch input.uppercased() {
            case "?", "":
                if input == "?" {
                    listXrefs(ctx: ctx, processor: processor)
                    return .continue
                }
                fallthrough
            case "A", "ATTACH":
                stage = .awaitingAttachPath
                XrefCommandSupport.openTextPrompt(
                    "Drawing file to attach:", processor: processor)
                return .continue
            case "B", "BIND", "D", "DETACH", "R", "RELOAD", "U", "UNLOAD", "L", "LOAD", "P", "PATH":
                let option = input.uppercased()
                stage = .awaitingName(option: option)
                XrefCommandSupport.openTextPrompt("Xref name:", processor: processor)
                return .continue
            default:
                XrefCommandSupport.openTextPrompt(
                    "Invalid option. [?/Bind/Attach/Detach/Reload/Unload/Load/Path]:",
                    processor: processor)
                return .continue
            }
        case .awaitingAttachPath:
            do {
                let (block, _, _) = try XrefManager.attach(
                    store: ctx.store, documents: ctx.documents,
                    activeDocument: ctx.active,
                    fileURL: URL(fileURLWithPath: input),
                    isOverlay: false, pathType: XrefSysvars.refPathType,
                    hostFolder: ctx.hostFolder)
                print("[Xref] Attached '\(block.name)'. Use INSERT to place instances.")
            } catch {
                print("[Xref] Attach failed: \(error)")
            }
            return .finished
        case .awaitingName(let option):
            guard let block = ctx.active.allBlocks.first(where: {
                $0.isXref && $0.name.caseInsensitiveCompare(input) == .orderedSame
            }) else {
                print("[Xref] No xref named \"\(input)\".")
                return .finished
            }
            switch option {
            case "B", "BIND":
                do {
                    try XrefManager.bind(
                        store: ctx.store, documents: ctx.documents,
                        activeDocument: ctx.active, blockHandle: block.handle,
                        bindType: XrefSysvars.bindType)
                    print("[Xref] Bound '\(block.name)' into the host drawing.")
                } catch {
                    print("[Xref] Bind failed: \(error)")
                }
                return .finished
            case "D", "DETACH":
                let result = XrefManager.detach(
                    store: ctx.store, documents: ctx.documents,
                    activeDocument: ctx.active, blockHandle: block.handle)
                print("[Xref] Detached '\(block.name)': \(result.instances) instance(s) removed, layers purged: \(result.layersPurged).")
                return .finished
            case "R", "RELOAD", "L", "LOAD":
                ctx.store.updateEntry(for: block.handle) { $0.userUnloaded = false }
                XrefLoader.requestLoad(
                    store: ctx.store, blockHandle: block.handle,
                    documents: ctx.documents, hostFolder: ctx.hostFolder,
                    forceReload: true)
                return .finished
            case "U", "UNLOAD":
                XrefLoader.unload(
                    store: ctx.store, blockHandle: block.handle, documents: ctx.documents)
                return .finished
            default:  // PATH
                stage = .awaitingPath(blockHandle: block.handle)
                XrefCommandSupport.openTextPrompt("New path:", processor: processor)
                return .continue
            }
        case .awaitingPath(let blockHandle):
            XrefManager.repath(
                store: ctx.store, documents: ctx.documents,
                blockHandle: blockHandle,
                newFileURL: URL(fileURLWithPath: input),
                pathType: XrefSysvars.refPathType, hostFolder: ctx.hostFolder)
            return .finished
        case .done:
            return .finished
        }
    }

    private func listXrefs(
        ctx: (store: XrefRuntimeStore, documents: [CADDocument], active: CADDocument, hostFolder: String?),
        processor: CADCommandProcessor
    ) {
        let rows = XrefPalettePolicy.rows(store: ctx.store, documents: ctx.documents)
        if rows.isEmpty {
            print("[Xref] No external references in this drawing.")
        }
        for row in rows {
            print("[Xref] \(row.name) — \(row.statusText), \(row.typeText), \(row.instanceCount) instance(s), saved: \(row.savedPath), found: \(row.foundAtPath ?? "—")")
        }
        XrefCommandSupport.openTextPrompt(
            "Enter xref option [?/Bind/Attach/Detach/Reload/Unload/Load/Path] <Attach>:",
            processor: processor)
    }
}

// MARK: - XBIND

/// Binds one xref-dependent layer into the host (rename per BINDTYPE,
/// or merge when BINDTYPE=1 and the leaf name already exists).
public final class XBindCommand: FeatureCommand {
    public var name: String { "XBIND" }
    private var done = false

    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        XrefCommandSupport.openTextPrompt(
            "Dependent symbol to bind (e.g. SitePlan|Walls):", processor: processor)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) { done = true }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult { .continue }

    public func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor
    ) {}

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public func handleCommandText(
        _ text: String, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .finished }
        guard let tab = engine.tabManager.activeTab else { return .finished }
        var bound: String?
        for doc in tab.drawingViews.map(\.document) {
            if let result = doc.xbindLayer(named: input, bindType: XrefSysvars.bindType) {
                bound = result
            } else if let result = doc.xbindStyle(named: input, bindType: XrefSysvars.bindType) {
                bound = result
            }
        }
        if let bound {
            print("[Xref] Bound layer '\(input)' as '\(bound)'.")
        } else {
            print("[Xref] '\(input)' is not an xref-dependent layer, style, or linetype.")
        }
        return .finished
    }
}
