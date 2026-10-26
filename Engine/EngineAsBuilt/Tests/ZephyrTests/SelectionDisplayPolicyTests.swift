import XCTest
@testable import ZephyrCore

/// AutoCAD selection-display rules:
/// - GRIPOBJLIMIT: over the limit grips are suppressed entirely; loose
///   entities keep a geometry highlight and never get per-entity boxes.
/// - SELECTIONPREVIEWLIMIT: over the limit rect-select preview highlight
///   is disabled for the whole set.
/// - GROUPDISPLAYMODE: a group collapses to one union frame, not one
///   frame per member. Blocks/xrefs and images may show their own frame.
@MainActor
final class SelectionDisplayPolicyTests: XCTestCase {

    func testGripSuppressionBoundary() {
        XCTAssertFalse(CADSelectionDisplayPolicy.gripsSuppressed(
            selectedCount: 100, gripObjectLimit: 100))
        XCTAssertTrue(CADSelectionDisplayPolicy.gripsSuppressed(
            selectedCount: 101, gripObjectLimit: 100))
        XCTAssertFalse(CADSelectionDisplayPolicy.gripsSuppressed(
            selectedCount: 0, gripObjectLimit: 100))
    }

    func testGripHandlesEmptyWhenSuppressed() {
        let handles = Set((0..<101).map { _ in UUID() })
        XCTAssertTrue(CADSelectionDisplayPolicy.gripHandles(
            selectedHandles: handles, gripObjectLimit: 100).isEmpty)
        let under = Set(handles.prefix(100))
        XCTAssertEqual(CADSelectionDisplayPolicy.gripHandles(
            selectedHandles: under, gripObjectLimit: 100), under)
    }

    func testPreviewSuppressionBoundary() {
        let limit = CADSelectionDisplayPolicy.defaultSelectionPreviewLimit
        XCTAssertFalse(CADSelectionDisplayPolicy.previewSuppressed(
            previewCount: limit, selectionPreviewLimit: limit))
        XCTAssertTrue(CADSelectionDisplayPolicy.previewSuppressed(
            previewCount: limit + 1, selectionPreviewLimit: limit))
    }

    func testLooseEntitiesNeverGetBoundingFrame() {
        // Even a primitive-heavy loose entity is highlighted by geometry,
        // not replaced with a wireframe box.
        for count in [1, 50, 51, 5000] {
            XCTAssertEqual(
                CADSelectionDisplayPolicy.highlightStyle(
                    isImage: false, isBlockReference: false,
                    primitiveCount: count),
                .geometry, "primitiveCount \(count)")
        }
    }

    func testBlockAndImageFrames() {
        XCTAssertEqual(
            CADSelectionDisplayPolicy.highlightStyle(
                isImage: true, isBlockReference: false, primitiveCount: 1),
            .boundingFrame)
        XCTAssertEqual(
            CADSelectionDisplayPolicy.highlightStyle(
                isImage: false, isBlockReference: true, primitiveCount: 51),
            .boundingFrame)
        XCTAssertEqual(
            CADSelectionDisplayPolicy.highlightStyle(
                isImage: false, isBlockReference: true, primitiveCount: 50),
            .geometry)
    }

    func testGroupUnionBoundsIsSingleFrame() {
        let boxes = [
            BoundingBox3D(min: Vector3(x: 0, y: 0, z: 0),
                          max: Vector3(x: 2, y: 3, z: 0)),
            BoundingBox3D(min: Vector3(x: -1, y: 1, z: 0),
                          max: Vector3(x: 5, y: 2, z: 0)),
        ]
        let union = CADSelectionDisplayPolicy.unionBounds(of: boxes)
        XCTAssertEqual(union?.min, Vector3(x: -1, y: 0, z: 0))
        XCTAssertEqual(union?.max, Vector3(x: 5, y: 3, z: 0))
        XCTAssertEqual(union?.center, Vector3(x: 2, y: 1.5, z: 0))
        XCTAssertNil(CADSelectionDisplayPolicy.unionBounds(of: []))
    }

