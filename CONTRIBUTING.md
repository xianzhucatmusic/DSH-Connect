# 参与开发

欢迎 Issue 和 PR。这个项目的目标是让本地模型接入 DSH 变得简单，任何降低使用门槛的改动都值得讨论。

## 开发环境

| 需要 | 版本 |
|---|---|
| macOS | 14+ |
| Xcode 命令行工具 | 15+ |
| Apple Silicon | M1 以上 |

```bash
xcode-select --install      # 如果还没装
git clone <repo>
cd xianzhu-dsh-connect
./build.sh --no-llama       # 开发时不必打包 llama.cpp
open build/XianzhuDSHConnect.app
```

开发模式下没有 llama.cpp 也不影响启动，只是不能真正跑模型。

## 项目结构

```
Sources/XianzhuDSHConnect/
├── main.swift              AppConfig / Routing / ServerController / ContentView / 模型页 / 设置页 / 日志页
├── DesignSystem.swift      配色、圆角、按钮样式（改外观从这里入手）
├── ChatTab.swift           对话界面
├── ChatStore.swift         会话持久化
├── DownloadTab.swift       下载界面
├── HuggingFace.swift       HF API、断点续传
├── ToolDetector.swift      扫描本机 DSH 工具
├── DSHConfigExporter.swift 写入 DSH 配置
└── PortGuard.swift         端口占用清理
```

没有用 Xcode 工程，`swiftc` 直接编译。加新文件放进 `Sources/XianzhuDSHConnect/` 即可，`build.sh` 会自动带上。

## 提交规范

```
feat: 支持切换 DSH profile
fix: 端口清理时误判其他进程
docs: 补充 llama.cpp 安装说明
refactor: 拆分 ServerController
```

正文说清**为什么**改，不只是改了什么。

## 代码风格

- 注释写意图，不写复述。`// 递增计数器` 没意义，`// llama.cpp 用 -np 平分上下文，默认必须为 1` 有意义
- 新增用户可见的文案用简体中文
- 涉及 DSH 内部接口的地方，注明对应的 DSH 版本

## 改动 DSH 配置前必读

`DSHConfigExporter` 会改用户真实的 `~/.dsh/profiles/desktop/cordis.patch.yml`。

**任何改动都要保证**：

1. 只动标记块内部
2. 写入前备份
3. 重复执行结果一致（幂等）

测试时建议先 `cp ~/.dsh/profiles/desktop/cordis.patch.yml /tmp/backup.yml`。

## 工具组开关的设计约束

`tools.restrict()` 必须在 agent scope 内调用，且**只在会话创建时生效**。
中途改动会往历史里写 `developer/message`，部分适配器会拒绝这类消息导致会话报错。

改这块之前请先读 `ToolDetector.swift` 顶部的注释。

## 提 PR 之前

```bash
./build.sh --no-llama   # 必须能编译通过
```

如果改了界面，附一张截图。
