# Xianzhu DSH Connect

把本地 GGUF 模型接进 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 的 macOS 工具。

它做三件事：**启动本地推理服务**、**把模型注册进 DSH**、**控制 DSH 发给模型的工具提示词**。

---

## 它解决什么问题

DSH 默认调用云端模型。接本地模型时有两个实际困难：

1. **配置繁琐** —— 要手写 llama-server 启动参数，再把地址、模型名、上下文长度填进 DSH 的 profile
2. **上下文不够** —— DSH 会挂载所有工具插件，逆向工程类插件有 229 个工具、约 68,500 token，小窗口的本地模型直接放不下

这个 App 用图形界面处理这两件事。

---

## 功能

### 模型管理
- 导入 GGUF 模型，按文件夹自动分组
- 同目录的 `mmproj-*.gguf`（视觉投影）自动配对
- 拖拽调参数：上下文长度、GPU 层数、并发槽位、Flash Attention

### 本地对话
- 内置聊天页，不走 DSH 也能测试模型
- 流式输出、思考过程折叠、停止生成
- 多会话，历史自动持久化

### 工具提示词控制
- 自动扫描本机的 DSH 安装，列出实际可用的工具组
- 按组勾选启用，每组标出真实 token 成本
- **只对本地模型生效** —— 切到云端模型时自动恢复完整工具集

### 其他
- **下载**：内置 Hugging Face 搜索与下载（支持镜像、断点续传）
- **一键导入**：把模型路由直接写进 DSH 配置，自动备份
- **教程**：内置新手 PDF
- **深色模式**

---

## 系统要求

| 项 | 要求 |
|---|---|
| 芯片 | Apple Silicon（M1 / M2 / M3 / M4） |
| 系统 | macOS 14+ |
| 内存 | 35B 的 Q4 模型建议 32 GB 以上 |
| 依赖 | DeepSeek Harness（工具提示词功能需要） |

---

## 安装

```bash
git clone https://github.com/xianzhucatmusic/DSH-Connect.git
cd xianzhu-dsh-connect
./build.sh
open build/XianzhuDSHConnect.app
```

App 不附带模型。用「导入模型组…」选择你磁盘上的 `.gguf`。

**llama.cpp** 需要单独准备。`build.sh` 会从
`~/Library/Application Support/XianzhuDSHConnect/llama/` 打包推理引擎，
也可以用 `LLAMA_SRC=/path/to/llama.cpp ./build.sh` 指定。

---

## 使用

### 最快路径

1. 「模型」页 → 导入模型组 → 选中模型
2. 底部「启动服务」，等状态点变绿（首次加载模型要几十秒）
3. 打开 DSH，模型下拉里选你的模型

### 让 DSH 认识你的模型

「设置 → 导入到 DeepSeek Harness → 一键导入配置」。

它会往 `~/.dsh/profiles/desktop/cordis.patch.yml` 写一个带标记的区块，
只替换这一段，其它配置不动，写入前自动备份。**改完需要重启 DSH。**

### 控制工具提示词

「设置 → 工具提示词」。点「重新检测」会扫描本机 DSH 安装。

用不上 REA 逆向工具的话取消勾选，能省 68,500 token。
改动只影响**新建**的会话，即时生效、无需重启 DSH。

---

## 设计说明

### 为什么工具开关只对本地模型生效

DSH 的工具面是按会话挂载的，与模型无关。本地模型窗口小、需要精简，
云端模型窗口大、裁掉反而损失能力。所以按会话创建时的模型路由分流：
`provider` 命中云端列表就保持完整，否则按勾选执行。

路由读不到时保守放行 —— 宁可多给工具，也不让会话意外缺能力。

### 为什么中途不能改工具

DSH 在工具集变化时会往会话历史里写 `developer/message`。
部分适配器（如 pi-ai）会拒绝这类消息，导致整个会话后续都报错。
所以开关只作用于新建会话。

### 上下文为什么会被“分走”

llama.cpp 的 `--parallel` 会把总上下文**平均分给每个并发槽位**。
设成 8、上下文 128K，实际每个请求只有 16K。默认值设成了 1。

---

## 配置文件

| 路径 | 作用 |
|---|---|
| `~/Library/Application Support/XianzhuDSHConnect/config.json` | App 设置 |
| `.../models.json` | 已导入的模型组 |
| `.../llama/` | 推理引擎 |
| `.../logs/` | 运行日志 |
| `~/.dsh/tool-groups.json` | 工具组开关状态 |

---

## 项目结构

```
Sources/XianzhuDSHConnect/
├── main.swift              应用入口、主界面、模型管理
├── DesignSystem.swift      配色、圆角、按钮样式
├── ChatTab.swift           对话界面
├── ChatStore.swift         多会话持久化
├── DownloadTab.swift       模型下载界面
├── HuggingFace.swift       HF API 与断点续传
├── ToolDetector.swift      扫描本机 DSH 工具
├── DSHConfigExporter.swift 写入 DSH 配置
├── PortGuard.swift         清理占用端口的残留进程
└── TutorialTab.swift       内置教程阅读器
```

---

## 贡献

欢迎提交 Issue 和 PR。

### 待办

- [ ] 支持切换 DSH 的 profile（目前固定 `desktop`）
- [ ] 下载支持多任务并行
- [ ] 教程 PDF 支持多语言

---

## 已知限制

- 只支持 Apple Silicon
- 工具组开关复用 `tools.restrict()`，依赖 DSH 内部接口，DSH 升级后可能需要适配
- 端口清理只处理本 App 启动的 `llama-server`

---

## 许可

[MIT](LICENSE)

## 致谢

- [llama.cpp](https://github.com/ggml-org/llama.cpp) — 本地推理引擎
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — 宿主平台
