// Xianzhu DSH Connect — load local models into DeepSeek Harness.
//
// Two things in one window:
//   1. a llama.cpp server manager for local GGUF models, and
//   2. a control panel for what DSH offers those models: which tool groups
//      (their system-prompt cost) and which model routes.
//
// What it does:
//   * imports GGUF model files (and optional mmproj vision projectors)
//   * launches a llama.cpp `llama-server` child process with the chosen settings
//   * shows live server output, health, and the OpenAI-compatible endpoint
//   * optionally exposes the server beyond loopback (LAN / public) with a bearer token
//
// External control (used by tooling, harmless otherwise):
//   open -a "Xianzhu DSH Connect" --args --autostart --model <path.gguf> --port 8686 --ctx 32768
//
// Design notes: everything lives under ~/Library/Application Support/XianzhuDSHConnect
// (llama/ binaries, models.json, config.json, logs). No LocModel dependency:
// the llama.cpp build was vendored once; re-vendor by pointing LLAMA_SRC at
// another llama.cpp directory.

import AppKit
import PDFKit
import SwiftUI

// MARK: - Paths

enum Paths {
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/XianzhuDSHConnect", isDirectory: true)
    /// llama.cpp 二进制的查找顺序：
    ///   1. App 包内的 Resources/llama（自包含分发时用）
    ///   2. Application Support 下的 llama（用户导入或首次安装）
    static var llamaDir: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("llama"),
           FileManager.default.isExecutableFile(
             atPath: bundled.appendingPathComponent("llama-server").path) {
            return bundled
        }
        return support.appendingPathComponent("llama", isDirectory: true)
    }
    static var serverBin: URL { llamaDir.appendingPathComponent("llama-server") }
    static let modelsFile = support.appendingPathComponent("models.json")
    static let configFile = support.appendingPathComponent("config.json")
    static let logsDir = support.appendingPathComponent("logs", isDirectory: true)

    static func prepare() {
        for dir in [support, logsDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static func logURL(port: Int) -> URL {
        logsDir.appendingPathComponent("llama-server-\(port).log")
    }
}

// MARK: - Settings model

enum Routing: String, CaseIterable, Identifiable, Codable {
    case local, lan, publicNet
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "仅本机 (127.0.0.1)"
        case .lan: return "局域网 (0.0.0.0)"
        case .publicNet: return "公网 (0.0.0.0 + 外网)"
        }
    }
    var hint: String {
        switch self {
        case .local: return "只有这台 Mac 能访问。"
        case .lan: return "同一 Wi-Fi/局域网内的设备可用 http://<本机IP>:端口/v1 访问，需携带密钥。"
        case .publicNet: return "局域网开放，并自动尝试建立外网隧道。需要在 App 外另行部署隧道（见说明）。"
        }
    }
    var bindAddress: String { self == .local ? "127.0.0.1" : "0.0.0.0" }
}

/// 外观主题。
enum Appearance: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppConfig: Codable {
    var modelPath: String = ""
    var mmprojPath: String = ""
    var port: Int = 8686
    var contextSize: Int = 32768
    var gpuLayers: Int = 99
    var threads: Int = 0            // 0 = automatic
    var parallel: Int = 1
    var flashAttention: Bool = true
    var useFit: Bool = true
    var reasoningPreserve: Bool = true
    /// 关闭模型思考。推理模型默认先写一大段 thinking 再回答，
    /// 简单问题会白白耗掉几万 token。开启后：
    ///   · 导出 DSH 配置时注入 enable_thinking: false
    ///   · 停止传 --reasoning-preserve
    var disableThinking: Bool = false
    var routing: Routing = .local
    var apiKey: String = ""
    var requireApiKey: Bool = true
    var extraArgs: String = ""
    var autostart: Bool = false
    // 精简 DSH 工具提示词：本地模型上下文小，把重型工具组（默认 REA 逆向工具）
    // 从 DSH 里摘掉，把工具定义从 ~74K tokens 压到 ~6K。
    var leanPromptEnabled: Bool = true
    var leanDisabledGroups: [String] = ["rea"]
    /// 模型下载保存位置（留空则用建议目录）。
    var downloadDirectory: String = ""
    /// Hugging Face 下载线路。
    var hfRoute: HFRoute = .official
    /// 外观：浅色 / 深色 / 跟随系统。
    var appearance: Appearance = .light

    /// 下载目录的可选 URL 形式；空值 → 建议目录。
    var downloadDirectoryURL: URL? {
        let trimmed = downloadDirectory.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: Paths.configFile),
              let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return cfg
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Paths.configFile, options: .atomic)
        }
    }

    /// Command line for llama-server, derived strictly from these settings.
    func arguments() -> [String] {
        var args: [String] = ["-m", modelPath]
        if !mmprojPath.isEmpty {
            args += ["--mmproj", mmprojPath]
        }
        args += ["--host", routing.bindAddress, "--port", String(port)]
        args += ["-c", String(contextSize)]
        args += ["-ngl", String(gpuLayers)]
        if threads > 0 { args += ["-t", String(threads)] }
        args += ["-np", String(parallel)]
        if flashAttention { args += ["--flash-attn", "on"] }
        if !useFit { args += ["--fit", "off"] }
        if reasoningPreserve { args.append("--reasoning-preserve") }
        if requireApiKey && !apiKey.isEmpty {
            args += ["--api-key", apiKey]
        }
        args += ["--jinja"]
        if !extraArgs.isEmpty {
            args += extraArgs.split(separator: " ").map(String.init)
        }
        return args
    }
}

struct ModelEntry: Codable, Identifiable, Hashable {
    var path: String
    /// 同一组的视觉投影（mmproj）；空表示纯文本模型。
    var mmproj: String
    /// 分组名。一个模型和它的视觉投影放在同一组，便于一起导入、一起切换。
    var group: String = ""
    var id: String { path }

