import XCTest
@testable import ZephyrCore

/// Regression: clicking a hatch in packaged builds crashed with
/// "unable to find bundle named Zephyr_ZephyrCore".
///
/// `HatchPatternLibrary.candidateDirectories()` touched the generated
/// `Bundle.module` accessor, which `fatalError`s when the SwiftPM resource
/// bundle is absent. Packaged installs ship `Patterns/` as a plain folder
/// next to the executable (no resource bundle), so the first hatch edit
/// trapped. The bundle lookup must be best-effort, never fatal.
final class HatchPatternLibraryBundleTests: XCTestCase {

    private func makeFolder() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hatch-bundle-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Packaged layout: no `Zephyr_ZephyrCore.bundle` anywhere near the
    /// executable. The lookup must return no candidates instead of trapping.
    func testPackagePatternsLookupMissingBundleReturnsEmpty() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = HatchPatternLibrary.packagePatternsDirectories(searchBases: [folder])
        XCTAssertEqual(result, [])
    }

    /// Dev layout: bundle present under a search base. Its `Patterns`
    /// directory must be among the returned candidates.
    func testPackagePatternsLookupFindsBundledPatterns() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let patterns = folder
            .appendingPathComponent("Zephyr_ZephyrCore.bundle", isDirectory: true)
            .appendingPathComponent("Patterns", isDirectory: true)
        try FileManager.default.createDirectory(at: patterns, withIntermediateDirectories: true)

        let result = HatchPatternLibrary.packagePatternsDirectories(searchBases: [folder])
        XCTAssertTrue(
            result.contains { $0.standardizedFileURL.path == patterns.standardizedFileURL.path },
            "expected \(patterns.path) in \(result.map(\.path))")
    }

    /// Integration smoke: the full candidate search used on hatch edit must
    /// return normally (this is the call that crashed the packaged app).
    func testCandidateDirectoriesReturnsWithoutCrashing() {
        XCTAssertFalse(HatchPatternLibrary.candidateDirectories().isEmpty)
    }
}
