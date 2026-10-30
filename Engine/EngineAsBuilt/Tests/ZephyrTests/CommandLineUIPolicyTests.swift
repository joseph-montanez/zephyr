import XCTest
@testable import ZephyrCore

final class CommandLineUIPolicyTests: XCTestCase {
    func testCommandLineRendersOnlyInWindowShowingActiveTab() {
        XCTAssertFalse(CommandLineUIPolicy.shouldRender(showsActiveTab: false))
        XCTAssertTrue(CommandLineUIPolicy.shouldRender(showsActiveTab: true))
    }
}
