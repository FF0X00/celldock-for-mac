import SwiftUI

struct VoWiFiUpstreamProxyManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: VoWiFiController
    @ObservedObject private var store: VoWiFiUpstreamProxyStore
    @State private var editing: VoWiFiUpstreamProxyConfiguration?
    @State private var localError: String?
    @State private var showingLinkSheet = false

    init(controller: VoWiFiController) {
        self.controller = controller
        store = controller.upstreamStore
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.configurations.isEmpty {
                    ContentUnavailableView(
                        L10n.tr("没有上游代理"),
                        systemImage: "network.badge.shield.half.filled",
                        description: Text(verbatim: L10n.tr("添加支持 UDP ASSOCIATE 的 SOCKS5 代理。"))
                    )
                } else {
                    List(store.configurations) { configuration in
                        row(configuration)
                    }
                }
            }
            .navigationTitle(L10n.tr("VoWiFi 上游代理"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("完成")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .newDraft() } label: {
                        Label(L10n.tr("添加代理"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("VoWiFiAddUpstreamProxy")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingLinkSheet = true } label: {
                        Label(L10n.tr("从链接添加"), systemImage: "link")
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 430)
        .sheet(item: $editing) { configuration in
            VoWiFiUpstreamProxyEditorView(
                configuration: configuration,
                existingPassword: store.password(for: configuration.id),
                onSave: { updated, password in
                    do {
                        try store.save(updated, password: password)
                        editing = nil
                    } catch {
                        localError = error.localizedDescription
                    }
                }
            )
        }
        .sheet(isPresented: $showingLinkSheet) {
            VoWiFiUpstreamProxyLinkSheetView { parsed, password in
                let configuration = VoWiFiUpstreamProxyConfiguration(
                    id: UUID(),
                    name: parsed.name,
                    host: parsed.host,
                    port: parsed.port,
                    isEnabled: true,
                    authentication: (parsed.username != nil || parsed.password != nil)
                        ? .usernamePassword(username: parsed.username ?? "")
                        : .none,
                    transport: parsed.scheme == "hysteria2" ? "hysteria2" : nil,
                    link: parsed.scheme == "hysteria2" ? parsed.rawLink : nil
                )
                do {
                    try store.save(configuration, password: parsed.password)
                    showingLinkSheet = false
                } catch {
                    localError = error.localizedDescription
                }
            }
        }
        .alert(L10n.tr("无法保存代理"), isPresented: Binding(
            get: { localError != nil },
            set: { if !$0 { localError = nil } }
        )) {
            Button(L10n.tr("好"), role: .cancel) {}
        } message: {
            Text(verbatim: localError ?? "")
        }
    }

    private func row(_ configuration: VoWiFiUpstreamProxyConfiguration) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(configuration.isEnabled ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: configuration.name.isEmpty ? configuration.endpointDescription : configuration.name)
                        .font(.headline)
                    if configuration.isHysteria2 {
                        Text("hysteria2")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(verbatim: configuration.endpointDescription)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                probeLabel(configuration.id)
            }
            Spacer()
            Button(L10n.tr("测试")) { controller.probeUpstream(configuration.id) }
                .disabled(!configuration.isEnabled || isProbing(configuration.id))
                .accessibilityIdentifier("VoWiFiProbeUpstream")
            Button(L10n.tr("编辑")) { editing = configuration }
            Button(role: .destructive) {
                do { try store.delete(configuration.id) }
                catch { localError = error.localizedDescription }
            } label: {
                Image(systemName: "trash")
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private func probeLabel(_ id: UUID) -> some View {
        switch store.probeStates[id] ?? .idle {
        case .idle:
            EmptyView()
        case .probing:
            Text(verbatim: L10n.tr("正在验证 TCP、认证与 UDP ASSOCIATE…"))
                .foregroundStyle(.secondary)
        case .succeeded:
            Text(verbatim: L10n.tr("连接测试通过"))
                .foregroundStyle(.green)
        case let .failed(reason):
            Text(verbatim: reason).foregroundStyle(.red).lineLimit(2)
        }
    }

    private func isProbing(_ id: UUID) -> Bool {
        if case .probing = store.probeStates[id] { return true }
        return false
    }
}

/// 粘贴代理链接（hysteria2://、socks5://、http:// 等）直接添加
private struct VoWiFiUpstreamProxyLinkSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var linkText = ""
    let onAdd: (ParsedProxyLink, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("代理链接")) {
                    TextField("hysteria2://…", text: $linkText, axis: .vertical)
                        .lineLimit(3...6)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("VoWiFiProxyLinkInput")
                }
                if let parsed = parsedLink {
                    Section(L10n.tr("解析结果")) {
                        LabeledContent(L10n.tr("类型"), value: parsed.scheme)
                        LabeledContent(L10n.tr("名称"), value: parsed.name)
                        LabeledContent(L10n.tr("服务器"), value: "\(parsed.host):\(parsed.port)")
                        if let username = parsed.username, !username.isEmpty {
                            LabeledContent(L10n.tr("用户名"), value: username)
                        }
                        if parsed.scheme == "hysteria2" {
                            Text(L10n.tr("hysteria2 将通过本机 mihomo 转换为 SOCKS5 使用"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if !linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L10n.tr("无法解析该链接，请检查格式（支持 hysteria2://、socks5://、http://）"))
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.tr("从链接添加"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("添加"), action: add)
                        .disabled(parsedLink == nil)
                }
            }
        }
        .frame(width: 520, height: 430)
    }

    private var parsedLink: ParsedProxyLink? {
        ProxyLinkParser.parse(linkText)
    }

    private func add() {
        guard let parsed = parsedLink else { return }
        onAdd(parsed, parsed.password)
    }
}

private struct VoWiFiUpstreamProxyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: VoWiFiUpstreamProxyConfiguration
    @State private var port: String
    @State private var usesAuthentication: Bool
    @State private var username: String
    @State private var password: String
    @State private var validationError: String?
    let onSave: (VoWiFiUpstreamProxyConfiguration, String?) -> Void

    init(
        configuration: VoWiFiUpstreamProxyConfiguration,
        existingPassword: String?,
        onSave: @escaping (VoWiFiUpstreamProxyConfiguration, String?) -> Void
    ) {
        _configuration = State(initialValue: configuration)
        _port = State(initialValue: String(configuration.port))
        if case let .usernamePassword(value) = configuration.authentication {
            _usesAuthentication = State(initialValue: true)
            _username = State(initialValue: value)
        } else {
            _usesAuthentication = State(initialValue: false)
            _username = State(initialValue: "")
        }
        _password = State(initialValue: existingPassword ?? "")
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.tr("服务器")) {
                    TextField(L10n.tr("名称"), text: $configuration.name)
                        .accessibilityIdentifier("VoWiFiProxyName")
                    TextField(L10n.tr("主机名或 IP 地址"), text: $configuration.host)
                        .accessibilityIdentifier("VoWiFiProxyHost")
                    TextField(L10n.tr("端口"), text: $port)
                        .accessibilityIdentifier("VoWiFiProxyPort")
                    Toggle(L10n.tr("启用此代理"), isOn: $configuration.isEnabled)
                }
                Section(L10n.tr("认证")) {
                    Toggle(L10n.tr("用户名和密码"), isOn: $usesAuthentication)
                    if usesAuthentication {
                        TextField(L10n.tr("用户名"), text: $username)
                            .accessibilityIdentifier("VoWiFiProxyUsername")
                        SecureField(L10n.tr("密码"), text: $password)
                            .accessibilityIdentifier("VoWiFiProxyPassword")
                    }
                }
                if let validationError {
                    Text(verbatim: validationError).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.tr("SOCKS5 上游代理"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("保存"), action: save)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("VoWiFiSaveUpstreamProxy")
                }
            }
        }
        .frame(width: 520, height: 430)
    }

    private func save() {
        let trimmedHost = configuration.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = configuration.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, let value = UInt16(port), value > 0 else {
            validationError = L10n.tr("请输入有效的主机和端口。")
            return
        }
        if usesAuthentication && (username.isEmpty || password.isEmpty) {
            validationError = L10n.tr("请输入用户名和密码。")
            return
        }
        configuration.host = trimmedHost
        configuration.name = trimmedName.isEmpty ? trimmedHost : trimmedName
        configuration.port = value
        configuration.authentication = usesAuthentication
            ? .usernamePassword(username: username)
            : .none
        onSave(configuration, usesAuthentication ? password : nil)
    }
}
