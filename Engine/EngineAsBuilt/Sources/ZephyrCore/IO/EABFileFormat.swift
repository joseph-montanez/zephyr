import Foundation

// =========================================================================
// MARK: - Little-endian byte helpers
// =========================================================================

/// The one place that turns a scalar into its little-endian byte representation for the EAB format.
///
/// Every fixed-width write used to spell the conversion out inline, allocating a throwaway `Data`
/// (`withUnsafeBytes(of: v) { Data($0) }`) or `[UInt8]` (`… { Array($0) }`) per field. The byte order
/// and width now live here, so a reader can check the format's endianness in one place instead of 22.
///
/// The buffers are handed straight to `Data`/`Array`, so no intermediate container is allocated.
enum LittleEndianBytes {
    @inline(__always)
    static func append<Value>(_ value: Value, to data: inout Data) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }

    @inline(__always)
    static func append<Value>(_ value: Value, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value) { bytes.append(contentsOf: $0) }
    }

    @inline(__always)
    static func patch<Value>(_ value: Value, into data: inout Data, at offset: Int) {
        withUnsafeBytes(of: value) {
            data.replaceSubrange(offset..<(offset + $0.count), with: $0)
        }
    }

    /// A `Data` containing just the little-endian bytes of a scalar.
    @inline(__always)
    static func data<Value>(_ value: Value) -> Data {
        withUnsafeBytes(of: value) { Data($0) }
    }

    /// Reads a scalar at `offset`.
    ///
    /// Uses the safe `RawSpan.load` (SE-0525). Despite being a Swift 6.4 proposal, the plain
    /// `load(fromByteOffset:as:)` sits in an extension annotated
    /// `@available(SwiftCompatibilitySpan 5.0, *)` — macOS 10.14.4+ — alongside the rest of the Span
    /// family, so it is usable at our macOS 12 floor. (Only the `ByteOrder` overload is gated at
    /// `StdlibDeploymentTarget 6.4`.) An earlier revision used `loadUnaligned` on the mistaken belief
    /// that this needed macOS 27.
    @inline(__always)
    static func read<Value: ConvertibleFromBytes>(_ type: Value.Type, from data: Data, at offset: Int) -> Value {
        data.withUnsafeBytes { raw in
            RawSpan(_unsafeBytes: raw).load(fromByteOffset: offset, as: Value.self)
        }
    }
}

// =========================================================================
// MARK: - EABFileFormat
//
// Defines the Zephyr Binary (EAB) file format structures.
// EAB is a compact, versioned binary format for fast save/load of
// CAD documents, including layers, blocks, entities, constraints,
// and a BVH (bounding volume hierarchy) for spatial queries.
//
// The format uses flatbuffers-style serialization with fixed-size
// headers and variable-length data sections for optimal read performance.

// =========================================================================
// MARK: - EAB Constants
// =========================================================================

/// Magic bytes at the start of every .eab file.
public let EABMagic: UInt32 = 0x00424145  // "EAB\0" in little-endian

/// Magic bytes at the start of an EAB Archive (multi-view).
public let EABArchiveMagic: UInt32 = 0x41424145  // "EABA" in little-endian

/// Current file format version.
/// Version 13 persists full text style properties.
/// Version 14 persists associative array parameters and overrides.
/// Version 15 persists native leader metadata and named multileader styles.
/// Version 16 persists analytic hatch spline data and associative source handles.
/// Version 17 adds penStroke primitive with per-vertex pressure/tilt/rotation.
/// Version 18 adds a long-string sentinel for payloads over the UInt16 limit.
/// Version 19 adds the xrefs section (external-reference descriptors).
/// Version 20 adds the mediaDefinitions section (ATTACH image/PDF refs).
/// Version 21 stores dimension styles raw with overallScale (DIMSCALE);
/// v20-era readers would misrender the unscaled values, so they reject v21.
/// Version 22 persists block attribute definitions (ATTDEF) and per-insert
/// attribute values (ATTRIB).
public let EABVersion: UInt32 = 22
/// First version whose strings may use the 0xFFFF + UInt32 long-length form.
public let EABVersionLongStrings: UInt32 = 18

/// Section type identifiers in the section table.
public enum EABSectionType: UInt32, Sendable {
    case layers      = 1
    case blocks      = 2
    case entities    = 3
    case constraints = 4
    case solved      = 5
    case pvaBlock    = 6
    case pvaEntity   = 7
    case bvh         = 8
    case xdata       = 9
    case metadata    = 10
    case textStyles   = 11
    case lineTypes    = 12
    case images       = 13
    case dimensionStyles = 14
    case leaderStyles = 15
    case xrefs       = 16
    case mediaDefinitions = 17
    case groups      = 18
}

