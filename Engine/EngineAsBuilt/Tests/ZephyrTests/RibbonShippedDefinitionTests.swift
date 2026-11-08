import XCTest
import ZephyrLisp
@testable import ZephyrCore

/// Validates the *shipped* `lisp/ribbon.lsp` end to end: it must parse, must
/// reference only commands this build can dispatch, must use only icons the
/// painter draws, and must carry the documented tab/menu set.
///
/// The catalog is the descriptor list plus the names the app registers
/// feature commands under — several of those (`PENSTROKE`, `REVCLOUD`,
/// `TABLE`, …) register without a descriptor, so a descriptor-only catalog
/// would wrongly flag them. `AppCommandRegistration.swift` is the source of
/// truth for those names, hence the source read (the file lives beside the
/// tests, like the LISP corpus files other suites use).
@MainActor
final class RibbonShippedDefinitionTests: XCTestCase {

    private static func repositoryRoot() -> URL {
        // .../Engine/EngineAsBuilt/Tests/ZephyrTests/<this file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ZephyrTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // EngineAsBuilt
    }

    private static func shippedDefinitionURL() -> URL {
        repositoryRoot().appendingPathComponent("lisp/ribbon.lsp")
    }

    private func appRegisteredCommandNames() throws -> Set<String> {
        let url = Self.repositoryRoot()
            .appendingPathComponent("Sources/Zephyr/AppCommandRegistration.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        var names = Set<String>()
        // registerFeatureCommand(name: "FOO", ...) plus its descriptor
        // aliases: canonicalName: "FOO" / aliases: ["A", "B"].
        for line in source.split(separator: "\n") {
            var rest = Substring(line)
            while let range = rest.range(of: "\"") {
                guard let close = rest[range.upperBound...].firstIndex(of: "\"")
                else { break }
                let value = String(rest[range.upperBound..<close])
                rest = rest[rest.index(after: close)...]
                // Every quoted token in this file is a command name, alias,
                // category label, or a description; keep the command-shaped
                // ones and let the catalog filter the rest.
                if value == value.uppercased(), !value.isEmpty,
                   value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) {
                    names.insert(value)
                }
            }
        }
        return names
    }

    private func catalog() throws -> RibbonCommandCatalog {
        var known = RibbonCommandCatalog.fromCurrentApp().known
        known.formUnion(try appRegisteredCommandNames())
        // Appended by RibbonSpecLoader itself in the running app.
        known.formUnion(["RIBBON", "RIBBONCLOSE", "RIBBONMODE", "RIBBONRELOAD"])
        // Registered by PhrostEngine.init (not by AppCommandRegistration), so
        // a test process without an engine would not see them.
        known.formUnion(["LOAD", "EVAL", "SCRIPT"])
        return RibbonCommandCatalog(known: known)
    }

    /// Runs the definition exactly like the app does: prelude + file, then
    /// the `(zephyr-ribbon)` call.
    private func evaluateShippedDefinition() async throws -> LispValue {
        let source = try String(
            contentsOf: Self.shippedDefinitionURL(), encoding: .utf8)
        let document = CADDocument()
        document.addLayer(Layer(name: "0"))
        let host = LispCADHost(
            document: document, selection: CADSelectionManager())
        host.output = { _ in }
        let outcome = await RibbonLoadEvaluator.evaluate(
            source: RibbonPrelude.source + "\n" + source,
            host: host,
            environment: LispEnvironment())
        if let message = outcome.errorMessage {
            throw RibbonSpecError(message)
        }
        guard let value = outcome.value else {
            throw RibbonSpecError("the shipped definition produced no value")
        }
        return value
    }

    // MARK: - Tests

    func testShippedDefinitionParsesWithoutWarnings() async throws {
        let value = try await evaluateShippedDefinition()
        let result = try RibbonSpecParser.parse(
            value, catalog: try catalog())

        XCTAssertEqual(
            result.warnings, [],
            "the shipped definition must not reference unknown commands or icons")
        XCTAssertFalse(result.spec.tabs.isEmpty)
        XCTAssertFalse(result.spec.menus.isEmpty)
    }

