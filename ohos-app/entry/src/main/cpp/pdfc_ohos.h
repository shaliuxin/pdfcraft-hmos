#ifndef PDFC_OHOS_H
#define PDFC_OHOS_H
/* C-ABI contract with the Rust core (crates/ohos). Keep in sync with
 * crates/ohos/src/lib.rs. This is the only surface the C++ glue depends on. */

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A rendered page: straight-alpha RGBA8888 (row-major) buffer + geometry.
 * Free the buffer with pdfc_free. */
typedef struct {
    uint8_t* data;   /* row-major straight-alpha RGBA8888, or NULL on failure */
    int32_t  width;  /* device pixels (0 on failure) */
    int32_t  height; /* device pixels (0 on failure) */
    uint64_t len;    /* == width * height * 4 */
    uint64_t cap;    /* allocation capacity; opaque to the caller */
} PdfcPage;

/* Lifecycle. pdfc_open copies the bytes, so `data` may be freed afterwards.
 * pdfc_open_with_password additionally unlocks encrypted files; password may be NULL/0. */
void*    pdfc_open(const uint8_t* data, size_t len);
void*    pdfc_open_with_password(const uint8_t* data, size_t len,
                                 const uint8_t* password, size_t password_len);
/* True when the file needs a password (so the UI can prompt instead of a parse error). */
bool     pdfc_needs_password(const uint8_t* data, size_t len);
void     pdfc_close(void* doc);
int64_t  pdfc_page_count(const void* doc);

/* Render `page` (0-based) at `scale` (device px per PDF point). */
PdfcPage pdfc_render_page(void* doc, int32_t page, float scale);

/* Release a PdfcPage buffer. */
void     pdfc_free(PdfcPage page);

/* A UTF-8 JSON string handed across FFI. Free with pdfc_free_str. */
typedef struct {
    uint8_t* data; /* UTF-8 bytes, or NULL when empty */
    uint64_t len;  /* byte length */
    uint64_t cap;  /* allocation capacity; opaque to the caller */
} PdfcStr;

/* Document metadata (title/author/subject/keywords/creator/producer/pdfVersion/
 * fileSize/pages/encrypted/fonts[]/pageSize[]). JSON object string. */
PdfcStr  pdfc_metadata(const void* doc);

/* Outline/bookmarks flattened pre-order: {"more":bool,"items":[{title,page},...]}. */
PdfcStr  pdfc_outline(const void* doc);

/* Whole-document search. Returns {"total":N,"pages":[{page,count,rects[[x0,y0,x1,y1],..]},..]}.
 * needle is a UTF-8 byte string; rects are in view space (PDF pt, y-down). */
PdfcStr  pdfc_search(void* doc, const uint8_t* needle, size_t needle_len,
                     bool case_sensitive, bool whole_words, int32_t cap);

/* Release a PdfcStr buffer. */
void     pdfc_free_str(PdfcStr s);

/* ---- Editing session (pure-Rust crates; see crates/ohos/src/edit.rs) ------
 * pdfc_edit_open returns an opaque handle (NULL when the file cannot be parsed or
 * the password is wrong). Every other call takes that handle as a bigint pointer. */

/* Open an editable document. password may be NULL/0 for unencrypted files. */
void*    pdfc_edit_open(const uint8_t* data, size_t len,
                        const uint8_t* password, size_t password_len);
void     pdfc_edit_close(void* editor);

/* State JSON: {pages,dirty,canUndo,canRedo,encrypted,title,author,rotations:[...]}. */
PdfcStr  pdfc_edit_state(const void* editor);

/* One JSON command with an `op` field. Returns {ok,error,state,...}. */
PdfcStr  pdfc_edit_command(void* editor, const uint8_t* cmd, size_t cmd_len);
PdfcStr  pdfc_edit_undo(void* editor);
PdfcStr  pdfc_edit_redo(void* editor);

/* Serialise to PDF bytes. Returned in a PdfcPage with width/height == 0; free with
 * pdfc_free. full=true rewrites the file (required after an encryption change). */
PdfcPage pdfc_edit_save(void* editor, bool full);

#ifdef __cplusplus
}
#endif

#endif /* PDFC_OHOS_H */
