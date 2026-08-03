import XCTest
@testable import ZephyrCore

final class HatchPatternFileParserTests: XCTestCase {
    func testParsesPatternHeadersDescriptionsAndDashSequences() {
        let source = """
        ;; comment
        *ANSI31, ANSI Iron, Brick, Stone masonry
        45, 0,0, 0,.125
        *DOTS, Dotted pattern
        0, 0,0, 0,.25, 0,-.25
        """

        let patterns = HatchPatternFileParser.parse(contents: source)
        XCTAssertEqual(patterns.count, 2)
        XCTAssertEqual(patterns[0].name, "ANSI31")
        XCTAssertEqual(patterns[0].description, "ANSI Iron, Brick, Stone masonry")
        XCTAssertEqual(patterns[0].lines[0].offset.y, 0.125, accuracy: 1e-12)
        XCTAssertEqual(patterns[1].lines[0].dashes, [0, -0.25])
    }

    func testSkipsMalformedDefinitionLinesWithoutDiscardingPattern() {
        let source = """
        *TEST, Test pattern
        malformed
        90, 1,2, 3,4, 5,-6
        """

        let patterns = HatchPatternFileParser.parse(contents: source)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns[0].lines.count, 1)
        XCTAssertEqual(patterns[0].lines[0].angleDegrees, 90)
    }
}
