//
//  ChatTab.swift — 内置对话页：不离开这个 App 就能和本地模型聊几句。
//
//  走的是 llama-server 的 OpenAI 兼容接口（/v1/chat/completions，流式 SSE）。
//  目的是「验证模型能不能用」和「快速试一句」，不是取代 DSH 的完整工作台。
//

import AppKit
import SwiftUI

// MARK: - 消息模型

struct ChatMessage: Identifiable, Equatable {
    enum Role: String { case user, assistant, system }
    let id = UUID()
    var role: Role
    var text: String
    /// 思考过程（Qwen 的 reasoning_content），单独存以便折叠展示。
    var thinking: String = ""
    var isStreaming = false
    var error: String? = nil
}

// MARK: - 会话控制器

@MainActor
final class ChatSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var input: String = ""
    @Published var busy = false
    @Published var useThinking = false
    @Published var temperature: Double = 0.7
    @Published var maxTokens: Int = 2048

    private var streamTask: Task<Void, Never>?
    private var persistTick = 0
    private var currentStream: URLSessionDataTask?
    private var baseURL: URL = URL(string: "http://127.0.0.1:8686/v1")!
    private var modelName: String = "local"

    func configure(baseURL: String, model: String) {
        if let url = URL(string: baseURL.hasSuffix("/v1") ? baseURL : baseURL + "/v1") {
            self.baseURL = url
        }
        self.modelName = model
    }

    var canSend: Bool { !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 切换/新建会话时重置内存态。
    func reset(messages newMessages: [ChatMessage] = []) {
        streamTask?.cancel()
        streamTask = nil
        currentStream?.cancel()
        busy = false
        messages = newMessages
    }

    /// 每次流式更新后通知外部持久化。
    var onPersist: ((_ messages: [ChatMessage]) -> Void)? = nil

    private func notifyPersist() {
        onPersist?(messages)
    }

    /// 发送当前输入。
    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: "", isStreaming: true))
        busy = true

        notifyPersist()
        streamTask = Task { [weak self] in
            await self?.run(messages: self?.messages ?? [])
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        currentStream?.cancel()
        finishStreaming()
        busy = false
    }

    private func finishStreaming() {
        if let idx = messages.lastIndex(where: { $0.isStreaming }) {
            messages[idx].isStreaming = false
        }
    }

    /// 真正的网络请求：把历史按 OpenAI 格式发出去，逐块接收。
    private func run(messages history: [ChatMessage]) async {
        defer {
            busy = false
            finishStreaming()
            streamTask = nil
            notifyPersist()
        }

        // 只发完成的对话，跳过占位的空助手消息。
        var payload: [[String: Any]] = []
        for m in history where !m.isStreaming {
            let role: String
            switch m.role {
            case .user: role = "user"
            case .assistant: role = "assistant"
            case .system: role = "system"
            }
            if role == "assistant" && m.text.isEmpty { continue }
            payload.append(["role": role, "content": m.text])
        }

        var body: [String: Any] = [
            "model": modelName,
            "messages": payload,
            "stream": true,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "chat_template_kwargs": ["enable_thinking": useThinking],
        ]
        // 关闭思考时也明确给个上限，避免模型自言自语太久。
        if !useThinking { body["max_tokens"] = maxTokens }

        guard let url = URL(string: "\(baseURL.absoluteString)/chat/completions"),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            fail("请求构造失败"); return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer local", forHTTPHeaderField: "Authorization")
        request.httpBody = data
        request.timeoutInterval = 300

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { fail("没有响应"); return }
            guard http.statusCode == 200 else {
                // 读一下错误体，转成可读提示。
                var detail = ""
                for try await line in bytes.lines.prefix(20) { detail += line }
                fail(friendly(error: detail, status: http.statusCode))
                return
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard line.hasPrefix("data:") else { continue }
                let chunk = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if chunk == "[DONE]" { break }
                guard let json = try? JSONSerialization.jsonObject(with: Data(chunk.utf8)) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any] else { continue }

                if let piece = delta["content"] as? String, !piece.isEmpty {
                    append(text: piece, isThinking: false)
                }
                if let think = delta["reasoning_content"] as? String, !think.isEmpty {
                    append(text: think, isThinking: true)
                }
            }
        } catch is CancellationError {
            // 用户点了停止
        } catch {
            if (error as NSError).code != NSURLErrorCancelled {
                fail(friendly(error: error.localizedDescription, status: 0))
            }
        }
    }

    private func append(text piece: String, isThinking: Bool) {
        guard let idx = messages.lastIndex(where: { $0.isStreaming }) else { return }
        if isThinking {
            messages[idx].thinking += piece
        } else {
            messages[idx].text += piece
        }
        // 节流：每 12 个块存一次，避免频繁写盘。
        persistTick += 1
        if persistTick % 12 == 0 { notifyPersist() }
    }

    private func fail(_ message: String) {
        guard let idx = messages.lastIndex(where: { $0.isStreaming }) else {
            messages.append(ChatMessage(role: .assistant, text: "", error: message))
            return
        }
        messages[idx].error = message
        messages[idx].isStreaming = false
    }

    /// 把服务端错误翻译成用户能懂的话。
    private func friendly(error raw: String, status: Int) -> String {
        let lower = raw.lowercased()
        if lower.contains("exceed_context_size") || lower.contains("context size") {
            return "上下文不够了。点上方「新对话」清空历史，或者到设置里调大上下文长度。"
        }
        if lower.contains("image input is not supported") {
            return "这个模型不支持读图。"
        }
        if status == 0 {
            return "连接不上模型服务。确认 App 底部显示「运行中」，端口是 8686。\n\n\(raw)"
        }
        return "服务返回 \(status)：\(raw.prefix(300))"
    }
}

