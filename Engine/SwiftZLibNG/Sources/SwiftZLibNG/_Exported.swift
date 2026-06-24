// =========================================================================
// MARK: - SwiftZLibNG
//
// Re-exports the CZLibNG Clang module so that dependents can write
// `import SwiftZLibNG` instead of `import CZLibNG`. This is purely a
// convenience layer — all zlib-ng functions are accessed through the
// C module's global namespace (e.g., `deflateInit(...)`, `inflate(...)`).
// =========================================================================

#if canImport(CZLibNG)
@_exported import CZLibNG
#endif
