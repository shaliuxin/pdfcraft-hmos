# PdfCraft 鸿蒙移植说明

> 纯 Rust PDF 阅读器 `storytoled/pdfcraft` → HarmonyOS。架构复刻 RustDesk 成功路径：
> Rust `staticlib`（双架构）→ C++ N-API（`libentry.so`）→ ArkTS 阅读器 UI → hvigor 打包 → 签名 HAP。

## 包名铁律（本项目专属包名）
- **本项目 bundleName = `cn.shaliuxin.pdfcraft`**（独立，不复用 RustDesk 的 `cn.shaliuxin.remotedesk`）。
- 原因：`.p7b` 签名 Profile 绑定 bundleName + 设备 UDID，复用旧包名会与已装旧 App 撞车
  （真机 `9568263 版本降级` / 覆盖旧 App），且包名上架后永久不可改。
- **要出可装 HAP**：`AppScope/app.json5` 已是 `cn.shaliuxin.pdfcraft`；在 DevEco「File → Project Structure →
  Signing Configs」用该新包名做一次自动签名（生成绑定此包名的专属 Profile，回写 `build-profile.json5`），
  再 `bash scripts/ohos/build-hap.sh hap` 即可。
- 现状：`~/.ohos/config` 里尚无绑定 `cn.shaliuxin.pdfcraft` 的调试 Profile，所以直接 `build-hap.sh`
  会卡在建签步骤，属预期。之前临时用 `cn.shaliuxin.remotedesk` 出的 HAP 只是验证用的旁路产物。

## 应用图标
- 用 pdfcraft 官方图标 `assets/app-icon/pdfcraft-1024.png`（红底狮子吉祥物）缩放到 512×512，
  替换 `AppScope/resources/base/media/app_icon.png` 与 `entry/src/main/resources/base/media/app_icon.png`
  （不要用旧项目 RustDesk 的图标）。

## 关键实现点
- Rust C-ABI 桥：`crates/ohos`（name=`pdfcraft-ohos`），导出 `pdfc_open/close/page_count/render_page/free`，
  渲染返回 RGBA8888。
- OHOS NAPI 签名与 Node.js 不同（见 `napi_bridge.cpp` 内注释）：
  - `napi_create_arraybuffer(env, len, void** data, napi_value* result)` —— data 在前。
  - `napi_set_property` 的 key 需先用 `napi_create_string_utf8` 造。
  - `napi_get_cb_info` 第 5 参是 `napi_value*`（传 nullptr）。
- CMake 需补链 `libtime_service_ndk.so`（`OH_TimeService_GetTimeZone`，time/chrono 引入）。
- 双架构：`aarch64-unknown-linux-ohos` + `x86_64-unknown-linux-ohos`。

## 构建
```bash
bash scripts/ohos/build-core.sh debug              # 编 aarch64 核心库
OHOS_TARGET=x86_64-unknown-linux-ohos bash scripts/ohos/build-core.sh debug   # 编 x86_64
bash scripts/ohos/build-hap.sh hap                 # 打包 + 签名（需先有匹配包名的 Profile）
```

## 编辑功能移植（2026-11-07）

### 为什么不用 `pdfcraft-engine`
桌面版编辑会话在 `crates/engine/src/session/`（`Session::apply(id, Edit)`，`Edit` 枚举约 90 个变体），
看似最省事，但 **实测无法为 OHOS 交叉编译**：依赖链
`pdfcraft-engine → pdfcraft-print → winprint → sigstore → reqwest → rustls → aws-lc-sys`，
`aws-lc-sys` 的 build.rs 用 CMake + 宿主 `C:/Strawberry/c/bin/gcc.exe`，
不认 `--target=aarch64-linux-ohos --sysroot=...`，报
`gcc.exe: error: unrecognized command-line option '--target=...'`（`aws-lc-sys` 实测日志）。
此外还拖着 boa JS 引擎、rten OCR 模型、reqwest 网络栈，对移动端无意义。

### 实际采用的方案
直接驱动**纯 Rust、零 C 依赖**的六个 crate（已实测可为 `aarch64`/`x86_64-unknown-linux-ohos` 编译）：

| crate | 用途 |
|---|---|
| `pdfcraft-cos` | `Document::open_with_password` / `write_full` / `write_incremental` / `set_encryption` / `remove_encryption` |
| `pdfcraft-organize` | 旋转/删除/移动/反转/复制/插入空白页/抽取/set_info/书签/页码样式 |
| `pdfcraft-annot` | `add_annotation` / `delete_annotation` / `set_contents` / `add_reply` / `summaries` |
| `pdfcraft-forms` | `add_field` / `set_value` / `delete_field` / `reset` / `fields` |
| `pdfcraft-edit` | `add_content` / `delete_content` / `add_watermark` / `add_header_footer` / `remove_marks` |
| `serde_json` | 命令解析（纯 Rust） |

