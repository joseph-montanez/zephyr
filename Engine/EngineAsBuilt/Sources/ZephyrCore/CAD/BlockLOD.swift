import Foundation
import SwiftSDL

// =========================================================================
// MARK: - BlockLOD
//
// Zoom-gated block level-of-detail + batch-friendly manual simplify boxes.
//
// Manual `SIMPLIFY` collapses complex blocks to bounding boxes. The legacy
// shape (`.rect` outline) tessellates on the `.line` pipeline while
// surrounding weighted geometry tessellates on `.triangle`, splitting draw
// batches. Both shapes below are `.fillRect`, so they merge with the
// dominant triangle runs in `CADVertexBufferBuilder.tessellate`.
//
// Two shapes, one pipeline:
//   - `.hollowOutline`: manual SIMPLIFY (zoom-independent). Four thin
//     `.fillRect` strips (24 verts) so a zoomed-in box never renders as an
//     opaque wall over grid lines and overlapping geometry.
//   - `.solidBox`: zoom-gated auto-collapse. One `.fillRect` (6 verts) for
//     inserts smaller than `collapseThresholdPx` — visually identical to a
//     thick outline at that size.
// =========================================================================

/// Which collapsed-box shape to emit for an entity, if any.
public enum BlockLODKind: Sendable, Hashable {
    /// Manual SIMPLIFY: hollow outline built from 4 thin triangle quads.
    case hollowOutline
    /// Auto-LOD: solid triangle quad for sub-pixel inserts.
    case solidBox
}

/// Zoom context for the auto-collapse decision.
///
/// - Regen path: `pixelsPerUnit` is the curve band's `designZoom` (stable
///   within a band, so the collapse set cannot thrash mid-band).
/// - Interaction path (hit-test/hover): live `pixelsPerUnit`.
public struct BlockLODContext: Sendable, Hashable {
    public var pixelsPerUnit: Double
    public var collapseThresholdPx: Double
    public var autoEnabled: Bool

    /// Curve-band this context was built for (regen path only; the
    /// collapse decision uses `pixelsPerUnit`, the band gates regen).
    public var band: Int?

    public init(
        pixelsPerUnit: Double,
        collapseThresholdPx: Double = BlockLOD.collapseThresholdPx,
        autoEnabled: Bool = true,
        band: Int? = nil
    ) {
        self.pixelsPerUnit = pixelsPerUnit
        self.collapseThresholdPx = collapseThresholdPx
        self.autoEnabled = autoEnabled
        self.band = band
    }

    /// Collapse decision for one entity. Manual SIMPLIFY wins when zoomed in;
    /// auto-collapse applies only below the pixel threshold.
    public func kind(
        worldDiagonal: Double?,
        geometryCount: Int,
        isXref: Bool,
        manualSimplify: Bool
    ) -> BlockLODKind? {
        BlockLOD.collapseKind(
            worldDiagonal: worldDiagonal,
            geometryCount: geometryCount,
            isXref: isXref,
            manualSimplify: manualSimplify,
            context: self)
    }

    /// Hit-test/hover shortcut predicate: true when the rendered form is a
    /// collapsed box, so per-primitive testing is wasted work.
    public func usesBoundingBoxShortcut(
        geometryCount: Int,
        isXref: Bool,
        manualSimplify: Bool,
        worldDiagonal: Double?
    ) -> Bool {
        kind(
            worldDiagonal: worldDiagonal,
            geometryCount: geometryCount,
            isXref: isXref,
            manualSimplify: manualSimplify) != nil
    }
}

public enum BlockLOD: Sendable {
    /// Screen-space diagonal below which an insert auto-collapses.
    public static let collapseThresholdPx = 6.0
    /// Blocks at or below this size never collapse: a box saves nothing.
    public static let minCollapsiblePrimitives = 2
    /// Manual SIMPLIFY trigger, unchanged from the legacy behavior.
    public static let manualSimplifyThreshold = 50
    /// Collapsed boxes always cover at least this many pixels, so
    /// sub-pixel boxes cannot twinkle across pixel centers while panning.
    public static let minBoxPixels = 1.0

