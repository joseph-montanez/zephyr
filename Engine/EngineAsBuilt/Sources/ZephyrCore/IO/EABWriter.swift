import Foundation
import CZLibNG

// =========================================================================
// MARK: - SaveProgressTracker
// =========================================================================

/// Aggregates progress across multiple serialization sections.
/// Each section may use its own `BinaryWriter`; the tracker sums them.
public final class SaveProgressTracker: @unchecked Sendable {
    let estimatedTotal: Int
    private var completedBytes: Int = 0
    private var currentSectionBytes: Int = 0
    private var lastPublished: Float = 0
    var onProgress: ((Float) -> Void)?

    init(estimatedTotal: Int) { self.estimatedTotal = max(estimatedTotal, 1) }

    func attach(to writer: BinaryWriter) {
        writer.progressHandler = { [weak self] byteCount in
            self?.currentSectionBytes = byteCount
            self?.maybePublish()
        }
    }

    func finishSection(bytes: Int) {
        completedBytes += bytes
        currentSectionBytes = 0
        maybePublish()
    }

    func publishNow() {
        maybePublish()
    }

    private func maybePublish() {
        let total = completedBytes + currentSectionBytes
        let clamped = min(0.99, Float(total) / Float(estimatedTotal))
        if abs(clamped - lastPublished) >= 0.01 {
            lastPublished = clamped
            onProgress?(clamped)
        }
    }
}

// =========================================================================
// MARK: - EABWriter
// =========================================================================
// Serializes a Zephyr CAD document to the EAB binary format.
// Writes layers, blocks, entities, constraints, and a BVH tree for
// fast spatial queries on subsequent loads. Uses the EABFileFormat
// structures for serialization.

// =========================================================================
// MARK: - EABWriter
// =========================================================================

/// Serializes a `CADDocument` to the Zephyr Binary (.eab) file format.
///
/// Usage:
/// ```swift
/// try EABWriter.write(document: document, to: fileURL)
/// ```
public enum EABWriter {

    // MARK: - Public API (sync, legacy)

    /// Write a complete .eab file from a document tab's drawing views.
    public static func write(views: [DrawingView], to url: URL) throws {
        let data = try serialize(views: views)
        try data.write(to: url, options: .atomic)
    }

    /// Write a single document (legacy wrapper).
    public static func write(document: CADDocument, to url: URL) throws {
        let view = DrawingView(name: "Model", kind: .model, document: document)
        try write(views: [view], to: url)
    }

    // MARK: - Public API (async background-save)

    /// Write a complete .eab file from save snapshots with progress and cancellation.
    /// Writes to a unique temp file, then atomically replaces the target.
    public static func write(snapshots: [SaveDocumentSnapshot], to url: URL,
                              progress: ((Float) -> Void)? = nil) throws {
        let estimatedSize = estimateSerializedSize(snapshots: snapshots)
        let tracker = SaveProgressTracker(estimatedTotal: estimatedSize)
        tracker.onProgress = progress
        let data = try serialize(snapshots: snapshots, tracker: tracker)
        try atomicWrite(data: data, to: url)
    }

    /// Rough estimate of serialized byte count for progress tracking.
    public static func estimateSerializedSize(snapshots: [SaveDocumentSnapshot]) -> Int {
        var estimate = 20  // V7 archive header
        // Directory entries
        for snap in snapshots {
            estimate += 2 + snap.viewName.utf8.count + 1 + 32 + 8 + 8
            estimate += estimateSerializedSize(docSnapshot: snap.docSnapshot)
            // Image assets
            for asset in snap.imageAssets.values {
                estimate += 2 + asset.name.utf8.count
                    + 2 + asset.originalFilename.utf8.count
                    + 2 + asset.mimeType.utf8.count
                    + 4 + 4 + 2 + asset.sha256.utf8.count + 8
                    + asset.data.count
            }
        }
        return estimate
    }

    private static func estimateSerializedSize(docSnapshot: CADDocumentSnapshot) -> Int {
        var e = 32  // V6 header
        e += 64     // metadata
        e += 4 + docSnapshot.layers.count * 64
        e += 4 + docSnapshot.blocks.count * 80
        e += 4 + docSnapshot.entities.count * 128
        e += 4 + docSnapshot.constraints.count * 64
        e += 4 + docSnapshot.solvedTransforms.count * 72
        // PVA: rough 56 bytes per vertex, estimate 4 verts per entity/block
        let entityCount = max(docSnapshot.entities.count, 1)
        let blockCount = max(docSnapshot.blocks.count, 1)
        e += entityCount * 4 * 56
        e += blockCount * 4 * 56
        // BVH nodes
        e += max((entityCount + blockCount) * 2, 1) * 40
        e += entityCount * 4 + blockCount * 4  // index arrays
        // Text styles, linetypes, images, section table
        e += 256
        return e
    }

    /// Write Data to a unique temp file, then atomically swap with the target.
    private static func atomicWrite(data: Data, to targetURL: URL) throws {
        let tmpURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try data.write(to: tmpURL, options: .atomic)

#if os(Windows)
        // replaceItemAt is not implemented in Foundation on Windows.
        // Fall back to remove-then-move (not atomic, but safe).
        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: targetURL)
#else
        if FileManager.default.fileExists(atPath: targetURL.path) {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tmpURL)
        } else {
            try FileManager.default.moveItem(at: tmpURL, to: targetURL)
        }
