import XCTest
@testable import ZephyrCore

/// Layer sorting (AutoCAD LAYER-palette style): keys, direction
/// toggling, deterministic name tiebreak, persistence of settings.
@MainActor
final class LayerSortPolicyTests: XCTestCase {

    private func fixture() -> (layers: [Layer], counts: [UUID: Int]) {
        var bravo = Layer(name: "Bravo", color: .white)       // ACI 7
        bravo.isVisible = false
        bravo.lineWeight = 0.5
        bravo.lineType = "DASHED"
        bravo.opacity = 0.5
        var alpha = Layer(
            name: "alpha",
            color: ColorRGBA(r: 255, g: 0, b: 0, a: 255))        // ACI 1 (red)
        alpha.lineWeight = 0.25
        alpha.isPlottable = false
        let charlie = Layer(
            name: "Charlie",
            color: ColorRGBA(r: 255, g: 255, b: 0, a: 255))        // ACI 2 (yellow)
        let layers = [bravo, charlie, alpha]
        // alpha and Charlie used; Bravo empty.
        let counts = [alpha.handle: 3, charlie.handle: 1]
        return (layers, counts)
    }

    private func names(_ layers: [Layer]) -> [String] { layers.map(\.name) }

    func testNameSortBothDirections() {
        let (layers, counts) = fixture()
        XCTAssertEqual(
            names(LayerSortPolicy.sorted(layers, entityCounts: counts,
                settings: LayerSortSettings(key: .name, ascending: true))),
            ["alpha", "Bravo", "Charlie"])
        XCTAssertEqual(
            names(LayerSortPolicy.sorted(layers, entityCounts: counts,
                settings: LayerSortSettings(key: .name, ascending: false))),
            ["Charlie", "Bravo", "alpha"])
    }

    func testPropertyKeys() {
        let (layers, counts) = fixture()
        func sorted(_ key: LayerSortKey, _ asc: Bool = true) -> [String] {
            names(LayerSortPolicy.sorted(
                layers, entityCounts: counts,
                settings: LayerSortSettings(key: key, ascending: asc)))
        }
        // On before Off ascending; visible pair tie-breaks by name.
        XCTAssertEqual(sorted(.onOff), ["alpha", "Charlie", "Bravo"])
        XCTAssertEqual(sorted(.onOff, false), ["Bravo", "alpha", "Charlie"])
        // Color by ACI: red 1, yellow 2, white 7.
        XCTAssertEqual(sorted(.color), ["alpha", "Charlie", "Bravo"])
        // Linetype: CONTINUOUS pair (name tiebreak) before DASHED.
        XCTAssertEqual(sorted(.linetype), ["alpha", "Charlie", "Bravo"])
        // Lineweight ascending: 0.25 pair (name tiebreak), then 0.5.
        XCTAssertEqual(sorted(.lineweight), ["alpha", "Charlie", "Bravo"])
        XCTAssertEqual(sorted(.lineweight, false), ["Bravo", "alpha", "Charlie"])
        // Opacity ascending: 0.5 first.
        XCTAssertEqual(sorted(.opacity), ["Bravo", "alpha", "Charlie"])
        // Plot ascending: plottable first (Bravo, Charlie), alpha no-plot last.
        XCTAssertEqual(sorted(.plot), ["Bravo", "Charlie", "alpha"])
        // Used ascending: used first (alpha, Charlie), empty Bravo last.
        XCTAssertEqual(sorted(.used), ["alpha", "Charlie", "Bravo"])
        XCTAssertEqual(sorted(.used, false), ["Bravo", "alpha", "Charlie"])
    }

    func testHeaderClickToggleSemantics() {
        let start = LayerSortSettings(key: .name, ascending: true)
        let flipped = start.selecting(.name)
        XCTAssertEqual(flipped, LayerSortSettings(key: .name, ascending: false))
        let switched = flipped.selecting(.color)
        XCTAssertEqual(switched, LayerSortSettings(key: .color, ascending: true),
                       "new key starts ascending")
    }

    func testSettingsPersistenceRoundTrip() {
        let saved = LayerSortSettings.load()
        defer { saved.save() }
        LayerSortSettings(key: .lineweight, ascending: false).save()
        XCTAssertEqual(
            LayerSortSettings.load(),
            LayerSortSettings(key: .lineweight, ascending: false))
    }

    func testEntityCounts() {
        let doc = CADDocument()
        let layerA = Layer(name: "A")
        let layerB = Layer(name: "B")
        doc.importLayersBlocksEntities(
            layers: [layerA, layerB], blocks: [],
            entities: [
                CADEntity(layerID: layerA.handle, localGeometry: [], transform: .identity),
                CADEntity(layerID: layerA.handle, localGeometry: [], transform: .identity),
                CADEntity(layerID: layerB.handle, localGeometry: [], transform: .identity),
            ])
        let counts = LayerSortPolicy.entityCounts(in: doc)
        XCTAssertEqual(counts[layerA.handle], 2)
        XCTAssertEqual(counts[layerB.handle], 1)
    }
}

extension LayerSortPolicyTests {

    // MARK: - LAYERSORT command

    func testCommandTokenParsing() {
        let start = LayerSortSettings(key: .name, ascending: true)
        XCTAssertEqual(
            start.applyingCommandTokens(["COLOR"]),
            LayerSortSettings(key: .color, ascending: true))
        XCTAssertEqual(
            start.applyingCommandTokens(["COLOR", "DESC"]),
            LayerSortSettings(key: .color, ascending: false))
        XCTAssertEqual(
            start.applyingCommandTokens(["NAME"]),
            LayerSortSettings(key: .name, ascending: false),
            "repeating the current key toggles direction, like a column header")
        XCTAssertEqual(
            start.applyingCommandTokens(["REVERSE"]),
            LayerSortSettings(key: .name, ascending: false))
        XCTAssertNil(start.applyingCommandTokens(["BOGUS"]))
        XCTAssertNil(start.applyingCommandTokens(["NAME", "BOGUS"]))
    }

    func testLayerSortCommandIsRegistered() {
        XCTAssertTrue(CommandDescriptor.allCommands.contains {
            $0.canonicalName == "LAYERSORT"
        })
    }

    func testLayerSortCommandUpdatesSharedSettings() {
        let saved = LayerSortSettings.load()
        defer { saved.save() }
        LayerSortSettings(key: .name, ascending: true).save()
        let processor = CADCommandProcessor()

        processor.executeCommand("LAYERSORT COLOR DESC")
        XCTAssertEqual(
            LayerSortSettings.load(),
            LayerSortSettings(key: .color, ascending: false))

        processor.executeCommand("LAYERSORT COLOR")
        processor.executeCommand("")
        XCTAssertEqual(
            LayerSortSettings.load(),
            LayerSortSettings(key: .color, ascending: true),
            "repeating COLOR toggles back to ascending")

        processor.executeCommand("LASORT USED ASC")
        XCTAssertEqual(
            LayerSortSettings.load(),
            LayerSortSettings(key: .used, ascending: true))

        processor.executeCommand("LAYERSORT REVERSE")
        XCTAssertEqual(
            LayerSortSettings.load(),
            LayerSortSettings(key: .used, ascending: false))

        processor.executeCommand("LAYERSORT BOGUS")
        XCTAssertEqual(
            LayerSortSettings.load(),
            LayerSortSettings(key: .used, ascending: false),
            "invalid option leaves settings unchanged")
    }
}
