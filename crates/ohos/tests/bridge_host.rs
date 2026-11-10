//! 宿主机端到端测试：不经 NAPI / 不上设备，直接驱动 C-ABI 桥接的每个导出函数，
//! 验证 open / page_count / render_page / metadata / outline / search 的真实输出。
//! 构造的样张：2 页（第 1 页有 "Hello World" 文本），带 1 条书签和 Info 元数据。

use pdfcraft_ohos::{
    pdfc_close, pdfc_edit_close, pdfc_edit_command, pdfc_edit_open, pdfc_edit_redo, pdfc_edit_save,
    pdfc_edit_state, pdfc_edit_undo, pdfc_free, pdfc_free_str, pdfc_metadata, pdfc_open,
    pdfc_open_with_password, pdfc_outline, pdfc_page_count, pdfc_render_page, pdfc_search, PdfcPage,
    PdfcStr,
};

/// 与 `Index.ets` + `napi_bridge.cpp` 的调用方式保持一致（空输入 → null，宽容解析无 xref）。
fn build_doc() -> Vec<u8> {
    let mut v: Vec<u8> = Vec::new();
    v.extend_from_slice(b"%PDF-1.4\n");
    v.extend_from_slice(b"1 0 obj << /Type /Catalog /Pages 2 0 R /Outlines 10 0 R >> endobj\n");
    v.extend_from_slice(b"2 0 obj << /Type /Pages /Kids [3 0 R 8 0 R] /Count 2 >> endobj\n");
    v.extend_from_slice(
        b"3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] \
/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >> endobj\n",
    );
    // stream 内容必须与 /Length 43 完全一致
    v.extend_from_slice(b"4 0 obj << /Length 43 >> stream\n");
    v.extend_from_slice(b"BT /F1 24 Tf 72 700 Td (Hello World) Tj ET\n");
    v.extend_from_slice(b"endstream endobj\n");
    v.extend_from_slice(b"5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n");
    v.extend_from_slice(b"8 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >> endobj\n");
    v.extend_from_slice(b"10 0 obj << /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >> endobj\n");
    v.extend_from_slice(b"11 0 obj << /Title (Part One) /Parent 10 0 R /Dest [3 0 R /Fit] >> endobj\n");
    v.extend_from_slice(b"20 0 obj << /Title (Test Doc) /Author (Shal) >> endobj\n");
    v.extend_from_slice(b"trailer << /Root 1 0 R /Info 20 0 R >>\n");
    v.extend_from_slice(b"%%EOF");
    v
}

fn take_json(s: PdfcStr) -> String {
    assert!(
        !s.data.is_null() && s.len > 0,
        "桥接返回了空字符串（open 失败或字段为空）"
    );
    let bytes = unsafe { std::slice::from_raw_parts(s.data, s.len as usize) };
    let text = String::from_utf8(bytes.to_vec()).expect("JSON 应为合法 UTF-8");
    pdfc_free_str(s);
    text
}

/// 从 `"rects":[[x0,y0,x1,y1]` 提取第一个矩形。
fn first_rect(json: &str) -> [f64; 4] {
    let start = json
        .find("\"rects\":[[")
        .expect("JSON 里应有 rects")
        + "\"rects\":[[".len();
    let rest = &json[start..];
    let end = rest.find(']').expect("rect 应有右括号");
    let nums: Vec<f64> = rest[..end]
        .split(',')
        .map(|p| p.trim().parse().expect("rect 坐标应为数字"))
        .collect();
    assert!(nums.len() >= 4, "rect 应有 4 个坐标，实际 {:?}", nums);
    [nums[0], nums[1], nums[2], nums[3]]
}

