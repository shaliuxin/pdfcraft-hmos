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

---

## ⭐ OHOS 平台判定与资源探测必查（2026-11-11 全项目强制）

> 本节是**跨项目强制条款**，源自 PhotoCraft v0.22.0 的严重缺陷「打开照片报内存不足，只有很小的图片能打开」。
> 权威版见《craft-鸿蒙移植通用检查清单》文首 ⭐ 铁律与 §18。新项目开工、每次上游升级后必须逐项打勾。

**一眼判据**：编译、链接、启动全绿，只有稍大的数据失败，且报错里出现 `0.0 GB is free`、
`0 bytes available`、`0 cores`、`limit 0` 这类**零值** → 先怀疑「资源探测器读不到 → fail-closed 返回 0」，
不要当成真的资源不足，也不要先猜「文件太大 / ArkTS 缓存 / fd 读取」。

**根因**：OHOS triple（`*-unknown-linux-ohos`）仍报告 `target_os = "linux"`。上游凡靠
`#[cfg(target_os = "linux")]` 分派的 Linux 专属逻辑（cgroup / procfs / 内存探测 / 字体路径 / `dlopen` /
系统目录）在鸿蒙应用沙箱里都会被误用。PhotoCraft 的通用 Linux 探测器要求 cgroup v1 挂载带 `memory`
controller 名，而 OHOS 把 memory 控制器挂在 `/dev/memcg`、`mountinfo` 不含 controller 名，应用进程读
`/dev/memcg` 与 `/proc/<pid>/root/sys/fs/cgroup` 均为 `Permission denied`；探测器因此返回
`available_ram = Some(0)`，图片导入准入 `check_fits()` 把每张稍大的照片判成内存不足，真机报错原文是
`not enough memory to open this 6000 × 4000 px image: it needs about 0.1 GB and 0.0 GB is free`
（该设备 `/proc/meminfo` 实际有约 22.2 GiB 可用）。

**本项目自检清单（开工 / 每次上游升级后）**：
- [ ] `grep -rn 'target_os = "linux"\|cfg(unix)' <上游>/crates`，逐个判断平台假设在 OHOS 沙箱里是否成立；重点查「读取系统资源上限」类代码（内存、CPU、磁盘、cgroup、rlimit）。
- [ ] OHOS 专用分支只用 `#[cfg(target_env = "ohos")]`；真正的 Linux 分支写成 `#[cfg(all(target_os = "linux", not(target_env = "ohos")))]`，且 OHOS 交叉编译不得有该模块的 dead_code 警告。
- [ ] 探测器「测不到」必须返回 `UNKNOWN`（让上游走未知资源的保守策略），**绝不返回 `Some(0)`**。
- [ ] 只用沙箱真正可读的数据源（`/proc/meminfo` 的 `MemAvailable`），按单应用口径保守封顶；不要把整机 RAM 原样交给单个任务；由系统管理的 swap/zram 记 0。
- [ ] 平台修复做成独立 numbered patch + `target_env = "ohos"` 分支 + `#[cfg(any(target_env = "ohos", test))]` 的主机可跑纯函数单测，保证上游升级只冲突一个 hunk。
- [ ] 真机前后对照：构造「文件小、解码内存大」的样本，先在旧包复现报错，再 `hdc install -r -d` 覆盖安装验证；不能只跑 `cargo check` / 单测就宣布修好。

> 出处（MLA）：「⭐ OHOS 平台判定与资源探测铁律」与「§18. PhotoCraft 追加经验」，
> *craft-鸿蒙移植通用检查清单.md*, 本地工作区 `C:/Users/mingh/WorkBuddy/2026-11-01-23-18-01/`,
> 11 Nov. 2026. 修复实例见 PhotoCraft `patches/0005-ohos-memory.patch` 与
> `upstream/photocraft/crates/raster/src/memory/system.rs`。

---

## ⭐ 关窗保存确认必查（2026-11-11 全项目强制）

> 本节是**跨项目强制条款**，源自「点系统窗口 X / 返回手势不弹『是否保存』对话框、未保存改动静默丢失」
> 这一**数据丢失级缺陷**。权威版见《craft-鸿蒙移植通用检查清单》文首 ⭐ 关窗保存确认铁律（12 项）、
> §8、§15 / §15.1 / §15.2 与 §19 全项目落地登记。新项目从骨架阶段、每次上游升级后按序打勾。

**为什么最容易漏**：关闭链路跨 ArkTS 拦截层、Rust 逻辑相帧顺序、上游「允许关闭」信号三层，
任一层缺失都能编译通过、正常启动、hilog 甚至全绿，但点 X 就是不弹框。VectorCraft v0.23.0
连续修了两次才闭环——首版只接通道，用户复测仍是「直接关掉、不弹框」。

**现象 → 断点速判**：点 X 直接退出且无日志 → ArkTS 没订阅窗口级关窗事件；
拦到了却静默关窗 → Rust `tick` 在 `run_ui` pass 外 / 「无 CancelClose」被误判成「无未保存」；
弹框但选完保存或丢弃窗口不关 → 没锁存本上游的允许关闭信号；
框根本画不出来 → 关窗时窗口失焦、`active=false` 让 Frame 分支提前返回。

