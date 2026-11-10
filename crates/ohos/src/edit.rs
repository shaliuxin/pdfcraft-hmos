//! Editing session for the HarmonyOS bridge.
//!
//! `pdfcraft-engine` (the desktop app's session façade) cannot cross-compile for OHOS: its
//! dependency chain ends in `pdfcraft-print -> winprint -> sigstore -> reqwest -> rustls ->
//! aws-lc-sys`, which needs CMake + a host C compiler and rejects `--target=aarch64-linux-ohos`.
//! Verified 2026-11-07 on this machine. Instead this module drives the *pure-Rust* editing
//! crates directly:
//!
//!   `pdfcraft-cos`       — document object model, open / write_full / write_incremental / encryption
//!   `pdfcraft-organize`  — rotate / delete / move / duplicate / insert / extract / info / bookmarks
//!   `pdfcraft-annot`     — sticky notes, highlights, shapes, replies
//!   `pdfcraft-forms`     — add fields, fill values, reset
//!   `pdfcraft-edit`      — add text, watermarks, headers/footers, delete added content
//!
//! All of them are pure Rust with zero native dependencies (verified by cross-compiling for
//! `aarch64-unknown-linux-ohos`). `cos::Document` is cheap to clone (copy-on-write overlay), so
//! undo/redo uses snapshots of it — the same approach `engine::Session` takes.
//!
//! Commands arrive as one UTF-8 JSON object with an `op` field. A single `pdfc_edit_command`
//! entry point keeps the NAPI surface small while new operations only need a new match arm.

use std::sync::{Arc, Mutex};

use pdfcraft_annot as annot;
use pdfcraft_cos as cos;
use pdfcraft_edit as edit;
use pdfcraft_forms as forms;
use pdfcraft_organize as org;
use serde_json::Value;

use crate::{PdfcPage, PdfcStr, empty_page, empty_str, json_escape_into, json_str_field, to_str};

/// Maximum undo snapshots kept (each is a cheap copy-on-write `Document` clone).
const UNDO_LIMIT: usize = 60;

struct EditorState {
    doc: cos::Document,
    undo: Vec<cos::Document>,
    redo: Vec<cos::Document>,
    dirty: bool,
    /// Sequential id for annotation `/NM` values (no OS randomness needed).
    seq: u64,
}

/// Opaque editable-document handle, crosses FFI as `void*`.
pub struct PdfcEditor {
    inner: Mutex<EditorState>,
}

// ---------------------------------------------------------------------------
// Small JSON helpers (serde_json is pure Rust and cross-compiles for OHOS).
// ---------------------------------------------------------------------------

fn s<'a>(v: &'a Value, key: &str, default: &'a str) -> &'a str {
    v.get(key).and_then(Value::as_str).unwrap_or(default)
}

fn f(v: &Value, key: &str, default: f64) -> f64 {
    v.get(key).and_then(Value::as_f64).unwrap_or(default)
}

fn i(v: &Value, key: &str, default: i64) -> i64 {
    v.get(key).and_then(Value::as_i64).unwrap_or(default)
}

fn b(v: &Value, key: &str, default: bool) -> bool {
    v.get(key).and_then(Value::as_bool).unwrap_or(default)
}

fn page_list(v: &Value, key: &str) -> Vec<usize> {
    v.get(key)
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|x| x.as_u64().map(|n| n as usize)).collect())
        .unwrap_or_default()
}

fn rect4(v: &Value, key: &str, default: [f64; 4]) -> [f64; 4] {
    match v.get(key).and_then(Value::as_array) {
        Some(a) if a.len() >= 4 => [
            a[0].as_f64().unwrap_or(default[0]),
            a[1].as_f64().unwrap_or(default[1]),
            a[2].as_f64().unwrap_or(default[2]),
            a[3].as_f64().unwrap_or(default[3]),
        ],
        _ => default,
    }
}

fn point2(v: &Value, key: &str, default: [f64; 2]) -> [f64; 2] {
    match v.get(key).and_then(Value::as_array) {
        Some(a) if a.len() >= 2 => [a[0].as_f64().unwrap_or(default[0]), a[1].as_f64().unwrap_or(default[1])],
        _ => default,
    }
}

