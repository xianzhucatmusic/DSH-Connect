#!/bin/bash
# 生成可分发的 DMG：XianzhuDSHConnect-arm64.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VER=$(defaults read "$PWD/build/XianzhuDSHConnect.app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 1.0)
STAGE=$(mktemp -d)
DMG="dist/XianzhuDSHConnect-arm64-$VER.dmg"

cp -R build/XianzhuDSHConnect.app "$STAGE/"
cp dist/install.sh "$STAGE/"
chmod +x "$STAGE/install.sh"
cat > "$STAGE/使用说明.txt" <<'TXT'
Xianzhu DSH Connect — 把本地模型接进 DeepSeek Harness

安装
  1. 双击 install.sh 不会运行；请在「终端」里执行：
       cd <本文件夹> && ./install.sh
     或者右键 App → 打开（首次会被 Gatekeeper 询问一次）。

系统要求
  · Apple Silicon (M1/M2/M3/M4) Mac
  · macOS 14 或更高

模型
  · App 不附带模型。用「导入模型组…」选择你磁盘上的 .gguf。
  · 同一目录下的 mmproj-*.gguf 会自动配对给该目录的模型（视觉能力）。

它做什么
  · 启动本地 llama.cpp 服务，OpenAI 兼容，默认 http://127.0.0.1:8686/v1
  · 为 DeepSeek Harness 配置模型路由与工具组开关
  · 自动检测本机 DSH 实际可用的工具（含 MCP），按组勾选启用以控制提示词成本

TXT

rm -f "$DMG"
hdiutil create -volname "Xianzhu DSH Connect" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "packaged: $PWD/$DMG ($(du -h "$DMG" | cut -f1))"
