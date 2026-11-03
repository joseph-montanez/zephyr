import Foundation

// =========================================================================
// MARK: - DrawingViewFactory
// -------------------------------------------------------------------------
// Single shared funnel from a `DXFImportResult` (DXF / DWT directly, DWG
// via the ODA temporary-DXF path) to tab-ready `[DrawingView]`.
//
// Used by both `TabManager.openTab` (file opening) and the publish
// execution loader (publish loading) so per-view document assembly —
// shared layers/blocks, per-view entities, text/media/linetype/style
// tables, paper-space group scoping, plot settings, units, saved
// revision, and open-time FIELD identity — cannot drift between the two.
// =========================================================================

public enum DrawingViewFactory {

    /// Build one `DrawingView` per imported view.
    ///
    /// Model views own the model-space groups; sheet views own their
    /// paper-space groups (projected copies never join groups).
    /// Freshly imported documents are clean (`savedRevision` synced) with
    /// open-time `$FILENAME` / `$TABNAME` FIELD identity recorded.
    public static func makeDrawingViews(
        from imported: DXFImportResult,
        sourceFileName: String
    ) -> [DrawingView] {
        imported.views.map { view -> DrawingView in
            let doc = CADDocument()
            doc.importLayersBlocksEntities(
                layers: imported.layers,
                blocks: imported.blocks,
                entities: view.entities
            )
            doc.textStyles = imported.textStyles
            doc.importMediaDefinitions(
                image: imported.imageDefinitions, pdf: imported.pdfDefinitions)
            doc.linetypePatterns = imported.linetypePatterns
            doc.dimensionStyles = imported.dimensionStyles
            doc.leaderStyles = imported.leaderStyles
            let viewGroups = view.kind == .sheet ? view.groups : imported.groups
            doc.groups = Dictionary(
                uniqueKeysWithValues: viewGroups.map { ($0.name, $0) })
            doc.plotSettings = view.plotSettings
            doc.paperSpaceLinetypeScale = imported.paperSpaceLinetypeScale
            doc.pstyleMode = imported.pstyleMode
            doc.insertionBase = imported.insBase
            doc.dxfRoundTripPayload = imported.roundTripPayload
            doc.currentLeaderStyleName = imported.leaderStyles["Standard"] == nil
                ? (imported.leaderStyles.keys.sorted().first ?? "Standard")
                : "Standard"
            if let ls = view.layoutSettings {
                doc.layoutSettings = ls
                doc.unit = (ls.plotPaperUnits == 0) ? .inch : .millimeter
            } else if let su = imported.sourceUnit {
                doc.unit = su
            }
            doc.savedRevision = doc.editRevision // freshly imported
            doc.finalizeOpen(
                sourceFileName: sourceFileName, layoutName: view.name)
            return DrawingView(
                name: view.name,
                kind: view.kind,
                document: doc,
                backgroundColor: view.backgroundColor
            )
        }
    }

    /// Snapshot every view document keyed by view name for background
    /// consumers (publish execution). Snapshots are value types: the live
    /// drawings are never touched again after this returns.
    public static func snapshotViews(
        _ views: [DrawingView]
    ) -> [String: CADDocumentSnapshot] {
        Dictionary(
            views.map { ($0.name, $0.document.snapshot()) },
            uniquingKeysWith: { first, _ in first })
    }
}
