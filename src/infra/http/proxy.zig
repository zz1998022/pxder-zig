//! 代理配置模块
//! 支持 HTTP/HTTPS CONNECT 和 SOCKS4/4a/5/5h 代理协议。
//!
//! 代理格式: [protocol://][user:pass@]host:port
//! 特殊值: 空字符串 = 使用系统代理, "disable" = 禁用代理
//!
//! HTTP/HTTPS 代理通过 std.http.Client 内置的 CONNECT 隧道支持。
//! SOCKS5 代理需要手动建立 TCP 连接后进行握手。

const std = @import("std");

/// 支持的代理类型
pub const ProxyType = enum {
    http,
    https,
    socks4,
    socks4a,
    socks5,
    socks5h,
};

/// 解析后的代理配置
pub const ProxyConfig = struct {
    proxy_type: ProxyType,
    host: []const u8,
    port: u16,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// 检查代理字符串格式是否合法
/// 接受: 空字符串、"disable"、http(s)://、socks4/4a/5/5h:// 前缀
pub fn checkProxyFormat(proxy_str: []const u8) bool {
    if (proxy_str.len == 0) return true;
    if (std.mem.eql(u8, proxy_str, "disable")) return true;

    const prefixes = .{
        "http://",
        "https://",
        "socks4://",
        "socks4a://",
        "socks5://",
        "socks5h://",
    };
    inline for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, proxy_str, prefix)) return true;
    }
    return false;
}

/// 从环境变量映射表中检测系统代理设置
/// 依次检查: all_proxy, ALL_PROXY, https_proxy, HTTPS_PROXY, http_proxy, HTTP_PROXY
pub fn fromEnv(environ_map: *std.process.Environ.Map) ?ProxyConfig {
    const env_vars = .{
        "all_proxy",
        "ALL_PROXY",
        "https_proxy",
        "HTTPS_PROXY",
        "http_proxy",
        "HTTP_PROXY",
    };
    inline for (env_vars) |var_name| {
        if (environ_map.get(var_name)) |val| {
            if (val.len > 0) {
                return parse(val) catch null;
            }
        }
    }
    return null;
}

/// 解析代理字符串为 ProxyConfig
/// 格式: protocol://[user:pass@]host:port
pub fn parse(proxy_str: []const u8) !ProxyConfig {
    // 提取协议类型和剩余部分
    const type_and_rest = blk: {
        const entries = .{
            .{ "http://", ProxyType.http },
            .{ "https://", ProxyType.https },
            .{ "socks4://", ProxyType.socks4 },
            .{ "socks4a://", ProxyType.socks4a },
            .{ "socks5://", ProxyType.socks5 },
            .{ "socks5h://", ProxyType.socks5h },
        };
        inline for (entries) |entry| {
            if (std.mem.startsWith(u8, proxy_str, entry[0])) {
                break :blk .{ entry[1], proxy_str[entry[0].len..] };
            }
        }
        return error.InvalidProxyFormat;
    };

    const ptype = type_and_rest[0];
    var rest = type_and_rest[1];

    var host: []const u8 = undefined;
    var port: u16 = 0;
    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    // 提取可选的认证信息 [user:pass@]
    if (std.mem.indexOfScalar(u8, rest, '@')) |at_idx| {
        const auth_part = rest[0..at_idx];
        rest = rest[at_idx + 1 ..];
        if (std.mem.indexOfScalar(u8, auth_part, ':')) |colon_idx| {
            username = auth_part[0..colon_idx];
            password = auth_part[colon_idx + 1 ..];
        } else {
            username = auth_part;
        }
    }

    // 提取主机和端口 host:port
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon_idx| {
        host = rest[0..colon_idx];
        port = std.fmt.parseInt(u16, rest[colon_idx + 1 ..], 10) catch return error.InvalidProxyPort;
    } else {
        return error.InvalidProxyFormat;
    }

    return ProxyConfig{
        .proxy_type = ptype,
        .host = host,
        .port = port,
        .username = username,
        .password = password,
    };
}

test "parse http proxy" {
    const cfg = try parse("http://127.0.0.1:1080");
    try std.testing.expectEqual(ProxyType.http, cfg.proxy_type);
    try std.testing.expectEqualStrings("127.0.0.1", cfg.host);
    try std.testing.expectEqual(@as(u16, 1080), cfg.port);
}

test "parse socks5 with auth" {
    const cfg = try parse("socks5://user:pass@10.0.0.1:9050");
    try std.testing.expectEqual(ProxyType.socks5, cfg.proxy_type);
    try std.testing.expectEqualStrings("10.0.0.1", cfg.host);
    try std.testing.expectEqual(@as(u16, 9050), cfg.port);
    try std.testing.expectEqualStrings("user", cfg.username.?);
    try std.testing.expectEqualStrings("pass", cfg.password.?);
}

test "checkProxyFormat valid" {
    try std.testing.expect(checkProxyFormat(""));
    try std.testing.expect(checkProxyFormat("disable"));
    try std.testing.expect(checkProxyFormat("http://127.0.0.1:1080"));
    try std.testing.expect(checkProxyFormat("socks5://host:9050"));
}

test "checkProxyFormat invalid" {
    try std.testing.expect(!checkProxyFormat("ftp://bad"));
    try std.testing.expect(!checkProxyFormat("random"));
}
