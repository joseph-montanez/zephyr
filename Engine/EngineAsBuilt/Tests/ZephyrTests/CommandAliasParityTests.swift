import XCTest
import CSDL3
@testable import ZephyrCore

/// AutoCAD LT alias parity gate (Phase 0 of
/// plans/autocad-lt-command-alignment.md).
///
/// The LT golden rows pin the post-remap state: each input must resolve to
/// the stated canonical command through `matchCommands` (the S1 surface).
/// Exact-alias matches always outrank prefix matches, so these rows are
/// deterministic. The invariant tests pin the structural rules that keep
/// the four dispatch surfaces (S1 descriptors, S2 switch, S3 registry, S4
/// scripted set) from drifting apart again.
@MainActor
final class CommandAliasParityTests: XCTestCase {

    /// (typed input, expected canonical command)
    private static let goldenRows: [(String, String)] = [
        ("AA", "AREA"),
        ("DT", "TEXT"), ("TB", "TABLE"), ("DATATABLE", "TABLE"),
        ("R", "REDRAW"),
        ("RO", "ROTATE"), ("SC", "SCALE"), ("S", "STRETCH"),
        ("D", "DIMSTYLE"), ("PS", "PSPACE"), ("CL", "CENTERLINE"),
        ("PLINE", "PLINE"), ("POLYLINE", "PLINE"), ("PL", "PLINE"),
        ("RECTANG", "RECTANG"), ("RECTANGLE", "RECTANG"),
        ("REC", "RECTANG"), ("RECT", "RECTANG"),
        ("SPLINEDIT", "SPLINEDIT"), ("SPLINEEDIT", "SPLINEDIT"),
        ("SPE", "SPLINEDIT"),
        ("MT", "MTEXT"), ("T", "MTEXT"), ("MTEXT", "MTEXT"),
        ("TEXT", "TEXT"), ("DTEXT", "TEXT"),
        ("TEXTEDIT", "TEXTEDIT"), ("TEDIT", "TEXTEDIT"),
        ("DDEDIT", "TEXTEDIT"), ("ED", "TEXTEDIT"),
        ("EPDF", "EXPORTPDF"), ("PDFEXPORT", "EXPORTPDF"),
        ("EXPORTPDF", "EXPORTPDF"),
        ("ME", "MEASURE"), ("JOG", "DIMJOGGED"),
        ("DCO", "DIMCONTINUE"), ("DIMCONTINUE", "DIMCONTINUE"),
        ("DBA", "DIMBASELINE"), ("DIMBASELINE", "DIMBASELINE"),
        ("DIM", "DIM"),
        ("CM", "CENTERMARK"), ("CENTERMARK", "CENTERMARK"),
        ("DCE", "DIMCENTER"), ("DIMCENTER", "DIMCENTER"),
        ("DIMREASSOCIATE", "DIMREASSOCIATE"), ("DRE", "DIMREASSOCIATE"),
        ("DIMDISASSOCIATE", "DIMDISASSOCIATE"), ("DDA", "DIMDISASSOCIATE"),
        ("DIMEDIT", "DIMEDIT"), ("DED", "DIMEDIT"),
        ("DIMTEDIT", "DIMTEDIT"),
        ("DIMBREAK", "DIMBREAK"),
        ("DIMSPACE", "DIMSPACE"),
        ("FIND", "FIND"),
        ("TEXTALIGN", "TEXTALIGN"), ("TA", "TEXTALIGN"),
        ("TXT2MTXT", "TXT2MTXT"),
        ("FIELD", "FIELD"),
        ("B", "BLOCK"), ("BMAKE", "BLOCK"),
        ("XR", "XREF"), ("ER", "XREF"),
        ("IAT", "IMAGEATTACH"),
        ("UN", "UNITS"), ("UNIT", "UNITS"), ("DDUNITS", "UNITS"),
        ("V", "VIEW"), ("VIEWS", "VIEW"),
        ("LO", "LAYOUT"), ("SHEET", "LAYOUT"), ("LAYOUT", "LAYOUT"),
        ("I", "INSERT"), ("-I", "INSERT"),
        ("CP", "COPY"), ("BH", "HATCH"), ("U", "UNDO"),
        ("GD", "GRADIENT"),
        ("G", "GROUP"), ("W", "WBLOCK"),
        ("TO", "TOOLBAR"), ("TOR", "TORIENT"),
        ("PR", "PROPERTIES"), ("CH", "PROPERTIES"), ("MO", "PROPERTIES"),
        ("PROPS", "PROPERTIES"), ("PROPERTIES", "PROPERTIES"),
        ("AALINES", "AALINES"), ("RAY", "RAY"),
        ("PSTROKE", "PENSTROKE"),
        ("OSNAP", "OSNAP"),
        ("COMMANDLINE", "COMMANDLINE"), ("CLI", "COMMANDLINE"),
        ("CLEANSCREENON", "CLEANSCREENON"),
        ("CLEANSCREENOFF", "CLEANSCREENOFF"),
        ("DRAWORDER", "DRAWORDER"), ("DR", "DRAWORDER"),
        ("HATCHEDIT", "HATCHEDIT"), ("HE", "HATCHEDIT"),
        ("-HATCH", "-HATCH"),
        ("-TEXT", "-TEXT"),
        ("-LAYER", "-LAYER"), ("-LA", "-LAYER"),
        ("CHPROP", "CHPROP"), ("CHANGE", "CHANGE"),
        ("DIST", "DIST"), ("DI", "DIST"),
        ("ID", "ID"),
        ("LIST", "LIST"), ("LI", "LIST"), ("LS", "LIST"),
        ("AREA", "AREA"), ("AA", "AREA"),
        ("XLINE", "XLINE"), ("XL", "XLINE"),
        ("POLYGON", "POLYGON"), ("POL", "POLYGON"),
        ("BOUNDARY", "BOUNDARY"), ("BO", "BOUNDARY"),
        ("POINT", "POINT"), ("PO", "POINT"),
        ("PTYPE", "PTYPE"), ("DDPTYPE", "PTYPE"),
        ("DONUT", "DONUT"), ("DO", "DONUT"),
        ("LAYOFF", "LAYOFF"), ("LAYON", "LAYON"),
        ("LAYISO", "LAYISO"), ("LAYUNISO", "LAYUNISO"),
        ("LAYMCUR", "LAYMCUR"), ("AI_MOLC", "LAYMCUR"),
        ("LAYMCH", "LAYMCH"),
    ]

