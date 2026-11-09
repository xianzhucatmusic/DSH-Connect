//
//  DownloadTab.swift — 在 App 内浏览 Hugging Face 并下载 GGUF 模型。
//

import AppKit
import SwiftUI

// MARK: - 下载任务

@MainActor
final class DownloadTask: ObservableObject, Identifiable {
    let id = UUID()
    let repo: String
    let file: String
    /// 常驻目录（`models`）；用户选的是「保存到哪」，实际文件进该目录里的模型文件夹。
    let directory: URL

    @Published var received: Int64 = 0
    @Published var expected: Int64? = nil
    @Published var state: State = .waiting
    @Published var message: String = ""

    enum State { case waiting, running, done, failed, cancelled }

    private var job: Task<Void, Never>?

    init(repo: String, file: String, directory: URL) {
        self.repo = repo
        self.file = file
        self.directory = directory
    }

    var progress: Double {
        guard let expected, expected > 0 else { return 0 }
        return min(Double(received) / Double(expected), 1)
    }

    var progressText: String {
        let got = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        if let expected {
            let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            return "\(got) / \(total)"
        }
        return got
    }

    func start(route: HFRoute) {
        guard state != .running else { return }
        state = .running
        message = ""
        job = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await HuggingFace.download(
                    repo: repo, file: file, into: directory, route: route
                ) { got, total in
                    Task { @MainActor in
                        self.received = got
                        self.expected = total
                    }
                }
                self.state = .done
                self.message = url.path
            } catch is CancellationError {
                self.state = .cancelled
            } catch {
                self.state = .failed
                self.message = error.localizedDescription
            }
        }
    }

    func cancel() {
        job?.cancel()
        job = nil
        if state == .running { state = .cancelled }
    }
}

// MARK: - 下载页

struct DownloadTab: View {
    @ObservedObject var ctl: ServerController
    @ObservedObject var downloads: DownloadCenter

