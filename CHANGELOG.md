# 更新记录

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] — 2026-11-10

首个公开版本。

### 新增

- **模型管理**：导入 GGUF 模型，按目录自动分组；同目录的 `mmproj-*.gguf` 自动配对为视觉投影
- **本地对话**：内置聊天页，支持流式输出、思考过程折叠、多会话持久化
- **工具提示词控制**：扫描本机 DSH 安装，按组勾选工具；每组显示真实 token 成本
- **模型分流**：工具裁剪只对本地模型生效，云端模型保持完整工具集
- **下载**：Hugging Face 搜索与下载，支持镜像站、断点续传
- **一键导入**：把模型路由写进 DSH 配置，同名条目自动去重，写入前备份
- **内置教程**：面向新手的 PDF 手册
- **深色模式**
- **端口清理**：启动前回收残留的 `llama-server` 进程
- **GitHub Actions**：推 tag 自动构建并发布

### 设计取舍

- 工具裁剪在**会话创建时**决定，不在中途切换。DSH 在工具集变化时会写
  `developer/message` 进历史，pi-ai 适配器会拒绝这类消息。
- llama.cpp 的 `--parallel` 会平分上下文，默认值设为 `1` 避免窗口被切碎。
- 推理引擎不打包进仓库，由用户自行放入或首次启动时指定路径。

[1.0.0]: https://github.com/your-org/xianzhu-dsh-connect/releases/tag/v1.0.0
