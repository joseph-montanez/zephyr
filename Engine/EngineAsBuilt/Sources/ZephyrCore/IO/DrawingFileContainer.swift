import Foundation

// =========================================================================
// MARK: - DrawingFileInsert (container blocks)
//
// Headless container support for the Blocks palette library tabs: enumerate
// block definitions inside an unopened DXF/DWG/EAB file and clone one
// definition into the host document.
//
// Conventions (see the Blocks palette plan):
//   - Container geometry is already flat (the DXF importer bakes nested
//     INSERTs; EAB stores baked definitions), so cloning never recurses.
//   - Unit scaling is baked into the clone ONCE (Option A): the resident
//     definition lives in host units and inserts at defaultScale 1.0, so
//     `.useExisting` re-inserts and Current-tab inserts stay correct.
//   - Whole-file `insertFile` keeps its existing behavior (entity-scale via
//     the returned defaultScale) untouched.
// =========================================================================

extension DrawingFileInsert {

    /// Name-collision policy for container-block cloning (v1: no redefine;
    /// `redefineBlock` is a separate post-v1 document mutation).
    public enum CollisionPolicy: Sendable {
        /// Keep the resident definition; report scale 1.0 (the clone would
        /// already be in host units, so existing instances are unaffected).
        case useExisting
        /// Import under a unique `Name_1`, `Name_2`, … suffix.
        case importAsCopy
    }

    /// Headless view of one container file: everything `cloneBlock` needs
    /// without touching any document. Cheap to hold; the heavy
    /// `DXFImportResult` is discarded after mapping.
    public struct ContainerBundle: Sendable {
        public var blocks: [CADBlock]
        public var layers: [Layer]
        public var textStyles: [String: CADTextStyle]
        public var linetypePatterns: [String: [Double]]
        public var dimensionStyles: [String: CADDimensionStyle]
        public var leaderStyles: [String: CADLeaderStyle]
        public var sourceUnit: CADUnit?

        public init(
            blocks: [CADBlock] = [],
            layers: [Layer] = [],
            textStyles: [String: CADTextStyle] = [:],
            linetypePatterns: [String: [Double]] = [:],
            dimensionStyles: [String: CADDimensionStyle] = [:],
            leaderStyles: [String: CADLeaderStyle] = [:],
            sourceUnit: CADUnit? = nil
        ) {
            self.blocks = blocks
            self.layers = layers
            self.textStyles = textStyles
            self.linetypePatterns = linetypePatterns
            self.dimensionStyles = dimensionStyles
            self.leaderStyles = leaderStyles
            self.sourceUnit = sourceUnit
        }

        public init(imported: DXFImportResult) {
            self.init(
                blocks: imported.blocks,
                layers: imported.layers,
                textStyles: imported.textStyles,
                linetypePatterns: imported.linetypePatterns,
                dimensionStyles: imported.dimensionStyles,
                leaderStyles: imported.leaderStyles,
                sourceUnit: imported.sourceUnit)
        }

        /// Bundle from a live document (used for EAB view archives, which
        /// carry no document header — see `EABWriter.write(document:)`).
        public init(document: CADDocument) {
            self.init(
                blocks: document.allBlocks,
                layers: document.allLayers,
                textStyles: document.textStyles,
                linetypePatterns: document.linetypePatterns,
                dimensionStyles: document.dimensionStyles,
                leaderStyles: document.leaderStyles,
                sourceUnit: document.unit)
        }
    }