fn rgb(v: &Value, key: &str, default: [f64; 3]) -> [f64; 3] {
    match v.get(key).and_then(Value::as_array) {
        Some(a) if a.len() >= 3 => [
            a[0].as_f64().unwrap_or(default[0]),
            a[1].as_f64().unwrap_or(default[1]),
            a[2].as_f64().unwrap_or(default[2]),
        ],
        _ => default,
    }
}

fn strings(v: &Value, key: &str) -> Vec<String> {
    v.get(key)
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

fn quads(v: &Value, key: &str) -> Vec<[f64; 8]> {
    v.get(key)
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|q| q.as_array())
                .filter(|q| q.len() >= 8)
                .map(|q| {
                    let mut out = [0.0f64; 8];
                    for (i, x) in q.iter().take(8).enumerate() {
                        out[i] = x.as_f64().unwrap_or(0.0);
                    }
                    out
                })
                .collect()
        })
        .unwrap_or_default()
}

/// All pages when the command omits `pages` or sends an empty list.
fn all_or(v: &Value, doc: &cos::Document) -> Vec<usize> {
    let p = page_list(v, "pages");
    if p.is_empty() {
        (0..org::page_count(doc).unwrap_or(0)).collect()
    } else {
        p
    }
}

fn meta(seq: &mut u64) -> annot::Meta {
    *seq += 1;
    annot::Meta { date: None, id: format!("ohos-{}", *seq) }
}

// ---------------------------------------------------------------------------
// Command dispatch
// ---------------------------------------------------------------------------

/// Ok(extra) where `extra` is a JSON fragment inserted into the success reply (may be empty).
type CmdResult = Result<String, String>;