#endif
    }

    // MARK: - Serialization

    /// Serialize multiple views to in-memory Data (V7 Archive).
    public static func serialize(views: [DrawingView]) throws -> Data {
        let w = BinaryWriter()

        // 1. Reserve V7 Archive Header (20 bytes: magic(4) + version(4) + viewCount(4) + directoryOffset(8))
        w.writeZeros(20)

        // 2. Reserve Directory table space
        // Each entry is: nameLength (2), name (N), kind (1), camera (32), dataOffset (8), dataSize (8)
        var directoryPositions: [(nameOffset: Int, cameraOffset: Int, offsetPos: Int, sizePos: Int)] = []
        for view in views {
            w.writeString(view.name)
            w.writeUInt8(view.kind == .model ? 0 : 1)
            let cameraOffset = w.count
            w.writeZeros(32)  // Reserve 32 bytes for cameraState
            let offsetPos = w.reserveUInt64()
            let sizePos = w.reserveUInt64()
            directoryPositions.append((nameOffset: 0, cameraOffset: cameraOffset, offsetPos: offsetPos, sizePos: sizePos))
        }

        let directoryOffset = UInt64(20) // immediately follows 20-byte header

        // 3. Serialize each view's V6 document
        for (i, view) in views.enumerated() {
            let dataOffset = UInt64(w.count)
            let v6Data = try serialize(document: view.document)
            w.writeBytes(v6Data)
            let dataSize = UInt64(v6Data.count)

            // Fill directory entry
            let pos = directoryPositions[i]
            
            // Fill camera state
            w.fillFloat64(at: pos.cameraOffset, value: view.cameraState.offsetX)
            w.fillFloat64(at: pos.cameraOffset + 8, value: view.cameraState.offsetY)
            w.fillFloat64(at: pos.cameraOffset + 16, value: view.cameraState.zoom)
            w.fillFloat64(at: pos.cameraOffset + 24, value: view.cameraState.rotation)

            w.fillUInt64(at: pos.offsetPos, value: dataOffset)
            w.fillUInt64(at: pos.sizePos, value: dataSize)
        }

        // 4. Fill header
        var data = w.build()
        data.replaceSubrange(0..<4, with: withUnsafeBytes(of: EABArchiveMagic.littleEndian) { Data($0) })
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: EABVersion.littleEndian) { Data($0) })
        data.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(views.count).littleEndian) { Data($0) })
        data.replaceSubrange(12..<20, with: withUnsafeBytes(of: directoryOffset.littleEndian) { Data($0) })

        return data
    }

    /// Serialize from save snapshots with progress tracking and cancellation.
    /// Reconstructs temporary CADDocuments from snapshots so it can reuse the
    /// existing V6 serialization logic. The tracker aggregates progress across
    /// all sections and all views.
    public static func serialize(snapshots: [SaveDocumentSnapshot],
                                  tracker: SaveProgressTracker) throws -> Data {
        try Task.checkCancellation()

        let w = BinaryWriter()
        tracker.attach(to: w)

        // 1. Reserve V7 Archive Header
        w.writeZeros(20)

        // 2. Directory table
        var directoryPositions: [(cameraOffset: Int, offsetPos: Int, sizePos: Int)] = []
        for snap in snapshots {
            w.writeString(snap.viewName)
            w.writeUInt8(snap.viewKind == .model ? 0 : 1)
            let cameraOffset = w.count
            w.writeZeros(32)
            let offsetPos = w.reserveUInt64()
            let sizePos = w.reserveUInt64()
            directoryPositions.append((cameraOffset: cameraOffset, offsetPos: offsetPos, sizePos: sizePos))
        }

        let directoryOffset = UInt64(20)

        // 3. Serialize each view
        for (i, snap) in snapshots.enumerated() {
            try Task.checkCancellation()

            let dataOffset = UInt64(w.count)
            // Reconstruct a temporary document from the snapshot
            let tempDoc = CADDocument()
            tempDoc.restore(from: snap.docSnapshot)
            // Inject image assets so the inner serializer can find them
            for (name, asset) in snap.imageAssets {
                tempDoc.imageStore[name] = asset
            }
            let v6Data = try serialize(document: tempDoc, tracker: tracker)
            tracker.finishSection(bytes: v6Data.count)
            w.writeBytes(v6Data)
            let dataSize = UInt64(v6Data.count)

            let pos = directoryPositions[i]
            w.fillFloat64(at: pos.cameraOffset, value: snap.cameraState.offsetX)
            w.fillFloat64(at: pos.cameraOffset + 8, value: snap.cameraState.offsetY)
            w.fillFloat64(at: pos.cameraOffset + 16, value: snap.cameraState.zoom)
            w.fillFloat64(at: pos.cameraOffset + 24, value: snap.cameraState.rotation)
            w.fillUInt64(at: pos.offsetPos, value: dataOffset)
            w.fillUInt64(at: pos.sizePos, value: dataSize)
        }

        try Task.checkCancellation()

        // 4. Fill header
        var data = w.build()
        data.replaceSubrange(0..<4, with: withUnsafeBytes(of: EABArchiveMagic.littleEndian) { Data($0) })
        data.replaceSubrange(4..<8, with: withUnsafeBytes(of: EABVersion.littleEndian) { Data($0) })
        data.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(snapshots.count).littleEndian) { Data($0) })
        data.replaceSubrange(12..<20, with: withUnsafeBytes(of: directoryOffset.littleEndian) { Data($0) })

        return data
    }


    /// Serialize a single CADDocument to in-memory Data (V6).
    public static func serialize(document: CADDocument) throws -> Data {
        return try serialize(document: document, tracker: nil)
    }

    /// Serialize with optional progress tracker for background saves.
    private static func serialize(document: CADDocument, tracker: SaveProgressTracker?) throws -> Data {
        let w = BinaryWriter()
        tracker?.attach(to: w)

        // 1. Reserve header (32 bytes)
        let headerOffset = w.count
        w.writeZeros(32)

        // 2. Build PVA data first (needed by blocks/entities sections for offsets)
        let (blockPVA, blockPVAOffsets, blockPVAByteCounts) = buildBlockPVA(document: document)
        let (entityPVA, entityPVAOffsets, entityPVAByteCounts) = buildEntityPVA(document: document)

        try Task.checkCancellation()

        // 3. Write sections in order, collecting entries
        var entries: [EABSectionEntry] = []

        // Metadata
        let metadataData = serializeMetadata(document: document)
        entries.append(EABSectionEntry(type: .metadata, offset: UInt64(w.count),
                                        size: UInt64(metadataData.count), compression: .none))
        w.writeBytes(metadataData)
        w.pad(to: 4)

        // Layers
        let layersData = serializeLayers(document: document)
        entries.append(EABSectionEntry(type: .layers, offset: UInt64(w.count),
                                        size: UInt64(layersData.count), compression: .none))
        w.writeBytes(layersData)
        w.pad(to: 4)

        // Blocks
        let blocksData = serializeBlocks(document: document,
                                          pvaOffsets: blockPVAOffsets,
                                          pvaByteCounts: blockPVAByteCounts)
        entries.append(EABSectionEntry(type: .blocks, offset: UInt64(w.count),
                                        size: UInt64(blocksData.count), compression: .none))
        w.writeBytes(blocksData)
        w.pad(to: 4)

        // Entities
        let entitiesData = serializeEntities(document: document,
                                              pvaOffsets: entityPVAOffsets,
                                              pvaByteCounts: entityPVAByteCounts)
        entries.append(EABSectionEntry(type: .entities, offset: UInt64(w.count),
                                        size: UInt64(entitiesData.count), compression: .none))
        w.writeBytes(entitiesData)
        w.pad(to: 4)
        tracker?.publishNow()  // force progress update after heaviest section

        // Constraints
        let constraintsData = serializeConstraints(document: document)
        entries.append(EABSectionEntry(type: .constraints, offset: UInt64(w.count),
                                        size: UInt64(constraintsData.count), compression: .none))
        w.writeBytes(constraintsData)
        w.pad(to: 4)

        // Solved transforms
        let solvedData = serializeSolvedTransforms(document: document)
        entries.append(EABSectionEntry(type: .solved, offset: UInt64(w.count),
                                        size: UInt64(solvedData.count), compression: .none))
        w.writeBytes(solvedData)
        w.pad(to: 4)

        // PVA Block section
        if !blockPVA.isEmpty {
            entries.append(EABSectionEntry(type: .pvaBlock, offset: UInt64(w.count),
                                            size: UInt64(blockPVA.count), compression: .none))
            // 16-byte align for GPU upload
            w.pad(to: 16)
            let newOffset = w.count
            // Update the entry offset after padding
            entries[entries.count - 1] = EABSectionEntry(
                type: .pvaBlock, offset: UInt64(newOffset),
                size: UInt64(blockPVA.count), compression: .none)
            w.writeBytes(blockPVA)
        }

        // PVA Entity section
        if !entityPVA.isEmpty {
            entries.append(EABSectionEntry(type: .pvaEntity, offset: UInt64(w.count),
                                            size: UInt64(entityPVA.count), compression: .none))
            w.pad(to: 16)
            let newOffset = w.count
            entries[entries.count - 1] = EABSectionEntry(
                type: .pvaEntity, offset: UInt64(newOffset),
                size: UInt64(entityPVA.count), compression: .none)
            w.writeBytes(entityPVA)
            tracker?.publishNow()  // PVA can be large
        }

        // BVH
        let bvhData = serializeBVH(document: document)
        entries.append(EABSectionEntry(type: .bvh, offset: UInt64(w.count),
                                        size: UInt64(bvhData.count), compression: .none))
        w.writeBytes(bvhData)
        w.pad(to: 4)

        // XData (document-level)
        let xdataData = serializeXData(document: document)
        entries.append(EABSectionEntry(type: .xdata, offset: UInt64(w.count),
                                        size: UInt64(xdataData.count), compression: .none))
        w.writeBytes(xdataData)
        w.pad(to: 4)

        // Text style fonts (added in EAB v4)
        if !document.textStyles.isEmpty {
            let textStylesData = serializeTextStyles(document: document)
            entries.append(EABSectionEntry(type: .textStyles, offset: UInt64(w.count),
                                            size: UInt64(textStylesData.count), compression: .none))
            w.writeBytes(textStylesData)
            w.pad(to: 4)
        }

        // Dimension styles
        if !document.dimensionStyles.isEmpty {
            let dimensionStylesData = serializeDimensionStyles(document: document)
            entries.append(EABSectionEntry(type: .dimensionStyles, offset: UInt64(w.count),
                                            size: UInt64(dimensionStylesData.count), compression: .none))
            w.writeBytes(dimensionStylesData)
            w.pad(to: 4)
        }

        // Linetype patterns (added in EAB v4)
        if !document.linetypePatterns.isEmpty {
            let lineTypesData = serializeLinetypePatterns(document: document)
            entries.append(EABSectionEntry(type: .lineTypes, offset: UInt64(w.count),
                                            size: UInt64(lineTypesData.count), compression: .none))
            w.writeBytes(lineTypesData)
            w.pad(to: 4)
        }

        // Image assets (added in EAB v5)
        if !document.imageStore.isEmpty {
            try Task.checkCancellation()
            let imagesData = serializeImageStore(document: document)
            entries.append(EABSectionEntry(type: .images, offset: UInt64(w.count),
                                            size: UInt64(imagesData.count), compression: .none))
            w.writeBytes(imagesData)
            w.pad(to: 4)
            tracker?.publishNow()  // images can be large
        }

        // 4. Write section table at end
        let tableOffset = UInt64(w.count)
        let tableData = serializeSectionTable(entries: entries)
        w.writeBytes(tableData)

        // 5. Build final data, fill header
        var data = w.build()
        let header = EABHeader(unit: document.unit, sectionTableOffset: tableOffset,
                               fileCRC: crc32(data[32...]))
        writeHeader(header, into: &data, at: headerOffset)

        tracker?.publishNow()  // ensure final progress is published

        return data
    }

    // MARK: - Header

    private static func writeHeader(_ h: EABHeader, into data: inout Data, at offset: Int) {
        data.replaceSubrange(offset..<offset+4,
            with: withUnsafeBytes(of: h.magic.littleEndian) { Data($0) })
        data.replaceSubrange(offset+4..<offset+8,
            with: withUnsafeBytes(of: h.version.littleEndian) { Data($0) })
        data.replaceSubrange(offset+8..<offset+12,
            with: withUnsafeBytes(of: h.flags.littleEndian) { Data($0) })
        data[offset + 12] = h.unit.rawValue
        // 3 reserved bytes at offset 13-15
        data.replaceSubrange(offset+16..<offset+24,
            with: withUnsafeBytes(of: h.sectionTableOffset.littleEndian) { Data($0) })
        data.replaceSubrange(offset+24..<offset+28,
            with: withUnsafeBytes(of: h.fileCRC.littleEndian) { Data($0) })
        // 4 reserved bytes at offset 28-31
    }

    // MARK: - Section Table

    private static func serializeSectionTable(entries: [EABSectionEntry]) -> Data {
        let w = BinaryWriter()
        w.writeUInt32(UInt32(entries.count))
        for e in entries {
            w.writeUInt32(e.type.rawValue)
            w.writeUInt64(e.offset)
            w.writeUInt64(e.size)
            w.writeUInt8(e.compression.rawValue)
            w.writeZeros(3)  // reserved
        }
        return w.build()
    }

    // MARK: - Metadata

    private static func serializeMetadata(document: CADDocument) -> Data {
        let w = BinaryWriter()
        w.writeFloat64(Date().timeIntervalSince1970)          // createdAt
        w.writeFloat64(Date().timeIntervalSince1970)          // modifiedAt
        w.writeString("")                                      // author
        // application name
        let appName = "Zephyr"
        w.writeUInt16(UInt16(appName.utf8.count))
        w.writeBytes(Data(appName.utf8))
        w.writeUInt32(1); w.writeUInt32(0); w.writeUInt32(0)  // version 1.0.0
        w.writeFloat64(0)                                      // constraintTimestamp
        // activeLayerID (added in EAB v4)
        w.writeUUID(document.activeLayerID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
        w.writeUInt32(0)                                       // custom byte count
        return w.build()
    }

    // MARK: - Layers

    private static func serializeLayers(document: CADDocument) -> Data {
        let w = BinaryWriter()
        let layers = document.allLayers
        w.writeUInt32(UInt32(layers.count))
        for layer in layers {
            w.writeUUID(layer.handle)
            w.writeString(layer.name)
            var flags: UInt8 = 0
            if layer.isVisible { flags |= 0x01 }
            // bit1=locked, bit2=frozen (unused for now)
            w.writeUInt8(flags)
            w.writeFloat32(Float(layer.lineWeight))
            // color as RGBA32
            let colorVal = UInt32(layer.color.r) << 24 | UInt32(layer.color.g) << 16
                | UInt32(layer.color.b) << 8 | UInt32(layer.color.a)
            w.writeUInt32(colorVal)
            // opacity (added in EAB v3)
            w.writeFloat64(layer.opacity)
            // lineType (added in EAB v4)
            w.writeString(layer.lineType)
            // Plot metadata (added in EAB v9)
            var plotFlags: UInt8 = layer.isPlottable ? 0x01 : 0
            if layer.plotStyleHandle != nil { plotFlags |= 0x02 }
            w.writeUInt8(plotFlags)
            if let plotStyleHandle = layer.plotStyleHandle {
                w.writeString(plotStyleHandle)
            }
        }
        return w.build()
    }

    // MARK: - Blocks

    private static func serializeBlocks(
        document: CADDocument,
        pvaOffsets: [UUID: UInt32],
        pvaByteCounts: [UUID: UInt32]
    ) -> Data {
        let w = BinaryWriter()
        let blocks = document.allBlocks
        w.writeUInt32(UInt32(blocks.count))
        for block in blocks {
            w.writeUUID(block.handle)
            w.writeString(block.name)
            w.writeUInt32(pvaOffsets[block.handle] ?? 0)
            w.writeUInt32(pvaByteCounts[block.handle] ?? 0)
            w.writeUInt32(0)  // vertexCount placeholder
            w.writeUInt32(0)  // indexCount placeholder
            // bbox
            w.writeFloat32(Float(block.localBoundingBox.min.x))
            w.writeFloat32(Float(block.localBoundingBox.min.y))
            w.writeFloat32(Float(block.localBoundingBox.min.z))
            w.writeFloat32(Float(block.localBoundingBox.max.x))
            w.writeFloat32(Float(block.localBoundingBox.max.y))
            w.writeFloat32(Float(block.localBoundingBox.max.z))
            // primitives (needed for round-tripping since PVA is lossy)
            serializePrimitives(block.geometry, to: w)
            // Per-primitive DXF styles retained for flattened blocks (EAB v9).
            serializePrimitiveStyles(block.primitiveStyles, to: w)
            w.writeInt32(Int32(clamping: block.dxfFlags))
            w.writeUInt8(block.isInternalTableDisplayBlock ? 1 : 0)
            serializePrimitiveXData(block.primitiveXData, geometryCount: block.geometry.count, to: w)
        }
        return w.build()
    }

    private static func serializePrimitiveXData(
        _ values: [Int: [String: XDataValue]],
        geometryCount: Int,
        to w: BinaryWriter
    ) {
        let valid = values.filter {
            $0.key >= 0 && $0.key < geometryCount && !$0.value.isEmpty
        }
        w.writeUInt32(UInt32(valid.count))
        for (index, xdata) in valid.sorted(by: { $0.key < $1.key }) {
            w.writeUInt32(UInt32(index))
            serializeXDataDict(xdata, to: w)
        }
    }

    private static func serializePrimitiveStyles(
        _ styles: [Int: CADPrimitiveStyle],
        to w: BinaryWriter
    ) {
        let validStyles = styles.filter { $0.key >= 0 }
        w.writeUInt32(UInt32(validStyles.count))
        for (index, style) in validStyles.sorted(by: { $0.key < $1.key }) {
            w.writeUInt32(UInt32(index))
            var flags: UInt16 = 0
            if style.layerName != nil { flags |= 1 << 0 }
            if style.color != nil { flags |= 1 << 1 }
            if style.isColorByBlock { flags |= 1 << 2 }
            if style.lineType != nil { flags |= 1 << 3 }
            if style.isLineTypeByBlock { flags |= 1 << 4 }
            if style.lineWeight != nil { flags |= 1 << 5 }
            if style.isLineWeightByBlock { flags |= 1 << 6 }
            if style.lineTypeScale != nil { flags |= 1 << 7 }
            if style.geomWidth != nil { flags |= 1 << 8 }
            if style.opacity != nil { flags |= 1 << 9 }
            if style.plotStyleHandle != nil { flags |= 1 << 10 }
            if style.textBackgroundScale != nil { flags |= 1 << 11 }
            if style.textBackgroundColor != nil { flags |= 1 << 12 }
            if style.textBackgroundUsesViewportColor { flags |= 1 << 13 }
            w.writeUInt16(flags)

            if let layerName = style.layerName { w.writeString(layerName) }
            if let color = style.color {
                let value = UInt32(color.r) << 24 | UInt32(color.g) << 16
                    | UInt32(color.b) << 8 | UInt32(color.a)
                w.writeUInt32(value)
            }
            if let lineType = style.lineType { w.writeString(lineType) }
            if let lineWeight = style.lineWeight { w.writeFloat64(lineWeight) }
            if let lineTypeScale = style.lineTypeScale { w.writeFloat64(lineTypeScale) }
            if let geomWidth = style.geomWidth { w.writeFloat64(geomWidth) }
            if let opacity = style.opacity { w.writeFloat64(opacity) }
            if let plotStyleHandle = style.plotStyleHandle { w.writeString(plotStyleHandle) }
            if let textBackgroundScale = style.textBackgroundScale { w.writeFloat64(textBackgroundScale) }
            if let textBackgroundColor = style.textBackgroundColor {
                let value = UInt32(textBackgroundColor.r) << 24
                    | UInt32(textBackgroundColor.g) << 16
                    | UInt32(textBackgroundColor.b) << 8
                    | UInt32(textBackgroundColor.a)
                w.writeUInt32(value)
            }
        }
    }

    // MARK: - Entities

    private static func serializeEntities(
        document: CADDocument,
        pvaOffsets: [UUID: UInt32],
        pvaByteCounts: [UUID: UInt32]
    ) -> Data {
        let w = BinaryWriter()
        let entities = document.allEntities
        w.writeUInt32(UInt32(entities.count))
        for entity in entities {
            w.writeUUID(entity.handle)
            w.writeUUID(entity.layerID)
            // blockHandle: nil → all-zeros UUID
            w.writeUUID(entity.blockID ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
            // transform: 16 f64
            writeTransform(entity.transform, to: w)
            // flags
            var flags: UInt8 = 0
            if !entity.xdata.isEmpty { flags |= 0x01 }
            if entity.localGeometry != nil && !(entity.localGeometry?.isEmpty ?? true) {
                flags |= 0x02
            }
            // Always set drawOrder flag (0x04) — every entity has a drawOrder property.
            flags |= 0x04
            if entity.dimensionMetadata != nil { flags |= 0x08 }
            if entity.arrayData != nil { flags |= 0x10 }
            w.writeUInt8(flags)
            // bbox (local-space)
            if let bb = entity.localBoundingBox {
                w.writeFloat32(Float(bb.min.x))
                w.writeFloat32(Float(bb.min.y))
                w.writeFloat32(Float(bb.min.z))
                w.writeFloat32(Float(bb.max.x))
                w.writeFloat32(Float(bb.max.y))
                w.writeFloat32(Float(bb.max.z))
            } else {
                for _ in 0..<6 { w.writeFloat32(0) }
            }
            // local geometry PVA + primitives
            if flags & 0x02 != 0 {
                w.writeUInt32(pvaOffsets[entity.handle] ?? 0)
                w.writeUInt32(pvaByteCounts[entity.handle] ?? 0)
                w.writeUInt32(0)  // vertexCount placeholder
                serializePrimitives(entity.localGeometry ?? [], to: w)
            }
            // xdata
            if flags & 0x01 != 0 {
                serializeXDataDict(entity.xdata, to: w)
            }
            // drawOrder (v6+, flag 0x04)
            w.writeInt32(Int32(clamping: entity.drawOrder))
            // dimensionMetadata
            if flags & 0x08 != 0, let dim = entity.dimensionMetadata?.value {
                serializeDimensionMetadata(dim, to: w)
            }
            if flags & 0x10 != 0, let array = entity.arrayData {
                let data = (try? JSONEncoder().encode(array)) ?? Data()
                w.writeUInt32(UInt32(data.count))
                w.writeBytes(data)
            }
        }
        return w.build()
    }



    private static func serializeDimensionMetadata(_ dim: CADDimensionMetadata, to w: BinaryWriter) {
        let styleBytes = Data(dim.styleName.utf8)
        w.writeUInt32(UInt32(styleBytes.count))
        w.writeBytes(styleBytes)
        
        w.writeInt32(Int32(dim.type.rawValue))
        w.writeFloat64(dim.measurement)
        
        w.writeFloat64(dim.defPoint.x)
        w.writeFloat64(dim.defPoint.y)
        w.writeFloat64(dim.defPoint.z)
        
        w.writeFloat64(dim.defPoint2.x)
        w.writeFloat64(dim.defPoint2.y)
        w.writeFloat64(dim.defPoint2.z)
        
        if let dp3 = dim.defPoint3 {
            w.writeUInt8(1)
            w.writeFloat64(dp3.x)
            w.writeFloat64(dp3.y)
            w.writeFloat64(dp3.z)
        } else {
            w.writeUInt8(0)
        }
        
        w.writeFloat64(dim.textMidpoint.x)
        w.writeFloat64(dim.textMidpoint.y)
        w.writeFloat64(dim.textMidpoint.z)
        
        if let override = dim.textOverride {
            let ovBytes = Data(override.utf8)
            w.writeUInt32(UInt32(ovBytes.count))
            w.writeBytes(ovBytes)
        } else {
            w.writeUInt32(0)
        }
        
        w.writeFloat64(dim.rotationAngle)
        w.writeInt32(Int32(dim.flags))
    }

    /// Write the raw 16 f64 matrix elements in row-major order.
    /// This preserves the full affine transform without the sign loss inherent in
    /// decomposing via `position` / `scale` / `rotation` (the latter returns
    /// column-vector *magnitudes*, which drop negative scale signs from mirrored
    /// DXF INSERTs).  The reader (`readTransform`) reads back the same raw values.
    private static func writeTransform(_ t: Transform3D, to w: BinaryWriter) {
        for element in t.rawElements {
            w.writeFloat64(element)
        }
    }

    // MARK: - Constraints

    private static func serializeConstraints(document: CADDocument) -> Data {
        let w = BinaryWriter()
        let constraints = document.allConstraints
        w.writeUInt32(UInt32(constraints.count))
        for c in constraints {
            w.writeUUID(c.handle)
            w.writeUInt8(c.type.rawValue)
            w.writeUUID(c.entityA)
            w.writeUUID(c.entityB ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
            w.writeUInt8(c.subEntityA.rawValue)
            w.writeUInt8(c.subIndexA)
            w.writeUInt8(c.subEntityB.rawValue)
            w.writeUInt8(c.subIndexB)
            w.writeUInt8(UInt8(c.params.count))
            for p in c.params { w.writeFloat64(p) }
            var flags: UInt8 = 0
            if c.isEnabled { flags |= 0x01 }
            if c.isDriven { flags |= 0x02 }
            w.writeUInt8(flags)
        }
        return w.build()
    }

    // MARK: - Solved Transforms

    private static func serializeSolvedTransforms(document: CADDocument) -> Data {
        let w = BinaryWriter()
        w.writeUInt32(UInt32(document.solvedTransforms.count))
        for (handle, transform) in document.solvedTransforms {
            w.writeUUID(handle)
            writeTransform(transform, to: w)
            // bbox placeholder (world-space bbox after solve)
            for _ in 0..<6 { w.writeFloat32(0) }
        }
        return w.build()
    }

    // MARK: - PVA Builders

    /// Build packed vertex array for all block geometries.
    /// Returns: (combinedPVA, [blockHandle: offset], [blockHandle: byteCount])
    private static func buildBlockPVA(document: CADDocument) -> (Data, [UUID: UInt32], [UUID: UInt32]) {
        var pvaData = Data()
        var offsets: [UUID: UInt32] = [:]
        var byteCounts: [UUID: UInt32] = [:]

        for block in document.allBlocks {
            offsets[block.handle] = UInt32(pvaData.count)
            let blockVertices = blockGeometryToPVA(block.geometry)
            var blockBytes = Data()
            for v in blockVertices {
                blockBytes.append(contentsOf: pvaVertexToBytes(v))
            }
            pvaData.append(blockBytes)
            byteCounts[block.handle] = UInt32(blockBytes.count)
        }
        return (pvaData, offsets, byteCounts)
    }

    /// Build packed vertex array for entity local geometries.
    private static func buildEntityPVA(document: CADDocument) -> (Data, [UUID: UInt32], [UUID: UInt32]) {
        var pvaData = Data()
        var offsets: [UUID: UInt32] = [:]
        var byteCounts: [UUID: UInt32] = [:]

        for entity in document.allEntities {
            guard let geom = entity.localGeometry, !geom.isEmpty else { continue }
            offsets[entity.handle] = UInt32(pvaData.count)
            let verts = blockGeometryToPVA(geom)
            var bytes = Data()
            for v in verts { bytes.append(contentsOf: pvaVertexToBytes(v)) }
            pvaData.append(bytes)
            byteCounts[entity.handle] = UInt32(bytes.count)
        }
        return (pvaData, offsets, byteCounts)
    }

    /// Convert CADPrimitive array to packed vertices (line-strip style).
    private static func blockGeometryToPVA(_ primitives: [CADPrimitive]) -> [PVAVertex] {
        var verts: [PVAVertex] = []
        for p in primitives {
            switch p {
            case .point(let pos, let color):
                let c = color ?? .white
                verts.append(PVAVertex(position: pos, color: c))
            case .line(let start, let end, let color):
                let c = color ?? .white
                verts.append(PVAVertex(position: start, color: c))
                verts.append(PVAVertex(position: end, color: c))
            case .rect(let origin, let size, let color), .fillRect(let origin, let size, let color):
                let c = color ?? .white
                verts.append(PVAVertex(position: origin, color: c))
                verts.append(PVAVertex(position: Vector3(x: origin.x + size.x, y: origin.y, z: origin.z), color: c))
                verts.append(PVAVertex(position: Vector3(x: origin.x + size.x, y: origin.y + size.y, z: origin.z), color: c))
                verts.append(PVAVertex(position: Vector3(x: origin.x, y: origin.y + size.y, z: origin.z), color: c))
            case .polygon(let points, let color), .fillPolygon(let points, let color):
                let c = color ?? .white
                for pt in points { verts.append(PVAVertex(position: pt, color: c)) }
            case .polyline(let path, let color):
                let c = color ?? .white
                for point in path.tessellatedPoints() {
                    verts.append(PVAVertex(position: point, color: c))
                }
            case .fillComplexPolygon(let outer, let holes, let color):
                let c = color ?? .white
                for pt in outer { verts.append(PVAVertex(position: pt, color: c)) }
                for hole in holes {
                    for pt in hole { verts.append(PVAVertex(position: pt, color: c)) }
                }
            case .gradient(let outer, let holes, _, _, let color1, _):
                let c = color1
                for pt in outer { verts.append(PVAVertex(position: pt, color: c)) }
                for hole in holes {
                    for pt in hole { verts.append(PVAVertex(position: pt, color: c)) }
                }
            case .circle(let center, let radius, let color):
                let c = color ?? .white
                let segments = 32
                for i in 0...segments {
                    let a = Double(i) * 2.0 * .pi / Double(segments)
                    verts.append(PVAVertex(position: Vector3(
                        x: center.x + cos(a) * radius,
                        y: center.y + sin(a) * radius, z: center.z), color: c))
                }
            case .arc(let center, let radius, let startAngle, let endAngle, let color):
                let c = color ?? .white
                let segments = 16
                let span = endAngle - startAngle
                for i in 0...segments {
                    let a = startAngle + Double(i) * span / Double(segments)
                    verts.append(PVAVertex(position: Vector3(
                        x: center.x + cos(a) * radius,
                        y: center.y + sin(a) * radius, z: center.z), color: c))
                }
            case .text(let pos, _, _, _, _, _, _, _, let color):
                let c = color ?? .white
                verts.append(PVAVertex(position: pos, color: c))
            case .spline(let controlPoints, let knots, let degree, let weights, let color):
                let c = color ?? .white
                let w = weights ?? Array(repeating: 1.0, count: controlPoints.count)
                let evaluated = NURBSEvaluator.evaluateByKnotSpans(
                    degree: degree, knots: knots,
                    controlPoints: controlPoints, weights: w, segmentsPerSpan: 12)
                for pt in evaluated {
                    verts.append(PVAVertex(position: pt, color: c))
                }
            case .ellipse(let center, let majorAxis, let minorRatio, let color):
                let c = color ?? .white
                let segments = 64
                let majorLen = majorAxis.magnitude
                let minorLen = majorLen * minorRatio
                let rot = atan2(majorAxis.y, majorAxis.x)
                for i in 0...segments {
                    let t = Double(i) * 2.0 * .pi / Double(segments)
                    verts.append(PVAVertex(position: Vector3(
                        x: center.x + cos(t) * majorLen * cos(rot) - sin(t) * minorLen * sin(rot),
                        y: center.y + cos(t) * majorLen * sin(rot) + sin(t) * minorLen * cos(rot),
                        z: center.z), color: c))
                }
            case .hatch(let boundary, _, _, _, let color, _):
                let c = color ?? .white
                for pt in boundary { verts.append(PVAVertex(position: pt, color: c)) }
            case .hatchPath(let boundary, let holes, _, _, _, let color, _):
                let c = color ?? .white
                for pt in boundary.boundingPoints() { verts.append(PVAVertex(position: pt, color: c)) }
                for hole in holes { for pt in hole.boundingPoints() { verts.append(PVAVertex(position: pt, color: c)) } }
            case .ray(let start, let direction, let color):
                let c = color ?? .white
                verts.append(PVAVertex(position: start, color: c))
                verts.append(PVAVertex(position: Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z), color: c))
            case .image:
                // Images are not converted to PVA vertices
                break
            case .table: break
            }
        }
        return verts
    }

    /// Convert a PVAVertex to its 56-byte on-disk representation.
    private static func pvaVertexToBytes(_ v: PVAVertex) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(PVAVertex.stride)
        // position
        bytes.append(contentsOf: withUnsafeBytes(of: v.px) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: v.py) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: v.pz) { Array($0) })
        // normal
        bytes.append(contentsOf: withUnsafeBytes(of: v.nx) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: v.ny) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: v.nz) { Array($0) })
        // texCoord
        bytes.append(contentsOf: withUnsafeBytes(of: v.u) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: v.v) { Array($0) })
        // color
        bytes.append(v.r); bytes.append(v.g); bytes.append(v.b); bytes.append(v.a)
        // padding to 56
        while bytes.count < PVAVertex.stride { bytes.append(0) }
        return bytes
    }

    // MARK: - BVH

    private static func serializeBVH(document: CADDocument) -> Data {
        // Build items from both entities and blocks
        var items: [BVHBuilder.BuildItem] = []
        for (i, entity) in document.allEntities.enumerated() {
            if let wbb = entity.worldBoundingBox {
                items.append(BVHBuilder.BuildItem(
                    bbox: wbb, entityIndex: UInt32(i), blockIndex: .max))
            }
        }
        for (i, block) in document.allBlocks.enumerated() {
            items.append(BVHBuilder.BuildItem(
                bbox: block.localBoundingBox, entityIndex: .max, blockIndex: UInt32(i)))
        }

        // Limit items to avoid excessive recursion depth in BVH builder.
        // Large datasets can overflow the stack with the recursive midpoint-split.
        let maxBVHItems = 10000
        let tree: BVHTree
        if items.count > maxBVHItems {
            // For very large datasets, produce a degenerate single-node tree
            // that includes everything (no spatial filtering benefit, but safe).
            tree = BVHTree()
        } else if items.isEmpty {
            tree = BVHTree()
        } else {
            tree = BVHBuilder.build(from: items)
        }
        let w = BinaryWriter()

        // Write entity index array
        w.writeUInt32(UInt32(tree.entityIndices.count))
        for idx in tree.entityIndices { w.writeUInt32(idx) }

        // Write block index array
        w.writeUInt32(UInt32(tree.blockIndices.count))
        for idx in tree.blockIndices { w.writeUInt32(idx) }

        // Write BVH nodes
        w.writeUInt32(UInt32(tree.nodes.count))
        for node in tree.nodes {
            w.writeUInt8(node.flags)
            w.writeUInt8(node.splitAxis)
            w.writeUInt8(node.childCount)
            w.writeZeros(1)  // alignment pad
            w.writeUInt32(node.firstChildOrPrimitive)
            w.writeUInt32(node.primitiveCount)
            w.writeFloat32(node.bboxMin.0)
            w.writeFloat32(node.bboxMin.1)
            w.writeFloat32(node.bboxMin.2)
            w.writeFloat32(node.bboxMax.0)
            w.writeFloat32(node.bboxMax.1)
            w.writeFloat32(node.bboxMax.2)
        }
        return w.build()
    }

    // MARK: - XData

    private static func serializeXData(document: CADDocument) -> Data {
        let w = BinaryWriter()
        // For document-level xdata (currently empty — placeholder for future use)
        w.writeUInt32(0)
        return w.build()
    }

    private static func serializeXDataDict(_ dict: [String: XDataValue], to w: BinaryWriter) {
        w.writeUInt16(UInt16(dict.count))
        for (key, value) in dict {
            w.writeUInt8(UInt8(key.utf8.count))
            w.writeBytes(Data(key.utf8))
            switch value {
            case .string(let s):
                w.writeUInt8(0)
                w.writeString(s)
            case .double(let d):
                w.writeUInt8(1)
                w.writeFloat64(d)
            case .int(let i):
                w.writeUInt8(2)
                w.writeUInt64(UInt64(bitPattern: Int64(i)))
            case .bool(let b):
                w.writeUInt8(3)
                w.writeUInt8(b ? 1 : 0)
            case .date(let d):
                w.writeUInt8(4)
                w.writeFloat64(d.timeIntervalSince1970)
            }
        }
    }

    // MARK: - Text Style Fonts

    private static func serializeTextStyles(document: CADDocument) -> Data {
        let w = BinaryWriter()
        let styles = document.textStyles.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        w.writeUInt32(UInt32(styles.count))
        for style in styles {
            let normalized = style.normalized
            w.writeString(normalized.name)
            w.writeString(normalized.fontFile)
            w.writeFloat64(normalized.fixedHeight)
            w.writeFloat64(normalized.widthFactor)
            w.writeFloat64(normalized.obliqueAngle)
            w.writeUInt8(normalized.isAnnotative ? 1 : 0)
        }
        return w.build()
    }

    // MARK: - Dimension Styles

    private static func serializeDimensionStyles(document: CADDocument) -> Data {
        let w = BinaryWriter()
        w.writeUInt32(UInt32(document.dimensionStyles.count))
        let encoder = JSONEncoder()
        for (styleName, style) in document.dimensionStyles {
            w.writeString(styleName)
            if let data = try? encoder.encode(style), let str = String(data: data, encoding: .utf8) {
                w.writeString(str)
            } else {
                w.writeString("{}")
            }
        }
        return w.build()
    }

    // MARK: - Linetype Patterns

    private static func serializeLinetypePatterns(document: CADDocument) -> Data {
        let w = BinaryWriter()
        w.writeUInt32(UInt32(document.linetypePatterns.count))
        for (name, pattern) in document.linetypePatterns {
            w.writeString(name)
            w.writeUInt32(UInt32(pattern.count))
            for value in pattern {
                w.writeFloat64(value)
            }
        }
        return w.build()
    }

    // MARK: - Image Store

    private static func serializeImageStore(document: CADDocument) -> Data {
        let w = BinaryWriter()
        let assets = document.imageStore.values
        // Only save referenced images (those in entity/block geometries)
        var referenced = Set<String>()
        for entity in document.allEntities {
            if let geom = entity.localGeometry {
                for prim in geom {
                    if case .image(_, _, _, let name, _, _) = prim {
                        referenced.insert(name)
                    }
                }
            }
        }
        for block in document.allBlocks {
            for prim in block.geometry {
                if case .image(_, _, _, let name, _, _) = prim {
                    referenced.insert(name)
                }
            }
        }
        let filtered = assets.filter { referenced.contains($0.name) }
        w.writeUInt32(UInt32(filtered.count))
        for asset in filtered {
            w.writeString(asset.name)
            w.writeString(asset.originalFilename)
            w.writeString(asset.mimeType)
            w.writeUInt32(UInt32(asset.pixelWidth))
            w.writeUInt32(UInt32(asset.pixelHeight))
            w.writeString(asset.sha256)
            w.writeUInt64(UInt64(asset.data.count))
            w.writeBytes(asset.data)
        }
        return w.build()
    }

    // MARK: - CRC32 (zlib-ng native)

    private static func crc32(_ data: Data) -> UInt32 {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return UInt32(0) }
            return UInt32(zng_crc32(0, base, UInt32(raw.count)))
        }
    }

    // MARK: - CADPrimitive Serialization

    /// Serialize CADPrimitives inline into the block/entity record.
    /// PVA is lossy (raw vertices), so we also store the original primitives for round-tripping.
    private static func serializePrimitives(_ primitives: [CADPrimitive], to w: BinaryWriter) {
        w.writeUInt32(UInt32(primitives.count))
        for p in primitives {
            // Helper to write optional color
            let writeColor = { (color: ColorRGBA?) in
                if let c = color {
                    w.writeUInt8(1)
                    w.writeUInt8(c.r); w.writeUInt8(c.g); w.writeUInt8(c.b); w.writeUInt8(c.a)
                } else {
                    w.writeUInt8(0)
                }
            }
            let writeHatchPathMetadata = { (path: CADPolyline) in
                w.writeUInt8(path.isHatchBoundaryCarrier ? 1 : 0)
                w.writeInt32(Int32(path.hatchLoopType ?? -1))
                w.writeUInt32(UInt32(path.hatchEdges.count))
                for edge in path.hatchEdges {
                    switch edge {
                    case .line(let start, let end):
                        w.writeUInt8(0)
                        for point in [start, end] {
                            w.writeFloat64(point.x); w.writeFloat64(point.y); w.writeFloat64(point.z)
                        }
                    case .circularArc(let center, let radius, let startAngle, let sweep):
                        w.writeUInt8(1)
                        w.writeFloat64(center.x); w.writeFloat64(center.y); w.writeFloat64(center.z)
                        w.writeFloat64(radius); w.writeFloat64(startAngle); w.writeFloat64(sweep)
                    case .ellipticalArc(let center, let axisU, let axisV, let startParam, let sweep):
                        w.writeUInt8(2)
                        for point in [center, axisU, axisV] {
                            w.writeFloat64(point.x); w.writeFloat64(point.y); w.writeFloat64(point.z)
                        }
                        w.writeFloat64(startParam); w.writeFloat64(sweep)
                    case .spline(let controlPoints, let knots, let degree, let weights, let closed, let periodic):
                        w.writeUInt8(3)
                        w.writeUInt32(UInt32(degree))
                        w.writeUInt8(closed ? 1 : 0)
                        w.writeUInt8(periodic ? 1 : 0)
                        w.writeUInt32(UInt32(controlPoints.count))
                        for point in controlPoints {
                            w.writeFloat64(point.x); w.writeFloat64(point.y); w.writeFloat64(point.z)
                        }
                        w.writeUInt32(UInt32(knots.count))
                        for knot in knots { w.writeFloat64(knot) }
                        w.writeUInt8(weights == nil ? 0 : 1)
                        if let weights {
                            w.writeUInt32(UInt32(weights.count))
                            for weight in weights { w.writeFloat64(weight) }
                        }
                    }
                }
            }

            // type byte: 0=point, 1=line, 2=rect, 3=fillRect, 4=polygon,
            // 5=circle, 6=arc, 7=fillPolygon, 8=text, 9=fillComplexPolygon,
            // 10=gradient, 11=spline, 12=ellipse, 13=hatch, 14=ray,
            // 15=legacy straight polyline, 16=image, 18=bulge-aware polyline
            switch p {
            case .point(let pos, let color):
                w.writeUInt8(0)
                w.writeFloat64(pos.x); w.writeFloat64(pos.y); w.writeFloat64(pos.z)
                writeColor(color)
            case .line(let start, let end, let color):
                w.writeUInt8(1)
                w.writeFloat64(start.x); w.writeFloat64(start.y); w.writeFloat64(start.z)
                w.writeFloat64(end.x);   w.writeFloat64(end.y);   w.writeFloat64(end.z)
                writeColor(color)
            case .rect(let origin, let size, let color):
                w.writeUInt8(2)
                w.writeFloat64(origin.x); w.writeFloat64(origin.y); w.writeFloat64(origin.z)
                w.writeFloat64(size.x);   w.writeFloat64(size.y)
                writeColor(color)
            case .fillRect(let origin, let size, let color):
                w.writeUInt8(3)
                w.writeFloat64(origin.x); w.writeFloat64(origin.y); w.writeFloat64(origin.z)
                w.writeFloat64(size.x);   w.writeFloat64(size.y)
                writeColor(color)
            case .polygon(let points, let color):
                w.writeUInt8(4)
                w.writeUInt32(UInt32(points.count))
                for pt in points {
                    w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                }
                writeColor(color)
            case .polyline(let path, let color):
                w.writeUInt8(18)
                w.writeUInt8(path.isClosed ? 1 : 0)
                w.writeUInt8(path.lineTypeGenerationEnabled ? 1 : 0)
                w.writeUInt32(UInt32(path.vertices.count))
                for vertex in path.vertices {
                    let point = vertex.position
                    w.writeFloat64(point.x); w.writeFloat64(point.y); w.writeFloat64(point.z)
                    w.writeFloat64(vertex.bulge)
                    w.writeFloat64(vertex.startWidth)
                    w.writeFloat64(vertex.endWidth)
                }
                writeHatchPathMetadata(path)
                writeColor(color)
            case .fillPolygon(let points, let color):
                w.writeUInt8(7)
                w.writeUInt32(UInt32(points.count))
                for pt in points {
                    w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                }
                writeColor(color)
            case .fillComplexPolygon(let outer, let holes, let color):
                w.writeUInt8(9)
                w.writeUInt32(UInt32(outer.count))
                for pt in outer {
                    w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                }
                w.writeUInt32(UInt32(holes.count))
                for hole in holes {
                    w.writeUInt32(UInt32(hole.count))
                    for pt in hole {
                        w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                    }
                }
                writeColor(color)
            case .circle(let center, let radius, let color):
                w.writeUInt8(5)
                w.writeFloat64(center.x); w.writeFloat64(center.y); w.writeFloat64(center.z)
                w.writeFloat64(radius)
                writeColor(color)
            case .arc(let center, let radius, let startAngle, let endAngle, let color):
                w.writeUInt8(6)
                w.writeFloat64(center.x); w.writeFloat64(center.y); w.writeFloat64(center.z)
                w.writeFloat64(radius)
                w.writeFloat64(startAngle); w.writeFloat64(endAngle)
                writeColor(color)
            case .spline(let controlPoints, let knots, let degree, let weights, let color):
                w.writeUInt8(11)
                w.writeUInt32(UInt32(controlPoints.count))
                for cp in controlPoints {
                    w.writeFloat64(cp.x); w.writeFloat64(cp.y); w.writeFloat64(cp.z)
                }
                w.writeUInt32(UInt32(knots.count))
                for k in knots { w.writeFloat64(k) }
                w.writeUInt32(UInt32(degree))
                let hasWeights = weights != nil
                w.writeUInt8(hasWeights ? 1 : 0)
                if let splineWeights = weights {
                    for weight in splineWeights { w.writeFloat64(weight) }
                }
                writeColor(color)
            case .gradient(let outer, let holes, let name, let angle, let color1, let color2):
                w.writeUInt8(10)
                w.writeUInt32(UInt32(outer.count))
                for pt in outer {
                    w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                }
                w.writeUInt32(UInt32(holes.count))
                for hole in holes {
                    w.writeUInt32(UInt32(hole.count))
                    for pt in hole {
                        w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                    }
                }
                w.writeString(name)
                w.writeFloat64(angle)
                writeColor(color1)
                writeColor(color2)
            case .text(let pos, let text, let height, let rotation, let style, let alignH, let alignV, let mtextWidth, let color):
                w.writeUInt8(8)
                w.writeFloat64(pos.x); w.writeFloat64(pos.y); w.writeFloat64(pos.z)
                w.writeString(text)
                w.writeFloat64(height)
                w.writeFloat64(rotation)
                w.writeString(style ?? "")
                w.writeUInt32(UInt32(alignH))
                w.writeUInt32(UInt32(alignV))
                w.writeFloat64(mtextWidth ?? -1.0)
                writeColor(color)
            case .ellipse(let center, let majorAxis, let minorRatio, let color):
                w.writeUInt8(12)
                w.writeFloat64(center.x); w.writeFloat64(center.y); w.writeFloat64(center.z)
                w.writeFloat64(majorAxis.x); w.writeFloat64(majorAxis.y); w.writeFloat64(majorAxis.z)
                w.writeFloat64(minorRatio)
                writeColor(color)
            case .hatch(let boundary, let pattern, let scale, let angle, let color, _):
                w.writeUInt8(13)
                w.writeUInt32(UInt32(boundary.count))
                for pt in boundary {
                    w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                }
                w.writeString(pattern)
                w.writeFloat64(scale)
                w.writeFloat64(angle)
                writeColor(color)
            case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let color, let backgroundColor):
                func writePath(_ path: CADPolyline) {
                    w.writeUInt32(UInt32(path.vertices.count))
                    w.writeUInt8(path.isClosed ? 1 : 0)
                    w.writeUInt8(path.lineTypeGenerationEnabled ? 1 : 0)
                    for vertex in path.vertices {
                        w.writeFloat64(vertex.position.x); w.writeFloat64(vertex.position.y); w.writeFloat64(vertex.position.z)
                        w.writeFloat64(vertex.bulge)
                        w.writeFloat64(vertex.startWidth)
                        w.writeFloat64(vertex.endWidth)
                    }
                    writeHatchPathMetadata(path)
                }
                w.writeUInt8(19)
                writePath(boundary)
                w.writeUInt32(UInt32(holes.count))
                for hole in holes { writePath(hole) }
                w.writeString(pattern)
                w.writeFloat64(scale)
                w.writeFloat64(angle)
                writeColor(color)
                writeColor(backgroundColor)
            case .ray(let start, let direction, let color):
                w.writeUInt8(14)
                w.writeFloat64(start.x); w.writeFloat64(start.y); w.writeFloat64(start.z)
                w.writeFloat64(direction.x); w.writeFloat64(direction.y); w.writeFloat64(direction.z)
                writeColor(color)
            case .image(let insertion, let uAxis, let vAxis, let imageName, let clipBoundary, let tint):
                w.writeUInt8(16)
                w.writeFloat64(insertion.x); w.writeFloat64(insertion.y); w.writeFloat64(insertion.z)
                w.writeFloat64(uAxis.x); w.writeFloat64(uAxis.y); w.writeFloat64(uAxis.z)
                w.writeFloat64(vAxis.x); w.writeFloat64(vAxis.y); w.writeFloat64(vAxis.z)
                w.writeString(imageName)
                if let clip = clipBoundary {
                    w.writeUInt32(UInt32(clip.count))
                    for pt in clip {
                        w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                    }
                } else {
                    w.writeUInt32(0)
                }
                if let t = tint {
                    w.writeUInt8(1)
                    w.writeUInt8(t.r); w.writeUInt8(t.g); w.writeUInt8(t.b); w.writeUInt8(t.a)
                } else {
                    w.writeUInt8(0)
                }
            case .table(let data, let origin, let color):
                w.writeUInt8(17)
                w.writeFloat64(origin.x); w.writeFloat64(origin.y); w.writeFloat64(origin.z)
                // Encode DataTableData as JSON string for simplicity
                let encoder = JSONEncoder()
                if let jsonData = try? encoder.encode(data),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    w.writeString(jsonStr)
                } else {
                    w.writeString("{}")
                }
                if let c = color {
                    w.writeUInt8(1)
                    w.writeUInt8(c.r); w.writeUInt8(c.g); w.writeUInt8(c.b); w.writeUInt8(c.a)
                } else {
                    w.writeUInt8(0)
                }
            }
        }
    }
}