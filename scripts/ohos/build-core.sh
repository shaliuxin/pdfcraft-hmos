#!/usr/bin/env bash
# 构建 PdfCraft 的 HarmonyOS / OpenHarmony 核心静态库（libpdfcraft_ohos.a）。
#
# 用法：
#   bash scripts/ohos/build-core.sh              # debug（默认，快）
#   bash scripts/ohos/build-core.sh release      # release（上架/体积更小）
#
# 与 RustDesk 的关键区别：PdfCraft 的 PDF 核心是纯 Rust（hayro / lopdf / skrifa /
# kurbo），没有 opus / vpx / aom / libsodium 那类 C 依赖，所以这里**不需要**
# 准备 sysroot 的第三方 .a、不需要 libsodium 双份链接、不需要 PKG_CONFIG_PATH。
# 只需把 OHOS clang 作为 linker / cc 告诉 cargo —— 这些其实已写进 .cargo/config.toml，
# 这里再显式导一遍只为在命令行环境（CI/非 DevEco shell）下也能独立跑通。
set -euo pipefail

MODE="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

TARGET="${OHOS_TARGET:-aarch64-unknown-linux-ohos}"

echo "==> [1/3] 检查 Rust 目标是否安装"
if ! rustup target list --installed 2>/dev/null | grep -q "^${TARGET}$"; then
  echo "未安装目标 ${TARGET}，请先执行：rustup target add ${TARGET}"
  exit 1
fi

# --- C / 汇编 交叉工具链（供 cc-crate / linker 用）----------------------------
NDK="${OHOS_NDK:-C:/ohos-sdk/default/openharmony/native}"
case "$TARGET" in
  aarch64-unknown-linux-ohos) T="aarch64-linux-ohos"; TU="AARCH64_UNKNOWN_LINUX_OHOS" ;;
  x86_64-unknown-linux-ohos)  T="x86_64-linux-ohos";  TU="X86_64_UNKNOWN_LINUX_OHOS"  ;;
  *) echo "未知的 OHOS 目标：$TARGET"; exit 1 ;;
esac
export CC_${TU}="$NDK/llvm/bin/clang.exe"
export CXX_${TU}="$NDK/llvm/bin/clang++.exe"
export AR_${TU}="$NDK/llvm/bin/llvm-ar.exe"
export RANLIB_${TU}="$NDK/llvm/bin/llvm-ranlib.exe"
export CFLAGS_${TU}="--target=${T} --sysroot=$NDK/sysroot -D__MUSL__"
export CXXFLAGS_${TU}="--target=${T} --sysroot=$NDK/sysroot -D__MUSL__"

echo "==> [2/3] 编译 ${TARGET} (${MODE})  -p pdfcraft-ohos"
if [[ "$MODE" == "release" ]]; then
  cargo build --target "$TARGET" -p pdfcraft-ohos --release
else
  cargo build --target "$TARGET" -p pdfcraft-ohos
fi

echo "==> [3/3] 产物"
ART="target/${TARGET}/${MODE}/libpdfcraft_ohos.a"
if [[ -f "$ART" ]]; then
  ls -lh "$ART"
  echo "OK: $ART"
else
  echo "预期产物不存在，列出候选："
  ls -lh "target/${TARGET}/${MODE}/"*.a 2>/dev/null || true
  exit 1
fi
