//
//  ChatStore.swift — 本地会话的持久化与管理。
//
//  每个会话是一个 JSON 文件，存在：
//    ~/Library/Application Support/XianzhuDSHConnect/chats/<uuid>.json
//  这样重启 App 后历史还在，删除会话也只是删掉对应文件。
//

import Foundation
import SwiftUI

/// 一个会话的持久化结构。
struct StoredChat: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String = "新对话"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var messages: [StoredMessage] = []

    /// 列表里显示的时间。
    var timeText: String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(updatedAt) {
            f.dateFormat = "HH:mm"
            return f.string(from: updatedAt)
        }
        if cal.isDateInYesterday(updatedAt) {
            return "昨天"
        }
        f.dateFormat = "M月d日"
        return f.string(from: updatedAt)
    }

    var preview: String {
        messages.last(where: { $0.role == "assistant" && !$0.text.isEmpty })?.text
            ?? messages.last?.text ?? ""
    }
}

/// 消息的持久化结构（只存必要字段）。
struct StoredMessage: Codable, Equatable {
    var role: String          // user / assistant
    var text: String
    var thinking: String = ""
}

// MARK: - 会话管理

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var chats: [StoredChat] = []
    @Published var selectedID: UUID? = nil

    private let directory: URL

    init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/XianzhuDSHConnect", isDirectory: true)
        directory = base.appendingPathComponent("chats", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    var selected: StoredChat? {
        guard let selectedID else { return nil }
        return chats.first { $0.id == selectedID }
    }

    /// 当前会话，没有就建一个。
    @discardableResult
    func ensureSelected() -> StoredChat {
        if let current = selected { return current }
        return create()
    }

    @discardableResult
    func create() -> StoredChat {
        let chat = StoredChat(title: "新对话")
        chats.insert(chat, at: 0)
        selectedID = chat.id
        persist(chat)
        return chat
    }

    func delete(_ id: UUID) {
        chats.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: fileURL(id))
        if selectedID == id {
            selectedID = chats.first?.id
        }
    }

    func deleteAll() {
        for chat in chats {
            try? FileManager.default.removeItem(at: fileURL(chat.id))
        }
        chats.removeAll()
        selectedID = nil
    }

    /// 更新一个会话（消息变化、标题变化）。
    func update(_ chat: StoredChat, retitle: Bool = false) {
        guard let idx = chats.firstIndex(where: { $0.id == chat.id }) else { return }
        var updated = chat
        updated.updatedAt = Date()

        // 第一次有用户消息时，用它的前若干字作为标题。
        if retitle || updated.title == "新对话" {
            if let first = updated.messages.first(where: { $0.role == "user" })?.text,
               !first.isEmpty {
                updated.title = String(first.prefix(24)).replacingOccurrences(of: "\n", with: " ")
            }
        }
        chats[idx] = updated
        chats.sort { $0.updatedAt > $1.updatedAt }
        persist(updated)
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let idx = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[idx].title = trimmed
        persist(chats[idx])
    }

    // MARK: 磁盘

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ chat: StoredChat) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(chat) {
            try? data.write(to: fileURL(chat.id), options: .atomic)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        var loaded: [StoredChat] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let chat = try? decoder.decode(StoredChat.self, from: data) else { continue }
            loaded.append(chat)
        }
        chats = loaded.sorted { $0.updatedAt > $1.updatedAt }
        selectedID = chats.first?.id
    }
}
