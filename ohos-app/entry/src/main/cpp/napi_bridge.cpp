// ArkTS <-> C++ NAPI boundary for the PdfCraft HarmonyOS port.
//
// Thin, synchronous wrappers over the C-ABI functions in pdfc_ohos.h (implemented in the
// Rust core `libpdfcraft_ohos.a`). PdfCraft is a static-document reader, so — unlike RustDesk —
// there is no persistent render loop or threadsafe-function event pump: each call opens a
// document, renders one page to an RGBA8888 buffer, hands it to ArkTS, and frees it.

#include "pdfc_ohos.h"

#include <hilog/log.h>
#include <napi/native_api.h>

#include <cstring>
#include <string>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "PdfCraftNapi"

namespace {

// Defined below; forward-declared so JsOpen can unlock encrypted documents too.
bool GetUtf8(napi_env env, napi_value value, std::string& out);

napi_value MakeUndefined(napi_env env) {
    napi_value out;
    napi_get_undefined(env, &out);
    return out;
}

napi_value MakeNull(napi_env env) {
    napi_value out;
    napi_get_null(env, &out);
    return out;
}

PdfcStr empty_pdfc_str() {
    PdfcStr s;
    s.data = nullptr;
    s.len = 0;
    s.cap = 0;
    return s;
}

// Read a document handle (64-bit pointer) passed as a JS BigInt.
bool GetHandle(napi_env env, napi_value value, void*& out) {
    bool lossless = false;
    uint64_t h = 0;
    if (napi_get_value_bigint_uint64(env, value, &h, &lossless) != napi_ok) return false;
    out = reinterpret_cast<void*>(static_cast<uintptr_t>(h));
    return true;
}

// open(ArrayBuffer, password?) -> BigInt handle (null on failure)
// The optional password unlocks encrypted PDFs for the reader as well as metadata/outline.
napi_value JsOpen(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    void* raw = nullptr;
    size_t len = 0;
    // OHOS NAPI 签名：napi_get_cb_info(env, cbinfo, &argc, argv, napi_value* this_arg, void** data)。
    // 前 5 参用不到 this_arg / data，传 nullptr。
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) {
        return MakeNull(env);
    }
    if (napi_get_arraybuffer_info(env, args[0], &raw, &len) != napi_ok) {
        return MakeNull(env);
    }
    std::string pw;
    const uint8_t* pw_ptr = nullptr;
    size_t pw_len = 0;
    if (argc >= 2) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, args[1], &t);
        if (t == napi_string && GetUtf8(env, args[1], pw)) {
            pw_ptr = reinterpret_cast<const uint8_t*>(pw.data());
            pw_len = pw.size();
        }
    }
    void* doc = pdfc_open_with_password(static_cast<const uint8_t*>(raw), len, pw_ptr, pw_len);
    if (doc == nullptr) {
        return MakeNull(env);
    }
    napi_value result;
    napi_create_bigint_uint64(env, static_cast<uint64_t>(reinterpret_cast<uintptr_t>(doc)), &result);
    return result;
}

// needsPassword(ArrayBuffer) -> boolean
napi_value JsNeedsPassword(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    void* raw = nullptr;
    size_t len = 0;
    bool needed = false;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) == napi_ok && argc >= 1 &&
        napi_get_arraybuffer_info(env, args[0], &raw, &len) == napi_ok) {
        needed = pdfc_needs_password(static_cast<const uint8_t*>(raw), len);
    }
    napi_value out;
    napi_get_boolean(env, needed, &out);
    return out;
}

// pageCount(handle) -> number
napi_value JsPageCount(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* doc = nullptr;
    int32_t zero = 0;
    if (argc < 1 || !GetHandle(env, args[0], doc)) {
        napi_value out;
        napi_create_int32(env, zero, &out);
        return out;
    }
    int64_t count = pdfc_page_count(doc);
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(count), &result);
    return result;
}