/// Compression mode for a data section.
public enum EABCompression: UInt8, Sendable {
    case none = 0
    case zstd = 1
}

// =========================================================================
// MARK: - EAB Header
// =========================================================================

/// The 32-byte fixed header at the start of an .eab file.
public struct EABHeader: Sendable {
    public let magic: UInt32
    public let version: UInt32
    public let flags: UInt32
    public let unit: CADUnit
    public let sectionTableOffset: UInt64
    public let fileCRC: UInt32

    public init(unit: CADUnit, sectionTableOffset: UInt64, fileCRC: UInt32 = 0,
                version: UInt32 = EABVersion) {
        self.magic = EABMagic
        self.version = version
        self.flags = 0
        self.unit = unit
        self.sectionTableOffset = sectionTableOffset
        self.fileCRC = fileCRC
    }
}

// =========================================================================
// MARK: - EAB Archive (Version 7)
// =========================================================================

/// The 16-byte fixed header at the start of a V7 multi-view .eab file.
public struct EABArchiveHeader: Sendable {
    public let magic: UInt32
    public let version: UInt32
    public let viewCount: UInt32
    public let directoryOffset: UInt64

    public init(viewCount: UInt32, directoryOffset: UInt64) {
        self.magic = EABArchiveMagic
        self.version = EABVersion
        self.viewCount = viewCount
        self.directoryOffset = directoryOffset
    }
}

/// An entry in the V7 multi-view directory.
public struct EABViewHeader: Sendable {
    public let name: String
    public let kind: UInt8
    public let cameraOffsetX: Double
    public let cameraOffsetY: Double
    public let cameraZoom: Double
    public let cameraRotation: Double
    public let dataOffset: UInt64
    public let dataSize: UInt64
}

// =========================================================================
// MARK: - Section Table Entry
// =========================================================================

public struct EABSectionEntry: Sendable {
    public let type: EABSectionType
    public let offset: UInt64
    public let size: UInt64
    public let compression: EABCompression
}

// =========================================================================
// MARK: - BVH Node
// =========================================================================

/// A single node in the binary BVH tree (52 bytes on disk).
public struct BVHNode: Sendable {
    public var flags: UInt8          // bit0 = leaf
    public var splitAxis: UInt8      // 0=X, 1=Y, 2=Z
    public var childCount: UInt8     // 0=empty, 2=internal, 1+=leaf
    public var firstChildOrPrimitive: UInt32  // leaf: offset into entity/block index; internal: unused
    public var primitiveCount: UInt32
    public var bboxMin: (Float, Float, Float)
    public var bboxMax: (Float, Float, Float)

    public var isLeaf: Bool { (flags & 0x01) != 0 }

    public init(
        isLeaf: Bool,
        splitAxis: UInt8 = 0,
        childCount: UInt8 = 0,
        firstPrimitive: UInt32 = 0,
        primitiveCount: UInt32 = 0,
        bboxMin: (Float, Float, Float) = (0, 0, 0),
        bboxMax: (Float, Float, Float) = (0, 0, 0)
    ) {
        self.flags = isLeaf ? 1 : 0
        self.splitAxis = splitAxis
        self.childCount = childCount
        self.firstChildOrPrimitive = firstPrimitive
        self.primitiveCount = primitiveCount
        self.bboxMin = bboxMin
        self.bboxMax = bboxMax
    }

    public static var stride: Int { 52 }
}

/// The complete BVH tree: flat node array + entity/block index arrays.
public struct BVHTree: Sendable {
    public let nodes: [BVHNode]
    public let entityIndices: [UInt32]   // maps primitive offsets → entity indices
    public let blockIndices: [UInt32]    // maps primitive offsets → block indices

    public init(nodes: [BVHNode] = [], entityIndices: [UInt32] = [], blockIndices: [UInt32] = []) {
        self.nodes = nodes
        self.entityIndices = entityIndices
        self.blockIndices = blockIndices
    }

