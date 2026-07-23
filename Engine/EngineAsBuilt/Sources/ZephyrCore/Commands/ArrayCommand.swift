import Foundation
import CSDL3

@MainActor
public final class ArrayCommand: FeatureCommand {
    private enum Step {
        case selectObjects
        case chooseType
        case pickPolarCenter
        case pickPath
        case done
    }

    private let forceAssociative: Bool?
    private let allowedKinds: Set<CADArrayKind>
    private var kind: CADArrayKind?
    private var step: Step = .selectObjects
    private var sourceHandles: Set<UUID> = []

    public init(
        initialKind: CADArrayKind? = nil,
        forceAssociative: Bool? = nil,
        allowedKinds: Set<CADArrayKind> = Set(CADArrayKind.allCases)
    ) {
        self.forceAssociative = forceAssociative
        self.allowedKinds = allowedKinds.isEmpty ? Set(CADArrayKind.allCases) : allowedKinds
        self.kind = initialKind
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        sourceHandles = engine.cadSelection.selectedHandles
        if sourceHandles.isEmpty {
            step = .selectObjects
            processor.commandPrompt = "Select objects for array, then press Enter"
        } else if advanceAfterSelection(engine: engine, processor: processor) == .finished {
            processor.finishFeatureCommand(engine: engine)
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        step = .done
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch step {
        case .selectObjects:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let handle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: engine.simplifyComplexBlocks)
            else { return .handled }
            let shift = engine.io?.pointee.KeyShift ?? false
            if shift { engine.cadSelection.removeFromSelection(handle) }
            else { engine.cadSelection.addToSelection(handle) }
            processor.commandPrompt = "Select objects for array, then press Enter (\(engine.cadSelection.selectedCount) selected)"
            return .handled

        case .chooseType:
            return .handled

        case .pickPolarCenter:
            let base = engine.document.collectiveCenter(for: sourceHandles)
                ?? Vector3(x: worldX, y: worldY, z: 0)
            return createArray(
                basePoint: base,
                centerPoint: Vector3(x: worldX, y: worldY, z: 0),
                pathHandle: nil,
                engine: engine,
                processor: processor)

        case .pickPath:
            let threshold = 8.0 / max(engine.camera.zoom, 0.001)
            guard let pathHandle = engine.cadSelection.hitTest(
                worldX: worldX,
                worldY: worldY,
                document: engine.document,
                threshold: threshold,
                simplifyComplexBlocks: false),
                !sourceHandles.contains(pathHandle),
                isSupportedPath(handle: pathHandle, document: engine.document)
            else {
                processor.commandPrompt = "Select a line, polyline, arc, circle, ellipse, or spline path"
                return .handled
            }
            let base = engine.document.collectiveCenter(for: sourceHandles)
                ?? Vector3(x: worldX, y: worldY, z: 0)
            return createArray(
                basePoint: base,
                centerPoint: nil,
                pathHandle: pathHandle,
                engine: engine,
                processor: processor)

        case .done:
            return .finished
        }
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            if step == .selectObjects {
                sourceHandles = engine.cadSelection.selectedHandles
                guard !sourceHandles.isEmpty else { return .handled }
                return advanceAfterSelection(engine: engine, processor: processor)
            }
            if step == .chooseType {
                let preferred = allowedKinds.contains(processor.arrayDefaultType)
                    ? processor.arrayDefaultType
                    : .rectangular
                kind = preferred
                return advanceAfterType(engine: engine, processor: processor)
            }
            return .continue
        case SDL_SCANCODE_R where step == .chooseType && allowedKinds.contains(.rectangular):
            kind = .rectangular
            return advanceAfterType(engine: engine, processor: processor)
        case SDL_SCANCODE_P where step == .chooseType && allowedKinds.contains(.polar):
            kind = .polar
            return advanceAfterType(engine: engine, processor: processor)
        case SDL_SCANCODE_A where step == .chooseType && allowedKinds.contains(.path):
            kind = .path
            return advanceAfterType(engine: engine, processor: processor)
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard step == .chooseType else { return .continue }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let requested: CADArrayKind
        switch value {
        case "":
            requested = allowedKinds.contains(processor.arrayDefaultType)
                ? processor.arrayDefaultType
                : .rectangular
        case "r", "rect", "rectangular": requested = .rectangular
        case "p", "polar": requested = .polar
        case "a", "path", "arraypath": requested = .path
        default: return .continue
        }
        guard allowedKinds.contains(requested) else {
            processor.commandPrompt = arrayTypePrompt(defaultKind: processor.arrayDefaultType)
            return .handled
        }
        kind = requested
        return advanceAfterType(engine: engine, processor: processor)
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}

