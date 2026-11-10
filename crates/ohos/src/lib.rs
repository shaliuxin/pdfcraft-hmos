//! HarmonyOS (OpenHarmony) C-ABI bridge for PdfCraft's pure-Rust PDF core.
//!
//! Re-exposes the CPU rasterizer in [`pdfcraft_render`] through a small, FFI-safe C API so the
//! C++ NAPI glue layer (mirroring the RustDesk OHOS port) can open a document, query its page
//! count and render a page to non-premultiplied RGBA8888 (row-major).
//!
//! No `wgpu` / `glow` / GPU backend is involved anywhere in this path: rendering is
//! `PageRenderer::render`, the same pure-Rust routine the web (wasm32) build uses.
//!
//! # Safety
//! Every `#[unsafe(no_mangle)] extern "C"` entry keeps raw-pointer work inside an explicit
//! `unsafe` block. Callers (the C++ layer) must uphold the pointer contracts stated on each
//! function. [`PdfcDoc`] guards a single `PageRenderer` with a mutex, so calls may be issued
//! from any number of native threads and are serialised.

use std::fmt::Write as _;
use std::sync::{Arc, Mutex};

mod edit;
// Editing entry points are re-exported at the crate root so their `#[unsafe(no_mangle)]`
// symbols stay in the staticlib.
pub use edit::*;

// `raster` is a private module of pdfcraft-render; its items are re-exported at the crate root.
use pdfcraft_render::{inspect, OpenError, OutlineItem, PageRenderer, RenderConfig, RenderRequest, RequestKind};

/// Opaque document handle: a renderer guarded by a mutex, plus the original bytes so the
/// pure `inspect()` entry (outline / metadata) can reuse them without re-reading the file.
/// Crosses FFI as `void*`.
pub struct PdfcDoc {
    bytes: Arc<Vec<u8>>,
    /// Password used to decrypt the file. Kept so `metadata` / `outline` (which re-run
    /// `inspect()` on the raw bytes) can read encrypted documents too.
    password: Option<Arc<str>>,
    renderer: Mutex<PageRenderer>,
}

/// A rendered page handed across FFI: a straight-alpha RGBA8888 buffer plus geometry.
/// Release the buffer with [`pdfc_free`]. `#[repr(C)]` keeps the layout C-compatible.
#[repr(C)]
pub struct PdfcPage {
    /// Row-major straight-alpha RGBA8888, or null when `width`/`height` are 0.
    pub data: *mut u8,
    /// Rendered width in device pixels (0 on failure).
    pub width: i32,
    /// Rendered height in device pixels (0 on failure).
    pub height: i32,
    /// Byte length of `data` (== width * height * 4).
    pub len: u64,
    /// Allocation capacity, needed to release the buffer. Not for the caller to use.
    pub cap: u64,
}

fn empty_page() -> PdfcPage {
    PdfcPage { data: std::ptr::null_mut(), width: 0, height: 0, len: 0, cap: 0 }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Open a PDF document from raw bytes (unencrypted). Returns a handle, or null on empty input.
///
/// Parsing is lazy and tolerant (mirrors `PageRenderer`'s never-panic contract): a malformed
/// document yields a handle whose `pdfc_page_count` is 0 rather than a failed open.
///
/// For password-protected files use [`pdfc_open_with_password`].
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_open(data: *const u8, len: usize) -> *mut PdfcDoc {
    pdfc_open_with_password(data, len, std::ptr::null(), 0)
}

/// Open a PDF document with a user/owner password. `password` may be null/0 for plain files.
///
/// Returns a handle (possibly with 0 pages when the password is wrong), or null on empty input.
/// The caller can distinguish "wrong password" from "not a PDF" by checking `pdfc_page_count`.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_open_with_password(
    data: *const u8,
    len: usize,
    password: *const u8,
    password_len: usize,
) -> *mut PdfcDoc {
    if data.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let bytes: Arc<Vec<u8>>;
    unsafe {
        let slice = std::slice::from_raw_parts(data, len);
        bytes = Arc::new(slice.to_vec());
    }
    let pw: Option<Arc<str>> = if password.is_null() || password_len == 0 {
        None
    } else {
        let raw = unsafe { std::slice::from_raw_parts(password, password_len) };
        std::str::from_utf8(raw).ok().map(Arc::<str>::from)
    };
    let cfg = RenderConfig { password: pw.clone(), ..RenderConfig::default() };
    let renderer = PageRenderer::new(bytes.clone(), cfg);
    Box::into_raw(Box::new(PdfcDoc { bytes, password: pw, renderer: Mutex::new(renderer) }))
}

