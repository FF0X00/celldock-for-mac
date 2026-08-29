import Foundation

/// 为 hysteria2 上游代理条目运行独立的 mihomo 子进程，
/// 在 127.0.0.1 上暴露 SOCKS5（含 UDP ASSOCIATE），供 VoWiFi runtime 使用。
///
/// VoWiFi runtime 只认 SOCKS5 上游；hysteria2 是 QUIC 传输协议，无法直接使用。
/// 这里借用已安装的 Clash Verge mihomo 内核，为每个启用的 hysteria2 条目生成
/// 一份最小配置（global 模式 + 单节点），并启动独立实例监听随机本地端口。
@MainActor
final class Hysteria2ProxyService {
    static let shared = Hysteria2ProxyService()

    private struct RunningInstance {
        let process: Process
        let port: UInt16
        let directory: URL
    }

    private var instances: [UUID: RunningInstance] = [:]

    private init() {}

    /// 条目对应的本地 SOCKS5 端口（未运行返回 nil）
    func localPort(for id: UUID) -> UInt16? {
        instances[id]?.port
    }

    /// 根据存储配置启停 hysteria2 实例
    func sync(with configurations: [VoWiFiUpstreamProxyConfiguration]) {
        let desired = Set(
            configurations.filter { $0.isHysteria2 && $0.isEnabled }.map(\.id)
        )
        for id in instances.keys where !desired.contains(id) {
            stop(id)
        }
        for configuration in configurations
        where desired.contains(configuration.id) && instances[configuration.id] == nil {
            start(configuration)
        }
    }

    /// app 退出时清理全部子进程
    func stopAll() {
        for id in instances.keys { stop(id) }
    }

    // MARK: - 私有

    private func start(_ configuration: VoWiFiUpstreamProxyConfiguration) {
        guard configuration.isHysteria2,
              let link = configuration.link,
              let parsed = ProxyLinkParser.parse(link),
              parsed.scheme == "hysteria2",
              let port = Self.allocatePort(),
              let mihomoURL = Self.mihomoBinaryURL else { return }

        let directory = Self.supportDirectory
            .appendingPathComponent(configuration.id.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return
        }
        // ⚠️ verge-mihomo 定制版忽略 -f/-d 配置（还会把目录内 config.yaml 覆盖为默认），
        // 必须用 -config 传入 base64 内联配置；数据目录经 currentDirectory 隔离。
        let yaml = Self.mihomoConfiguration(for: parsed, localPort: port)
        guard let encoded = yaml.data(using: .utf8)?.base64EncodedString() else { return }

        let process = Process()
        process.executableURL = mihomoURL
        process.arguments = ["-config", encoded]
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return
        }
        instances[configuration.id] = RunningInstance(
            process: process,
            port: port,
            directory: directory
        )
    }

    private func stop(_ id: UUID) {
        guard let instance = instances.removeValue(forKey: id) else { return }
        if instance.process.isRunning {
            instance.process.terminate()
        }
        // 给 mihomo 一点优雅退出的时间，然后清理配置目录
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            try? FileManager.default.removeItem(at: instance.directory)
        }
    }

    // MARK: - 配置生成

    private static func mihomoConfiguration(
        for parsed: ParsedProxyLink,
        localPort: UInt16
    ) -> String {
        var nodeLines: [String] = [
            "  - name: hy2",
            "    type: hysteria2",
            "    server: \"\(parsed.host)\"",
            "    port: \(parsed.port)",
        ]
        if let username = parsed.username, !username.isEmpty,
           let password = parsed.password {
            nodeLines.append("    username: \"\(username)\"")
            nodeLines.append("    password: \"\(password)\"")
        } else if let rawAuth = parsed.rawAuthentication, !rawAuth.isEmpty {
            nodeLines.append("    password: \"\(rawAuth)\"")
        }
        let sni = parsed.parameters["sni"] ?? parsed.host
        nodeLines.append("    sni: \"\(sni)\"")
        let insecure = parsed.parameters["insecure"] == "1"
            || parsed.parameters["insecure"] == "true"
        nodeLines.append("    skip-cert-verify: \(insecure)")

        return """
        mixed-port: \(localPort)
        bind-address: 127.0.0.1
        allow-lan: false
        mode: global
        log-level: silent
        ipv6: false
        proxies:
        \(nodeLines.joined(separator: "\n"))
        rules:
          - MATCH,hy2

        """
    }

    // MARK: - 环境

    private static var mihomoBinaryURL: URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo"),
            URL(fileURLWithPath: "/Applications/Clash Verge Rev.app/Contents/MacOS/verge-mihomo"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("CellDock/mihomo", isDirectory: true)
    }

    /// 分配一个空闲本地端口（bind 0 探测后立即释放；竞态可接受）
    private static func allocatePort() -> UInt16? {
        var socketDescriptor: Int32 = -1
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return nil }
        defer { Darwin.close(socketDescriptor) }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard Darwin.getsockname(
            socketDescriptor,
            withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } },
            &length
        ) == 0 else { return nil }
        return UInt16(bigEndian: bound.sin_port)
    }
}
