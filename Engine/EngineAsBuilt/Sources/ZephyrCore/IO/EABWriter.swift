import Foundation

// =========================================================================
// MARK: - EABWriter
//
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

    // MARK: - Public API

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

    // MARK: - Serialization

    /// Serialize multiple views to in-memory Data (V7 Archive).
    public static func serialize(views: [DrawingView]) throws -> Data {
        let w = BinaryWriter()

        // 1. Reserve V7 Archive Header (16 bytes)
        w.writeZeros(16)

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

        let directoryOffset = UInt64(16) // immediately follows header

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

    /// Serialize a single CADDocument to in-memory Data (V6).
    public static func serialize(document: CADDocument) throws -> Data {
        let w = BinaryWriter()

        // 1. Reserve header (32 bytes)
        let headerOffset = w.count
        w.writeZeros(32)

        // 2. Build PVA data first (needed by blocks/entities sections for offsets)
        let (blockPVA, blockPVAOffsets, blockPVAByteCounts) = buildBlockPVA(document: document)
        let (entityPVA, entityPVAOffsets, entityPVAByteCounts) = buildEntityPVA(document: document)

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
        if !document.textStyleFonts.isEmpty {
            let textStylesData = serializeTextStyleFonts(document: document)
            entries.append(EABSectionEntry(type: .textStyles, offset: UInt64(w.count),
                                            size: UInt64(textStylesData.count), compression: .none))
            w.writeBytes(textStylesData)
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
            let imagesData = serializeImageStore(document: document)
            entries.append(EABSectionEntry(type: .images, offset: UInt64(w.count),
                                            size: UInt64(imagesData.count), compression: .none))
            w.writeBytes(imagesData)
            w.pad(to: 4)
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
        }
        return w.build()
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
            w.writeInt32(Int32(entity.drawOrder))
        }
        return w.build()
    }

    private static func writeTransform(_ t: Transform3D, to w: BinaryWriter) {
        // Write 16 f64 values (row-major). We can't easily iterate the tuple,
        // so extract via position/scale/rotation + manually.
        // Simpler: serialize via withUnsafeBytes of the Transform3D.
        // But Transform3D uses a private tuple — we serialize the known fields.
        // Actually, let's use the raw initializer path by round-tripping through
        // a reconstruction. Better: expose a raw property on Transform3D.
        // For now, write identity if we can't get the internal representation.
        // WORKAROUND: serialize known components
        let pos = t.position
        let scl = t.scale
        let rot = t.rotation
        // Reconstruct matrix from position, scale, rotation
        let c = cos(rot)
        let sn = sin(rot)
        w.writeFloat64(c * scl.x)    // m00
        w.writeFloat64(-sn * scl.y)   // m01
        w.writeFloat64(0)             // m02
        w.writeFloat64(pos.x)         // m03
        w.writeFloat64(sn * scl.x)    // m10
        w.writeFloat64(c * scl.y)     // m11
        w.writeFloat64(0)             // m12
        w.writeFloat64(pos.y)         // m13
        w.writeFloat64(0)             // m20
        w.writeFloat64(0)             // m21
        w.writeFloat64(scl.z)         // m22
        w.writeFloat64(pos.z)         // m23
        w.writeFloat64(0)             // m30
        w.writeFloat64(0)             // m31
        w.writeFloat64(0)             // m32
        w.writeFloat64(1)             // m33
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
            case .polygon(let points, let color), .fillPolygon(let points, let color), .polyline(let points, let color):
                let c = color ?? .white
                for pt in points { verts.append(PVAVertex(position: pt, color: c)) }
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
                let evaluated = NURBSEvaluator.evaluate(
                    degree: degree, knots: knots,
                    controlPoints: controlPoints, weights: w, segments: 48)
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
            case .hatch(let boundary, _, _, _, let color):
                let c = color ?? .white
                for pt in boundary { verts.append(PVAVertex(position: pt, color: c)) }
            case .ray(let start, let direction, let color):
                let c = color ?? .white
                verts.append(PVAVertex(position: start, color: c))
                verts.append(PVAVertex(position: Vector3(x: start.x + direction.x, y: start.y + direction.y, z: start.z), color: c))
            case .image:
                // Images are not converted to PVA vertices
                break
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

    private static func serializeTextStyleFonts(document: CADDocument) -> Data {
        let w = BinaryWriter()
        w.writeUInt32(UInt32(document.textStyleFonts.count))
        for (styleName, fontFile) in document.textStyleFonts {
            w.writeString(styleName)
            w.writeString(fontFile)
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

    // MARK: - CRC32

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if (crc & 1) != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return ~crc
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

            // type byte: 0=point,1=line,2=rect,3=fillRect,4=polygon,5=circle,6=arc,7=fillPolygon,8=text,9=fillComplexPolygon,10=gradient,11=spline
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
            case .polyline(let points, let color):
                w.writeUInt8(15)
                w.writeUInt32(UInt32(points.count))
                for pt in points {
                    w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                }
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
            case .hatch(let boundary, let pattern, let scale, let angle, let color):
                w.writeUInt8(13)
                w.writeUInt32(UInt32(boundary.count))
                for pt in boundary {
                    w.writeFloat64(pt.x); w.writeFloat64(pt.y); w.writeFloat64(pt.z)
                }
                w.writeString(pattern)
                w.writeFloat64(scale)
                w.writeFloat64(angle)
                writeColor(color)
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
            }
        }
    }
}