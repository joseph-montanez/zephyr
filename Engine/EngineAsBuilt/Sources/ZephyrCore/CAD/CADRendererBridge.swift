import Foundation
import SwiftSDL

// Large-file design note:
// Keep this type as the regeneration coordinator. Snapshot compilation,
// render-resource application, and direct-edit mutation are separate services
// to extract through composition; do not add class extensions to spread this
// implementation across files. See Documentation/LargeFileRefactoring.md.

// =========================================================================
// MARK: - CADRendererBridge
//
// The bridge between the CAD document model and the GPU rendering pipeline.
// Converts CAD entities into RenderPrimitives, manages async regeneration
// of geometry, and provides vertex-editing hooks for grip-based direct
// manipulation (vertex/midpoint dragging).
//
// Key responsibilities:
//   - Regenerate geometry from document snapshots asynchronously
//   - Apply regeneration results atomically (generation-tagged to avoid races)
//   - Convert entity geometry to vertex buffers via CADVertexBufferBuilder
//   - Provide vertex-editing access for grip-based direct manipulation

// =========================================================================
// MARK: - CADRendererBridge
// =========================================================================

/// Converts CAD entities from the document into `RenderPrimitive` objects
/// that the existing SDL rendering pipeline can draw.
///
/// Usage (in the render loop):
/// ```swift
/// if document.isDirty {
///     bridge.regenerate(from: document, into: engine.geometryManager)
///     document.isDirty = false
/// }
/// ```
@MainActor
public final class CADRendererBridge {
    public lazy var vertexEditor = CADVertexEditor(bridge: self)
    private let directPrimitiveMover = CADDirectPrimitiveMover()

    /// Maps CAD entity handle → the primitive IDs we created, so we can update/remove them.
    internal var entityPrimitiveMap: [UUID: [SpriteID]] = [:]

    /// Maps CAD entity handle → the text sprite IDs we created, so we can clean them up.
    internal var entitySpriteMap: [UUID: [SpriteID]] = [:]

    /// The z-order base for CAD primitives. Incremented per entity to ensure
    /// correct draw order (back-to-front).
    private var nextZ: Double = 0
    /// Pending regeneration results, tagged with the generation they were computed for.
    /// Protected by `pendingLock` — written from the background task, read from the render
    /// loop on the main thread. The generation tag lets the render loop discard results from
    /// a superseded tab/edit instead of displaying them.
    private nonisolated(unsafe) var pendingResults: (
        generation: Int,
        renderOrigin: CADRenderOrigin,
        results: [EntityResult]
    )? = nil
    private let pendingLock = NSLock()


    public init() {}

    // MARK: - Regenerate


    /// Clear all previously generated primitives and rebuild from the document.
    /// Async: call with `await`. Handles thread-safety internally.
    /// Thread-safe: accepts a value-typed snapshot. Runs off-actor via
    /// `Task.detached` — must be `nonisolated` since the render loop blocks
    /// the main actor and `await` would never resolve.
    public nonisolated func regenerate(
        fromSnapshot snapshot: CADDocumentSnapshot,
        generation: Int,
        simplifyComplexBlocks: Bool,
        into geometryManager: GeometryManager,
        renderOrigin: CADRenderOrigin = .zero,
        splineTessellationDivisor: Double = 5000.0
    ) async {
        let results = await Self.computeSpecs(
            fromSnapshot: snapshot,
            simplifyComplexBlocks: simplifyComplexBlocks,
            renderOrigin: renderOrigin,
            splineTessellationDivisor: splineTessellationDivisor)
        print("[CADBridge] computeSpecs (gen \(generation)) returned \(results.count) entity results")
        // Best-effort early-out: if a newer tab/edit cancelled this task, don't publish.
        // The generation guards below + in applyPendingIfNeeded are the authoritative checks.
        if Task.isCancelled { return }
        pendingLock.withLock {
            // Never let an older generation overwrite results from a newer one that already
            // landed (tasks can finish out of order; the newest generation always wins).
            if let existing = pendingResults, existing.generation >= generation { return }
            pendingResults = (generation, renderOrigin, results)
        }
    }

    /// Called by the render loop (on the main thread) to apply any pending regeneration whose
    /// generation matches `wantGen`. Results from a superseded generation are discarded.
    public func applyPendingIfNeeded(
        forGeneration wantGen: Int,
        into geometryManager: GeometryManager,
        splineTessellationDivisor: Double = 5000.0,
        engine: PhrostEngine
    ) -> Bool {
        let applied = pendingLock.withLock { () -> (CADRenderOrigin, [EntityResult])? in
            guard let p = pendingResults else { return nil }
            if p.generation != wantGen {
                // Stale: drop older generations so they can't linger and be applied later.
                // (A pending generation newer than wantGen shouldn't happen — wantGen is the
                //  latest — but if it ever did, leave it for the frame that catches up to it.)
                if p.generation < wantGen { pendingResults = nil }
                return nil
            }
            pendingResults = nil
            return (p.renderOrigin, p.results)
        }
        guard let (renderOrigin, results) = applied else { return false }
        geometryManager.renderOrigin = renderOrigin
        applySpecs(results, into: geometryManager, engine: engine)
        print("[CADBridge] applySpecs (gen \(wantGen)) done, geomMgr has \(geometryManager.primitiveCount) primitives")
        return true
    }

    /// Discards any pending regeneration results. Called on tab switch to prevent
    /// stale results from a previous document being applied to the new active document.
    public func cancelPending() {
        pendingLock.withLock { pendingResults = nil }
    }

    private struct ResolvedPrimitiveStyle: Sendable {
        let color: ColorRGBA
        let lineType: String
        let lineWeight: Double
        let lineTypeScale: Double
        let geomWidth: Double
        let opacityMultiplier: Double
    }

    private nonisolated static func explicitColor(of primitive: CADPrimitive) -> ColorRGBA? {
        switch primitive {
        case .point(_, let color): return color
        case .line(_, _, let color): return color
        case .rect(_, _, let color): return color
        case .fillRect(_, _, let color): return color
        case .polygon(_, let color): return color
        case .polyline(_, let color): return color
        case .fillPolygon(_, let color): return color
        case .fillComplexPolygon(_, _, let color): return color
        case .gradient: return nil
        case .circle(_, _, let color): return color
        case .arc(_, _, _, _, let color): return color
        case .spline(_, _, _, _, let color): return color
        case .text(_, _, _, _, _, _, _, _, let color): return color
        case .ellipse(_, _, _, let color): return color
        case .hatch(_, _, _, _, let color, _): return color
        case .hatchPath(_, _, _, _, _, let color, _): return color
        case .ray(_, _, let color): return color
        case .image(_, _, _, _, _, let color): return color
        case .table(_, _, let color): return color
        }
    }

    private nonisolated static func inheritingColor(
        _ inheritedColor: ColorRGBA?,
        into primitive: CADPrimitive
    ) -> CADPrimitive {
        guard let inheritedColor, explicitColor(of: primitive) == nil else {
            return primitive
        }

        switch primitive {
        case .line(let start, let end, _):
            return .line(start: start, end: end, color: inheritedColor)
        case .fillRect(let origin, let size, _):
            return .fillRect(origin: origin, size: size, color: inheritedColor)
        case .text(
            let position, let text, let height, let rotation, let style,
            let alignH, let alignV, let mtextWidth, _
        ):
            return .text(
                position: position,
                text: text,
                height: height,
                rotation: rotation,
                style: style,
                alignH: alignH,
                alignV: alignV,
                mtextWidth: mtextWidth,
                color: inheritedColor)
        default:
            return primitive
        }
    }

    private nonisolated static func isFillPrimitive(_ primitive: CADPrimitive) -> Bool {
        switch primitive {
        case .fillRect, .fillPolygon, .fillComplexPolygon, .gradient, .hatch,
             .hatchPath, .image:
            return true
        default:
            return false
        }
    }

    private nonisolated static func resolvedPrimitiveStyle(
        primitive: CADPrimitive,
        style: CADPrimitiveStyle?,
        entityColor: ColorRGBA,
        entityLineType: String,
        entityLineWeight: Double,
        entityLineTypeScale: Double,
        entityGeomWidth: Double,
        entityLayerOpacity: Double,
        layersByName: [String: Layer]
    ) -> ResolvedPrimitiveStyle {
        let styleLayer: Layer?
        if let name = style?.layerName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty,
           name != "0" {
            styleLayer = layersByName[name.uppercased()]
        } else {
            styleLayer = nil
        }

        let color: ColorRGBA
        if let explicit = Self.explicitColor(of: primitive) ?? style?.color {
            color = explicit
        } else if style?.isColorByBlock == true {
            color = entityColor
        } else if let styleLayer {
            color = styleLayer.color
        } else {
            color = entityColor
        }

        let lineType: String
        if let style {
            let raw = style.lineType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "BYLAYER"
            switch raw.uppercased() {
            case "", "BYLAYER": lineType = styleLayer?.lineType ?? entityLineType
            case "BYBLOCK": lineType = entityLineType
            default: lineType = raw
            }
        } else {
            lineType = entityLineType
        }

        let lineWeight: Double
        if let style {
            if style.isLineWeightByBlock {
                lineWeight = entityLineWeight
            } else if let explicit = style.lineWeight, explicit >= 0 {
                lineWeight = explicit
            } else {
                lineWeight = styleLayer?.lineWeight ?? entityLineWeight
            }
        } else {
            lineWeight = entityLineWeight
        }

        let sourceLayerOpacity = styleLayer?.opacity ?? entityLayerOpacity
        let opacityMultiplier = max(0.0, min(1.0,
            sourceLayerOpacity * (style?.opacity ?? 1.0)))
        let adjustedColor = ColorRGBA(
            r: color.r,
            g: color.g,
            b: color.b,
            a: UInt8(min(255, Double(color.a) * opacityMultiplier)))

        return ResolvedPrimitiveStyle(
            color: adjustedColor,
            lineType: lineType,
            lineWeight: lineWeight,
            lineTypeScale: entityLineTypeScale * (style?.lineTypeScale ?? 1.0),
            geomWidth: style?.geomWidth ?? entityGeomWidth,
            opacityMultiplier: opacityMultiplier)
    }

