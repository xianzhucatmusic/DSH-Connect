//
//  ToolGroupWriter.swift — 把 App 里的工具组勾选状态真正写进 DSH。
//
//  DSH 的 dsh-tool-groups 插件在**每次创建会话**时读取
//  ~/.dsh/tool-groups.json，来决定这次会话给模型哪些工具。
//
//  状态文件格式：
//    {
//      "default": "on" | "off",
//      "groups":  { "rea": { "off": true } },
//      "sessions": { "<sessionId>": { "off": ["rea", "web"] } }
//    }
//
//  语义（来自插件源码）：
//    · 某个组 off → 为它拥有的每个工具贡献一条 deny
//    · default=off 时，未在 groups 里显式写的组也一并关掉
//    · 全部关闭 → 用 deny 白名单；部分关闭 → 用 allow 反向列出剩下的
//

import Foundation

enum ToolGroupWriter {

    /// 与插件内置定义一致的分组。App 用它来展示和回写。
    static let groups: [(id: String, label: String, tools: [String], prefixes: [String])] = [
        ("core", "核心：文件与终端",
         ["bash", "read", "write", "edit", "glob", "grep", "read_image",
          "load_workspace_dependencies", "present"], []),
        ("search", "联网搜索与抓取", ["web_search", "web_fetch"], []),
        ("jobs", "后台任务", ["job_list", "job_output", "job_kill"], []),
        ("plan", "计划与待办", ["todo_write"], []),
        ("goals", "目标", ["create_goal", "get_goal", "update_goal"], []),
        ("skills", "技能库", ["skill"], []),
        ("delegation", "子智能体与工作流",
         ["subagent", "subagent_fork", "send_message", "interrupt_agent",
          "list_agents", "workflow"], []),
        ("ask", "向用户提问", ["ask_user_question"], []),
        ("mcp", "MCP 资源",
         ["list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"], []),
        ("rea", "REA 逆向工程（229 个工具）", [], ["mcp__rea__"]),
        ("ace", "ACE Studio 音乐", [], ["mcp__ace-studio__"]),
    ]

    static var stateFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/tool-groups.json")
    }

    /// 读取当前状态：返回被关闭的组 id 集合。
    static func readDisabled() -> Set<String> {
        guard let data = try? Data(contentsOf: stateFileURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let globalOff = (root["default"] as? String) == "off"
        var off = Set<String>()
        let dict = (root["groups"] as? [String: Any]) ?? [:]

        for g in groups {
            let entry = dict[g.id]
            if let obj = entry as? [String: Any], let flag = obj["off"] as? Bool {
                if flag { off.insert(g.id) }
            } else if entry == nil && globalOff {
                off.insert(g.id)
            }
        }
        return off
    }

    /// 写入状态。disabled 为空表示全部开启。
    @discardableResult
    static func write(disabled: Set<String>) throws -> URL {
        let url = stateFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)

        // 保留会话级覆盖，避免把用户已经打开的会话设置清掉
        var sessions: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = root["sessions"] as? [String: Any] {
            sessions = s
        }

        var groupsDict: [String: Any] = [:]
        for g in groups {
            groupsDict[g.id] = ["off": disabled.contains(g.id)]
        }

        let root: [String: Any] = [
            "default": "on",
            "groups": groupsDict,
            "sessions": sessions,
        ]

        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 预估被关掉之后省下的 token。
    static func savedTokens(disabled: Set<String>) -> Int {
        // REA 与 ACE 是外部 MCP，按已知实测值估
        var total = 0
        for id in disabled {
            switch id {
            case "rea": total += 68_500
            case "ace": total += 12_000
            default:
                total += ToolGroupWriter.estimatedTokens(for: id)
            }
        }
        return total
    }

    /// 单个组的大致 token 成本（按工具数量 × 平均 schema 大小）。
    static func estimatedTokens(for id: String) -> Int {
        guard let g = groups.first(where: { $0.id == id }) else { return 0 }
        let per = 295   // 单个工具定义的经验值
        return g.tools.count * per
    }
}