    /// Query the BVH for primitives intersecting a viewport AABB.
    /// Returns indices into entityIndices and blockIndices arrays.
    public func query(viewport: BoundingBox3D) -> (entityIdx: Set<Int>, blockIdx: Set<Int>) {
        var entitySet = Set<Int>()
        var blockSet = Set<Int>()

        guard !nodes.isEmpty else { return (entitySet, blockSet) }

        var stack: [Int] = [0]
        while let nodeIdx = stack.popLast() {
            let node = nodes[nodeIdx]
            // AABB intersection test
            if node.bboxMax.0 < Float(viewport.min.x) || node.bboxMin.0 > Float(viewport.max.x)
                || node.bboxMax.1 < Float(viewport.min.y) || node.bboxMin.1 > Float(viewport.max.y)
                || node.bboxMax.2 < Float(viewport.min.z) || node.bboxMin.2 > Float(viewport.max.z)
            {
                continue
            }
            if node.isLeaf {
                for i in 0..<Int(node.primitiveCount) {
                    let primIdx = Int(node.firstChildOrPrimitive) + i
                    if let e = entityIndices[safe: primIdx], e != UInt32.max {
                        entitySet.insert(Int(e))
                    }
                    if let b = blockIndices[safe: primIdx], b != UInt32.max {
                        blockSet.insert(Int(b))
                    }
                }
            } else {
                let left = nodeIdx * 2 + 1
                let right = nodeIdx * 2 + 2
                if left < nodes.count { stack.append(left) }
                if right < nodes.count { stack.append(right) }
            }
        }
        return (entitySet, blockSet)
    }
}

// =========================================================================
// MARK: - BinaryWriter
// =========================================================================

/// Appends binary data to a backing Data buffer. Little-endian.
public final class BinaryWriter {
    private var data: Data
    private var lastProgressBytes: Int = 0
    
    /// Called every ~64 KB of accumulated data with the current byte count.
    public var progressHandler: ((Int) -> Void)?

    public init() { data = Data() }

    public var count: Int { data.count }

    /// The bytes written so far. Exposed for the verification harness (`ZephyrBench eab-scalars`).
    public var bytes: Data { data }

    // MARK: Fixed-width writes

    @inline(__always)
    public func writeUInt8(_ v: UInt8) { data.append(v) }

    @inline(__always)
    public func writeUInt16(_ v: UInt16) {
        LittleEndianBytes.append(v.littleEndian, to: &data)
        checkProgress()
    }

    @inline(__always)
    public func writeUInt32(_ v: UInt32) {
        LittleEndianBytes.append(v.littleEndian, to: &data)
        checkProgress()
    }

    @inline(__always)
    public func writeInt32(_ v: Int32) {
        writeUInt32(UInt32(bitPattern: v))
    }

    @inline(__always)
    public func writeUInt64(_ v: UInt64) {
        LittleEndianBytes.append(v.littleEndian, to: &data)
        checkProgress()
    }

    @inline(__always)
    public func writeFloat32(_ v: Float) {
        LittleEndianBytes.append(v, to: &data)
        checkProgress()
    }

    @inline(__always)
    public func writeFloat64(_ v: Double) {
        LittleEndianBytes.append(v, to: &data)
        checkProgress()
    }

    public func writeUUID(_ uuid: UUID) {
        LittleEndianBytes.append(uuid.uuid, to: &data)   // 16 bytes
        checkProgress()
    }

    public func writeString(_ s: String) {
        let bytes = Data(s.utf8)
        let byteCount = min(bytes.count, Int(UInt32.max))
        if byteCount < 0xFFFF {
            writeUInt16(UInt16(byteCount))
        } else {
            // EAB v18 long form: 0xFFFF sentinel + UInt32 byte count.
            writeUInt16(0xFFFF)
            writeUInt32(UInt32(byteCount))
        }
        data.append(bytes.prefix(byteCount))
        checkProgress()
    }

    public func writeBytes(_ bytes: Data) {
        data.append(bytes)
        checkProgress()
    }

    public func writeZeros(_ count: Int) {
        data.append(Data(count: count))
        checkProgress()
    }

    /// Fire progress handler every 65536 bytes.
    private func checkProgress() {
        guard let handler = progressHandler else { return }
        let threshold = lastProgressBytes + 65536
        if data.count >= threshold {
            lastProgressBytes = data.count
            handler(data.count)
        }
    }

    /// Pad to the given alignment with zero bytes.
    public func pad(to alignment: Int) {
        let rem = data.count % alignment
        if rem != 0 { writeZeros(alignment - rem) }
    }

    /// Reserve a placeholder for a UInt32, return the offset. Fill with `fillUInt32`.
    public func reserveUInt32() -> Int {
        let pos = data.count
        writeUInt32(0)
        return pos
    }

