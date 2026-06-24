import Foundation
import ImGui
import SwiftSDL

// =========================================================================
// MARK: - JoinCommand
// =========================================================================

/// JOIN — Merge connected line entities into polyline entities.
///
/// **Workflow (AutoCAD-style):**
///   1. Select line entities.
///   2. Type `JOIN` (or `J`).
///   3. The command executes immediately — no interactive steps.
///
/// **Algorithm:**
///   - Collects world-space line segments from selected entities containing
///     `.line` and/or open `.polyline` primitives. Polylines are expanded into
///     their constituent segments for endpoint graph construction.
///   - Groups segment endpoints by spatial proximity into clusters (tolerance
///     = 0.001 world units).
///   - Builds an adjacency graph: each cluster is a node, each segment is an
///     edge connecting two clusters.
///   - Walks the graph greedily to extract maximal non-branching chains:
///     starts from degree-1 nodes first (open chains), then processes
///     remaining edges (closed loops). Chains stop at branch points.
///   - For each chain:
///     * **Closed** (first and last endpoints match within tolerance, ≥3
///       points) → single `.polygon(points:)` primitive with
///       `xdata["dxf.closed"] = .bool(true)`.
///     * **Open** → one `.polyline(points:)` primitive.
///   - Creates one `CADEntity` per chain (identity transform, world-space
///     geometry), deletes all original entities, and selects the new ones.
///
/// **Edge cases:**
///   - Entities with block references: skipped.
///   - Entities with unsupported primitives (circle, spline, etc.): skipped.
///   - Single-line entity with no matching neighbours: passed through as-is
///     (one open chain with one segment).
///   - Branching chains (three lines meeting at one point): split at the
///     branch point into separate chains.
///   - Zero-segment chains: silently skipped.
///   - Lines on different layers: each chain inherits the layer of its first
///     segment.
///
/// **Undo:** `start()` calls `document.replaceEntities(remove:add:)` which
/// pushes a single undo snapshot before mutating the entity registry.
/// Reverting restores all original entities and removes the joined polyline(s)
/// in one undo step.
@MainActor
public final class JoinCommand: FeatureCommand {

    /// Endpoints closer than this distance (world units) are merged into the
    /// same cluster. 0.001 is tight enough to avoid accidental merges and
    /// wide enough to absorb single-precision rounding from DXF import.
    private static let endpointTolerance: Double = 0.001

    // MARK: - FeatureCommand conformance

    public init() {}

