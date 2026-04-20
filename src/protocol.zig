//! Windows pixiv:// 协议处理器模块
//! 通过注册自定义 URI 协议实现 OAuth 登录回调。
//!
//! 工作原理:
//!   1. registerProtocol() — 通过 reg add 注册 pixiv:// 自定义 URI 协议
//!   2. unregisterProtocol() — 通过 reg delete 移除协议注册
//!   3. startReceiver() — 启动临时 localhost TCP 服务器（随机端口），等待回调
//!   4. waitForCode() — 从 HTTP 请求中提取 code 参数
//!   5. sendCode() — 将 pixiv:// URL 中的 code 转发给 receiver
//!
//! 仅 Windows 上有实际效果，其他平台返回 error.NotSupported。

const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;

const SelfPathError = error{
    SelfPathFailed,
};

/// 注册 pixiv:// 协议到 Windows 注册表
/// 非Windows平台返回 error.NotSupported
pub fn registerProtocol(allocator: std.mem.Allocator, io: std.Io) !void {
    if (builtin.os.tag != .windows) return error.NotSupported;

    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);

    const key = "HKCU\\Software\\Classes\\pixiv";
    const argv = &.{
        "reg",
        "add",
        key,
        "/ve",
        "/d",
        "URL:pixiv Protocol",
        "/f",
    };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .create_no_window = true,
    }) catch return error.RegistryOperationFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const argv_icon = &.{
        "reg",
        "add",
        key,
        "/v",
        "URL Protocol",
        "/d",
        "",
        "/f",
    };
    const result2 = std.process.run(allocator, io, .{
        .argv = argv_icon,
        .create_no_window = true,
    }) catch return error.RegistryOperationFailed;
    defer allocator.free(result2.stdout);
    defer allocator.free(result2.stderr);

    const argv_cmd = &.{
        "reg",
        "add",
        key ++ "\\shell\\open\\command",
        "/ve",
        "/d",
        try std.fmt.allocPrint(allocator, "\"{s}\" --protocol-callback \"%1\"", .{self_path}),
        "/f",
    };
    defer allocator.free(argv_cmd[6]);
    const result3 = std.process.run(allocator, io, .{
        .argv = argv_cmd,
        .create_no_window = true,
    }) catch return error.RegistryOperationFailed;
    defer allocator.free(result3.stdout);
    defer allocator.free(result3.stderr);
}

