#!/bin/bash
# 在任意一台 Apple Silicon Mac 上安装 Xianzhu DSH Connect。
#
# 用法（解压或挂载后，在包含本脚本的目录运行）：
#   ./install.sh
#
# 做的事：
#   1. 把 App 复制到 /Applications
#   2. 去掉 quarantine 扩展属性（App 未签名，不去掉会被报「已损坏」）
#   3. 如检测到旧版 QwenServing，提示可迁移配置
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Xianzhu DSH Connect"
SRC="$(pwd)/XianzhuDSHConnect.app"
DEST="/Applications/${APP_NAME}.app"

if [ ! -d "$SRC" ]; then
  echo "错误：当前目录找不到 XianzhuDSHConnect.app" >&2
  echo "请在解压后的文件夹里运行本脚本。" >&2
  exit 1
fi

# ── 环境检查 ────────────────────────────────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  echo "错误：这个构建是 Apple Silicon (arm64) 专用，当前机器是 $ARCH。" >&2
  exit 1
fi

MACOS=$(sw_vers -productVersion)
MAJOR=${MACOS%%.*}
if [ "$MAJOR" -lt 14 ]; then
  echo "错误：需要 macOS 14 或更高版本，当前是 $MACOS。" >&2
  exit 1
fi

DSH="/Applications/DeepSeek Harness.app"
if [ ! -d "$DSH" ]; then
  echo "提示：没在 /Applications 找到 DeepSeek Harness。"
  echo "      App 本身能装，但「自动检测工具组」会退到插件清单这一路。"
fi

echo "机器：$(uname -m) · macOS $MACOS"

# ── 安装 ────────────────────────────────────────────────────────────────────
echo "安装到 $DEST"
if [ -d "$DEST" ]; then
  read -r -p "已存在同名 App，覆盖？[y/N] " reply
  case "$reply" in [yY]*) rm -rf "$DEST" ;; *) echo "已取消"; exit 0 ;; esac
fi

cp -R "$SRC" "$DEST"

# 未签名的 App 从网上下载后带 quarantine，会被 Gatekeeper 拦截。
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || true

# ── 旧版迁移提示 ────────────────────────────────────────────────────────────
OLD="$HOME/Library/Application Support/QwenServing"
NEW="$HOME/Library/Application Support/XianzhuDSHConnect"
if [ -d "$OLD" ] && [ ! -d "$NEW" ]; then
  read -r -p "发现旧版 QwenServing 配置，迁移过来？[y/N] " reply
  case "$reply" in
    [yY]*) cp -R "$OLD" "$NEW"; echo "已迁移到 $NEW" ;;
  esac
fi

# ── 模型与 llama.cpp 就绪检查 ──────────────────────────────────────────────
BUNDLED_LLAMA="$DEST/Contents/Resources/llama/llama-server"
if [ -x "$BUNDLED_LLAMA" ]; then
  echo "llama.cpp：已内置（无需另外安装）"
else
  echo "llama.cpp：未内置。从另一台机器复制 llama 目录到："
  echo "  $HOME/Library/Application Support/XianzhuDSHConnect/llama/"
fi

echo
echo "完成。打开方式："
echo "  open \"$DEST\""
echo
echo "首次打开如果被拦截（未签名），右键点 App 选「打开」，或运行："
echo "  xattr -dr com.apple.quarantine \"$DEST\""
