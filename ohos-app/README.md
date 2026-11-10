# RustDesk for HarmonyOS —— DevEco 工程

这是鸿蒙侧的**壳**：ArkTS 界面 + C++ 胶水层，真正的 RustDesk 核心是仓库根目录
那个 Rust 工程编译出来的 `liblibrustdesk.a`。

```
ohos-app/
├── entry/src/main/
│   ├── cpp/
│   │   ├── CMakeLists.txt      链 librustdesk.a + 系统库
│   │   ├── ohos_abi.cpp        实现 Rust 需要的 19 个 ohos_*（hilog/display/deviceinfo…）
│   │   ├── napi_bridge.cpp     napi 导出 + 事件派发（threadsafe function）
│   │   ├── renderer.cpp        XComponent Surface 渲染循环（帧直写，不过 ArkTS）
│   │   └── types/libentry/     index.d.ts，ArkTS 侧的类型契约
│   ├── ets/
│   │   ├── common/RustDesk.ets napi 封装 + 事件总线
│   │   ├── common/KeyMap.ets   KeyCode → RustDesk 的 VK_* 键名
│   │   ├── pages/Index.ets     连接页
│   │   └── pages/SessionPage.ets 会话页（XComponent + 手势）
│   └── module.json5
└── build-profile.json5
```

C ABI 契约在 **`../ohos/include/rustdesk_ohos.h`**（Rust 与 C++ 共用同一份，
不要在这里复制第二份）。

## 数据流

```
              ┌──────────── 视频 ────────────┐
Rust video_service ──on_rgba(mem::swap)──▶ 帧槽
                                            │
                    renderer.cpp 线程 ──acquire/mmap/memcpy/flush──▶ XComponent Surface
                                            │
                                        release（背压：不 release 画面就停）

              ┌──────────── 输入 ────────────┐
ArkTS 手势/键盘 ──napi──▶ rustdesk_ohos_mouse/_key ──▶ io_loop ──▶ 远端

              ┌──────────── 状态 ────────────┐
Rust ui_handler ──JSON──▶ ohos_ui_event ──tsfn──▶ ArkTS onEvent
```

**帧为什么不过 ArkTS**：1080p 一帧 8MB，走 napi 传 ArrayBuffer 每帧一次跨语言
拷贝，30fps 就是 250MB/s，手机上直接卡死。所以 C++ 自己从帧槽取、自己写 Surface。

**事件为什么只有一条通道**：Rust 的 `InvokeUiSession` 有 48 个方法，一个方法一个
回调就要 48 个 threadsafe function 和 48 个上下文对象。统一成
`{"event":..,"data":..}` 后，C++ 只需要一次线程切换。

## 构建

### 前置

| 项 | 要求 |
|---|---|
| DevEco Studio | 5.0 及以上（工程按 API 12 语法写，本机验证用 API 26 SDK） |
| SDK | `C:/ohos-sdk/default/openharmony/native`（或你自己装的路径） |
| Rust | `rustup target add aarch64-unknown-linux-ohos` |
| 签名 | 必须配，否则装不上真机 |

### 第一步：编 Rust 静态库

```bash
bash scripts/ohos/build-core.sh release
# 产物：target/aarch64-unknown-linux-ohos/release/liblibrustdesk.a
```

**必须用 release**。debug 的 `.a` 有 648MB，DevEco 链接时会吃掉几个 G 内存，
基本必失败。

脚本还会顺带做两件事：施加 `apply-mobile-cfg.py` 的 cfg 补丁（Tier-2，不提交）、
准备 libsodium 的宿主/目标双份链接目录。

### 第二步：打开工程

DevEco Studio → `File > Open` → 选 `ohos-app/` 目录。

首次打开有两处要按你本机情况改：

1. **`build-profile.json5` 的 SDK 版本**
   ```json5
   "compatibleSdkVersion": "6.0.0(26)",   // ← 改成你装的版本，例如 "5.0.5(17)"
   "targetSdkVersion": "6.0.0(26)",
   ```

2. **Rust 库路径**（一般不用改）
   CMakeLists 会按 `../../../../..` 反推出仓库根，再用
   `target/aarch64-unknown-linux-ohos/{release|debug}/liblibrustdesk.a`。
   如果你的产物在别处，加一行：
   ```json5
   "buildOption": {
     "externalNativeOptions": {
       "arguments": "-DRUSTDESK_LIB=/abs/path/liblibrustdesk.a"
     }
   }
   ```

### 第三步：配签名

`File > Project Structure > Signing Configs` → 勾 `Automatically generate signature`。
需要登录华为账号。

### 第四步：跑

连真机 → Run。日志过滤 `RustDesk`：

```bash
hdc shell hilog -T RustDesk
hdc shell hilog -T RustDeskNapi
hdc shell hilog -T RustDeskRender
```

按这个顺序出现说明链路通了：

```
RustDeskNapi: XComponent registered
RustDesk: 设备形态 / core initialized, abi=1     ← ArkTS 侧
RustDeskRender: surface created 1080x2340
RustDeskRender: render loop enter
```

## 当前边界（M1）

已经通了：

- 主控连接（`session_start` → `io_loop` → 解码 → 出画面）
- 触摸手势 → 鼠标（单击 / 拖动 / 长按右键 / 双指滚轮）
- 物理键盘 → VK 键名（2in1 或接外接键盘）
- 状态事件（connected / close / display / block_input）

明确**没有**做的，别误以为坏了：

| 功能 | 状态 | 原因 |
|---|---|---|
| 剪贴板同步 | 空实现 | 要走 UDMF + `ohos.permission.READ_PASTEBOARD`（system_basic，需 ACL），M2 |
| 软键盘输入 | 未接 | 需要在会话页加隐藏输入框，M2 |
| 文件传输 | 事件已上报，UI 未做 | M2 |
| 被控端（手机共享屏幕） | `ohos_capture_can_start()` 返回 0 | 要接 AVScreenCapture，M3 |
| 2in1 键鼠注入 | 能力查询已实现，注入未接 | 要 `ohos.permission.INJECT_INPUT_EVENT`（需 ACL），M3 |
| 多显示器切换 | `switchDisplay` 已导出，UI 未做 | M2 |

## 排错

**`找不到 Rust 静态库`**
先跑第一步。CMake 会把期望路径打出来。

**`undefined symbol: ohos_xxx`**
说明 `ohos_abi.cpp` 没被编进来，或者你删掉了某个实现。19 个 `ohos_*` 全在
那个文件里，一个都不能少。

**画面出来了但不动**
`frame_release` 没被调。渲染循环的每条返回路径都必须 release，否则 Rust 侧
背压会把后续帧全丢掉。

**画面静止时 CPU 也不高，但一动就花屏**
可能是 `SET_BUFFER_GEOMETRY` 用的尺寸与帧尺寸不一致。见 renderer.cpp 里
"buffer 的几何尺寸取帧尺寸"那段注释。

**点不准**
XComponent 的尺寸必须等于 `displayW()/displayH()`（按远端宽高比算出来的），
不能直接 `width('100%')`。否则 Surface 被拉伸，坐标换算就偏。