**本项目必查清单（骨架 → 交付，缺一项不算闭环）**：
- [ ] **1. 先查本上游用什么表达「可以关窗」，绝不照抄兄弟工程字段**：
      `grep -rn "close_requested\|allow_close\|quit_requested\|ui.status\|CancelClose\|quit_confirmed" <上游>/apps <上游>/crates`。
      GridCraft 用 `SheetApp::allow_close`；WordCraft 用 `close_requested()` + `quit_requested`；
      VectorCraft 没有 `allow_close`，靠 `unsaved::close_all(app, "quit")` 写 `app.ui.status = "quit"`；
      FilmCraft / DeckCraft 用 `intercept_quit()` 发 `CancelClose`，作答后 `quit_confirmed` + `Close`。
- [ ] **2. ArkTS 只订阅一个窗口级关窗事件**：`EntryAbility.onWindowStageCreate` 里
      `getMainWindowSync().on('windowWillClose', async (): Promise<boolean> => …)`。SDK 26 契约：
      `return true` = 拦截（窗口保留）、`false` / reject = 放行；写成同步 `(): boolean` 会报
      `10505001 No overload matches this call`。别同时注册 `windowStageClose` / `onPrepareToTerminate`
      （优先级冲突，见 §8）；WordCraft 的 `windowStageClose` 是另一套已验证写法，照抄前先核 SDK 声明。
- [ ] **3. 回调内直连、无条件拦截**：`native.close(); return true;`，**不要** `closeGuard.ets` 那种跨模块
      单例回调（多一层「两文件是否共享同一模块实例」的不确定性，见 §15.2）。Rust 确认后由页面
      `receive('close')` → `terminateSelf()`，该路径不会再触发 `windowWillClose`，无需「已确认放行」标志。
- [ ] **4. 返回手势也要消费**：`onBackPress()` 转发 Escape（键码 2070）并 `return true`，
      否则返回手势直接销毁页面，同样绕过未保存确认。
- [ ] **5. 头号根因：Rust `editor_frame` 把 `tick` / `finish_ime_logic` 放进 `ctx.run_ui` 的 pass 内、
      `ui()` 之前**，用 `current_pass_index() == 0` 防多 pass 重复。只要上游 logic 读 `ctx.input()`
      （`close_requested` / `focused` / zoom / viewport）就必须如此：pass 外只能读上一帧 input，
      `ViewportEvent::Close` 当帧不可见 → 上游不发 `CancelClose` → 宿主误判「无未保存」→ 静默关窗（§15.1）。
      对照物：eframe `App::logic`、web shell `logic`、GridCraft `editor_frame` 三者顺序一致。
- [ ] **6. 关窗判定不能反向推断**：`CancelClose` 优先暂缓（等用户作答）；**绝不**把「本帧没有
      `CancelClose`」当成「无未保存」直接 Confirm；锁存第 1 项查到的允许关闭信号后放行一次，
      加 `terminating` 防重复 `notify("close")`。用户点 Cancel 时上游不发信号、窗口自然保留。
- [ ] **7. 关窗期间强制出帧**：`Message::Close` 里 `active = true; bridge::resume()`，
      Frame / vsync 请求 / repaint 排帧的 active 判断在校验期间放行（`active || close`）。
      否则系统 X 先触发 `onBackground → active(false)`，保存框永远画不出来。
- [ ] **8. 三段诊断日志**：`system X forwarded` → `saveChanges pending, window kept` →
      `confirmed, notifying host`（Rust `bridge::notify(0,"diagnostic",…)` + ArkTS `console.info`），
      真机点一次 X 就能从 hilog 读出全链路，无需合成输入。
- [ ] **9. 构建与包内校验**：`cargo check` → 双 ABI release → `assembleHap` → 包内 ArkTS 字节码含
      `windowWillClose`、`.so` 含三段诊断文案 → `hdc install -r -d` 覆盖安装；别只改源码就宣布修好。
- [ ] **10. 真机三态人工验收不可省**：制造未保存改动 → 点 X → **亲眼看到**「是否保存」框；
      分别试 Save / Don't Save / Cancel，前两者应出现 `confirmed, notifying host` 且窗口关闭，Cancel 保留。
- [ ] **11. 验收判据写进移植报告**：`RegisterListener: [windowWillClose, 1]` 只证明**监听器注册**，
      **不等于修好**；必须有用户真机点 X 的实证日志 / 截图才算闭环。VectorCraft 首版正是栽在这里。
- [ ] **12. 多窗口 2-in-1 设备不发合成点击**：合成点击会被误路由并改动邻窗
      （VectorCraft 曾在 GridCraft 单元格误写 `7`），此项一律请用户手点。

> **升级 / 回归**：上游大版本升级可能改宿主帧顺序或允许关闭字段名，按第 1、5、6 项重新 `grep`，
> 再跑一次第 10 项三态验收。
>
> 出处（MLA）：「⭐ 关窗保存确认铁律」与「§15. 关窗保存守卫」，
> *craft-鸿蒙移植通用检查清单.md*, 本地工作区 `C:/Users/mingh/WorkBuddy/2026-11-01-23-18-01/`,
> 10–11 Nov. 2026.