    /// Enumerate a container file's block definitions without touching any
    /// document. Supports `.dxf`/`.dwg` (DWG via the ODA temp conversion)
    /// and native `.eab`.
    public static func loadContainerBundle(fromFile path: String) throws -> ContainerBundle {
        let ext = (path as NSString).pathExtension.lowercased()
        guard FileManager.default.fileExists(atPath: path) else {
            throw InsertError.fileNotFound(path)
        }
        switch ext {
        case "dxf", "dwg":
            return ContainerBundle(imported: try loadImportedFile(fromFile: path))
        case "eab":
            let url = URL(fileURLWithPath: path)
            if let eab = try? EABReader.readDocument(from: url) {
                return ContainerBundle(
                    blocks: eab.blocks,
                    layers: eab.layers,
                    textStyles: eab.textStyles,
                    linetypePatterns: eab.linetypePatterns,
                    dimensionStyles: eab.dimensionStyles,
                    leaderStyles: eab.leaderStyles,
                    sourceUnit: eab.unit)
            }
            // Fall back to view archives (EABWriter.write(document:)), which
            // store per-view documents without the snapshot header.
            do {
                let views = try EABReader.readViews(from: url)
                guard let doc = views.first?.document else {
                    throw InsertError.importFailed("EAB has no views: \(path)")
                }
                return ContainerBundle(document: doc)
            } catch let importError as InsertError {
                throw importError
            } catch {
                throw InsertError.importFailed("EAB read failed for \(path): \(error)")
            }
        default:
            throw InsertError.unsupportedFile(path)
        }
    }

    /// Names already taken in `document` (case-insensitive block lookup).
    public static func uniqueBlockName(base: String, in document: CADDocument) -> String {
        let taken = { (candidate: String) in
            document.allBlocks.contains {
                $0.name.caseInsensitiveCompare(candidate) == .orderedSame
            }
        }
        guard taken(base) else { return base }
        var i = 1
        while taken("\(base)_\(i)") { i += 1 }
        return "\(base)_\(i)"
    }

    /// Clone one container block into `document`, merging missing layers and
    /// styles. Source geometry is unit-baked to host units, so the returned
    /// `defaultScale` is always 1.0. Places no instance.
    @discardableResult
    public static func cloneBlock(
        named name: String, from bundle: ContainerBundle,
        into document: CADDocument, policy: CollisionPolicy = .useExisting
    ) throws -> (block: CADBlock, defaultScale: Double) {
        guard let source = bundle.blocks.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw InsertError.importFailed("Block \"\(name)\" not found in container")
        }
        if let existing = document.allBlocks.first(where: {
            $0.name.caseInsensitiveCompare(source.name) == .orderedSame
        }) {
            switch policy {
            case .useExisting:
                return (existing, 1.0)
            case .importAsCopy:
                break
            }
        }

        let scale = CADModelSpaceBaker.unitScale(from: bundle.sourceUnit, to: document.unit)
        mergeBundleSymbols(bundle, into: document)

        let targetName: String
        if document.allBlocks.contains(where: {
            $0.name.caseInsensitiveCompare(source.name) == .orderedSame
        }) {
            targetName = uniqueBlockName(base: source.name, in: document)
        } else {
            targetName = source.name
        }