#[test]
fn bridge_end_to_end() {
    let bytes = build_doc();

    // ---- open：空输入必须返回 null，不崩溃 ----
    let empty = pdfc_open(std::ptr::null(), 0);
    assert!(empty.is_null(), "空输入应返回 null 句柄");

    // ---- open + page_count ----
    let doc = pdfc_open(bytes.as_ptr(), bytes.len());
    assert!(!doc.is_null(), "合法 PDF 应打开成功");
    assert_eq!(pdfc_page_count(doc), 2, "样张应有 2 页");

    // ---- render_page：几何应正确（scale=2.0 → 612*2 × 792*2，RGBA8888）----
    let page = pdfc_render_page(doc, 0, 2.0);
    assert_eq!(page.width, 1224, "渲染宽 = 612 点 × 2.0");
    assert_eq!(page.height, 1584, "渲染高 = 792 点 × 2.0");
    assert_eq!(page.len, (page.width as u64) * (page.height as u64) * 4);
    assert!(!page.data.is_null(), "渲染缓冲不应为空");
    pdfc_free(page);

    // 越界页码应返回空页而不是崩溃
    let bad = pdfc_render_page(doc, 99, 2.0);
    assert_eq!(bad.width, 0, "越界页应渲染失败（宽 0）");
    pdfc_free(bad);

    // ---- metadata：标题/作者/页数/页尺寸 ----
    let meta = take_json(pdfc_metadata(doc));
    assert!(meta.contains("\"title\":\"Test Doc\""), "metadata 缺标题：{meta}");
    assert!(meta.contains("\"author\":\"Shal\""), "metadata 缺作者：{meta}");
    assert!(meta.contains("\"pages\":2"), "metadata 页数错误：{meta}");
    assert!(
        meta.contains("\"pageSize\":[[612,792,"),
        "metadata 页尺寸错误（应为 612×792 点）：{meta}"
    );
    assert!(meta.contains("\"pdfVersion\":\"1.4\""), "metadata 缺 PDF 版本：{meta}");

    // ---- outline：书签标题 + 目标页 ----
    let outline = take_json(pdfc_outline(doc));
    assert!(
        outline.contains("\"title\":\"Part One\""),
        "outline 缺书签标题：{outline}"
    );
    assert!(outline.contains("\"page\":0"), "书签目标页应为 0 基第 1 页：{outline}");

    // ---- search：命中数 / 目标页 / 矩形在页内且方向正确（左上原点 y 向下）----
    let needle = b"Hello";
    let hits = take_json(pdfc_search(doc, needle.as_ptr(), needle.len(), false, false, 2048));
    assert!(hits.contains("\"total\":1"), "应恰好命中 1 次：{hits}");
    assert!(hits.contains("\"page\":0"), "命中应落在第 0 页：{hits}");
    assert!(hits.contains("\"count\":1"), "第 0 页应命中 1 次：{hits}");
    let r = first_rect(&hits);
    assert!(
        r[0] >= 0.0 && r[2] <= 612.0 && r[3] <= 792.0,
        "命中矩形必须在页内（0..612 × 0..792）：{r:?}"
    );
    assert!(r[1] < r[3], "矩形 y0 必须小于 y1（y 向下）：{r:?}");
    // 文本在 PDF 空间 baseline y=700（底部起算）→ 顶部起算 ≈ 792-700≈92 附近，断言在上半页
    assert!(
        r[1] < 400.0,
        "命中矩形应在页面上半部（顶部原点 y 向下坐标系），实际 y0={}",
        r[1]
    );

    // ---- search：大小写默认不敏感 + 无命中 ----
    let hits_ci = take_json(pdfc_search(doc, b"hello".as_ptr(), 5, false, false, 2048));
    assert!(hits_ci.contains("\"total\":1"), "默认应大小写不敏感：{hits_ci}");
    let misses = take_json(pdfc_search(doc, b"zzzz".as_ptr(), 4, false, false, 2048));
    assert!(misses.contains("\"total\":0"), "无命中应返回 total 0：{misses}");

    // ---- search：空词防护（按文档约定返回空字符串，ArkTS 侧调用前已拦截空词）----
    let blank = pdfc_search(doc, b"".as_ptr(), 0, false, false, 2048);
    assert!(blank.data.is_null(), "空词应返回空字符串而不是崩溃");

    pdfc_close(doc);
}

// ---------------------------------------------------------------------------
// 编辑会话端到端：真实驱动 cos/organize/annot/forms/edit，验证「打开→编辑→
// 撤销/重做→保存字节→重新打开校验」整条闭环，以及加密/解密。
// ---------------------------------------------------------------------------

fn edit_cmd(editor: *mut pdfcraft_ohos::PdfcEditor, cmd: &str) -> String {
    let s = pdfc_edit_command(editor, cmd.as_ptr(), cmd.len());
    assert!(!s.data.is_null(), "edit_command 返回空: {cmd}");
    let bytes = unsafe { std::slice::from_raw_parts(s.data, s.len as usize) };
    let text = String::from_utf8(bytes.to_vec()).expect("命令结果应为 UTF-8 JSON");
    pdfc_free_str(s);
    text
}