fn apply(state: &mut EditorState, op: &str, v: &Value) -> CmdResult {
    // Split the borrow so helper functions can read the doc / bump the id counter while
    // individual match arms hold `&mut Document`.
    let EditorState { doc, seq, .. } = &mut *state;
    match op {
        // ---- Organize pages ------------------------------------------------
        "rotate" => org::rotate_pages(doc, &page_list(v, "pages"), i(v, "degrees", 90))
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "deletePages" => org::delete_pages(doc, &page_list(v, "pages"))
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "movePages" => org::move_pages(doc, &page_list(v, "pages"), i(v, "to", 0).max(0) as usize)
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "reversePages" => org::reverse_pages(doc, &page_list(v, "pages"))
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "duplicatePages" => {
            let at = v.get("at").and_then(Value::as_u64).map(|n| n as usize);
            org::duplicate_pages(doc, &page_list(v, "pages"), at)
                .map(|_| String::new()).map_err(|e| e.to_string())
        }
        "insertBlank" => org::insert_blank_page(
            doc,
            i(v, "at", 0).max(0) as usize,
            f(v, "width", 612.0),
            f(v, "height", 792.0),
        )
        .map(|_| String::new()).map_err(|e| e.to_string()),
        "extractPages" => {
            let pages = page_list(v, "pages");
            let extracted = org::extract_pages(doc, &pages).map_err(|e| e.to_string())?;
            *doc = extracted;
            Ok(String::new())
        }
        "setInfo" => org::set_info(doc, s(v, "key", "Title"), s(v, "value", ""))
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "addBookmark" => org::add_bookmark(
            doc,
            &page_list(v, "parent"),
            i(v, "index", i64::MAX).max(0) as usize,
            s(v, "title", "Bookmark"),
            i(v, "page", 0).max(0) as usize,
        )
        .map(|_| String::new()).map_err(|e| e.to_string()),
        "deleteBookmark" => org::delete_bookmark(doc, &page_list(v, "path"))
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "renameBookmark" => org::rename_bookmark(doc, &page_list(v, "path"), s(v, "title", ""))
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "numberPages" => {
            // Label pages from `start` using the requested style.
            let from = i(v, "start", 0).max(0) as usize;
            let to = i(v, "to", -1);
            let count = org::page_count(doc).unwrap_or(0) as i64;
            let end = if to < 0 { count - 1 } else { to.min(count - 1) };
            if end < from as i64 { return Err("no pages in the label range".into()); }
            let style = match s(v, "style", "decimal") {
                "romanLower" => org::LabelStyle::LowerRoman,
                "romanUpper" => org::LabelStyle::UpperRoman,
                "alphaLower" => org::LabelStyle::LowerAlpha,
                "alphaUpper" => org::LabelStyle::UpperAlpha,
                "none" => org::LabelStyle::None,
                _ => org::LabelStyle::Decimal,
            };
            org::number_pages(
                doc,
                from,
                end as usize,
                style,
                s(v, "prefix", ""),
                i(v, "first", 1).max(1) as u32,
            )
            .map(|_| String::new()).map_err(|e| e.to_string())
        }

        // ---- Comments / annotations ---------------------------------------
        "addNote" => {
            let shape = annot::Shape::Note {
                at: point2(v, "at", [72.0, 72.0]),
                icon: annot::NoteIcon::default(),
            };
            let style = annot::Style::default_for(&shape);
            let m = meta(seq);
            annot::add_annotation(doc, &annot::NewAnnotation {
                page: i(v, "page", 0).max(0) as usize,
                shape,
                style,
                contents: s(v, "text", "").to_string(),
                author: s(v, "author", "PdfCraft").to_string(),
            }, &m)
            .map(|idx| format!("\"index\":{}", idx)).map_err(|e| e.to_string())
        }
        "addHighlight" => {
            let q = quads(v, "quads");
            if q.is_empty() { return Err("no highlight quads given".into()); }
            let shape = annot::Shape::TextMarkup { kind: annot::Markup::Highlight, quads: q };
            let style = annot::Style::default_for(&shape);
            let m = meta(seq);
            annot::add_annotation(doc, &annot::NewAnnotation {
                page: i(v, "page", 0).max(0) as usize,
                shape,
                style,
                contents: s(v, "text", "").to_string(),
                author: s(v, "author", "PdfCraft").to_string(),
            }, &m)
            .map(|idx| format!("\"index\":{}", idx)).map_err(|e| e.to_string())
        }
        "addShape" => {
            let rect = rect4(v, "rect", [72.0, 72.0, 240.0, 160.0]);
            let shape = match s(v, "shape", "rectangle") {
                "oval" => annot::Shape::Oval { rect },
                "line" => annot::Shape::Line {
                    from: [rect[0], rect[1]],
                    to: [rect[2], rect[3]],
                    start: annot::LineEnding::None,
                    end: annot::LineEnding::None,
                },
                _ => annot::Shape::Rectangle { rect },
            };
            let style = annot::Style::default_for(&shape);
            let m = meta(seq);
            annot::add_annotation(doc, &annot::NewAnnotation {
                page: i(v, "page", 0).max(0) as usize,
                shape,
                style,
                contents: s(v, "text", "").to_string(),
                author: s(v, "author", "PdfCraft").to_string(),
            }, &m)
            .map(|idx| format!("\"index\":{}", idx)).map_err(|e| e.to_string())
        }
        "deleteAnnotation" => annot::delete_annotation(
            doc,
            i(v, "page", 0).max(0) as usize,
            i(v, "index", 0).max(0) as usize,
        )
        .map(|_| String::new()).map_err(|e| e.to_string()),
        "setAnnotationContents" => {
            let m = meta(seq);
            annot::set_contents(
                doc,
                i(v, "page", 0).max(0) as usize,
                i(v, "index", 0).max(0) as usize,
                s(v, "text", ""),
                &m,
            )
            .map(|_| String::new()).map_err(|e| e.to_string())
        }
        "replyToAnnotation" => {
            let m = meta(seq);
            annot::add_reply(
                doc,
                i(v, "page", 0).max(0) as usize,
                i(v, "index", 0).max(0) as usize,
                s(v, "text", ""),
                s(v, "author", "PdfCraft"),
                &m,
            )
            .map(|_| String::new()).map_err(|e| e.to_string())
        }
        "listAnnotations" => {
            let page = i(v, "page", 0).max(0) as usize;
            let items = annot::summaries(doc);
            let mut arr = String::from("[");
            let mut first = true;
            for it in items.iter().filter(|it| it.page == page) {
                if !first { arr.push(','); }
                first = false;
                arr.push('{');
                json_str_field(&mut arr, "kind", &it.subtype);
                arr.push(',');
                json_str_field(&mut arr, "text", it.contents.as_deref().unwrap_or(""));
                let _ = std::fmt::Write::write_fmt(&mut arr, format_args!(",\"index\":{}", it.index));
                arr.push_str("}");
            }
            arr.push(']');
            Ok(format!("\"annotations\":{}", arr))
        }

        // ---- Forms ---------------------------------------------------------
        "addField" => {
            let kind = match s(v, "kind", "text") {
                "checkbox" => forms::NewField::CheckBox,
                "date" => forms::NewField::Date,
                "radio" => forms::NewField::Radio {
                    group: None,
                    export: s(v, "export", "Yes").to_string(),
                },
                "combo" => forms::NewField::Combo { options: strings(v, "options"), editable: b(v, "editable", false) },
                "list" => forms::NewField::List { options: strings(v, "options"), multi: b(v, "multi", false) },
                "button" => forms::NewField::Button { caption: s(v, "caption", "Button").to_string() },
                "image" => forms::NewField::Image,
                "signature" => forms::NewField::Signature,
                _ => forms::NewField::Text { multiline: b(v, "multiline", false) },
            };
            let name = match v.get("name").and_then(Value::as_str) {
                Some(n) if !n.is_empty() => Some(n),
                _ => None,
            };
            forms::add_field(
                doc,
                i(v, "page", 0).max(0) as usize,
                rect4(v, "rect", [72.0, 72.0, 240.0, 96.0]),
                &kind,
                name,
            )
            .map(|n| { let mut o = String::from("\"fieldName\":"); json_escape_into(&mut o, &n); o })
            .map_err(|e| e.to_string())
        }
        "setFieldValue" => {
            let value = if b(v, "checked", false) && v.get("value").is_none() {
                forms::FieldValue::Check(true)
            } else {
                match v.get("value") {
                    Some(Value::Bool(x)) => forms::FieldValue::Check(*x),
                    Some(Value::Array(a)) => forms::FieldValue::Choice(
                        a.iter().filter_map(|x| x.as_str().map(String::from)).collect(),
                    ),
                    _ => forms::FieldValue::Text(s(v, "value", "").to_string()),
                }
            };
            forms::set_value(doc, s(v, "name", ""), &value)
                .map(|_| String::new()).map_err(|e| e.to_string())
        }
        "deleteField" => forms::delete_field(doc, s(v, "name", ""))
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "resetForm" => forms::reset(doc, None)
            .map(|_| String::new()).map_err(|e| e.to_string()),
        "listFields" => {
            let mut arr = String::from("[");
            for (i, fld) in forms::fields(doc).iter().enumerate() {
                if i > 0 { arr.push(','); }
                arr.push('{');
                json_str_field(&mut arr, "name", &fld.name);
                arr.push(',');
                json_str_field(&mut arr, "kind", &format!("{:?}", fld.kind));
                arr.push('}');
            }
            arr.push(']');
            Ok(format!("\"fields\":{}", arr))
        }

        // ---- Edit content --------------------------------------------------
        "addText" => {
            let mut t = edit::AddedText {
                rect: rect4(v, "rect", [72.0, 72.0, 300.0, 100.0]),
                text: s(v, "text", "").to_string(),
                size: f(v, "size", 12.0),
                color: rgb(v, "color", [0.0, 0.0, 0.0]),
                bold: b(v, "bold", false),
                italic: b(v, "italic", false),
                ..Default::default()
            };
            t.family = match s(v, "family", "Helvetica") {
                "Times" => edit::Family::Times,
                "Courier" => edit::Family::Courier,
                _ => edit::Family::Helvetica,
            };
            t.align = match s(v, "align", "Left") {
                "Center" => edit::Align::Center,
                "Right" => edit::Align::Right,
                "Justify" => edit::Align::Justify,
                _ => edit::Align::Left,
            };
            edit::add_content(doc, i(v, "page", 0).max(0) as usize, &edit::Content::Text(t))
                .map(|idx| format!("\"index\":{}", idx)).map_err(|e| e.to_string())
        }
        "deleteContent" => edit::delete_content(
            doc,
            i(v, "page", 0).max(0) as usize,
            i(v, "index", 0).max(0) as usize,
        )
        .map(|_| String::new()).map_err(|e| e.to_string()),
        "addWatermark" => {
            let pages = all_or(v, doc);
            let wm = edit::Watermark {
                text: s(v, "text", "").to_string(),
                color: rgb(v, "color", [0.6, 0.6, 0.6]),
                opacity: f(v, "opacity", 0.5),
                rotation: f(v, "rotation", 45.0),
                behind: b(v, "behind", false),
                font_size: f(v, "fontSize", 0.0),
                scale: f(v, "scale", 0.5),
                offset: point2(v, "offset", [0.0, 0.0]),
                ..Default::default()
            };
            edit::add_watermark(doc, &pages, &wm, b(v, "replace", true))
                .map(|_| String::new()).map_err(|e| e.to_string())
        }
        "addHeaderFooter" => {
            let pages = all_or(v, doc);
            let texts = strings(v, "text");
            let mut hf = edit::HeaderFooter::default();
            for (i, t) in texts.iter().take(6).enumerate() {
                hf.text[i] = t.clone();
            }
            hf.font_size = f(v, "fontSize", 10.0);
            hf.color = rgb(v, "color", [0.0, 0.0, 0.0]);
            hf.underline = b(v, "underline", false);
            let cx = edit::Context { date: (2026, 1, 1) };
            edit::add_header_footer(doc, &pages, &hf, b(v, "replace", true), &cx)
                .map(|_| String::new()).map_err(|e| e.to_string())
        }
        "removeMarks" => {
            let pages = all_or(v, doc);
            let kind = match s(v, "kind", "watermark") {
                "headerFooter" => edit::MarkKind::HeaderFooter,
                "background" => edit::MarkKind::Background,
                _ => edit::MarkKind::Watermark,
            };
            edit::remove_marks(doc, &pages, kind)
                .map(|n| format!("\"removed\":{}", n)).map_err(|e| e.to_string())
        }

        // ---- Protection ----------------------------------------------------
        "encrypt" => {
            let algorithm = match s(v, "algorithm", "aes256") {
                "rc4_40" => cos::Algorithm::Rc4_40,
                "rc4_128" => cos::Algorithm::Rc4_128,
                "aes128" => cos::Algorithm::Aes128,
                _ => cos::Algorithm::Aes256,
            };
            let mut seed = [0u8; 32];
            let raw = v.get("seed").and_then(Value::as_array);
            if let Some(a) = raw {
                for (i, x) in a.iter().take(32).enumerate() {
                    seed[i] = x.as_u64().unwrap_or(0) as u8;
                }
            } else {
                // Deterministic fallback derived from the passwords and a counter. A real client
                // should supply 32 random bytes through `seed`.
                let mut h: u64 = 0x9e3779b97f4a7c15;
                for c in s(v, "userPassword", "").bytes().chain(s(v, "ownerPassword", "").bytes()) {
                    h = h.wrapping_mul(31).wrapping_add(c as u64);
                }
                for x in seed.chunks_mut(8) {
                    h ^= h << 13; h ^= h >> 7; h ^= h << 17;
                    for (i, byte) in x.iter_mut().enumerate() { *byte = (h >> (i * 8)) as u8; }
                }
            }
            let user = s(v, "userPassword", "").to_string();
            let owner = s(v, "ownerPassword", "").to_string();
            doc.set_encryption(&cos::NewEncryption {
                algorithm,
                user_password: &user,
                owner_password: &owner,
                permissions: i(v, "permissions", -1) as i32,
                encrypt_metadata: b(v, "encryptMetadata", true),
                seed,
            })
            .map(|_| String::new()).map_err(|e| e.to_string())
        }
        "removeEncryption" => {
            doc.remove_encryption();
            Ok(String::new())
        }

        _ => Err(format!("unknown op: {}", op)),
    }
}