/// 移除 pixiv:// 协议注册
/// 非Windows平台返回 error.NotSupported
pub fn unregisterProtocol(allocator: std.mem.Allocator, io: std.Io) !void {
    if (builtin.os.tag != .windows) return error.NotSupported;

    const key = "HKCU\\Software\\Classes\\pixiv";
    const argv = &.{
        "reg",
        "delete",
        key,
        "/f",
    };
    const result = std.process.run(allocator, io, .{
        .argv = argv,
        .create_no_window = true,
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
}

/// 回调接收器，封装 TCP 服务器和客户端连接
pub const Receiver = struct {
    server: net.Server,
    port: u16,
};

/// 启动 TCP 监听服务器，绑定 127.0.0.1:0（随机端口）
/// 返回 Receiver，包含 server 实例和分配到的端口号
/// 调用者负责调用 receiver.server.deinit(io) 释放资源
pub fn startReceiver(io: std.Io) !Receiver {
    if (builtin.os.tag != .windows) return error.NotSupported;

    var addr: net.IpAddress = .{ .ip4 = .loopback(0) };
    const server = try net.IpAddress.listen(&addr, io, .{});
    const port = server.socket.address.getPort();
    return .{ .server = server, .port = port };
}

/// 等待客户端连接，读取 HTTP 请求并从中提取 code 参数
/// 返回的 code 字符串由 allocator 分配，需要调用者释放
pub fn waitForCode(allocator: std.mem.Allocator, io: std.Io, receiver: *Receiver) ![]const u8 {
    var accept_buf: [4096]u8 = undefined;
    const stream = receiver.server.accept(io) catch |err| {
        return switch (err) {
            error.ConnectionAborted => error.CallbackFailed,
            else => err,
        };
    };
    defer stream.close(io);

    var reader = stream.reader(io, &accept_buf);

    // 读取 HTTP 请求行（GET /?code=xxx HTTP/1.1）
    var req_buf: [8192]u8 = undefined;
    var req_writer = std.Io.Writer.fixed(&req_buf);
    // 读取直到遇到 \r\n\r\n（HTTP 请求头结束）
    while (true) {
        const byte = reader.interface.readByte() catch return error.CallbackFailed;
        req_writer.writeByte(byte) catch return error.CallbackFailed;
        const written = req_writer.buffered();
        if (written.len >= 4) {
            const tail = written[written.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) break;
        }
        if (written.len >= req_buf.len) return error.CallbackFailed;
    }

    const request = req_writer.buffered();

    // 发送 HTTP 200 响应，让浏览器显示"登录成功"
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n<html><body><h1>Login successful</h1><p>You can close this tab now.</p></body></html>";
    var send_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &send_buf);
    writer.interface.writeAll(response) catch {};
    writer.interface.flush() catch {};

    // 从请求行提取 code
    const code = extractCodeFromRequest(request) orelse return error.CallbackFailed;
    return allocator.dupe(u8, code);
}

/// 从 HTTP 请求中提取 code 参数值
fn extractCodeFromRequest(request: []const u8) ?[]const u8 {
    // 找到 GET 行
    const get_start = std.mem.indexOf(u8, request, "GET ") orelse return null;
    const path_start = get_start + 4;

    // 找到 code= 参数
    const code_prefix = "code=";
    const code_start = std.mem.indexOfPos(u8, request, path_start, code_prefix) orelse return null;
    const value_start = code_start + code_prefix.len;

    // code 值截止到下一个 & 或空格或 HTTP 版本
    var value_end = value_start;
    while (value_end < request.len) : (value_end += 1) {
        const ch = request[value_end];
        if (ch == '&' or ch == ' ' or ch == '\r' or ch == '\n') break;
    }

    const code = request[value_start..value_end];
    if (code.len == 0) return null;
    return code;
}

/// 将 pixiv:// URL 中的 code 转发给本地 receiver
/// 由协议处理器（即本程序自身通过 --protocol-callback 参数）调用
pub fn sendCode(allocator: std.mem.Allocator, io: std.Io, port: u16, url: []const u8) !void {
    if (builtin.os.tag != .windows) return error.NotSupported;

    const code = extractCodeFromUrl(url) orelse return error.InvalidCallbackUrl;

    // 构造转发 URL
    const forward_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/?code={s}", .{ port, code });
    defer allocator.free(forward_url);

    // 连接到本地 receiver 并发送 HTTP GET
    var addr: net.IpAddress = .{ .ip4 = .loopback(port) };
    const stream = try net.IpAddress.connect(&addr, io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    var send_buf: [4096]u8 = undefined;
    var writer = stream.writer(io, &send_buf);
    try writer.interface.print("GET /?code={s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{ code, port });
    try writer.interface.flush();

    // 读取响应（不关心内容，只是为了确保发送完成）
    var recv_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    _ = reader.interface.readByte() catch {};
}

/// 从 pixiv:// URL 中提取 code 参数
fn extractCodeFromUrl(url: []const u8) ?[]const u8 {
    const code_prefix = "code=";
    const code_start = std.mem.indexOf(u8, url, code_prefix) orelse return null;
    const value_start = code_start + code_prefix.len;

    var value_end = value_start;
    while (value_end < url.len) : (value_end += 1) {
        const ch = url[value_end];
        if (ch == '&' or ch == ' ' or ch == '\r' or ch == '\n') break;
    }

    const code = url[value_start..value_end];
    if (code.len == 0) return null;
    return code;
}

test "extractCodeFromRequest" {
    const req = "GET /?code=abc123def HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n";
    const code = extractCodeFromRequest(req).?;
    try std.testing.expectEqualStrings("abc123def", code);
}

test "extractCodeFromUrl" {
    const url = "pixiv://login?code=test_code_123&state=xyz";
    const code = extractCodeFromUrl(url).?;
    try std.testing.expectEqualStrings("test_code_123", code);
}

test "extractCodeFromUrl no code" {
    const url = "pixiv://login?error=denied";
    try std.testing.expect(extractCodeFromUrl(url) == null);
}

test "extractCodeFromRequest no code" {
    const req = "GET /?error=denied HTTP/1.1\r\n\r\n";
    try std.testing.expect(extractCodeFromRequest(req) == null);
}