fn state(editor: *mut pdfcraft_ohos::PdfcEditor) -> String {
    let s = pdfc_edit_state(editor);
    assert!(!s.data.is_null(), "edit_state 返回空");
    let bytes = unsafe { std::slice::from_raw_parts(s.data, s.len as usize) };
    let text = String::from_utf8(bytes.to_vec()).expect("state 应为 UTF-8 JSON");
    pdfc_free_str(s);
    text
}

fn pages_of(editor: *mut pdfcraft_ohos::PdfcEditor) -> i64 {
    let st = state(editor);
    let v: serde_json::Value = serde_json::from_str(&st).unwrap();
    v["pages"].as_i64().unwrap()
}

fn cmd_ok(editor: *mut pdfcraft_ohos::PdfcEditor, cmd: &str) {
    let out = edit_cmd(editor, cmd);
    let v: serde_json::Value = serde_json::from_str(&out).unwrap();
    assert!(v["ok"] == true, "命令应成功: {cmd} => {out}");
}

fn saved_bytes(editor: *mut pdfcraft_ohos::PdfcEditor, full: bool) -> Vec<u8> {
    let p: PdfcPage = pdfc_edit_save(editor, full);
    assert!(!p.data.is_null() && p.len > 0, "edit_save 应返回 PDF 字节");
    assert_eq!(p.width, 0, "save 返回的 width 应为 0（非图像）");
    let bytes = unsafe { std::slice::from_raw_parts(p.data, p.len as usize).to_vec() };
    pdfc_free(p);
    bytes
}