`cos::Document` 是 cheap clone（copy-on-write overlay），因此撤销栈直接存 `Document` 快照，
与 `engine::Session` 的做法一致。

### 架构
- `crates/ohos/src/edit.rs`：`PdfcEditor` + **统一 JSON 命令分发**（`pdfc_edit_command` 一个入口，
  `op` 字段分派 30+ 个操作，新增操作只需加一个 match arm，不必改 NAPI）。
- `pdfc_edit_open/close/state/command/undo/redo/save` 共 7 个导出；`save` 复用 `PdfcPage` 布局返回 PDF 字节。
- `napi_bridge.cpp` / `pdfc_ohos.h` / `index.d.ts` 同步暴露 `editOpen/editClose/editState/editCommand/editUndo/editRedo/editSave`。
- `Index.ets`：欢迎页 5 张工具卡由「敬请期待」改为真实入口；顶栏 ✎ 打开编辑抽屉；
  抽屉含 5 类工具分组、参数输入、撤销/重做/另存为；每条命令后 `editSave(false)` →
  `pdfc.open` 重建渲染句柄，立即预览修改结果。

### 关键 API 事实（源码核实，勿臆测）
- `Document::security()` 是**打开时**的加密处理器；`Document::output_handler()` 才是**下一次保存**会写入的保护。
  `encrypt`/`removeEncryption` 改的是后者，所以状态里的 `encrypted` 必须用 `output_handler().is_some()`。
- `LabelStyle` 变体是 `UpperRoman/LowerRoman/UpperAlpha/LowerAlpha/Decimal/None`；
  `number_pages(doc, from, to, style, prefix, first)` 是 6 个位置参数，不是 `LabelRange` 数组。
- `annot::Summary` 字段是 `subtype`/`contents: Option<String>`/`index`，没有 `kind`。
- `HeaderFooter::text` 是 `[String; 6]`；`add_header_footer` 需要 `Context { date }`。
- `NewEncryption.seed: [u8;32]` 由调用方提供随机源（ArkTS 用 `Math.random()` 生成），crate 本身不访问 OS。
- 加密变更后必须 `write_full`（`encryption_changed()`），增量保存非法。

### 验证
`cargo test -p pdfcraft-ohos --test bridge_host`（Windows 宿主机可直接跑）3 个测试全绿：
阅读层原有断言 + `edit_session_end_to_end`（组织页面/元数据/书签/撤销重做/批注/表单/文本/水印/页码样式/保存重开/未知 op/抽取）
+ `edit_encryption_round_trip`（AES-256 加密→无密码打不开→密码解锁→移除保护→免密打开）。

### 构建注意
`build-core.sh` 默认只编 `aarch64`；改了 Rust 层后**必须**再跑
`OHOS_TARGET=x86_64-unknown-linux-ohos bash scripts/ohos/build-core.sh`，
否则 hvigor 编 x86_64 的 `libentry.so` 会报 `undefined symbol: pdfc_edit_open`。

### 第二轮修复（2026-11-07，真机复验后）
- 编辑面板：弃用 `bindSheet` 抽屉（内容挤在下部），改全屏 `editPanel()`，
  结构为 顶栏 + 状态行 + 工具页签 + 单一滚动区（参数 + 2 列「全部功能」网格 + 结果）+ 固定底栏（撤销/重做/另存为）。
- 插入空白页：拆「当前页前 / 后」两个动作；`insert_blank_page` 的 `at` 为「插入到该下标之前」，
  前插 `at=curPage`、后插 `at=curPage+1`，插入后 `gotoPage=at` 跳到新页；尺寸跟随当前页。
- 补齐「列出字段」(`listFields`) 与添加批注入口（`addNote`/`addHighlight`/`addShape` 矩形/椭圆/直线）。
- 加密密码：保护页签专设 用户密码(必填)/确认/所有者(可空)，加密前校验非空且一致。
- 阅读侧加密打开：`pdfc_open_with_password` + `needsPassword` 弹框 + `submitPassword` 重试（Rust/C++/ArkTS 三处接好）。
- 双架构重建 + `build-hap.sh` 出 64MB signed HAP，`hdc install` → `install bundle successfully`。