    /// Reserve a placeholder for a UInt64, return the offset. Fill with `fillUInt64`.
    public func reserveUInt64() -> Int {
        let pos = data.count
        writeUInt64(0)
        return pos
    }

    /// Fill a size placeholder at the given offset.
    public func fillUInt32(at offset: Int, value: UInt32) {
        LittleEndianBytes.patch(value.littleEndian, into: &data, at: offset)
    }

    /// Fill a UInt64 placeholder at the given offset.
    public func fillUInt64(at offset: Int, value: UInt64) {
        LittleEndianBytes.patch(value.littleEndian, into: &data, at: offset)
    }

    /// Fill a Float64 placeholder at the given offset.
    public func fillFloat64(at offset: Int, value: Double) {
        LittleEndianBytes.patch(value, into: &data, at: offset)
    }

    public func build() -> Data { data }
}

// =========================================================================
// MARK: - BinaryReader
// =========================================================================

/// Reads binary data from a Data buffer. Little-endian.
public final class BinaryReader {
    private let data: Data
    private var cursor: Int
    /// EAB v18+: a 0xFFFF string length is a sentinel for a UInt32 length.
    public let usesLongStringSentinel: Bool

    public init(data: Data, startOffset: Int = 0,
                usesLongStringSentinel: Bool = false) {
        self.data = data
        self.cursor = startOffset
        self.usesLongStringSentinel = usesLongStringSentinel
    }

    public var position: Int { cursor }
    public var remaining: Int { data.count - cursor }

    /// Check that we can read `count` bytes safely without overflow or OOB.
    public func canRead(_ count: Int) -> Bool {
        guard cursor >= 0, cursor <= data.count, count >= 0 else { return false }
        let (end, overflow) = cursor.addingReportingOverflow(count)
        return !overflow && end <= data.count
    }

    // MARK: Fixed-width reads

    public func readUInt8() -> UInt8 {
        guard canRead(1) else { return 0 }
        let v = data[cursor]
        cursor += 1
        return v
    }

    public func readUInt16() -> UInt16 {
        guard canRead(2) else { return 0 }
        let v = LittleEndianBytes.read(UInt16.self, from: data, at: cursor)
        cursor += 2
        return UInt16(littleEndian: v)
    }

    public func readUInt32() -> UInt32 {
        guard canRead(4) else { return 0 }
        let v = LittleEndianBytes.read(UInt32.self, from: data, at: cursor)
        cursor += 4
        return UInt32(littleEndian: v)
    }

    public func readInt32() -> Int32 {
        Int32(bitPattern: readUInt32())
    }

    public func readUInt64() -> UInt64 {
        guard canRead(8) else { return 0 }
        let v = LittleEndianBytes.read(UInt64.self, from: data, at: cursor)
        cursor += 8
        return UInt64(littleEndian: v)
    }

    public func readFloat32() -> Float {
        guard canRead(4) else { return 0 }
        let v = LittleEndianBytes.read(Float.self, from: data, at: cursor)
        cursor += 4
        return v
    }

    public func readFloat64() -> Double {
        guard canRead(8) else { return 0 }
        let v = LittleEndianBytes.read(Double.self, from: data, at: cursor)
        cursor += 8
        return v
    }

    public func readUUID() -> UUID {
        guard canRead(16) else {
            cursor = data.count
            return UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for i in 0..<16 { bytes.append(data[cursor + i]) }
        cursor += 16
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public func readString() -> String {
        let shortLength = readUInt16()
        let len: Int
        if usesLongStringSentinel && shortLength == 0xFFFF {
            len = Int(readUInt32())
        } else {
            len = Int(shortLength)
        }
        guard len > 0, canRead(len) else { return "" }
        let str = String(data: data.subdata(in: cursor..<cursor+len), encoding: .utf8) ?? ""
        cursor += len
        return str
    }

    public func readBytes(count: Int) -> Data {
        let safeCount = min(count, max(0, data.count - cursor))
        let d = safeCount > 0 ? data.subdata(in: cursor..<cursor+safeCount) : Data()
        cursor += safeCount
        return d
    }

    public func skip(_ count: Int) { cursor += count }

    public func seek(to offset: Int) { cursor = offset }

    /// Read raw bytes at an absolute offset without moving the cursor.
    public func readAt(offset: Int, length: Int) -> Data {
        data.subdata(in: offset..<offset+length)
    }
}

// =========================================================================
// MARK: - Array safe subscript
// =========================================================================

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