#[test]
fn edit_session_end_to_end() {
    let bytes = build_doc();

    // 空输入 / 错误句柄防护
    assert!(pdfc_edit_open(std::ptr::null(), 0, std::ptr::null(), 0).is_null());

    let ed = pdfc_edit_open(bytes.as_ptr(), bytes.len(), std::ptr::null(), 0);
    assert!(!ed.is_null(), "合法 PDF 应能打开编辑会话");
    assert_eq!(pages_of(ed), 2, "初始应有 2 页");
    assert!(state(ed).contains("\"dirty\":false"), "新会话应为干净状态");

    // ---- 组织页面：旋转 / 插入空白页 / 删除 / 复制 ----
    cmd_ok(ed, r#"{"op":"rotate","pages":[0],"degrees":90}"#);
    assert!(state(ed).contains("\"rotations\":[90,0]"), "第 1 页应旋转 90°：{}", state(ed));

    cmd_ok(ed, r#"{"op":"insertBlank","at":1,"width":612,"height":792}"#);
    assert_eq!(pages_of(ed), 3, "插入空白页后应有 3 页");
    cmd_ok(ed, r#"{"op":"duplicatePages","pages":[0],"at":null}"#);
    assert_eq!(pages_of(ed), 4, "复制页后应有 4 页");
    cmd_ok(ed, r#"{"op":"deletePages","pages":[1]}"#);
    assert_eq!(pages_of(ed), 3, "删除页后应有 3 页");
    cmd_ok(ed, r#"{"op":"movePages","pages":[0],"to":2}"#);
    assert_eq!(pages_of(ed), 3, "移动页不改变页数");

    // ---- 元数据 / 书签 ----
    cmd_ok(ed, r#"{"op":"setInfo","key":"Title","value":"Edited Doc"}"#);
    assert!(state(ed).contains("\"title\":\"Edited Doc\""), "标题应已修改：{}", state(ed));
    cmd_ok(ed, r#"{"op":"addBookmark","title":"Chapter 1","page":0}"#);

    // ---- 撤销 / 重做 ----
    let before = pages_of(ed);
    cmd_ok(ed, r#"{"op":"insertBlank","at":0,"width":300,"height":400}"#);
    assert_eq!(pages_of(ed), before + 1);
    let ujson = {
        let s = pdfc_edit_undo(ed);
        let b = unsafe { std::slice::from_raw_parts(s.data, s.len as usize).to_vec() };
        pdfc_free_str(s);
        String::from_utf8(b).unwrap()
    };
    assert!(ujson.contains("\"ok\":true"), "撤销应成功：{ujson}");
    assert_eq!(pages_of(ed), before, "撤销后页数应还原");
    let rjson = {
        let s = pdfc_edit_redo(ed);
        let b = unsafe { std::slice::from_raw_parts(s.data, s.len as usize).to_vec() };
        pdfc_free_str(s);
        String::from_utf8(b).unwrap()
    };
    assert!(rjson.contains("\"ok\":true"), "重做应成功：{rjson}");
    assert_eq!(pages_of(ed), before + 1, "重做后页数应恢复");
    pdfc_free_str(pdfc_edit_undo(ed)); // 回到插入前

    // ---- 批注 / 表单 / 编辑内容：真实写入 ----
    cmd_ok(ed, r#"{"op":"addNote","page":0,"at":[100,100],"text":"A note","author":"Tester"}"#);
    cmd_ok(ed, r#"{"op":"addShape","page":0,"shape":"rectangle","rect":[80,80,200,140],"text":"box"}"#);
    // 「列出本页批注」必须真的列出刚添加的批注，而不是只返回 ok。
    let anns = edit_cmd(ed, r#"{"op":"listAnnotations","page":0}"#);
    assert!(anns.contains("\"annotations\":[{") && anns.contains("A note"),
        "列出本页批注应返回刚添加的便签：{anns}");
    cmd_ok(ed, r#"{"op":"addField","page":0,"rect":[72,72,240,96],"kind":"text","name":"Field1"}"#);
    cmd_ok(ed, r#"{"op":"setFieldValue","name":"Field1","value":"filled"}"#);
    // 「列出字段」必须真的列出刚添加的字段。
    let flds = edit_cmd(ed, r#"{"op":"listFields"}"#);
    assert!(flds.contains("\"fields\":[{") && flds.contains("Field1"),
        "列出字段应返回刚添加的字段：{flds}");
    cmd_ok(ed, r#"{"op":"addText","page":0,"rect":[72,600,300,640],"text":"Added text","size":14}"#);
    cmd_ok(ed, r#"{"op":"addWatermark","text":"DRAFT","opacity":0.3}"#);
    cmd_ok(ed, r#"{"op":"numberPages","start":0,"to":2,"style":"romanLower","prefix":"","first":1}"#);

    // ---- 保存字节 → 必须是可重新打开的 PDF ----
    let out = saved_bytes(ed, true);
    assert!(out.starts_with(b"%PDF-"), "保存结果应以 %PDF- 开头");
    let reopened = pdfc_open(out.as_ptr(), out.len());
    assert!(!reopened.is_null(), "保存的字节必须能被渲染层重新打开");
    assert_eq!(pdfc_page_count(reopened), pages_of(ed) as i64, "重新打开后页数应一致");
    pdfc_close(reopened);

    // ---- 未知 op 应失败且不留副作用 ----
    let bad = edit_cmd(ed, r#"{"op":"noSuchOp"}"#);
    assert!(bad.contains("\"ok\":false"), "未知命令应返回失败：{bad}");
    assert!(bad.contains("unknown op"), "错误信息应说明原因：{bad}");

    // ---- 抽取页面：只保留指定页 ----
    cmd_ok(ed, r#"{"op":"extractPages","pages":[0,1]}"#);
    assert_eq!(pages_of(ed), 2, "抽取 2 页后应只剩 2 页");
    let out2 = saved_bytes(ed, true);
    let r2 = pdfc_open(out2.as_ptr(), out2.len());
    assert_eq!(pdfc_page_count(r2), 2, "抽取后保存的文件应能打开且为 2 页");
    pdfc_close(r2);
    pdfc_edit_close(ed);
}

#[test]
fn insert_blank_page_respects_insertion_index() {
    // 回归：UI 之前把所有空白页都塞到第一页后面。insert_blank_page 的 `at` 是
    // 「插入到该下标之前」的 0 基位置，at=0 应把原第 1 页推到第 2 页。
    let bytes = build_doc();
    let ed = pdfc_edit_open(bytes.as_ptr(), bytes.len(), std::ptr::null(), 0);
    assert!(!ed.is_null());
    cmd_ok(ed, r#"{"op":"insertBlank","at":0,"width":612,"height":792}"#);
    assert_eq!(pages_of(ed), 3);
    let out = saved_bytes(ed, true);
    let doc = pdfc_open(out.as_ptr(), out.len());
    assert_eq!(pdfc_page_count(doc), 3);
    let hits = take_json(pdfc_search(doc, b"Hello".as_ptr(), 5, false, false, 2048));
    assert!(hits.contains("\"page\":1"), "插入到最前时，原第 1 页应变成第 2 页：{hits}");
    pdfc_close(doc);
    pdfc_edit_close(ed);

    // at=2（末尾追加）不应移动原第 1 页。
    let ed2 = pdfc_edit_open(bytes.as_ptr(), bytes.len(), std::ptr::null(), 0);
    cmd_ok(ed2, r#"{"op":"insertBlank","at":2,"width":612,"height":792}"#);
    let out2 = saved_bytes(ed2, true);
    let doc2 = pdfc_open(out2.as_ptr(), out2.len());
    let hits2 = take_json(pdfc_search(doc2, b"Hello".as_ptr(), 5, false, false, 2048));
    assert!(hits2.contains("\"page\":0"), "追加到末尾时原第 1 页不动：{hits2}");
    pdfc_close(doc2);
    pdfc_edit_close(ed2);
}

#[test]
fn edit_encryption_round_trip() {
    let bytes = build_doc();
    let ed = pdfc_edit_open(bytes.as_ptr(), bytes.len(), std::ptr::null(), 0);
    assert!(!ed.is_null());

    let seed: Vec<u8> = (0..32u8).collect();
    let seed_json = serde_json::to_string(&seed).unwrap();
    let cmd = format!(
        r#"{{"op":"encrypt","algorithm":"aes256","userPassword":"user123","ownerPassword":"owner456","permissions":-1,"encryptMetadata":true,"seed":{}}}"#,
        seed_json
    );
    cmd_ok(ed, &cmd);
    assert!(state(ed).contains("\"encrypted\":true"), "加密后状态应为 encrypted：{}", state(ed));

    let encrypted = saved_bytes(ed, true);
    assert!(encrypted.starts_with(b"%PDF-"), "加密后的文件仍是 PDF");

    // 无密码打开应失败，带正确密码应成功。
    assert!(
        pdfc_edit_open(encrypted.as_ptr(), encrypted.len(), std::ptr::null(), 0).is_null(),
        "加密文档无密码不应能打开"
    );
    let pw = b"user123";
    let unlocked = pdfc_edit_open(encrypted.as_ptr(), encrypted.len(), pw.as_ptr(), pw.len());
    assert!(!unlocked.is_null(), "用用户密码应能打开加密文档");
    assert_eq!(pages_of(unlocked), 2, "解锁后页数应正确");

    // ---- 阅读层也必须能用密码打开加密文件（否则「加密后另存」的文件在本 App 里打不开）----
    let locked_reader = pdfc_open(encrypted.as_ptr(), encrypted.len());
    assert!(!locked_reader.is_null(), "open 对加密文件仍返回句柄（宽容解析）");
    assert_eq!(pdfc_page_count(locked_reader), 0, "无密码时阅读层应读不出页面");
    pdfc_close(locked_reader);

    let reader = pdfc_open_with_password(
        encrypted.as_ptr(),
        encrypted.len(),
        pw.as_ptr(),
        pw.len(),
    );
    assert!(!reader.is_null(), "带密码的 open 应返回句柄");
    assert_eq!(pdfc_page_count(reader), 2, "带密码的阅读层应读到 2 页");
    let raster = pdfc_render_page(reader, 0, 1.0);
    assert!(raster.width > 0 && raster.height > 0, "带密码的阅读层应能渲染页面");
    pdfc_free(raster);
    let md = take_json(pdfc_metadata(reader));
    assert!(md.contains("\"encrypted\":true"), "带密码读取的属性应标记加密：{md}");
    pdfc_close(reader);

    // 解密后无需密码即可打开。
    cmd_ok(unlocked, r#"{"op":"removeEncryption"}"#);
    let plain = saved_bytes(unlocked, true);
    let re = pdfc_edit_open(plain.as_ptr(), plain.len(), std::ptr::null(), 0);
    assert!(!re.is_null(), "移除保护后应无需密码即可打开");
    pdfc_edit_close(re);
    pdfc_edit_close(unlocked);
    pdfc_edit_close(ed);
}
