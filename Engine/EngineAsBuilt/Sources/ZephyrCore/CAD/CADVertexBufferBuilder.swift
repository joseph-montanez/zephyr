import Foundation

// =========================================================================
// MARK: - CADVertexBufferBuilder
//
// Builds GPU vertex and instance-data (UV) buffers from render primitives.
// Operates lock-free: the builder produces VertexBuildResult values that
// are atomically swapped into the EngineRenderer. Supports cancellation
// via a pending-slot pattern so async builds can be safely abandoned.
import SwiftSDL

// =========================================================================
// MARK: - Tessellation Input / Output Types
// =========================================================================

/// Value-type snapshot of a RenderPrimitive's tessellation-relevant fields.
/// Safe to pass across actor boundaries — the detached build task never touches
/// the live RenderPrimitive.
public struct TessInput: Sendable {
    public let type: PrimitiveType
    public let points: [SDL_FPoint]
    public let rects: [SDL_FRect]
    public let corners: [SDL_FPoint]
    public let color: (UInt8, UInt8, UInt8, UInt8)
    public let lineWeight: Double
    public let geomWidth: Double
    public let segmentLineWeights: [Double]
    public let entityIndex: UInt32
    public let isHatchLine: Bool
    public let hatchSpacing: Double
    public let isPanProxy: Bool
    public let gradientData: RenderPrimitive.GradientData?
    /// PDMODE glyph style + raw PDSIZE for `.point` inputs. The size is
    /// resolved to world units in `tessellate` (which knows the region
    /// height): PDSIZE > 0 absolute, == 0 → 5% of region height,
    /// < 0 → -PDSIZE percent of region height.
    public let pointStyle: Int
    public let pointSize: Double

    public init(
        type: PrimitiveType,
        points: [SDL_FPoint],
        rects: [SDL_FRect],
        corners: [SDL_FPoint],
        color: (UInt8, UInt8, UInt8, UInt8),
        lineWeight: Double,
        geomWidth: Double,
        segmentLineWeights: [Double] = [],
        entityIndex: UInt32,
        isHatchLine: Bool = false,
        hatchSpacing: Double = 0.0,
        isPanProxy: Bool = false,
        gradientData: RenderPrimitive.GradientData? = nil,
        pointStyle: Int = 0,
        pointSize: Double = 0
    ) {
        self.type = type
        self.points = points
        self.rects = rects
        self.corners = corners
        self.color = color
        self.lineWeight = lineWeight
        self.geomWidth = geomWidth
        self.segmentLineWeights = segmentLineWeights
        self.entityIndex = entityIndex
        self.isHatchLine = isHatchLine
        self.hatchSpacing = hatchSpacing
        self.isPanProxy = isPanProxy
        self.gradientData = gradientData
        self.pointStyle = pointStyle
        self.pointSize = pointSize
    }

    /// Resolve a raw PDSIZE to world units against the region height.
    public static func resolvePointSize(_ pdsize: Double, regionHeight: Double) -> Double {
        let h = regionHeight.isFinite && regionHeight > 0 ? regionHeight : 1.0
        if pdsize > 0 { return pdsize }
        if pdsize < 0 { return -pdsize / 100.0 * h }
        return 0.05 * h
    }
}

/// Sendable output of the tessellation pass. Carries both the vertex data and
/// the region+zoom metadata so `applyVertexBuild` can write cache fields
/// atomically at swap time.
public struct VertexBuildResult: Sendable {
    public let vertices: [CADVertex]
    public let batches: [CADDrawBatch]
    public let vertexCount: Int

    /// The buffered region this build is valid for.
    public let regionMinX: Double
    public let regionMinY: Double
    public let regionMaxX: Double
    public let regionMaxY: Double

    /// Camera zoom at which this build was computed.
    public let builtZoom: Double

    /// Mutation generation the build targeted.
    public let mutationGen: Int

    /// Vertices emitted for hatch-pattern lines (diagnostic: zoomed-out
    /// hatch density dominates the vertex budget in hatched drawings).
    public let hatchVerts: Int

    /// True when the hard total-vertex guard dropped trailing inputs.
    /// Displayed in PerfStats; zoom in to recover full detail.
    public let capped: Bool

    public init(
        vertices: [CADVertex],
        batches: [CADDrawBatch],
        vertexCount: Int,
        hatchVerts: Int = 0,
        capped: Bool = false,
        regionMinX: Double,
        regionMinY: Double,
        regionMaxX: Double,
        regionMaxY: Double,
        builtZoom: Double,
        mutationGen: Int
    ) {
        self.vertices = vertices
        self.batches = batches
        self.vertexCount = vertexCount
        self.hatchVerts = hatchVerts
        self.capped = capped
        self.regionMinX = regionMinX
        self.regionMinY = regionMinY
        self.regionMaxX = regionMaxX
        self.regionMaxY = regionMaxY
        self.builtZoom = builtZoom
        self.mutationGen = mutationGen
    }
}

// =========================================================================
// MARK: - CADVertexBufferBuilder
// =========================================================================

/// Owns the pure tessellator plus a lock-guarded pending slot for async builds.
/// Mirrors the `CADRendererBridge` pattern: tessellate off-actor, stash behind
/// a generation token, apply on the main thread.
///
/// GPU access stays on the engine (in `applyVertexBuild`); this class is
/// strictly CPU tessellation + pending-result plumbing.
@MainActor
public final class CADVertexBufferBuilder {