    public var isSnappingEnabled: Bool {
        step != .selectObjects && step != .chooseType
    }

    public func getDrawingSnapPoints() -> [Vector3] { [] }

    private func advanceAfterSelection(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        sourceHandles = engine.cadSelection.selectedHandles
        guard !sourceHandles.isEmpty else {
            step = .selectObjects
            processor.commandPrompt = "Select objects for array, then press Enter"
            return .handled
        }
        if kind == nil {
            step = .chooseType
            processor.commandPrompt = arrayTypePrompt(defaultKind: processor.arrayDefaultType)
            return .handled
        }
        return advanceAfterType(engine: engine, processor: processor)
    }

    private func advanceAfterType(
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let selectedKind = kind ?? .rectangular
        guard allowedKinds.contains(selectedKind) else {
            kind = nil
            step = .chooseType
            processor.commandPrompt = arrayTypePrompt(defaultKind: processor.arrayDefaultType)
            return .handled
        }
        processor.arrayDefaultType = selectedKind
        switch selectedKind {
        case .rectangular:
            let basePoint = engine.document.collectiveCenter(for: sourceHandles) ?? .zero
            return createArray(
                basePoint: basePoint,
                centerPoint: nil,
                pathHandle: nil,
                engine: engine,
                processor: processor)
        case .polar:
            step = .pickPolarCenter
            processor.commandPrompt = "Specify center point of array"
            return .handled
        case .path:
            step = .pickPath
            processor.commandPrompt = "Select path curve"
            return .handled
        }
    }

    private func createArray(
        basePoint: Vector3,
        centerPoint: Vector3?,
        pathHandle: UUID?,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        guard let source = buildSourceBlock(
            handles: sourceHandles,
            basePoint: basePoint,
            document: engine.document)
        else {
            processor.commandPrompt = "Unable to create array from the selected objects"
            return .finished
        }

        let bounds = source.block.localBoundingBox.size
        let columnSpacing = max(abs(bounds.x) * 1.5, 1.0)
        let rowSpacing = max(abs(bounds.y) * 1.5, 1.0)
        var array: CADArrayData

        switch kind ?? .rectangular {
        case .rectangular:
            array = .rectangular(
                columns: 4,
                rows: 3,
                columnSpacing: columnSpacing,
                rowSpacing: rowSpacing)

        case .polar:
            let center = centerPoint ?? basePoint
            array = .polar(
                itemCount: 6,
                centerPoint: center - basePoint)

        case .path:
            guard let pathHandle,
                  let pathEntity = engine.document.entity(for: pathHandle),
                  let pathGeometry = engine.document.resolvedGeometry(for: pathEntity),
                  let cached = CADArrayPathResolver.localPoints(
                    geometry: pathGeometry,
                    pathTransform: pathEntity.transform,
                    containerTransform: .translated(by: basePoint))
            else {
                processor.commandPrompt = "The selected object is not a supported path"
                return .finished
            }
            let total = zip(cached, cached.dropFirst()).reduce(0.0) { $0 + $1.0.distance(to: $1.1) }
            array = .path(
                method: .divide,
                itemCount: 6,
                itemSpacing: max(total / 5.0, 1e-6),
                alignItems: true,
                pathEntityHandle: pathHandle,
                cachedPath: cached)
        }

        var entity = CADEntity(
            layerID: source.layerID,
            blockID: source.block.handle,
            arrayData: array,
            transform: .translated(by: basePoint),
            drawOrder: source.drawOrder)
        entity.updateArrayCache(
            sourceBoundingBox: source.block.localBoundingBox,
            pathPoints: array.cachedPath)
        let associative = forceAssociative ?? processor.arrayAssociativity
        engine.cadSelection.clearSelection()
        if associative {
            engine.document.replaceWithAssociativeArray(
                sourceBlock: source.block,
                removing: sourceHandles,
                arrayEntity: entity)
            engine.cadSelection.select(entity.handle)
        } else {
            let copies = engine.document.replaceWithNonAssociativeArray(
                sourceBlock: source.block,
                removing: sourceHandles,
                arrayEntity: entity)
            for handle in copies { engine.cadSelection.addToSelection(handle) }
        }
        processor.commandPrompt = nil
        step = .done
        return .finished
    }