    func testGoldenLTAliasesResolveToCanonical() {
        let processor = CADCommandProcessor()
        for (input, expected) in Self.goldenRows {
            let top = processor.matchCommands(input: input)
                .prefix(3)
                .map { $0.descriptor.canonicalName }
            XCTAssertTrue(
                top.contains(expected),
                "'\(input)' should resolve to \(expected); top-3 was \(top)")
        }
    }

    /// No alias may map to two different canonicals across the descriptor
    /// registry. This is the `R` → ROTATE-vs-RAY class of bug.
    func testNoAliasMapsToTwoCanonicals() {
        var owners: [String: Set<String>] = [:]
        for desc in CommandDescriptor.allCommands {
            for key in desc.allMatches {
                owners[key, default: []].insert(desc.canonicalName)
            }
        }
        let collisions = owners.filter { $0.value.count > 1 }
        XCTAssertTrue(
            collisions.isEmpty,
            "Aliases owned by multiple commands: \(collisions)")
    }

    /// Every S4 scripted name must be an S1 canonical, an S1 alias, or a
    /// documented scripted-only name (interactive form lands separately).
    func testScriptedSetCoveredByDescriptors() {
        let canonicals = Set(CommandDescriptor.allCommands.map { $0.canonicalName })
        let aliases = Set(CommandDescriptor.allCommands.flatMap { $0.aliases })
        // Audited scripted-only surface: SELECT has no interactive command.
        // CHPROP/CHANGE/-HATCH/-TEXT gained interactive forms in 0.5.
        let scriptedOnly: Set<String> = [
            "SELECT",
        ]
        for name in LispScriptedCommands.scripted {
            XCTAssertTrue(
                canonicals.contains(name) || aliases.contains(name)
                    || scriptedOnly.contains(name),
                "Scripted command '\(name)' has no descriptor and is not documented scripted-only")
        }
    }