// ---------------------------------------------------------------------------
// State serialisation
// ---------------------------------------------------------------------------

fn state_json(state: &EditorState) -> String {
    let doc = &state.doc;
    let pages = org::page_count(doc).unwrap_or(0);
    let mut out = String::from("{");
    let _ = std::fmt::Write::write_fmt(&mut out, format_args!("\"pages\":{}", pages));
    let _ = std::fmt::Write::write_fmt(&mut out, format_args!(",\"dirty\":{}", state.dirty));
    let _ = std::fmt::Write::write_fmt(&mut out, format_args!(",\"canUndo\":{}", !state.undo.is_empty()));
    let _ = std::fmt::Write::write_fmt(&mut out, format_args!(",\"canRedo\":{}", !state.redo.is_empty()));
    // `security()` is the handler the file was *opened* with; `output_handler()` is what the
    // next save writes (which is what `encrypt` / `removeEncryption` change). Report the latter.
    let _ = std::fmt::Write::write_fmt(&mut out, format_args!(",\"encrypted\":{}", doc.output_handler().is_some()));
    out.push(',');
    json_str_field(&mut out, "title", org::info(doc, "Title").as_deref().unwrap_or(""));
    out.push(',');
    json_str_field(&mut out, "author", org::info(doc, "Author").as_deref().unwrap_or(""));
    out.push_str(",\"rotations\":[");
    for p in 0..pages {
        if p > 0 { out.push(','); }
        let _ = std::fmt::Write::write_fmt(&mut out, format_args!("{}", org::page_rotation(doc, p).unwrap_or(0)));
    }
    out.push_str("]}");
    out
}

