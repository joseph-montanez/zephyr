// =========================================================================
// MARK: - PDFium Bridge Implementation
//
// Links against pdfium.dll (or libpdfium.dylib / libpdfium.so) to render
// PDF pages to PNG bitmaps. Uses stb_image_write for the PNG encoding.
//
// pdfium API reference: https://pdfium.googlesource.com/pdfium/+/refs/heads/main/public/
// =========================================================================

#include "pdfium_bridge.h"

// PDFium public headers (installed alongside the prebuilt binary)
#include <fpdfview.h>
#include <fpdf_edit.h>   // FPDFBitmap_*

// stb_image_write — single-header PNG encoder (public domain)
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

#include <stdlib.h>
#include <string.h>

// =========================================================================
// Helper: NULL-safe C string copy for PDFium password param
// =========================================================================
// PDFium's FPDF_LoadDocument second argument is a password; we pass NULL
// for unencrypted PDFs. Encrypted PDFs are not supported by this bridge.

// =========================================================================
// pdfium_page_count
// =========================================================================

int pdfium_page_count(const char* path) {
    if (!path) return -1;

    FPDF_InitLibrary();

    FPDF_DOCUMENT doc = FPDF_LoadDocument(path, NULL);
    if (!doc) {
        FPDF_DestroyLibrary();
        return -1;
    }

    int count = FPDF_GetPageCount(doc);
    FPDF_CloseDocument(doc);
    FPDF_DestroyLibrary();

    return count;
}

// =========================================================================
// pdfium_page_width / pdfium_page_height
// =========================================================================

static int internal_page_dimension(const char* path, int page_index,
                                   float dpi, int want_height) {
    if (!path || page_index < 0) return -1;

    FPDF_InitLibrary();

    FPDF_DOCUMENT doc = FPDF_LoadDocument(path, NULL);
    if (!doc) { FPDF_DestroyLibrary(); return -1; }

    int count = FPDF_GetPageCount(doc);
    if (page_index >= count) {
        FPDF_CloseDocument(doc);
        FPDF_DestroyLibrary();
        return -1;
    }

    FS_SIZEF size;
    int ok = FPDF_GetPageSizeByIndexF(doc, page_index, &size);
    FPDF_CloseDocument(doc);
    FPDF_DestroyLibrary();

    if (!ok) return -1;

    double pts = want_height ? (double)size.height : (double)size.width;
    return (int)(pts * dpi / 72.0 + 0.5);
}

int pdfium_page_width(const char* path, int page_index, float dpi) {
    return internal_page_dimension(path, page_index, dpi, 0);
}

int pdfium_page_height(const char* path, int page_index, float dpi) {
    return internal_page_dimension(path, page_index, dpi, 1);
}

// =========================================================================
// pdfium_render_page_to_png
// =========================================================================

uint8_t* pdfium_render_page_to_png(const char* path, int page_index,
                                   float dpi, int* out_len) {
    if (!path || page_index < 0 || !out_len) return NULL;
    *out_len = 0;

    FPDF_InitLibrary();

    // ---- Load document ----
    FPDF_DOCUMENT doc = FPDF_LoadDocument(path, NULL);
    if (!doc) { FPDF_DestroyLibrary(); return NULL; }

    int count = FPDF_GetPageCount(doc);
    if (page_index >= count) {
        FPDF_CloseDocument(doc);
        FPDF_DestroyLibrary();
        return NULL;
    }

    // ---- Compute pixel dimensions at target DPI ----
    FS_SIZEF size;
    FPDF_GetPageSizeByIndexF(doc, page_index, &size);

    int w = (int)((double)size.width  * dpi / 72.0 + 0.5);
    int h = (int)((double)size.height * dpi / 72.0 + 0.5);

    if (w <= 0 || h <= 0 || w > 20000 || h > 20000) {
        FPDF_CloseDocument(doc);
        FPDF_DestroyLibrary();
        return NULL;
    }

    // ---- Load page ----
    FPDF_PAGE page = FPDF_LoadPage(doc, page_index);
    if (!page) {
        FPDF_CloseDocument(doc);
        FPDF_DestroyLibrary();
        return NULL;
    }

    // ---- Create bitmap (BGRA format, with alpha) ----
    FPDF_BITMAP bitmap = FPDFBitmap_CreateEx(w, h, FPDFBitmap_BGRA,
                                              NULL, 0);
    if (!bitmap) {
        FPDF_ClosePage(page);
        FPDF_CloseDocument(doc);
        FPDF_DestroyLibrary();
        return NULL;
    }

    // Fill white background (PDFs are often transparent; black lines
    // on a dark canvas would be invisible).
    FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0xFFFFFFFF);

    // ---- Render page to bitmap ----
    // FPDF_REVERSE_BYTE_ORDER = 0 (no flags). pdfium renders BGRA natively,
    // but stb_image_write expects RGBA. We'll swizzle below.
    FPDF_RenderPageBitmap(bitmap, page, 0, 0, w, h, 0, FPDF_ANNOT);

    // ---- Extract pixels ----
    const uint8_t* src = (const uint8_t*)FPDFBitmap_GetBuffer(bitmap);
    int stride = FPDFBitmap_GetStride(bitmap);

    if (!src || stride <= 0) {
        FPDFBitmap_Destroy(bitmap);
        FPDF_ClosePage(page);
        FPDF_CloseDocument(doc);
        FPDF_DestroyLibrary();
        return NULL;
    }

    // ---- BGRA → RGBA swizzle (pdfium uses BGRA; stb expects RGBA) ----
    uint8_t* rgba = (uint8_t*)malloc(w * h * 4);
    if (!rgba) {
        FPDFBitmap_Destroy(bitmap);
        FPDF_ClosePage(page);
        FPDF_CloseDocument(doc);
        FPDF_DestroyLibrary();
        return NULL;
    }

    for (int y = 0; y < h; y++) {
        const uint8_t* src_row = src + y * stride;
        uint8_t* dst_row = rgba + y * w * 4;
        for (int x = 0; x < w; x++) {
            // BGRA → RGBA: swap B and R
            dst_row[x * 4 + 0] = src_row[x * 4 + 2]; // R ← B
            dst_row[x * 4 + 1] = src_row[x * 4 + 1]; // G ← G
            dst_row[x * 4 + 2] = src_row[x * 4 + 0]; // B ← R
            dst_row[x * 4 + 3] = src_row[x * 4 + 3]; // A ← A
        }
    }

    // ---- Encode to PNG in memory ----
    int png_len = 0;
    unsigned char* png_data = stbi_write_png_to_mem(
        rgba, w * 4, w, h, 4, &png_len);

    free(rgba);

    // ---- Clean up pdfium resources ----
    FPDFBitmap_Destroy(bitmap);
    FPDF_ClosePage(page);
    FPDF_CloseDocument(doc);
    FPDF_DestroyLibrary();

    if (!png_data) return NULL;

    *out_len = png_len;
    return png_data;
}

// =========================================================================
// pdfium_free_buffer
// =========================================================================

void pdfium_free_buffer(void* data) {
    // stbi_write_png_to_mem allocates with STBIW_MALLOC, which maps to
    // malloc by default. Free with the corresponding STBIW_FREE.
    STBIW_FREE(data);
}
