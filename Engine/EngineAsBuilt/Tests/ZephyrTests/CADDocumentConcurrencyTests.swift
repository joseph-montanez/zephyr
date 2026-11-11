import XCTest
@testable import ZephyrCore

/// Regression test for the AutoLISP crash: main-thread reads
/// (`entityCount`, `entitiesView`, status snapshot, layer lookup) raced
/// detached-evaluator writes (`addEntity`, `removeEntities`, `restore`).
/// Every shared-dictionary access now serializes on `documentLock`.
final class CADDocumentConcurrencyTests: XCTestCase {
    private final class DocumentBox: @unchecked Sendable {
        let document: CADDocument
        init(_ document: CADDocument) { self.document = document }
    }

    private func makeDocument(seedEntities: Int) -> (CADDocument, UUID) {
        let document = CADDocument()
        let layer = Layer(name: "0", color: .white)
        let entities = (0..<seedEntities).map { _ in
            CADEntity(layerID: layer.handle, transform: .identity)
        }
        document.importLayersBlocksEntities(
            layers: [layer], blocks: [], entities: entities)
        document.activeLayerID = layer.handle
        return (document, layer.handle)
    }

    /// Writer stress: add/remove/restore/undo (what a Lisp `(command ...)`
    /// loop does) while readers poll every main-thread read path, including
    /// the exact status-bar call from the crash backtrace.
    func testConcurrentWritesAndStatusReads() async throws {
        let (document, layerID) = makeDocument(seedEntities: 500)
        let box = DocumentBox(document)
        let iterations = 300

        await withTaskGroup(of: Void.self) { group in
            group.addTask { @Sendable in
                let doc = box.document
                for i in 0..<iterations {
                    let entity = CADEntity(layerID: layerID, transform: .identity)
                    doc.addEntity(entity)
                    if i % 3 == 0 {
                        doc.removeEntities(handles: [entity.handle])
                    }
                    if i % 10 == 0 {
                        let snap = doc.snapshot()
                        doc.restore(from: snap)
                    }
                    if i % 25 == 0 { doc.undo() }
                }
            }
            group.addTask { @Sendable in
                let doc = box.document
                for _ in 0..<iterations {
                    _ = doc.entityCount
                    _ = Array(doc.entitiesView)
                    _ = doc.statusBarSnapshot()
                    _ = doc.withEntities { $0.count }
                    _ = doc.layer(for: layerID)
                    _ = doc.allEntities
                    _ = doc.snapshot()
                    let tab = DocumentTab(
                        displayName: "Stress.dxf",
                        drawingViews: [DrawingView(
                            name: "Model", kind: .model, document: doc)])
                    _ = StatusBarUIPolicy.shownInfo(tab: tab, viewIndex: 0)
                }
            }
        }

        let count = document.entityCount
        XCTAssertEqual(count, document.allEntities.count)
        XCTAssertEqual(count, document.statusBarSnapshot().entityCount)
        XCTAssertEqual(count, document.withEntities { $0.count })
        XCTAssertGreaterThanOrEqual(count, 500)
        for entity in document.allEntities {
            XCTAssertEqual(entity.layerID, layerID)
        }
    }
}