// renderPage(handle, page, scale) -> {width, height, rgba: ArrayBuffer} | null
napi_value JsRenderPage(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    void* doc = nullptr;
    int32_t page = 0;
    double scale_d = 2.0;
    if (argc < 1 || !GetHandle(env, args[0], doc)) {
        return MakeNull(env);
    }
    if (argc >= 2) napi_get_value_int32(env, args[1], &page);
    if (argc >= 3) napi_get_value_double(env, args[2], &scale_d);

    PdfcPage rp = pdfc_render_page(doc, page, static_cast<float>(scale_d));
    if (rp.data == nullptr || rp.len == 0) {
        if (rp.data != nullptr) {
            pdfc_free(rp);
        }
        return MakeNull(env);
    }

    // Capture geometry and length BEFORE releasing the Rust-owned buffer.
    const int32_t w = rp.width;
    const int32_t h = rp.height;
    const size_t len = static_cast<size_t>(rp.len);

    void* buf_ptr = nullptr;
    napi_value buf;
    // OHOS NAPI：napi_create_arraybuffer(env, byte_length, void** data, napi_value* result)
    // —— data 在前、result 在后（与 Node.js 相反）。
    if (napi_create_arraybuffer(env, len, &buf_ptr, &buf) != napi_ok) {
        pdfc_free(rp);
        return MakeNull(env);
    }
    std::memcpy(buf_ptr, rp.data, len);
    pdfc_free(rp); // safe: bytes already copied, geometry captured

    napi_value obj;
    napi_create_object(env, &obj);
    // OHOS NAPI：napi_set_property 的 key 必须是 napi_value（字符串），不能是 const char*。
    auto set_str = [&](const char* name, napi_value val) {
        napi_value key;
        if (napi_create_string_utf8(env, name, strlen(name), &key) == napi_ok) {
            napi_set_property(env, obj, key, val);
        }
    };
    napi_value wv;
    napi_create_int32(env, w, &wv);
    set_str("width", wv);
    napi_value hv;
    napi_create_int32(env, h, &hv);
    set_str("height", hv);
    set_str("rgba", buf);
    return obj;
}

// Convert a Rust-owned PdfcStr (UTF-8 JSON) into a JS string, then release the buffer.
napi_value StrToJs(napi_env env, PdfcStr s) {
    std::string utf8;
    if (s.data != nullptr && s.len > 0) {
        utf8.assign(reinterpret_cast<const char*>(s.data), static_cast<size_t>(s.len));
    }
    pdfc_free_str(s);
    napi_value out;
    if (utf8.empty()) {
        napi_create_string_utf8(env, "", 0, &out);
        return out;
    }
    napi_create_string_utf8(env, utf8.c_str(), utf8.size(), &out);
    return out;
}

// metadata(handle) -> string(JSON)
napi_value JsMetadata(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* doc = nullptr;
    if (argc < 1 || !GetHandle(env, args[0], doc)) {
        return StrToJs(env, empty_pdfc_str());
    }
    return StrToJs(env, pdfc_metadata(doc));
}

// outline(handle) -> string(JSON)
napi_value JsOutline(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* doc = nullptr;
    if (argc < 1 || !GetHandle(env, args[0], doc)) {
        return StrToJs(env, empty_pdfc_str());
    }
    return StrToJs(env, pdfc_outline(doc));
}

// search(handle, needle, caseSensitive, wholeWords, cap) -> string(JSON)
napi_value JsSearch(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* doc = nullptr;
    if (argc < 2 || !GetHandle(env, args[0], doc)) {
        return StrToJs(env, empty_pdfc_str());
    }
    // needle -> UTF-8 bytes
    size_t slen = 0;
    char* str = nullptr;
    if (napi_get_value_string_utf8(env, args[1], nullptr, 0, &slen) != napi_ok || slen == 0) {
        return StrToJs(env, empty_pdfc_str());
    }
    std::string needle(slen, '\0');
    if (napi_get_value_string_utf8(env, args[1], needle.data(), slen, &slen) != napi_ok) {
        return StrToJs(env, empty_pdfc_str());
    }
    bool cs = false;
    bool ww = false;
    int32_t cap = 0;
    if (argc >= 3) napi_get_value_bool(env, args[2], &cs);
    if (argc >= 4) napi_get_value_bool(env, args[3], &ww);
    if (argc >= 5) napi_get_value_int32(env, args[4], &cap);
    return StrToJs(env, pdfc_search(doc, reinterpret_cast<const uint8_t*>(needle.data()),
                                    slen, cs, ww, cap));
}

// Read a JS string as UTF-8. Returns false when the value is not a string.
bool GetUtf8(napi_env env, napi_value value, std::string& out) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) return false;
    out.assign(len + 1, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, out.data(), out.size(), &written) != napi_ok) return false;
    out.resize(written);
    return true;
}

// Copy a Rust-owned raw byte buffer (PdfcPage / PdfcStr layout) into a JS ArrayBuffer.
// Returns null and frees the Rust buffer on failure.
napi_value BytesToJs(napi_env env, uint8_t* data, uint64_t len) {
    if (data == nullptr || len == 0) return MakeNull(env);
    void* dst = nullptr;
    napi_value buf;
    if (napi_create_arraybuffer(env, static_cast<size_t>(len), &dst, &buf) != napi_ok) {
        return MakeNull(env);
    }
    std::memcpy(dst, data, static_cast<size_t>(len));
    return buf;
}