    private func arrayTypePrompt(defaultKind: CADArrayKind) -> String {
        let orderedKinds: [CADArrayKind] = [.rectangular, .path, .polar]
        let options = orderedKinds.compactMap { kind -> String? in
            guard allowedKinds.contains(kind) else { return nil }
            switch kind {
            case .rectangular: return "Rectangular"
            case .path: return "Path"
            case .polar: return "Polar"
            }
        }
        let effectiveDefault = allowedKinds.contains(defaultKind) ? defaultKind : .rectangular
        let defaultName: String
        switch effectiveDefault {
        case .rectangular: defaultName = "Rectangular"
        case .path: defaultName = "Path"
        case .polar: defaultName = "Polar"
        }
        return "Enter array type [\(options.joined(separator: "/"))] <\(defaultName)>:"
    }

    private func buildSourceBlock(
        handles: Set<UUID>,
        basePoint: Vector3,
        document: CADDocument
    ) -> (block: CADBlock, layerID: UUID, drawOrder: Int)? {
        let inverseBase = Transform3D.translated(by: Vector3(
            x: -basePoint.x,
            y: -basePoint.y,
            z: -basePoint.z))
        var geometry: [CADPrimitive] = []
        var styles: [Int: CADPrimitiveStyle] = [:]
        var primitiveXData: [Int: [String: XDataValue]] = [:]
        var layerID = document.activeLayerID
        var drawOrder = Int.max

        for handle in handles.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entity = document.entity(for: handle),
                  let sourceGeometry = document.resolvedGeometry(for: entity)
            else { continue }
            layerID = layerID ?? entity.layerID
            drawOrder = min(drawOrder, entity.drawOrder)

            let instances: [Transform3D]
            if let array = entity.arrayData {
                let path = CADArrayPathResolver.points(
                    for: array,
                    containerTransform: entity.transform,
                    document: document)
                instances = array.evaluatedInstances(pathPoints: path).map {
                    entity.transform.multiplying(by: $0.transform)
                }
            } else {
                instances = [entity.transform]
            }

            let sourceStyles: [Int: CADPrimitiveStyle]
            let sourceXData: [Int: [String: XDataValue]]
            if let blockID = entity.blockID, let block = document.block(for: blockID) {
                sourceStyles = block.primitiveStyles
                sourceXData = block.primitiveXData
            } else {
                sourceStyles = [:]
                sourceXData = [:]
            }

            for instance in instances {
                let transform = inverseBase.multiplying(by: instance)
                for (sourceIndex, primitive) in sourceGeometry.enumerated() {
                    let transformed = CADGeometryMath.transformPrimitives([primitive], by: transform)
                    let start = geometry.count
                    geometry.append(contentsOf: transformed)

                    let style = resolvedSourceStyle(
                        sourceStyles[sourceIndex],
                        entity: entity,
                        document: document)
                    for outputIndex in start..<geometry.count { styles[outputIndex] = style }

                    var xdata = entity.xdata
                    if let primitiveValues = sourceXData[sourceIndex] {
                        for (key, value) in primitiveValues { xdata[key] = value }
                    }
                    if !xdata.isEmpty {
                        for outputIndex in start..<geometry.count { primitiveXData[outputIndex] = xdata }
                    }
                }
            }
        }