    /// 手写解码：老版本 models.json 没有 `group`，缺字段时用默认值而不是整条丢弃。
    enum CodingKeys: String, CodingKey { case path, mmproj, group }

    init(path: String, mmproj: String, group: String = "") {
        self.path = path
        self.mmproj = mmproj
        self.group = group
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        mmproj = (try? c.decodeIfPresent(String.self, forKey: .mmproj)) ?? ""
        group = (try? c.decodeIfPresent(String.self, forKey: .group)) ?? ""
    }

    var displayName: String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".gguf") ? String(name.dropLast(5)) : name
    }
    /// 组名回退到所在目录名，便于把同目录的模型和投影视为一组。
    var effectiveGroup: String {
        if !group.trimmingCharacters(in: .whitespaces).isEmpty { return group }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (dir as NSString).lastPathComponent
        return name.isEmpty ? "未分组" : name
    }

    var hasVision: Bool { !mmproj.isEmpty && FileManager.default.fileExists(atPath: mmproj) }

    var sizeText: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

// MARK: - Server controller

@MainActor
final class ServerController: ObservableObject {
    @Published var config: AppConfig
    @Published var models: [ModelEntry]

    @Published var isRunning = false
    @Published var statusLine = "未启动"
    @Published var logText = ""
    @Published var healthOK = false
    @Published var pid: Int32 = 0
    @Published var lastExitCode: Int32? = nil
    @Published var busyMessage: String? = nil
    /// 模型下载队列，跨标签页存活。
    let downloads = DownloadCenter()
    /// 对话会话列表。
    let chats = ChatStore()
    /// 工具组开关在界面上的镜像值；改动时同步落盘。
    @Published var groupEnabledUI: [String: Bool] = [:]
    /// App 打开时磁盘上的精简设置；用于判断是否真的被用户改过，
    /// 避免把启动时读到的旧内存值又写回磁盘。
    private(set) var leanStateAtLaunch: (enabled: Bool, groups: [String]) = (true, ["rea"])

    private var process: Process?
    private var logHandle: FileHandle?
    private let logQueue = DispatchQueue(label: "qwen.log.tail")
    private var healthTimer: Timer?
    private var logTimer: Timer?

    init() {
        Paths.prepare()
        config = AppConfig.load()
        models = ServerController.loadModels()
        if config.modelPath.isEmpty, let first = models.first {
            config.modelPath = first.path
            config.mmprojPath = first.mmproj
        }
        if config.apiKey.isEmpty {
            config.apiKey = ServerController.makeToken()
        }
        // 启动时把磁盘上的真实状态读进界面，避免两边不一致
        let disabledOnDisk = ToolGroupWriter.readDisabled()
        config.leanDisabledGroups = Array(disabledOnDisk)
        leanStateAtLaunch = (config.leanPromptEnabled, config.leanDisabledGroups)
        groupEnabledUI = groupEnabled
        tailLog()
        redetectTools()
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "qwen-" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func loadModels() -> [ModelEntry] {
        guard let data = try? Data(contentsOf: Paths.modelsFile),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        // 逐条解码：一条坏数据不该让整个列表消失。
        return raw.compactMap { dict -> ModelEntry? in
            guard let path = dict["path"] as? String, !path.isEmpty else { return nil }
            let mmproj = (dict["mmproj"] as? String) ?? ""
            let group = (dict["group"] as? String) ?? ""
            return ModelEntry(path: path, mmproj: mmproj, group: group)
        }
    }

    func persistModels() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(models) {
            try? data.write(to: Paths.modelsFile, options: .atomic)
        }
    }

    // MARK: model import

    func importModels(groupName: String = "") {
        let panel = NSOpenPanel()
        panel.title = "选择 GGUF 模型文件"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["gguf"]
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        guard panel.runModal() == .OK else { return }
        addModels(panel.urls.map(\.path), groupName: groupName)
    }

    func addModels(_ paths: [String], groupName: String = "") {
        let ggufs = paths.filter { $0.lowercased().hasSuffix(".gguf") }

        // 投影文件按目录归拢：同目录的 mmproj 会配给该目录下的每个模型。
        var projectors: [String: String] = [:]
        for path in ggufs where (path as NSString).lastPathComponent.lowercased().contains("mmproj") {
            let dir = (path as NSString).deletingLastPathComponent
            projectors[dir] = path
        }

        var added = 0
        for path in ggufs where !(path as NSString).lastPathComponent.lowercased().contains("mmproj") {
            if models.contains(where: { $0.path == path }) { continue }
            let dir = (path as NSString).deletingLastPathComponent
            let mm = projectors[dir] ?? siblingMMProj(for: path) ?? ""
            let group = groupName.isEmpty
                ? (dir as NSString).lastPathComponent
                : groupName
            models.append(ModelEntry(path: path, mmproj: mm, group: group))
            added += 1
        }

        // 只选了一个 mmproj：配给同目录已导入的模型。
        for (dir, mm) in projectors where added == 0 || ggufs.count == projectors.count {
            for i in models.indices where (models[i].path as NSString).deletingLastPathComponent == dir {
                models[i].mmproj = mm
                if !groupName.isEmpty { models[i].group = groupName }
            }
        }

        persistModels()
        if config.modelPath.isEmpty, let first = models.first {
            config.modelPath = first.path
            config.mmprojPath = first.mmproj
            config.save()
        }
    }

    /// 模型同目录下自动找 mmproj（视觉投影）。
    private func siblingMMProj(for model: String) -> String? {
        let dir = (model as NSString).deletingLastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        guard let hit = names.first(where: {
            $0.lowercased().contains("mmproj") && $0.lowercased().hasSuffix(".gguf")
        }) else { return nil }
        return dir + "/" + hit
    }

