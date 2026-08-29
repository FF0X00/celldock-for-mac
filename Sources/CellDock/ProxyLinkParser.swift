import Foundation

/// 解析后的代理链接
struct ParsedProxyLink: Equatable {
    var scheme: String
    var name: String
    var host: String
    var port: UInt16
    var username: String?
    var password: String?
    var parameters: [String: String]

    /// 认证 base64 原串（hysteria2 链接 userinfo 部分）
    var rawAuthentication: String?
    /// 原始链接（去首尾空白）
    var rawLink: String
}

/// 代理链接解析器：支持 hysteria2://、socks5://、socks5h://、http://、https://
enum ProxyLinkParser {
    static func parse(_ rawLink: String) -> ParsedProxyLink? {
        let link = rawLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let components = URLComponents(string: link) else { return nil }
        guard let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let port = components.port, port > 0 else { return nil }
        guard ["hysteria2", "socks5", "socks5h", "http", "https"].contains(scheme) else { return nil }

        var username = components.user
        var password = components.password
        var rawAuthentication: String?
        if scheme == "hysteria2", let auth = components.user {
            rawAuthentication = auth
            // hysteria2 惯例：userinfo 为 base64(用户名:密码)，解码失败则视为明文用户名
            if let data = Data(base64Encoded: auth),
               let decoded = String(data: data, encoding: .utf8),
               !decoded.isEmpty {
                let parts = decoded.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    username = String(parts[0])
                    password = String(parts[1])
                } else {
                    username = decoded
                    password = nil
                }
            } else if auth.isEmpty {
                username = nil
            }
        }

        var parameters: [String: String] = [:]
        if let items = components.queryItems {
            for item in items {
                if let value = item.value {
                    parameters[item.name] = value
                }
            }
        }

        let fragment = components.fragment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = fragment.isEmpty ? "\(scheme)-\(host)" : fragment

        return ParsedProxyLink(
            scheme: scheme,
            name: name,
            host: host,
            port: UInt16(port),
            username: username,
            password: password,
            parameters: parameters,
            rawAuthentication: rawAuthentication,
            rawLink: link
        )
    }
}