        guard !geometry.isEmpty, let finalLayerID = layerID else { return nil }
        let name = "*UARR_" + String(UUID().uuidString.prefix(8))
        return (
            CADBlock(
                name: name,
                geometry: geometry,
                primitiveStyles: styles,
                primitiveXData: primitiveXData,
                dxfFlags: 1),
            finalLayerID,
            drawOrder)
    }

    private func resolvedSourceStyle(
        _ source: CADPrimitiveStyle?,
        entity: CADEntity,
        document: CADDocument
    ) -> CADPrimitiveStyle {
        var style = source ?? CADPrimitiveStyle()
        let layer = document.layer(for: entity.layerID)
        let layerName = style.layerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if layerName.isEmpty || layerName == "0" {
            style.layerName = layer?.name
        }

        if let value = entity.xdata["dxf.color"],
           case .string(let hex) = value,
           let color = ColorRGBA(hex: hex) {
            style.color = color
            style.isColorByBlock = false
        } else if style.isColorByBlock, let color = layer?.color {
            style.color = color
            style.isColorByBlock = false
        }

        if let value = entity.xdata["dxf.lineType"],
           case .string(let lineType) = value,
           !lineType.isEmpty,
           lineType.uppercased() != "BYLAYER" {
            style.lineType = lineType
            style.isLineTypeByBlock = false
        } else if style.isLineTypeByBlock, let lineType = layer?.lineType {
            style.lineType = lineType
            style.isLineTypeByBlock = false
        }

        if let value = entity.xdata["dxf.lineWeight"],
           case .double(let lineWeight) = value,
           lineWeight >= 0 {
            style.lineWeight = lineWeight
            style.isLineWeightByBlock = false
        } else if style.isLineWeightByBlock, let lineWeight = layer?.lineWeight {
            style.lineWeight = lineWeight
            style.isLineWeightByBlock = false
        }

        if let value = entity.xdata["dxf.lineTypeScale"], case .double(let scale) = value {
            style.lineTypeScale = (style.lineTypeScale ?? 1.0) * scale
        }
        if let value = entity.xdata["dxf.polylineWidth"], case .double(let width) = value {
            style.geomWidth = width
        }
        if let value = entity.xdata["dxf.opacity"], case .double(let opacity) = value {
            style.opacity = max(0, min(1, (style.opacity ?? 1.0) * opacity))
        }
        return style
    }

    private func isSupportedPath(handle: UUID, document: CADDocument) -> Bool {
        guard let entity = document.entity(for: handle),
              let geometry = document.resolvedGeometry(for: entity)
        else { return false }
        return geometry.contains { !CADArrayPathResolver.sampledPoints(from: $0).isEmpty }
    }
}

@MainActor
public final class ExplodeArrayCommand: FeatureCommand {
    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let exploded = engine.document.explodeAssociativeArrays(
            handles: engine.cadSelection.selectedHandles)
        if !exploded.isEmpty {
            engine.cadSelection.clearSelection()
            for handle in exploded { engine.cadSelection.addToSelection(handle) }
        }
        processor.finishFeatureCommand(engine: engine)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .finished }
    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .finished }
    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}

@MainActor
public final class ArrayEditCommand: FeatureCommand {
    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        if selectCurrentArray(engine: engine) {
            processor.finishFeatureCommand(engine: engine)
        } else {
            processor.commandPrompt = "Select associative array"
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let threshold = 8.0 / max(engine.camera.zoom, 0.001)
        guard let handle = engine.cadSelection.hitTest(
            worldX: worldX,
            worldY: worldY,
            document: engine.document,
            threshold: threshold,
            simplifyComplexBlocks: engine.simplifyComplexBlocks),
              engine.document.entity(for: handle)?.arrayData != nil else {
            processor.commandPrompt = "Select associative array"
            return .handled
        }
        engine.cadSelection.select(handle)
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            return selectCurrentArray(engine: engine) ? .finished : .handled
        default:
            return .continue
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }

    private func selectCurrentArray(engine: PhrostEngine) -> Bool {
        guard engine.cadSelection.selectedCount == 1,
              let handle = engine.cadSelection.lastSelectedHandle,
              engine.document.entity(for: handle)?.arrayData != nil else { return false }
        engine.cadSelection.select(handle)
        return true
    }
}