    /// 已有模型的分组改名。
    func renameGroup(_ entry: ModelEntry, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // 整组改名：同组内所有模型一起动，保持“一组一个模型 + 投影”。
        let oldGroup = entry.effectiveGroup
        for i in models.indices where models[i].effectiveGroup == oldGroup {
            models[i].group = trimmed
        }
        persistModels()
    }

    /// 全部组名（去重、排序）。
    var modelGroups: [String] {
        Array(Set(models.map(\.effectiveGroup))).sorted()
    }

    /// 按组归并后的模型列表。
    var modelsByGroup: [(group: String, entries: [ModelEntry])] {
        modelsByGroup(models)
    }

    func modelsByGroup(_ entries: [ModelEntry]) -> [(group: String, entries: [ModelEntry])] {
        Dictionary(grouping: entries, by: \.effectiveGroup)
            .sorted { $0.key < $1.key }
            .map { (group: $0.key, entries: $0.value.sorted { $0.displayName < $1.displayName }) }
    }

    /// 把刚下载的文件登记为模型（自动配对同目录的 mmproj）。
    func importDownloaded(_ task: DownloadTask) {
        guard task.state == .done, !task.message.isEmpty else { return }
        let path = task.message
        guard FileManager.default.fileExists(atPath: path) else { return }
        addModels([path])
        // 选中刚导入的那个
        if let entry = models.first(where: { $0.path == path }) { select(entry) }
    }

    func removeModel(_ entry: ModelEntry) {
        models.removeAll { $0.path == entry.path }
        if config.modelPath == entry.path {
            config.modelPath = models.first?.path ?? ""
            config.mmprojPath = models.first?.mmproj ?? ""
            config.save()
        }
        persistModels()
    }

    func select(_ entry: ModelEntry) {
        config.modelPath = entry.path
        config.mmprojPath = entry.mmproj
        config.save()
    }

    // MARK: lifecycle

    var endpoint: String { "http://127.0.0.1:\(config.port)/v1" }
    var modelID: String { config.modelPath }

    func start() {
        guard !isRunning else { return }
        guard FileManager.default.isExecutableFile(atPath: Paths.serverBin.path) else {
            statusLine = "找不到 llama-server：\(Paths.serverBin.path)"
            return
        }
        guard !config.modelPath.isEmpty, FileManager.default.fileExists(atPath: config.modelPath) else {
            statusLine = "请先在「模型」页导入并选择一个 GGUF 文件"
            return
        }
        // 启动前先清掉占着端口的残留 llama-server（App 异常退出时留下的孤儿进程）。
        let cleanup = PortGuard.sweep(port: config.port)
        if !cleanup.swept.isEmpty {
            statusLine = "已清理残留进程 \(cleanup.swept.map(String.init).joined(separator: ","))，启动中"
        }
        if !cleanup.foreign.isEmpty {
            // 端口被别人占着，我们动不了，直接说明情况而不是让用户看 code 1
            statusLine = "端口 \(config.port) 被其他程序占用：\(cleanup.foreign.first ?? "")"
            busyMessage = nil
            return
        }
        if !cleanup.ready {
            statusLine = "端口 \(config.port) 仍被占用，无法启动"
            busyMessage = nil
            return
        }

        config.save()
        busyMessage = "正在加载模型…"
        statusLine = "启动中"
        logText = ""

        let logURL = Paths.logURL(port: config.port)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: logURL) else {
            statusLine = "无法写入日志文件"
            busyMessage = nil
            return
        }
        logHandle = handle

