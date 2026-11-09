#!/bin/bash
# 构建 XianzhuDSHConnect.app（arm64，未签名，自包含 llama.cpp）
#
# 用法:
#   ./build.sh                 # 构建，把已有的 llama 目录一起打包
#   ./build.sh --no-llama      # 构建，不带 llama 二进制（体积小，需目标机另装）
set -euo pipefail
cd "$(dirname "$0")"

APP="build/XianzhuDSHConnect.app"
BIN="XianzhuDSHConnect"
LLAMA_SRC="${LLAMA_SRC:-$HOME/Library/Application Support/XianzhuDSHConnect/llama}"
WITH_LLAMA=1
[ "${1:-}" = "--no-llama" ] && WITH_LLAMA=0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 最小部署目标：macOS 14（SwiftUI 的 Form/List 需要）
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o "$APP/Contents/MacOS/$BIN" Sources/XianzhuDSHConnect/*.swift

cp App/Info.plist "$APP/Contents/Info.plist"
[ -f App/AppIcon.icns ] && cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f Tools/tutorial.pdf ] && cp Tools/tutorial.pdf "$APP/Contents/Resources/tutorial.pdf"

if [ "$WITH_LLAMA" = "1" ] && [ -x "$LLAMA_SRC/llama-server" ]; then
  echo "打包 llama.cpp: $LLAMA_SRC"
  # 保留符号链接（dylib 靠 @loader_path 互相引用）
  rsync -aH --exclude '*.log' "$LLAMA_SRC/" "$APP/Contents/Resources/llama/"
  # 去掉不需要的辅助程序，省体积
  for extra in llama-bench llama-quantize llama-imatrix llama-perplexity \
               llama-gguf-split llama-cvector-generator llama-batched-bench \
               llama-export-lora llama-completion llama-fit-params \
               llama-mtmd-cli llama-mtmd-debug llama-llava-cli \
               llama-minicpmv-cli llama-qwen2vl-cli llama-gemma3-cli \
               llama-tokenize llama-tts llama-embedding llama-rerank \
               ggml-rpc-server ggml-metal-tuning; do
    rm -f "$APP/Contents/Resources/llama/$extra" 2>/dev/null || true
    rm -f "$APP/Contents/Resources/llama/lib${extra#llama-}-impl.dylib" 2>/dev/null || true
  done
fi

# 未签名：目标机首次打开需右键「打开」，或运行 install.sh 里的去隔离步骤
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

SIZE=$(du -sh "$APP" | cut -f1)
echo "built: $PWD/$APP  ($SIZE)"
