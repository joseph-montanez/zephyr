import Foundation

// =========================================================================
// MARK: - DrawingFileInsert
//
// Imports a DXF/DWG file's model space as a new internal block
// definition (AutoCAD's INSERT-of-a-file). Shared by the INSERT command
// and scripted `(command "INSERT" "path" ...)`; the XrefLoader reuses
// the import + bake path for shadow geometry.
// =========================================================================

public enum DrawingFileInsert {

    public enum InsertError: Error, CustomStringConvertible, Sendable {
        case fileNotFound(String)
        case unsupportedFile(String)
        case blockAlreadyExists(String)
        case emptyDrawing(String)
        case importFailed(String)

        public var description: String {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .unsupportedFile(let path): return "Only .dxf, .dwg and .eab files can be inserted: \(path)"
            case .blockAlreadyExists(let name): return "Block \"\(name)\" already exists"
            case .emptyDrawing(let path): return "Drawing has no model-space geometry: \(path)"
            case .importFailed(let message): return message
            }
        }
    }

    /// Valid block name derived from a filename stem (DXF symbol-name
    /// rules: no `<>/"':;?*|=` or backtick).
    public static func blockName(forFilePath path: String) -> String {
        let stem = (path as NSString).lastPathComponent
        let base = (stem as NSString).deletingPathExtension
        let invalid = CharacterSet(charactersIn: "<>/\"':;?*|=`\\")
        let cleaned = base.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
        let name = String(cleaned).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Inserted" : name
    }

    /// Read a DXF/DWG file into a `DXFImportResult` (DWG via ODA temp
    /// conversion). The single file-reading entry point shared by
    /// file-insert and the xref loader.
    public static func loadImportedFile(fromFile path: String) throws -> DXFImportResult {
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "dxf" || ext == "dwg" else { throw InsertError.unsupportedFile(path) }
        guard FileManager.default.fileExists(atPath: path) else {
            throw InsertError.fileNotFound(path)
        }
        let dxfPath: String
        if ext == "dwg" {
            guard ODADWGConverter.isAvailable else {
                throw InsertError.importFailed(
                    "ODA File Converter is not installed; cannot read DWG file \(path)")
            }
            let tmpDXF = FileManager.default.temporaryDirectory
                .appendingPathComponent("zephyr-insert-\(UUID().uuidString).dxf")
            do {
                try ODADWGConverter.convertSync(
                    input: URL(fileURLWithPath: path), output: tmpDXF, toFormat: "DXF")
            } catch {
                throw InsertError.importFailed("DWG conversion failed for \(path): \(error)")
            }
            dxfPath = tmpDXF.path
        } else {
            dxfPath = path
        }
        do {
            return try DXFImporter.importDXFViews(filePath: dxfPath)
        } catch {
            throw InsertError.importFailed("DXF import failed: \(error)")
        }
    }

    /// Import `path` and return its model space baked into block space
    /// (origin at the source $INSBASE), without touching any document.
    public static func loadModelSpace(
        fromFile path: String
    ) throws -> (baked: CADModelSpaceBaker.Baked, imported: DXFImportResult) {
        let imported = try loadImportedFile(fromFile: path)
        let baked = CADModelSpaceBaker.bake(
            entities: imported.entities,
            layers: imported.layers,
            blocks: imported.blocks,
            basePoint: imported.insBase)
        guard !baked.geometry.isEmpty else { throw InsertError.emptyDrawing(path) }
        return (baked, imported)
    }

    /// Create a block definition from `path` in `document`, merging any
    /// missing source layers/styles. Places no instance — callers add
    /// the INSERT entity. Returns the block and the unit-based default
    /// insertion scale.
    @discardableResult
    public static func insertFile(
        at path: String, into document: CADDocument, desiredName: String? = nil
    ) throws -> (block: CADBlock, defaultScale: Double) {
        let name = desiredName ?? blockName(forFilePath: path)
        if document.allBlocks.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw InsertError.blockAlreadyExists(name)
        }
        let baked: CADModelSpaceBaker.Baked
        let bundle: ContainerBundle
        if (path as NSString).pathExtension.lowercased() == "eab" {
            let eab = try loadModelSpaceEAB(fromFile: path)
            baked = eab.baked
            bundle = eab.bundle
        } else {
            let (modelBaked, imported) = try loadModelSpace(fromFile: path)
            baked = modelBaked
            bundle = ContainerBundle(imported: imported)
        }

        // Merge missing named objects so baked styles resolve in the host.
        mergeBundleSymbols(bundle, into: document)

        var block = CADBlock(
            name: name, geometry: baked.geometry,
            primitiveStyles: baked.primitiveStyles,
            primitiveXData: baked.primitiveXData)
        block.updateBoundingBox()
        document.addBlock(block)
        let scale = CADModelSpaceBaker.unitScale(from: bundle.sourceUnit, to: document.unit)
        return (block, scale)
    }

    /// Insertion transform: uniform-or-XYZ scale, Z rotation (degrees,
    /// AutoCAD prompt order), then translation to the insertion point.
    public static func insertionTransform(
        point: Vector3, scaleX: Double, scaleY: Double, scaleZ: Double = 1,
        rotationDegrees: Double
    ) -> Transform3D {
        let scale = Transform3D.scaled(by: Vector3(x: scaleX, y: scaleY, z: scaleZ))
        let rotated = Transform3D.rotated(by: rotationDegrees * .pi / 180).multiplying(by: scale)
        return Transform3D.translated(by: point).multiplying(by: rotated)
    }
}