    /// Pending result from the most-recently-completed async build.
    /// Guarded by `pendingLock`. `nonisolated(unsafe)` + NSLock pattern matches
    /// `CADRendererBridge.pendingResults` (SE-0434 caveat applies).
    private nonisolated(unsafe) var pendingBuild: (token: Int, result: VertexBuildResult)? = nil
    private let pendingLock = NSLock()

    public init() {}

    // MARK: - Pure Tessellation (nonisolated, cancellable)

    /// Run the CAD tessellation loop against value-typed inputs. Pure function —
    /// no access to `self`, `gpuDevice`, or any actor-isolated state.
    ///
    /// Returns `nil` if cancelled mid-loop.
    /// Returns a valid (possibly empty) `VertexBuildResult` otherwise.
    ///
    /// The body is lifted directly from `rebuildCadVertexBuffer()`.
    /// Maximum bytes for one vertex-buffer upload. Drivers reject larger
    /// single allocations (observed as device removal, DXGI 0x887A0006),
    /// so oversized builds are refused with a clear message instead of
    /// killing the GPU device. Chunked upload is the follow-up.
    internal static let maxSingleVertexUploadBytes: UInt64 = 512 * 1024 * 1024

    /// Upload size for a vertex count, or nil when it cannot be created:
    /// empty, overflowing a 32-bit GPU size, or over the single-buffer
    /// budget. Callers keep the previous buffer on nil.
    internal static func vertexUploadByteSize(vertexCount: Int) -> UInt64? {
        guard vertexCount > 0 else { return nil }
        let bytes = UInt64(vertexCount) * UInt64(MemoryLayout<CADVertex>.stride)
        guard bytes <= UInt64(UInt32.max), bytes <= maxSingleVertexUploadBytes else { return nil }
        return bytes
    }

    /// Maximum vertices per uploaded chunk (4M verts = 128 MB at 32 B/vert).
    /// Tessellated output is split into chunk-sized batch groups so no
    /// single GPU allocation can exceed driver limits.
    internal nonisolated static let maxVertsPerChunk = 4_194_304

    /// Hairline-quad estimate above which plain hairlines fall back to
    /// 1px line pairs (same pixels, ~3x fewer verts). Env override
    /// `ZEPHYR_HAIRLINE_VERT_BUDGET`. The quad upgrade exists to unify
    /// pipelines; past one chunk of hairline verts the memory cost wins.
    internal nonisolated static let defaultHairlineVertBudget = maxVertsPerChunk

    /// Hard total-vertex ceiling per build (last-resort OOM guard).
    /// Env override `ZEPHYR_MAX_TOTAL_VERTS`. Excess inputs are skipped
    /// with a warning and a `capped` flag instead of removing the device.
    internal nonisolated static let defaultMaxTotalVerts = 16_777_216

    internal nonisolated static func hairlineVertBudget() -> Int {
        if let raw = ProcessInfo.processInfo.environment["ZEPHYR_HAIRLINE_VERT_BUDGET"],
           let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return defaultHairlineVertBudget
    }

    internal nonisolated static func maxTotalVerts() -> Int {
        if let raw = ProcessInfo.processInfo.environment["ZEPHYR_MAX_TOTAL_VERTS"],
           let parsed = Int(raw), parsed > 0 {
            return parsed
        }
        return defaultMaxTotalVerts
    }