    /// The canonical alias table itself must be collision-free.
    func testAliasTableHasNoInternalCollisions() {
        var owners: [String: String] = [:]
        for row in CADCommandAliasTable.entries {
            for key in [row.canonicalName] + row.aliases {
                if let prior = owners[key] {
                    XCTFail("Table key '\(key)' claimed by \(prior) and \(row.canonicalName)")
                } else {
                    owners[key] = row.canonicalName
                }
            }
        }
    }

    /// Reserved stubs report honestly and real commands never stub-report.
    func testStubMessages() {
        for stub in ["S", "STRETCH", "PS", "PSPACE",
                     "G", "GROUP", "W", "WBLOCK"] {
            XCTAssertNotNil(
                CADCommandAliasTable.stubMessage(for: stub),
                "'\(stub)' should report not-implemented-yet")
        }
        for real in ["LINE", "L", "COPY", "TRIM", "AA", "R", "TABLE"] {
            XCTAssertNil(
                CADCommandAliasTable.stubMessage(for: real),
                "'\(real)' must not stub-report")
        }
    }

    /// The registry tracks key ownership (the `R` → ROTATE-vs-RAY guard) and
    /// never duplicates descriptors: registering TABLE twice — once via the
    /// static list, once via table synthesis — leaves exactly one entry.
    /// (`CADCommandAliasTable.entry(descriptor)` content is pinned by the
    /// golden rows above resolving through `matchCommands`.)
    func testRegistryKeysTrackedAndDescriptorsIdempotent() {
        let processor = CADCommandProcessor()
        let before = CommandDescriptor.allCommands.filter {
            $0.canonicalName == "TABLE"
        }.count
        processor.registerFeatureCommand(
            name: "TABLE",
            aliases: ["TB", "DATATABLE"],
            factory: { SynthProbeCommand() })
        processor.registerFeatureCommand(
            name: "TABLE",
            aliases: ["TB", "DATATABLE"],
            factory: { SynthProbeCommand() })
        let after = CommandDescriptor.allCommands.filter {
            $0.canonicalName == "TABLE"
        }.count
        XCTAssertEqual(before, after)
        XCTAssertGreaterThanOrEqual(after, 1)
        XCTAssertEqual(
            CommandDescriptor.allCommands.first {
                $0.canonicalName == "TABLE"
            }?.aliases,
            ["TB", "DATATABLE"])
        XCTAssertEqual(processor.featureCommandKeys["TB"], "TABLE")
        XCTAssertEqual(processor.featureCommandKeys["TABLE"], "TABLE")
    }
}

/// Minimal FeatureCommand for registry-mechanism tests.
@MainActor
private final class SynthProbeCommand: FeatureCommand {
    func start(engine: PhrostEngine, processor: CADCommandProcessor) {}
    func cancel(engine: PhrostEngine, processor: CADCommandProcessor) {}
    func handleMouseClick(
        worldX: Double, worldY: Double, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }
    func handleMouseMotion(
        worldX: Double, worldY: Double, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) {}
    func handleKeyDown(
        scancode: SDL_Scancode, engine: PhrostEngine,
        processor: CADCommandProcessor
    ) -> CommandResult { .continue }
    func renderOverlay(cam: CameraTransform, engine: PhrostEngine) {}
}