        let proc = Process()
        proc.executableURL = Paths.serverBin
        proc.arguments = config.arguments()
        proc.currentDirectoryURL = Paths.llamaDir
        proc.standardOutput = handle
        proc.standardError = handle
        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                let code = p.terminationStatus
                self.lastExitCode = code
                self.isRunning = false
                self.healthOK = false
                self.pid = 0
                self.busyMessage = nil
                self.statusLine = code == 0 ? "已停止" : "已退出 (code \(code))，详见日志"
                self.process = nil
                self.stopTimers()
            }
        }
        do {
            try proc.run()
            process = proc
            isRunning = true
            pid = proc.processIdentifier
            statusLine = "加载中… pid \(pid)"
            startTimers()
        } catch {
            statusLine = "启动失败：\(error.localizedDescription)"
            busyMessage = nil
        }
    }

    func stop() {
        guard let proc = process else { return }
        let pid = proc.processIdentifier
        if proc.isRunning { proc.terminate() }

        // 等它自己退；不退就强杀，避免变成孤儿占着端口。
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline {
                if kill(pid, 0) != 0 { return }     // 已退出
                usleep(200_000)
            }
            kill(pid, SIGKILL)
            Task { @MainActor in
                self.isRunning = false
                self.healthOK = false
                self.pid = 0
                self.statusLine = "已强制停止"
            }
        }
    }

    func restart() {
        guard isRunning else { start(); return }
        stop()
        // wait for terminationHandler, then start again
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in self.start() }
        }
    }

    // MARK: polling

    private func startTimers() {
        stopTimers()
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tailLog() }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probeHealth() }
        }
        RunLoop.main.add(logTimer!, forMode: .common)
        RunLoop.main.add(healthTimer!, forMode: .common)
    }

    private func stopTimers() {
        healthTimer?.invalidate(); healthTimer = nil
        logTimer?.invalidate(); logTimer = nil
    }

    func tailLog() {
        let url = Paths.logURL(port: config.port)
        guard let data = try? Data(contentsOf: url) else { return }
        let slice = data.count > 400_000 ? data.suffix(400_000) : data[...]
        let text = String(decoding: slice, as: UTF8.self)
        if text != logText { logText = text }
    }

    private func probeHealth() {
        guard let url = URL(string: "http://127.0.0.1:\(config.port)/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            Task { @MainActor in
                self.healthOK = ok
                if ok {
                    if self.busyMessage != nil { self.busyMessage = nil }
                    if self.isRunning { self.statusLine = "运行中 · 端口 \(self.config.port)" }
                }
            }
        }.resume()
    }

    // MARK: helpers for UI

    // MARK: - REA 会话开关（写入插件读取的状态文件）

    // MARK: - DSH 工具组开关（写入插件读取的状态文件）

    private var toolGroupsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/tool-groups.json")
    }

    /// 自动检测到的工具组；扫描完成后填充。
    @Published var detectedGroups: [ToolGroup] = []
    @Published var detectionSource: String = "未检测"
    @Published var detectedToolCount: Int = 0
    @Published var detecting: Bool = false

    /// 重新扫描本机的 DSH 工具（会话日志 → profile 配置 → 插件包）。
    /// 把精简开关落盘到 ~/.dsh/tool-groups.json。
    /// lean=true 时只保留核心组，其余全部关闭。
    func writeToolGroups(lean: Bool) {
        let keep: Set<String> = ["core", "search", "jobs", "plan", "goals", "ask", "mcp"]
        var disabled: Set<String>
        if lean {
            disabled = Set(ToolGroupWriter.groups.map(\.id)).subtracting(keep)
        } else {
            disabled = []
        }
        do {
            let url = try ToolGroupWriter.write(disabled: disabled)
            config.leanDisabledGroups = Array(disabled)
            config.save()
            groupEnabledUI = groupEnabled
            let saved = ToolGroupWriter.savedTokens(disabled: disabled)
            statusLine = lean
                ? "已精简工具，预计省下 \(saved / 1000)K token（新会话生效）"
                : "已恢复全部工具组"
            _ = url
        } catch {
            statusLine = "写入工具组状态失败：\(error.localizedDescription)"
        }
    }

    func redetectTools() {
        detecting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let inventory = ToolDetector.detect()
            DispatchQueue.main.async {
                self.detectedGroups = inventory.groups
                self.detectionSource = inventory.source
                self.detectedToolCount = inventory.tools.count
                self.detecting = false
                self.groupEnabledUI = self.groupEnabled
                // 把检测到的组同步给插件，作为它的分组定义。
                self.publishGroupsToPlugin(inventory.groups)
            }
        }
    }

    /// 把检测结果写入 `~/.dsh/tool-groups.groups.json`，插件按名字/前缀匹配。
    private func publishGroupsToPlugin(_ groups: [ToolGroup]) {
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "groups": groups.reduce(into: [String: Any]()) { acc, group in
                acc[group.id] = ["label": group.label, "tools": group.tools, "prefixes": group.prefixes]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dsh/tool-groups.detected.json")
        try? data.write(to: url, options: .atomic)
    }

    /// 总计 token 成本。
    var totalDetectedTokens: Int { detectedGroups.reduce(0) { $0 + $1.approxTokens } }
    var enabledTokens: Int {
        detectedGroups.filter { groupEnabledUI[$0.id] ?? true }.reduce(0) { $0 + $1.approxTokens }
    }

    private func readToolGroups() -> [String: Any] {
        guard let data = try? Data(contentsOf: toolGroupsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ["groups": [String: Any](), "sessions": [String: Any]()] }
        return obj
    }

    /// 当前各组是否开启。
    var groupEnabled: [String: Bool] {
        let state = readToolGroups()
        let groups = (state["groups"] as? [String: Any]) ?? [:]
        let globalOff = (state["default"] as? String) == "off"
        var result: [String: Bool] = [:]
        for group in detectedGroups {
            let entry = groups[group.id] as? [String: Any]
            // 组内显式 off 优先，否则看全局 default；两者都缺省时视为开启。
            let offFlag: Bool
            if let explicit = entry?["off"] as? Bool { offFlag = explicit }
            else { offFlag = globalOff }
            result[group.id] = !offFlag
        }
        return result
    }

    /// 正在生效（被关闭）的组。
    var disabledGroupIDs: [String] {
        groupEnabled.filter { !$0.value }.map(\.key)
    }

    /// 勾选或取消一个组：写 `groups.<id>.off`，保留其它字段。
    func setGroup(_ id: String, enabled: Bool) {
        var state = readToolGroups()
        var groups = (state["groups"] as? [String: Any]) ?? [:]
        groups[id] = ["off": !enabled]
        state["groups"] = groups
        if state["sessions"] == nil { state["sessions"] = [String: Any]() }
        state["default"] = "on"
        guard let data = try? JSONSerialization.data(withJSONObject: state,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: toolGroupsURL, options: .atomic)
        reloadToolGroups()
    }

    /// 一次性设置多个组。
    func setGroups(_ enabled: Set<String>) {
        var state = readToolGroups()
        var groups: [String: Any] = [:]
        for group in detectedGroups { groups[group.id] = ["off": !enabled.contains(group.id)] }
        state["groups"] = groups
        if state["sessions"] == nil { state["sessions"] = [String: Any]() }
        state["default"] = "on"
        guard let data = try? JSONSerialization.data(withJSONObject: state,
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: toolGroupsURL, options: .atomic)
        reloadToolGroups()
    }

    /// 从状态文件重新载入界面镜像。
    func reloadToolGroups() {
        groupEnabledUI = groupEnabled
    }

    /// 单会话覆盖（会话 id → 关闭的组）。
    var sessionOverrides: [(String, [String])] {
        let sessions = (readToolGroups()["sessions"] as? [String: Any]) ?? [:]
        return sessions.compactMap { key, value in
            guard let entry = value as? [String: Any], let off = entry["off"] as? [String] else { return nil }
            return (key, off)
        }.sorted { $0.0 < $1.0 }
    }

    var localIPs: [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let s = String(cString: host)
                if !result.contains(s) { result.append(s) }
            }
        }
        return result
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - UI