    func testGripGenerationHonorsLimit() {
        // Grip *generation* (not just drawing) stops over GRIPOBJLIMIT,
        // so suppressed grips cannot be hovered or dragged invisibly.
        let doc = CADDocument()
        let layer = Layer(name: "0")
        var entities: [CADEntity] = []
        for i in 0..<3 {
            entities.append(CADEntity(
                layerID: layer.handle,
                localGeometry: [.line(
                    start: Vector3(x: Double(i * 10), y: 0, z: 0),
                    end: Vector3(x: Double(i * 10 + 5), y: 0, z: 0))],
                transform: .identity))
        }
        doc.importLayersBlocksEntities(
            layers: [layer], blocks: [], entities: entities)
        let handles = Set(entities.map(\.handle))
        let cam = CameraTransform(
            camX: 0, camY: 0, camZoom: 1, camSin: 0, camCos: 1,
            screenCenterX: 400, screenCenterY: 300)

        let overLimit = CADGripSystem.getAllGrips(
            document: doc, cam: cam, simplifyComplexBlocks: true,
            selectedHandles: handles, gripObjectLimit: 2)
        XCTAssertTrue(overLimit.isEmpty)

        let underLimit = CADGripSystem.getAllGrips(
            document: doc, cam: cam, simplifyComplexBlocks: true,
            selectedHandles: handles, gripObjectLimit: 100)
        XCTAssertFalse(underLimit.isEmpty)
    }

    func testFrameRequiredMatchesHighlightStyle() {
        let doc = CADDocument()
        let layer = Layer(name: "0")
        let loose = CADEntity(
            layerID: layer.handle,
            localGeometry: [.line(
                start: .zero,
                end: Vector3(x: 1, y: 0, z: 0))],
            transform: .identity)
        let image = CADEntity(
            layerID: layer.handle,
            localGeometry: [.image(
                insertion: .zero,
                uAxis: Vector3(x: 1, y: 0, z: 0),
                vAxis: Vector3(x: 0, y: 1, z: 0),
                imageName: "frame-test")],
            transform: .identity)
        let simpleBlock = CADBlock(
            name: "SimpleFrame",
            geometry: [.line(start: .zero, end: Vector3(x: 1, y: 0, z: 0))])
        let complexBlock = CADBlock(
            name: "ComplexFrame",
            geometry: (0..<51).map { i in
                CADPrimitive.line(
                    start: Vector3(x: Double(i), y: 0, z: 0),
                    end: Vector3(x: Double(i) + 1, y: 0, z: 0))
            })
        let simpleInstance = CADEntity(
            layerID: layer.handle, blockID: simpleBlock.handle,
            transform: .identity)
        let complexInstance = CADEntity(
            layerID: layer.handle, blockID: complexBlock.handle,
            transform: .identity)
        doc.importLayersBlocksEntities(
            layers: [layer],
            blocks: [simpleBlock, complexBlock],
            entities: [loose, image, simpleInstance, complexInstance])

        // Loose entities keep the geometry highlight: no frame required,
        // even over GRIPOBJLIMIT.
        XCTAssertFalse(CADSelectionHighlightRenderer.frameRequired(
            handle: loose.handle, document: doc))
        XCTAssertFalse(CADSelectionHighlightRenderer.frameRequired(
            handle: simpleInstance.handle, document: doc))
        // Images and complex block references highlight as frames.
        XCTAssertTrue(CADSelectionHighlightRenderer.frameRequired(
            handle: image.handle, document: doc))
        XCTAssertTrue(CADSelectionHighlightRenderer.frameRequired(
            handle: complexInstance.handle, document: doc))
        XCTAssertFalse(CADSelectionHighlightRenderer.frameRequired(
            handle: UUID(), document: doc))
    }
}
