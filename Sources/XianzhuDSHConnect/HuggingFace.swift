//
//  HuggingFace.swift — 在 App 内浏览 Hugging Face 并下载 GGUF 模型。
//
//  网络说明：部分网络环境访问不了 huggingface.co 的网页端，但 API 与下载
//  链路通常可用；另有 hf-mirror.com 镜像可作备选。两条线路都做成可切换。
//
//  下载策略：写入「部分下载文件」再改名，这样中断后可以按 Range 续传，
//  也不会让半个文件出现在模型列表里。
//

import Foundation

/// 一个可下载的 HF 仓库。
struct HFRepo: Identifiable, Hashable, Codable {
    let id: String            // 例如 unsloth/Qwen3-8B-GGUF
    var downloads: Int = 0
    var likes: Int = 0
    var lastModified: String = ""

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
}

/// 仓库里的一个文件。
struct HFFile: Identifiable, Hashable, Codable {
    let name: String          // rfilename，例如 Qwen3-8B-Q4_K_M.gguf
    var size: Int64? = nil    // 字节数，来自 LFS 元信息；未知为 nil

    var id: String { name }
    var isGGUF: Bool { name.lowercased().hasSuffix(".gguf") }
    var isMMProj: Bool {
        let lower = name.lowercased()
        return lower.contains("mmproj") && lower.hasSuffix(".gguf")
    }
    /// 量化等级，从文件名里粗略抽出，用于排序与展示。
    var quant: String? {
        let upper = name.uppercased()
        for token in ["Q8_0", "Q8", "Q6_K", "Q5_K_M", "Q5_K_S", "Q5", "Q4_K_M",
                      "Q4_K_S", "Q4_K", "Q4", "Q3_K_M", "Q3", "Q2_K", "IQ4_XS",
                      "IQ4_NL", "IQ3", "IQ2", "BF16", "F16", "F32"] {
            if upper.contains(token) { return token }
        }
        return nil
    }

    var sizeText: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

/// 下载线路。
enum HFRoute: String, CaseIterable, Identifiable, Codable {
    case official, mirror
    var id: String { rawValue }
    var title: String {
        switch self {
        case .official: return "Hugging Face 官方"
        case .mirror: return "hf-mirror.com 镜像"
        }
    }
    var apiBase: String { "https://huggingface.co" }
    var fileBase: String {
        switch self {
        case .official: return "https://huggingface.co"
        case .mirror: return "https://hf-mirror.com"
        }
    }
}

/// HF 的公开 API 与下载实现。
enum HuggingFace {

    // MARK: - 搜索

    /// 搜索仓库。`query` 为空时返回按下载量排序的 GGUF 仓库。
    static func search(_ query: String, limit: Int = 30, ggufOnly: Bool = true) async throws -> [HFRepo] {
        var text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { text = "gguf" }
        var comps = URLComponents(string: "\(HFRoute.official.apiBase)/api/models")!
        var items = [
            URLQueryItem(name: "search", value: text),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
        ]
        if ggufOnly { items.append(URLQueryItem(name: "filter", value: "gguf")) }
        comps.queryItems = items
        guard let url = comps.url else { throw HFError.badURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HFError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Row: Decodable {
            let id: String
            let downloads: Int?
            let likes: Int?
            let lastModified: String?
        }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return rows.map {
            HFRepo(id: $0.id, downloads: $0.downloads ?? 0, likes: $0.likes ?? 0,
                   lastModified: $0.lastModified ?? "")
        }
    }

    // MARK: - 文件列表

    /// 列出仓库里的 GGUF 文件（带大小）。大小优先取 LFS 元信息。
    static func files(in repo: String) async throws -> [HFFile] {
        let escaped = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        guard let url = URL(string: "\(HFRoute.official.apiBase)/api/models/\(escaped)") else {
            throw HFError.badURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw HFError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
            let lfs: LFS?
            struct LFS: Decodable { let size: Int64? }
        }
        struct Detail: Decodable { let siblings: [Sibling]? }
        let detail = try JSONDecoder().decode(Detail.self, from: data)
        return (detail.siblings ?? [])
            .map { HFFile(name: $0.rfilename, size: $0.lfs?.size ?? $0.size) }
            .filter { $0.isGGUF }
            .sorted { ($0.size ?? 0) < ($1.size ?? 0) }
    }

    // MARK: - 下载

    /// 下载 URL（走所选线路）。
    static func downloadURL(repo: String, file: String, route: HFRoute) -> URL? {
        let r = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo
        let f = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        return URL(string: "\(route.fileBase)/\(r)/resolve/main/\(f)")
    }

    /// 下载到目标目录，支持续传。完成后返回最终文件 URL。
    ///
    /// - 先写 `<name>.part`；中断后再调用会从已写入的字节数继续。
    /// - 进度通过 `onProgress(已下载, 总大小)` 回调。
    static func download(repo: String, file: String, into directory: URL,
                         route: HFRoute,
                         onProgress: @escaping (Int64, Int64?) -> Void) async throws -> URL {
        guard let url = downloadURL(repo: repo, file: file, route: route) else {
            throw HFError.badURL
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let finalName = (file as NSString).lastPathComponent
        let finalURL = directory.appendingPathComponent(finalName)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return finalURL                                   // 已经下过
        }
        let partURL = directory.appendingPathComponent(finalName + ".part")

        var existing: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
           let size = attrs[.size] as? Int64 {
            existing = size
        }

        var request = URLRequest(url: url)
        request.setValue("XianzhuDSHConnect/1.0", forHTTPHeaderField: "User-Agent")
        if existing > 0 {
            request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw HFError.http(-1) }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 416 {                       // 已经下完
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: partURL, to: finalURL)
                return finalURL
            }
            throw HFError.http(http.statusCode)
        }

        // 续传被拒绝（服务器返回 200 而不是 206）时从头写。
        let resuming = existing > 0 && http.statusCode == 206
        if !resuming { existing = 0 }

        let expected = http.expectedContentLength > 0
            ? http.expectedContentLength + existing
            : nil

        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var written = existing
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var lastReport = Date.distantPast

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let now = Date()
                if now.timeIntervalSince(lastReport) > 0.15 {
                    lastReport = now
                    onProgress(written, expected)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        onProgress(written, expected)

        try? handle.close()
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        return finalURL
    }

    /// 建议的存放目录：外置硬盘优先，否则用户「下载」目录下的 Models。
    static var suggestedDirectory: URL {
        let fm = FileManager.default
        if let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for name in volumes.sorted() where !["Macintosh HD"].contains(name) {
                let candidate = URL(fileURLWithPath: "/Volumes/\(name)")
                if fm.isWritableFile(atPath: candidate.path) {
                    return candidate.appendingPathComponent("模型", isDirectory: true)
                }
            }
        }
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/Models", isDirectory: true)
    }
}

/// HF 相关错误。
enum HFError: LocalizedError {
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址无效"
        case .http(let code):
            switch code {
            case 401, 403: return "没有访问权限（可能需要登录或该仓库受限）"
            case 404: return "找不到（仓库名或文件名写错了）"
            case 429: return "请求太频繁，稍等再试"
            case 416: return "续传位置无效"
            default: return "服务器返回 \(code)"
            }
        }
    }
}