    /// Splits a tessellated batch list into chunk-sized groups with
    /// chunk-local first-vertex offsets. All pipelines use LIST topologies,
    /// so cutting a batch mid-run into consecutive same-pipeline draws is
    /// pixel-identical (same state, same order); pan-proxy and pipeline
    /// boundaries are never crossed, only subdivided.
    internal static func chunkBatches(
        _ batches: [CADDrawBatch],
        maxVertsPerChunk: Int = maxVertsPerChunk
    ) -> [[CADDrawBatch]] {
        guard maxVertsPerChunk > 0, maxVertsPerChunk <= Int(UInt32.max) else {
            return batches.isEmpty ? [] : [batches]
        }
        let cap = UInt32(maxVertsPerChunk)
        var chunks: [[CADDrawBatch]] = []
        var current: [CADDrawBatch] = []
        var currentVerts: UInt32 = 0
        var base: UInt32 = 0
        func closeChunk() {
            base += currentVerts
            currentVerts = 0
            chunks.append(current)
            current = []
        }
        for batch in batches {
            // Splits must land on primitive boundaries: cutting a triangle
            // batch at a non-multiple of 3 phase-shifts every following
            // triangle in the next chunk (corners from neighboring
            // triangles draw as long streaks across the map).
            let granularity: UInt32
            switch batch.pipelineType {
            case .triangle, .aaLine: granularity = 3
            case .line: granularity = 2
            case .point: granularity = 1
            }
            var start = batch.firstVertex
            var remaining = batch.vertexCount
            while remaining > 0 {
                if currentVerts >= cap {
                    closeChunk()
                    continue
                }
                var take = min(remaining, cap - currentVerts)
                if take < remaining {
                    take -= take % granularity
                }
                if take == 0 {
                    if currentVerts == 0 {
                        // Cap below one primitive: overshoot by one primitive
                        // rather than spin forever closing empty chunks.
                        take = min(remaining, granularity)
                    } else {
                        closeChunk()
                        continue
                    }
                }
                current.append(CADDrawBatch(
                    pipelineType: batch.pipelineType,
                    firstVertex: start - base,
                    vertexCount: take,
                    isPanProxy: batch.isPanProxy,
                    lineWeight: batch.lineWeight))
                start += take
                remaining -= take
                currentVerts += take
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    public nonisolated static func tessellate(
        _ inputs: [TessInput],
        cameraZoom: Double,
        pixelScale: Float,
        antiAliasLines: Bool,
        hairlineQuads: Bool,
        region: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        mutationGen: Int,
        hairlineBudgetOverride: Int? = nil,
        maxTotalVertsOverride: Int? = nil
    ) -> VertexBuildResult? {
        // Pre-allocate array capacities.
        var estimatedVertices = 0
        var hairlineEstimate = 0
        for input in inputs {
            estimatedVertices += input.points.count * 6
            estimatedVertices += input.corners.count
            estimatedVertices += input.rects.count * 6
            // Hairline-eligible inputs mirror the pipeType branch below:
            // plain hairlines that would be upgraded to 1px quads.
            switch input.type {
            case .line, .lines:
                if input.segmentLineWeights.isEmpty
                    && input.lineWeight <= 0.25
                    && input.geomWidth <= 0.0
                    && !antiAliasLines {
                    hairlineEstimate += input.points.count * 6
                }
            default:
                break
            }
        }
        estimatedVertices = max(estimatedVertices, 1024)

        // Budget-gated hairline degrade: the quad upgrade unifies pipelines
        // (fewer draws), but past one chunk of hairline verts the memory
        // cost dominates — fall back to 1px line pairs (same pixels).
        // Input-driven, never zoom-driven, so no band flip-flop.
        // Overrides are test seams; production passes nil for env/defaults.
        let hairlineBudget = hairlineBudgetOverride ?? Self.hairlineVertBudget()
        let hardCap = maxTotalVertsOverride ?? Self.maxTotalVerts()
        let allowHairlineQuads = hairlineEstimate <= hairlineBudget
        // Effective flag used by BOTH the batch pipeline key and the
        // emission paths below — they must agree, or quads get drawn
        // as lines (wasted verts) or vice versa.
        let effHairlineQuads = hairlineQuads && allowHairlineQuads
        var cappedInputs = 0

        var vertices: [CADVertex] = []
        vertices.reserveCapacity(estimatedVertices)
        
        var batches: [CADDrawBatch] = []
        var hatchVerts = 0
        let safeZoom = max(Float(cameraZoom), 0.000001)
        let safePixelScale = max(pixelScale, 0.000001)
        let safePixelZoom = max(safeZoom * safePixelScale, 0.000001)

        struct LineRasterMetrics {
            let worldWidth: Float
            let coreHalfPixels: Float
            let outerHalfPixels: Float
        }

        func lineRasterMetrics(lineWeight: Double, geomWidth: Double = 0.0) -> LineRasterMetrics {
            let corePixels: Float
            if geomWidth > 0.0 {
                corePixels = max(Float(geomWidth) * safePixelZoom, 0.000001)
            } else if lineWeight > 0.25 {
                corePixels = max(1.0, Float(lineWeight) * (96.0 / 25.4))
            } else {
                corePixels = 1.0
            }

            let coreHalfPixels = corePixels * 0.5
            let outerHalfPixels = antiAliasLines
                ? coreHalfPixels + 0.5
                : coreHalfPixels

            return LineRasterMetrics(
                worldWidth: (outerHalfPixels * 2.0) / safePixelZoom,
                coreHalfPixels: coreHalfPixels,
                outerHalfPixels: outerHalfPixels)
        }

        func lineRasterMetrics(for input: TessInput) -> LineRasterMetrics {
            lineRasterMetrics(lineWeight: input.lineWeight, geomWidth: input.geomWidth)
        }

        func appendLineVertex(_ p: SDL_FPoint, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            vertices.append(CADVertex(x: p.x, y: p.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
        }

        func appendLineSegment(_ p1: SDL_FPoint, _ p2: SDL_FPoint, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            // Non-finite endpoints produce undefined GPU behavior (and have
            // removed devices in the wild): drop the segment. The quad path
            // below already rejects these via its length guard.
            guard p1.x.isFinite, p1.y.isFinite, p2.x.isFinite, p2.y.isFinite else { return }
            appendLineVertex(p1, r, g, b, a)
            appendLineVertex(p2, r, g, b, a)
        }

        func appendQuadSegment(
            _ p1: SDL_FPoint,
            _ p2: SDL_FPoint,
            _ metrics: LineRasterMetrics,
            _ r: Float,
            _ g: Float,
            _ b: Float,
            _ a: Float
        ) {
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let len = sqrt(dx * dx + dy * dy)
            guard len > 1e-5 else { return }

            let halfW = metrics.worldWidth * 0.5
            let nx = -dy / len * halfW
            let ny = dx / len * halfW
            let c1 = SDL_FPoint(x: p1.x + nx, y: p1.y + ny)
            let c2 = SDL_FPoint(x: p1.x - nx, y: p1.y - ny)
            let c3 = SDL_FPoint(x: p2.x - nx, y: p2.y - ny)
            let c4 = SDL_FPoint(x: p2.x + nx, y: p2.y + ny)

            let coreHalf = metrics.coreHalfPixels
            let outerHalf = metrics.outerHalfPixels

            vertices.append(CADVertex(x: c1.x, y: c1.y, r: r, g: g, b: b, a: a, u: coreHalf, v: outerHalf))
            vertices.append(CADVertex(x: c2.x, y: c2.y, r: r, g: g, b: b, a: a, u: coreHalf, v: -outerHalf))
            vertices.append(CADVertex(x: c3.x, y: c3.y, r: r, g: g, b: b, a: a, u: coreHalf, v: -outerHalf))

            vertices.append(CADVertex(x: c1.x, y: c1.y, r: r, g: g, b: b, a: a, u: coreHalf, v: outerHalf))
            vertices.append(CADVertex(x: c3.x, y: c3.y, r: r, g: g, b: b, a: a, u: coreHalf, v: -outerHalf))
            vertices.append(CADVertex(x: c4.x, y: c4.y, r: r, g: g, b: b, a: a, u: coreHalf, v: outerHalf))
        }

        func appendRenderableSegment(_ p1: SDL_FPoint, _ p2: SDL_FPoint, _ input: TessInput, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            if input.lineWeight > 0.25 || input.geomWidth > 0.0 || antiAliasLines || effHairlineQuads {
                appendQuadSegment(p1, p2, lineRasterMetrics(for: input), r, g, b, a)
            } else {
                appendLineSegment(p1, p2, r, g, b, a)
            }
        }

        func appendJoinedQuadPath(
            _ sourcePoints: [SDL_FPoint],
            _ metrics: LineRasterMetrics,
            _ r: Float,
            _ g: Float,
            _ b: Float,
            _ a: Float
        ) {
            guard sourcePoints.count >= 2 else { return }

            var points: [SDL_FPoint] = []
            points.reserveCapacity(sourcePoints.count)
            for point in sourcePoints {
                if let last = points.last {
                    let dx = point.x - last.x
                    let dy = point.y - last.y
                    if dx * dx + dy * dy <= 1e-10 { continue }
                }
                points.append(point)
            }
            guard points.count >= 2 else { return }
            if points.count == 2 {
                appendQuadSegment(points[0], points[1], metrics, r, g, b, a)
                return
            }

            let closeDX = points[points.count - 1].x - points[0].x
            let closeDY = points[points.count - 1].y - points[0].y
            let isClosed = points.count >= 3 && closeDX * closeDX + closeDY * closeDY <= 1e-10
            if isClosed {
                points.removeLast()
            }
            guard points.count >= 2 else { return }

            let halfW = metrics.worldWidth * 0.5
            let count = points.count
            let segmentCount = isClosed ? count : count - 1
            var normals = [SDL_FPoint](repeating: SDL_FPoint(x: 0, y: 0), count: segmentCount)

            for i in 0..<segmentCount {
                let next = (i + 1) % count
                let dx = points[next].x - points[i].x
                let dy = points[next].y - points[i].y
                let len = sqrt(dx * dx + dy * dy)
                guard len > 1e-5 else { continue }
                let ux = dx / len
                let uy = dy / len
                normals[i] = SDL_FPoint(x: -uy, y: ux)
            }

            var left = [SDL_FPoint](repeating: SDL_FPoint(x: 0, y: 0), count: count)
            var right = [SDL_FPoint](repeating: SDL_FPoint(x: 0, y: 0), count: count)
            let miterLimit: Float = 10.0

            for i in 0..<count {
                let offsetX: Float
                let offsetY: Float

                if !isClosed && i == 0 {
                    offsetX = normals[0].x * halfW
                    offsetY = normals[0].y * halfW
                } else if !isClosed && i == count - 1 {
                    offsetX = normals[segmentCount - 1].x * halfW
                    offsetY = normals[segmentCount - 1].y * halfW
                } else {
                    let previousSegment = (i - 1 + segmentCount) % segmentCount
                    let nextSegment = i % segmentCount
                    let previousNormal = normals[previousSegment]
                    let nextNormal = normals[nextSegment]
                    let sumX = previousNormal.x + nextNormal.x
                    let sumY = previousNormal.y + nextNormal.y
                    let sumLength = sqrt(sumX * sumX + sumY * sumY)

                    if sumLength <= 1e-5 {
                        offsetX = nextNormal.x * halfW
                        offsetY = nextNormal.y * halfW
                    } else {
                        let miterX = sumX / sumLength
                        let miterY = sumY / sumLength
                        let denominator = miterX * nextNormal.x + miterY * nextNormal.y
                        if abs(denominator) <= 1e-4 {
                            offsetX = nextNormal.x * halfW
                            offsetY = nextNormal.y * halfW
                        } else {
                            let unclampedLength = halfW / denominator
                            let limitedLength = max(-halfW * miterLimit, min(halfW * miterLimit, unclampedLength))
                            offsetX = miterX * limitedLength
                            offsetY = miterY * limitedLength
                        }
                    }
                }

                left[i] = SDL_FPoint(x: points[i].x + offsetX, y: points[i].y + offsetY)
                right[i] = SDL_FPoint(x: points[i].x - offsetX, y: points[i].y - offsetY)
            }

            for i in 0..<segmentCount {
                let next = (i + 1) % count
                let l1 = left[i]
                let r1 = right[i]
                let l2 = left[next]
                let r2 = right[next]

                let coreHalf = metrics.coreHalfPixels
                let outerHalf = metrics.outerHalfPixels

                vertices.append(CADVertex(x: l1.x, y: l1.y, r: r, g: g, b: b, a: a, u: coreHalf, v: outerHalf))
                vertices.append(CADVertex(x: r1.x, y: r1.y, r: r, g: g, b: b, a: a, u: coreHalf, v: -outerHalf))
                vertices.append(CADVertex(x: r2.x, y: r2.y, r: r, g: g, b: b, a: a, u: coreHalf, v: -outerHalf))

                vertices.append(CADVertex(x: l1.x, y: l1.y, r: r, g: g, b: b, a: a, u: coreHalf, v: outerHalf))
                vertices.append(CADVertex(x: r2.x, y: r2.y, r: r, g: g, b: b, a: a, u: coreHalf, v: -outerHalf))
                vertices.append(CADVertex(x: l2.x, y: l2.y, r: r, g: g, b: b, a: a, u: coreHalf, v: outerHalf))
            }
        }

        // Variable-width pen paths use geometric widths in world units. Unlike
        // CAD lineWeight (a plot/screen-space width), these widths must scale with
        // camera zoom so a zoomed-out freehand drawing does not turn into a blob.
        func appendVariableWidthJoinedPath(
            _ sourcePoints: [SDL_FPoint],
            _ sourceSegmentWeights: [Double],
            _ r: Float,
            _ g: Float,
            _ b: Float,
            _ a: Float
        ) {
            guard sourcePoints.count >= 2,
                  sourceSegmentWeights.count == sourcePoints.count - 1 else { return }

            var points: [SDL_FPoint] = [sourcePoints[0]]
            var segmentWeights: [Double] = []
            points.reserveCapacity(sourcePoints.count)
            segmentWeights.reserveCapacity(sourceSegmentWeights.count)

            for i in 0..<sourceSegmentWeights.count {
                let next = sourcePoints[i + 1]
                let last = points[points.count - 1]
                let dx = next.x - last.x
                let dy = next.y - last.y
                if dx * dx + dy * dy <= 1e-10 { continue }
                points.append(next)
                segmentWeights.append(sourceSegmentWeights[i])
            }

            guard points.count >= 2, segmentWeights.count == points.count - 1 else { return }
            if points.count == 2 {
                appendQuadSegment(
                    points[0], points[1],
                    lineRasterMetrics(lineWeight: 0.0, geomWidth: segmentWeights[0]),
                    r, g, b, a)
                return
            }

            let segmentCount = points.count - 1
            let segmentMetrics = segmentWeights.map {
                lineRasterMetrics(lineWeight: 0.0, geomWidth: $0)
            }
            var normals = [SDL_FPoint](
                repeating: SDL_FPoint(x: 0, y: 0),
                count: segmentCount)

            for i in 0..<segmentCount {
                let dx = points[i + 1].x - points[i].x
                let dy = points[i + 1].y - points[i].y
                let len = sqrt(dx * dx + dy * dy)
                guard len > 1e-5 else { continue }
                normals[i] = SDL_FPoint(x: -dy / len, y: dx / len)
            }

            var vertexMetrics: [LineRasterMetrics] = []
            vertexMetrics.reserveCapacity(points.count)
            for i in 0..<points.count {
                if i == 0 {
                    vertexMetrics.append(segmentMetrics[0])
                } else if i == points.count - 1 {
                    vertexMetrics.append(segmentMetrics[segmentCount - 1])
                } else {
                    let previous = segmentMetrics[i - 1]
                    let next = segmentMetrics[i]
                    let coreHalf = (previous.coreHalfPixels + next.coreHalfPixels) * 0.5
                    let outerHalf = (previous.outerHalfPixels + next.outerHalfPixels) * 0.5
                    vertexMetrics.append(LineRasterMetrics(
                        worldWidth: (outerHalf * 2.0) / safePixelZoom,
                        coreHalfPixels: coreHalf,
                        outerHalfPixels: outerHalf))
                }
            }

            var left = [SDL_FPoint](
                repeating: SDL_FPoint(x: 0, y: 0),
                count: points.count)
            var right = left
            let miterLimit: Float = 4.0

            for i in 0..<points.count {
                let halfW = vertexMetrics[i].worldWidth * 0.5
                let offsetX: Float
                let offsetY: Float

                if i == 0 {
                    offsetX = normals[0].x * halfW
                    offsetY = normals[0].y * halfW
                } else if i == points.count - 1 {
                    offsetX = normals[segmentCount - 1].x * halfW
                    offsetY = normals[segmentCount - 1].y * halfW
                } else {
                    let previousNormal = normals[i - 1]
                    let nextNormal = normals[i]
                    let sumX = previousNormal.x + nextNormal.x
                    let sumY = previousNormal.y + nextNormal.y
                    let sumLength = sqrt(sumX * sumX + sumY * sumY)

                    if sumLength <= 1e-5 {
                        offsetX = nextNormal.x * halfW
                        offsetY = nextNormal.y * halfW
                    } else {
                        let miterX = sumX / sumLength
                        let miterY = sumY / sumLength
                        let denominator = miterX * nextNormal.x + miterY * nextNormal.y
                        if abs(denominator) <= 1e-4 {
                            offsetX = nextNormal.x * halfW
                            offsetY = nextNormal.y * halfW
                        } else {
                            let unclampedLength = halfW / denominator
                            let limitedLength = max(
                                -halfW * miterLimit,
                                min(halfW * miterLimit, unclampedLength))
                            offsetX = miterX * limitedLength
                            offsetY = miterY * limitedLength
                        }
                    }
                }

                left[i] = SDL_FPoint(
                    x: points[i].x + offsetX,
                    y: points[i].y + offsetY)
                right[i] = SDL_FPoint(
                    x: points[i].x - offsetX,
                    y: points[i].y - offsetY)
            }

            for i in 0..<segmentCount {
                let next = i + 1
                let startMetrics = vertexMetrics[i]
                let endMetrics = vertexMetrics[next]

                vertices.append(CADVertex(
                    x: left[i].x, y: left[i].y, r: r, g: g, b: b, a: a,
                    u: startMetrics.coreHalfPixels, v: startMetrics.outerHalfPixels))
                vertices.append(CADVertex(
                    x: right[i].x, y: right[i].y, r: r, g: g, b: b, a: a,
                    u: startMetrics.coreHalfPixels, v: -startMetrics.outerHalfPixels))
                vertices.append(CADVertex(
                    x: right[next].x, y: right[next].y, r: r, g: g, b: b, a: a,
                    u: endMetrics.coreHalfPixels, v: -endMetrics.outerHalfPixels))

                vertices.append(CADVertex(
                    x: left[i].x, y: left[i].y, r: r, g: g, b: b, a: a,
                    u: startMetrics.coreHalfPixels, v: startMetrics.outerHalfPixels))
                vertices.append(CADVertex(
                    x: right[next].x, y: right[next].y, r: r, g: g, b: b, a: a,
                    u: endMetrics.coreHalfPixels, v: -endMetrics.outerHalfPixels))
                vertices.append(CADVertex(
                    x: left[next].x, y: left[next].y, r: r, g: g, b: b, a: a,
                    u: endMetrics.coreHalfPixels, v: endMetrics.outerHalfPixels))
            }
        }

        func appendRenderablePath(_ points: [SDL_FPoint], _ input: TessInput, _ r: Float, _ g: Float, _ b: Float, _ a: Float) {
            if input.segmentLineWeights.count == points.count - 1 {
                appendVariableWidthJoinedPath(
                    points, input.segmentLineWeights, r, g, b, a)
            } else if input.lineWeight > 0.25 || input.geomWidth > 0.0 || antiAliasLines || effHairlineQuads {
                appendJoinedQuadPath(points, lineRasterMetrics(for: input), r, g, b, a)
            } else {
                for i in 0..<(points.count - 1) {
                    appendLineSegment(points[i], points[i + 1], r, g, b, a)
                }
            }
        }

        for (i, input) in inputs.enumerated() {
            // Cooperative cancellation: check every 256 primitives.
            if i & 0xFF == 0 && Task.isCancelled {
                return nil
            }

            // Hard total-vertex guard: last-resort OOM protection. Stops
            // tessellating further inputs instead of handing the driver a
            // device-removing upload. Zoom in to recover (the region
            // pre-filter shrinks the input set).
            if vertices.count >= hardCap {
                cappedInputs = inputs.count - i
                break
            }

            // Hatch backstop: pattern lines closer than a pixel merge into a
            // solid mass on screen; skip them instead of tessellating
            // thousands of invisible lines. Runs at tessellate time with
            // live zoom, so no regen invalidation is needed.
            // This is a cross-band stale-buffer backstop only: regen-time
            // `HatchLOD` solidification (cutoff 4 design-px) normally replaces
            // dense patterns with a fill before they reach tessellation, and
            // its in-band invariant keeps live spacing above 1px whenever the
            // pattern path is taken.
            if input.isHatchLine, input.hatchSpacing > 0,
               input.hatchSpacing * Double(safePixelZoom) < 1.0 {
                continue
            }

            let color = input.color
            let r = Float(color.0) / 255.0
            let g = Float(color.1) / 255.0
            let b = Float(color.2) / 255.0
            let a = Float(color.3) / 255.0

            let firstVtx = UInt32(vertices.count)

            switch input.type {
            case .point, .points:
                let base = input.pointStyle % 32
                if input.pointStyle == 1 {
                    break  // PDMODE 1 = none: emit nothing.
                }
                guard base != 0 else {
                    let pointPixels: Float = input.isHatchLine
                        ? lineRasterMetrics(for: input).coreHalfPixels * 2.0
                        : 4.0
                    let halfW: Float = (pointPixels * 0.5) / safePixelZoom
                    for p in input.points {
                        let x0 = p.x - halfW
                        let x1 = p.x + halfW
                        let y0 = p.y - halfW
                        let y1 = p.y + halfW

                        vertices.append(CADVertex(x: x0, y: y0, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x1, y: y0, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x1, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                        vertices.append(CADVertex(x: x0, y: y0, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x1, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x0, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    }
                    break
                }
                // PDMODE 2/3/4 glyphs (+32 circle / +64 square): hairline
                // world-space segments sized by the resolved PDSIZE.
                let size = TessInput.resolvePointSize(
                    input.pointSize, regionHeight: region.maxY - region.minY)
                let h = Float(size * 0.5)
                func glyphSeg(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) {
                    appendRenderableSegment(
                        SDL_FPoint(x: x0, y: y0), SDL_FPoint(x: x1, y: y1),
                        input, r, g, b, a)
                }
                for p in input.points {
                    switch base {
                    case 2:  // plus
                        glyphSeg(p.x - h, p.y, p.x + h, p.y)
                        glyphSeg(p.x, p.y - h, p.x, p.y + h)
                    case 3:  // X
                        glyphSeg(p.x - h, p.y - h, p.x + h, p.y + h)
                        glyphSeg(p.x - h, p.y + h, p.x + h, p.y - h)
                    case 4:  // tick
                        glyphSeg(p.x, p.y - h, p.x, p.y + h)
                    default:
                        break
                    }
                    let extra = input.pointStyle - base
                    if extra == 32 || extra == 96 {
                        // Surrounding circle (24-gon outline, radius h).
                        let n = 24
                        for k in 0..<n {
                            let a0 = Float(k) * 2.0 * .pi / Float(n)
                            let a1 = Float(k + 1) * 2.0 * .pi / Float(n)
                            glyphSeg(p.x + h * cos(a0), p.y + h * sin(a0),
                                     p.x + h * cos(a1), p.y + h * sin(a1))
                        }
                    }
                    if extra == 64 || extra == 96 {
                        // Surrounding square (side 2h).
                        glyphSeg(p.x - h, p.y - h, p.x + h, p.y - h)
                        glyphSeg(p.x + h, p.y - h, p.x + h, p.y + h)
                        glyphSeg(p.x + h, p.y + h, p.x - h, p.y + h)
                        glyphSeg(p.x - h, p.y + h, p.x - h, p.y - h)
                    }
                }

            case .line:
                guard input.points.count >= 2 else { break }
                if input.isHatchLine {
                    var j = 0
                    while j + 1 < input.points.count {
                        appendRenderableSegment(input.points[j], input.points[j + 1], input, r, g, b, a)
                        j += 2
                    }
                } else {
                    appendRenderableSegment(input.points[0], input.points[1], input, r, g, b, a)
                }

            case .lines:
                guard input.points.count >= 2 else { break }
                // Screen-space running-anchor decimation. Open inputs
                // always keep their endpoints (sub-pixel dashes still draw
                // their dot, so dashed lines can never vanish); closed
                // sub-pixel loops collapse to nothing. Dash-safe: dash
                // splitting happens upstream at regen, and fragments are
                // open paths that survive here by construction.
                let pathPoints = BlockLOD.decimatedPolyline(
                    input.points, pixelsPerUnit: Double(safePixelZoom))
                guard pathPoints.count >= 2 else { break }
                appendRenderablePath(pathPoints, input, r, g, b, a)

            case .rect, .rects:
                if input.corners.count == 4 {
                    let c = input.corners
                    vertices.append(CADVertex(x: c[0].x, y: c[0].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    vertices.append(CADVertex(x: c[1].x, y: c[1].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                    vertices.append(CADVertex(x: c[1].x, y: c[1].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    vertices.append(CADVertex(x: c[2].x, y: c[2].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                    vertices.append(CADVertex(x: c[2].x, y: c[2].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    vertices.append(CADVertex(x: c[3].x, y: c[3].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                    vertices.append(CADVertex(x: c[3].x, y: c[3].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    vertices.append(CADVertex(x: c[0].x, y: c[0].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                } else {
                    for rect in input.rects {
                        let x1 = rect.x
                        let y1 = rect.y
                        let x2 = rect.x + rect.w
                        let y2 = rect.y + rect.h
                        vertices.append(CADVertex(x: x1, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x2, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                        vertices.append(CADVertex(x: x2, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x2, y: y2, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                        vertices.append(CADVertex(x: x2, y: y2, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x1, y: y2, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                        vertices.append(CADVertex(x: x1, y: y2, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: x1, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    }
                }

            case .fillRect, .fillRects:
                if let g = input.gradientData {
                    func appendGradientVertex(x: Float, y: Float) {
                        let rx = Double(x) - g.minX
                        let ry = Double(y) - g.minY
                        let proj = (rx * g.angleCos + ry * g.angleSin) / g.diag
                        let tc = max(0, min(1, Float(proj)))
                        let gr = Float(g.color1.0) + (Float(g.color2.0) - Float(g.color1.0)) * tc
                        let gg = Float(g.color1.1) + (Float(g.color2.1) - Float(g.color1.1)) * tc
                        let gb = Float(g.color1.2) + (Float(g.color2.2) - Float(g.color1.2)) * tc
                        let ga = Float(g.color1.3) + (Float(g.color2.3) - Float(g.color1.3)) * tc
                        vertices.append(CADVertex(x: x, y: y, r: gr / 255.0, g: gg / 255.0, b: gb / 255.0, a: ga / 255.0, u: 0.0, v: 0.0))
                    }
                    if input.corners.count >= 3 {
                        if input.corners.count % 3 == 0 {
                            for c in input.corners {
                                appendGradientVertex(x: c.x, y: c.y)
                            }
                        } else if input.corners.count == 4 {
                            let c = input.corners
                            appendGradientVertex(x: c[0].x, y: c[0].y)
                            appendGradientVertex(x: c[1].x, y: c[1].y)
                            appendGradientVertex(x: c[2].x, y: c[2].y)

                            appendGradientVertex(x: c[0].x, y: c[0].y)
                            appendGradientVertex(x: c[2].x, y: c[2].y)
                            appendGradientVertex(x: c[3].x, y: c[3].y)
                        } else {
                            let c = input.corners
                            for j in 1..<(c.count - 1) {
                                appendGradientVertex(x: c[0].x, y: c[0].y)
                                appendGradientVertex(x: c[j].x, y: c[j].y)
                                appendGradientVertex(x: c[j+1].x, y: c[j+1].y)
                            }
                        }
                    } else {
                        for rect in input.rects {
                            let x1 = rect.x
                            let y1 = rect.y
                            let x2 = rect.x + rect.w
                            let y2 = rect.y + rect.h
                            appendGradientVertex(x: x1, y: y1)
                            appendGradientVertex(x: x2, y: y1)
                            appendGradientVertex(x: x2, y: y2)

                            appendGradientVertex(x: x1, y: y1)
                            appendGradientVertex(x: x2, y: y2)
                            appendGradientVertex(x: x1, y: y2)
                        }
                    }
                } else {
                    if input.corners.count >= 3 {
                        if input.corners.count % 3 == 0 {
                            for c in input.corners {
                                vertices.append(CADVertex(x: c.x, y: c.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            }
                        } else if input.corners.count == 4 {
                            let c = input.corners
                            vertices.append(CADVertex(x: c[0].x, y: c[0].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: c[1].x, y: c[1].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: c[2].x, y: c[2].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
    
                            vertices.append(CADVertex(x: c[0].x, y: c[0].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: c[2].x, y: c[2].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: c[3].x, y: c[3].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        } else {
                            let c = input.corners
                            for j in 1..<(c.count - 1) {
                                vertices.append(CADVertex(x: c[0].x, y: c[0].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                                vertices.append(CADVertex(x: c[j].x, y: c[j].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                                vertices.append(CADVertex(x: c[j+1].x, y: c[j+1].y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            }
                        }
                    } else {
                        for rect in input.rects {
                            let x1 = rect.x
                            let y1 = rect.y
                            let x2 = rect.x + rect.w
                            let y2 = rect.y + rect.h
                            vertices.append(CADVertex(x: x1, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: x2, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: x2, y: y2, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))

                            vertices.append(CADVertex(x: x1, y: y1, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: x2, y: y2, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                            vertices.append(CADVertex(x: x1, y: y2, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        }
                    }
                }
            }

            // (Removed uvData padding logic as u/v are now embedded in CADVertex)

            // Phase 2: Set entityIndex on all vertices for this primitive.
            let eIdx = input.entityIndex
            if eIdx != 0 {
                let start = Int(firstVtx)
                let end = vertices.count
                if start < end {
                    // `Array.mutableSpan` is macOS 26+, so this stays on the raw-pointer API. The loop
                    // is a plain exclusive write of one field across a contiguous range.
                    vertices.withUnsafeMutableBufferPointer { buffer in
                        for j in start..<end {
                            buffer[j].entityIndex = eIdx
                        }
                    }
                }
            }

            let vtxCount = UInt32(vertices.count) - firstVtx
            guard vtxCount > 0 else { continue }
            if input.isHatchLine { hatchVerts += Int(vtxCount) }

            let pipeType: CADPipelineType
            switch input.type {
            case .point, .points:
                pipeType = .triangle
            case .fillRect, .fillRects:
                pipeType = .triangle
            case .line, .lines:
                // NOTE: .rect/.rects deliberately NOT in this case - their
                // emission appends raw corner vertices as line pairs (never
                // quads), so they belong on the .line pipeline via default:
                if !input.segmentLineWeights.isEmpty || input.lineWeight > 0.25 || input.geomWidth > 0.0 || antiAliasLines {
                    pipeType = antiAliasLines ? .aaLine : .triangle
                } else if effHairlineQuads {
                    pipeType = .triangle
                } else {
                    pipeType = .line
                }
            default:
                pipeType = .line
            }

            // Line weight is baked per-vertex (world width + AA falloff in
            // the vertex UVs) and never read from the batch at draw time, so
            // it must not split batches: runs of the same pipeline merge
            // across weight changes. Only pipeline and pan-proxy (a
            // visibility gate evaluated per frame) may start a new batch.
            if !batches.isEmpty
                && batches.last!.pipelineType == pipeType
                && batches.last!.isPanProxy == input.isPanProxy
            {
                batches[batches.count - 1].vertexCount += vtxCount
            } else {
                batches.append(CADDrawBatch(
                    pipelineType: pipeType,
                    firstVertex: firstVtx,
                    vertexCount: vtxCount,
                    isPanProxy: input.isPanProxy,
                    lineWeight: input.lineWeight))
            }
        }

        if cappedInputs > 0 {
            print("[CADVertex] vertex budget exceeded (\(vertices.count) verts) — dropping \(cappedInputs) inputs; zoom in to recover full detail")
        }

        return VertexBuildResult(
            vertices: vertices,
            batches: batches,
            vertexCount: vertices.count,
            hatchVerts: hatchVerts,
            capped: cappedInputs > 0,
            regionMinX: region.minX,
            regionMinY: region.minY,
            regionMaxX: region.maxX,
            regionMaxY: region.maxY,
            builtZoom: Double(safePixelZoom),
            mutationGen: mutationGen
        )
    }

    // MARK: - Async Plumbing (lock-guarded, mirrors CADRendererBridge)

    /// Off-actor entry point. Runs `tessellate`, then stashes the result if
    /// this is still the newest build (token ≥ any already-pending token).
    public nonisolated func build(
        inputs: [TessInput],
        token: Int,
        cameraZoom: Double,
        pixelScale: Float,
        antiAliasLines: Bool,
        hairlineQuads: Bool,
        region: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        mutationGen: Int
    ) async {
        guard let result = Self.tessellate(
            inputs, cameraZoom: cameraZoom, pixelScale: pixelScale, antiAliasLines: antiAliasLines,
            hairlineQuads: hairlineQuads, region: region, mutationGen: mutationGen)
        else {
            // Cancelled mid-loop — don't stash anything.
            return
        }

        pendingLock.withLock {
            // Never let an older build overwrite a newer one that already landed.
            if let existing = pendingBuild, existing.token >= token {
                return
            }
            pendingBuild = (token, result)
        }
    }

    /// Main-thread: returns (and clears) the pending result iff its token
    /// matches `wantToken`. Stale/superseded results are dropped.
    public nonisolated func takePending(forToken wantToken: Int) -> VertexBuildResult? {
        pendingLock.lock()
        guard let p = pendingBuild else {
            pendingLock.unlock()
            return nil
        }
        if p.token != wantToken {
            // Drop older generations; leave newer ones for the frame that catches up.
            if p.token < wantToken { pendingBuild = nil }
            pendingLock.unlock()
            return nil
        }
        pendingBuild = nil
        pendingLock.unlock()
        return p.result
    }

    /// Discards any pending result. Called on tab switch / shutdown.
    public func cancelPending() {
        pendingLock.lock()
        pendingBuild = nil
        pendingLock.unlock()
    }
}
