//
//  ToolDetector.swift — 自动检测这台机器上 DSH 实际可用的工具，并归类成工具组。
//
//  三路检测，取证据最全的一路：
//    1. DSH 会话日志（request/header.tools）—— 最权威：模型实际收到的工具清单。
//    2. profile / home 的 cordis.patch.yml —— 拿到已配置的 MCP 服务器名。
//    3. 应用内的 dsh-tool-* 包 —— 拿到「装了但可能没启用」的插件清单。
//
//  检测结果只用于界面展示与成本估算；真正的开关仍由 dsh-tool-groups 插件
//  在会话创建时按状态文件执行。
//

import Foundation

/// 一个工具组：id、中文名、它包含的工具名和 token 成本。
struct ToolGroup: Identifiable, Hashable {
    let id: String
    let label: String
    let tools: [String]
    let prefixes: [String]
    let approxTokens: Int
    let source: String   // "会话" / "配置" / "插件"

    var costText: String {
        approxTokens >= 1000
            ? String(format: "%.1fK", Double(approxTokens) / 1000)
            : "\(approxTokens)"
    }

    var toolCountText: String {
        if !tools.isEmpty { return "\(tools.count) 个工具" }
        if let p = prefixes.first { return "\(p)* 全部" }
        return ""
    }
}

/// 检测到的工具快照。
struct ToolInventory {
    var tools: [String] = []
    var mcpServers: [String] = []
    var groups: [ToolGroup] = []
    var source: String = "无"
    var detectedAt: Date = .init()
}

enum ToolDetector {

    /// 已知工具名 → 分组规则。未命中的工具归入「其它」。
    private static let rules: [(id: String, label: String, tools: [String])] = [
        ("core", "文件与终端", ["bash", "pwsh", "read", "write", "edit", "read_image",
                              "glob", "grep", "str_replace_editor", "load_workspace_dependencies"]),
        ("search", "联网搜索与抓取", ["web_search", "web_fetch"]),
        ("jobs", "后台任务", ["job_list", "job_output", "job_kill"]),
        ("plan", "计划与待办", ["todo_write", "exit_plan_mode"]),
        ("goals", "目标", ["create_goal", "get_goal", "update_goal"]),
        ("skills", "技能库", ["skill"]),
        ("delegation", "子智能体与工作流",
         ["subagent", "subagent_fork", "send_message", "interrupt_agent", "list_agents",
          "list_subagent_models", "workflow", "ralph"]),
        ("ask", "向用户提问", ["ask_user_question"]),
        ("present", "交付物", ["present"]),
        ("mcpresources", "MCP 资源", ["list_mcp_resources", "read_mcp_resource",
                                     "list_mcp_resource_templates"]),
        ("cordis", "插件自省", ["cordis_inspect_list", "cordis_inspect_query"]),
    ]

    /// 粗略 token 估算：工具 schema 的 JSON 字符数 / 4。
    /// 中文描述占得多，但 schema 主要是英文键名，除以 4 与实测 73 891 对 304 769 字节吻合。
    private static func approxTokens(_ count: Int, averageChars: Int = 1180) -> Int {
        max(count * averageChars / 4, 0)
    }

    /// 主入口：扫描并返回工具清单。
    static func detect() -> ToolInventory {
        var inventory = ToolInventory()

        let fromSessions = detectFromSessionLogs()
        if !fromSessions.tools.isEmpty {
            inventory.tools = fromSessions.tools
            inventory.mcpServers = fromSessions.mcpServers
            inventory.source = "会话日志"
        } else {
            let fromConfig = detectFromConfig()
            inventory.mcpServers = fromConfig
            inventory.source = fromConfig.isEmpty ? "插件清单" : "profile 配置"
            inventory.tools = detectFromPluginBundles()
        }

        inventory.groups = buildGroups(tools: inventory.tools, mcpServers: inventory.mcpServers)
        return inventory
    }

    // MARK: - 1. 会话日志（权威）