    private nonisolated static func makeTextBackgroundSpec(
        text: String,
        origin: Vector3,
        height: Double,
        rotation: Double,
        alignH: Int,
        alignV: Int,
        maxWidth: Double?,
        scale: Double,
        color: ColorRGBA?,
        usesViewportColor: Bool,
        z: Double,
        renderOrigin: CADRenderOrigin
    ) -> PrimitiveSpec? {
        guard scale >= 1.0, usesViewportColor || color != nil else { return nil }
        let bounds = CADEntity.estimateTextLocalBounds(
            text: text,
            height: height,
            alignH: alignH,
            alignV: alignV,
            mtextWidth: maxWidth)
        let margin = max(0.0, (scale - 1.0) * height * 0.5)
        let localCorners = [
            (bounds.minX - margin, bounds.minY - margin),
            (bounds.maxX + margin, bounds.minY - margin),
            (bounds.maxX + margin, bounds.maxY + margin),
            (bounds.minX - margin, bounds.maxY + margin),
        ]
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let corners = localCorners.map { local -> SDL_FPoint in
            SDL_FPoint(
                x: renderOrigin.localX(origin.x + local.0 * cosR - local.1 * sinR),
                y: renderOrigin.localY(origin.y + local.0 * sinR + local.1 * cosR))
        }
        let rgba = color.map { ($0.r, $0.g, $0.b, $0.a) } ?? (0, 0, 0, 255)
        return PrimitiveSpec(
            type: .fillRect,
            points: [],
            rects: [],
            corners: corners,
            z: z,
            color: rgba,
            usesViewportBackground: usesViewportColor)
    }