    /// Shared collapse decision used by regen and hit-testing.
    public static func collapseKind(
        worldDiagonal: Double?,
        geometryCount: Int,
        isXref: Bool,
        manualSimplify: Bool,
        context: BlockLODContext?
    ) -> BlockLODKind? {
        guard !isXref, geometryCount > minCollapsiblePrimitives else { return nil }
        if manualSimplify && geometryCount > manualSimplifyThreshold {
            return .hollowOutline
        }
        guard let context, context.autoEnabled else { return nil }
        guard let diag = worldDiagonal, diag.isFinite, diag > 0 else { return nil }
        let ppu = context.pixelsPerUnit
        guard ppu.isFinite, ppu > 0 else { return nil }
        return diag * ppu < context.collapseThresholdPx ? .solidBox : nil
    }

    /// Sticky 2x zoom band for the auto-collapse key. Mirrors the curve-LOD
    /// hysteresis (`bandHysteresis`): promotion is immediate, demotion waits,
    /// so hovering near a band edge cannot flap full regens.
    public static func stickyBand(pixelsPerUnit: Double, current: Int?) -> Int {
        if let current {
            return CurveScreenTessellation.zoomBand(
                for: pixelsPerUnit, currentBand: current)
        }
        return CurveScreenTessellation.zoomBand(for: pixelsPerUnit)
    }

    /// Per-regen content census: what the drawing is made of. Drives the
    /// zoom-band regen gate (only regen-dependent content — collapsed
    /// blocks and culled text — can flip a band decision) and the
    /// `PerfStats` breakdown.
    public struct ContentCensus: Sendable, Hashable {
        public var blockInserts: Int = 0
        public var textEntities: Int = 0
        public var hatchEntities: Int = 0
        public var dashedEntities: Int = 0
        public init(
            blockInserts: Int = 0,
            textEntities: Int = 0,
            hatchEntities: Int = 0,
            dashedEntities: Int = 0
        ) {
            self.blockInserts = blockInserts
            self.textEntities = textEntities
            self.hatchEntities = hatchEntities
            self.dashedEntities = dashedEntities
        }
    }

    /// Running-anchor decimation for polylines in screen space. Keeps the
    /// first and last vertices always; keeps an interior vertex only when
    /// it is at least `radiusPx` (default 0.5px) from the last kept vertex.
    /// Open inputs always keep their endpoints (a sub-pixel dash still
    /// draws its dot, so dashed lines can never vanish). Closed inputs
    /// (`first == last`, which `tessellatedPoints()` guarantees for closed
    /// paths) collapse to nothing when fewer than 3 distinct vertices
    /// survive — this also swallows the zero-length closing segment that
    /// would otherwise feed degenerate quads.
    public static func decimatedPolyline(
        _ points: [SDL_FPoint],
        pixelsPerUnit: Double,
        radiusPx: Double = 0.5
    ) -> [SDL_FPoint] {
        guard points.count >= 3 else { return points }
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0,
              radiusPx.isFinite, radiusPx > 0 else { return points }
        let r = radiusPx / pixelsPerUnit
        let r2 = r * r
        let first = points[0]
        let last = points[points.count - 1]
        let closed = first.x == last.x && first.y == last.y
        var kept: [SDL_FPoint] = [first]
        kept.reserveCapacity(points.count)
        for i in 1..<(points.count - 1) {
            let dx = Double(points[i].x - kept[kept.count - 1].x)
            let dy = Double(points[i].y - kept[kept.count - 1].y)
            if dx * dx + dy * dy >= r2 {
                kept.append(points[i])
            }
        }
        kept.append(last)
        guard closed else { return kept }
        // Merge a near-zero closing segment into its endpoint so the quad
        // path never sees a degenerate normal.
        let eps = (0.1 / pixelsPerUnit) * (0.1 / pixelsPerUnit)
        if kept.count >= 3 {
            let a = kept[kept.count - 2]
            let dx = Double(a.x - last.x)
            let dy = Double(a.y - last.y)
            if dx * dx + dy * dy < eps {
                kept[kept.count - 2] = last
                kept.removeLast()
            }
        }
        // `first` is duplicated at the end: fewer than 4 entries means
        // fewer than 3 distinct vertices. Drop only when the whole loop
        // is sub-pixel — a larger collapsed needle still draws (and has
        // no zero-length segment after the merge above).
        if kept.count < 4 {
            var mnx = kept[0].x, mxx = kept[0].x
            var mny = kept[0].y, mxy = kept[0].y
            for p in kept {
                if p.x < mnx { mnx = p.x }
                if p.x > mxx { mxx = p.x }
                if p.y < mny { mny = p.y }
                if p.y > mxy { mxy = p.y }
            }
            let diag = hypot(Double(mxx - mnx), Double(mxy - mny))
            if diag * pixelsPerUnit < 1.0 { return [] }
        }
        return kept
    }

