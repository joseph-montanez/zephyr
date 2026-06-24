import Foundation

// =========================================================================
// MARK: - BVHBuilder
//
// Builds a bounding volume hierarchy (BVH) from entity and block bounding
// boxes. Uses a top-down midpoint-split strategy for good spatial query
// performance. The resulting BVHTree is used for:
//   - Fast viewport culling (skip off-screen geometry)
//   - Hit testing acceleration (rapid spatial queries)
//   - EAB file format serialization (pre-built tree for fast loading)

// =========================================================================
// MARK: - BVHBuilder
// =========================================================================

/// Builds a bounding volume hierarchy from entity and block bounding boxes.
///
/// Uses a top-down midpoint-split for good query performance.
/// The result is a `BVHTree` ready for serialization into the EAB BVH section.
public enum BVHBuilder {

    // MARK: - Build Item

    /// One item fed to the BVH builder.
    public struct BuildItem: Sendable {
        public let bbox: BoundingBox3D
        public let entityIndex: UInt32
        public let blockIndex: UInt32

        public init(bbox: BoundingBox3D, entityIndex: UInt32 = .max, blockIndex: UInt32 = .max) {
            self.bbox = bbox
            self.entityIndex = entityIndex
            self.blockIndex = blockIndex
        }
    }

    // MARK: - Internal Primitive (fileprivate to avoid nested-in-generic limitation)

    fileprivate struct Prim {
        let bbox: BoundingBox3D
        let entityIndex: UInt32
        let blockIndex: UInt32
    }

    // MARK: - Public API

    /// Build a BVH covering all entities and blocks in the document.
    public static func build<T>(from items: T) -> BVHTree where T: Collection, T.Element == BuildItem {
        guard !items.isEmpty else { return BVHTree() }

        var primitives: [Prim] = []
        primitives.reserveCapacity(items.count)
        for item in items {
            primitives.append(Prim(
                bbox: item.bbox,
                entityIndex: item.entityIndex,
                blockIndex: item.blockIndex
            ))
        }

        var nodes: [BVHNode] = []
        var entityIndices: [UInt32] = []
        var blockIndices: [UInt32] = []

        buildRecursive(primitives: primitives, start: 0, count: primitives.count,
                       nodes: &nodes, entityIndices: &entityIndices,
                       blockIndices: &blockIndices, parentNodeIdx: 0)

        return BVHTree(nodes: nodes, entityIndices: entityIndices, blockIndices: blockIndices)
    }

    // MARK: - Recursive Build

    private static func buildRecursive(
        primitives: [Prim],
        start: Int, count: Int,
        nodes: inout [BVHNode],
        entityIndices: inout [UInt32],
        blockIndices: inout [UInt32],
        parentNodeIdx: Int
    ) {
        guard count > 0 else {
            ensure(node: parentNodeIdx, in: &nodes, isLeaf: true, childCount: 0)
            return
        }

        if count <= 4 {
            let firstPrimIdx = UInt32(entityIndices.count)
            for i in start..<(start + count) {
                entityIndices.append(primitives[i].entityIndex)
                blockIndices.append(primitives[i].blockIndex)
            }
            let box = computeBBox(primitives: primitives, start: start, count: count)
            ensure(node: parentNodeIdx, in: &nodes, isLeaf: true, childCount: UInt8(count),
                   firstPrimitive: firstPrimIdx, primitiveCount: UInt32(count), box: box)
            return
        }

        let box = computeBBox(primitives: primitives, start: start, count: count)
        let size = box.size
        let axis: UInt8 = (size.x >= size.y && size.x >= size.z) ? 0
            : (size.y >= size.z ? 1 : 2)

        var sorted = Array(primitives[start..<(start + count)])
        sorted.sort { a, b in
            let ca: Double
            let cb: Double
            switch axis {
            case 0: ca = (a.bbox.min.x + a.bbox.max.x) * 0.5
                    cb = (b.bbox.min.x + b.bbox.max.x) * 0.5
            case 1: ca = (a.bbox.min.y + a.bbox.max.y) * 0.5
                    cb = (b.bbox.min.y + b.bbox.max.y) * 0.5
            default: ca = (a.bbox.min.z + a.bbox.max.z) * 0.5
                     cb = (b.bbox.min.z + b.bbox.max.z) * 0.5
            }
            return ca < cb
        }

        let mid = count / 2
        ensure(node: parentNodeIdx, in: &nodes, isLeaf: false, splitAxis: axis,
               childCount: 2, box: box)

        let left = parentNodeIdx * 2 + 1
        let right = parentNodeIdx * 2 + 2

        buildRecursive(primitives: sorted, start: 0, count: mid,
                       nodes: &nodes, entityIndices: &entityIndices,
                       blockIndices: &blockIndices, parentNodeIdx: left)
        buildRecursive(primitives: sorted, start: mid, count: count - mid,
                       nodes: &nodes, entityIndices: &entityIndices,
                       blockIndices: &blockIndices, parentNodeIdx: right)
    }

    private static func ensure(
        node idx: Int, in nodes: inout [BVHNode],
        isLeaf: Bool, splitAxis: UInt8 = 0, childCount: UInt8 = 0,
        firstPrimitive: UInt32 = 0, primitiveCount: UInt32 = 0,
        box: BoundingBox3D = BoundingBox3D()
    ) {
        while nodes.count <= idx { nodes.append(BVHNode(isLeaf: false)) }
        let bboxMin: (Float, Float, Float) = (Float(box.min.x), Float(box.min.y), Float(box.min.z))
        let bboxMax: (Float, Float, Float) = (Float(box.max.x), Float(box.max.y), Float(box.max.z))
        nodes[idx] = BVHNode(
            isLeaf: isLeaf, splitAxis: splitAxis, childCount: childCount,
            firstPrimitive: firstPrimitive, primitiveCount: primitiveCount,
            bboxMin: bboxMin, bboxMax: bboxMax
        )
    }

    private static func computeBBox(primitives: [Prim], start: Int, count: Int) -> BoundingBox3D {
        guard count > 0 else { return BoundingBox3D() }
        var mn = primitives[start].bbox.min
        var mx = primitives[start].bbox.max
        for i in (start + 1)..<(start + count) {
            let b = primitives[i].bbox
            if b.min.x < mn.x { mn.x = b.min.x }
            if b.min.y < mn.y { mn.y = b.min.y }
            if b.min.z < mn.z { mn.z = b.min.z }
            if b.max.x > mx.x { mx.x = b.max.x }
            if b.max.y > mx.y { mx.y = b.max.y }
            if b.max.z > mx.z { mx.z = b.max.z }
        }
        return BoundingBox3D(min: mn, max: mx)
    }
}
