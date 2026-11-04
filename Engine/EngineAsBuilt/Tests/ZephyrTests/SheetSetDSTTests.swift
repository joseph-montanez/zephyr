import XCTest
import Foundation
@testable import ZephyrCore

/// Step 1-2: `.dst` byte-substitution codec + zero-DWG sheet listing.
/// Byte layer ported from Bedz01/dst-codec (MIT); vectors below pin the
/// confirmed mappings plus the fail-closed blocks (0xB, CR).
final class SheetSetDSTTests: XCTestCase {

    func testKnownByteVectors() throws {
        // '<' (60) = block 0xD base 47 + PERMUTE[0] 13 -> dst 0xD0 (208).
        XCTAssertEqual(try SheetSetDST.decode(Data([208])), "<")
        // 'A' (65) = block 0xC base 63 + PERMUTE[15] 2 -> dst 0xCF (207).
        XCTAssertEqual(try SheetSetDST.decode(Data([207])), "A")
        // Whitespace: AutoCAD LF 131, TAB 134, ARES LF 135.
        XCTAssertEqual(try SheetSetDST.decode(Data([131])), "\n")
        XCTAssertEqual(try SheetSetDST.decode(Data([134])), "\t")
        XCTAssertEqual(try SheetSetDST.decode(Data([135])), "\n")
    }

    func testRoundTripASCIIAndMultibyte() throws {
        let xml = "<AcSmSheet ID=\"g1\"><AcSmProp propname=\"Title\" vt=\"8\">Plan — Détail</AcSmProp></AcSmSheet>\n"
        let decoded = try SheetSetDST.decode(try SheetSetDST.encode(xml))
        XCTAssertEqual(decoded, xml)
    }

    func testEncodeNormalizesCRLF() throws {
        let crlf = try SheetSetDST.encode("<a>\r\n</a>")
        let lf = try SheetSetDST.encode("<a>\n</a>")
        XCTAssertEqual(crlf, lf)
    }

    func testFailClosedBlocks() {
        // 0xB0 (176): high nibble 0xB has no confirmed base.
        XCTAssertThrowsError(try SheetSetDST.decode(Data([176]))) { error in
            XCTAssertEqual(error as? SheetSetDSTError, .unknownDSTByte(offset: 0, byte: 176))
        }
        XCTAssertThrowsError(try SheetSetDST.decode(Data()))
    }

    func testListSheetsDocumentOrderAndHandleIdentity() throws {
        let xml = """
        <AcSmDatabase><AcSmSheet ID="g1"><AcSmProp propname="Number" vt="8">A101</AcSmProp><AcSmProp propname="Title" vt="8">Plan</AcSmProp><AcSmProp propname="DoNotPlot" vt="8">0</AcSmProp><AcSmAcDbLayoutReference><AcSmProp propname="Relative_FileName" vt="8">.\\A.dwg</AcSmProp><AcSmProp propname="FileName" vt="8">C:\\job\\A.dwg</AcSmProp><AcSmProp propname="AcDbHandle" vt="8">1F2</AcSmProp><AcSmProp propname="Name" vt="8">Layout1</AcSmProp></AcSmAcDbLayoutReference></AcSmSheet><AcSmSheet ID="g2"><AcSmProp propname="Number" vt="8">A102</AcSmProp><AcSmProp propname="Title" vt="8">RCP &amp; Details</AcSmProp><AcSmProp propname="DoNotPlot" vt="8">-1</AcSmProp><AcSmAcDbLayoutReference><AcSmProp propname="Relative_FileName" vt="8">.\\B.dwg</AcSmProp><AcSmProp propname="FileName" vt="8">C:\\job\\B.dwg</AcSmProp><AcSmProp propname="AcDbHandle" vt="8">AB</AcSmProp><AcSmProp propname="Name" vt="8">StaleName</AcSmProp></AcSmAcDbLayoutReference></AcSmSheet></AcSmDatabase>
        """
        // Zero-DWG path: list straight from XML, and via encode->decode.
        let direct = SheetSetDST.listSheets(xml: xml)
        let roundTripped = SheetSetDST.listSheets(xml: try SheetSetDST.decode(try SheetSetDST.encode(xml)))
        XCTAssertEqual(direct, roundTripped)
        XCTAssertEqual(direct.count, 2)
        XCTAssertEqual(direct[0].number, "A101")
        XCTAssertEqual(direct[0].absoluteFile, "C:\\job\\A.dwg")
        XCTAssertEqual(direct[0].handle, "1F2")
        XCTAssertTrue(direct[0].includeForPlot)
        XCTAssertEqual(direct[1].title, "RCP & Details")
        XCTAssertFalse(direct[1].includeForPlot)
    }
}