@MainActor
public final class ArrayCloseCommand: FeatureCommand {
    private let commandLineOnly: Bool

    public init(commandLineOnly: Bool) {
        self.commandLineOnly = commandLineOnly
    }

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        guard engine.tabManager.editingArrayHandle != nil else {
            if !commandLineOnly,
               engine.cadSelection.selectedCount == 1,
               let handle = engine.cadSelection.lastSelectedHandle,
               engine.document.entity(for: handle)?.arrayData != nil {
                engine.cadSelection.clearSelection()
            }
            processor.finishFeatureCommand(engine: engine)
            return
        }

        if commandLineOnly {
            processor.commandPrompt = "Save changes to array [Yes/No] <Yes>:"
        } else {
            engine.ui.blockClosePending = true
            processor.finishFeatureCommand(engine: engine)
        }
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleMouseClick(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .handled }

    public func handleMouseMotion(
        worldX: Double,
        worldY: Double,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}

    public func handleKeyDown(
        scancode: SDL_Scancode,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER:
            engine.tabManager.exitBlockEditor(saveChanges: true)
            return .finished
        default:
            return .continue
        }
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "y", "yes", "1":
            engine.tabManager.exitBlockEditor(saveChanges: true)
            return .finished
        case "n", "no", "0":
            engine.tabManager.exitBlockEditor(saveChanges: false)
            return .finished
        default:
            processor.commandPrompt = "Save changes to array [Yes/No] <Yes>:"
            return .handled
        }
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
}

@MainActor
public final class ArrayAssociativityCommand: FeatureCommand {
    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Enter new value for ARRAYASSOCIATIVITY <\(processor.arrayAssociativity ? 1 : 0)>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": return .finished
        case "0", "off", "false", "no": processor.arrayAssociativity = false
        case "1", "on", "true", "yes": processor.arrayAssociativity = true
        default:
            processor.commandPrompt = "ARRAYASSOCIATIVITY accepts 0 or 1:"
            return .handled
        }
        print("[CAD] ARRAYASSOCIATIVITY = \(processor.arrayAssociativity ? 1 : 0)")
        return .finished
    }

    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .handled }
    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER: return .finished
        default: return .continue
        }
    }
    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
}

@MainActor
public final class ArrayTypeCommand: FeatureCommand {
    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = "Enter new value for ARRAYTYPE <\(arrayTypeValue(processor.arrayDefaultType))>:"
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleCommandText(
        _ text: String,
        engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "": return .finished
        case "0", "r", "rect", "rectangular": processor.arrayDefaultType = .rectangular
        case "1", "a", "path": processor.arrayDefaultType = .path
        case "2", "p", "polar": processor.arrayDefaultType = .polar
        default:
            processor.commandPrompt = "ARRAYTYPE accepts 0 (Rectangular), 1 (Path), or 2 (Polar):"
            return .handled
        }
        print("[CAD] ARRAYTYPE = \(arrayTypeValue(processor.arrayDefaultType))")
        return .finished
    }

    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .handled }
    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult {
        switch scancode {
        case SDL_SCANCODE_RETURN, SDL_SCANCODE_KP_ENTER: return .finished
        default: return .continue
        }
    }
    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }

    private func arrayTypeValue(_ kind: CADArrayKind) -> Int {
        switch kind {
        case .rectangular: return 0
        case .path: return 1
        case .polar: return 2
        }
    }
}

@MainActor
public final class ArrayEditStateCommand: FeatureCommand {
    public init() {}

    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        print("[CAD] ARRAYEDITSTATE = \(engine.tabManager.editingArrayHandle == nil ? 0 : 1)")
        processor.finishFeatureCommand(engine: engine)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        processor.commandPrompt = nil
    }

    public func handleMouseClick(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .finished }
    public func handleMouseMotion(worldX: Double, worldY: Double, engine: PhrostEngine, processor: CADCommandProcessor) {}
    public func handleKeyDown(scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor) -> CommandResult { .finished }
    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
    public var isSnappingEnabled: Bool { false }
}
