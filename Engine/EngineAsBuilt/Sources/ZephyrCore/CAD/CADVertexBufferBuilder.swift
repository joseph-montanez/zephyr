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
    public let entityIndex: UInt32
    public let isHatchLine: Bool
    public let hatchSpacing: Double
    public let isPanProxy: Bool
    public let gradientData: RenderPrimitive.GradientData?

    public init(
        type: PrimitiveType,
        points: [SDL_FPoint],
        rects: [SDL_FRect],
        corners: [SDL_FPoint],
        color: (UInt8, UInt8, UInt8, UInt8),
        lineWeight: Double,
        geomWidth: Double,
        entityIndex: UInt32,
        isHatchLine: Bool = false,
        hatchSpacing: Double = 0.0,
        isPanProxy: Bool = false,
        gradientData: RenderPrimitive.GradientData? = nil
    ) {
        self.type = type
        self.points = points
        self.rects = rects
        self.corners = corners
        self.color = color
        self.lineWeight = lineWeight
        self.geomWidth = geomWidth
        self.entityIndex = entityIndex
        self.isHatchLine = isHatchLine
        self.hatchSpacing = hatchSpacing
        self.isPanProxy = isPanProxy
        self.gradientData = gradientData
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

    public init(
        vertices: [CADVertex],
        batches: [CADDrawBatch],
        vertexCount: Int,
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
    public nonisolated static func tessellate(
        _ inputs: [TessInput],
        cameraZoom: Double,
        antiAliasLines: Bool,
        region: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        mutationGen: Int
    ) -> VertexBuildResult? {
        // Pre-allocate array capacities.
        var estimatedVertices = 0
        for input in inputs {
            estimatedVertices += input.points.count * 6
            estimatedVertices += input.corners.count
            estimatedVertices += input.rects.count * 6
        }
        estimatedVertices = max(estimatedVertices, 1024)

        var vertices: [CADVertex] = []
        vertices.reserveCapacity(estimatedVertices)
        
        var batches: [CADDrawBatch] = []

        for (i, input) in inputs.enumerated() {
            // Cooperative cancellation: check every 256 primitives.
            if i & 0xFF == 0 && Task.isCancelled {
                return nil
            }

            let color = input.color
            let r = Float(color.0) / 255.0
            let g = Float(color.1) / 255.0
            let b = Float(color.2) / 255.0
            let a = Float(color.3) / 255.0

            let firstVtx = UInt32(vertices.count)

            switch input.type {
            case .point, .points:
                let pointPixels: Float = 4.0
                let halfW: Float = (pointPixels * 0.5) / Float(cameraZoom)
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

            case .line:
                if input.isHatchLine {
                    for p in input.points {
                        vertices.append(CADVertex(x: p.x, y: p.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    }
                } else if input.lineWeight > 0.25 || input.geomWidth > 0.0 || antiAliasLines {
                    guard input.points.count >= 2 else { break }
                    let p1 = input.points[0]
                    let p2 = input.points[1]
                    let dx = p2.x - p1.x
                    let dy = p2.y - p1.y
                    let len = sqrt(dx*dx + dy*dy)
                    if len > 1e-5 {
                        // World-space line width (no zoom compensation — zoom scales naturally via camera matrix).
                        // geomWidth and lineWeight are both in world units (mm).
                        // The ×8 factor gives reasonable visibility: 0.25 mm → 2.0 world units.
                        let w: Float
                        if input.geomWidth > 0.0 {
                            w = Float(input.geomWidth)
                        } else if input.lineWeight > 0.25 {
                            w = Float(input.lineWeight * 8.0)
                        } else {
                            w = 2.0
                        }

                        let halfW: Float = w * 0.5
                        let nx: Float = -dy / len * halfW
                        let ny: Float = dx / len * halfW
                        let c1 = SDL_FPoint(x: p1.x + nx, y: p1.y + ny)
                        let c2 = SDL_FPoint(x: p1.x - nx, y: p1.y - ny)
                        let c3 = SDL_FPoint(x: p2.x - nx, y: p2.y - ny)
                        let c4 = SDL_FPoint(x: p2.x + nx, y: p2.y + ny)

                        vertices.append(CADVertex(x: c1.x, y: c1.y, r: r, g: g, b: b, a: a, u: 0.0, v: 1.0))
                        vertices.append(CADVertex(x: c2.x, y: c2.y, r: r, g: g, b: b, a: a, u: 0.0, v: -1.0))
                        vertices.append(CADVertex(x: c3.x, y: c3.y, r: r, g: g, b: b, a: a, u: 1.0, v: -1.0))

                        vertices.append(CADVertex(x: c1.x, y: c1.y, r: r, g: g, b: b, a: a, u: 0.0, v: 1.0))
                        vertices.append(CADVertex(x: c3.x, y: c3.y, r: r, g: g, b: b, a: a, u: 1.0, v: -1.0))
                        vertices.append(CADVertex(x: c4.x, y: c4.y, r: r, g: g, b: b, a: a, u: 1.0, v: 1.0))
                    }
                } else {
                    for p in input.points {
                        vertices.append(CADVertex(x: p.x, y: p.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    }
                }

            case .lines:
                guard input.points.count >= 2 else { break }
                if input.isHatchLine {
                    for j in 0..<(input.points.count - 1) {
                        let p1 = input.points[j]
                        let p2 = input.points[j+1]
                        vertices.append(CADVertex(x: p1.x, y: p1.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: p2.x, y: p2.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    }
                } else if input.lineWeight > 0.25 || input.geomWidth > 0.0 || antiAliasLines {
                    for j in 0..<(input.points.count - 1) {
                        let p1 = input.points[j]
                        let p2 = input.points[j+1]
                        let dx = p2.x - p1.x
                        let dy = p2.y - p1.y
                        let len = sqrt(dx*dx + dy*dy)
                        if len > 1e-5 {
                            // World-space line width (no zoom compensation — zoom scales naturally via camera matrix).
                            let w: Float
                            if input.geomWidth > 0.0 {
                                w = Float(input.geomWidth)
                            } else if input.lineWeight > 0.25 {
                                w = Float(input.lineWeight * 8.0)
                            } else {
                                w = 2.0
                            }

                            let halfW: Float = w * 0.5
                            let nx: Float = -dy / len * halfW
                            let ny: Float = dx / len * halfW
                            let c1 = SDL_FPoint(x: p1.x + nx, y: p1.y + ny)
                            let c2 = SDL_FPoint(x: p1.x - nx, y: p1.y - ny)
                            let c3 = SDL_FPoint(x: p2.x - nx, y: p2.y - ny)
                            let c4 = SDL_FPoint(x: p2.x + nx, y: p2.y + ny)

                            vertices.append(CADVertex(x: c1.x, y: c1.y, r: r, g: g, b: b, a: a, u: 0.0, v: 1.0))
                            vertices.append(CADVertex(x: c2.x, y: c2.y, r: r, g: g, b: b, a: a, u: 0.0, v: -1.0))
                            vertices.append(CADVertex(x: c3.x, y: c3.y, r: r, g: g, b: b, a: a, u: 1.0, v: -1.0))

                            vertices.append(CADVertex(x: c1.x, y: c1.y, r: r, g: g, b: b, a: a, u: 0.0, v: 1.0))
                            vertices.append(CADVertex(x: c3.x, y: c3.y, r: r, g: g, b: b, a: a, u: 1.0, v: -1.0))
                            vertices.append(CADVertex(x: c4.x, y: c4.y, r: r, g: g, b: b, a: a, u: 1.0, v: 1.0))
                        }
                    }
                } else {
                    for j in 0..<(input.points.count - 1) {
                        let p1 = input.points[j]
                        let p2 = input.points[j+1]
                        vertices.append(CADVertex(x: p1.x, y: p1.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                        vertices.append(CADVertex(x: p2.x, y: p2.y, r: r, g: g, b: b, a: a, u: 0.0, v: 0.0))
                    }
                }

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
                    vertices.withUnsafeMutableBufferPointer { buffer in
                        for j in start..<end {
                            buffer[j].entityIndex = eIdx
                        }
                    }
                }
            }

            let vtxCount = UInt32(vertices.count) - firstVtx
            guard vtxCount > 0 else { continue }

            let pipeType: CADPipelineType
            switch input.type {
            case .point, .points:
                pipeType = .triangle
            case .fillRect, .fillRects:
                pipeType = .triangle
            case .line, .lines:
                if input.isHatchLine {
                    pipeType = .line
                } else if input.lineWeight > 0.25 || input.geomWidth > 0.0 {
                    pipeType = antiAliasLines ? .aaLine : .triangle
                } else if antiAliasLines {
                    pipeType = .aaLine
                } else {
                    pipeType = .line
                }
            default:
                pipeType = .line
            }

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
                    isPanProxy: input.isPanProxy))
            }
        }

        return VertexBuildResult(
            vertices: vertices,
            batches: batches,
            vertexCount: vertices.count,
            regionMinX: region.minX,
            regionMinY: region.minY,
            regionMaxX: region.maxX,
            regionMaxY: region.maxY,
            builtZoom: cameraZoom,
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
        antiAliasLines: Bool,
        region: (minX: Double, minY: Double, maxX: Double, maxY: Double),
        mutationGen: Int
    ) async {
        guard let result = Self.tessellate(
            inputs, cameraZoom: cameraZoom, antiAliasLines: antiAliasLines,
            region: region, mutationGen: mutationGen)
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