/// True when the file can only be read with a password. Lets the UI show a password prompt
/// instead of a generic "cannot parse this file" error.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_needs_password(data: *const u8, len: usize) -> bool {
    if data.is_null() || len == 0 {
        return false;
    }
    let bytes = unsafe { Arc::new(std::slice::from_raw_parts(data, len).to_vec()) };
    matches!(inspect(bytes, None), Err(OpenError::NeedsPassword))
}

/// Free a handle created by [`pdfc_open`]. Safe to call with null.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_close(doc: *mut PdfcDoc) {
    if doc.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(doc));
    }
}

/// Number of pages, or 0 if `doc` is null, malformed, or locked out.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_page_count(doc: *const PdfcDoc) -> i64 {
    if doc.is_null() {
        return 0;
    }
    unsafe {
        let d: &PdfcDoc = &*doc;
        d.renderer.lock().map(|r| r.page_count() as i64).unwrap_or(0)
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Render `page` (0-based) at `scale` (device px per PDF point) to a straight-alpha RGBA8888
/// buffer. Returns the pixels and geometry in a [`PdfcPage`]; release with [`pdfc_free`].
/// On failure `data` is null and `width`/`height` are 0.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_render_page(doc: *mut PdfcDoc, page: i32, scale: f32) -> PdfcPage {
    if doc.is_null() || page < 0 {
        return empty_page();
    }
    let scale = if scale.is_finite() && scale > 0.0 { scale } else { 2.0 };

    let rendered = {
        let mut opt = None;
        unsafe {
            let d: &mut PdfcDoc = &mut *doc;
            if let Ok(mut guard) = d.renderer.lock() {
                let req = RenderRequest {
                    page: page as usize,
                    kind: RequestKind::Pixels,
                    scale,
                    ..Default::default()
                };
                opt = Some(guard.render(req));
            }
        }
        match opt {
            Some(r) => r,
            None => return empty_page(),
        }
    };

    if rendered.error.is_some() {
        return empty_page();
    }

    let words = rendered.rgba.into_words();
    let w = rendered.width;
    let h = rendered.height;
    let mut out: Vec<u8> = Vec::with_capacity((w as usize).saturating_mul(h as usize).saturating_mul(4));

    // Each `u32` word is one pixel. pdfcraft's renderer stores them as 0xRRGGBBAA (red in the
    // high byte); un-premultiply into the straight-alpha RGBA8888 (row-major) an OHOS
    // `NativeWindow` surface expects.
    for word in words.iter() {
        let a = (word >> 24) & 0xFF;
        let b = (word >> 16) & 0xFF;
        let g = (word >> 8) & 0xFF;
        let r = word & 0xFF;
        let unm = |v: u32| if a == 0 { 0 } else { (v.saturating_mul(255) / a).min(255) };
        out.push(unm(r) as u8);
        out.push(unm(g) as u8);
        out.push(unm(b) as u8);
        out.push(a as u8);
    }

    if out.is_empty() {
        return empty_page();
    }
    let data = out.as_mut_ptr();
    let len = out.len() as u64;
    let cap = out.capacity() as u64;
    std::mem::forget(out);
    PdfcPage { data, width: w as i32, height: h as i32, len, cap }
}

/// Release the buffer in a [`PdfcPage`] returned by [`pdfc_render_page`]. Safe on an empty page.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_free(page: PdfcPage) {
    if page.data.is_null() || page.cap == 0 {
        return;
    }
    let v = unsafe { Vec::from_raw_parts(page.data, page.len as usize, page.cap as usize) };
    drop(v);
}

