import Foundation
import SwiftSDL
import ZephyrCore

// =========================================================================
// MARK: - Archive / font gates (Phase 2)
// =========================================================================
//
// The EAB and SHX work is a pure refactor of byte handling, so the gate is "the bytes and the parsed
// result are unchanged". Three checks:
//
//   * `eab-scalars`   — encodes a fixed sequence of scalars through `BinaryWriter` and hashes the
//                       exact bytes. Pins byte order, widths and the reserve/fill patching.
//   * `eab-roundtrip` — builds a document, serializes it, reads it back and digests the result
//                       (UUID-free, so it is stable across runs).
//   * `shx-render`    — parses an SHX font and digests the rendered geometry for a fixed string.
//
// Golden files live next to the DXF ones in `Tools/bench/golden/`.

extension Cases {

    // MARK: Canonical document description

    /// Canonical, UUID-free description of a document's contents.
    ///
    /// Shared by the DXF and EAB digests. UUIDs are deliberately excluded everywhere: entity handles
    /// and layer/block ids are generated per import/load, so including them would make every run
    /// produce a different digest and no baseline could ever match.
    static func canonicalDocumentLines(
        layers: [Layer],
        blocks: [CADBlock],
        entities: [CADEntity]
    ) -> [String] {
        var lines: [String] = []
        let layerNamesByID = Dictionary(uniqueKeysWithValues: layers.map { ($0.handle, $0.name) })
        let blockNamesByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.handle, $0.name) })

        let sortedLayers = layers.sorted { $0.name < $1.name }
        lines.append("layerCount: \(sortedLayers.count)")
        for layer in sortedLayers {
            lines.append("layer: \(layer.name) c=\(layer.color.r),\(layer.color.g),\(layer.color.b),\(layer.color.a)"
                + " lw=\(layer.lineWeight) lt=\(layer.lineType) vis=\(layer.isVisible) op=\(layer.opacity)")
        }

        let sortedBlocks = blocks.sorted { $0.name < $1.name }
        lines.append("blockCount: \(sortedBlocks.count)")
        for block in sortedBlocks {
            let hash = Self.fnv(String(describing: block.geometry))
            lines.append("block: \(block.name) geometry=\(block.geometry.count) hash=\(hash)")
        }

        var entityLines: [String] = []
        var byPrimitive: [String: Int] = [:]
        for entity in entities {
            let kind = entity.localGeometry?.first.map { Self.primitiveCaseName($0) } ?? "block-instance"
            byPrimitive[kind, default: 0] += 1
            let geometry = entity.localGeometry.map { String(describing: $0) } ?? "<block-instance>"
            entityLines.append(
                "entity: kind=\(kind)"
                + " layer=\(layerNamesByID[entity.layerID] ?? "?")"
                + " block=\(entity.blockID.flatMap { blockNamesByID[$0] } ?? "-")"
                + " geomCount=\(entity.localGeometry?.count ?? 0)"
                + " transform=\(Self.fnv(String(describing: entity.transform)))"
                + " geometry=\(Self.fnv(geometry))")
        }
        entityLines.sort()
        lines.append("entityCount: \(entities.count)")
        lines.append(contentsOf: entityLines)
        for (kind, count) in byPrimitive.sorted(by: { $0.key < $1.key }) {
            lines.append("primitiveKind: \(kind) count=\(count)")
        }
        return lines
    }

    // MARK: - EAB scalar encoding

    /// Encodes one fixed sequence through `BinaryWriter` — the exact bytes are the point.
    static func eabScalarsDigest() -> String {
        let writer = BinaryWriter()
        writer.writeUInt8(0x12)
        writer.writeUInt16(0x3456)
        writer.writeUInt32(0x789A_BCDE)
        writer.writeInt32(-2)
        writer.writeUInt64(0x0123_4567_89AB_CDEF)
        writer.writeFloat32(1.5)
        writer.writeFloat64(-2.25)
        writer.writeUUID(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!)
        writer.writeString("Header")           // 2-byte length prefix + UTF-8 bytes
        writer.writeBytes(Data([0xAA, 0xBB]))
        writer.writeZeros(3)
        writer.pad(to: 8)
        let patchOffset = writer.reserveUInt32()
        writer.writeString("tail")
        writer.fillUInt32(at: patchOffset, value: 0xDEAD_BEEF)

        let bytes = writer.bytes
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return [
            "scalarBytes: \(bytes.count)",
            "hex: \(hex)",
        ].joined(separator: "\n")
    }

    // MARK: - EAB round-trip

    /// Serializes a document covering every primitive kind, reads it back, and digests the result.
    static func eabRoundtripDigest() throws -> String {
        let document = CADDocument()

        let layer = Layer(name: "GateLayer", color: ColorRGBA(r: 10, g: 20, b: 30, a: 255))
        document.importLayersBlocksEntities(layers: [layer], blocks: [], entities: [])

        let primitives: [CADPrimitive] = [
            .point(position: Vector3(x: 1, y: 2, z: 3), color: ColorRGBA(r: 255, g: 0, b: 0, a: 255)),
            .line(start: Vector3(x: 0, y: 0, z: 0), end: Vector3(x: 10, y: 5, z: 1)),
            .rect(origin: Vector3(x: 2, y: 3, z: 0), size: Vector3(x: 4, y: 6, z: 0)),
            .fillRect(origin: Vector3(x: 1, y: 1, z: 0), size: Vector3(x: 2, y: 2, z: 0)),
            .polygon(points: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 1, y: 0, z: 0), Vector3(x: 1, y: 1, z: 0)]),
            .fillPolygon(points: [Vector3(x: 0, y: 0, z: 0), Vector3(x: 2, y: 0, z: 0), Vector3(x: 2, y: 2, z: 0)]),
            .circle(center: Vector3(x: 5, y: 5, z: 0), radius: 3.5),
            .arc(center: Vector3(x: 0, y: 0, z: 0), radius: 4.0, startAngle: 0.5, endAngle: 2.5),
            .polyline(path: CADPolyline(vertices: [
                CADPolylineVertex(position: Vector3(x: 0, y: 0, z: 0)),
                CADPolylineVertex(position: Vector3(x: 5, y: 0, z: 0)),
                CADPolylineVertex(position: Vector3(x: 5, y: 5, z: 0), bulge: 0.25),
            ], isClosed: true)),
            .text(
                position: Vector3(x: 40, y: 41, z: 42),
                text: "Roundtrip Gate",
                height: 2.5,
                rotation: 0.78,
                style: "FancyStyle",
                alignH: 1,
                alignV: 2,
                mtextWidth: 15.0,
                color: ColorRGBA(r: 0, g: 0, b: 255, a: 255)),
        ]

        let block = CADBlock(name: "GateBlock", geometry: primitives)
        document.importLayersBlocksEntities(layers: [], blocks: [block], entities: [])

        let entity = CADEntity(layerID: layer.handle, blockID: block.handle, transform: .identity)
        document.importLayersBlocksEntities(layers: [], blocks: [], entities: [entity])

        let archive = try EABWriter.serialize(document: document)
        let restored = try EABReader.readDocument(from: archive)

        var lines = [
            "archiveBytes: \(archive.count)",
            "restoredLayers: \(restored.layers.count)",
            "restoredBlocks: \(restored.blocks.count)",
            "restoredEntities: \(restored.entities.count)",
        ]
        lines.append(contentsOf: canonicalDocumentLines(
            layers: restored.layers,
            blocks: restored.blocks,
            entities: restored.entities))
        return lines.joined(separator: "\n")
    }

    // MARK: - Vertex buffer building

    /// Tessellates a deterministic primitive set through `CADVertexBufferBuilder.tessellate` and
    /// digests the result.
    ///
    /// Exists so the vertex path (where `withUnsafeMutableBufferPointer` still appears) has a gate:
    /// the entity-index tagging pass is the part that gets rewritten, and the histogram below covers it
    /// exhaustively rather than by sampling.
    static func vertexBuildDigest() -> String {
        var inputs: [TessInput] = []
        let colors: [(UInt8, UInt8, UInt8, UInt8)] = [
            (255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255), (255, 255, 255, 128),
        ]

        for index in 0..<50 {
            let baseX = Float(index) * 3.0
            let points = (0..<8).map { step in
                SDL_FPoint(x: baseX + Float(step) * 0.75, y: Float((index * step) % 7) * 1.25)
            }
            inputs.append(TessInput(
                type: .line,
                points: points,
                rects: [],
                corners: [],
                color: colors[index % colors.count],
                lineWeight: 0.25 * Double(index % 5),
                geomWidth: index % 3 == 0 ? 0.4 : 0.0,
                segmentLineWeights: [],
                entityIndex: UInt32(index + 1),
                isHatchLine: index % 7 == 0,
                hatchSpacing: index % 7 == 0 ? 1.5 : 0.0,
                isPanProxy: index % 11 == 0,
                gradientData: nil))
        }

        for index in 0..<20 {
            inputs.append(TessInput(
                type: .fillRect,
                points: [],
                rects: [SDL_FRect(x: Float(index), y: Float(index) * 0.5, w: 2.0, h: 1.0)],
                corners: [],
                color: colors[(index + 1) % colors.count],
                lineWeight: 0.0,
                geomWidth: 0.0,
                segmentLineWeights: [],
                entityIndex: UInt32(index + 100),
                isHatchLine: false,
                hatchSpacing: 0.0,
                isPanProxy: false,
                gradientData: nil))
        }

        guard let result = CADVertexBufferBuilder.tessellate(
            inputs,
            cameraZoom: 1.25,
            pixelScale: 2.0,
            antiAliasLines: true,
            hairlineQuads: true,
            region: (minX: -10, minY: -10, maxX: 200, maxY: 200),
            mutationGen: 7
        ) else {
            return "cancelled: true"
        }

        var byEntity: [UInt32: Int] = [:]
        for vertex in result.vertices {
            byEntity[vertex.entityIndex, default: 0] += 1
        }
        var byPipeline: [String: Int] = [:]
        for batch in result.batches {
            byPipeline["\(batch.pipelineType)", default: 0] += 1
        }

        var lines = [
            "inputs: \(inputs.count)",
            "vertexCount: \(result.vertexCount)",
            "vertexArrayCount: \(result.vertices.count)",
            "batchCount: \(result.batches.count)",
            "mutationGen: \(result.mutationGen)",
            "region: \(result.regionMinX),\(result.regionMinY),\(result.regionMaxX),\(result.regionMaxY)",
            "zoom: \(result.builtZoom)",
        ]
        for (pipeline, count) in byPipeline.sorted(by: { $0.key < $1.key }) {
            lines.append("pipeline: \(pipeline) batches=\(count)")
        }
        for (entity, count) in byEntity.sorted(by: { $0.key < $1.key }) {
            lines.append("entityIndex: \(entity) vertices=\(count)")
        }
        lines.append("verticesHash: \(Self.fnv(String(describing: result.vertices)))")
        return lines.joined(separator: "\n")
    }

    // MARK: - DXF export round-trip

    /// Imports each fixture, exports it with `DXFExporter`, re-imports the result and digests that.
    ///
    /// Covers the writer side (`DXFWriter` / `DXFWriterBridge`), which the import-only gates never
    /// touch. The export is compared through a round-trip rather than byte-for-byte because exported
    /// handles are derived from per-import UUIDs; `exportLineCount`/`exportBytes` still pin the layout.
    static func dxfRoundtripDigest(directory: String) throws -> String {
        // Pin SHX discovery to the source-tree Fonts beside the golden fixtures.
        // Export header extents use SHX text bounds when a font resolves and an
        // estimated rectangle otherwise, so without this the digest depends on
        // the process working directory and on assets staged next to the binary
        // (Windows CI runs the bench from the repo root before staging Fonts).
        let packageFonts = URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fonts", isDirectory: true)
        if FileManager.default.fileExists(atPath: packageFonts.path) {
            CADFontManager.registerFontDirectory(packageFonts)
        }
        let url = URL(fileURLWithPath: directory)
        let fixtures = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "dxf" }
            .sorted { $0.path < $1.path }

        var lines: [String] = ["fixtures: \(fixtures.count)"]
        for fixture in fixtures {
            let imported = try DXFImporter.importDXFViews(filePath: fixture.path)
            let document = CADDocument()
            document.importLayersBlocksEntities(
                layers: imported.layers, blocks: imported.blocks, entities: imported.entities)

            let exported = FileManager.default.temporaryDirectory
                .appendingPathComponent("zephyr-bench-\(UUID().uuidString).dxf")
            defer { try? FileManager.default.removeItem(at: exported) }
            try DXFExporter.export(document: document, to: exported)

            let exportedData = try Data(contentsOf: exported)
            let reimported = try DXFImporter.importDXFViews(filePath: exported.path)

            lines.append("fixture: \(fixture.lastPathComponent)")
            lines.append("exportBytes: \(exportedData.count)")
            lines.append("exportLineCount: \(exportedData.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 })")
            lines.append(contentsOf: canonicalDocumentLines(
                layers: reimported.layers,
                blocks: reimported.blocks,
                entities: reimported.entities))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - NURBS evaluation

    /// Deterministic spline used by the NURBS gate and the timings case.
    ///
    /// Degree 3 over 12 control points with a clamped uniform knot vector — the shape the DXF importer
    /// produces for a SPLINE entity. A degree-p NURBS over n+1 control points needs n+p+2 knots
    /// (here 11 + 3 + 2 = 16: four 0s, eight interior values, four 1s).
    static func nurbsInputs() -> (degree: Int, knots: [Double], controlPoints: [Vector3], weights: [Double]) {
        let degree = 3
        let controlPoints = (0..<12).map { index in
            Vector3(x: Double(index), y: sin(Double(index) * 0.7) * 3.0, z: Double(index % 3) * 0.5)
        }
        let interiorCount = controlPoints.count - degree - 1
        let knots: [Double] =
            [Double](repeating: 0, count: degree + 1)
            + (1...interiorCount).map { Double($0) / Double(interiorCount + 1) }
            + [Double](repeating: 1, count: degree + 1)
        let weights = controlPoints.indices.map { 1.0 + Double($0 % 3) * 0.25 }   // rational, non-uniform
        return (degree, knots, controlPoints, weights)
    }

    /// Digests every public evaluation entry point, because they all funnel through the internal basis
    /// routine that Phase 3 rewrites (`evaluateAtInternal`).
    static func nurbsDigest() -> String {
        let (degree, knots, controlPoints, weights) = nurbsInputs()
        var lines: [String] = []

        let polyline = NURBSEvaluator.evaluate(
            degree: degree, knots: knots, controlPoints: controlPoints,
            weights: weights, segments: 64)
        lines.append("evaluate: \(polyline.count) points hash=\(Self.fnv(String(describing: polyline)))")

        var samples: [Vector3] = []
        for step in 0...128 {
            let t = Double(step) / 128.0
            if let point = NURBSEvaluator.evaluateAt(
                degree: degree, knots: knots, controlPoints: controlPoints,
                weights: weights, at: t) {
                samples.append(point)
            }
        }
        lines.append("evaluateAt: \(samples.count) samples hash=\(Self.fnv(String(describing: samples)))")

        let byKnotSpans = NURBSEvaluator.evaluateByKnotSpans(
            degree: degree, knots: knots, controlPoints: controlPoints, weights: weights)
        lines.append("evaluateByKnotSpans: \(byKnotSpans.count) points hash=\(Self.fnv(String(describing: byKnotSpans)))")

        let adaptive = NURBSEvaluator.evaluateAdaptiveByKnotSpans(
            degree: degree, knots: knots, controlPoints: controlPoints, weights: weights)
        lines.append("evaluateAdaptiveByKnotSpans: \(adaptive.count) points hash=\(Self.fnv(String(describing: adaptive)))")

        // findClosestParameter is the interactive path (snapping / hit-testing) and calls the internal
        // evaluator in a loop, so it is the caller most affected by the scratch-buffer change.
        for probeIndex in 0..<4 {
            let probe = Vector3(x: Double(probeIndex) * 3.0 - 1.0, y: 0.75, z: 0.0)
            let found = NURBSEvaluator.findClosestParameter(
                degree: degree, knots: knots, controlPoints: controlPoints,
                weights: weights, to: probe)
            lines.append("closest(\(probeIndex)): t=\(found)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - SHX rendering

    /// Parses a shape font and digests the geometry it renders for a fixed string.
    static func shxRenderDigest(path: String) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "ZephyrBench", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "no such SHX font: \(path)",
            ])
        }
        let font = try SHXShapeFont(url: URL(fileURLWithPath: path))
        let sample = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,-()/&%$#@!?"
        let primitives = font.renderText(sample, origin: Vector3(x: 1, y: 2, z: 0), height: 12.0)

        var lines = [
            "font: \((path as NSString).lastPathComponent)",
            "sampleCharacters: \(sample.count)",
            "primitiveCount: \(primitives.count)",
        ]
        var byKind: [String: Int] = [:]
        for primitive in primitives {
            byKind[Self.primitiveCaseName(primitive), default: 0] += 1
        }
        for (kind, count) in byKind.sorted(by: { $0.key < $1.key }) {
            lines.append("primitiveKind: \(kind) count=\(count)")
        }
        lines.append("geometryHash: \(Self.fnv(String(describing: primitives)))")
        return lines.joined(separator: "\n")
    }
}