fn reply(state: &EditorState, ok: bool, error: &str, extra: &str) -> PdfcStr {
    let mut out = String::from("{");
    let _ = std::fmt::Write::write_fmt(&mut out, format_args!("\"ok\":{}", ok));
    out.push(',');
    json_str_field(&mut out, "error", error);
    out.push_str(",\"state\":");
    out.push_str(&state_json(state));
    if !extra.is_empty() {
        out.push(',');
        out.push_str(extra);
    }
    out.push('}');
    to_str(out)
}

fn push_undo(state: &mut EditorState) {
    state.undo.push(state.doc.clone());
    if state.undo.len() > UNDO_LIMIT {
        state.undo.remove(0);
    }
    state.redo.clear();
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

/// Open an editable document from raw bytes. `password` may be null/0 for unencrypted files.
/// Returns null when the file cannot be parsed (or the password is wrong).
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_edit_open(
    data: *const u8,
    len: usize,
    password: *const u8,
    password_len: usize,
) -> *mut PdfcEditor {
    if data.is_null() || len == 0 {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(data, len).to_vec() };
    let pw: Option<String> = if password.is_null() || password_len == 0 {
        None
    } else {
        let raw = unsafe { std::slice::from_raw_parts(password, password_len) };
        std::str::from_utf8(raw).ok().map(String::from)
    };
    let doc = match cos::Document::open_with_password(Arc::new(bytes), pw.as_deref()) {
        Ok(d) => d,
        Err(_) => return std::ptr::null_mut(),
    };
    Box::into_raw(Box::new(PdfcEditor {
        inner: Mutex::new(EditorState { doc, undo: Vec::new(), redo: Vec::new(), dirty: false, seq: 0 }),
    }))
}

/// Free an editing handle. Safe on null.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_edit_close(editor: *mut PdfcEditor) {
    if editor.is_null() {
        return;
    }
    unsafe { drop(Box::from_raw(editor)); }
}