struct ContentView: View {
    @ObservedObject var ctl: ServerController
    @State private var tab = 0

    /// 顶部胶囊标签。
    private let tabs: [(id: Int, title: String, icon: String)] = [
        (0, "模型", "shippingbox.fill"),
        (6, "对话", "bubble.left.fill"),
        (5, "下载", "arrow.down.circle.fill"),
        (1, "设置", "slider.horizontal.3"),
        (2, "访问", "antenna.radiowaves.left.and.right"),
        (3, "日志", "text.alignleft"),
        (4, "教程", "book.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider().overlay(Palette.hairline)
            Group {
                switch tab {
                case 6: ChatTab(ctl: ctl, store: ctl.chats)
                case 1: SettingsTab(ctl: ctl)
                case 2: AccessTab(ctl: ctl)
                case 3: ConsoleTab(ctl: ctl)
                case 4: TutorialTab()
                case 5: DownloadTab(ctl: ctl, downloads: ctl.downloads)
                default: ModelsTab(ctl: ctl)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(Palette.hairline)
            footer
        }
        .background(Palette.cream)
        .preferredColorScheme(ctl.config.appearance.colorScheme)
        .frame(minWidth: 780, minHeight: 600)
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 10) {
            AppLogo(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Xianzhu DSH Connect")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(ctl.config.modelPath.isEmpty
                     ? "还没有选择模型"
                     : (ctl.config.modelPath as NSString).lastPathComponent)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.inkFaint)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                StatusDot(color: ctl.healthOK ? Palette.mint
                          : (ctl.isRunning ? Palette.amber : Palette.inkFaint),
                          pulsing: ctl.healthOK)
                Text(ctl.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.inkSoft)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Palette.card, in: Capsule())
            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Palette.card.opacity(0.75))
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.id) { item in
                TabPill(title: item.title, icon: item.icon, selected: tab == item.id) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
                        tab = item.id
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Palette.card.opacity(0.55))
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                ctl.isRunning ? ctl.stop() : ctl.start()
            } label: {
                Label(ctl.isRunning ? "停止服务" : "启动服务",
                      systemImage: ctl.isRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(CandyButtonStyle())
            .disabled(ctl.config.modelPath.isEmpty)

            Button { ctl.restart() } label: {
                Label("重启", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SoftButtonStyle())
            .disabled(!ctl.isRunning)

            if let busy = ctl.busyMessage {
                TypingDots()
                Text(busy).font(.system(size: 10.5)).foregroundStyle(Palette.inkFaint)
            }

            Spacer()

            Button { ctl.copy(ctl.endpoint) } label: {
                Label(ctl.endpoint, systemImage: "doc.on.doc")
            }
            .buttonStyle(SoftButtonStyle(compact: true))
            .help("复制 OpenAI 兼容地址")

            Toggle("登录时自启", isOn: Binding(
                get: { ctl.config.autostart },
                set: {
                    ctl.config.autostart = $0
                    ctl.config.save()
                    LaunchAgent.install(enabled: $0, cfg: ctl.config)
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            .foregroundStyle(Palette.inkSoft)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Palette.card.opacity(0.75))
    }
}

/// 品牌官网。
enum Brand {
    static let site = URL(string: "https://xianzhucatmusic.xyz")!
}

/// 窗口标题栏的品牌标记：读 App 包内的图标资源，缺失时退回系统符号。
struct AppLogo: View {
    var size: CGFloat = 30
    @State private var hovering = false

    var body: some View {
        content
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .rotationEffect(.degrees(hovering ? -4 : 0), anchor: .bottom)
            .scaleEffect(hovering ? 1.08 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
            .onHover { hovering = $0 }
            .onTapGesture { NSWorkspace.shared.open(Brand.site) }
            .help("访问 xianzhucatmusic.xyz")
            .accessibilityLabel("Xianzhu DSH Connect")
    }

    private var content: some View {
        Group {
            if let image = AppLogo.bundled {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "waveform.circle")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Palette.sky)
            }
        }
    }

    static let bundled: NSImage? = {
        if let icon = NSImage(named: "AppIcon") { return icon }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return nil
    }()
}

/// 顶部胶囊标签。
struct TabPill: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .white : (hovering ? Palette.skyDeep : Palette.inkSoft))
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    selected ? AnyShapeStyle(Palette.candyGradient)
                    : (hovering ? AnyShapeStyle(Palette.skySoft)
                       : AnyShapeStyle(Color.clear))
                )
            )
            .overlay(
                Capsule().stroke(selected ? Color.clear : Palette.hairline, lineWidth: 1)
            )
            .shadow(color: Palette.sakura.opacity(selected ? 0.25 : 0),
                    radius: selected ? 5 : 0, y: 2)
            .scaleEffect(hovering && !selected ? 1.03 : 1.0)
            .animation(.easeOut(duration: 0.14), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ModelsTab: View {
    @ObservedObject var ctl: ServerController
    @State private var importGroup: String = ""
    @State private var renaming: ModelEntry? = nil
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { ctl.importModels(groupName: importGroup) } label: {
                    Label("导入模型组…", systemImage: "plus")
                }
                TextField("组名（留空则用目录名）", text: $importGroup)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .font(.system(size: 12))
                Button {
                    let panel = NSOpenPanel()
                    panel.title = "选择 mmproj 视觉投影文件（配给同组的模型）"
                    panel.allowedFileTypes = ["gguf"]
                    panel.directoryURL = URL(fileURLWithPath: "/Volumes")
                    if panel.runModal() == .OK, let url = panel.url {
                        ctl.addModels([url.path], groupName: importGroup)
                    }
                } label: { Label("导入投影", systemImage: "eye") }
                Spacer()
                Text("模型文件不会被复制，只记录路径").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Text("导入时会把同一目录下的 mmproj 自动配对给该目录的模型；也可以填组名把它们归成一组。")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            List {
                ForEach(ctl.modelsByGroup, id: \.group) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            row(entry)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(section.group).font(.system(size: 11, weight: .semibold))
                            Text("\(section.entries.count) 个模型")
                                .font(.system(size: 10)).foregroundStyle(.tertiary)
                            Spacer()
                            Button("改组名") {
                                renaming = section.entries.first
                                renameText = section.group
                            }
                            .buttonStyle(.borderless).font(.system(size: 10))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)
            .overlay {
                if ctl.models.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "shippingbox").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text("还没有导入模型").foregroundStyle(.secondary)
                        Text("点「导入模型组…」选择 .gguf 文件；同目录的 mmproj 会自动配对")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .alert("改组名", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("组名", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("确定") {
                if let entry = renaming { ctl.renameGroup(entry, to: renameText) }
                renaming = nil
            }
        } message: {
            Text("整组改名：该组内所有模型会一起改。")
        }
    }

    @ViewBuilder
    private func row(_ entry: ModelEntry) -> some View {
        let selected = entry.path == ctl.config.modelPath
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Text(entry.path).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .truncationMode(.middle).lineLimit(1)
                HStack(spacing: 8) {
                    if !entry.sizeText.isEmpty {
                        Text(entry.sizeText).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    if entry.hasVision {
                        Label((entry.mmproj as NSString).lastPathComponent, systemImage: "eye")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("纯文本").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button("删除") { ctl.removeModel(entry) }.buttonStyle(.borderless)
                .foregroundStyle(.red).font(.system(size: 11))
        }
        .contentShape(Rectangle())
        .onTapGesture { ctl.select(entry) }
        .listRowBackground(selected ? Color.accentColor.opacity(0.08) : Color.clear)
    }
}

struct SettingsTab: View {
    @ObservedObject var ctl: ServerController
    @State private var dshMessage: String? = nil
    @State private var dshError: String? = nil

    private var dshReadiness: (ok: Bool, detail: String) { DSHConfigExporter.readiness() }
    private var dshReady: Bool { dshReadiness.ok }
    private var dshReadinessDetail: String { dshReadiness.detail }

    var body: some View {
        Form {
            Section("运行参数") {
                HStack {
                    TextField("端口", value: $ctl.config.port, format: .number)
                        .frame(width: 90)
                    Text("OpenAI 兼容地址：\(ctl.endpoint)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Picker("上下文长度 (-c)", selection: $ctl.config.contextSize) {
                    ForEach([8192, 16384, 32768, 65536, 131072], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("GPU 层数 (-ngl)", selection: $ctl.config.gpuLayers) {
                    Text("全部卸载到 GPU (99)").tag(99)
                    Text("自动").tag(-1)
                    Text("仅 CPU (0)").tag(0)
                }
                Stepper("线程数：\(ctl.config.threads == 0 ? "自动" : "\(ctl.config.threads)")", value: $ctl.config.threads, in: 0...32)
                Stepper("并发槽位 (-np)：\(ctl.config.parallel)", value: $ctl.config.parallel, in: 1...8)
                Toggle("Flash Attention (-fa)", isOn: $ctl.config.flashAttention)
                Toggle("按显存自动收缩参数 (--fit)", isOn: $ctl.config.useFit)
                Toggle("保留思考内容 (--reasoning-preserve)", isOn: $ctl.config.reasoningPreserve)

                // 推理模型默认先写一大段思考再回答，简单问题也会耗掉几万 token。
                // 打开这个开关后，导出 DSH 配置时会注入 enable_thinking: false。
                // 精简工具：真正写进 DSH 的状态文件，只在新建会话时生效。
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("精简工具（关掉用不上的工具组，省下大量窗口）",
                           isOn: Binding(
                            get: { ctl.config.leanPromptEnabled },
                            set: { newValue in
                                ctl.config.leanPromptEnabled = newValue
                                ctl.config.save()
                                ctl.writeToolGroups(lean: newValue)
                            }))
                    Text("打开后只保留核心工具（文件、终端、搜索等），关掉逆向工程、音乐等重型组。\n改动只影响**新建**的会话，已有会话不受影响。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("关闭模型思考（响应更快，省 token）", isOn: $ctl.config.disableThinking)
                        .onChange(of: ctl.config.disableThinking) { _, _ in ctl.config.save() }
                    Text("推理模型会先思考再回答。关掉后像「你好」这样的简单问题直接出结果。改完需要在「导入到 DSH」里重新导入一次配置，然后重启 DSH。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if ctl.config.disableThinking {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.skyDeep)
                        Text("已关闭思考。如果模型仍先思考，说明配置还没重新导入。")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.inkSoft)
                    }
                }
            }
            Section("工具提示词：加载模型时勾选启用哪些") {
                HStack {
                    if ctl.detecting {
                        ProgressView().scaleEffect(0.6).frame(width: 16)
                        Text("正在检测本机工具…").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("检测到 \(ctl.detectedToolCount) 个工具 · 来源：\(ctl.detectionSource)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { ctl.redetectTools() } label: {
                        Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
                    }.buttonStyle(.borderless).font(.system(size: 11))
                }

                Text("勾选的组会注入模型；改动只影响新建的 DSH 会话，即时生效、无需重启。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)

                ForEach(ctl.detectedGroups) { group in
                    Toggle(isOn: Binding(
                        get: { ctl.groupEnabledUI[group.id] ?? true },
                        set: { ctl.setGroup(group.id, enabled: $0) }
                    )) {
                        HStack(spacing: 8) {
                            Text(group.label)
                            Text(group.toolCountText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(group.costText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(group.approxTokens >= 20000 ? .orange : .secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("全选") { ctl.setGroups(Set(ctl.detectedGroups.map(\.id))) }
                    Button("仅核心") { ctl.setGroups(["core"]) }
                    Button("核心 + 计划") { ctl.setGroups(["core", "plan", "skills"]) }
                    Spacer()
                    Text("预计 \(ctl.enabledTokens / 1000)K / \(ctl.totalDetectedTokens / 1000)K tokens")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))

                if !ctl.sessionOverrides.isEmpty {
                    Text("单会话覆盖：" + ctl.sessionOverrides.map { "\($0.0.prefix(8))… 关闭 [\($0.1.joined(separator: ","))]" }.joined(separator: "；"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Section("外观") {
                Picker("主题", selection: Binding(
                    get: { ctl.config.appearance },
                    set: { ctl.config.appearance = $0; ctl.config.save() }
                )) {
                    ForEach(Appearance.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("导入到 DeepSeek Harness") {
                HStack(spacing: 8) {
                    Image(systemName: dshReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(dshReady ? Palette.mint : Palette.amber)
                        .font(.system(size: 11))
                    Text(dshReady ? "配置已就绪，可以把下面的模型注册进 DSH"
                                  : dshReadinessDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.inkSoft)
                    Spacer()
                    if DSHConfigExporter.alreadyImported() {
                        CapsuleTag(text: "已导入过", tint: Palette.mint)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        do {
                            let outcome = try DSHConfigExporter.export(ctl: ctl)
                            dshMessage = "已写入 \(outcome.modelCount) 个模型路由。\n重启 DeepSeek Harness 后生效。"
                            dshError = nil
                        } catch {
                            dshError = error.localizedDescription
                            dshMessage = nil
                        }
                    } label: {
                        Label("一键导入配置", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(CandyButtonStyle())
                    .disabled(!dshReady || ctl.models.isEmpty)

                    Button("打开配置文件") {
                        NSWorkspace.shared.activateFileViewerSelecting([DSHConfigExporter.patchFile])
                    }
                    .buttonStyle(SoftButtonStyle())

                    Spacer()
                }

                Text("会把当前所有模型写进 DSH 的模型选择器。只替换本 App 管理的那一段，其他配置不动；写入前自动备份。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.inkFaint)

                if let dshError {
                    Label(dshError, systemImage: "xmark.octagon.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.coral)
                }
                if let dshMessage {
                    Label(dshMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.mint)
                }
            }

            Section("高级") {
                TextField("额外 llama-server 参数", text: $ctl.config.extraArgs, prompt: Text("例如 --temp 0.7 --top-p 0.9"))
                    .font(.system(size: 12, design: .monospaced))
                Text("修改后需「重启」服务生效。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: ctl.config.contextSize) { ctl.config.save() }
        .onChange(of: ctl.config.port) { ctl.config.save() }
        .onChange(of: ctl.config.gpuLayers) { ctl.config.save() }
        .onChange(of: ctl.config.threads) { ctl.config.save() }
        .onChange(of: ctl.config.parallel) { ctl.config.save() }
        .onChange(of: ctl.config.flashAttention) { ctl.config.save() }
        .onChange(of: ctl.config.useFit) { ctl.config.save() }
        .onChange(of: ctl.config.reasoningPreserve) { ctl.config.save() }
        .onChange(of: ctl.config.extraArgs) { ctl.config.save() }
    }
}

struct AccessTab: View {
    @ObservedObject var ctl: ServerController

    var body: some View {
        Form {
            Section("暴露范围") {
                Picker("", selection: $ctl.config.routing) {
                    ForEach(Routing.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(ctl.config.routing.hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("访问密钥") {
                Toggle("要求 Bearer 密钥 (--api-key)", isOn: $ctl.config.requireApiKey)
                HStack {
                    TextField("密钥", text: $ctl.config.apiKey)
                        .font(.system(size: 12, design: .monospaced))
                        .disabled(!ctl.config.requireApiKey)
                    Button { ctl.config.apiKey = ServerController.makeToken(); ctl.config.save() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }.help("重新生成")
                    Button { ctl.copy(ctl.config.apiKey) } label: { Image(systemName: "doc.on.doc") }
                }
            }

            Section("可用地址") {
                ForEach(ctl.localIPs, id: \.self) { ip in
                    HStack {
                        Text("http://\(ip):\(ctl.config.port)/v1")
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button { ctl.copy("http://\(ip):\(ctl.config.port)/v1") } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                    }
                }
                if ctl.localIPs.isEmpty {
                    Text("未检测到局域网地址").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            Section("公网使用") {
                Text("""
                App 只负责把服务绑到 0.0.0.0 并加 Bearer 密钥。要让外网设备访问，需在 App 之外建立隧道，二选一：
                • cloudflared tunnel --url http://127.0.0.1:\(ctl.config.port)
                • tailscale serve --bg \(ctl.config.port)
                公网暴露前请务必保留密钥，并在路由器上限制来源。
                """)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: ctl.config.routing) { ctl.config.save() }
        .onChange(of: ctl.config.requireApiKey) { ctl.config.save() }
        .onChange(of: ctl.config.apiKey) { ctl.config.save() }
    }
}

// MARK: - 教程（内置 PDF）

/// 内置教程 PDF 的阅读器：直接嵌 PDFKit，不依赖外部预览程序。
struct TutorialTab: View {
    @State private var document: PDFDocument? = nil
    @State private var pageIndex = 0
    @State private var loadError: String? = nil

    var body: some View {
        Group {
            if let document {
                VStack(spacing: 0) {
                    PDFKitView(document: document, pageIndex: $pageIndex)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    HStack(spacing: 10) {
                        Button { pageIndex = max(0, pageIndex - 1) } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(pageIndex <= 0)
                        Text("\(pageIndex + 1) / \(document.pageCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button { pageIndex = min(document.pageCount - 1, pageIndex + 1) } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(pageIndex >= document.pageCount - 1)
                        Spacer()
                        Button {
                            if let url = Self.pdfURL { NSWorkspace.shared.open(url) }
                        } label: { Label("用预览打开", systemImage: "arrow.up.forward.app") }
                        .font(.system(size: 11))
                        SpanButton { NSWorkspace.shared.open(Brand.site) }
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(loadError ?? "教程尚未内置")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("把 tutorial.pdf 放进 App 包的 Resources 即可。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    SpanButton { NSWorkspace.shared.open(Brand.site) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard document == nil else { return }
        guard let url = Self.pdfURL else {
            loadError = "App 包里找不到 tutorial.pdf"
            return
        }
        if let doc = PDFDocument(url: url) {
            document = doc
        } else {
            loadError = "无法读取 \(url.lastPathComponent)"
        }
    }

    static var pdfURL: URL? {
        Bundle.main.url(forResource: "tutorial", withExtension: "pdf")
    }
}

/// 包一层 PDFView：自动缩放页面宽度，滚动。
struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = NSColor.textBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        guard let page = document.page(at: pageIndex), view.currentPage !== page else { return }
        view.go(to: page)
    }
}

/// 品牌网站入口按钮。
struct SpanButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("xianzhucatmusic.xyz", systemImage: "globe")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
    }
}

struct ConsoleTab: View {
    @ObservedObject var ctl: ServerController
    @State private var stickToBottom = true

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("日志 · \(Paths.logURL(port: ctl.config.port).lastPathComponent)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("跟随末尾", isOn: $stickToBottom).toggleStyle(.checkbox).font(.system(size: 11))
                Button { ctl.logText = "" } label: { Label("清屏", systemImage: "eraser") }.buttonStyle(.borderless).font(.system(size: 11))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(ctl.logText.isEmpty ? "（暂无输出）" : ctl.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: ctl.logText) {
                    if stickToBottom { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
            }
        }
        .padding(14)
    }
}

// MARK: - LaunchAgent (login autostart)

enum LaunchAgent {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.xianzhu.dshconnect.plist")
    }

    static func install(enabled: Bool, cfg: AppConfig) {
        let fm = FileManager.default
        if !enabled {
            if fm.fileExists(atPath: plistURL.path) {
                _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["unload", plistURL.path])
                try? fm.removeItem(at: plistURL)
            }
            return
        }
        try? fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let appPath = Bundle.main.bundlePath
        guard let bin = Bundle.main.executablePath else { return }
        var args = ["--autostart"]
        if !cfg.modelPath.isEmpty { args += ["--model", cfg.modelPath] }
        args += ["--port", String(cfg.port), "--ctx", String(cfg.contextSize)]
        let argXML = args.map { "<string>\($0)</string>" }.joined(separator: "\n        ")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>com.xianzhu.dshconnect</string>
          <key>ProgramArguments</key>
          <array>
            <string>\(bin)</string>
            \(argXML)
          </array>
          <key>RunAtLoad</key><true/>
          <key>WorkingDirectory</key><string>\(appPath)</string>
          <key>StandardOutPath</key><string>\(Paths.logsDir.path)/agent.log</string>
          <key>StandardErrorPath</key><string>\(Paths.logsDir.path)/agent.err.log</string>
        </dict>
        </plist>
        """
        try? plist.write(to: plistURL, atomically: true, encoding: .utf8)
        _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"), arguments: ["load", "-w", plistURL.path])
    }
}

// MARK: - App entry

@main
struct XianzhuDSHConnectApp: App {
    @StateObject private var ctl = ServerController()

    init() {
        Paths.prepare()
        // ---- headless control paths (used by tooling) ----
        let args = CommandLine.arguments
        if args.contains("--selftest") {
            print("llama-server: \(Paths.serverBin.path)")
            print("exists: \(FileManager.default.isExecutableFile(atPath: Paths.serverBin.path))")
            var cfg = AppConfig.load()
            if let i = args.firstIndex(of: "--model"), i + 1 < args.count { cfg.modelPath = args[i + 1] }
            print("args: \(cfg.arguments().joined(separator: " "))")
            exit(0)
        }
        var boot = AppConfig.load()
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { boot.modelPath = args[i + 1] }
        if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = Int(args[i + 1]) { boot.port = p }
        if let i = args.firstIndex(of: "--ctx"), i + 1 < args.count, let c = Int(args[i + 1]) { boot.contextSize = c }
        if args.contains("--autostart") {
            boot.autostart = true
            boot.save()
            let cfg = boot
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NotificationCenter.default.post(name: .xianzhuAutostart, object: cfg)
            }
        } else if args.contains("--model") || args.contains("--port") {
            boot.save()
        }
    }

    var body: some Scene {
        WindowGroup("Xianzhu DSH Connect") {
            ContentView(ctl: ctl)
                .onAppear {
                    ctl.config = AppConfig.load()
                    if ctl.config.modelPath.isEmpty, let first = ctl.models.first {
                        ctl.config.modelPath = first.path
                        ctl.config.mmprojPath = first.mmproj
                    }
                    if ctl.config.autostart || CommandLine.arguments.contains("--autostart") {
                        ctl.start()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .xianzhuAutostart)) { _ in
                    ctl.start()
                }
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Xianzhu DSH Connect") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            }
        }
    }
}

extension Notification.Name {
    static let xianzhuAutostart = Notification.Name("xianzhu.dshconnect.autostart")
}
