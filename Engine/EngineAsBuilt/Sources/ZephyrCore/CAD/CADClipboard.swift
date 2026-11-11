import Foundation

// =========================================================================
// MARK: - CADClipboard
//
// In-process clipboard for CAD copy/paste across document tabs. There is
// one engine and one command processor, so the entry survives tab switches
// (see TabManager.switchToTab). No OS clipboard serialization: geometry
// stays as value-type CADEntity/CADBlock copies.
//
//   - COPYCLIP  → snapshots selection; anchor = lower-left of bounds
//   - COPYBASE  → same, but anchor = picked base point
//   - PASTECLIP → interactive insertion-point prompt, ghost at cursor
//   - PASTEORIG → duplicates at (unit-scaled) original coordinates
//   - PASTEBLOCK→ bundles the entry into one anonymous *A block
//
// Cross-document paste remaps by NAME (target wins), never by UUID:
// layers, blocks, and styles resolve case-insensitively against the
// target document; missing definitions are imported. See
// CADClipboardImport for the single commit path.
// =========================================================================

// MARK: - CADClipboardEntry

/// A single clipboard entry: copied entities plus every definition needed
/// to paste them into a different document and render identically.
public struct CADClipboardEntry: Sendable {
    /// Deep-copied entities captured at COPYCLIP/COPYBASE time.
    /// Handles are source-document handles — regenerated at paste time.
    public let entities: [CADEntity]

    /// Block definitions referenced by the copied entities.
    /// Keyed by source-document block handle — remapped at paste time.
    public let blocks: [UUID: CADBlock]

    /// Layers referenced by the copied entities (entity layers plus any
    /// layers named by block primitive styles). Keyed by source handle.
    public let layers: [UUID: Layer]

    /// Named styles referenced by the copied content. Merged skip-if-exists
    /// (same rule as DrawingFileInsert.mergeBundleSymbols).
    public let textStyles: [String: CADTextStyle]
    public let dimensionStyles: [String: CADDimensionStyle]
    public let leaderStyles: [String: CADLeaderStyle]
    /// Linetype patterns, keyed by uppercased name (document convention).
    public let linetypePatterns: [String: [Double]]

    /// Image assets + referenced-media definitions used by the content.
    public let imageAssets: [String: CADImageAsset]
    public let imageDefinitions: [String: CADImageDefinition]
    public let pdfDefinitions: [String: CADPdfDefinition]

    /// Source drawing unit for INSUNITS scaling at paste time.
    /// Nil (unspecified) pastes 1:1 like CADModelSpaceBaker.unitScale.
    public let sourceUnit: CADUnit?

    /// Anchor in source world coordinates. COPYBASE stores the picked
    /// point; COPYCLIP stores the lower-left of the selection bounds.
    /// Pasted entities offset so this point lands at the insertion point.
    public let basePoint: Vector3

    public init(
        entities: [CADEntity],
        blocks: [UUID: CADBlock] = [:],
        layers: [UUID: Layer] = [:],
        textStyles: [String: CADTextStyle] = [:],
        dimensionStyles: [String: CADDimensionStyle] = [:],
        leaderStyles: [String: CADLeaderStyle] = [:],
        linetypePatterns: [String: [Double]] = [:],
        imageAssets: [String: CADImageAsset] = [:],
        imageDefinitions: [String: CADImageDefinition] = [:],
        pdfDefinitions: [String: CADPdfDefinition] = [:],
        sourceUnit: CADUnit? = nil,
        basePoint: Vector3
    ) {
        self.entities = entities
        self.blocks = blocks
        self.layers = layers
        self.textStyles = textStyles
        self.dimensionStyles = dimensionStyles
        self.leaderStyles = leaderStyles
        self.linetypePatterns = linetypePatterns
        self.imageAssets = imageAssets
        self.imageDefinitions = imageDefinitions
        self.pdfDefinitions = pdfDefinitions
        self.sourceUnit = sourceUnit
        self.basePoint = basePoint
    }
}

// MARK: - CADClipboard

/// Holds at most one clipboard entry at a time (AutoCAD-style single-entry clipboard).
public struct CADClipboard: Sendable {
    /// The current clipboard entry, or nil if nothing has been copied.
    public var entry: CADClipboardEntry?

    /// Whether the clipboard holds entity data that can be pasted.
    public var hasEntities: Bool { entry != nil }

    public init() {}
}
