#!/usr/bin/env bash
# 打包 PdfCraft 的 HarmonyOS 产物（ArkTS 应用层，依赖已构建好的核心静态库）。
#
# 用法：
#   bash scripts/ohos/build-hap.sh            # 调试/侧载用 HAP（默认）
#   bash scripts/ohos/build-hap.sh hap        # 同上
#   bash scripts/ohos/build-hap.sh app        # 应用市场用发布包 .app（release）
#
# 前置：先跑 build-core.sh（两架构核心库就位：
#   target/aarch64-unknown-linux-ohos/<mode>/libpdfcraft_ohos.a
#   target/x86_64-unknown-linux-ohos/<mode>/libpdfcraft_ohos.a）。
# 本脚本不编 Rust，只调 hvigorw。
#
# 产物：
#   hap → ohos-app/entry/build/default/outputs/default/entry-default-signed.hap
#   app → ohos-app/build/outputs/release/*-signed.app
#
# 为什么需要本脚本：hvigorw 需要 JAVA_HOME / DEVECO_SDK_HOME 都在环境里，
# 少任何一个就报 00303217（找不到 SDK）。路径都是 DevEco 默认安装位置，
# 装在别处时用环境变量覆盖。
set -euo pipefail

KIND="${1:-hap}"
case "$KIND" in
  hap|app) ;;
  *) echo "用法：bash scripts/ohos/build-hap.sh [hap|app]"; exit 1 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# PATH 里必须是 POSIX 风格（/c/...），Windows 风格条目会被 MSYS bash 忽略。
DEVECO_HOME="${DEVECO_HOME:-/c/Program Files/Huawei/DevEco Studio}"
DEV_WIN="$(cygpath -w "$DEVECO_HOME" 2>/dev/null || echo "$DEVECO_HOME")"
export JAVA_HOME="${JAVA_HOME:-$DEV_WIN/jbr}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEV_WIN/sdk}"
export PATH="$DEVECO_HOME/tools/hvigor/bin:$DEVECO_HOME/jbr/bin:$PATH"

cd "$ROOT/ohos-app"

if [[ "$KIND" == "hap" ]]; then
  # 调试产品：调试签名（绑定设备 UDID），可侧载真机。
  hvigorw assembleHap --mode module -p product=default
  ART="$ROOT/ohos-app/entry/build/default/outputs/default/entry-default-signed.hap"
else
  # 发布产品：发布签名。.app 是「应用包」（App Pack），AGC 上传用的是这个。
  # 注意发布签名包不能侧载真机（9568322 not trusted），真机调试用 hap。
  hvigorw assembleApp --mode project -p product=release -p buildMode=release
  ART="$(ls -t "$ROOT"/ohos-app/build/outputs/*/*.app 2>/dev/null | grep -v unsigned | head -1 || true)"
fi

if [[ -n "${ART:-}" && -f "$ART" ]]; then
  ls -lh "$ART"
  echo "OK: $ART"
else
  echo "打包失败：未找到 ${KIND} 产物，请看上方 hvigorw 输出"
  exit 1
fi