// ---------------------------------------------------------------------------
// JSON string results (metadata / outline / search)
//
// Complex core types (`PageText`, `OutlineItem`, `FontInfo`, `PageInfo`) are not `#[repr(C)]`
// and carry `Vec`/`String`/`Option`/`Arc`, so they cannot cross FFI directly. We serialise each
// result to a UTF-8 JSON byte buffer and hand it over as a `PdfcStr`; the C++ layer copies it
// into a JS string and releases it with [`pdfc_free_str`]. JSON is built by hand (no serde dep)
// so the bridge stays a single path-dependency.
// ---------------------------------------------------------------------------

/// A UTF-8 JSON string handed across FFI. Release with [`pdfc_free_str`].
#[repr(C)]
pub struct PdfcStr {
    /// UTF-8 bytes, or null when empty.
    pub data: *mut u8,
    /// Byte length of `data`.
    pub len: u64,
    /// Allocation capacity, needed to release. Not for the caller to use.
    pub cap: u64,
}

fn empty_str() -> PdfcStr {
    PdfcStr { data: std::ptr::null_mut(), len: 0, cap: 0 }
}

fn to_str(s: String) -> PdfcStr {
    let mut v = s.into_bytes();
    let data = v.as_mut_ptr();
    let len = v.len() as u64;
    let cap = v.capacity() as u64;
    std::mem::forget(v);
    PdfcStr { data, len, cap }
}

/// Release a [`PdfcStr`] returned by `pdfc_metadata` / `pdfc_outline` / `pdfc_search`.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_free_str(s: PdfcStr) {
    if s.data.is_null() || s.cap == 0 {
        return;
    }
    let v = unsafe { Vec::from_raw_parts(s.data, s.len as usize, s.cap as usize) };
    drop(v);
}

fn json_escape_into(out: &mut String, s: &str) {
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn json_str_field(out: &mut String, name: &str, val: &str) {
    out.push('"');
    out.push_str(name);
    out.push_str("\":");
    json_escape_into(out, val);
}

/// Serialise the outline tree (pre-order) into the `"items":[...]` JSON fragment.
fn outline_into(items: &mut String, list: &[OutlineItem], first: &mut bool) {
    for it in list {
        if !*first {
            items.push(',');
        }
        *first = false;
        items.push_str("{\"title\":");
        json_escape_into(items, &it.title);
        let _ = write!(items, ",\"page\":{}", it.page.map(|p| p as i64).unwrap_or(-1));
        items.push('}');
        outline_into(items, &it.children, first);
    }
}

fn doc_parts(doc: *const PdfcDoc) -> Option<(Arc<Vec<u8>>, Option<Arc<str>>)> {
    if doc.is_null() {
        return None;
    }
    let d = unsafe { &*doc };
    Some((d.bytes.clone(), d.password.clone()))
}

/// Document metadata as a JSON object:
/// `{"title","author","subject","keywords","creator","producer","pdfVersion","fileSize",
///  "pages","encrypted","fonts":[{name,kind,embedded}],"pageSize":[[w,h,rot],...]}`.
/// Returns an empty string on error.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_metadata(doc: *const PdfcDoc) -> PdfcStr {
    let (bytes, pw) = match doc_parts(doc) {
        Some(p) => p,
        None => return empty_str(),
    };
    let info = match inspect(bytes, pw.as_deref()) {
        Ok(i) => i,
        Err(_) => return empty_str(),
    };
    let mut s = String::from("{");
    json_str_field(&mut s, "title", info.title.as_deref().unwrap_or(""));
    s.push(',');
    json_str_field(&mut s, "author", info.author.as_deref().unwrap_or(""));
    s.push(',');
    json_str_field(&mut s, "subject", info.subject.as_deref().unwrap_or(""));
    s.push(',');
    json_str_field(&mut s, "keywords", info.keywords.as_deref().unwrap_or(""));
    s.push(',');
    json_str_field(&mut s, "creator", info.creator.as_deref().unwrap_or(""));
    s.push(',');
    json_str_field(&mut s, "producer", info.producer.as_deref().unwrap_or(""));
    s.push(',');
    json_str_field(&mut s, "pdfVersion", &info.pdf_version);
    let _ = write!(s, ",\"fileSize\":{}", info.file_size);
    let _ = write!(s, ",\"pages\":{}", info.pages.len());
    let _ = write!(s, ",\"encrypted\":{}", info.encrypted);
    s.push_str(",\"fonts\":[");
    for (i, f) in info.fonts.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str("{\"name\":");
        json_escape_into(&mut s, &f.name);
        s.push_str(",\"kind\":");
        json_escape_into(&mut s, &f.kind);
        let _ = write!(s, ",\"embedded\":{}", f.embedded);
        s.push('}');
    }
    s.push_str("],\"pageSize\":[");
    for (i, p) in info.pages.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        let _ = write!(s, "[{},{},{}]", p.width, p.height, p.rotation);
    }
    s.push_str("]}");
    to_str(s)
}

