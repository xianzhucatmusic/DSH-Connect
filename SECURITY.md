# 安全说明

## 报告漏洞

如果发现安全问题，请**不要**开公开 Issue。

发邮件到仓库维护者邮箱（见 GitHub 个人主页），或用 GitHub 的
[私密漏洞报告](https://docs.github.com/zh/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability) 功能。

## 这个 App 会碰哪些地方

了解权限范围有助于判断风险：

| 路径 | 用途 | 风险 |
|---|---|---|
| `~/.dsh/profiles/*/cordis.patch.yml` | 写入模型路由与工具组插件 | **会修改 DSH 配置**，写入前自动备份 |
| `~/.dsh/tool-groups.json` | 工具组开关状态 | 新建文件 |
| `~/Library/Application Support/XianzhuDSHConnect/` | App 自己的数据 | 仅限本目录 |
| `127.0.0.1:<port>` | 与 llama-server 通信 | 仅监听本机回环 |

App **不做**这些事：

- 不联网（除 Hugging Face 下载功能，且只在你主动搜索/下载时）
- 不上传任何数据
- 不请求 root 权限
- 不修改系统设置

## 本地推理服务

llama-server 监听 `127.0.0.1`，不对局域网开放。

但请注意：**任何本机程序都能访问这个端口**。如果模型涉及敏感数据，
用完停止服务，不要在后台常驻。

## 未签名构建

官方 release 的 App 未做代码签名和公证（`codesign --sign -` 只是 ad-hoc 签名）。

首次打开需要右键 → 打开，或：

```bash
xattr -dr com.apple.quarantine /Applications/XianzhuDSHConnect.app
```

**自己从源码构建**是更安全的选择，`build.sh` 只依赖系统自带的 `swiftc`。