// MARK: - 对话页

struct ChatTab: View {
    @ObservedObject var ctl: ServerController
    @ObservedObject var store: ChatStore
    @StateObject private var chat = ChatSession()
    @FocusState private var inputFocused: Bool
    @State private var renamingID: UUID? = nil
    @State private var renameText = ""
    @State private var confirmingDelete: UUID? = nil

    var body: some View {
        HSplitView {
            sidebar
            conversation
        }
        .onAppear {
            syncRoute()
            store.ensureSelected()
            loadSelected()
            chat.onPersist = { messages in save(messages) }
        }
        .onChange(of: ctl.config.modelPath) { syncRoute() }
        .onChange(of: ctl.config.port) { syncRoute() }
        .onChange(of: store.selectedID) { loadSelected() }
        .alert("重命名会话", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("标题", text: $renameText)
            Button("取消", role: .cancel) { renamingID = nil }
            Button("确定") {
                if let id = renamingID { store.rename(id, to: renameText) }
                renamingID = nil
            }
        }
        .alert("删除这个会话？", isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { confirmingDelete = nil }
            Button("删除", role: .destructive) {
                if let id = confirmingDelete {
                    store.delete(id)
                    loadSelected()
                }
                confirmingDelete = nil
            }
        } message: {
            Text("会话记录会被永久删除，无法恢复。")
        }
    }

    // MARK: 会话切换与保存

    private func syncRoute() {
        chat.configure(baseURL: "http://127.0.0.1:\(ctl.config.port)",
                       model: ctl.config.modelPath)
    }

    /// 把选中会话的历史装进内存。
    private func loadSelected() {
        guard let stored = store.selected else {
            chat.reset()
            return
        }
        let restored = stored.messages.map { message -> ChatMessage in
            ChatMessage(role: message.role == "user" ? .user : .assistant,
                        text: message.text,
                        thinking: message.thinking)
        }
        chat.reset(messages: restored)
    }