    /// Alpha fade for TTF sprites by on-screen size: fully transparent at
    /// or below `minPx`, fully opaque at or above `maxPx`. Render-time use
    /// only — no regen state, so no popping hysteresis is needed.
    public static func spriteFadeAlpha(
        sizePx: Double, minPx: Double = 3.0, maxPx: Double = 5.0
    ) -> Double {
        guard sizePx.isFinite else { return 1.0 }
        if sizePx <= minPx { return 0.0 }
        if sizePx >= maxPx { return 1.0 }
        return (sizePx - minPx) / max(maxPx - minPx, 1e-9)
    }

    /// Live pixels-per-unit from camera zoom and display scale.
    public static func livePixelsPerUnit(zoom: Double, scaleX: Double, scaleY: Double) -> Double {
        zoom * max(1.0, max(scaleX, scaleY))
    }

    /// Interaction-time context (hover/hit-test/highlight) from live camera
    /// state. Uses live pixels-per-unit, not the band design zoom.
    public static func liveContext(
        zoom: Double, scaleX: Double, scaleY: Double, autoEnabled: Bool
    ) -> BlockLODContext {
        BlockLODContext(
            pixelsPerUnit: livePixelsPerUnit(zoom: zoom, scaleX: scaleX, scaleY: scaleY),
            autoEnabled: autoEnabled)
    }

    /// Bounding box over visible primitives only. Hidden/off-layer
    /// construction geometry (clearance circles, DEFPOINTS frames) must not
    /// inflate the collapsed box. Returns nil when nothing is visible.
    public static func visibleBoundingBox(
        geometry: [CADPrimitive],
        styles: [Int: CADPrimitiveStyle],
        layersByName: [String: Layer]
    ) -> BoundingBox3D? {
        var box: BoundingBox3D?
        for (index, prim) in geometry.enumerated() {
            guard CADPrimitiveVisibility.isVisible(
                style: styles[index], layersByName: layersByName) else { continue }
            let primBox = CADBlock.computeBoundingBox(from: [prim])
            box = box?.union(with: primBox) ?? primBox
        }
        return box
    }

    /// Representative color for the collapsed box. Layer-`0` INSERT entities
    /// usually resolve to the foreground color while the geometry inside the
    /// block lives on semantic layers — using the INSERT color would turn
    /// the zoomed-out drawing monochrome. Prefer the first decisive
    /// internal color; fall back to the entity color only when nothing
    /// inside overrides it (faithful to what the renderer would draw).
    public static func representativeColor(
        geometry: [CADPrimitive],
        styles: [Int: CADPrimitiveStyle],
        layersByName: [String: Layer],
        entityColor: ColorRGBA
    ) -> ColorRGBA {
        for (index, prim) in geometry.enumerated() {
            let style = styles[index]
            guard CADPrimitiveVisibility.isVisible(
                style: style, layersByName: layersByName) else { continue }
            if let explicit = explicitColor(of: prim) { return explicit }
            if let c = style?.color { return c }
            // ByBlock and style-less primitives resolve to the entity color
            // in the renderer: not decisive, keep looking for an internal
            // layer color that distinguishes the block.
            if style?.isColorByBlock == true { continue }
            if let name = style?.effectiveLayerUppercased,
               let layer = layersByName[name] { return layer.color }
        }
        return entityColor
    }