    /// Pure computation from a value-typed snapshot. Safe for any thread —
    /// the snapshot is an independent copy of all document state.
    nonisolated static func computeSpecs(
        fromSnapshot snapshot: CADDocumentSnapshot,
        simplifyComplexBlocks: Bool,
        renderOrigin: CADRenderOrigin = .zero,
        splineTessellationDivisor: Double = 5000.0
    ) async -> [EntityResult] {
        var visible:
            [(
                index: Int, handle: UUID,
                geometry: [CADPrimitive], primitiveStyles: [Int: CADPrimitiveStyle],
                primitiveXData: [Int: [String: XDataValue]],
                transform: Transform3D, color: ColorRGBA,
                lineType: String,
                lineWeight: Double,
                lineTypeScale: Double,
                geomWidth: Double,
                layerOpacity: Double,
                textBackgroundScale: Double?,
                textBackgroundColor: ColorRGBA?,
                textBackgroundUsesViewportColor: Bool
            )] = []
        var visibleText: [(index: Int, handle: UUID, text: String, height: Double,
                            heightOverride: Bool, textStyle: String?,
                            alignH: Int, alignV: Int, widthFactor: Double,
                            widthFactorOverride: Bool, oblique: Double,
                            obliqueOverride: Bool,
                            mtextWidth: Double?, mtextLineSpacing: Double,
                            mtextLineSpacingStyle: Int,
                            transform: Transform3D, color: ColorRGBA,
                            formattedText: FormattedText?, textBackgroundScale: Double?,
                            textBackgroundColor: ColorRGBA?, textBackgroundUsesViewportColor: Bool)] = []
        var index = 0
        let layersByName = Dictionary(
            snapshot.layers.values.map { ($0.name.uppercased(), $0) },
            uniquingKeysWith: { first, _ in first })

        let sortedEntities = snapshot.entities.values.sorted { e1, e2 in
            let o1 = e1.drawOrder
            let o2 = e2.drawOrder
            
            if o1 != o2 {
                return o1 < o2
            }
            return e1.handle.uuidString < e2.handle.uuidString
        }

        for entity in sortedEntities {
            guard let layer = snapshot.layers[entity.layerID], layer.isVisible else {
                continue
            }
            
            let entityColor: ColorRGBA
            if let cv = entity.xdata["dxf.color"], case .string(let hex) = cv, let c = ColorRGBA(hex: hex) {
                entityColor = c
            } else {
                entityColor = layer.color
            }
            let entityOpacity: Double
            if let value = entity.xdata["dxf.opacity"], case .double(let opacity) = value {
                entityOpacity = max(0.0, min(1.0, opacity))
            } else {
                entityOpacity = 1.0
            }
            let combinedLayerOpacity = layer.opacity * entityOpacity
            let effectiveColor = ColorRGBA(
                r: entityColor.r,
                g: entityColor.g,
                b: entityColor.b,
                a: UInt8(min(255, Double(entityColor.a) * combinedLayerOpacity)))

            let entityTextBackgroundScale: Double?
            if let value = entity.xdata["dxf.mtextBackgroundScale"],
               case .double(let scale) = value {
                entityTextBackgroundScale = scale
            } else {
                entityTextBackgroundScale = nil
            }
            let entityTextBackgroundUsesViewportColor: Bool
            if let value = entity.xdata["dxf.mtextBackgroundUsesViewportColor"],
               case .int(let flag) = value {
                entityTextBackgroundUsesViewportColor = flag != 0
            } else {
                entityTextBackgroundUsesViewportColor = false
            }
            let entityTextBackgroundColor: ColorRGBA?
            if let value = entity.xdata["dxf.mtextBackgroundColor"],
               case .string(let hex) = value,
               var background = ColorRGBA(hex: hex) {
                if let opacityValue = entity.xdata["dxf.mtextBackgroundOpacity"],
                   case .double(let opacity) = opacityValue {
                    background = ColorRGBA(
                        r: background.r,
                        g: background.g,
                        b: background.b,
                        a: UInt8(min(255.0, Double(background.a) * max(0.0, min(1.0, opacity)))))
                }
                entityTextBackgroundColor = background
            } else {
                entityTextBackgroundColor = nil
            }

            // Text entities
            if let tv = entity.xdata["dxf.text"], case .string(let text) = tv, !text.isEmpty {
                let h: Double
                if let th = entity.xdata["dxf.textHeight"], case .double(let v) = th { h = v }
                else { h = 2.5 }

                let heightOverride: Bool
                if let value = entity.xdata["dxf.textHeightOverride"],
                   case .int(let flag) = value {
                    heightOverride = flag != 0
                } else {
                    heightOverride = entity.xdata["dxf.textEntityType"] != nil
                }

                let style: String?
                if let ts = entity.xdata["dxf.textStyle"], case .string(let s) = ts { style = s }
                else { style = nil }

                let alignH: Int
                if let ah = entity.xdata["dxf.alignH"], case .int(let v) = ah { alignH = v }
                else { alignH = 0 }

                let alignV: Int
                if let av = entity.xdata["dxf.alignV"], case .int(let v) = av { alignV = v }
                else { alignV = 0 }

                let isMTextEntity: Bool
                if let entityType = entity.xdata["dxf.textEntityType"],
                   case .string(let value) = entityType {
                    isMTextEntity = value.uppercased() == "MTEXT"
                } else {
                    isMTextEntity = false
                }

                let widthFactor: Double
                if !isMTextEntity,
                   let width = entity.xdata["dxf.textWidthScale"],
                   case .double(let value) = width,
                   value > 0 {
                    widthFactor = value
                } else {
                    widthFactor = 1.0
                }

                let widthFactorOverride: Bool
                if !isMTextEntity,
                   let value = entity.xdata["dxf.textWidthScaleOverride"],
                   case .int(let flag) = value {
                    widthFactorOverride = flag != 0
                } else {
                    widthFactorOverride = !isMTextEntity && abs(widthFactor - 1.0) > 1e-12
                }

                let oblique: Double
                if let value = entity.xdata["dxf.textOblique"], case .double(let angle) = value {
                    oblique = angle
                } else {
                    oblique = 0
                }

                let obliqueOverride: Bool
                if !isMTextEntity,
                   let value = entity.xdata["dxf.textObliqueOverride"],
                   case .int(let flag) = value {
                    obliqueOverride = flag != 0
                } else {
                    obliqueOverride = !isMTextEntity && abs(oblique) > 1e-12
                }

                let mtextWidth: Double?
                if let mw = entity.xdata["dxf.mtextWidth"], case .double(let v) = mw { mtextWidth = v }
                else { mtextWidth = nil }

                let mtextLineSpacing: Double
                if let spacing = entity.xdata["dxf.mtextLineSpacing"],
                   case .double(let value) = spacing,
                   value > 0 {
                    mtextLineSpacing = value
                } else {
                    mtextLineSpacing = 1.0
                }

                let mtextLineSpacingStyle: Int
                if let style = entity.xdata["dxf.mtextLineSpacingStyle"],
                   case .int(let value) = style,
                   value == 2 {
                    mtextLineSpacingStyle = 2
                } else {
                    mtextLineSpacingStyle = 1
                }

                // Decode formatted text if present
                let ft: FormattedText?
                if let ftJSON = entity.xdata["dxf.formattedText"], case .string(let jsonStr) = ftJSON,
                   let jsonData = jsonStr.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(FormattedText.self, from: jsonData) {
                    ft = decoded
                } else {
                    ft = nil
                }

                // Use plain text from formatted text if available, otherwise use dxf.text
                let displayText = ft?.toPlainText() ?? text

                visibleText.append((
                    index, entity.handle, displayText, h, heightOverride, style,
                    alignH, alignV, widthFactor, widthFactorOverride,
                    oblique, obliqueOverride, mtextWidth, mtextLineSpacing,
                    mtextLineSpacingStyle, entity.transform, effectiveColor, ft,
                    entityTextBackgroundScale, entityTextBackgroundColor,
                    entityTextBackgroundUsesViewportColor))
                index += 1
                continue
            }

            // Resolve geometry from block or local
            let resolved: [CADPrimitive]?
            var primitiveStyles: [Int: CADPrimitiveStyle]
            var primitiveXData: [Int: [String: XDataValue]]
            if let bid = entity.blockID, let block = snapshot.blocks[bid] {
                // ACAD_TABLE entities are imported as references to their anonymous
                // *T display blocks. Render those references so table cell text and
                // borders survive DXF/EAB/DXF round-trips.
                resolved = block.geometry
                primitiveStyles = block.primitiveStyles
                primitiveXData = block.primitiveXData
            } else {
                resolved = entity.localGeometry
                primitiveStyles = [:]
                primitiveXData = [:]
            }
            guard var geometry = resolved else { continue }
            
            if simplifyComplexBlocks && geometry.count > 50 {
                if let localBox = entity.localBoundingBox {
                    geometry = [.rect(origin: localBox.min, size: localBox.size, color: nil)]
                    primitiveStyles = [:]
                    primitiveXData = [:]
                }
            }
            
            let lineType: String
            if let ltv = entity.xdata["dxf.lineType"], case .string(let s) = ltv, s != "BYLAYER" {
                lineType = s
            } else {
                lineType = layer.lineType
            }

            let lineWeight: Double
            if let lwv = entity.xdata["dxf.lineWeight"], case .double(let d) = lwv, d >= 0 {
                lineWeight = d
            } else {
                lineWeight = layer.lineWeight
            }

            let lineTypeScale: Double
            if let ltsv = entity.xdata["dxf.lineTypeScale"], case .double(let d) = ltsv {
                lineTypeScale = d
            } else {
                lineTypeScale = 1.0
            }

            let geomWidth: Double
            if let gwv = entity.xdata["dxf.polylineWidth"], case .double(let d) = gwv {
                geomWidth = d
            } else {
                geomWidth = 0.0
            }

            visible.append((index, entity.handle, geometry, primitiveStyles,
                            primitiveXData, entity.transform, entityColor, lineType, lineWeight,
                            lineTypeScale, geomWidth, combinedLayerOpacity,
                            entityTextBackgroundScale, entityTextBackgroundColor,
                            entityTextBackgroundUsesViewportColor))
            index += 1
        }

        let zBand: Double = 100.0
        let numProcessors = ProcessInfo.processInfo.activeProcessorCount
        let numChunks = max(1, min(visible.count + visibleText.count, numProcessors * 2))

        var totalSpecs = 0
        var totalSprites = 0
        var maxSpecs = 0
        var maxSpecHandle: UUID? = nil

        return await withTaskGroup(of: [EntityResult].self) { group in
            // Chunk visible entities
            if !visible.isEmpty {
                let visibleChunks = max(1, numChunks * visible.count / (visible.count + visibleText.count))
                let chunkSize = (visible.count + visibleChunks - 1) / visibleChunks
                for chunkIdx in 0..<visibleChunks {
                    let start = chunkIdx * chunkSize
                    let end = min(start + chunkSize, visible.count)
                    guard start < end else { continue }
                    let chunk = Array(visible[start..<end])
                    
                    group.addTask {
                        var chunkResults: [EntityResult] = []
                        for v in chunk {
                            let baseZ = Double(v.index) * zBand
                            var specs: [PrimitiveSpec] = []
                            var currentZ = baseZ
                            
                            // Expand tables before ordering so their generated text passes through
                            // the same SHX/TTF rendering path as ordinary text primitives.
                            // CADPrimitiveGenerator can only emit geometry specs, so leaving a table
                            // nested there drops TTF-backed cell text.
                            let indexedGeometry: [(index: Int, primitive: CADPrimitive)] =
                                v.geometry.enumerated().flatMap { item in
                                    if case .table(let data, let origin, let tableColor) = item.element {
                                        return DataTableTessellator.generateVisualPrimitives(
                                            data: data,
                                            origin: origin
                                        ).map { visual in
                                            (
                                                index: item.offset,
                                                primitive: Self.inheritingColor(
                                                    tableColor,
                                                    into: visual)
                                            )
                                        }
                                    }
                                    return [(index: item.offset, primitive: item.element)]
                                }

                            let orderedGeometry: [(index: Int, primitive: CADPrimitive)]
                            if indexedGeometry.count <= 1 {
                                orderedGeometry = indexedGeometry
                            } else {
                                let fills = indexedGeometry.filter { Self.isFillPrimitive($0.primitive) }
                                let nonFills = indexedGeometry.filter { !Self.isFillPrimitive($0.primitive) }
                                orderedGeometry = fills + nonFills
                            }

                            var textSprites: [TextSpriteSpec] = []

                            for item in orderedGeometry {
                                let primitive = item.primitive
                                let primitiveStyle = v.primitiveStyles[item.index]
                                let primitiveXData = v.primitiveXData[item.index] ?? [:]
                                let drawStyle = Self.resolvedPrimitiveStyle(
                                    primitive: primitive,
                                    style: primitiveStyle,
                                    entityColor: v.color,
                                    entityLineType: v.lineType,
                                    entityLineWeight: v.lineWeight,
                                    entityLineTypeScale: v.lineTypeScale,
                                    entityGeomWidth: v.geomWidth,
                                    entityLayerOpacity: v.layerOpacity,
                                    layersByName: layersByName)
                                let primZ = Self.isFillPrimitive(primitive)
                                    ? currentZ
                                    : currentZ + 1000000.0
                                var primitiveForRender = primitive
                                var primitiveTextWidthFactor = 1.0
                                var primitiveTextObliqueAngle = 0.0

                                if case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, _) = primitive {
                                    let textStyle = CADTextStyle.resolve(style, in: snapshot.textStyles)
                                    let fontFile = textStyle.fontFile
                                    let resolvedColor = drawStyle.color
                                    let spriteColor = (resolvedColor.r, resolvedColor.g, resolvedColor.b, resolvedColor.a)

                                    if resolvedColor.a == 0 {
                                        currentZ += 0.01
                                        continue
                                    }

                                    let origin = v.transform.transformPoint(pos)
                                    let localX = Vector3(x: cos(rotation), y: sin(rotation), z: 0)
                                    let localY = Vector3(x: -sin(rotation), y: cos(rotation), z: 0)
                                    let worldX = v.transform.transformPoint(pos + localX) - origin
                                    let worldY = v.transform.transformPoint(pos + localY) - origin
                                    let finalRotation = atan2(worldX.y, worldX.x)
                                    let heightScale = max(worldY.magnitude, 1e-12)
                                    let widthScale = max(worldX.magnitude, 1e-12)
                                    let isMTextPrimitive: Bool
                                    if let entityType = primitiveXData["dxf.textEntityType"],
                                       case .string(let value) = entityType {
                                        isMTextPrimitive = value.uppercased() == "MTEXT"
                                    } else {
                                        isMTextPrimitive = false
                                    }

                                    let heightOverride: Bool
                                    if let value = primitiveXData["dxf.textHeightOverride"],
                                       case .int(let flag) = value {
                                        heightOverride = flag != 0
                                    } else {
                                        heightOverride =
                                            primitiveXData["dxf.textEntityType"] != nil
                                    }

                                    let entityWidthFactor: Double
                                    if !isMTextPrimitive,
                                       let width = primitiveXData["dxf.textWidthScale"],
                                       case .double(let value) = width,
                                       value > 0 {
                                        entityWidthFactor = value
                                    } else {
                                        entityWidthFactor = 1.0
                                    }
                                    let widthFactorOverride: Bool
                                    if !isMTextPrimitive,
                                       let value = primitiveXData["dxf.textWidthScaleOverride"],
                                       case .int(let flag) = value {
                                        widthFactorOverride = flag != 0
                                    } else {
                                        widthFactorOverride =
                                            !isMTextPrimitive
                                            && abs(entityWidthFactor - 1.0) > 1e-12
                                    }
                                    primitiveTextWidthFactor = widthFactorOverride
                                        ? entityWidthFactor
                                        : textStyle.widthFactor

                                    let entityOblique: Double
                                    if let value = primitiveXData["dxf.textOblique"],
                                       case .double(let angle) = value {
                                        entityOblique = angle
                                    } else {
                                        entityOblique = 0
                                    }
                                    let obliqueOverride: Bool
                                    if !isMTextPrimitive,
                                       let value = primitiveXData["dxf.textObliqueOverride"],
                                       case .int(let flag) = value {
                                        obliqueOverride = flag != 0
                                    } else {
                                        obliqueOverride =
                                            !isMTextPrimitive && abs(entityOblique) > 1e-12
                                    }
                                    primitiveTextObliqueAngle = obliqueOverride
                                        ? entityOblique
                                        : textStyle.obliqueAngle

                                    let effectiveWidthFactor =
                                        primitiveTextWidthFactor * widthScale / heightScale
                                    let effectiveHeight =
                                        heightOverride || textStyle.fixedHeight <= 0
                                        ? height
                                        : textStyle.fixedHeight
                                    let worldHeight = effectiveHeight * heightScale
                                    primitiveForRender = .text(
                                        position: pos,
                                        text: text,
                                        height: effectiveHeight,
                                        rotation: rotation,
                                        style: textStyle.name,
                                        alignH: alignH,
                                        alignV: alignV,
                                        mtextWidth: mtextWidth,
                                        color: nil)
                                    let worldWidth = mtextWidth.map { $0 * widthScale }
                                    let backgroundScale = primitiveStyle?.textBackgroundScale
                                        ?? v.textBackgroundScale
                                    let backgroundColor = primitiveStyle?.textBackgroundColor
                                        ?? v.textBackgroundColor
                                    let backgroundUsesViewportColor =
                                        primitiveStyle?.textBackgroundUsesViewportColor == true
                                        || v.textBackgroundUsesViewportColor
                                    let formattedText: FormattedText?
                                    if let value = primitiveXData["dxf.formattedText"],
                                       case .string(let json) = value {
                                        formattedText = try? JSONDecoder().decode(
                                            FormattedText.self,
                                            from: Data(json.utf8))
                                    } else {
                                        formattedText = nil
                                    }

                                    let formattedTTFPath = CADFontManager.resolveFormattedTTFPath(
                                        formattedText,
                                        styleName: style,
                                        textStyleFonts: snapshot.textStyleFonts)
                                    let styleTTFPath = CADFontManager.getOrLoadSHXFont(
                                        filename: fontFile,
                                        allowFallback: false) == nil
                                        ? CADFontManager.getTTFEquivalent(filename: fontFile)
                                        : nil

                                    if let ttfPath = formattedTTFPath ?? styleTTFPath {
                                        let backgroundRGBA = backgroundColor.map {
                                            ($0.r, $0.g, $0.b, $0.a)
                                        }
                                        textSprites.append(TextSpriteSpec(
                                            text: text,
                                            fontPath: ttfPath,
                                            fontSize: 64.0,
                                            x: origin.x,
                                            y: origin.y,
                                            z: primZ,
                                            rotation: finalRotation,
                                            height: worldHeight,
                                            widthFactor: effectiveWidthFactor,
                                            obliqueAngle: primitiveTextObliqueAngle,
                                            maxWidth: worldWidth,
                                            alignH: alignH,
                                            alignV: alignV,
                                            color: spriteColor,
                                            backgroundScale: backgroundScale,
                                            backgroundColor: backgroundRGBA,
                                            backgroundUsesViewportColor: backgroundUsesViewportColor,
                                            formattedText: formattedText
                                        ))

                                        currentZ += 0.01
                                        continue
                                    }

                                    if let backgroundScale,
                                       let mask = Self.makeTextBackgroundSpec(
                                        text: text,
                                        origin: origin,
                                        height: worldHeight,
                                        rotation: finalRotation,
                                        alignH: alignH,
                                        alignV: alignV,
                                        maxWidth: worldWidth,
                                        scale: backgroundScale,
                                        color: backgroundColor,
                                        usesViewportColor: backgroundUsesViewportColor,
                                        z: primZ - 0.02,
                                        renderOrigin: renderOrigin) {
                                        specs.append(mask)
                                    }
                                }

                                let s = CADPrimitiveGenerator.computePrimitiveSpecs(
                                    from: primitiveForRender,
                                    transform: v.transform,
                                    color: (drawStyle.color.r, drawStyle.color.g,
                                            drawStyle.color.b, drawStyle.color.a),
                                    z: primZ,
                                    lineType: drawStyle.lineType,
                                    lineWeight: drawStyle.lineWeight,
                                    lineTypeScale: drawStyle.lineTypeScale,
                                    geomWidth: drawStyle.geomWidth,
                                    textWidthFactor: primitiveTextWidthFactor,
                                    textObliqueAngle: primitiveTextObliqueAngle,
                                    textStyleFonts: snapshot.textStyleFonts,
                                    linetypePatterns: snapshot.linetypePatterns,
                                    opacityMultiplier: drawStyle.opacityMultiplier,
                                    renderOrigin: renderOrigin,
                                    splineTessellationDivisor: splineTessellationDivisor)
                                if s.count > 10000 {
                                    let typeStr: String
                                    switch primitive {
                                    case .line: typeStr = "line"
                                    case .polygon(let pts, _): typeStr = "polygon(\(pts.count)pts)"
                                    case .polyline(let pts, _): typeStr = "polyline(\(pts.count)pts)"
                                    case .fillComplexPolygon(let outer, let holes, _): typeStr = "fillComplexPolygon(outer:\(outer.count),holes:\(holes.count))"
                                    case .fillPolygon(let pts, _): typeStr = "fillPolygon(\(pts.count)pts)"
                                    case .hatch, .hatchPath: typeStr = "hatch"
                                    case .spline: typeStr = "spline"
                                    case .circle: typeStr = "circle"
                                    case .arc: typeStr = "arc"
                                    case .text: typeStr = "text"
                                    case .ellipse: typeStr = "ellipse"
                                    case .point: typeStr = "point"
                                    case .gradient: typeStr = "gradient"
                                    case .ray: typeStr = "ray"
                                    case .rect: typeStr = "rect"
                                    case .fillRect: typeStr = "fillRect"
                                    case .image: typeStr = "image"
                                    case .table: typeStr = "table"
                                    }
                                    print("[CADBridge]   EXPLOSION: \(typeStr) → \(s.count) specs (lineType=\(drawStyle.lineType), lw=\(drawStyle.lineWeight), ltScale=\(drawStyle.lineTypeScale))")
                                }
                                specs.append(contentsOf: s)
                                currentZ += 0.01
                            }

                            // Collect image specs from .image primitives
                            var imageSpecs: [ImageSpec] = []
                            for (primitiveIndex, primitive) in v.geometry.enumerated() {
                                if case .image = primitive {
                                    let drawStyle = Self.resolvedPrimitiveStyle(
                                        primitive: primitive,
                                        style: v.primitiveStyles[primitiveIndex],
                                        entityColor: v.color,
                                        entityLineType: v.lineType,
                                        entityLineWeight: v.lineWeight,
                                        entityLineTypeScale: v.lineTypeScale,
                                        entityGeomWidth: v.geomWidth,
                                        entityLayerOpacity: v.layerOpacity,
                                        layersByName: layersByName)
                                    if let imgSpec = CADPrimitiveGenerator.computeImageSpec(
                                        from: primitive,
                                        transform: v.transform,
                                        z: baseZ + 500000.0,
                                        tint: drawStyle.color,
                                        renderOrigin: renderOrigin
                                    ) {
                                        imageSpecs.append(imgSpec)
                                    }
                                }
                            }

                            chunkResults.append((v.handle, specs, textSprites, imageSpecs))
                        }
                        return chunkResults
                    }
                }
            }
            
            // Chunk visibleText
            if !visibleText.isEmpty {
                let textChunks = max(1, numChunks * visibleText.count / (visible.count + visibleText.count))
                let chunkSize = (visibleText.count + textChunks - 1) / textChunks
                for chunkIdx in 0..<textChunks {
                    let start = chunkIdx * chunkSize
                    let end = min(start + chunkSize, visibleText.count)
                    guard start < end else { continue }
                    let chunk = Array(visibleText[start..<end])
                    
                    group.addTask {
                        var chunkResults: [EntityResult] = []
                        for vt in chunk {
                            let baseZ = Double(vt.index) * zBand + 1000000.0
                            let color = (vt.color.r, vt.color.g, vt.color.b, vt.color.a)
                            let textStyle = CADTextStyle.resolve(vt.textStyle, in: snapshot.textStyles)
                            let fontFile = textStyle.fontFile
                            let formattedTTFPath = CADFontManager.resolveFormattedTTFPath(
                                vt.formattedText,
                                styleName: vt.textStyle,
                                textStyleFonts: snapshot.textStyleFonts)
                            let formattedSHXFont = formattedTTFPath == nil
                                ? CADFontManager.resolveFormattedSHXFont(
                                    vt.formattedText,
                                    styleName: vt.textStyle,
                                    textStyleFonts: snapshot.textStyleFonts)
                                : nil
                            let exactStyleSHXFont = CADFontManager.getOrLoadSHXFont(
                                filename: fontFile,
                                allowFallback: false)
                            let ttfPath = formattedTTFPath
                                ?? (exactStyleSHXFont == nil
                                    ? CADFontManager.getTTFEquivalent(filename: fontFile)
                                    : nil)
                            let shapeFont = formattedSHXFont
                                ?? (formattedTTFPath == nil ? exactStyleSHXFont : nil)
                                ?? (ttfPath == nil
                                    ? CADFontManager.getOrLoadSHXFont(filename: "simplex.shx")
                                    : nil)
                            
                            var specs: [PrimitiveSpec] = []
                            var textSprites: [TextSpriteSpec] = []
                            let origin = vt.transform.position
                            let localX = Vector3(x: 1, y: 0, z: 0)
                            let localY = Vector3(x: 0, y: 1, z: 0)
                            let worldX = vt.transform.transformPoint(localX) - origin
                            let worldY = vt.transform.transformPoint(localY) - origin
                            let heightScale = max(worldY.magnitude, 1e-12)
                            let widthScale = max(worldX.magnitude, 1e-12)
                            let baseWidthFactor = vt.widthFactorOverride
                                ? vt.widthFactor
                                : textStyle.widthFactor
                            let effectiveWidthFactor =
                                baseWidthFactor * widthScale / heightScale
                            let effectiveHeight =
                                vt.heightOverride || textStyle.fixedHeight <= 0
                                ? vt.height
                                : textStyle.fixedHeight
                            let worldHeight = effectiveHeight * heightScale
                            let effectiveOblique = vt.obliqueOverride
                                ? vt.oblique
                                : textStyle.obliqueAngle
                            let worldWidth = vt.mtextWidth.map { $0 * widthScale }
                            let worldRotation = atan2(worldX.y, worldX.x)
                            
                            if let font = shapeFont {
                                if let backgroundScale = vt.textBackgroundScale,
                                   let mask = Self.makeTextBackgroundSpec(
                                    text: vt.text,
                                    origin: origin,
                                    height: worldHeight,
                                    rotation: worldRotation,
                                    alignH: vt.alignH,
                                    alignV: vt.alignV,
                                    maxWidth: worldWidth,
                                    scale: backgroundScale,
                                    color: vt.textBackgroundColor,
                                    usesViewportColor: vt.textBackgroundUsesViewportColor,
                                    z: baseZ - 0.02,
                                    renderOrigin: renderOrigin) {
                                    specs.append(mask)
                                }
                                let textPrims: [CADPrimitive]
                                if var formatted = vt.formattedText {
                                    let localHeightScale = effectiveHeight / max(vt.height, 1e-12)
                                    formatted.styleName = textStyle.name
                                    formatted.defaultFont = fontFile
                                    formatted.defaultHeight *= localHeightScale * heightScale
                                    for paragraphIndex in formatted.paragraphs.indices {
                                        for runIndex in formatted.paragraphs[paragraphIndex].runs.indices {
                                            if let runHeight = formatted.paragraphs[paragraphIndex].runs[runIndex].height {
                                                formatted.paragraphs[paragraphIndex].runs[runIndex].height = runHeight * localHeightScale * heightScale
                                            }
                                            if formatted.paragraphs[paragraphIndex].runs[runIndex].oblique == nil {
                                                formatted.paragraphs[paragraphIndex].runs[runIndex].oblique =
                                                    effectiveOblique
                                            }
                                        }
                                    }
                                    textPrims = font.renderFormattedText(
                                        formatted,
                                        origin: origin,
                                        rotation: worldRotation,
                                        alignH: vt.alignH,
                                        alignV: vt.alignV,
                                        widthFactor: effectiveWidthFactor,
                                        maxWidth: worldWidth,
                                        lineSpacingFactor: vt.mtextLineSpacing,
                                        lineSpacingStyle: vt.mtextLineSpacingStyle,
                                        textStyleFonts: snapshot.textStyleFonts)
                                } else {
                                    textPrims = font.renderText(
                                        vt.text, origin: origin,
                                        height: worldHeight, rotation: worldRotation,
                                        alignH: vt.alignH, alignV: vt.alignV,
                                        widthFactor: effectiveWidthFactor,
                                        obliqueAngle: effectiveOblique,
                                        maxWidth: worldWidth)
                                }
                                if textPrims.count > 500 {
                                    let preview = vt.text.prefix(40).replacingOccurrences(of: "\n", with: "\\n")
                                    print("[CADBridge] SHX text '\(preview)...' → \(textPrims.count) line primitives (height=\(vt.height))")
                                }
                                var z = baseZ
                                for prim in textPrims {
                                    let s = CADPrimitiveGenerator.computePrimitiveSpecs(
                                        from: prim, transform: .identity, color: color, z: z,
                                        textStyleFonts: snapshot.textStyleFonts,
                                        linetypePatterns: snapshot.linetypePatterns,
                                        renderOrigin: renderOrigin,
                                        splineTessellationDivisor: splineTessellationDivisor)
                                    specs.append(contentsOf: s)
                                    z += 0.01
                                }
                            } else if let ttfPath {
                                let spec = TextSpriteSpec(
                                    text: vt.text,
                                    fontPath: ttfPath,
                                    fontSize: 64.0,
                                    x: origin.x,
                                    y: origin.y,
                                    z: baseZ,
                                    rotation: worldRotation,
                                    height: worldHeight,
                                    widthFactor: effectiveWidthFactor,
                                    obliqueAngle: effectiveOblique,
                                    maxWidth: worldWidth,
                                    alignH: vt.alignH,
                                    alignV: vt.alignV,
                                    color: color,
                                    lineSpacingFactor: vt.mtextLineSpacing,
                                    lineSpacingStyle: vt.mtextLineSpacingStyle,
                                    backgroundScale: vt.textBackgroundScale,
                                    backgroundColor: vt.textBackgroundColor.map {
                                        ($0.r, $0.g, $0.b, $0.a)
                                    },
                                    backgroundUsesViewportColor: vt.textBackgroundUsesViewportColor,
                                    formattedText: vt.formattedText
                                )
                                textSprites.append(spec)
                            }
                            chunkResults.append((vt.handle, specs, textSprites, [ImageSpec]()))
                        }
                        return chunkResults
                    }
                }
            }
            
            var collected: [EntityResult] = []
            for await chunkResults in group {
                for result in chunkResults {
                    totalSpecs += result.specs.count
                    totalSprites += result.textSprites.count
                    if result.specs.count > maxSpecs {
                        maxSpecs = result.specs.count
                        maxSpecHandle = result.handle
                    }
                    collected.append(result)
                }
            }
            // Diagnostic: primitive counts
            let textEntityCount = visibleText.count
            let geomEntityCount = visible.count
            print("[CADBridge] computeSpecs: \(geomEntityCount) geometry entities, \(textEntityCount) text entities → \(totalSpecs) specs, \(totalSprites) textSprites")
            if maxSpecs > 1000, let handle = maxSpecHandle {
                // Find the entity to log its detail
                if let v = visible.first(where: { $0.handle == handle }) {
                    print("[CADBridge]   culprit entity: \(v.geometry.count) prims, lineType=\(v.lineType), geomWidth=\(v.geomWidth), lineWeight=\(v.lineWeight), lineTypeScale=\(v.lineTypeScale)")
                    for (i, p) in v.geometry.enumerated() where i < 10 {
                        let typeStr: String
                        switch p {
                        case .line: typeStr = "line"
                        case .polygon(let pts, _): typeStr = "polygon(\(pts.count)pts)"
                        case .polyline(let pts, _): typeStr = "polyline(\(pts.count)pts)"
                        case .fillComplexPolygon(let outer, let holes, _): typeStr = "fillComplexPolygon(outer:\(outer.count),holes:\(holes.count))"
                        case .fillPolygon(let pts, _): typeStr = "fillPolygon(\(pts.count)pts)"
                        case .hatch, .hatchPath: typeStr = "hatch"
                        case .spline: typeStr = "spline"
                        case .circle: typeStr = "circle"
                        case .arc: typeStr = "arc"
                        case .text: typeStr = "text"
                        case .ellipse: typeStr = "ellipse"
                        case .point: typeStr = "point"
                        case .gradient: typeStr = "gradient"
                        case .ray: typeStr = "ray"
                        case .rect: typeStr = "rect"
                        case .fillRect: typeStr = "fillRect"
                        case .image: typeStr = "image"
                    case .table: typeStr = "table"
                        }
                        print("[CADBridge]     prim[\(i)]: \(typeStr)")
                    }
                    if v.geometry.count > 10 {
                        print("[CADBridge]     ... and \(v.geometry.count - 10) more primitives")
                    }
                }
                print("[CADBridge]   max specs from single entity = \(maxSpecs) (handle=\(handle.uuidString.prefix(8))...)")
            }
            return collected
        }
    }




    /// Apply computed specs to geometryManager. Must run on main actor.
    private func applySpecs(
        _ results: [EntityResult],
        into geometryManager: GeometryManager,
        splineTessellationDivisor: Double = 5000.0,
        engine: PhrostEngine
    ) {
        // Clear old primitives atomically
        geometryManager.clearAll()
        for (_, oldSprites) in entitySpriteMap {
            for id in oldSprites {
                engine.spriteManager.removeSprite(id: id)
            }
        }
        entityPrimitiveMap.removeAll()
        entitySpriteMap.removeAll()
        var newEntityIndexToHandle: [UInt32: UUID] = [:]

        let viewport = engine.ui.backgroundColor
        func channel(_ value: Float) -> UInt8 {
            UInt8(max(0.0, min(255.0, value * 255.0)).rounded())
        }
        let viewportBackground = (
            channel(viewport.r), channel(viewport.g),
            channel(viewport.b), channel(viewport.a))

        // Add new primitives
        for (entityIdx, res) in results.enumerated() {
            let idx = UInt32(entityIdx + 1)  // 0 = background/no-entity
            newEntityIndexToHandle[idx] = res.handle
            var primIDs: [SpriteID] = []
            primIDs.reserveCapacity(res.specs.count)
            for spec in res.specs {
                let id = spec.addTo(
                    geometryManager,
                    viewportBackground: viewportBackground)
                // Tag the primitive with the entity index for GPU ID-buffer pass
                if let prim = geometryManager.getPrimitive(id: id) {
                    prim.entityIndex = idx
                }
                primIDs.append(id)
            }
            entityPrimitiveMap[res.handle] = primIDs

            var spriteIDs: [SpriteID] = []
            spriteIDs.reserveCapacity(res.textSprites.count)
            for ts in res.textSprites {
                let rendered = engine.textManager.addCADTextSprites(
                    text: ts.text,
                    fontPath: ts.fontPath,
                    fontSize: ts.fontSize,
                    position: Vector3(x: ts.x, y: ts.y, z: ts.z),
                    rotation: ts.rotation,
                    height: ts.height,
                    widthFactor: ts.widthFactor,
                    obliqueAngle: ts.obliqueAngle,
                    maxWidth: ts.maxWidth,
                    alignH: ts.alignH,
                    alignV: ts.alignV,
                    lineSpacingFactor: ts.lineSpacingFactor,
                    lineSpacingStyle: ts.lineSpacingStyle,
                    formattedText: ts.formattedText,
                    color: ts.color,
                    backgroundScale: ts.backgroundScale,
                    backgroundColor: ts.backgroundUsesViewportColor
                        ? viewportBackground
                        : ts.backgroundColor,
                    backgroundUsesViewportColor: ts.backgroundUsesViewportColor,
                    z: ts.z,
                    geometryManager: geometryManager,
                    spriteManager: engine.spriteManager,
                    renderer: engine.renderer,
                    gpuDevice: engine.gpuDevice
                )

                spriteIDs.append(contentsOf: rendered.spriteIDs)
                primIDs.append(contentsOf: rendered.primitiveIDs)
            }
            if !spriteIDs.isEmpty {
                entitySpriteMap[res.handle] = spriteIDs
            }

            // Handle image specs: load textures and create textured sprites
            for imgSpec in res.imageSpecs {
                guard let asset = engine.document.imageStore[imgSpec.imageName] else {
                    print("[CADBridge] Image asset '\(imgSpec.imageName)' not found in document imageStore")
                    continue
                }
                let (tex, _, _) = engine.textureManager.loadTexture(
                    from: asset.data,
                    name: imgSpec.imageName,
                    mimeType: asset.mimeType
                )
                guard let texture = tex else {
                    print("[CADBridge] Failed to load GPU texture for image '\(imgSpec.imageName)'")
                    continue
                }
                // Sprite position is bottom-left corner (renderer adds hw/hh to get center).
                // c0 = insertion point = bottom-left for unrotated images.
                let w = sqrt(pow(Double(imgSpec.c1.x - imgSpec.c0.x), 2) + pow(Double(imgSpec.c1.y - imgSpec.c0.y), 2))
                let h = sqrt(pow(Double(imgSpec.c3.x - imgSpec.c0.x), 2) + pow(Double(imgSpec.c3.y - imgSpec.c0.y), 2))
                let spriteColor = imgSpec.tint ?? (UInt8(255), UInt8(255), UInt8(255), UInt8(255))
                let spriteID = SpriteID(id1: Int64(entityIdx) + 1000000, id2: 0)
                // Use sprite system to render as textured quad
                engine.spriteManager.addSprite(
                    id1: spriteID.id1, id2: spriteID.id2,
                    position: (
                        geometryManager.renderOrigin.worldX(imgSpec.c0.x),
                        geometryManager.renderOrigin.worldY(imgSpec.c0.y),
                        imgSpec.z),
                    size: (w, h),
                    color: spriteColor,
                    texture: texture
                )
                // Suppress textured quad during camera pan (like TTF fonts);
                // bounding box is drawn by the CAD selection highlight.
                if let sprite = engine.spriteManager.getSprite(for: spriteID) {
                    sprite.useBoundsWhilePanning = true
                }
                spriteIDs.append(spriteID)
            }
            if !spriteIDs.isEmpty {
                entitySpriteMap[res.handle] = spriteIDs
            }
        }

        // Store entity index → handle mapping for GPU ID-buffer pass
        geometryManager.entityIndexToHandle = newEntityIndexToHandle
        geometryManager.handleToEntityIndex = Dictionary(uniqueKeysWithValues: newEntityIndexToHandle.map { ($1, $0) })

        // Build spatial grid for large datasets
        geometryManager.buildSpatialGridIfNeeded()
    }


    /// Remove all CAD-generated primitives from the geometry manager.
    public func clear(from geometryManager: GeometryManager, engine: PhrostEngine) {
        geometryManager.clearAll()
        for (_, oldSprites) in entitySpriteMap {
            for id in oldSprites {
                engine.spriteManager.removeSprite(id: id)
            }
        }
        entityPrimitiveMap.removeAll()
        entitySpriteMap.removeAll()
    }

    /// Directly offset world-space primitives for the given entity handles.
    /// Much faster than full regenerate — no allocation, no geometry rebuild.
    /// Used during drag operations. Screen-space cache is invalidated automatically.
    /// Caller must finalize entity transforms + regenerate on mouse-up.
    public func movePrimitivesDirect(
        handles: Set<UUID>, by delta: (Double, Double),
        in gm: GeometryManager,
        spriteManager: SpriteManager? = nil
    ) {
        directPrimitiveMover.move(
            handles: handles,
            by: delta,
            primitiveIDs: entityPrimitiveMap,
            spriteIDs: entitySpriteMap,
            geometryManager: gm,
            spriteManager: spriteManager)
    }

    /// Directly offset a single vertex of an entity's primitive by its resolved-geometry index.
    /// During drag, provides real-time visual feedback. On mouse-up, caller must update
    /// the entity's CADPrimitive and trigger regeneration.
    public func moveVertexDirect(
        handle: UUID, vertexIndex: Int, by delta: (Double, Double),
        in gm: GeometryManager, document: CADDocument,
        spriteManager: SpriteManager? = nil
    ) {
        let dx = Float(delta.0)
        let dy = Float(delta.1)
        guard let entity = document.entity(for: handle),
              let geometry = document.resolvedGeometry(for: entity)
        else { return }

        let ids = entityPrimitiveMap[handle] ?? []
        let invTransform = entity.transform.inverse()

        /// Dashed/styled lines are tessellated into multiple render primitives
        /// (one per dash segment). For start/end vertices we need the first or
        /// last render primitive, not just the one at `primIdx`.
        func firstRP() -> RenderPrimitive? {
            guard let firstID = ids.first else { return nil }
            return gm.getPrimitive(id: firstID)
        }
        func lastRP() -> RenderPrimitive? {
            guard let lastID = ids.last else { return nil }
            return gm.getPrimitive(id: lastID)
        }
        func updateFirstPointOfFirstRP() {
            guard let rp = firstRP(), rp.points.count >= 2 else { return }
            rp.points[0].x += dx
            rp.points[0].y += dy
            markPrimitiveDirty(rp, in: gm)
        }
        func updateLastPointOfLastRP() {
            guard let rp = lastRP(), rp.points.count >= 2 else { return }
            let last = rp.points.count - 1
            rp.points[last].x += dx
            rp.points[last].y += dy
            markPrimitiveDirty(rp, in: gm)
        }

        var offset = 0
        for (primIdx, prim) in geometry.enumerated() {
            let pts: [Vector3]
            if case .hatchPath(let boundary, _, _, _, _, _, _) = prim {
                pts = boundary.points.map { entity.transform.transformPoint($0) }
            } else {
                pts = CADGeometryMath.worldPointsForPrimitive(prim, transform: entity.transform)
            }
            let localIdx = vertexIndex - offset
            if localIdx >= 0 && localIdx < pts.count {
                var newGeom = geometry

                func writeLiveGeometry(_ updated: CADPrimitive) {
                    newGeom[primIdx] = updated
                    if let blockID = entity.blockID {
                        document.updateBlockGeometryLive(handle: blockID, geometry: newGeom)
                    } else {
                        document.updateEntityGeometryLive(for: handle, geometry: newGeom)
                    }
                }

                /// Returns the render primitive at `primIdx` for cases that don't
                /// do per-dash tessellation (circle, arc, spline, ellipse, hatch, ray).
                func rpForCurrentPrimitive() -> RenderPrimitive? {
                    guard primIdx < ids.count else { return nil }
                    return gm.getPrimitive(id: ids[primIdx])
                }

                switch prim {
                case .point(_, let c):
                    let wp = pts[localIdx]
                    let moved = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)
                    let local = invTransform.transformPoint(moved)
                    writeLiveGeometry(.point(position: local, color: c))
                    updateFirstPointOfFirstRP()
                    return

                case .line(let start, let end, let c):
                    var a = start
                    var b = end
                    let wp = pts[localIdx]
                    let moved = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)

                    if localIdx == 0 {
                        a = invTransform.transformPoint(moved)
                    } else {
                        b = invTransform.transformPoint(moved)
                    }

                    let needsStyledRebuild = shouldRebuildLiveStroke(for: entity, document: document)
                    writeLiveGeometry(.line(start: a, end: b, color: c))

                    if needsStyledRebuild, rebuildSinglePrimitiveEntityLive(handle: handle, in: gm, document: document) {
                        return
                    }

                    if localIdx == 0 {
                        updateFirstPointOfFirstRP()
                    } else {
                        updateLastPointOfLastRP()
                    }

                    return

                case .polygon(let points, let c):
                    guard localIdx < points.count else { return }
                    var movedPoints = points
                    let wp = pts[localIdx]
                    let moved = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)
                    let movedLocal = invTransform.transformPoint(moved)
                    let originalLocal = points[localIdx]
                    movedPoints[localIdx] = movedLocal

                    var updatedGeometry = newGeom
                    updatedGeometry[primIdx] = .polygon(points: movedPoints, color: c)

                    if isInvisibleEditBoundaryPolygon(color: c) {
                        updatedGeometry = updateVisibleHatchBoundaryFromEditBoundary(
                            geometry: updatedGeometry,
                            editPrimitiveIndex: primIdx,
                            editVertexIndex: localIdx,
                            originalLocalPoint: originalLocal,
                            movedLocalPoint: movedLocal)
                    }

                    if let blockID = entity.blockID {
                        document.updateBlockGeometryLive(handle: blockID, geometry: updatedGeometry)
                    } else {
                        document.updateEntityGeometryLive(for: handle, geometry: updatedGeometry)
                    }

                    if localIdx == 0 { updateFirstPointOfFirstRP() }
                    else if localIdx == points.count - 1 { updateLastPointOfLastRP() }
                    return

                case .polyline(let path, let c):
                    guard localIdx < path.vertices.count else { return }
                    var movedPath = path
                    let wp = pts[localIdx]
                    let moved = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)
                    movedPath.vertices[localIdx].position = invTransform.transformPoint(moved)
                    writeLiveGeometry(.polyline(path: movedPath, color: c))
                    if rebuildSinglePrimitiveEntityLive(
                        handle: handle, in: gm, document: document
                    ) {
                        return
                    }
                    if let rp = rpForCurrentPrimitive() {
                        rp.points = movedPath.tessellatedPoints().map {
                            let world = entity.transform.transformPoint($0)
                            return SDL_FPoint(
                                x: gm.renderOrigin.localX(world.x),
                                y: gm.renderOrigin.localY(world.y))
                        }
                        markPrimitiveDirty(rp, in: gm)
                    }
                    return

                case .fillPolygon(let points, let c):
                    guard localIdx < points.count else { return }
                    var movedPoints = points
                    let wp = pts[localIdx]
                    let moved = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)
                    movedPoints[localIdx] = invTransform.transformPoint(moved)
                    writeLiveGeometry(.fillPolygon(points: movedPoints, color: c))
                    if localIdx == 0 { updateFirstPointOfFirstRP() }
                    else if localIdx == points.count - 1 { updateLastPointOfLastRP() }
                    return

                case .fillComplexPolygon(let outer, let holes, let c):
                    guard localIdx < outer.count else { return }
                    var movedOuter = outer
                    let wp = pts[localIdx]
                    let moved = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)
                    movedOuter[localIdx] = invTransform.transformPoint(moved)
                    writeLiveGeometry(.fillComplexPolygon(outer: movedOuter, holes: holes, color: c))
                    if localIdx == 0 { updateFirstPointOfFirstRP() }
                    else if localIdx == outer.count - 1 { updateLastPointOfLastRP() }
                    return

                case .gradient(let outer, let holes, let gradientName, let angle, let color1, let color2):
                    guard localIdx < outer.count else { return }
                    var movedOuter = outer
                    let wp = pts[localIdx]
                    let moved = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)
                    movedOuter[localIdx] = invTransform.transformPoint(moved)
                    writeLiveGeometry(.gradient(outer: movedOuter, holes: holes, gradientName: gradientName, angle: angle, color1: color1, color2: color2))
                    if localIdx == 0 { updateFirstPointOfFirstRP() }
                    else if localIdx == outer.count - 1 { updateLastPointOfLastRP() }
                    return

                case .rect(let origin, let size, let c):
                    let worldCorners = pts
                    guard worldCorners.count >= 4 else { return }
                    var movedCorners = worldCorners
                    movedCorners[localIdx].x += Double(dx)
                    movedCorners[localIdx].y += Double(dy)
                    let localCorners = movedCorners.map { invTransform.transformPoint($0) }
                    let minX = localCorners.map { Double($0.x) }.min() ?? origin.x
                    let maxX = localCorners.map { Double($0.x) }.max() ?? origin.x + size.x
                    let minY = localCorners.map { Double($0.y) }.min() ?? origin.y
                    let maxY = localCorners.map { Double($0.y) }.max() ?? origin.y + size.y
                    writeLiveGeometry(.rect(origin: Vector3(x: minX, y: minY, z: origin.z), size: Vector3(x: maxX - minX, y: maxY - minY, z: size.z), color: c))
                    return

                case .fillRect(let origin, let size, let c):
                    let worldCorners = pts
                    guard worldCorners.count >= 4 else { return }
                    var movedCorners = worldCorners
                    movedCorners[localIdx].x += Double(dx)
                    movedCorners[localIdx].y += Double(dy)
                    let localCorners = movedCorners.map { invTransform.transformPoint($0) }
                    let minX = localCorners.map { Double($0.x) }.min() ?? origin.x
                    let maxX = localCorners.map { Double($0.x) }.max() ?? origin.x + size.x
                    let minY = localCorners.map { Double($0.y) }.min() ?? origin.y
                    let maxY = localCorners.map { Double($0.y) }.max() ?? origin.y + size.y
                    writeLiveGeometry(.fillRect(origin: Vector3(x: minX, y: minY, z: origin.z), size: Vector3(x: maxX - minX, y: maxY - minY, z: size.z), color: c))
                    return

                case .circle(_, _, let c):
                    var newWorldPts = pts
                    newWorldPts[localIdx].x += Double(dx)
                    newWorldPts[localIdx].y += Double(dy)
                    guard newWorldPts.count >= 5 else { return }
                    let newCenterLocal = invTransform.transformPoint(newWorldPts[0])
                    let r1 = hypot(newWorldPts[1].x - newWorldPts[0].x, newWorldPts[1].y - newWorldPts[0].y)
                    let r2 = hypot(newWorldPts[2].x - newWorldPts[0].x, newWorldPts[2].y - newWorldPts[0].y)
                    let r3 = hypot(newWorldPts[3].x - newWorldPts[0].x, newWorldPts[3].y - newWorldPts[0].y)
                    let r4 = hypot(newWorldPts[4].x - newWorldPts[0].x, newWorldPts[4].y - newWorldPts[0].y)
                    let newRadiusWorld = (r1 + r2 + r3 + r4) / 4.0
                    let s = entity.transform.scale
                    let scaleAvg = max(abs(s.x), abs(s.y))
                    let newRadius = scaleAvg > 1e-9 ? newRadiusWorld / scaleAvg : 1.0
                    if let rp = rpForCurrentPrimitive() {
                        CADGeometryMath.regenCirclePoints(
                            rp: rp, center: newCenterLocal, radius: newRadius,
                            transform: entity.transform, renderOrigin: gm.renderOrigin)
                        markPrimitiveDirty(rp, in: gm)
                    }
                    writeLiveGeometry(.circle(center: newCenterLocal, radius: newRadius, color: c))
                    return

                case .arc(_, let radius, let startAngle, let endAngle, let c):
                    var newWorldPts = pts
                    newWorldPts[localIdx].x += Double(dx)
                    newWorldPts[localIdx].y += Double(dy)

                    if localIdx == 0 {
                        let movedCenter = invTransform.transformPoint(newWorldPts[0])
                        if let rp = rpForCurrentPrimitive() {
                            CADGeometryMath.regenArcPoints(
                                rp: rp, center: movedCenter, radius: radius,
                                startAngle: startAngle, endAngle: endAngle,
                                transform: entity.transform, renderOrigin: gm.renderOrigin)
                            markPrimitiveDirty(rp, in: gm)
                        }
                        writeLiveGeometry(.arc(center: movedCenter, radius: radius, startAngle: startAngle, endAngle: endAngle, color: c))
                    } else if localIdx == 1 || localIdx == 2 || localIdx == 3 {
                        // Three-point constraint edit. The two grips NOT being dragged
                        // must stay pinned at their positions from the start of the drag,
                        // so they are snapshotted into an ArcEditSession on the first
                        // frame and reused on every subsequent frame. Only the dragged
                        // grip accumulates the per-frame delta.
                        //
                        // Previously start/end/mid were re-derived from the arc's current
                        // parameters every frame. Two bugs followed:
                        //   1. The mid grip is the *parametric* midpoint of the sweep, so
                        //      after each re-solve it relocates; feeding that relocated
                        //      point back in as the "fixed" mid made it drift toward the
                        //      dragged endpoint frame after frame.
                        //   2. arcAnglesIncludingMid swaps startAngle/endAngle to keep the
                        //      stored sweep CCW. After a swap, grip indices 1 and 2 refer
                        //      to the *other* physical point, so the delta was applied to
                        //      the wrong end mid-drag — the arc flipped / went negative.
                        let session = vertexEditor.arcSessionApplyingDelta(
                            handle: handle, vertexIndex: vertexIndex,
                            primitiveIndex: primIdx, gripIndex: localIdx,
                            currentStart: pts[1], currentEnd: pts[2], currentMid: pts[3],
                            dx: Double(dx), dy: Double(dy))

                        let startLocal = invTransform.transformPoint(session.startWorld)
                        let endLocal = invTransform.transformPoint(session.endWorld)
                        let midLocal = invTransform.transformPoint(session.midWorld)

                        if let solved = CADGeometryMath.circleThroughThreePoints(startLocal, midLocal, endLocal) {
                            let angles = CADGeometryMath.arcAnglesIncludingMid(center: solved.center, start: startLocal, mid: midLocal, end: endLocal)
                            if let rp = rpForCurrentPrimitive() {
                                CADGeometryMath.regenArcPoints(
                                    rp: rp, center: solved.center, radius: solved.radius,
                                    startAngle: angles.start, endAngle: angles.end,
                                    transform: entity.transform, renderOrigin: gm.renderOrigin)
                                markPrimitiveDirty(rp, in: gm)
                            }
                            writeLiveGeometry(.arc(center: solved.center, radius: solved.radius, startAngle: angles.start, endAngle: angles.end, color: c))
                        }
                        // Collinear (degenerate) configuration: keep the last valid arc
                        // on screen. The old fallback translated the whole arc by the
                        // mouse delta, which produced visible jumps while crossing the
                        // chord; doing nothing for that single frame is correct.
                    }
                    return

                case .spline(let originalCPs, let knots, let degree, let weights, let c):
                    guard localIdx < originalCPs.count else { return }
                    var newLocalCPs = originalCPs
                    let wp = pts[localIdx]
                    let newWP = Vector3(x: wp.x + Double(dx), y: wp.y + Double(dy), z: wp.z)
                    newLocalCPs[localIdx] = invTransform.transformPoint(newWP)
                    let w = weights ?? Array(repeating: 1.0, count: newLocalCPs.count)
                    let evaluated = NURBSEvaluator.evaluateByKnotSpans(degree: degree, knots: knots, controlPoints: newLocalCPs, weights: w, segmentsPerSpan: 12)
                    if let rp = rpForCurrentPrimitive() {
                        rp.points = evaluated.map {
                            let twp = entity.transform.transformPoint($0)
                            return SDL_FPoint(x: gm.renderOrigin.localX(twp.x), y: gm.renderOrigin.localY(twp.y))
                        }
                        markPrimitiveDirty(rp, in: gm)
                    }
                    writeLiveGeometry(.spline(controlPoints: newLocalCPs, knots: knots, degree: degree, weights: weights, color: c))
                    return

                case .text:
                    var t = entity.transform
                    t.position = Vector3(
                        x: t.position.x + Double(dx),
                        y: t.position.y + Double(dy),
                        z: t.position.z
                    )
                    document.updateTransformLive(for: handle, to: t)
                    
                    if let spriteIDs = entitySpriteMap[handle], let sm = spriteManager {
                        for id in spriteIDs {
                            if let sprite = sm.getSprite(for: id) {
                                sprite.position.0 += Double(dx)
                                sprite.position.1 += Double(dy)
                            }
                        }
                    }
                    if let ids = entityPrimitiveMap[handle] {
                        for id in ids {
                            if let rp = gm.getPrimitive(id: id) {
                                for i in 0..<rp.points.count {
                                    rp.points[i].x += dx
                                    rp.points[i].y += dy
                                }
                                markPrimitiveDirty(rp, in: gm)
                            }
                        }
                    }
                    return

                case .ellipse(let center, let majorAxis, let minorRatio, let c):
                    var newWorldPts = pts
                    newWorldPts[localIdx].x += Double(dx)
                    newWorldPts[localIdx].y += Double(dy)
                    guard newWorldPts.count >= 5 else { return }
                    if localIdx == 0 {
                        // Move center
                        let newCenter = invTransform.transformPoint(newWorldPts[0])
                        writeLiveGeometry(.ellipse(center: newCenter, majorAxis: majorAxis, minorRatio: minorRatio, color: c))
                        if let rp = rpForCurrentPrimitive() {
                            CADGeometryMath.regenEllipseRP(
                                rp, center: newCenter, majorAxis: majorAxis,
                                minorRatio: minorRatio, transform: entity.transform,
                                renderOrigin: gm.renderOrigin)
                            markPrimitiveDirty(rp, in: gm)
                        }
                    } else {
                        // Move quadrant point — recompute majorAxis and minorRatio
                        let wpMoved = newWorldPts[localIdx]
                        let wc = newWorldPts[0]
                        let dc = Vector3(x: wpMoved.x - wc.x, y: wpMoved.y - wc.y, z: 0)
                        let dist = dc.magnitude
                        let halfMajor = majorAxis.magnitude
                        let newMajorAxis: Vector3
                        let newMinorRatio: Double
                        if localIdx == 1 || localIdx == 2 {
                            // Major axis endpoint
                            let norm = dist > 1e-9 ? Vector3(x: dc.x / dist, y: dc.y / dist, z: 0) : Vector3(x: 1, y: 0, z: 0)
                            let sign = (localIdx == 1) ? 1.0 : -1.0
                            newMajorAxis = Vector3(x: norm.x * dist * sign, y: norm.y * dist * sign, z: 0)
                            newMinorRatio = minorRatio
                        } else {
                            // Minor axis endpoint — compute new ratio
                            newMajorAxis = majorAxis
                            newMinorRatio = dist > 1e-9 && halfMajor > 1e-9 ? dist / halfMajor : minorRatio
                        }
                        writeLiveGeometry(.ellipse(center: center, majorAxis: newMajorAxis, minorRatio: newMinorRatio, color: c))
                        if let rp = rpForCurrentPrimitive() {
                            CADGeometryMath.regenEllipseRP(
                                rp, center: center, majorAxis: newMajorAxis,
                                minorRatio: newMinorRatio, transform: entity.transform,
                                renderOrigin: gm.renderOrigin)
                            markPrimitiveDirty(rp, in: gm)
                        }
                    }
                    return

                case .hatch(let boundary, let pattern, let scale, let angle, let c, _):
                    var newWorldPts = pts
                    newWorldPts[localIdx].x += Double(dx)
                    newWorldPts[localIdx].y += Double(dy)
                    guard localIdx < boundary.count else { return }
                    var newBoundary = boundary
                    let wp = newWorldPts[localIdx]
                    let moved = Vector3(x: wp.x, y: wp.y, z: 0)
                    newBoundary[localIdx] = invTransform.transformPoint(moved)
                    writeLiveGeometry(.hatch(boundary: newBoundary, pattern: pattern, scale: scale, angle: angle, color: c, backgroundColor: nil))
                    if let rp = rpForCurrentPrimitive(), localIdx < rp.points.count {
                        rp.points[localIdx].x += dx
                        rp.points[localIdx].y += dy
                        markPrimitiveDirty(rp, in: gm)
                    }
                    return

                case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let c, let bg):
                    guard boundary.hatchEdges.isEmpty else { return }
                    var newWorldPts = pts
                    newWorldPts[localIdx].x += Double(dx)
                    newWorldPts[localIdx].y += Double(dy)
                    guard localIdx < boundary.vertices.count else { return }
                    var newBoundary = boundary
                    let wp = newWorldPts[localIdx]
                    let moved = Vector3(x: wp.x, y: wp.y, z: 0)
                    newBoundary.vertices[localIdx].position = invTransform.transformPoint(moved)
                    writeLiveGeometry(.hatchPath(boundary: newBoundary, holes: holes, pattern: pattern, scale: scale, angle: angle, color: c, backgroundColor: bg))
                    if rebuildSinglePrimitiveEntityLive(
                        handle: handle, in: gm, document: document
                    ) {
                        return
                    }
                    return

                case .ray(let start, let direction, let c):
                    var newWorldPts = pts
                    newWorldPts[localIdx].x += Double(dx)
                    newWorldPts[localIdx].y += Double(dy)
                    if localIdx == 0 {
                        let newStart = invTransform.transformPoint(newWorldPts[0])
                        writeLiveGeometry(.ray(start: newStart, direction: direction, color: c))
                        if let rp = rpForCurrentPrimitive(), 0 < rp.points.count {
                            rp.points[0].x += dx
                            rp.points[0].y += dy
                            markPrimitiveDirty(rp, in: gm)
                        }
                    } else {
                        let ws = newWorldPts[0]
                        let wp = newWorldPts[localIdx]
                        let nd = Vector3(x: wp.x - ws.x, y: wp.y - ws.y, z: 0)
                        let newDir = invTransform.transformPoint(Vector3(x: start.x + nd.x, y: start.y + nd.y, z: 0))
                        let dirVec = Vector3(x: newDir.x - start.x, y: newDir.y - start.y, z: 0)
                        writeLiveGeometry(.ray(start: start, direction: dirVec, color: c))
                        if let rp = rpForCurrentPrimitive(), localIdx < rp.points.count {
                            rp.points[localIdx].x += dx
                            rp.points[localIdx].y += dy
                            markPrimitiveDirty(rp, in: gm)
                        }
                    }
                    return
                case .image:
                    // Images cannot be vertex-edited directly
                    return
                case .table:
                    // Tables cannot be vertex-edited directly
                    return
                }
            }
            offset += pts.count
        }
    }

    private func isInvisibleEditBoundaryPolygon(color: ColorRGBA?) -> Bool {
        guard let color else { return false }
        return color.a == 0
    }

    private func updateVisibleHatchBoundaryFromEditBoundary(
        geometry: [CADPrimitive],
        editPrimitiveIndex: Int,
        editVertexIndex: Int,
        originalLocalPoint: Vector3,
        movedLocalPoint: Vector3
    ) -> [CADPrimitive] {
        guard editPrimitiveIndex >= 0 && editPrimitiveIndex < geometry.count else { return geometry }

        var editLoopIndex = 0
        if editPrimitiveIndex > 0 {
            for i in 0..<editPrimitiveIndex {
                if case .polygon(_, let color) = geometry[i], isInvisibleEditBoundaryPolygon(color: color) {
                    editLoopIndex += 1
                }
            }
        }

        guard let visibleIndex = geometry[..<editPrimitiveIndex].lastIndex(where: { prim in
            switch prim {
            case .fillPolygon, .fillComplexPolygon, .gradient, .hatch, .hatchPath:
                return true
            default:
                return false
            }
        }) else {
            return geometry
        }

        let delta = Vector3(
            x: movedLocalPoint.x - originalLocalPoint.x,
            y: movedLocalPoint.y - originalLocalPoint.y,
            z: movedLocalPoint.z - originalLocalPoint.z)

        func moveNearestPoint(in points: [Vector3]) -> [Vector3] {
            guard !points.isEmpty else { return points }
            var result = points
            let targetIndex: Int
            if editVertexIndex < points.count {
                targetIndex = editVertexIndex
            } else {
                var bestIndex = 0
                var bestDistance = Double.greatestFiniteMagnitude
                for i in points.indices {
                    let dx = points[i].x - originalLocalPoint.x
                    let dy = points[i].y - originalLocalPoint.y
                    let dz = points[i].z - originalLocalPoint.z
                    let d = dx * dx + dy * dy + dz * dz
                    if d < bestDistance {
                        bestDistance = d
                        bestIndex = i
                    }
                }
                targetIndex = bestIndex
            }
            result[targetIndex] = Vector3(
                x: result[targetIndex].x + delta.x,
                y: result[targetIndex].y + delta.y,
                z: result[targetIndex].z + delta.z)
            return result
        }

        var result = geometry
        switch geometry[visibleIndex] {
        case .fillPolygon(let points, let color):
            if editLoopIndex == 0 {
                result[visibleIndex] = .fillPolygon(points: moveNearestPoint(in: points), color: color)
            }

        case .fillComplexPolygon(let outer, let holes, let color):
            if editLoopIndex == 0 {
                result[visibleIndex] = .fillComplexPolygon(outer: moveNearestPoint(in: outer), holes: holes, color: color)
            } else {
                let holeIndex = editLoopIndex - 1
                if holeIndex >= 0 && holeIndex < holes.count {
                    var newHoles = holes
                    newHoles[holeIndex] = moveNearestPoint(in: newHoles[holeIndex])
                    result[visibleIndex] = .fillComplexPolygon(outer: outer, holes: newHoles, color: color)
                }
            }

        case .gradient(let outer, let holes, let gradientName, let angle, let color1, let color2):
            if editLoopIndex == 0 {
                result[visibleIndex] = .gradient(
                    outer: moveNearestPoint(in: outer), holes: holes,
                    gradientName: gradientName, angle: angle, color1: color1, color2: color2)
            } else {
                let holeIndex = editLoopIndex - 1
                if holeIndex >= 0 && holeIndex < holes.count {
                    var newHoles = holes
                    newHoles[holeIndex] = moveNearestPoint(in: newHoles[holeIndex])
                    result[visibleIndex] = .gradient(
                        outer: outer, holes: newHoles,
                        gradientName: gradientName, angle: angle, color1: color1, color2: color2)
                }
            }

        case .hatch(let boundary, let pattern, let scale, let angle, let color, _):
            if editLoopIndex == 0 {
                result[visibleIndex] = .hatch(boundary: moveNearestPoint(in: boundary), pattern: pattern, scale: scale, angle: angle, color: color, backgroundColor: nil)
            }

        case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let color, let bg):
            if editLoopIndex == 0, boundary.hatchEdges.isEmpty {
                var newBoundary = boundary
                let moved = moveNearestPoint(in: boundary.points)
                if moved.count == newBoundary.vertices.count {
                    for i in moved.indices { newBoundary.vertices[i].position = moved[i] }
                }
                result[visibleIndex] = .hatchPath(boundary: newBoundary, holes: holes, pattern: pattern, scale: scale, angle: angle, color: color, backgroundColor: bg)
            }

        default:
            break
        }

        return result
    }

        private struct LivePrimitiveStyle {
        let color: ColorRGBA
        let lineType: String
        let lineWeight: Double
        let lineTypeScale: Double
        let geomWidth: Double
        let layerOpacity: Double
    }

    private func livePrimitiveStyle(for entity: CADEntity, document: CADDocument) -> LivePrimitiveStyle? {
        guard let layer = document.layer(for: entity.layerID) else { return nil }

        let entityColor: ColorRGBA
        if let cv = entity.xdata["dxf.color"], case .string(let hex) = cv, let c = ColorRGBA(hex: hex) {
            entityColor = c
        } else {
            entityColor = layer.color
        }

        let effectiveColor: ColorRGBA
        if layer.opacity < 1.0 {
            effectiveColor = ColorRGBA(
                r: entityColor.r,
                g: entityColor.g,
                b: entityColor.b,
                a: UInt8(min(255, Double(entityColor.a) * layer.opacity))
            )
        } else {
            effectiveColor = entityColor
        }

        let lineType: String
        if let ltv = entity.xdata["dxf.lineType"], case .string(let s) = ltv, s != "BYLAYER" {
            lineType = s
        } else {
            lineType = layer.lineType
        }

        let lineWeight: Double
        if let lwv = entity.xdata["dxf.lineWeight"], case .double(let d) = lwv, d >= 0 {
            lineWeight = d
        } else {
            lineWeight = layer.lineWeight
        }

        let lineTypeScale: Double
        if let ltsv = entity.xdata["dxf.lineTypeScale"], case .double(let d) = ltsv {
            lineTypeScale = d
        } else {
            lineTypeScale = 1.0
        }

        let geomWidth: Double
        if let gwv = entity.xdata["dxf.polylineWidth"], case .double(let d) = gwv {
            geomWidth = d
        } else {
            geomWidth = 0.0
        }

        return LivePrimitiveStyle(
            color: effectiveColor,
            lineType: lineType,
            lineWeight: lineWeight,
            lineTypeScale: lineTypeScale,
            geomWidth: geomWidth,
            layerOpacity: layer.opacity
        )
    }

    private func shouldRebuildLiveStroke(for entity: CADEntity, document: CADDocument) -> Bool {
        guard let style = livePrimitiveStyle(for: entity, document: document) else { return false }
        return CADPrimitiveGenerator.dashPattern(
            for: style.lineType,
            linetypePatterns: document.linetypePatterns
        ) != nil
    }

    @discardableResult
    private func rebuildSinglePrimitiveEntityLive(
        handle: UUID,
        in gm: GeometryManager,
        document: CADDocument
    ) -> Bool {
        guard let entity = document.entity(for: handle),
              let geometry = document.resolvedGeometry(for: entity),
              geometry.count == 1,
              let style = livePrimitiveStyle(for: entity, document: document),
              let oldIDs = entityPrimitiveMap[handle],
              !oldIDs.isEmpty
        else {
            return false
        }

        let oldPrimitives = oldIDs.compactMap { gm.getPrimitive(id: $0) }
        let mappedEntityIndex: UInt32?
        if let stored = gm.handleToEntityIndex[handle] {
            mappedEntityIndex = stored
        } else {
            mappedEntityIndex = nil
        }

        let primitiveEntityIndex: UInt32? = oldPrimitives
            .first(where: { $0.entityIndex != 0 })?
            .entityIndex

        let entityIndex: UInt32 = mappedEntityIndex ?? primitiveEntityIndex ?? 0

        let oldZ = oldPrimitives.first?.z ?? 0.0

        for id in oldIDs {
            gm.removePrimitive(id: id)
        }

        let primitive = geometry[0]
        let specs = CADPrimitiveGenerator.computePrimitiveSpecs(
            from: primitive,
            transform: entity.transform,
            color: (style.color.r, style.color.g, style.color.b, style.color.a),
            z: oldZ,
            lineType: style.lineType,
            lineWeight: style.lineWeight,
            lineTypeScale: style.lineTypeScale,
            geomWidth: style.geomWidth,
            linetypePatterns: document.linetypePatterns,
            opacityMultiplier: style.layerOpacity,
            renderOrigin: gm.renderOrigin,
            splineTessellationDivisor: 5000.0
        )

        var newIDs: [SpriteID] = []
        newIDs.reserveCapacity(specs.count)

        for spec in specs {
            let id = spec.addTo(gm)
            if let rp = gm.getPrimitive(id: id) {
                rp.entityIndex = entityIndex
            }
            newIDs.append(id)
        }

        entityPrimitiveMap[handle] = newIDs
        return true
    }

    private func markPrimitiveDirty(_ rp: RenderPrimitive, in gm: GeometryManager) {
        rp.computeWorldBounds(renderOrigin: gm.renderOrigin)
        rp.cameraGenerationPoints = -1
        rp.cameraGenerationRects = -1
        rp.cameraGenerationCorners = -1
    }


}
