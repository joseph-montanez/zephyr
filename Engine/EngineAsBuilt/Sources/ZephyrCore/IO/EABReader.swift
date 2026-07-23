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

    // MARK: - Helpers

    /// Safely convert a UInt64 to Int, returning nil if it exceeds Int.max.
    private static func safeInt(_ value: UInt64) -> Int? {
        guard value <= UInt64(Int.max) else { return nil }
        return Int(value)
    }

    /// Create a Range<Int> that is guaranteed to be within [0, count].
    /// Returns nil if offset is negative, size is non-positive, or the range overflows/overruns.
    private static func checkedRange(offset: Int, size: Int, count: Int) -> Range<Int>? {
        guard offset >= 0, size > 0, offset <= count else { return nil }
        let (end, overflow) = offset.addingReportingOverflow(size)
        guard !overflow, end <= count else { return nil }
        return offset..<end
    }

    // MARK: - Public API: Full Document Load

    /// Read a complete .eab file and return all views.
    /// Returns an array of `DrawingView` ready for `TabManager`.
    public static func readViews(from url: URL) throws -> [DrawingView] {
        let data = try Data(contentsOf: url)  // no .mappedIfSafe — file may be replaced atomically
        return try readViews(from: data)
    }

    /// Read views from in-memory Data.
    public static func readViews(from data: Data) throws -> [DrawingView] {
        let r = BinaryReader(data: data)
        let magic = r.readUInt32()
        
        if magic == EABArchiveMagic {
            // It's a V7 multi-view archive.
            // Try to parse its directory; if that yields garbage offsets (e.g. from the old
            // 16-byte header reservation bug), fall back to scanning for embedded V6 documents.
            if let views = try? parseV7Archive(data: data, r: r) {
                return views
            }
            // V7 directory corrupted — scan for V6 payloads inside the raw data.
            print("[EABReader] V7 directory appears corrupted; recovering by scanning for V6 data.")
            if let recovered = try? recoverV6Documents(data: data) {
                return recovered
            }
            throw EABError.readError("Unable to parse V7 archive — directory corrupted and no V6 payloads found.")
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
                textStyles: components.textStyles,
                dimensionStyles: components.dimensionStyles,
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
        textStyles: [String: CADTextStyle],
        dimensionStyles: [String: CADDimensionStyle],
        linetypePatterns: [String: [Double]],
        activeLayerID: UUID?,
        imageStore: [String: CADImageAsset]
    ) {
        let data = try Data(contentsOf: url)
        return try readDocument(from: data)
    }

    // MARK: - V7 Recovery Helpers

    private struct ParsedViewEntry {
        let name: String
        let kind: DXFDrawingViewKind
        let cameraState: CameraState
        let dataOffset: Int
        let dataSize: Int
    }

    /// Parse a V7 archive directory. Validates ALL entries before reading any payload.
    /// Returns nil if any directory entry has out-of-bounds or overflowed offsets.
    private static func parseV7Archive(data: Data, r: BinaryReader) throws -> [DrawingView]? {
        let version = r.readUInt32()
        guard version <= EABVersion else { throw EABError.unsupportedVersion(version) }

        let viewCount = Int(r.readUInt32())
        guard viewCount > 0, viewCount < 10_000 else { return nil }

        let rawDirOffset = r.readUInt64()
        guard let directoryOffset = safeInt(rawDirOffset),
              directoryOffset >= 16, directoryOffset < data.count else { return nil }

        let dirReader = BinaryReader(data: data, startOffset: directoryOffset)

        // Phase 1: collect and validate every entry
        var entries: [ParsedViewEntry] = []
        for _ in 0..<viewCount {
            // Need at least: name (2+len), kind (1), camera (32), offset (8), size (8)
            guard dirReader.canRead(1 + 32 + 8 + 8) else { return nil }

            let name = dirReader.readString()
            let kindRaw = dirReader.readUInt8()
            let kind: DXFDrawingViewKind = (kindRaw == 0) ? .model : .sheet

            let camX = dirReader.readFloat64()
            let camY = dirReader.readFloat64()
            let camZoom = dirReader.readFloat64()
            let camRot = dirReader.readFloat64()

            let rawViewOffset = dirReader.readUInt64()
            let rawViewSize = dirReader.readUInt64()

            guard let dataOffset = safeInt(rawViewOffset),
                  let dataSize = safeInt(rawViewSize) else { return nil }

            // Offset must be after the directory and within the file
            guard dataOffset > directoryOffset,
                  checkedRange(offset: dataOffset, size: dataSize, count: data.count) != nil
            else { return nil }

            entries.append(ParsedViewEntry(
                name: name, kind: kind,
                cameraState: CameraState(offsetX: camX, offsetY: camY, zoom: camZoom, rotation: camRot),
                dataOffset: dataOffset, dataSize: dataSize
            ))
        }

        // Phase 2: read each validated view payload
        var views: [DrawingView] = []
        for entry in entries {
            guard let range = checkedRange(offset: entry.dataOffset, size: entry.dataSize, count: data.count)
            else { return nil }

            let viewData = data.subdata(in: range)
            let components = try readDocument(from: viewData)

            let doc = CADDocument()
            doc.importEAB(
                layers: components.layers,
                blocks: components.blocks,
                entities: components.entities,
                constraints: components.constraints,
                solvedTransforms: components.solvedTransforms,
                unit: components.unit,
                textStyles: components.textStyles,
                dimensionStyles: components.dimensionStyles,
                linetypePatterns: components.linetypePatterns,
                activeLayerID: components.activeLayerID,
                imageStore: components.imageStore
            )

            views.append(DrawingView(name: entry.name, kind: entry.kind,
                                     document: doc, cameraState: entry.cameraState))
        }

        return views
    }

    /// Scan raw data for V6 documents (magic = EABMagic) and recover them as DrawingViews.
    private static func recoverV6Documents(data: Data) throws -> [DrawingView]? {
        let magicBytes = withUnsafeBytes(of: EABMagic.littleEndian) { Data($0) }
        var views: [DrawingView] = []
        var searchStart = 20  // Skip V7 header region

        while searchStart < data.count - 4 {
            guard let range = data.range(of: magicBytes, in: searchStart..<data.count) else { break }
            let offset = range.lowerBound
            let size = data.count - offset
            guard let viewRange = checkedRange(offset: offset, size: size, count: data.count) else { break }
            let viewData = data.subdata(in: viewRange)
            do {
                let components = try readDocument(from: viewData)
                let doc = CADDocument()
                doc.importEAB(
                    layers: components.layers,
                    blocks: components.blocks,
                    entities: components.entities,
                    constraints: components.constraints,
                    solvedTransforms: components.solvedTransforms,
                    unit: components.unit,
                    textStyles: components.textStyles,
                    dimensionStyles: components.dimensionStyles,
                    linetypePatterns: components.linetypePatterns,
                    activeLayerID: components.activeLayerID,
                    imageStore: components.imageStore
                )
                views.append(DrawingView(name: "Recovered", kind: .model, document: doc,
                                         cameraState: CameraState(offsetX: 0, offsetY: 0, zoom: 1, rotation: 0)))
            } catch {
                // This magic might be a false positive inside image data etc. Continue scanning.
            }
            searchStart = offset + 4
        }

        return views.isEmpty ? nil : views
    }

    /// Read from in-memory Data.
    public static func readDocument(from data: Data) throws -> (
        layers: [Layer],
        blocks: [CADBlock],
        entities: [CADEntity],
        constraints: [CADConstraint],
        solvedTransforms: [UUID: Transform3D],
        unit: CADUnit,
        textStyles: [String: CADTextStyle],
        dimensionStyles: [String: CADDimensionStyle],
        linetypePatterns: [String: [Double]],
        activeLayerID: UUID?,
        imageStore: [String: CADImageAsset]
    ) {
        let header = try parseHeader(from: data)
        let rawTableOffset = header.sectionTableOffset; guard rawTableOffset <= UInt64(Int.max) else { throw EABError.readError("Section table offset exceeds Int.max") }; let entries = try parseSectionTable(from: data, at: Int(rawTableOffset))

        var layers: [Layer] = []
        var blocks: [CADBlock] = []
        var entities: [CADEntity] = []
        var constraints: [CADConstraint] = []
        var solvedTransforms: [UUID: Transform3D] = [:]
        var textStyles: [String: CADTextStyle] = ["Standard": .standard]
        var dimensionStyles: [String: CADDimensionStyle] = [:]
        var linetypePatterns: [String: [Double]] = [:]
        var activeLayerID: UUID? = nil
        var loadedImageStore: [String: CADImageAsset] = [:]

        for entry in entries {
            let reader = BinaryReader(data: data, startOffset: safeInt(entry.offset) ?? 0)
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
                textStyles = try parseTextStyles(reader, version: header.version)
            case .dimensionStyles:
                dimensionStyles = try parseDimensionStyles(reader)
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
                textStyles, dimensionStyles, linetypePatterns, activeLayerID, loadedImageStore)
    }

    private static func parseDimensionStyles(_ r: BinaryReader) throws -> [String: CADDimensionStyle] {
        var styles: [String: CADDimensionStyle] = [:]
        let count = safeCount(r.readUInt32(), limit: maxSafeSectionCount, label: "dimensionStyles")
        let decoder = JSONDecoder()
        for _ in 0..<count {
            let styleName = r.readString()
            let jsonString = r.readString()
            if let data = jsonString.data(using: .utf8),
               let style = try? decoder.decode(CADDimensionStyle.self, from: data) {
                styles[styleName] = style
            } else {
                styles[styleName] = CADDimensionStyle.default
            }
        }
        return styles
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
        textStyles: [String: CADTextStyle],
        dimensionStyles: [String: CADDimensionStyle],
        linetypePatterns: [String: [Double]],
        activeLayerID: UUID?,
        imageStore: [String: CADImageAsset]
    ) {
        let data = try Data(contentsOf: url)
        let header = try parseHeader(from: data)
        let rawTableOffset = header.sectionTableOffset; guard rawTableOffset <= UInt64(Int.max) else { throw EABError.readError("Section table offset exceeds Int.max") }; let entries = try parseSectionTable(from: data, at: Int(rawTableOffset))

        // Find BVH section and query it
        guard let bvhEntry = entries.first(where: { $0.type == .bvh }) else {
            // No BVH — fall back to full load
            return try readDocument(from: data)
        }

        let bvhReader = BinaryReader(data: data, startOffset: safeInt(bvhEntry.offset) ?? 0)
        let tree = try parseBVHTree(bvhReader)
        let (entityIndices, blockIndices) = tree.query(viewport: viewport)

        var layers: [Layer] = []
        var blocks: [CADBlock] = []
        var entities: [CADEntity] = []
        var constraints: [CADConstraint] = []
        var solvedTransforms: [UUID: Transform3D] = [:]
        var textStyles: [String: CADTextStyle] = ["Standard": .standard]
        var dimensionStyles: [String: CADDimensionStyle] = [:]
        var linetypePatterns: [String: [Double]] = [:]
        var activeLayerID: UUID? = nil
        var loadedImageStore: [String: CADImageAsset] = [:]

        for entry in entries {
            let reader = BinaryReader(data: data, startOffset: safeInt(entry.offset) ?? 0)
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
                textStyles = try parseTextStyles(reader, version: header.version)
            case .dimensionStyles:
                dimensionStyles = try parseDimensionStyles(reader)
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
                textStyles, dimensionStyles, linetypePatterns, activeLayerID, loadedImageStore)
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
        let count = safeCount(r.readUInt32(), limit: 1000, label: "sectionTable")
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

    // MARK: - Safety Limits

    /// Maximum entity count per document to prevent OOM on corrupted files.
    private static let maxSafeEntityCount = 5_000_000
    /// Maximum block count per document.
    private static let maxSafeBlockCount = 500_000
    /// Maximum layer count per document.
    private static let maxSafeLayerCount = 50_000
    /// Maximum primitive count per block/entity.
    private static let maxSafePrimitiveCount = 10_000_000
    /// Maximum vertex count per polyline/polygon.
    private static let maxSafeVertexCount = 1_000_000
    /// Maximum edge count per hatch.
    private static let maxSafeHatchEdgeCount = 100_000
    /// Maximum style count per block.
    private static let maxSafeStyleCount = 100_000
    /// Maximum count for any section array/dict.
    private static let maxSafeSectionCount = 10_000_000

    /// Clamp a UInt32 count to a safe limit, logging a warning if it was exceeded.
    private static func safeCount(_ raw: UInt32, limit: Int, label: String) -> Int {
        let value = Int(raw)
        guard value <= limit else {
            print("[EABReader] WARNING: \(label) count \(value) exceeds limit \(limit), capping")
            return limit
        }
        return value
    }

    // MARK: - Layer Parsing

    private static func parseLayers(_ r: BinaryReader, version: UInt32) throws -> [Layer] {
        let count = safeCount(r.readUInt32(), limit: maxSafeLayerCount, label: "layers")
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
            let isPlottable: Bool
            let plotStyleHandle: String?
            if version >= 9 {
                let plotFlags = r.readUInt8()
                isPlottable = (plotFlags & 0x01) != 0
                plotStyleHandle = (plotFlags & 0x02) != 0 ? r.readString() : nil
            } else {
                isPlottable = true
                plotStyleHandle = nil
            }
            layers.append(Layer(handle: handle, name: name, isVisible: isVisible,
                                lineWeight: lineWeight,
                                color: ColorRGBA(r: rComp, g: gComp, b: bComp, a: aComp),
                                lineType: lineType,
                                isPlottable: isPlottable,
                                plotStyleHandle: plotStyleHandle,
                                opacity: opacity))
        }
        return layers
    }

    // MARK: - Block Parsing

    private static func parseBlocks(_ r: BinaryReader, version: UInt32) throws -> [CADBlock] {
        let count = safeCount(r.readUInt32(), limit: maxSafeBlockCount, label: "blocks")
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
            let primitiveStyles = version >= 9 ? parsePrimitiveStyles(r) : [:]
            let dxfFlags = version >= 12 ? Int(r.readInt32()) : (name.hasPrefix("*") ? 1 : 0)
            let isInternalTableDisplayBlock = version >= 12
                ? r.readUInt8() != 0
                : name.uppercased().hasPrefix("*T")
            let primitiveXData = version >= 12 ? try parsePrimitiveXData(r) : [:]
            var block = CADBlock(handle: handle, name: name, geometry: geometry,
                                 primitiveStyles: primitiveStyles,
                                 primitiveXData: primitiveXData,
                                 dxfFlags: dxfFlags,
                                 isInternalTableDisplayBlock: isInternalTableDisplayBlock)
            block.localBoundingBox = bbox
            blocks.append(block)
        }
        return blocks
    }

    private static func parsePrimitiveXData(
        _ r: BinaryReader
    ) throws -> [Int: [String: XDataValue]] {
        let count = safeCount(r.readUInt32(), limit: maxSafeStyleCount, label: "primitiveXData")
        var values: [Int: [String: XDataValue]] = [:]
        values.reserveCapacity(count)
        for _ in 0..<count {
            values[Int(r.readUInt32())] = try parseXDataDict(r)
        }
        return values
    }

    private static func parsePrimitiveStyles(_ r: BinaryReader) -> [Int: CADPrimitiveStyle] {
        let count = safeCount(r.readUInt32(), limit: maxSafeStyleCount, label: "primitiveStyles")
        var styles: [Int: CADPrimitiveStyle] = [:]
        styles.reserveCapacity(count)
        for _ in 0..<count {
            let index = Int(r.readUInt32())
            let flags = r.readUInt16()
            let layerName = (flags & (1 << 0)) != 0 ? r.readString() : nil
            let color: ColorRGBA?
            if (flags & (1 << 1)) != 0 {
                let value = r.readUInt32()
                color = ColorRGBA(
                    r: UInt8((value >> 24) & 0xFF),
                    g: UInt8((value >> 16) & 0xFF),
                    b: UInt8((value >> 8) & 0xFF),
                    a: UInt8(value & 0xFF))
            } else {
                color = nil
            }
            let lineType = (flags & (1 << 3)) != 0 ? r.readString() : nil
            let lineWeight = (flags & (1 << 5)) != 0 ? r.readFloat64() : nil
            let lineTypeScale = (flags & (1 << 7)) != 0 ? r.readFloat64() : nil
            let geomWidth = (flags & (1 << 8)) != 0 ? r.readFloat64() : nil
            let opacity = (flags & (1 << 9)) != 0 ? r.readFloat64() : nil
            let plotStyleHandle = (flags & (1 << 10)) != 0 ? r.readString() : nil
            let textBackgroundScale = (flags & (1 << 11)) != 0 ? r.readFloat64() : nil
            let textBackgroundColor: ColorRGBA?
            if (flags & (1 << 12)) != 0 {
                let value = r.readUInt32()
                textBackgroundColor = ColorRGBA(
                    r: UInt8((value >> 24) & 0xFF),
                    g: UInt8((value >> 16) & 0xFF),
                    b: UInt8((value >> 8) & 0xFF),
                    a: UInt8(value & 0xFF))
            } else {
                textBackgroundColor = nil
            }
            styles[index] = CADPrimitiveStyle(
                layerName: layerName,
                color: color,
                isColorByBlock: (flags & (1 << 2)) != 0,
                lineType: lineType,
                isLineTypeByBlock: (flags & (1 << 4)) != 0,
                lineWeight: lineWeight,
                isLineWeightByBlock: (flags & (1 << 6)) != 0,
                lineTypeScale: lineTypeScale,
                geomWidth: geomWidth,
                opacity: opacity,
                plotStyleHandle: plotStyleHandle,
                textBackgroundScale: textBackgroundScale,
                textBackgroundColor: textBackgroundColor,
                textBackgroundUsesViewportColor: (flags & (1 << 13)) != 0)
        }
        return styles
    }

    // MARK: - Entity Parsing

    private static func parseEntities(_ r: BinaryReader, version: UInt32) throws -> [CADEntity] {
        let count = safeCount(r.readUInt32(), limit: maxSafeEntityCount, label: "entities")
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
            let hasDimensionMetadata = (flags & 0x08) != 0
            let hasArrayData = version >= 14 && (flags & 0x10) != 0

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
                let raw = r.readInt32()
                drawOrder = raw == Int32.max ? Int.max : Int(raw)
            } else if version <= 5 {
                // Backward compat: migrate from legacy xdata key
                if case .int(let v) = xdata["dxf.drawOrder"] {
                    drawOrder = v
                    xdata.removeValue(forKey: "dxf.drawOrder")
                }
            }
            
            var dimensionMetadataBox: CADDimensionMetadataBox? = nil
            if hasDimensionMetadata {
                dimensionMetadataBox = try parseDimensionMetadata(r)
            }
            var arrayData: CADArrayData? = nil
            if hasArrayData {
                let byteCount = safeCount(r.readUInt32(), limit: 16 * 1024 * 1024, label: "arrayData")
                let bytes = r.readBytes(count: byteCount)
                arrayData = try? JSONDecoder().decode(CADArrayData.self, from: bytes)
            }

            var entity = CADEntity(
                handle: handle, layerID: layerID, blockID: blockID,
                localGeometry: localGeom, dimensionMetadata: dimensionMetadataBox,
                arrayData: arrayData,
                transform: transform, xdata: xdata,
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



    private static func parseDimensionMetadata(_ r: BinaryReader) throws -> CADDimensionMetadataBox {
        let styleLen = Int(r.readUInt32())
        let styleBytes = r.readBytes(count: styleLen)
        let styleName = String(decoding: styleBytes, as: UTF8.self)
        
        let typeRaw = Int(r.readInt32())
        let type = CADDimensionType(rawValue: typeRaw) ?? .linearOrRotated
        
        let measurement = r.readFloat64()
        let p1 = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
        let p2 = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
        
        let hasP3 = r.readUInt8() != 0
        let p3: Vector3? = hasP3 ? Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()) : nil
        
        let tp = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
        
        let overrideLen = Int(r.readUInt32())
        var textOverride: String? = nil
        if overrideLen > 0 {
            let ovBytes = r.readBytes(count: overrideLen)
            textOverride = String(decoding: ovBytes, as: UTF8.self)
        }
        
        let rot = r.readFloat64()
        let flags = Int(r.readInt32())
        
        let metadata = CADDimensionMetadata(
            styleName: styleName,
            type: type,
            measurement: measurement,
            defPoint: p1,
            defPoint2: p2,
            defPoint3: p3,
            textMidpoint: tp,
            textOverride: textOverride,
            rotationAngle: rot,
            flags: flags
        )
        return CADDimensionMetadataBox(metadata)
    }

    // MARK: - Constraint Parsing

    private static func parseConstraints(_ r: BinaryReader) throws -> [CADConstraint] {
        let count = safeCount(r.readUInt32(), limit: maxSafeSectionCount, label: "constraints")
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
        let count = safeCount(r.readUInt32(), limit: maxSafeSectionCount, label: "solvedTransforms")
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

    private static func parseTextStyles(_ r: BinaryReader, version: UInt32) throws -> [String: CADTextStyle] {
        let count = safeCount(r.readUInt32(), limit: maxSafeSectionCount, label: "textStyles")
        var styles: [String: CADTextStyle] = ["Standard": .standard]
        styles.reserveCapacity(count + 1)
        for _ in 0..<count {
            let styleName = r.readString()
            let fontFile = r.readString()
            let style: CADTextStyle
            if version >= 13 {
                style = CADTextStyle(
                    name: styleName,
                    fontFile: fontFile,
                    fixedHeight: r.readFloat64(),
                    widthFactor: r.readFloat64(),
                    obliqueAngle: r.readFloat64(),
                    isAnnotative: r.readUInt8() != 0
                ).normalized
            } else {
                style = CADTextStyle(name: styleName, fontFile: fontFile).normalized
            }
            if !style.name.isEmpty { styles[style.name] = style }
        }
        return styles
    }

    // MARK: - Linetype Patterns Parsing

    private static func parseLinetypePatterns(_ r: BinaryReader) throws -> [String: [Double]] {
        let count = safeCount(r.readUInt32(), limit: maxSafeSectionCount, label: "linetypePatterns")
        var patterns: [String: [Double]] = [:]
        patterns.reserveCapacity(count)
        for _ in 0..<count {
            let name = r.readString()
            let patternCount = safeCount(r.readUInt32(), limit: 10_000, label: "patternDashes")
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
        let count = safeCount(r.readUInt32(), limit: maxSafeSectionCount, label: "imageStore")
        var store: [String: CADImageAsset] = [:]
        store.reserveCapacity(count)
        for _ in 0..<count {
            let name = r.readString()
            let originalFilename = r.readString()
            let mimeType = r.readString()
            let pixelWidth = safeCount(r.readUInt32(), limit: 100_000, label: "imgPixelWidth")
            let pixelHeight = safeCount(r.readUInt32(), limit: 100_000, label: "imgPixelHeight")
            let sha256 = r.readString()
            let rawDataLen = r.readUInt64()
            guard rawDataLen <= UInt64(Int.max) else {
                throw EABError.readError("Image asset '\(name)' data length overflow")
            }
            let dataLen = Int(rawDataLen)
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
        let entityCount = safeCount(r.readUInt32(), limit: maxSafeEntityCount, label: "bvhEntities")
        var entityIndices: [UInt32] = []
        for _ in 0..<entityCount { entityIndices.append(r.readUInt32()) }

        // Block indices
        let blockCount = safeCount(r.readUInt32(), limit: maxSafeBlockCount, label: "bvhBlocks")
        var blockIndices: [UInt32] = []
        for _ in 0..<blockCount { blockIndices.append(r.readUInt32()) }

        // Nodes
        let nodeCount = safeCount(r.readUInt32(), limit: maxSafeSectionCount, label: "bvhNodes")
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
        let count = safeCount(r.readUInt32(), limit: maxSafePrimitiveCount, label: "primitives")
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
            let readHatchPathMetadata = { () -> (edges: [CADHatchEdge], carrier: Bool, loopType: Int?) in
                guard version >= 11 else { return ([], false, nil) }
                let carrier = r.readUInt8() != 0
                let loopType: Int?
                if version >= 12 {
                    let raw = Int(r.readInt32())
                    loopType = raw >= 0 ? raw : nil
                } else {
                    loopType = nil
                }
                let edgeCount = safeCount(r.readUInt32(), limit: maxSafeHatchEdgeCount, label: "hatchEdges")
                var edges: [CADHatchEdge] = []
                edges.reserveCapacity(edgeCount)
                for _ in 0..<edgeCount {
                    switch r.readUInt8() {
                    case 0:
                        let start = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                        let end = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                        edges.append(.line(start: start, end: end))
                    case 1:
                        let center = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                        edges.append(.circularArc(center: center,
                                                  radius: r.readFloat64(),
                                                  startAngle: r.readFloat64(),
                                                  sweep: r.readFloat64()))
                    case 2:
                        let center = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                        let axisU = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                        let axisV = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                        edges.append(.ellipticalArc(center: center, axisU: axisU, axisV: axisV,
                                                    startParam: r.readFloat64(), sweep: r.readFloat64()))
                    case 3:
                        let degree = Int(r.readUInt32())
                        let closed = r.readUInt8() != 0
                        let periodic = r.readUInt8() != 0
                        let controlCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "splineCtrlPts")
                        var controlPoints: [Vector3] = []
                        controlPoints.reserveCapacity(controlCount)
                        for _ in 0..<controlCount {
                            controlPoints.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                        }
                        let knotCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "splineKnots")
                        var knots: [Double] = []
                        knots.reserveCapacity(knotCount)
                        for _ in 0..<knotCount { knots.append(r.readFloat64()) }
                        let hasWeights = r.readUInt8() != 0
                        var weights: [Double]? = nil
                        if hasWeights {
                            let weightCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "splineWeights")
                            var values: [Double] = []
                            values.reserveCapacity(weightCount)
                            for _ in 0..<weightCount { values.append(r.readFloat64()) }
                            weights = values
                        }
                        edges.append(.spline(controlPoints: controlPoints, knots: knots,
                                             degree: degree, weights: weights,
                                             closed: closed, periodic: periodic))
                    default:
                        break
                    }
                }
                return (edges, carrier, loopType)
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
                let ptCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "polygonVerts")
                var pts: [Vector3] = []
                for _ in 0..<ptCount {
                    pts.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let color = readColor()
                prims.append(.polygon(points: pts, color: color))
            case 15: // polyline
                let ptCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "polylineVerts")
                var pts: [Vector3] = []
                for _ in 0..<ptCount {
                    pts.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let color = readColor()
                prims.append(.polyline(points: pts, color: color))
            case 18: // bulge-aware polyline
                let isClosed = r.readUInt8() != 0
                let lineTypeGenerationEnabled = r.readUInt8() != 0
                let vertexCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "bulgePolyVerts")
                var vertices: [CADPolylineVertex] = []
                vertices.reserveCapacity(vertexCount)
                for _ in 0..<vertexCount {
                    let position = Vector3(
                        x: r.readFloat64(),
                        y: r.readFloat64(),
                        z: r.readFloat64())
                    vertices.append(CADPolylineVertex(
                        position: position,
                        bulge: r.readFloat64(),
                        startWidth: r.readFloat64(),
                        endWidth: r.readFloat64()))
                }
                let metadata = readHatchPathMetadata()
                let color = readColor()
                prims.append(.polyline(
                    path: CADPolyline(
                        vertices: vertices,
                        isClosed: isClosed,
                        lineTypeGenerationEnabled: lineTypeGenerationEnabled,
                        hatchEdges: metadata.edges,
                        isHatchBoundaryCarrier: metadata.carrier,
                        hatchLoopType: metadata.loopType),
                    color: color))
            case 7: // fillPolygon
                let ptCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "fillPolyVerts")
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
                let cpCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "splineCPs")
                var controlPoints: [Vector3] = []
                for _ in 0..<cpCount {
                    controlPoints.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let knotCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "splineKnots2")
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
                let bCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "hatchBoundary")
                var boundary: [Vector3] = []
                for _ in 0..<bCount {
                    boundary.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let pattern = r.readString()
                let scale = r.readFloat64()
                let angle = r.readFloat64()
                let color = readColor()
                prims.append(.hatch(boundary: boundary, pattern: pattern, scale: scale, angle: angle, color: color, backgroundColor: nil))
            case 19: // hatchPath
                func readPath() -> CADPolyline {
                    let count = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "hatchPathVerts")
                    let isClosed = r.readUInt8() != 0
                    let lineTypeGenerationEnabled = r.readUInt8() != 0
                    var vertices: [CADPolylineVertex] = []
                    vertices.reserveCapacity(count)
                    for _ in 0..<count {
                        let position = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                        let bulge = r.readFloat64()
                        let startWidth = r.readFloat64()
                        let endWidth = r.readFloat64()
                        vertices.append(CADPolylineVertex(
                            position: position,
                            bulge: bulge,
                            startWidth: startWidth,
                            endWidth: endWidth))
                    }
                    let metadata = readHatchPathMetadata()
                    return CADPolyline(vertices: vertices,
                                       isClosed: isClosed,
                                       lineTypeGenerationEnabled: lineTypeGenerationEnabled,
                                       hatchEdges: metadata.edges,
                                       isHatchBoundaryCarrier: metadata.carrier,
                                       hatchLoopType: metadata.loopType)
                }
                let boundary = readPath()
                let holeCount = safeCount(r.readUInt32(), limit: maxSafeHatchEdgeCount, label: "hatchHoles")
                var holes: [CADPolyline] = []
                holes.reserveCapacity(holeCount)
                for _ in 0..<holeCount { holes.append(readPath()) }
                let pattern = r.readString()
                let scale = r.readFloat64()
                let angle = r.readFloat64()
                let color = readColor()
                let backgroundColor = readColor()
                prims.append(.hatchPath(boundary: boundary, holes: holes, pattern: pattern, scale: scale, angle: angle, color: color, backgroundColor: backgroundColor))

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
                let clipCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "imageClip")
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
            case 9: // fillComplexPolygon
                let outerCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "fillComplexOuter")
                var outer: [Vector3] = []
                for _ in 0..<outerCount {
                    outer.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let holeCount = safeCount(r.readUInt32(), limit: maxSafeHatchEdgeCount, label: "fillComplexHoles")
                var holes: [[Vector3]] = []
                for _ in 0..<holeCount {
                    let hc = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "fillComplexHoleVerts")
                    var hole: [Vector3] = []
                    for _ in 0..<hc {
                        hole.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                    }
                    holes.append(hole)
                }
                let color = readColor()
                prims.append(.fillComplexPolygon(outer: outer, holes: holes, color: color))
            case 17: // table
                let origin = Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64())
                let jsonStr = r.readString()
                let data: DataTableData
                if let jsonData = jsonStr.data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(DataTableData.self, from: jsonData) {
                    data = decoded
                } else {
                    data = DataTableData()
                }
                let hasColor = r.readUInt8()
                let color: ColorRGBA? = hasColor != 0
                    ? ColorRGBA(r: r.readUInt8(), g: r.readUInt8(), b: r.readUInt8(), a: r.readUInt8())
                    : nil
                prims.append(.table(data: data, origin: origin, color: color))
            case 10: // gradient
                let outerCount = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "gradientOuter")
                var outer: [Vector3] = []
                for _ in 0..<outerCount {
                    outer.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                }
                let holeCount = safeCount(r.readUInt32(), limit: maxSafeHatchEdgeCount, label: "gradientHoles")
                var holes: [[Vector3]] = []
                for _ in 0..<holeCount {
                    let hc = safeCount(r.readUInt32(), limit: maxSafeVertexCount, label: "gradientHoleVerts")
                    var hole: [Vector3] = []
                    for _ in 0..<hc {
                        hole.append(Vector3(x: r.readFloat64(), y: r.readFloat64(), z: r.readFloat64()))
                    }
                    holes.append(hole)
                }
                let gradientName = r.readString()
                let gradientAngle = r.readFloat64()
                let color1 = readColor() ?? .white
                let color2 = readColor() ?? .white
                prims.append(.gradient(outer: outer, holes: holes,
                                       gradientName: gradientName, angle: gradientAngle,
                                       color1: color1, color2: color2))
            default:
                throw EABError.readError("Unknown primitive type: \(type)")
            }
        }
        return prims
    }
}