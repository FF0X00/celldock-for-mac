import Foundation
import Security

// MARK: - Bot Token 钥匙串存取（与 VoWiFi 凭据同模式）

private enum TelegramSMSForwarderCredentialStore {
    static let service = "app.celldock.mac.sms-telegram"
    static let account = "bot-token"

    static func token() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: "app.celldock.mac.sms-telegram", code: Int(status))
        }
        return String(data: data, encoding: .utf8)
    }

    static func setToken(_ token: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else {
            throw NSError(domain: "app.celldock.mac.sms-telegram", code: Int(updated))
        }
        let status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "app.celldock.mac.sms-telegram", code: Int(status))
        }
    }

    static func deleteToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// MARK: - 短信 → Telegram 转发器

/// 收到新短信时通过 Telegram Bot API 推送到指定聊天。
/// 配置存 UserDefaults（开关 + chatID），Bot Token 存钥匙串。
@MainActor
final class TelegramSMSForwarder: ObservableObject {
    static let shared = TelegramSMSForwarder()

    static let enabledDefaultsKey = "SMSForwardingEnabled.v1"
    static let chatIDDefaultsKey = "SMSForwardingChatID.v1"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var chatID: String
    @Published private(set) var lastError: String?
    @Published private(set) var isSending = false
    @Published private(set) var lastDeliveredAt: Date?

    /// 进程内已转发消息 id（防重，防止同一消息被重复推送）
    private var forwardedIDs: Set<String> = []
    private let session: URLSession

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        chatID = UserDefaults.standard.string(forKey: Self.chatIDDefaultsKey) ?? ""
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration)
    }

    var botToken: String? {
        (try? TelegramSMSForwarderCredentialStore.token())?.nilIfEmpty
    }

    var isFullyConfigured: Bool {
        isEnabled && botToken != nil && !chatID.isEmpty
    }

    // MARK: 配置

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    func setChatID(_ chatID: String) {
        let trimmed = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self.chatID != trimmed else { return }
        self.chatID = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.chatIDDefaultsKey)
    }

    func setBotToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            TelegramSMSForwarderCredentialStore.deleteToken()
            return
        }
        try TelegramSMSForwarderCredentialStore.setToken(trimmed)
    }

    func clearBotToken() {
        TelegramSMSForwarderCredentialStore.deleteToken()
    }

    // MARK: 转发

    /// 转发新到短信（调用方在收到新消息时调用；内部去重）
    func forward(_ messages: [SMSMessage], moduleDisplayNames: [CellularModuleID: String] = [:]) {
        guard isFullyConfigured else { return }
        for message in messages {
            guard !forwardedIDs.contains(message.id) else { continue }
            forwardedIDs.insert(message.id)
            send(message, moduleDisplayNames: moduleDisplayNames)
        }
    }

    /// 发送测试消息（立即反馈结果，用于设置页验证）
    func sendTestMessage(completion: (@MainActor (Result<Void, Error>) -> Void)? = nil) {
        guard botToken != nil, !chatID.isEmpty else {
            completion?(.failure(ForwardingError.notConfigured))
            return
        }
        let testMessage = SMSMessage(
            id: "telegram-test-\(UUID().uuidString)",
            moduleID: nil,
            modemIndices: [],
            modemStorage: nil,
            modemReferences: nil,
            sender: "CellDock",
            body: "这是一条测试消息，短信转发功能正常 ✅",
            timestamp: Date(),
            rawPDUs: [],
            isRead: true,
            readAt: nil,
            firstSeenAt: Date(),
            direction: nil,
            deliveryState: nil,
            deliveryDetail: nil
        )
        send(testMessage) { result in
            completion?(result)
        }
    }

    // MARK: 内部

    private func send(_ message: SMSMessage, moduleDisplayNames: [CellularModuleID: String] = [:]) {
        send(message, moduleDisplayNames: moduleDisplayNames) { _ in }
    }

    private func send(_ message: SMSMessage, moduleDisplayNames: [CellularModuleID: String] = [:], completion: @escaping (Result<Void, Error>) -> Void) {
        guard let token = botToken, !chatID.isEmpty else {
            lastError = "未配置 Bot Token 或 Chat ID"
            completion(.failure(ForwardingError.notConfigured))
            return
        }
        let text = TelegramSMSForwarderFormatter.format(message, moduleDisplayNames: moduleDisplayNames)
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            lastError = "URL 构造失败"
            completion(.failure(ForwardingError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": chatID,
            "text": text,
            "disable_web_page_preview": true,
        ])

        isSending = true
        session.dataTask(with: request) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self else { return }
                self.isSending = false
                if let error {
                    self.lastError = error.localizedDescription
                    completion(.failure(error))
                    return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    self.lastError = nil
                    self.lastDeliveredAt = Date()
                    completion(.success(()))
                } else {
                    let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let detail = TelegramAPIErrorDetail.parse(body)
                    let message = "Telegram API \(status)\(detail)"
                    self.lastError = message
                    completion(.failure(ForwardingError.api(status: status, detail: detail)))
                }
            }
        }.resume()
    }

    // MARK: 文本格式（可测试）

}

/// 短信 → Telegram 文本格式化（非隔离，便于自测）
enum TelegramSMSForwarderFormatter {
    static func format(_ message: SMSMessage, moduleDisplayNames: [CellularModuleID: String] = [:]) -> String {
        let date = Self.dateFormatter.string(from: message.timestamp)
        var lines: [String] = []
        lines.append("📩 新短信")
        if let module = message.moduleID {
            let name = moduleDisplayNames[module] ?? module.rawValue
            lines.append("模块: \(name)")
        }
        lines.append("发件人: \(message.sender.isEmpty ? "未知" : message.sender)")
        lines.append("时间: \(date)")
        lines.append("内容:")
        lines.append(message.body.isEmpty ? "（空）" : message.body)
        return lines.joined(separator: "\n")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

// MARK: - 错误

enum ForwardingError: LocalizedError {
    case notConfigured
    case invalidURL
    case api(status: Int, detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "未配置 Bot Token 或 Chat ID"
        case .invalidURL:
            return "无法构造请求地址"
        case .api(let status, let detail):
            return "Telegram API 返回 \(status)\(detail)"
        }
    }
}

private struct TelegramAPIErrorDetail {
    static func parse(_ body: String) -> String {
        guard
            let data = body.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let description = json["description"] as? String
        else { return "" }
        return "（\(description)）"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
