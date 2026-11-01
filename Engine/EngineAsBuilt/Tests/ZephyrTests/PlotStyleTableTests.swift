import XCTest
@testable import ZephyrCore

/// Phase 3 step 18/24: CTB/STB parsing over every bundled table.
final class PlotStyleTableTests: XCTestCase {

    private var plotStylesDir: URL {
        URL(fileURLWithPath: "Plot Styles")
    }

    private func tables(matching ext: String) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(
            at: plotStylesDir, includingPropertiesForKeys: nil)
        return items.filter { $0.pathExtension.lowercased() == ext }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testEveryCTBParsesWith255Pens() throws {
        let urls = try tables(matching: "ctb")
        XCTAssertFalse(urls.isEmpty, "expected bundled .ctb fixtures")
        for url in urls {
            let table = try PlotStyleTable.parse(url: url)
            XCTAssertEqual(table.kind, .ctb, "\(url.lastPathComponent)")
            XCTAssertEqual(table.pens.count, 255, "\(url.lastPathComponent)")
            XCTAssertFalse(table.lineweightTable.isEmpty, "\(url.lastPathComponent)")
        }
    }

    func testEverySTBParses() throws {
        let urls = try tables(matching: "stb")
        XCTAssertFalse(urls.isEmpty, "expected bundled .stb fixtures")
        for url in urls {
            let table = try PlotStyleTable.parse(url: url)
            XCTAssertEqual(table.kind, .stb, "\(url.lastPathComponent)")
            XCTAssertFalse(table.pens.isEmpty, "\(url.lastPathComponent)")
        }
    }

    func testMonochromeMapsEverythingToBlack() throws {
        let table = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("monochrome.ctb"))
        XCTAssertEqual(table.pens.count, 255)
        for (index, pen) in table.pens.enumerated() {
            XCTAssertEqual(pen.colorARGB, 0xFF00_0000, "pen \(index)")
            XCTAssertEqual(pen.colorPolicy, 5, "pen \(index)")
            XCTAssertEqual(pen.screeningPercent, 100, "pen \(index)")
            XCTAssertNil(pen.lineweightMM, "pen \(index)")
        }
        // ACI lookup is 1-based.
        XCTAssertEqual(table.pen(forACI: 1)?.name, "Color_1")
        XCTAssertEqual(table.pen(forACI: 7)?.colorARGB, 0xFF00_0000)
        XCTAssertNil(table.pen(forACI: 0))
        XCTAssertNil(table.pen(forACI: 256))
    }

    func testAcadUsesObjectColorAndLineweight() throws {
        let table = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("acad.ctb"))
        XCTAssertEqual(table.pens.count, 255)
        let pen = try XCTUnwrap(table.pen(forACI: 3))
        XCTAssertEqual(pen.colorPolicy, 1)
        XCTAssertNil(pen.colorARGB) // object color
        XCTAssertEqual(pen.screeningPercent, 100)
        XCTAssertNil(pen.lineweightMM) // object lineweight
    }

    func testGrayscaleAndScreening() throws {
        let gray = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("Grayscale.ctb"))
        let pen = try XCTUnwrap(gray.pen(forACI: 1))
        XCTAssertEqual(pen.colorPolicy, 3)
        XCTAssertTrue(pen.isGrayscale)
        XCTAssertNil(pen.colorARGB)
        for pct in [25, 50, 75, 100] {
            let t = try PlotStyleTable.parse(
                url: plotStylesDir.appendingPathComponent("Screening \(pct)%.ctb"))
            XCTAssertEqual(t.pen(forACI: 9)?.screeningPercent, pct)
        }
    }

    func testNamedStylesResolveByName() throws {
        let table = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("monochrome.stb"))
        XCTAssertEqual(table.kind, .stb)
        let solid = table.pen(named: "Normal")
        XCTAssertNotNil(solid)
        XCTAssertEqual(table.pen(named: "normal")?.name, solid?.name)
        XCTAssertNil(table.pen(named: "No Such Style"))
    }

    func testLineweightTableValues() throws {
        let table = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("acad.ctb"))
        // Spot-check the canonical mm table.
        XCTAssertEqual(table.lineweightTable[5], 0.15, accuracy: 1e-9)
        XCTAssertEqual(table.lineweightTable[20], 1.0, accuracy: 1e-9)
    }

    // MARK: - Pen application (step 19)

    func testPenApplicationMonochrome() throws {
        let table = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("monochrome.ctb"))
        let pen = try XCTUnwrap(table.pen(forACI: 3)) // ACI 3 = green
        let out = PlotPenApplication.resolve(
            objectACI: 3, objectRGB: (0, 255, 0), pen: pen,
            objectLineweightMM: 0.25)
        XCTAssertEqual(out.r, 0)
        XCTAssertEqual(out.g, 0)
        XCTAssertEqual(out.b, 0)
        XCTAssertEqual(out.screening01, 1, accuracy: 1e-9)
        XCTAssertEqual(out.lineweightMM ?? -1, 0.25, accuracy: 1e-9) // object kept
    }

    func testPenApplicationObjectPassthrough() throws {
        let table = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("acad.ctb"))
        let pen = try XCTUnwrap(table.pen(forACI: 1))
        let out = PlotPenApplication.resolve(
            objectACI: 1, objectRGB: (255, 0, 0), pen: pen,
            objectLineweightMM: 0.35, scaleLineweights: true, plotScale: 2)
        XCTAssertEqual(out.r, 255)
        XCTAssertEqual(out.g, 0)
        XCTAssertEqual(out.b, 0)
        XCTAssertEqual(out.lineweightMM ?? -1, 0.7, accuracy: 1e-9)
    }

    func testPenApplicationGrayscaleAndScreening() throws {
        let gray = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("Grayscale.ctb"))
        let gpen = try XCTUnwrap(gray.pen(forACI: 3))
        let gout = PlotPenApplication.resolve(
            objectACI: 3, objectRGB: (0, 255, 0), pen: gpen,
            objectLineweightMM: 0.25)
        let lum = UInt8((0.587 * 255).rounded())
        XCTAssertEqual(gout.r, lum)
        XCTAssertEqual(gout.g, lum)
        XCTAssertEqual(gout.b, lum)
        let scr = try PlotStyleTable.parse(url: plotStylesDir.appendingPathComponent("Screening 25%.ctb"))
        let spen = try XCTUnwrap(scr.pen(forACI: 2))
        let sout = PlotPenApplication.resolve(
            objectACI: 2, objectRGB: (255, 255, 0), pen: spen,
            objectLineweightMM: 0.25)
        XCTAssertEqual(sout.screening01, 0.25, accuracy: 1e-9)
        XCTAssertEqual(sout.r, 255)
        XCTAssertEqual(sout.g, 255)
        XCTAssertEqual(sout.b, 0)
        // No table assigned → passthrough.
        let plain = PlotPenApplication.resolve(
            objectACI: 1, objectRGB: (10, 20, 30), pen: nil,
            objectLineweightMM: 0.5)
        XCTAssertEqual(plain.r, 10)
        XCTAssertEqual(plain.g, 20)
        XCTAssertEqual(plain.b, 30)
        XCTAssertEqual(plain.screening01, 1, accuracy: 1e-9)
    }

    func testCorruptInputThrows() {
        XCTAssertThrowsError(try PlotStyleTable.parse(data: Data("hello".utf8)))
        XCTAssertThrowsError(try PlotStyleTable.parse(data: Data()))
    }
}
