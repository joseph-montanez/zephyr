// =========================================================================
// MARK: - SwiftPdfium _Exported
//
// Re-exports the CPdfium C bridge so callers can `import SwiftPdfium`
// and access pdfium_page_count(), pdfium_render_page_to_png(), etc.
// =========================================================================

#if canImport(CPdfium)
@_exported import CPdfium
#endif