/// Current state as JSON: `{pages,dirty,canUndo,canRedo,encrypted,title,author,rotations:[...]}`.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_edit_state(editor: *const PdfcEditor) -> PdfcStr {
    if editor.is_null() { return empty_str(); }
    let e = unsafe { &*editor };
    match e.inner.lock() {
        Ok(s) => to_str(state_json(&s)),
        Err(_) => empty_str(),
    }
}

/// Run one editing command. `cmd` is a UTF-8 JSON object with an `op` field.
/// Returns `{ok,error,state:...,<extra>}`. On success the document becomes dirty and the
/// previous state is pushed onto the undo stack; on failure nothing changes.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_edit_command(
    editor: *mut PdfcEditor,
    cmd: *const u8,
    cmd_len: usize,
) -> PdfcStr {
    if editor.is_null() || cmd.is_null() || cmd_len == 0 {
        return empty_str();
    }
    let raw = unsafe { std::slice::from_raw_parts(cmd, cmd_len) };
    let v: Value = match serde_json::from_slice(raw) {
        Ok(v) => v,
        Err(e) => return to_str(format!("{{\"ok\":false,\"error\":\"bad JSON: {}\",\"state\":null}}", e)),
    };
    let op = v.get("op").and_then(Value::as_str).unwrap_or("").to_string();

    // Read-only commands must not create an undo entry.
    let readonly = matches!(op.as_str(), "listFields" | "listAnnotations");
    let e = unsafe { &*editor };
    let mut state = match e.inner.lock() {
        Ok(s) => s,
        Err(_) => return empty_str(),
    };
    if !readonly {
        push_undo(&mut state);
    }
    match apply(&mut state, &op, &v) {
        Ok(extra) => {
            if !readonly { state.dirty = true; }
            reply(&state, true, "", &extra)
        }
        Err(err) => {
            if !readonly {
                if let Some(prev) = state.undo.pop() {
                    state.doc = prev;
                }
            }
            reply(&state, false, &err, "")
        }
    }
}

