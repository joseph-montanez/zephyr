// =========================================================================
// MARK: - PDFium Bridge Header
//
// Thin C bridge around PDFium's C API. Exposes exactly what the Swift
// PDFPageRenderer needs: page count, page dimensions, and page-to-PNG
// rendering at a target DPI. All PDFium internals (library init, document
// loading, bitmap rendering, BGRA→RGBA swizzle, PNG encoding) stay
// inside the C implementation.
// =========================================================================

#ifndef PDFIUM_BRIDGE_H
#define PDFIUM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Returns the number of pages in the PDF at `path`, or -1 on error.
int pdfium_page_count(const char* path);

/// Returns the rendered pixel width of page `page_index` (0-based) at
/// the given DPI, or -1 on error.
int pdfium_page_width(const char* path, int page_index, float dpi);

/// Returns the rendered pixel height of page `page_index` (0-based) at
/// the given DPI, or -1 on error.
int pdfium_page_height(const char* path, int page_index, float dpi);

/// Renders page `page_index` (0-based) to an in-memory PNG buffer.
///
/// - `dpi`: rendering resolution (e.g. 150.0).
/// - `out_len`: receives the byte count of the returned PNG data.
///
/// Returns a heap-allocated buffer containing valid PNG data, or NULL on
/// error. The caller must free it with `pdfium_free_buffer()`.
///
/// Background is filled white so linework is visible on dark themes.
uint8_t* pdfium_render_page_to_png(const char* path, int page_index,
                                   float dpi, int* out_len);

/// Frees a buffer previously returned by pdfium_render_page_to_png().
void pdfium_free_buffer(void* data);

#ifdef __cplusplus
}
#endif

#endif // PDFIUM_BRIDGE_H
