//
//  DSHConfigExporter.swift — 把当前模型配置一键写进 DeepSeek Harness。
//
//  做的是 DSH 里手工改 profile 那件事：在
//    ~/.dsh/profiles/desktop/cordis.patch.yml
//  里维护一个 `llm-pi-ai` 条目，把本机 llama-server 注册成模型路由。
//
//  安全措施：
//    · 只动我们自己那一段（带标记的区块），其余配置原样保留
//    · 写入前先备份成 cordis.patch.yml.bak-<时间戳>
//    · 先写临时文件再原子替换，避免写一半断电
//

import Foundation

enum DSHConfigExporter {

    /// 我们管理的区块标记。重复导入只替换这两行之间的内容。
    static let blockStart = "# --- Xianzhu DSH Connect managed (do not edit inside) ---"
    static let blockEnd = "# --- end Xianzhu DSH Connect managed ---"

    /// DSH profile 目录。
    static var profileDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/profiles/desktop", isDirectory: true)
    }

    static var patchFile: URL {
        profileDirectory.appendingPathComponent("cordis.patch.yml")
    }

    enum ImportError: LocalizedError {
        case dshMissing
        case profileMissing
        case noModel
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .dshMissing:
                return "没找到 DeepSeek Harness。请先安装它。"
            case .profileMissing:
                return "没找到 DSH 的配置目录：~/.dsh/profiles/desktop"
            case .noModel:
                return "还没有选择模型，先到「模型」页导入并选中一个。"
            case .writeFailed(let detail):
                return "写入失败：\(detail)"
            }
        }
    }

    /// 结果摘要，用于界面反馈。
    struct Outcome {
        var patchPath: String
        var backupPath: String?
        var modelCount: Int
        var provider: String
        var needsRestart: Bool = true
    }

    /// 检查是否就绪（DSH 装了、profile 在）。
    static func readiness() -> (ok: Bool, detail: String) {
        let dsh = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app")
        let fm = FileManager.default
        if !fm.fileExists(atPath: dsh.path) {
            return (false, "没检测到 DeepSeek Harness")
        }
        if !fm.fileExists(atPath: profileDirectory.path) {
            return (false, "没找到 ~/.dsh/profiles/desktop")
        }
        if !fm.fileExists(atPath: patchFile.path) {
            return (false, "还没有 cordis.patch.yml")
        }
        return (true, "可以导入")
    }

    /// 生成我们要写入的 YAML 区块。
    @MainActor
    static func block(ctl: ServerController) -> String {
        let port = ctl.config.port
        let ctxWindow = ctl.config.contextSize
        let maxTokens = max(ctxWindow / 8, 1024)
        let models = ctl.models

        var lines: [String] = []
        lines.append(blockStart)
        lines.append("# 由 Xianzhu DSH Connect 生成，重新导入会整块替换。")
        lines.append("- id: llm-pi-ai")
        lines.append("  name: \"@deepseek-ai/dsh-llm-pi-ai\"")
        lines.append("  config:")
        lines.append("    providers:")
        lines.append("      locmodel-qwen:")
        lines.append("        displayName: Xianzhu Local")
        lines.append("        api: openai-completions")
        lines.append("        baseURL: http://127.0.0.1:\(port)/v1")
        lines.append("        apiKeyEnv: QWEN_LOCAL_API_KEY")
        lines.append("        defaultContextWindow: \(ctxWindow)")
        lines.append("        defaultMaxTokens: \(maxTokens)")
        lines.append("        models:")

        for entry in models {
            let path = entry.path
            let name = entry.displayName.replacingOccurrences(of: "\"", with: "'")
            let supportsImage = !entry.mmproj.isEmpty
            lines.append("          - id: \(path)")
            lines.append("            name: \(name)")
            lines.append("            contextWindow: \(ctxWindow)")
            lines.append("            maxTokens: \(maxTokens)")
            lines.append("            input:")
            lines.append("              - text")
            if supportsImage { lines.append("              - image") }
            lines.append("            reasoningEfforts:")
            lines.append("              off: null")
            lines.append("              low: low")
            lines.append("              medium: medium")
            lines.append("              high: high")
        }

        lines.append("        compat:")
        lines.append("          thinkingFormat: qwen-chat-template")
        lines.append("          supportsReasoningEffort: false")
        lines.append("          maxTokensField: max_tokens")
        lines.append(blockEnd)
        return lines.joined(separator: "\n")
    }

    /// 一键导入。会备份、替换区块、原子写入。
    @discardableResult
    @MainActor
    static func export(ctl: ServerController) throws -> Outcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: "/Applications/DeepSeek Harness.app") else {
            throw ImportError.dshMissing
        }
        guard fm.fileExists(atPath: profileDirectory.path) else {
            throw ImportError.profileMissing
        }
        guard !ctl.models.isEmpty else { throw ImportError.noModel }

        // 读现有内容；不存在就从零开始。
        let existing = (try? String(contentsOf: patchFile, encoding: .utf8)) ?? ""
        let newBlock = block(ctl: ctl)

        var composed: String
        if let startRange = existing.range(of: blockStart),
           let endRange = existing.range(of: blockEnd, range: startRange.upperBound..<existing.endIndex) {
            // 已有我们的区块：整块替换
            composed = String(existing[existing.startIndex..<startRange.lowerBound])
                + newBlock
                + String(existing[endRange.upperBound...])
            // 替换后仍可能残留手写的同名条目（用户以前手工配过），一并清掉
            composed = stripForeignProviderEntries(composed)
        } else {
            // 首次导入：先摘掉手写的 llm-pi-ai 条目，再追加我们的区块。
            // DSH 里插件 id 必须唯一，留下两个会让 DSH 启动失败。
            var base = stripForeignProviderEntries(existing)
            if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
            if !base.isEmpty { base += "\n" }
            composed = base + newBlock + "\n"
        }

        // 备份
        var backupPath: String? = nil
        if fm.fileExists(atPath: patchFile.path) {
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
            let backup = profileDirectory.appendingPathComponent("cordis.patch.yml.bak-xianzhu-\(stamp)")
            try? fm.copyItem(at: patchFile, to: backup)
            backupPath = backup.path
        }

        // 原子写入
        let tmp = profileDirectory.appendingPathComponent(".cordis.patch.yml.tmp")
        do {
            try composed.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try fm.replaceItemAt(patchFile, withItemAt: tmp,
                                     backupItemName: nil, options: [])
        } catch {
            try? fm.removeItem(at: tmp)
            throw ImportError.writeFailed(error.localizedDescription)
        }

        return Outcome(patchPath: patchFile.path,
                       backupPath: backupPath,
                       modelCount: ctl.models.count,
                       provider: "locmodel-qwen")
    }

    /// 移除手写的（不在我们标记区块内的）`llm-pi-ai` 条目。
    ///
    /// DSH 的插件 id 必须唯一。用户以前可能手工写过一条，
    /// 直接追加会导致两条同名条目，DSH 启动就会失败。
    /// 这个函数按 YAML 的顶层列表项切分，只删掉 id 是 llm-pi-ai 的那些块。
    static func stripForeignProviderEntries(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var skipping = false          // 正在丢弃一个手写条目
        var insideOurBlock = false    // 在我们自己的标记区间里，原样保留

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == blockStart {
                insideOurBlock = true
                skipping = false
                kept.append(line)
                continue
            }
            if trimmed == blockEnd {
                insideOurBlock = false
                kept.append(line)
                continue
            }
            if insideOurBlock {       // 我们写的内容一字不动
                kept.append(line)
                continue
            }

            let isTopLevelEntry = line.hasPrefix("- ")
            if isTopLevelEntry {
                if line.contains("id: llm-pi-ai") {
                    skipping = true   // 手写的同名条目：丢弃
                    continue
                }
                skipping = false
                kept.append(line)
                continue
            }

            if skipping { continue }  // 丢弃该条目的后续字段
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// 当前 profile 里是否已经有我们写的区块。
    static func alreadyImported() -> Bool {
        guard let text = try? String(contentsOf: patchFile, encoding: .utf8) else { return false }
        return text.contains(blockStart)
    }

    /// 现有 llm-pi-ai 条目是否是别的来源（不是我们写的）。
    static func hasForeignProviderConfig() -> Bool {
        guard let text = try? String(contentsOf: patchFile, encoding: .utf8) else { return false }
        return text.contains("id: llm-pi-ai") && !text.contains(blockStart)
    }

    /// 备份文件列表（用于界面展示/恢复提示）。
    static func backups() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: profileDirectory.path)
        else { return [] }
        return files.filter { $0.hasPrefix("cordis.patch.yml.bak") }.sorted().reversed()
    }
}