    /// Emit the collapsed box as `.fillRect` primitives (triangle pipeline).
    /// - `minBorderWorld`: world-space width for the hollow border (pass
    ///   `2/ppu` for a screen-constant 2px frame); `scale` converts it to
    ///   local units. Boxes too small for a frame go solid instead.
    public static func collapsedPrimitives(
        kind: BlockLODKind,
        box: BoundingBox3D,
        color: ColorRGBA?,
        minBorderWorld: Double = 0,
        scale: Vector3 = Vector3(x: 1, y: 1, z: 1)
    ) -> [CADPrimitive] {
        let w = box.size.x
        let h = box.size.y
        guard w > 0, h > 0 else {
            return [.fillRect(origin: box.min, size: Vector3(x: w, y: h, z: 0), color: color)]
        }
        switch kind {
        case .solidBox:
            return [.fillRect(origin: box.min, size: Vector3(x: w, y: h, z: 0), color: color)]
        case .hollowOutline:
            let minScale = max(min(abs(scale.x), abs(scale.y)), 1e-12)
            let maxT = 0.15 * min(w, h)
            guard maxT > 0 else {
                return [.fillRect(origin: box.min, size: Vector3(x: w, y: h, z: 0), color: color)]
            }
            // Screen-constant frame; boxes too small for a frame go solid
            // instead of shimmering sub-pixel strips.
            let minBorderLocal = (minBorderWorld.isFinite ? minBorderWorld : 0) / minScale
            let t: Double
            if minBorderLocal > 0 {
                guard minBorderLocal <= maxT else {
                    return [.fillRect(origin: box.min, size: Vector3(x: w, y: h, z: 0), color: color)]
                }
                t = minBorderLocal
            } else {
                // No zoom info (tests, export): legacy proportional frame.
                t = min(0.04 * min(w, h), maxT)
            }
            let minX = box.min.x, minY = box.min.y, maxX = box.max.x, maxY = box.max.y
            let z = box.min.z
            let innerH = h - 2 * t
            if innerH <= 0 {
                return [.fillRect(origin: box.min, size: Vector3(x: w, y: h, z: 0), color: color)]
            }
            return [
                .fillRect(origin: Vector3(x: minX, y: minY, z: z),
                           size: Vector3(x: w, y: t, z: 0), color: color),
                .fillRect(origin: Vector3(x: minX, y: maxY - t, z: z),
                           size: Vector3(x: w, y: t, z: 0), color: color),
                .fillRect(origin: Vector3(x: minX, y: minY + t, z: z),
                           size: Vector3(x: t, y: innerH, z: 0), color: color),
                .fillRect(origin: Vector3(x: maxX - t, y: minY + t, z: z),
                           size: Vector3(x: t, y: innerH, z: 0), color: color),
            ]
        }
    }

