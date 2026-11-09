import XCTest
@testable import ZephyrCore

/// Coverage guardrail for prompt option chips: every keyword-bearing
/// command offers its chips exactly in the phases whose prompts list
/// keywords, and stays silent in free-input phases. A keyword prompt
/// with no chips (or chips where no keyword applies) fails here.
@MainActor
final class PromptChipCoverageTests: XCTestCase {

    // MARK: - Keyword phases offer chips

    func testMeasureModesOfferChipsWithActiveMode() {
        let options = MeasureGeomTool().commandTextOptions(for: "")
        XCTAssertEqual(
            options.map(\.value), ["Distance", "Area", "Angle", "Quick", "Exit"])
        XCTAssertEqual(
            options.filter(\.isActive).map(\.value), ["Quick"])
    }

    func testWblockSourceOffersChips() {
        XCTAssertEqual(
            WblockCommand().commandTextOptions(for: "").map(\.value),
            ["Block", "Objects", "Entire"])
    }

    func testFieldCodeOffersChips() {
        XCTAssertEqual(
            FieldCommand().commandTextOptions(for: "").map(\.value),
            ["Date", "Filename", "Tabname", "Area", "Length", "Sheet"])
    }

    func testFilletOffersKeywordChipsAtRest() {
        // No Undo before the first operation in this session.
        XCTAssertEqual(
            FilletCommand().commandTextOptions(for: "").map(\.value),
            ["Radius", "Trim", "Multiple", "Polyline"])
    }

    func testChamferOffersKeywordChipsAtRest() {
        XCTAssertEqual(
            ChamferCommand().commandTextOptions(for: "").map(\.value),
            ["Distance", "Angle", "Trim", "Method", "Multiple", "Polyline"])
    }

    func testSelectSimilarOffersSettingsGateway() {
        XCTAssertEqual(
            SelectSimilarCommand().commandTextOptions(for: "").map(\.value),
            ["Settings"])
    }

    func testRevCloudTopLevelOffersChips() {
        XCTAssertEqual(
            RevCloudCommand().commandTextOptions(for: "").map(\.value),
            ["Arc length", "Object", "Rectangular", "Polygonal",
             "Freehand", "Style", "Modify", "Layer"])
    }

    func testSelectFilterTypeOffersAllTypes() {
        // QSELECT starts at the type question ...
        XCTAssertEqual(
            SelectFilterCommand(mode: .qselect)
                .commandTextOptions(for: "").map(\.value),
            ["All"] + EntityFilter.knownTypes)
        // ... while FILTER skips straight to the property question.
        XCTAssertEqual(
            SelectFilterCommand(mode: .filter)
                .commandTextOptions(for: "").map(\.value),
            ["ObjectType", "Layer", "Color", "Linetype", "Lineweight",
             "Handle"])
    }

    // MARK: - Non-keyword phases stay silent

    func testGatedCommandsOfferNoChipsAtInit() {
        let silent: [[FeatureCommandTextOption]] = [
            DViewCommand().commandTextOptions(for: ""),
            AlignCommand().commandTextOptions(for: ""),
            DimBreakCommand().commandTextOptions(for: ""),
            TextAlignCommand().commandTextOptions(for: ""),
            FindCommand().commandTextOptions(for: ""),
            ImageAdjustCommand().commandTextOptions(for: ""),
            PdfAdjustCommand().commandTextOptions(for: ""),
            MeasureDivideCommand(operation: .measure)
                .commandTextOptions(for: ""),
            MeasureDivideCommand(operation: .divide)
                .commandTextOptions(for: ""),
            MirrorCommand().commandTextOptions(for: ""),
        ]
        for options in silent {
            XCTAssertTrue(options.isEmpty)
        }
    }

    // MARK: - Filtering

    func testChipValuesFilterByTypedInput() {
        XCTAssertEqual(
            FieldCommand().commandTextOptions(for: "sh").map(\.value),
            ["Sheet"])
        XCTAssertEqual(
            FilletCommand().commandTextOptions(for: "po").map(\.value),
            ["Polyline"])
    }
}