    /// 把内存历史写回选中会话。
    private func save(_ messages: [ChatMessage]) {
        guard var stored = store.selected else { return }
        stored.messages = messages
            .filter { !$0.isStreaming && $0.error == nil }
            .compactMap { message in
                guard message.role != .system else { return nil }
                guard !message.text.isEmpty || !message.thinking.isEmpty else { return nil }
                return StoredMessage(role: message.role == .user ? "user" : "assistant",
                                     text: message.text,
                                     thinking: message.thinking)
            }
        store.update(stored, retitle: stored.title == "新对话")
    }

    private func newChat() {
        store.create()
        loadSelected()
        inputFocused = true
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { newChat() } label: {
                    Label("新建", systemImage: "square.and.pencil")
                        .font(.system(size: 11.5))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CandyButtonStyle(compact: true))
                .keyboardShortcut("n", modifiers: [.command])
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            if store.chats.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(.tertiary)
                    Text("还没有会话").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { store.selectedID },
                    set: { if let id = $0 { store.selectedID = id } }
                )) {
                    ForEach(store.chats) { item in
                        chatRow(item)
                            .tag(item.id)
                            .contextMenu {
                                Button("重命名…") {
                                    renamingID = item.id
                                    renameText = item.title
                                }
                                Divider()
                                Button("删除", role: .destructive) { confirmingDelete = item.id }
                            }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 178, idealWidth: 200, maxWidth: 260)
        .background(Palette.cream)
    }

    private func chatRow(_ item: StoredChat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(item.timeText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if !item.preview.isEmpty {
                Text(item.preview)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: 对话区

    private var conversation: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            composer
        }
    }

    // MARK: 顶部

    private var toolbar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(ctl.healthOK ? Color.green : (ctl.isRunning ? Color.orange : Color.gray))
                .frame(width: 8, height: 8)
            Text(ctl.healthOK ? "已连接" : (ctl.isRunning ? "加载中…" : "服务未启动"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if !ctl.healthOK {
                Button("启动服务") { ctl.start() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }

            Spacer()

            Toggle("深度思考", isOn: $chat.useThinking)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("开启后模型会先推理再回答，更准但更慢")

            Stepper("温度 \(String(format: "%.1f", chat.temperature))",
                    value: $chat.temperature, in: 0...1.5, step: 0.1)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: 消息区

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.messages.isEmpty { emptyState }
                    ForEach(chat.messages) { message in
                        bubble(message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: chat.messages.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(ctl.healthOK ? "想聊点什么？试试下面这些～" : "先去「模型」页启动服务哦")
                .font(.system(size: 12))
                .foregroundStyle(Palette.inkSoft)
            if ctl.healthOK {
                HStack(spacing: 8) {
                    ForEach(["你好，你是什么模型？", "用一句话解释什么是 token", "写一个快速排序"],
                            id: \.self) { sample in
                        Button(sample) {
                            chat.input = sample
                            chat.send()
                        }
                        .buttonStyle(SoftButtonStyle(compact: true))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 8) {
                Spacer(minLength: 50)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Palette.sakuraSoft)
                    .clipShape(RoundedRectangle(cornerRadius: Shape_.bubbleRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Shape_.bubbleRadius, style: .continuous)
                            .stroke(Palette.sakura.opacity(0.55), lineWidth: 1)
                    )
                Avatar(isUser: true)
            }
        case .assistant, .system:
            HStack(alignment: .top, spacing: 8) {
            Avatar(isUser: false)
            VStack(alignment: .leading, spacing: 6) {
                if !message.thinking.isEmpty {
                    ThinkingBlock(text: message.thinking, streaming: message.isStreaming)
                }
                if let error = message.error {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                        Text(error).font(.system(size: 11.5)).textSelection(.enabled)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if !message.text.isEmpty {
                    MarkdownText(message.text)
                }
                if message.isStreaming && message.text.isEmpty && message.thinking.isEmpty {
                    TypingDots()
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card)
            .clipShape(RoundedRectangle(cornerRadius: Shape_.bubbleRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Shape_.bubbleRadius, style: .continuous)
                    .stroke(Palette.hairline, lineWidth: 1)
            )
            Spacer(minLength: 30)
            }
        }
    }

    // MARK: 输入区

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("和本地模型聊两句…", text: $chat.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { if chat.canSend { chat.send() } }
                    .cuteField(focused: inputFocused)

                if chat.busy {
                    Button { chat.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.system(size: 24))
                            .foregroundStyle(Palette.coral)
                    }
                    .buttonStyle(.plain)
                    .help("停止生成")
                } else {
                    Button { chat.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                            .foregroundStyle(chat.canSend ? Palette.sakuraDeep : Palette.inkFaint)
                    }
                    .buttonStyle(.plain)
                    .disabled(!chat.canSend)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("发送（⌘↩）")
                }
            }
            HStack {
                Text("这条对话只在本机模型里跑，不会发到任何服务器。")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if !ctl.healthOK {
                    Text("需要先启动服务").font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - 对话页

// MARK: - 头像

/// 对话头像：用户用粉色圆点，AI 用小猫图标。
struct Avatar: View {
    let isUser: Bool

    var body: some View {
        Group {
            if isUser {
                Circle()
                    .fill(Palette.sakura.opacity(0.35))
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.sakuraDeep)
                    )
            } else if let icon = AppLogo.bundled {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Palette.skySoft)
                    .overlay(
                        Image(systemName: "cat.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.skyDeep)
                    )
            }
        }
        .frame(width: 26, height: 26)
        .overlay(Circle().stroke(Palette.hairline, lineWidth: 1))
    }
}

// MARK: - 思考过程折叠块

struct ThinkingBlock: View {
    let text: String
    let streaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                    Text(streaming ? "正在思考…" : "思考过程")
                        .font(.system(size: 10.5))
                    Text("\(text.count) 字").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)

            if expanded {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

// MARK: - 极简 Markdown 渲染

/// 只处理最常用的几种：标题、代码块、行内代码、列表、粗体。
struct MarkdownText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code, let lang):
                    CodeBlock(code: code, language: lang)
                case .text(let line):
                    Text(attributed(line))
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block {
        case text(String)
        case code(String, String?)
    }

    /// 把文本切成「代码块」和「普通段落」。
    private var blocks: [Block] {
        var result: [Block] = []
        var buffer: [String] = []
        var inCode = false
        var codeLines: [String] = []
        var language: String? = nil

        func flushText() {
            if !buffer.isEmpty {
                result.append(.text(buffer.joined(separator: "\n")))
                buffer.removeAll()
            }
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("```") {
                if inCode {
                    result.append(.code(codeLines.joined(separator: "\n"), language))
                    codeLines.removeAll()
                    inCode = false
                    language = nil
                } else {
                    flushText()
                    inCode = true
                    let tag = s.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                }
                continue
            }
            if inCode { codeLines.append(s) } else { buffer.append(s) }
        }
        if inCode { result.append(.code(codeLines.joined(separator: "\n"), language)) }
        flushText()
        return result
    }

    /// 行内粗体与行内代码。
    private func attributed(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while !rest.isEmpty {
            if let boldStart = rest.range(of: "**") {
                let before = rest[..<boldStart.lowerBound]
                out += AttributedString(String(before))
                let after = rest[boldStart.upperBound...]
                if let boldEnd = after.range(of: "**") {
                    var piece = AttributedString(String(after[..<boldEnd.lowerBound]))
                    piece.font = .system(size: 12.5, weight: .semibold)
                    out += piece
                    rest = after[boldEnd.upperBound...]
                } else {
                    out += AttributedString("**" + String(after))
                    rest = Substring("")
                }
            } else {
                out += AttributedString(String(rest))
                rest = Substring("")
            }
        }
        return out
    }
}

/// 代码块：等宽字体 + 背景 + 复制按钮。
struct CodeBlock: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9.5))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.09))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
            }
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
    }
}