        var clone: CADBlock
        if scale == 1.0 {
            clone = CADBlock(
                handle: UUID(),
                name: targetName,
                geometry: source.geometry,
                primitiveStyles: source.primitiveStyles,
                primitiveXData: source.primitiveXData,
                dxfFlags: source.dxfFlags,
                attributeDefinitions: source.attributeDefinitions)
        } else {
            clone = CADBlock(
                handle: UUID(),
                name: targetName,
                geometry: uniformScalePrimitives(source.geometry, by: scale),
                primitiveStyles: source.primitiveStyles,
                primitiveXData: source.primitiveXData,
                dxfFlags: source.dxfFlags,
                attributeDefinitions: source.attributeDefinitions.map {
                    scaledAttributeDefinition($0, by: scale)
                })
        }
        clone.updateBoundingBox()
        document.addBlock(clone)
        return (clone, 1.0)
    }

    /// Merge a bundle's named symbols into the host, skipping what exists.
    /// Same skip-if-exists rule as `insertFile`; layers route through the
    /// document import so layer tables stay consistent.
    public static func mergeBundleSymbols(_ bundle: ContainerBundle, into document: CADDocument) {
        let hostLayerNames = Set(document.allLayers.map { $0.name.uppercased() })
        let newLayers = bundle.layers.filter { !hostLayerNames.contains($0.name.uppercased()) }
        if !newLayers.isEmpty {
            document.importLayersBlocksEntities(layers: newLayers, blocks: [], entities: [])
        }
        for (key, value) in bundle.textStyles where document.textStyles[key] == nil {
            document.textStyles[key] = value
        }
        for (key, value) in bundle.linetypePatterns where document.linetypePatterns[key] == nil {
            document.linetypePatterns[key] = value
        }
        for (key, value) in bundle.dimensionStyles where document.dimensionStyles[key] == nil {
            document.dimensionStyles[key] = value
        }
        for (key, value) in bundle.leaderStyles where document.leaderStyles[key] == nil {
            document.leaderStyles[key] = value
        }
    }

    /// Bake an EAB file's model space into block space (origin at its
    /// insertion base), mirroring `loadModelSpace` for DXF/DWG.
    public static func loadModelSpaceEAB(
        fromFile path: String
    ) throws -> (baked: CADModelSpaceBaker.Baked, bundle: ContainerBundle) {
        let bundle = try loadContainerBundle(fromFile: path)
        guard (path as NSString).pathExtension.lowercased() == "eab" else {
            throw InsertError.unsupportedFile(path)
        }
        let eab: (
            layers: [Layer], blocks: [CADBlock], entities: [CADEntity],
            base: Vector3
        )
        let url = URL(fileURLWithPath: path)
        if let doc = try? EABReader.readDocument(from: url) {
            eab = (doc.layers, doc.blocks, doc.entities, doc.insertionBase)
        } else if let viewDoc = try? EABReader.readViews(from: url).first?.document {
            // View archives carry no insertion-base metadata; bake at origin.
            eab = (viewDoc.allLayers, viewDoc.allBlocks, viewDoc.allEntities, .zero)
        } else {
            throw InsertError.importFailed("EAB read failed for \(path)")
        }
        let baked = CADModelSpaceBaker.bake(
            entities: eab.entities,
            layers: eab.layers,
            blocks: eab.blocks,
            basePoint: eab.base)
        guard !baked.geometry.isEmpty else { throw InsertError.emptyDrawing(path) }
        return (baked, bundle)
    }

    // MARK: - Unit bake helpers

    private static func scaledAttributeDefinition(
        _ def: CADAttributeDefinition, by s: Double
    ) -> CADAttributeDefinition {
        var out = def
        out.position = Vector3(
            x: def.position.x * s, y: def.position.y * s, z: def.position.z * s)
        out.height = def.height * s
        return out
    }

    /// Strictly 1-to-1 uniform scaler (unlike the general transformer it
    /// never tessellates arcs/circles, so style/xdata index maps survive).
    /// Hatch pattern scales and mtext widths scale with the geometry so the
    /// baked clone renders like an entity-scaled whole-file import.
    static func uniformScalePrimitives(_ prims: [CADPrimitive], by s: Double) -> [CADPrimitive] {
        func p(_ v: Vector3) -> Vector3 {
            Vector3(x: v.x * s, y: v.y * s, z: v.z * s)
        }
        return prims.map { prim in
            switch prim {
            case .point(let position, let color):
                return .point(position: p(position), color: color)
            case .line(let start, let end, let color):
                return .line(start: p(start), end: p(end), color: color)
            case .rect(let origin, let size, let color):
                return .rect(origin: p(origin), size: p(size), color: color)
            case .fillRect(let origin, let size, let color):
                return .fillRect(origin: p(origin), size: p(size), color: color)
            case .polygon(let points, let color):
                return .polygon(points: points.map(p), color: color)
            case .polyline(let path, let color):
                var scaled = path
                scaled.vertices = path.vertices.map {
                    CADPolylineVertex(
                        position: p($0.position), bulge: $0.bulge,
                        startWidth: $0.startWidth * s, endWidth: $0.endWidth * s)
                }
                return .polyline(path: scaled, color: color)
            case .fillPolygon(let points, let color):
                return .fillPolygon(points: points.map(p), color: color)
            case .fillComplexPolygon(let outer, let holes, let color):
                return .fillComplexPolygon(
                    outer: outer.map(p), holes: holes.map { $0.map(p) }, color: color)
            case .gradient(let outer, let holes, let name, let angle, let c1, let c2):
                return .gradient(
                    outer: outer.map(p), holes: holes.map { $0.map(p) },
                    gradientName: name, angle: angle, color1: c1, color2: c2)
            case .circle(let center, let radius, let color):
                return .circle(center: p(center), radius: radius * s, color: color)
            case .arc(let center, let radius, let startAngle, let endAngle, let color):
                return .arc(
                    center: p(center), radius: radius * s,
                    startAngle: startAngle, endAngle: endAngle, color: color)
            case .spline(let controlPoints, let knots, let degree, let weights, let color):
                return .spline(
                    controlPoints: controlPoints.map(p), knots: knots,
                    degree: degree, weights: weights, color: color)
            case .penStroke(let vertices, let baseLineWeight, let color):
                return .penStroke(
                    vertices: vertices.map {
                        PenStrokeVertex(
                            position: p($0.position), pressure: $0.pressure,
                            xtilt: $0.xtilt, ytilt: $0.ytilt, rotation: $0.rotation)
                    },
                    baseLineWeight: baseLineWeight * s, color: color)
            case .text(let position, let text, let height, let rotation, let style,
                       let alignH, let alignV, let mtextWidth, let color):
                return .text(
                    position: p(position), text: text, height: height * s,
                    rotation: rotation, style: style, alignH: alignH, alignV: alignV,
                    mtextWidth: mtextWidth.map { $0 * s }, color: color)
            case .ellipse(let center, let majorAxis, let minorRatio, let color):
                return .ellipse(center: p(center), majorAxis: p(majorAxis),
                                minorRatio: minorRatio, color: color)
            case .hatch(let boundary, let pattern, let scale, let angle, let color, let background):
                return .hatch(
                    boundary: boundary.map(p), pattern: pattern, scale: scale * s,
                    angle: angle, color: color, backgroundColor: background)
            case .hatchPath(let boundary, let holes, let pattern, let scale, let angle, let color, let background):
                var scaledBoundary = boundary
                scaledBoundary.vertices = boundary.vertices.map {
                    CADPolylineVertex(position: p($0.position), bulge: $0.bulge,
                                      startWidth: $0.startWidth * s, endWidth: $0.endWidth * s)
                }
                return .hatchPath(
                    boundary: scaledBoundary,
                    holes: holes.map { hole in
                        var scaledHole = hole
                        scaledHole.vertices = hole.vertices.map {
                            CADPolylineVertex(position: p($0.position), bulge: $0.bulge,
                                              startWidth: $0.startWidth * s, endWidth: $0.endWidth * s)
                        }
                        return scaledHole
                    },
                    pattern: pattern, scale: scale * s, angle: angle,
                    color: color, backgroundColor: background)
            case .ray(let start, let direction, let color):
                return .ray(start: p(start), direction: p(direction), color: color)
            case .xline(let point, let direction, let color):
                return .xline(point: p(point), direction: p(direction), color: color)
            case .image(let insertion, let uAxis, let vAxis, let imageName, let clipBoundary, let tint):
                return .image(
                    insertion: p(insertion), uAxis: p(uAxis), vAxis: p(vAxis),
                    imageName: imageName, clipBoundary: clipBoundary?.map(p), tint: tint)
            case .table(let data, let origin, let color):
                return .table(data: data, origin: p(origin), color: color)
            }
        }
    }
}
