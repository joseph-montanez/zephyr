import Foundation

// =========================================================================
// MARK: - EABReader
//
// Reads Zephyr Binary (EAB) files and produces the full document
// state: layers, blocks, entities, constraints, solved transforms, and
// unit information. Uses the EABFileFormat structures for deserialization.

// =========================================================================
// MARK: - EABReader
// =========================================================================

/// Parses Zephyr Binary (.eab) files into CAD document components.
///
/// Supports full document load and partial (viewport-culled) load via the BVH index.
///
/// Usage:
/// ```swift
/// // Full load
/// let (layers, blocks, entities, constraints, solved, unit) = try EABReader.readDocument(from: url)
///
/// // Header-only (quick inspection)
/// let header = try EABReader.readHeader(from: url)
///
/// // Partial load (viewport-culled)
/// let doc = try EABReader.readPartial(from: url, viewport: someBoundingBox)
/// ```
public enum EABReader {

    // MARK: - Error

    public enum EABError: Error {
        case invalidMagic
        case unsupportedVersion(UInt32)
        case corruptedSectionTable
        case sectionNotFound(EABSectionType)
        case readError(String)
    }

    // MARK: - Public API: Full Document Load

    /// Read a complete .eab file and return all views.
    /// Returns an array of `DrawingView` ready for `TabManager`.
    public static func readViews(from url: URL) throws -> [DrawingView] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try readViews(from: data)
    }

    /// Read views from in-memory Data.
    public static func readViews(from data: Data) throws -> [DrawingView] {
        let r = BinaryReader(data: data)
        let magic = r.readUInt32()
        
        if magic == EABArchiveMagic {
            // It's a V7 multi-view archive
            let version = r.readUInt32()
            guard version <= EABVersion else { throw EABError.unsupportedVersion(version) }
            
            let viewCount = Int(r.readUInt32())
            let directoryOffset = Int(r.readUInt64())
            
            var views: [DrawingView] = []
            let dirReader = BinaryReader(data: data, startOffset: directoryOffset)
            
            for _ in 0..<viewCount {
                let name = dirReader.readString()
                let kindRaw = dirReader.readUInt8()
                let kind: DXFDrawingViewKind = (kindRaw == 0) ? .model : .sheet
                
                let camX = dirReader.readFloat64()
                let camY = dirReader.readFloat64()
                let camZoom = dirReader.readFloat64()
                let camRot = dirReader.readFloat64()
                let cameraState = CameraState(offsetX: camX, offsetY: camY, zoom: camZoom, rotation: camRot)
                
                let dataOffset = Int(dirReader.readUInt64())
                let dataSize = Int(dirReader.readUInt64())
                
                let viewData = data.subdata(in: dataOffset..<dataOffset + dataSize)
                let components = try readDocument(from: viewData)
                
                let doc = CADDocument()
                doc.importEAB(
                    layers: components.layers,
                    blocks: components.blocks,
                    entities: components.entities,
                    constraints: components.constraints,
                    solvedTransforms: components.solvedTransforms,
                    unit: components.unit,
                    textStyleFonts: components.textStyleFonts,
                    linetypePatterns: components.linetypePatterns,
                    activeLayerID: components.activeLayerID,
                    imageStore: components.imageStore
                )
                
                views.append(DrawingView(name: name, kind: kind, document: doc, cameraState: cameraState))
            }
            
            return views
        } else {
            // Fallback: Legacy single-document EAB
            let components = try readDocument(from: data)
            let doc = CADDocument()
            doc.importEAB(
                layers: components.layers,
                blocks: components.blocks,
                entities: components.entities,
                constraints: components.constraints,
                solvedTransforms: components.solvedTransforms,
                unit: components.unit,
                textStyleFonts: components.textStyleFonts,
                linetypePatterns: components.linetypePatterns,
                activeLayerID: components.activeLayerID,
                imageStore: components.imageStore
            )
            return [DrawingView(name: "Model", kind: .model, document: doc)]
        }
    }

    /// Read a complete .eab file and return all components.
    /// Returns components ready for `CADDocument.importEAB(...)`.
    public static func readDocument(from url: URL) throws -> (
        layers: [Layer],
        blocks: [CADBlock],
        entities: [CADEntity],
        constraints: [CADConstraint],
        solvedTransforms: [UUID: Transform3D],
        unit: CADUnit,
        textStyleFonts: [String: String],
        linetypePatterns: [String: [Double]],
        activeLayerID: UUID?,
        imageStore: [String: CADImageAsset]
    ) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try readDocument(from: data)
    }

    /// Read from in-memory Data.
    public static func readDocument(from data: Data) throws -> (
        layers: [Layer],
        blocks: [CADBlock],
        entities: [CADEntity],
        constraints: [CADConstraint],
        solvedTransforms: [UUID: Transform3D],
        unit: CADUnit,
        textStyleFonts: [String: String],
        linetypePatterns: [String: [Double]],
        activeLayerID: UUID?,
        imageStore: [String: CADImageAsset]
    ) {
        let header = try parseHeader(from: data)
        let entries = try parseSectionTable(from: data, at: Int(header.sectionTableOffset))

        var layers: [Layer] = []
        var blocks: [CADBlock] = []
        var entities: [CADEntity] = []
        var constraints: [CADConstraint] = []
        var solvedTransforms: [UUID: Transform3D] = [:]
        var textStyleFonts: [String: String] = [:]
        var linetypePatterns: [String: [Double]] = [:]
        var activeLayerID: UUID? = nil
        var loadedImageStore: [String: CADImageAsset] = [:]

        for entry in entries {
            let reader = BinaryReader(data: data, startOffset: Int(entry.offset))
            switch entry.type {
            case .layers:
                layers = try parseLayers(reader, version: header.version)
            case .blocks:
                blocks = try parseBlocks(reader, version: header.version)
            case .entities:
                entities = try parseEntities(reader, version: header.version)
            case .constraints:
                constraints = try parseConstraints(reader)
            case .solved:
                solvedTransforms = try parseSolvedTransforms(reader)
            case .textStyles:
                textStyleFonts = try parseTextStyleFonts(reader)
            case .lineTypes:
                linetypePatterns = try parseLinetypePatterns(reader)
            case .images:
                loadedImageStore = try parseImageStore(reader)
            case .metadata:
                activeLayerID = try parseMetadataActiveLayer(reader)
            default:
                break  // skip unknown sections
            }
        }

        return (layers, blocks, entities, constraints, solvedTransforms, header.unit,
                textStyleFonts, linetypePatterns, activeLayerID, loadedImageStore)
    }

    // MARK: - Public API: Header Only

    /// Read just the header for quick inspection (file version, unit, section table).
    public static func readHeader(from url: URL) throws -> EABHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let headerData = try handle.read(upToCount: 32), headerData.count == 32 else {
            throw EABError.readError("File too small for header")
        }
        return try parseHeader(from: headerData)
    }

    // MARK: - Public API: Partial Load (BVH-culled)

    /// Load only the entities and blocks whose bounding boxes intersect the given viewport.
    /// Uses the file's BVH section for spatial filtering.
    public static func readPartial(from url: URL, viewport: BoundingBox3D) throws -> (
        layers: [Layer],
        blocks: [CADBlock],
        entities: [CADEntity],
        constraints: [CADConstraint],
        solvedTransforms: [UUID: Transform3D],
        unit: CADUnit,
        textStyleFonts: [String: String],
        linetypePatterns: [String: [Double]],
        activeLayerID: UUID?,
        imageStore: [String: CADImageAsset]
    ) {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let header = try parseHeader(from: data)
        let entries = try parseSectionTable(from: data, at: Int(header.sectionTableOffset))

        // Find BVH section and query it
        guard let bvhEntry = entries.first(where: { $0.type == .bvh }) else {
            // No BVH — fall back to full load
            return try readDocument(from: data)
        }

        let bvhReader = BinaryReader(data: data, startOffset: Int(bvhEntry.offset))
        let tree = try parseBVHTree(bvhReader)
        let (entityIndices, blockIndices) = tree.query(viewport: viewport)

        var layers: [Layer] = []
        var blocks: [CADBlock] = []
        var entities: [CADEntity] = []
        var constraints: [CADConstraint] = []
        var solvedTransforms: [UUID: Transform3D] = [:]
        var textStyleFonts: [String: String] = [:]
        var linetypePatterns: [String: [Double]] = [:]
        var activeLayerID: UUID? = nil
        var loadedImageStore: [String: CADImageAsset] = [:]

        for entry in entries {
            let reader = BinaryReader(data: data, startOffset: Int(entry.offset))
            switch entry.type {
            case .layers:
                layers = try parseLayers(reader, version: header.version)
            case .blocks:
                let allBlocks = try parseBlocks(reader, version: header.version)
                blocks = blockIndices.isEmpty ? allBlocks
                    : blockIndices.sorted().compactMap { $0 < allBlocks.count ? allBlocks[$0] : nil }
            case .entities:
                let allEntities = try parseEntities(reader, version: header.version)
                entities = entityIndices.isEmpty ? allEntities
                    : entityIndices.sorted().compactMap { $0 < allEntities.count ? allEntities[$0] : nil }
            case .constraints:
                constraints = try parseConstraints(reader)
            case .solved:
                solvedTransforms = try parseSolvedTransforms(reader)
            case .textStyles:
                textStyleFonts = try parseTextStyleFonts(reader)
            case .lineTypes:
                linetypePatterns = try parseLinetypePatterns(reader)
            case .images:
                loadedImageStore = try parseImageStore(reader)
            case .metadata:
                activeLayerID = try parseMetadataActiveLayer(reader)
            default:
                break
            }
        }

        return (layers, blocks, entities, constraints, solvedTransforms, header.unit,
                textStyleFonts, linetypePatterns, activeLayerID, loadedImageStore)
    }

    // MARK: - Header Parsing

    private static func parseHeader(from data: Data) throws -> EABHeader {
        let r = BinaryReader(data: data)
        let magic = r.readUInt32()
        guard magic == EABMagic else { throw EABError.invalidMagic }
        let version = r.readUInt32()
        guard version <= EABVersion else { throw EABError.unsupportedVersion(version) }
        _ = r.readUInt32()  // flags
        let unitRaw = r.readUInt8()
        _ = r.readUInt8()  // reserved[0]
        _ = r.readUInt8()  // reserved[1]
        _ = r.readUInt8()  // reserved[2]
        let tableOffset = r.readUInt64()
        let fileCRC = r.readUInt32()
        // 4 reserved bytes
        _ = r.readUInt32()

        guard let unit = CADUnit(rawValue: unitRaw) else {
            throw EABError.readError("Unknown unit code: \(unitRaw)")
        }
        return EABHeader(unit: unit, sectionTableOffset: tableOffset, fileCRC: fileCRC)
    }

    // MARK: - Section Table

    private static func parseSectionTable(from data: Data, at offset: Int) throws -> [EABSectionEntry] {
        let r = BinaryReader(data: data, startOffset: offset)
        let count = Int(r.readUInt32())
        var entries: [EABSectionEntry] = []
        for _ in 0..<count {
            let typeRaw = r.readUInt32()
            let secOffset = r.readUInt64()
            let size = r.readUInt64()
            let compRaw = r.readUInt8()
            _ = r.readUInt8()  // reserved[0]
            _ = r.readUInt8()  // reserved[1]
            _ = r.readUInt8()  // reserved[2]

            guard let type = EABSectionType(rawValue: typeRaw),
                  let comp = EABCompression(rawValue: compRaw) else {
                throw EABError.corruptedSectionTable
            }
            entries.append(EABSectionEntry(type: type, offset: secOffset, size: size, compression: comp))
        }
        return entries
    }

    // MARK: - Layer Parsing

    private static func parseLayers(_ r: BinaryReader, version: UInt32) throws -> [Layer] {
        let count = Int(r.readUInt32())
        var layers: [Layer] = []
        for _ in 0..<count {
            let handle = r.readUUID()
            let name = r.readString()
            let flags = r.readUInt8()
            let lineWeight = Double(r.readFloat32())
            let colorVal = r.readUInt32()
            let rComp = UInt8((colorVal >> 24) & 0xFF)
            let gComp = UInt8((colorVal >> 16) & 0xFF)
            let bComp = UInt8((colorVal >> 8) & 0xFF)
            let aComp = UInt8(colorVal & 0xFF)
            let isVisible = (flags & 0x01) != 0
            // Opacity added in EAB version 3
            let opacity: Double = version >= 3 ? r.readFloat64() : 1.0
            let lineType = r.readString()
            layers.append(Layer(handle: handle, name: name, isVisible: isVisible,
                                lineWeight: lineWeight,
                                color: ColorRGBA(r: rComp, g: gComp, b: bComp, a: aComp),
                                lineType: lineType,
                                opacity: opacity))
        }
        return layers
    }

    // MARK: - Block Parsing

    private static func parseBlocks(_ r: BinaryReader, version: UInt32) throws -> [CADBlock] {
        let count = Int(r.readUInt32())
        var blocks: [CADBlock] = []
        for _ in 0..<count {
            let handle = r.readUUID()
            let name = r.readString()
            _ = r.readUInt32()  // pvaOffset
            _ = r.readUInt32()  // pvaByteCount
            _ = r.readUInt32()  // vertexCount
            _ = r.readUInt32()  // indexCount
            let bminX = Double(r.readFloat32())
            let bminY = Double(r.readFloat32())
            let bminZ = Double(r.readFloat32())
            let bmaxX = Double(r.readFloat32())
            let bmaxY = Double(r.readFloat32())
            let bmaxZ = Double(r.readFloat32())
            let bbox = BoundingBox3D(min: Vector3(x: bminX, y: bminY, z: bminZ),
                                      max: Vector3(x: bmaxX, y: bmaxY, z: bmaxZ))
            // Parse inline primitives (PVA is lossy, so we store originals too)
            let geometry = try parsePrimitives(r, version: version)
            var block = CADBlock(handle: handle, name: name, geometry: geometry)
            block.localBoundingBox = bbox
            blocks.append(block)
        }
        return blocks
    }

    // MARK: - Entity Parsing

    private static func parseEntities(_ r: BinaryReader, version: UInt32) throws -> [CADEntity] {
        let count = Int(r.readUInt32())
        var entities: [CADEntity] = []
        entities.reserveCapacity(count)
        for _ in 0..<count {
            let handle = r.readUUID()
            let layerID = r.readUUID()
            let blockIDUUID = r.readUUID()
            // nil blockID if all-zeros
            let blockID: UUID? = (blockIDUUID == UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) ? nil : blockIDUUID
            let transform = try readTransform(r)
            let flags = r.readUInt8()
            let hasXData = (flags & 0x01) != 0
            let hasLocalGeom = (flags & 0x02) != 0
            let hasDrawOrder = (flags & 0x04) != 0

            // bbox
            let bminX = Double(r.readFloat32())
            let bminY = Double(r.readFloat32())
            let bminZ = Double(r.readFloat32())
            let bmaxX = Double(r.readFloat32())
            let bmaxY = Double(r.readFloat32())
            let bmaxZ = Double(r.readFloat32())
            let bbox = BoundingBox3D(min: Vector3(x: bminX, y: bminY, z: bminZ),
                                      max: Vector3(x: bmaxX, y: bmaxY, z: bmaxZ))
            let isEmptyBBox = bminX == 0 && bminY == 0 && bminZ == 0
                            && bmaxX == 0 && bmaxY == 0 && bmaxZ == 0

            // local geometry PVA ref
            _ = hasLocalGeom ? r.readUInt32() : 0  // pvaOffset
            _ = hasLocalGeom ? r.readUInt32() : 0  // pvaByteCount
            _ = hasLocalGeom ? r.readUInt32() : 0  // vertexCount

            // local geometry primitives (serialized after PVA refs for round-tripping)
            let localGeom: [CADPrimitive]? = hasLocalGeom ? try parsePrimitives(r, version: version) : nil

            // xdata
            var xdata: [String: XDataValue] = [:]
            if hasXData {
                xdata = try parseXDataDict(r)
            }

            // drawOrder (v6+, flag 0x04)
            var drawOrder: Int = Int.max
            if hasDrawOrder {
                drawOrder = Int(r.readInt32())
            } else if version <= 5 {
                // Backward compat: migrate from legacy xdata key
                if case .int(let v) = xdata["dxf.drawOrder"] {
                    drawOrder = v
                    xdata.removeValue(forKey: "dxf.drawOrder")
                }
            }

            var entity = CADEntity(
                handle: handle, layerID: layerID, blockID: blockID,
                localGeometry: localGeom, transform: transform, xdata: xdata,
                drawOrder: drawOrder,
                localBoundingBox: isEmptyBBox ? nil : bbox
            )
            // If entity has a blockID but no local bbox, it'll get set when added to document
            if !isEmptyBBox {
                entity.updateAnchorCache()
            }
            entities.append(entity)
        }
        return entities
    }

    // MARK: - Constraint Parsing

    private static func parseConstraints(_ r: BinaryReader) throws -> [CADConstraint] {
        let count = Int(r.readUInt32())
        var constraints: [CADConstraint] = []
        for _ in 0..<count {
            let handle = r.readUUID()
            guard let cType = ConstraintType(rawValue: r.readUInt8()) else {
                throw EABError.corruptedSectionTable
            }
            let entityA = r.readUUID()
            let entityBUUID = r.readUUID()
            let entityB: UUID? = (entityBUUID == UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) ? nil : entityBUUID
            guard let subA = ConstraintSubEntity(rawValue: r.readUInt8()),
                  let subB = ConstraintSubEntity(rawValue: r.readUInt8()) else {
                throw EABError.corruptedSectionTable
            }
            let subIdxA = r.readUInt8()
            let subIdxB = r.readUInt8()
            let paramCount = Int(r.readUInt8())
            var params: [Double] = []
            for _ in 0..<paramCount { params.append(r.readFloat64()) }
            let flags = r.readUInt8()
            let isEnabled = (flags & 0x01) != 0
            let isDriven = (flags & 0x02) != 0

            constraints.append(CADConstraint(
                handle: handle, type: cType, entityA: entityA, entityB: entityB,
                subEntityA: subA, subIndexA: subIdxA,
                subEntityB: subB, subIndexB: subIdxB,
                params: params, isEnabled: isEnabled, isDriven: isDriven))
        }
        return constraints
    }

    // MARK: - Solved Transforms Parsing

    private static func parseSolvedTransforms(_ r: BinaryReader) throws -> [UUID: Transform3D] {
        let count = Int(r.readUInt32())
        var transforms: [UUID: Transform3D] = [:]
        for _ in 0..<count {
            let handle = r.readUUID()
            let transform = try readTransform(r)
            _ = r.readFloat32(); _ = r.readFloat32(); _ = r.readFloat32()  // bbox min
            _ = r.readFloat32(); _ = r.readFloat32(); _ = r.readFloat32()  // bbox max
            transforms[handle] = transform
        }
        return transforms
    }

    // MARK: - Transform Read

    private static func readTransform(_ r: BinaryReader) throws -> Transform3D {
        // Read 16 f64 values (row-major)
        var raw: [Double] = []
        for _ in 0..<16 { raw.append(r.readFloat64()) }
        return Transform3D(raw: raw)
    }

    // MARK: - XData Dict Parsing

    private static func parseXDataDict(_ r: BinaryReader) throws -> [String: XDataValue] {
        let count = Int(r.readUInt16())
        var dict: [String: XDataValue] = [:]
        dict.reserveCapacity(count)
        for _ in 0..<count {
            let keyLen = Int(r.readUInt8())
            let keyBytes = r.readBytes(count: keyLen)
            guard let key = String(data: keyBytes, encoding: .utf8) else { continue }
            let type = r.readUInt8()
            switch type {
            case 0:  // string
                dict[key] = .string(r.readString())
            case 1:  // double
                dict[key] = .double(r.readFloat64())
            case 2:  // int
                dict[key] = .int(Int(r.readUInt64()))
            case 3:  // bool
                dict[key] = .bool(r.readUInt8() != 0)
            case 4:  // date
                dict[key] = .date(Date(timeIntervalSince1970: r.readFloat64()))
            default:
                break
            }
        }
        return dict
    }

    // MARK: - Text Style Fonts Parsing

    private static func parseTextStyleFonts(_ r: BinaryReader) throws -> [String: String] {
        let count = Int(r.readUInt32())
        var fonts: [String: String] = [:]
        fonts.reserveCapacity(count)
        for _ in 0..<count {
            let styleName = r.readString()
            let fontFile = r.readString()
            fonts[styleName] = fontFile
        }
        return fonts
    }

    // MARK: - Linetype Patterns Parsing

    private static func parseLinetypePatterns(_ r: BinaryReader) throws -> [String: [Double]] {
        let count = Int(r.readUInt32())
        var patterns: [String: [Double]] = [:]
        patterns.reserveCapacity(count)
        for _ in 0..<count {
            let name = r.readString()
            let patternCount = Int(r.readUInt32())
            var pattern: [Double] = []
            pattern.reserveCapacity(patternCount)
            for _ in 0..<patternCount {
                pattern.append(r.readFloat64())
            }
            patterns[name] = pattern
        }
        return patterns
    }

    // MARK: - Image Store Parsing

    private static func parseImageStore(_ r: BinaryReader) throws -> [String: CADImageAsset] {
        let count = Int(r.readUInt32())
        var store: [String: CADImageAsset] = [:]
        store.reserveCapacity(count)
        for _ in 0..<count {
            let name = r.readString()
            let originalFilename = r.readString()
            let mimeType = r.readString()
            let pixelWidth = Int(r.readUInt32())
            let pixelHeight = Int(r.readUInt32())
            let sha256 = r.readString()
            let dataLen = Int(r.readUInt64())
            // Safety: cap max data length to avoid OOM on corrupt files
            guard dataLen <= CADImageAsset.maxFileBytes else {
                throw EABError.readError("Image asset '\(name)' exceeds max file size")
            }
            let data = r.readBytes(count: dataLen)
            let asset = CADImageAsset(
                name: name,
                originalFilename: originalFilename,
                mimeType: mimeType,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                sha256: sha256,
                data: data
            )
            store[name] = asset
        }
        return store
    }

    // MARK: - Metadata Active Layer Parsing

    /// Reads only the activeLayerID from the metadata section.
    /// The metadata format is: createdAt(f64), modifiedAt(f64), author(string),
    /// appNameLen(u16)+appName(bytes), version(u32×3), constraintTimestamp(f64),
    /// activeLayerID(uuid), customByteCount(u32).
    private static func parseMetadataActiveLayer(_ r: BinaryReader) throws -> UUID? {
        _ = r.readFloat64()  // createdAt
        _ = r.readFloat64()  // modifiedAt
        _ = r.readString()   // author
        let appNameLen = Int(r.readUInt16())
        _ = r.readBytes(count: appNameLen)  // appName
        _ = r.readUInt32(); _ = r.readUInt32(); _ = r.readUInt32()  // version
        _ = r.readFloat64()  // constraintTimestamp
        let layerID = r.readUUID()
        let allZeros = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
        return layerID == allZeros ? nil : layerID
    }

    // MARK: - BVH Tree Parsing

    private static func parseBVHTree(_ r: BinaryReader) throws -> BVHTree {
        // Entity indices
        let entityCount = Int(r.readUInt32())
        var entityIndices: [UInt32] = []
        for _ in 0..<entityCount { entityIndices.append(r.readUInt32()) }

        // Block indices
        let blockCount = Int(r.readUInt32())
        var blockIndices: [UInt32] = []
        for _ in 0..<blockCount { blockIndices.append(r.readUInt32()) }

        // Nodes
        let nodeCount = Int(r.readUInt32())
        var nodes: [BVHNode] = []
        nodes.reserveCapacity(nodeCount)
        for _ in 0..<nodeCount {
            let flags = r.readUInt8()
            let splitAxis = r.readUInt8()
            let childCount = r.readUInt8()
            _ = r.readUInt8()  // alignment pad
            let firstPrim = r.readUInt32()
            let primCount = r.readUInt32()
            let bminX = r.readFloat32(); let bminY = r.readFloat32(); let bminZ = r.readFloat32()
            let bmaxX = r.readFloat32(); let bmaxY = r.readFloat32(); let bmaxZ = r.readFloat32()
            nodes.append(BVHNode(
                isLeaf: (flags & 0x01) != 0,
                splitAxis: splitAxis, childCount: childCount,
                firstPrimitive: firstPrim, primitiveCount: primCount,
                bboxMin: (bminX, bminY, bminZ),
                bboxMax: (bmaxX, bmaxY, bmaxZ)))
        }
        return BVHTree(nodes: nodes, entityIndices: entityIndices, blockIndices: blockIndices)
    }

    // MARK: - CADPrimitive Parsing

    /// Parse CADPrimitives from inline block/entity record data.
    private static func parsePrimitives(_ r: BinaryReader, version: UInt32) throws -> [CADPrimitive] {
        let count = Int(r.readUInt32())
        guard count > 0 else { return [] }
        var prims: [CADPrimitive] = []
        prims.reserveCapacity(count)
        for _ in 0..<count {
            let type = r.readUInt8()
            let readColor = { () -> ColorRGBA? in
                guard version >= 2 else { return nil }
                let hasColor = r.readUInt8()
                if hasColor != 0 {
                    return ColorRGBA(r: r.readUInt8(), g: r.readUInt8(), b: r.readUInt8(), a: r.readUInt8())
                }
                return nil
            }
            switch type {
            case 0: // point
                let pos = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let color = readColor()
                prims.append(.point(position: pos, color: color))
            case 1: // line
                let start = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let end   = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let color = readColor()
                prims.append(.line(start: start, end: end, color: color))
            case 2: // rect
                let origin = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let size   = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: 0)
                let color = readColor()
                prims.append(.rect(origin: origin, size: size, color: color))
            case 3: // fillRect
                let origin = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let size   = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: 0)
                let color = readColor()
                prims.append(.fillRect(origin: origin, size: size, color: color))
            case 4: // polygon
                let ptCount = Int(r.readUInt32())
                var pts: [Vector3] = []
                for _ in 0..<ptCount {
                    pts.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let color = readColor()
                prims.append(.polygon(points: pts, color: color))
            case 15: // polyline
                let ptCount = Int(r.readUInt32())
                var pts: [Vector3] = []
                for _ in 0..<ptCount {
                    pts.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let color = readColor()
                prims.append(.polyline(points: pts, color: color))
            case 7: // fillPolygon
                let ptCount = Int(r.readUInt32())
                var pts: [Vector3] = []
                for _ in 0..<ptCount {
                    pts.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let color = readColor()
                prims.append(.fillPolygon(points: pts, color: color))
            case 5: // circle
                let center = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let radius = r.readFloat64()
                let color = readColor()
                prims.append(.circle(center: center, radius: radius, color: color))
            case 6: // arc
                let center = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let radius = r.readFloat64()
                let startAngle = r.readFloat64()
                let endAngle = r.readFloat64()
                let color = readColor()
                prims.append(.arc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, color: color))
            case 8: // text
                let pos = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let text = r.readString()
                let height = r.readFloat64()
                let rotation = r.readFloat64()
                let styleStr = r.readString()
                let style = styleStr.isEmpty ? nil : styleStr
                let alignH = Int(r.readUInt32())
                let alignV = Int(r.readUInt32())
                let mtextWidthVal = r.readFloat64()
                let mtextWidth = mtextWidthVal < 0 ? nil : mtextWidthVal
                let color = readColor()
                prims.append(.text(
                    position: pos,
                    text: text,
                    height: height,
                    rotation: rotation,
                    style: style,
                    alignH: alignH,
                    alignV: alignV,
                    mtextWidth: mtextWidth,
                    color: color
                ))
            case 11: // spline
                let cpCount = Int(r.readUInt32())
                var controlPoints: [Vector3] = []
                for _ in 0..<cpCount {
                    controlPoints.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let knotCount = Int(r.readUInt32())
                var knots: [Double] = []
                for _ in 0..<knotCount {
                    knots.append(r.readFloat64())
                }
                let degree = Int(r.readUInt32())
                let hasWeights = r.readUInt8() != 0
                var weights: [Double]? = nil
                if hasWeights {
                    var w: [Double] = []
                    for _ in 0..<cpCount {
                        w.append(r.readFloat64())
                    }
                    weights = w
                }
                let color = readColor()
                prims.append(.spline(controlPoints: controlPoints, knots: knots,
                                     degree: degree, weights: weights, color: color))
            case 12: // ellipse
                let center = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let majorAxis = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let minorRatio = r.readFloat64()
                let color = readColor()
                prims.append(.ellipse(center: center, majorAxis: majorAxis, minorRatio: minorRatio, color: color))
            case 13: // hatch
                let bCount = Int(r.readUInt32())
                var boundary: [Vector3] = []
                for _ in 0..<bCount {
                    boundary.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let pattern = r.readString()
                let scale = r.readFloat64()
                let angle = r.readFloat64()
                let color = readColor()
                prims.append(.hatch(boundary: boundary, pattern: pattern, scale: scale, angle: angle, color: color))
            case 14: // ray
                let start = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let direction = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let color = readColor()
                prims.append(.ray(start: start, direction: direction, color: color))
            case 16: // image
                let insertion = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let uAxis = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let vAxis = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let imageName = r.readString()
                let clipCount = Int(r.readUInt32())
                let clipBoundary: [Vector3]? = clipCount > 0 ? (0..<clipCount).map { _ in
                    Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                } : nil
                let hasTint = r.readUInt8()
                let tint: ColorRGBA? = hasTint != 0
                    ? ColorRGBA(r: r.readUInt8(), g: r.readUInt8(), b: r.readUInt8(), a: r.readUInt8())
                    : nil
                prims.append(.image(
                    insertion: insertion,
                    uAxis: uAxis,
                    vAxis: vAxis,
                    imageName: imageName,
                    clipBoundary: clipBoundary,
                    tint: tint
                ))
            default:
                throw EABError.readError("Unknown primitive type: \(type)")
            }
        }
        return prims
    }
}