/// The document outline/bookmarks flattened pre-order:
/// `{"more":bool,"items":[{"title":str,"page":i64},...]}` where `page` is 0-based or -1.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_outline(doc: *const PdfcDoc) -> PdfcStr {
    let (bytes, pw) = match doc_parts(doc) {
        Some(p) => p,
        None => return empty_str(),
    };
    let info = match inspect(bytes, pw.as_deref()) {
        Ok(i) => i,
        Err(_) => return empty_str(),
    };
    let mut items = String::new();
    let mut first = true;
    outline_into(&mut items, &info.outline, &mut first);
    let mut s = String::new();
    let _ = write!(s, "{{\"more\":{},\"items\":[{}]}}", info.outline_more, items);
    to_str(s)
}

/// Search the whole document for `needle` (a UTF-8 byte string).
/// Returns `{"total":N,"pages":[{"page":i,"count":k,"rects":[[x0,y0,x1,y1],...]},...]}`
/// with match rectangles in view space (PDF points, y-down). `cap` limits total reported
/// matches (0 = default 4096). Returns `{"total":0,"pages":[]}` if nothing found or on error.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_search(
    doc: *mut PdfcDoc,
    needle: *const u8,
    needle_len: usize,
    case_sensitive: bool,
    whole_words: bool,
    cap: i32,
) -> PdfcStr {
    if doc.is_null() || needle.is_null() || needle_len == 0 {
        return empty_str();
    }
    let needle = match std::str::from_utf8(unsafe { std::slice::from_raw_parts(needle, needle_len) }) {
        Ok(s) => s,
        Err(_) => return empty_str(),
    };
    if needle.is_empty() {
        return to_str(String::from("{\"total\":0,\"pages\":[]}"));
    }
    let limit = if cap > 0 { cap as usize } else { 4096 };

    let mut s = String::from("{\"total\":0,\"pages\":[");
    let mut total: usize = 0;
    let mut first_page = true;

    unsafe {
        let d: &mut PdfcDoc = &mut *doc;
        if let Ok(mut guard) = d.renderer.lock() {
            let n = guard.page_count();
            for page in 0..n {
                if total >= limit {
                    break;
                }
                let out = guard.render(RenderRequest {
                    page,
                    kind: RequestKind::Text,
                    ..Default::default()
                });
                if out.error.is_some() {
                    continue;
                }
                let text = match out.text {
                    Some(t) => t,
                    None => continue,
                };
                let ranges = text.find_opts(needle, case_sensitive, whole_words);
                if ranges.is_empty() {
                    continue;
                }
                let count = ranges.len();
                total += count;
                if !first_page {
                    s.push(',');
                }
                first_page = false;
                let _ = write!(s, "{{\"page\":{},\"count\":{},\"rects\":[", page, count);
                let mut first_rect = true;
                for rng in &ranges {
                    for r in text.line_rects(rng.clone()) {
                        if !first_rect {
                            s.push(',');
                        }
                        first_rect = false;
                        let _ = write!(s, "[{},{},{},{}]", r[0], r[1], r[2], r[3]);
                    }
                }
                s.push_str("]}");
            }
        }
    }

    let _ = write!(s, "],\"total\":{}}}", total);
    to_str(s)
}