    @State private var query = ""
    @State private var repos: [HFRepo] = []
    @State private var selected: HFRepo? = nil
    @State private var files: [HFFile] = []
    @State private var searching = false
    @State private var loadingFiles = false
    @State private var errorText: String? = nil
    @State private var saveDirectory: URL = HuggingFace.suggestedDirectory
    @State private var didLoadDefault = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HSplitView {
                repoColumn
                fileColumn
            }
            .frame(minHeight: 200)
            if !downloads.tasks.isEmpty {
                Divider()
                downloadList
            }
        }
        .onAppear {
            if !didLoadDefault {
                didLoadDefault = true
                saveDirectory = ctl.config.downloadDirectoryURL ?? HuggingFace.suggestedDirectory
                Task { await runSearch() }
            }
        }
    }

    // MARK: 搜索

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索模型仓库，例如 qwen、llama、gguf", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { Task { await runSearch() } }
            if searching { ProgressView().scaleEffect(0.55).frame(width: 14) }
            Button("搜索") { Task { await runSearch() } }
                .disabled(searching)
            Divider().frame(height: 16)
            Picker("线路", selection: Binding(
                get: { ctl.config.hfRoute },
                set: { ctl.config.hfRoute = $0; ctl.config.save() }
            )) {
                ForEach(HFRoute.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func runSearch() async {
        searching = true
        errorText = nil
        defer { searching = false }
        do {
            repos = try await HuggingFace.search(query)
            if selected == nil, let first = repos.first {
                await pick(first)
            }
        } catch {
            errorText = "搜索失败：\(error.localizedDescription)"
            repos = []
        }
    }

    private func pick(_ repo: HFRepo) async {
        selected = repo
        files = []
        loadingFiles = true
        errorText = nil
        defer { loadingFiles = false }
        do {
            files = try await HuggingFace.files(in: repo.id)
            if files.isEmpty { errorText = "这个仓库里没有 GGUF 文件" }
        } catch {
            errorText = "读取文件列表失败：\(error.localizedDescription)"
        }
    }

    // MARK: 仓库列表

    private var repoColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("搜索结果").font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(repos.count) 个仓库").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            List(repos, selection: Binding(
                get: { selected?.id },
                set: { id in
                    guard let id, let repo = repos.first(where: { $0.id == id }) else { return }
                    Task { await pick(repo) }
                }
            )) { repo in
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.id).font(.system(size: 12)).lineLimit(2)
                    Text(formatted(repo.downloads) + " 次下载 · ♥ \(repo.likes)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .tag(repo.id)
                .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 240, idealWidth: 280)
    }

    private func formatted(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
        : n >= 1000 ? String(format: "%.1fK", Double(n) / 1000)
        : "\(n)"
    }

    // MARK: 文件列表

    private var fileColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let selected {
                    Text(selected.id).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                } else {
                    Text("选择左边的仓库").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if loadingFiles { ProgressView().scaleEffect(0.5).frame(width: 12) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            if let errorText {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorText).font(.system(size: 11))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }

            directoryBar

            List(files) { file in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(file.name).font(.system(size: 12)).lineLimit(1)
                            if file.isMMProj {
                                Text("视觉投影").font(.system(size: 9))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.pink.opacity(0.18))
                                    .clipShape(Capsule())
                            } else if let q = file.quant {
                                Text(q).font(.system(size: 9, design: .monospaced))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(file.sizeText).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let task = downloads.tasks.first(where: {
                        $0.repo == selected?.id && $0.file == file.name
                    }) {
                        downloadBadge(task)
                    } else {
                        Button {
                            guard let repo = selected else { return }
                            downloads.add(repo: repo.id, file: file.name,
                                          directory: saveDirectory,
                                          route: ctl.config.hfRoute)
                        } label: {
                            Label("下载", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                    }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset)
        }
        .frame(minWidth: 320)
    }

    private var directoryBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(saveDirectory.path)
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.secondary)
            Spacer()
            Button("选择…") { chooseDirectory() }
                .buttonStyle(.borderless).font(.system(size: 10.5))
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择模型保存位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url
            ctl.config.downloadDirectory = url.path
            ctl.config.save()
        }
    }

    @ViewBuilder
    private func downloadBadge(_ task: DownloadTask) -> some View {
        HStack(spacing: 6) {
            switch task.state {
            case .waiting, .running:
                ProgressView(value: task.progress).frame(width: 70)
                Text(task.progressText).font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button { task.cancel() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
            case .done:
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.green)
                Button("导入") { ctl.importDownloaded(task) }
                    .buttonStyle(.borderless).font(.system(size: 10.5))
            case .failed:
                Label("失败", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.red)
                Button("重试") { task.start(route: ctl.config.hfRoute) }
                    .buttonStyle(.borderless).font(.system(size: 10.5))
            case .cancelled:
                Text("已取消").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Button("继续") { task.start(route: ctl.config.hfRoute) }
                    .buttonStyle(.borderless).font(.system(size: 10.5))
            }
        }
    }

    // MARK: 下载队列

    private var downloadList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("下载队列").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("清除已完成") { downloads.clearFinished() }
                    .buttonStyle(.borderless).font(.system(size: 10.5))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(downloads.tasks) { task in
                        HStack(spacing: 8) {
                            Text(task.file).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            downloadBadge(task)
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: 110)
        }
    }
}

/// 跨标签页存活的下载队列。
@MainActor
final class DownloadCenter: ObservableObject {
    @Published var tasks: [DownloadTask] = []
    private var route: HFRoute = .official

    func add(repo: String, file: String, directory: URL, route: HFRoute) {
        self.route = route
        let task = DownloadTask(repo: repo, file: file, directory: directory)
        tasks.append(task)
        task.start(route: route)
    }

    func clearFinished() {
        tasks.removeAll { $0.state == .done || $0.state == .cancelled }
    }
}