    /// Expand a local-space box so its world-space extent covers at least
    /// `minPixels` on screen. Prevents sub-pixel triangle dropout
    /// ("twinkling") while panning at extreme zoom-out.
    public static func clampedToMinPixels(
        localBox: BoundingBox3D,
        worldBox: BoundingBox3D,
        scale: Vector3,
        pixelsPerUnit: Double,
        minPixels: Double = minBoxPixels
    ) -> BoundingBox3D {
        guard pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return localBox }
        let minWorld = minPixels / pixelsPerUnit
        let sx = max(abs(scale.x), 1e-12)
        let sy = max(abs(scale.y), 1e-12)
        var minX = localBox.min.x, minY = localBox.min.y
        var maxX = localBox.max.x, maxY = localBox.max.y
        let needX = minWorld - worldBox.size.x
        if needX > 0 {
            let ex = needX / sx / 2
            minX -= ex; maxX += ex
        }
        let needY = minWorld - worldBox.size.y
        if needY > 0 {
            let ey = needY / sy / 2
            minY -= ey; maxY += ey
        }
        return BoundingBox3D(
            min: Vector3(x: minX, y: minY, z: localBox.min.z),
            max: Vector3(x: maxX, y: maxY, z: localBox.max.z))
    }

    /// Screen-space diagonal of a world box in pixels.
    public static func screenDiagonalPx(worldBox: BoundingBox3D?, pixelsPerUnit: Double) -> Double? {
        guard let worldBox, pixelsPerUnit.isFinite, pixelsPerUnit > 0 else { return nil }
        let s = worldBox.size
        return hypot(s.x, s.y) * pixelsPerUnit
    }

    private static func explicitColor(of primitive: CADPrimitive) -> ColorRGBA? {
        switch primitive {
        case .point(_, let c): return c
        case .line(_, _, let c): return c
        case .rect(_, _, let c): return c
        case .fillRect(_, _, let c): return c
        case .polygon(_, let c): return c
        case .polyline(_, let c): return c
        case .fillPolygon(_, let c): return c
        case .fillComplexPolygon(_, _, let c): return c
        case .gradient: return nil
        case .circle(_, _, let c): return c
        case .arc(_, _, _, _, let c): return c
        case .spline(_, _, _, _, let c): return c
        case .penStroke(_, _, let c): return c
        case .text(_, _, _, _, _, _, _, _, let c): return c
        case .ellipse(_, _, _, let c): return c
        case .hatch(_, _, _, _, let c, _): return c
        case .hatchPath(_, _, _, _, _, let c, _): return c
        case .ray(_, _, let c): return c
        case .xline(_, _, let c): return c
        case .image(_, _, _, _, _, let c): return c
        case .table(_, _, let c): return c
        }
    }
}

// =========================================================================
// MARK: - HatchLOD
//
// Zoom-gated dense-hatch solidification (screen viewport only).
//
// Patterned hatches whose on-screen line spacing is too small to read
// render as their boundary silhouette (outer loop minus holes) instead of
// thousands of sub-pixel lines — or instead of vanishing at the tessellate
// `<1px` skip. The decision is anchored at the curve band's `designZoom`
// (band upper edge, stable within the band), so it cannot flap mid-band.
//
// With the default `solidifyThresholdPx = 4.0` design-px, a hatch solidifies
// while its live on-screen spacing is somewhere in the ~2-4px window
// (2x band width, plus the 1.15 hysteresis dip below the lower edge). The
// cutoff stays above 2.3 design-px on purpose: the worst in-band live
// spacing (`threshold / 2.3`) never drops below the tessellate `<1px`
// skip, so there is no zoom window where a pattern both fails to solidify
// and gets culled to nothing.
//
// Print/export paths (PDF, DXF, explode, thumbnails) never consult this:
// they have no screen zoom and must keep faithful pattern lines.
// =========================================================================

public enum HatchLOD: Sendable {
    /// Design-zoom spacing below which a patterned hatch renders solid.
    /// Aggressive vs the tessellate `<1px` vanish threshold by design.
    public static let solidifyThresholdPx = 4.0

    /// True when `nominalSpacing` (authored world spacing from
    /// `DXFHatchGenerator.effectiveSpacing`, *not* the `diag/4096`-capped
    /// generation spacing) is unreadable at `designZoom`.
    /// Nil/degenerate inputs never solidify (pattern path is the safe
    /// fallback for previews and tests without a zoom context).
    public static func shouldSolidify(
        nominalSpacing: Double,
        designZoom: Double,
        thresholdPx: Double = solidifyThresholdPx
    ) -> Bool {
        guard nominalSpacing.isFinite, designZoom.isFinite,
              thresholdPx.isFinite,
              nominalSpacing > 0, designZoom > 0, thresholdPx > 0 else { return false }
        return nominalSpacing * designZoom < thresholdPx
    }
}