    private static func detectFromSessionLogs() -> (tools: [String], mcpServers: [String]) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsRoot = home.appendingPathComponent(".dsh/sessions")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return ([], [])
        }

        // 按修改时间取最近的若干个 project 目录下的会话
        var logs: [(URL, Date)] = []
        for dir in dirs {
            guard let subs = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for sub in subs {
                let log = sub.appendingPathComponent("session.v4.jsonl.zstd")
                guard FileManager.default.fileExists(atPath: log.path) else { continue }
                let mtime = (try? log.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                logs.append((log, mtime))
            }
        }
        logs.sort { $0.1 > $1.1 }

        var best: [String] = []
        var bestMcp: [String] = []
        for (log, _) in logs.prefix(12) {
            guard let names = readToolNames(fromLog: log) else { continue }
            if names.count > best.count {
                best = names
                bestMcp = Array(Set(names.filter { $0.hasPrefix("mcp__") }
                    .compactMap { $0.split(separator: "__").dropFirst().first.map(String.init) }))
            }
            if best.count > 200 { break }   // 已经拿到全量清单，不必再扫
        }
        return (best, bestMcp.sorted())
    }

    /// 解压并扫描一个会话日志，返回其中最大的 `request/header.tools` 名字集。
    private static func readToolNames(fromLog url: URL) -> [String]? {
        // 解压器按常见位置探测：Intel/Apple Silicon Homebrew、MacPorts、系统。
        // 都没有时返回 nil，检测会退到 profile 配置那一路。
        let candidates = [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/opt/local/bin/zstd",
            "/usr/bin/zstd"
        ]
        guard let zstd = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstd)
        process.arguments = ["-dc", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }

        var best: [String] = []
        for line in text.split(separator: "\n") {
            guard line.contains("\"request/header\""), line.contains("\"tools\"") else { continue }
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let dataObj = row["data"] as? [String: Any],
                  let header = dataObj["header"] as? [String: Any],
                  let tools = header["tools"] as? [[String: Any]] else { continue }
            let names = tools.compactMap { $0["name"] as? String }
            if names.count > best.count { best = names }
        }
        return best.isEmpty ? nil : best
    }

    // MARK: - 2. profile 配置（MCP 服务器名）

    private static func detectFromConfig() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".dsh/profiles/desktop/cordis.patch.yml"),
            home.appendingPathComponent(".dsh/cordis.patch.yml")
        ]
        var servers: Set<String> = []
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.contains("serverName:") {
                let value = line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                if let value, !value.isEmpty { servers.insert(value) }
            }
        }
        return servers.sorted()
    }

    // MARK: - 3. 应用内的工具插件

    private static func detectFromPluginBundles() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/DeepSeek Harness.app/Contents/Resources/app/dsh/node_modules/@deepseek-ai",
            home.appendingPathComponent("Applications/DeepSeek Harness.app/Contents/Resources/app/dsh/node_modules/@deepseek-ai").path
        ]
        guard let appModules = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }).map(URL.init(fileURLWithPath:)) else { return [] }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: appModules, includingPropertiesForKeys: nil) else { return [] }

        var names: Set<String> = []
        for entry in entries where entry.lastPathComponent.hasPrefix("dsh-tool-") {
            let file = entry.appendingPathComponent("lib/index.js")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            // 工具定义里的 name: "..."；过滤掉明显的非工具标识。
            let pattern = #"name:\s*"([a-z][a-z0-9_]{2,30})""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                      let r = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[r])
                if ["stdio", "native", "ptc", "list", "read", "write", "get", "set",
                    "result", "error", "text", "image", "input", "output",
                    "string", "number", "boolean", "object", "array"].contains(name) { continue }
                names.insert(name)
            }
        }
        return names.sorted()
    }

    // MARK: - 归类

    private static func buildGroups(tools: [String], mcpServers: [String]) -> [ToolGroup] {
        var groups: [ToolGroup] = []
        var claimed: Set<String> = []

        for rule in rules {
            let hit = tools.filter { rule.tools.contains($0) }
            guard !hit.isEmpty else { continue }
            claimed.formUnion(hit)
            groups.append(ToolGroup(
                id: rule.id, label: rule.label, tools: hit, prefixes: [],
                approxTokens: approxTokens(hit.count), source: "检测"))
        }

        // MCP 服务器各自成组：真实工具名以 `mcp__<server>__` 为前缀。
        var servers = mcpServers
        for tool in tools where tool.hasPrefix("mcp__") {
            if let server = tool.split(separator: "__").dropFirst().first.map(String.init),
               !servers.contains(server) { servers.append(server) }
        }
        for server in servers.sorted() {
            let prefix = "mcp__\(server)__"
            let hit = tools.filter { $0.hasPrefix(prefix) }
            let label: String
            switch server {
            case "rea": label = "REA 逆向工程"
            case "ace-studio": label = "ACE Studio 音乐"
            default: label = "MCP · \(server)"
            }
            groups.append(ToolGroup(
                id: server, label: label, tools: [], prefixes: [prefix],
                approxTokens: hit.isEmpty ? 0 : approxTokens(hit.count),
                source: hit.isEmpty ? "配置" : "会话"))
            claimed.formUnion(hit)
        }

        // 剩下没归类的，单独成组，避免「检测到但看不到」。
        let rest = tools.filter { !claimed.contains($0) }
        if !rest.isEmpty {
            groups.append(ToolGroup(
                id: "other", label: "其它工具", tools: rest, prefixes: [],
                approxTokens: approxTokens(rest.count), source: "会话"))
        }
        return groups
    }
}