    func testShippedDefinitionTabsAndMenus() async throws {
        let value = try await evaluateShippedDefinition()
        let spec = try RibbonSpecParser.parse(
            value, catalog: try catalog()).spec

        XCTAssertEqual(
            spec.tabs.map(\.title),
            ["Home", "Insert", "Annotate", "Parametric", "View", "Manage", "Output", "Custom"])
        XCTAssertEqual(
            spec.menus.map(\.title),
            ["File", "Edit", "View", "Insert", "Format", "Draw", "Modify", "Tools"])

        // Every tab has at least one panel, every panel at least one item
        // (the parser drops empties, so a dropped panel here would be a bug).
        for tab in spec.tabs {
            XCTAssertFalse(tab.panels.isEmpty, "\(tab.title) has no panels")
            for panel in tab.panels {
                XCTAssertFalse(panel.items.isEmpty, "\(panel.title) is empty")
            }
        }
    }

    func testShippedDefinitionUsesOnlyKnownIcons() async throws {
        let spec = try RibbonSpecParser.parse(
            try await evaluateShippedDefinition(),
            catalog: try catalog()).spec

        // Only icons that actually reach the painter matter: panel buttons
        // (big/small) and a flyout's own icon (derived from its first child).
        // Menu entries and flyout children are drawn as text rows.
        func check(_ items: [RibbonItem], context: String) {
            for item in items {
                switch item {
                case let .command(command):
                    XCTAssertTrue(
                        RibbonIconNames.isKnown(command.resolvedIconName),
                        "\(context): unknown icon \(command.resolvedIconName)")
                case let .dropdown(dropdown):
                    if let icon = dropdown.icon {
                        XCTAssertTrue(
                            RibbonIconNames.isKnown(icon),
                            "\(context) > \(dropdown.label): unknown icon \(icon)")
                    }
                case .separator:
                    break
                }
            }
        }
        for tab in spec.tabs {
            for panel in tab.panels {
                check(panel.items, context: "\(tab.title)/\(panel.title)")
            }
        }
        // Menus render as text rows (no icon column), so they are exempt.
    }

    /// The painter must implement every name the definition grammar accepts,
    /// otherwise a valid definition renders letter boxes.
    func testIconNameListMatchesPainterCoverage() throws {
        // The painter lives in the app target, which tests cannot import, so
        // this asserts the shared list is non-trivial and self-consistent;
        // `RibbonIconPainterTests` (app-side manual check) covers the rest.
        XCTAssertGreaterThan(RibbonIconNames.all.count, 40)
        XCTAssertTrue(RibbonIconNames.isKnown("line"))
        XCTAssertTrue(RibbonIconNames.isKnown("move"))
        XCTAssertTrue(RibbonIconNames.isKnown("layers"))
        XCTAssertTrue(RibbonIconNames.isKnown("reload"))
        XCTAssertFalse(RibbonIconNames.isKnown("zigzag"))
        // Every name is lowercase and non-empty.
        for name in RibbonIconNames.all {
            XCTAssertEqual(name, name.lowercased())
            XCTAssertFalse(name.isEmpty)
        }
        // The painter lives in the app target, which tests cannot import,
        // so scan its dispatch-table source: the painted names and the
        // registered names must match exactly.
        let iconURL = Self.repositoryRoot()
            .appendingPathComponent("Sources/Zephyr/RibbonIcon.swift")
        let iconSource = try String(contentsOf: iconURL, encoding: .utf8)
        var painted = Set<String>()
        // Unit-based split: Character-split compares grapheme clusters,
        // so a CRLF checkout yields zero lines (CR+LF is one cluster).
        // NSString split is line-ending agnostic.
        for rawLine in (iconSource as NSString).components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\""),
                  let close = trimmed.dropFirst().firstIndex(of: "\"")
            else { continue }
            let after = trimmed[trimmed.index(after: close)...]
            guard after.hasPrefix(":") else { continue }
            painted.insert(
                String(trimmed.dropFirst().prefix(upTo: close)))
        }
        XCTAssertEqual(
            painted, RibbonIconNames.all,
            "RibbonIconNames and RibbonIconPainter must match exactly")
    }

    func testDefinitionFileExistsWhereTheLoaderLooksForIt() {
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: Self.shippedDefinitionURL().path),
            "lisp/ribbon.lsp is the shipped default; compile.ps1 copies lisp/ "
                + "next to the executable")
    }
}
