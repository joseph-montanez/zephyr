import XCTest
@testable import ZephyrCore

@MainActor
final class BlockEditorExitTests: XCTestCase {
    func testDiscardExitRestoresParentDocumentAndRequestsRegeneration() {
        let manager = TabManager()
        _ = manager.newTab()
        let parent = manager.activeDocument
        let block = CADBlock(
            name: "ExitBlock",
            geometry: [
                .line(
                    start: Vector3(x: 0, y: 0, z: 0),
                    end: Vector3(x: 10, y: 0, z: 0),
                    color: .white)
            ])
        parent.importLayersBlocksEntities(layers: [], blocks: [block], entities: [])
        // Simulate the parent drawing having already been rendered before
        // entering the block editor.
        parent.needsRegeneration = false

        manager.enterBlockEditor(blockID: block.handle)
        XCTAssertEqual(manager.activeTab?.editingBlockID, block.handle)
        XCTAssertFalse(manager.activeDocument === parent)

        manager.exitBlockEditor(saveChanges: false)

        XCTAssertNil(manager.activeTab?.editingBlockID)
        XCTAssertTrue(manager.activeDocument === parent)
        XCTAssertTrue(
            parent.needsRegeneration,
            "restoring the parent document must request regeneration even when block edits are discarded")
    }

    func testRenderContextSupersedesWhenDocumentObjectChangesAtSameRevision() {
        let context = WindowRenderContext(
            geometry: GeometryManager(),
            sprites: SpriteManager(),
            bridge: CADRendererBridge())
        let blockEditorDocument = CADDocument()
        let parentDocument = CADDocument()
        XCTAssertEqual(blockEditorDocument.editRevision, parentDocument.editRevision)

        XCTAssertTrue(context.supersedeIfDocumentChanged(to: blockEditorDocument))
        context.appliedGeneration = context.regenGeneration
        context.builtRevision = blockEditorDocument.editRevision
        let builtGeneration = context.regenGeneration

        XCTAssertFalse(context.supersedeIfDocumentChanged(to: blockEditorDocument))
        XCTAssertEqual(context.regenGeneration, builtGeneration)

        XCTAssertTrue(context.supersedeIfDocumentChanged(to: parentDocument))
        XCTAssertEqual(context.regenGeneration, builtGeneration + 1)
        XCTAssertEqual(context.appliedGeneration, -1)
        XCTAssertNil(context.builtRevision)
        XCTAssertNil(context.pendingRevision)
    }
}