    /// Does all the work immediately. The command finishes on return.
    public func start(engine: PhrostEngine, processor: CADCommandProcessor) {
        let doc = engine.document
        let selection = engine.cadSelection

        guard selection.hasSelection else {
            processor.commandPrompt = "Select lines to join, then run JOIN."
            processor.finishFeatureCommand(engine: engine)
            return
        }

        // ---- Step 1: Collect world-space line segments from selected entities ----

        struct WorldLineSegment {
            let entityHandle: UUID
            let layerID: UUID
            let start: Vector3
            let end: Vector3
            let color: ColorRGBA?
            let xdata: [String: XDataValue]
        }

        var segments: [WorldLineSegment] = []
        var skippedBlockRefs = 0
        var skippedNonLine = 0
        var skippedEmpty = 0

        for handle in selection.selectedHandles {
            guard let entity = doc.entity(for: handle) else { continue }

            // Skip block references — they don't have local line geometry.
            if entity.blockID != nil {
                skippedBlockRefs += 1
                continue
            }

            guard let geometry = entity.localGeometry, !geometry.isEmpty else {
                skippedEmpty += 1
                continue
            }

            // Lines and open polylines can share the same endpoint graph.
            // Reject only geometry that cannot be represented as an open chain.
            let hasUnsupportedPrimitive = geometry.contains { prim in
                switch prim {
                case .line, .polyline:
                    return false
                default:
                    return true
                }
            }
            if hasUnsupportedPrimitive {
                skippedNonLine += 1
                continue
            }

            let t = entity.transform
            for prim in geometry {
                switch prim {
                case .line(let start, let end, let color):
                    segments.append(WorldLineSegment(
                        entityHandle: handle,
                        layerID: entity.layerID,
                        start: t.transformPoint(start),
                        end: t.transformPoint(end),
                        color: color,
                        xdata: entity.xdata
                    ))
                case .polyline(let points, let color):
                    guard points.count >= 2 else { continue }
                    for i in 0..<(points.count - 1) {
                        segments.append(WorldLineSegment(
                            entityHandle: handle,
                            layerID: entity.layerID,
                            start: t.transformPoint(points[i]),
                            end: t.transformPoint(points[i + 1]),
                            color: color,
                            xdata: entity.xdata
                        ))
                    }
                default:
                    break
                }
            }
        }

        guard !segments.isEmpty else {
            let reason: String
            if skippedNonLine > 0 {
                reason = "No joinable line or open-polyline geometry selected."
            } else if skippedBlockRefs > 0 {
                reason = "Selected entities are block references. Explode them first."
            } else if skippedEmpty > 0 {
                reason = "Selected entities have no geometry."
            } else {
                reason = "No line entities selected."
            }
            processor.commandPrompt = reason
            processor.finishFeatureCommand(engine: engine)
            return
        }

        // ---- Step 2: Cluster endpoints by proximity ----

        var endpointClusters: [Vector3] = []  // representative point per cluster

        func findOrCreateCluster(for point: Vector3) -> Int {
            for (i, cluster) in endpointClusters.enumerated() {
                if point.distance(to: cluster) < Self.endpointTolerance {
                    return i
                }
            }
            endpointClusters.append(point)
            return endpointClusters.count - 1
        }

        var segClusters: [(s: Int, e: Int)] = []  // (startClusterIndex, endClusterIndex)
        segClusters.reserveCapacity(segments.count)

        for seg in segments {
            let si = findOrCreateCluster(for: seg.start)
            let ei = findOrCreateCluster(for: seg.end)
            segClusters.append((si, ei))
        }

        // ---- Step 3: Build adjacency graph ----

        var clusterSegments: [[Int]] = Array(repeating: [], count: endpointClusters.count)
        for (segIdx, (si, ei)) in segClusters.enumerated() {
            clusterSegments[si].append(segIdx)
            if si != ei {
                clusterSegments[ei].append(segIdx)
            }
        }

        // ---- Step 4: Extract maximal non-branching chains ----

        var usedSegments = Set<Int>()
        var chains: [[Int]] = []  // each chain is a list of segment indices (order TBD)

        /// Follow a chain starting from `cluster` with initial segment
        /// `firstSeg`. Traverses until a dead end or branch. Returns the
        /// ordered list of segment indices visited.
        func followChain(from cluster: Int, firstSeg: Int) -> [Int] {
            var chain: [Int] = [firstSeg]
            usedSegments.insert(firstSeg)

            var cur = cluster
            var seg = firstSeg

            while true {
                // Advance to the other endpoint of the current segment.
                let (si, ei) = segClusters[seg]
                cur = (si == cur) ? ei : si

                let candidates = clusterSegments[cur].filter { !usedSegments.contains($0) }
                if candidates.isEmpty { break }          // dead end
                if candidates.count > 1 { break }        // branch point — stop

                seg = candidates[0]
                chain.append(seg)
                usedSegments.insert(seg)
            }
            return chain
        }

        // Phase A: walk from degree-1 nodes (open chains).
        for clusterIdx in 0..<endpointClusters.count {
            let candidates = clusterSegments[clusterIdx].filter { !usedSegments.contains($0) }
            guard candidates.count == 1 else { continue }
            let chain = followChain(from: clusterIdx, firstSeg: candidates[0])
            if !chain.isEmpty { chains.append(chain) }
        }

        // Phase B: pick up remaining edges (closed loops).
        for segIdx in 0..<segments.count {
            guard !usedSegments.contains(segIdx) else { continue }
            let (si, _) = segClusters[segIdx]
            let chain = followChain(from: si, firstSeg: segIdx)
            if !chain.isEmpty { chains.append(chain) }
        }

        // ---- Step 5: Order each chain's segments and produce polyline geometry ----

        /// Given a set of segment indices that form a non-branching chain,
        /// return the ordered world-space vertex list.
        func orderPoints(chain: Set<Int>) -> [Vector3] {
            guard !chain.isEmpty else { return [] }
            if chain.count == 1 {
                let segIdx = chain.first!
                let (si, ei) = segClusters[segIdx]
                return [endpointClusters[si], endpointClusters[ei]]
            }

            // Build local cluster→segment map restricted to this chain.
            var clusterToSegs: [Int: [Int]] = [:]
            for segIdx in chain {
                let (si, ei) = segClusters[segIdx]
                clusterToSegs[si, default: []].append(segIdx)
                clusterToSegs[ei, default: []].append(segIdx)
            }

            // Start from a degree-1 node if any, otherwise any node (closed loop).
            let degree1 = clusterToSegs.filter { $0.value.count == 1 }
            var cur: Int
            if let first = degree1.first {
                cur = first.key
            } else {
                cur = clusterToSegs.keys.first!
            }

            var ordered: [Vector3] = [endpointClusters[cur]]
            var usedLocal = Set<Int>()

            while usedLocal.count < chain.count {
                let candidates = (clusterToSegs[cur] ?? []).filter { !usedLocal.contains($0) }
                guard let nextSeg = candidates.first else { break }
                usedLocal.insert(nextSeg)

                let (si, ei) = segClusters[nextSeg]
                cur = (si == cur) ? ei : si
                ordered.append(endpointClusters[cur])
            }

            return ordered
        }

        // ---- Step 6: Create new polyline entities and collect originals for removal ----

        var removedHandles = Set<UUID>()
        var newEntities: [CADEntity] = []

        var mergedChains: [[Int]] = []
        var isolatedChains: [[Int]] = []

        for chain in chains {
            if chain.count >= 2 {
                mergedChains.append(chain)
                for segIdx in chain {
                    removedHandles.insert(segments[segIdx].entityHandle)
                }
            } else {
                isolatedChains.append(chain)
            }
        }

        var chainsToProcess = mergedChains
        for chain in isolatedChains {
            let segIdx = chain[0]
            if removedHandles.contains(segments[segIdx].entityHandle) {
                chainsToProcess.append(chain)
            }
        }

        for chain in chainsToProcess {
            let chainSet = Set(chain)
            let rawPoints = orderPoints(chain: chainSet)

            // Remove consecutive near-duplicates.
            var deduped: [Vector3] = []
            for pt in rawPoints {
                if let last = deduped.last, last.distance(to: pt) < Self.endpointTolerance {
                    continue
                }
                deduped.append(pt)
            }
            guard deduped.count >= 2 else { continue }

            // Determine if closed: first and last points coincide AND ≥3 points.
            let isClosed = deduped.count >= 3
                && deduped.first!.distance(to: deduped.last!) < Self.endpointTolerance

            let primitives: [CADPrimitive]
            let color = segments[chain[0]].color
            if isClosed {
                var closedPoints = deduped
                closedPoints.removeLast()  // the closing point duplicates the first
                primitives = [.polygon(points: closedPoints, color: color)]
            } else {
                primitives = [.polyline(points: deduped, color: color)]
            }

            // Use the first segment's layer; fall back to active layer.
            let firstSegIdx = chain[0]
            let layerID = segments[firstSegIdx].layerID

            var entity = CADEntity(
                layerID: layerID,
                localGeometry: primitives,
                transform: .identity
            )

            if isClosed {
                entity.xdata["dxf.closed"] = .bool(true)
            }

            // Carry over non-geometric xdata from the first segment.
            let xd = segments[firstSegIdx].xdata
            if let v = xd["dxf.lineType"]   { entity.xdata["dxf.lineType"]   = v }
            if let v = xd["dxf.color"]      { entity.xdata["dxf.color"]      = v }
            if let v = xd["dxf.lineWeight"] { entity.xdata["dxf.lineWeight"] = v }
            // drawOrder is now a first-class property, not xdata
            entity.drawOrder = doc.entity(for: segments[firstSegIdx].entityHandle)?.drawOrder ?? Int.max

            newEntities.append(entity)

            // Collect original entity handles for removal.
            for segIdx in chain {
                removedHandles.insert(segments[segIdx].entityHandle)
            }
        }

        // ---- Step 7: Atomic replace (one undo step) and select new entities ----

        doc.replaceEntities(remove: removedHandles, add: newEntities)

        selection.clearSelection()
        for entity in newEntities {
            selection.addToSelection(entity.handle)
        }

        engine.tabManager.markActiveDirty()

        // ---- Report ----

        var closedCount = 0
        for entity in newEntities {
            if let e = doc.entity(for: entity.handle),
               e.xdata["dxf.closed"] == .bool(true) {
                closedCount += 1
            }
        }

        let msg = "Joined \(removedHandles.count) entities into \(newEntities.count) polyline(s)"
            + (closedCount > 0 ? " (\(closedCount) closed)" : "")
            + "."
        print("[JOIN] \(msg)")
        processor.commandPrompt = msg

        processor.finishFeatureCommand(engine: engine)
    }

    public func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {
        // No cleanup needed — start() finishes before returning.
    }

    public func handleMouseClick(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .finished
    }

    public func handleMouseMotion(
        worldX: Double, worldY: Double,
        engine: PhrostEngine, processor: CADCommandProcessor
    ) {
    }

    public func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine, processor: CADCommandProcessor
    ) -> CommandResult {
        return .finished
    }

    public func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {
    }
}