/// Undo the last command. Returns the same `{ok,error,state}` shape.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_edit_undo(editor: *mut PdfcEditor) -> PdfcStr {
    if editor.is_null() { return empty_str(); }
    let e = unsafe { &*editor };
    let mut state = match e.inner.lock() { Ok(s) => s, Err(_) => return empty_str() };
    match state.undo.pop() {
        Some(prev) => {
            let current = std::mem::replace(&mut state.doc, prev);
            state.redo.push(current);
            reply(&state, true, "", "")
        }
        None => reply(&state, false, "nothing to undo", ""),
    }
}

/// Redo the last undone command.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_edit_redo(editor: *mut PdfcEditor) -> PdfcStr {
    if editor.is_null() { return empty_str(); }
    let e = unsafe { &*editor };
    let mut state = match e.inner.lock() { Ok(s) => s, Err(_) => return empty_str() };
    match state.redo.pop() {
        Some(next) => {
            let current = std::mem::replace(&mut state.doc, next);
            state.undo.push(current);
            reply(&state, true, "", "")
        }
        None => reply(&state, false, "nothing to redo", ""),
    }
}

/// Serialise the edited document to PDF bytes. `full=true` rewrites the file from scratch
/// (smaller, and required after an encryption change); `false` appends an incremental update.
/// The bytes are returned in a [`PdfcPage`] whose `width`/`height` are 0; release with
/// [`crate::pdfc_free`]. Returns an empty page on failure.
#[unsafe(no_mangle)]
pub extern "C" fn pdfc_edit_save(editor: *mut PdfcEditor, full: bool) -> PdfcPage {
    if editor.is_null() { return empty_page(); }
    let e = unsafe { &*editor };
    let state = match e.inner.lock() { Ok(s) => s, Err(_) => return empty_page() };
    let must_full = full || state.doc.encryption_changed() || state.doc.full_save_required();
    let opts = cos::SaveOptions::default();
    let bytes = if must_full {
        cos::write_full(&state.doc, &opts)
    } else {
        cos::write_incremental(&state.doc, &opts)
    };
    let mut out = match bytes { Ok(b) => b, Err(_) => return empty_page() };
    if out.is_empty() { return empty_page(); }
    let data = out.as_mut_ptr();
    let len = out.len() as u64;
    let cap = out.capacity() as u64;
    std::mem::forget(out);
    PdfcPage { data, width: 0, height: 0, len, cap }
}