// editOpen(ArrayBuffer, password?) -> BigInt handle | null
napi_value JsEditOpen(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc < 1) {
        return MakeNull(env);
    }
    void* raw = nullptr;
    size_t len = 0;
    if (napi_get_arraybuffer_info(env, args[0], &raw, &len) != napi_ok) return MakeNull(env);

    std::string pw;
    const uint8_t* pw_ptr = nullptr;
    size_t pw_len = 0;
    if (argc >= 2) {
        napi_valuetype t = napi_undefined;
        napi_typeof(env, args[1], &t);
        if (t == napi_string && GetUtf8(env, args[1], pw)) {
            pw_ptr = reinterpret_cast<const uint8_t*>(pw.data());
            pw_len = pw.size();
        }
    }
    void* editor = pdfc_edit_open(static_cast<const uint8_t*>(raw), len, pw_ptr, pw_len);
    if (editor == nullptr) return MakeNull(env);
    napi_value result;
    napi_create_bigint_uint64(env, static_cast<uint64_t>(reinterpret_cast<uintptr_t>(editor)), &result);
    return result;
}

// editClose(handle)
napi_value JsEditClose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* editor = nullptr;
    if (argc >= 1 && GetHandle(env, args[0], editor)) pdfc_edit_close(editor);
    return MakeUndefined(env);
}

// editState(handle) -> string(JSON)
napi_value JsEditState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* editor = nullptr;
    if (argc < 1 || !GetHandle(env, args[0], editor)) return StrToJs(env, empty_pdfc_str());
    return StrToJs(env, pdfc_edit_state(editor));
}

// editCommand(handle, commandJson) -> string(JSON)
napi_value JsEditCommand(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* editor = nullptr;
    std::string cmd;
    if (argc < 2 || !GetHandle(env, args[0], editor) || !GetUtf8(env, args[1], cmd)) {
        return StrToJs(env, empty_pdfc_str());
    }
    return StrToJs(env, pdfc_edit_command(editor,
        reinterpret_cast<const uint8_t*>(cmd.data()), cmd.size()));
}

// editUndo(handle) / editRedo(handle) -> string(JSON)
napi_value JsEditUndo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* editor = nullptr;
    if (argc < 1 || !GetHandle(env, args[0], editor)) return StrToJs(env, empty_pdfc_str());
    return StrToJs(env, pdfc_edit_undo(editor));
}

napi_value JsEditRedo(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* editor = nullptr;
    if (argc < 1 || !GetHandle(env, args[0], editor)) return StrToJs(env, empty_pdfc_str());
    return StrToJs(env, pdfc_edit_redo(editor));
}

// editSave(handle, full?) -> ArrayBuffer(PDF bytes) | null
napi_value JsEditSave(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* editor = nullptr;
    if (argc < 1 || !GetHandle(env, args[0], editor)) return MakeNull(env);
    bool full = true;
    if (argc >= 2) napi_get_value_bool(env, args[1], &full);
    PdfcPage rp = pdfc_edit_save(editor, full);
    napi_value out = BytesToJs(env, rp.data, rp.len);
    if (rp.data != nullptr) pdfc_free(rp);
    return out;
}

// close(handle)
napi_value JsClose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    void* doc = nullptr;
    if (argc >= 1 && GetHandle(env, args[0], doc)) {
        pdfc_close(doc);
    }
    return MakeUndefined(env);
}

} // namespace

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"open", nullptr, JsOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"needsPassword", nullptr, JsNeedsPassword, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pageCount", nullptr, JsPageCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"renderPage", nullptr, JsRenderPage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"metadata", nullptr, JsMetadata, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"outline", nullptr, JsOutline, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"search", nullptr, JsSearch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, JsClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        // Editing session (pure-Rust editing crates).
        {"editOpen", nullptr, JsEditOpen, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"editClose", nullptr, JsEditClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"editState", nullptr, JsEditState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"editCommand", nullptr, JsEditCommand, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"editUndo", nullptr, JsEditUndo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"editRedo", nullptr, JsEditRedo, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"editSave", nullptr, JsEditSave, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry", // 必须与 .so 基名一致（libentry.so → entry），否则 ArkTS 按名查找会落空
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterPdfCraftModule(void) {
    napi_module_register(&g_module);
}
