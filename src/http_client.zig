//! HTTP 客户端封装模块
//! 基于 std.http.Client 封装 HTTPS 请求，支持 HTTP/HTTPS CONNECT 代理。
//!
//! 代理支持:
//!   - HTTP CONNECT 隧道: 手动建立 CONNECT 隧道 + TLS 升级
//!     （std.http.Client 的内置 CONNECT 代理在 Zig 0.16 中缺少 TLS 升级）
//!   - SOCKS5: 暂未实现
//!
//! 使用方式:
//!   var client = try HttpClient.init(allocator, io, proxy_config);
//!   defer client.deinit();
//!   var resp = try client.get("https://example.com", &.{});
//!   defer resp.deinit();

const std = @import("std");
const proxy = @import("proxy.zig");
const terminal = @import("terminal.zig");

/// HTTP 响应，包含状态码和响应体
pub const HttpResponse = struct {
    status: std.http.Status,
    body: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *const HttpResponse) void {
        self.allocator.free(self.body);
    }
};

/// HTTP 客户端，封装 std.http.Client 并提供代理支持
pub const HttpClient = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    _proxy_ptr: ?*std.http.Client.Proxy = null,
    _proxy_host: ?[]const u8 = null,
    _proxy_auth: ?[]const u8 = null,
    _proxy_config: ?proxy.ProxyConfig = null,
    /// 系统证书缓存（手动 CONNECT 隧道用）
    _ca_bundle_loaded: bool = false,


    pub fn init(allocator: std.mem.Allocator, io: std.Io, proxy_config: ?proxy.ProxyConfig) !HttpClient {
        var self: HttpClient = .{
            .allocator = allocator,
            .client = .{
                .allocator = allocator,
                .io = io,
            },
        };
        errdefer self.deinit();

        if (proxy_config) |pc| {
            self._proxy_config = pc;
            switch (pc.proxy_type) {
                .http, .https => {
                    try self.setupHttpProxy(&pc);
                },
                .socks5, .socks5h => {},
                else => {},
            }
        }

        return self;
    }

    fn setupHttpProxy(self: *HttpClient, pc: *const proxy.ProxyConfig) !void {
        const host_bytes = try self.allocator.dupe(u8, pc.host);
        errdefer self.allocator.free(host_bytes);

        var auth_str: ?[]const u8 = null;
        if (pc.username) |user| {
            const pass = pc.password orelse "";
            const cred = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ user, pass });
            errdefer self.allocator.free(cred);
            const encoded_len = std.base64.standard.Encoder.calcSize(cred.len);
            const buf = try self.allocator.alloc(u8, "Basic ".len + encoded_len);
            errdefer self.allocator.free(buf);
            @memcpy(buf[0.."Basic ".len], "Basic ");
            _ = std.base64.standard.Encoder.encode(buf["Basic ".len..], cred);
            self.allocator.free(cred);
            auth_str = buf;
        }
        errdefer if (auth_str) |a| self.allocator.free(a);

        const proxy_ptr = try self.allocator.create(std.http.Client.Proxy);
        errdefer self.allocator.destroy(proxy_ptr);

        proxy_ptr.* = .{
            .protocol = .plain,
            .host = .{ .bytes = host_bytes },
            .authorization = auth_str,
            .port = pc.port,
            .supports_connect = true,
        };

        self._proxy_ptr = proxy_ptr;
        self._proxy_host = host_bytes;
        self._proxy_auth = auth_str;
        // 只设 http_proxy 用于 HTTP 请求; HTTPS 走手动 CONNECT+TLS
        self.client.http_proxy = proxy_ptr;
    }

    pub fn deinit(self: *HttpClient) void {
        self.client.http_proxy = null;
        self.client.https_proxy = null;
        self.client.deinit();
        if (self._proxy_host) |h| self.allocator.free(h);
        if (self._proxy_auth) |a| self.allocator.free(a);
        if (self._proxy_ptr) |p| self.allocator.destroy(p);
    }

    pub fn get(self: *HttpClient, url: []const u8, extra_headers: []const std.http.Header) !HttpResponse {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        if (isHttpsProxied(uri, self._proxy_config)) {
            return self.tunnelRequest(.GET, uri, null, null, extra_headers);
        }
        var req = try self.client.request(.GET, uri, .{ .extra_headers = extra_headers });
        defer req.deinit();
        try req.sendBodiless();
        var buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&buf);
        return self.readResponseBody(&response);
    }

    pub fn post(self: *HttpClient, url: []const u8, body: []const u8, extra_headers: []const std.http.Header) !HttpResponse {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        if (isHttpsProxied(uri, self._proxy_config)) {
            return self.tunnelRequest(.POST, uri, body, "application/x-www-form-urlencoded", extra_headers);
        }
        var req = try self.client.request(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = "application/x-www-form-urlencoded" } },
            .extra_headers = extra_headers,
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(@constCast(body));
        var buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&buf);
        return self.readResponseBody(&response);
    }

    pub fn postWithContentType(self: *HttpClient, url: []const u8, body: []const u8, content_type: []const u8, extra_headers: []const std.http.Header) !HttpResponse {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;
        if (isHttpsProxied(uri, self._proxy_config)) {
            return self.tunnelRequest(.POST, uri, body, content_type, extra_headers);
        }
        var req = try self.client.request(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = content_type } },
            .extra_headers = extra_headers,
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body.len };
        try req.sendBodyComplete(@constCast(body));
        var buf: [4096]u8 = undefined;
        var response = try req.receiveHead(&buf);
        return self.readResponseBody(&response);
    }

    fn readResponseBody(self: *HttpClient, response: *std.http.Client.Response) !HttpResponse {
        const status = response.head.status;
        const content_length = response.head.content_length;
        var transfer_buf: [8192]u8 = undefined;
        var body_reader = response.reader(&transfer_buf);
        if (content_length) |len| {
            if (len == 0) {
                const body = try self.allocator.dupe(u8, "");
                return .{ .status = status, .body = body, .allocator = self.allocator };
            }
            const body = try body_reader.readAlloc(self.allocator, @intCast(len));
            return .{ .status = status, .body = body, .allocator = self.allocator };
        } else {
            var body_buf: [1024 * 1024]u8 = undefined;
            var body_writer = std.Io.Writer.fixed(&body_buf);
            _ = body_reader.streamRemaining(&body_writer) catch return error.InvalidResponse;
            const body = try self.allocator.dupe(u8, body_writer.buffered());
            return .{ .status = status, .body = body, .allocator = self.allocator };
        }
    }

    /// 解码 HTTP chunked transfer encoding
    fn decodeChunked(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
        var result: std.ArrayListUnmanaged(u8) = .empty;
        errdefer result.deinit(allocator);
        var pos: usize = 0;
        while (pos < data.len) {
            // 读取 chunk 大小（十六进制行）
            const line_end = std.mem.indexOfScalarPos(u8, data, pos, '\r') orelse break;
            const size_str = data[pos..line_end];
            // 跳过分号后的 chunk extension
            const semi = std.mem.indexOfScalar(u8, size_str, ';');
            const size_part = if (semi) |s| size_str[0..s] else size_str;
            const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, size_part, " \t"), 16) catch break;
            pos = line_end + 2; // skip \r\n
            if (chunk_size == 0) break; // 终止 chunk
            if (pos + chunk_size > data.len) break;
            try result.appendSlice(allocator, data[pos .. pos + chunk_size]);
            pos += chunk_size + 2; // skip chunk data + \r\n
        }
        return result.toOwnedSlice(allocator);
    }

    // ==================== 手动 CONNECT 隧道 + TLS ====================

    /// 判断是否为需要手动隧道的 HTTPS+代理请求
    fn isHttpsProxied(uri: std.Uri, pc: ?proxy.ProxyConfig) bool {
        if (pc == null) return false;
        const scheme = uri.scheme;
        return std.mem.eql(u8, scheme, "https");
    }

    /// 确保系统 CA 证书已加载到 client
    fn ensureCaBundle(self: *HttpClient) !void {
        if (self._ca_bundle_loaded) return;
        self._ca_bundle_loaded = true;
        const io = self.client.io;
        const now = std.Io.Clock.real.now(io);
        {
            try self.client.ca_bundle_lock.lock(io);
            defer self.client.ca_bundle_lock.unlock(io);
            if (self.client.now != null) return;
        }
        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(self.allocator);
        bundle.rescan(self.allocator, io, now) catch return error.CertificateBundleLoadFailure;
        try self.client.ca_bundle_lock.lock(io);
        defer self.client.ca_bundle_lock.unlock(io);
        self.client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &self.client.ca_bundle, &bundle);
    }

    /// 通过 HTTP 代理建立 CONNECT 隧道，再进行 TLS 握手，发送 HTTP 请求
    fn tunnelRequest(
        self: *HttpClient,
        method: std.http.Method,
        uri: std.Uri,
        body: ?[]const u8,
        content_type: ?[]const u8,
        extra_headers: []const std.http.Header,
    ) !HttpResponse {
        const io = self.client.io;
        const allocator = self.allocator;
        const pc = self._proxy_config.?;

        // 确保证书已加载
        terminal.logDebug(io, "[tunnel] loading CA bundle...", .{});
        try self.ensureCaBundle();
        terminal.logDebug(io, "[tunnel] CA bundle loaded", .{});

        // 提取目标主机和端口
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const target_host = try uri.getHost(&host_buf);
        const target_port: u16 = uri.port orelse 443;
        terminal.logDebug(io, "[tunnel] target: {s}:{d}", .{ target_host.bytes, target_port });

        // 1. 连接代理
        terminal.logDebug(io, "[tunnel] connecting to proxy {s}:{d}...", .{ pc.host, pc.port });
        const proxy_host: std.Io.net.HostName = .{ .bytes = pc.host };
        var stream = try proxy_host.connect(io, pc.port, .{ .mode = .stream, .protocol = .tcp });
        errdefer stream.close(io);
        terminal.logDebug(io, "[tunnel] connected to proxy", .{});

        // 2. 发送 CONNECT 请求
        {
            var write_buf: [4096]u8 = undefined;
            var w = stream.writer(io, &write_buf);
            try w.interface.print("CONNECT {s}:{d} HTTP/1.1\r\nHost: {s}:{d}\r\n", .{
                target_host.bytes, target_port, target_host.bytes, target_port,
            });
            if (pc.username) |_| {
                // 代理认证（复用已编码的 Basic auth）
                if (self._proxy_auth) |auth| {
                    try w.interface.print("Proxy-Authorization: {s}\r\n", .{auth});
                }
            }
            try w.interface.writeAll("\r\n");
            try w.interface.flush();
        }

        // 3. 读取 CONNECT 响应（读到 \r\n\r\n）
        terminal.logDebug(io, "[tunnel] CONNECT sent, reading response...", .{});
        {
            var read_buf: [4096]u8 = undefined;
            var r = stream.reader(io, &read_buf);
            var resp_buf: [4096]u8 = undefined;
            var resp_writer = std.Io.Writer.fixed(&resp_buf);
            while (true) {
                const chunk = r.interface.take(1) catch return error.ProxyConnectFailed;
                if (chunk.len == 0) return error.ProxyConnectFailed;
                resp_writer.writeByte(chunk[0]) catch return error.ProxyConnectFailed;
                const written = resp_writer.buffered();
                if (written.len >= 4) {
                    const tail = written[written.len - 4 ..];
                    if (std.mem.eql(u8, tail, "\r\n\r\n")) break;
                }
                if (written.len >= resp_buf.len) return error.ProxyConnectFailed;
            }

            // 检查状态码: HTTP/1.x 200
            const resp = resp_writer.buffered();
            if (resp.len < 12) return error.ProxyConnectFailed;
            if (!std.mem.startsWith(u8, resp, "HTTP/1.")) return error.ProxyConnectFailed;
            const status_start = std.mem.indexOfScalar(u8, resp, ' ') orelse return error.ProxyConnectFailed;
            const status_str = resp[status_start + 1 ..][0..3];
            if (!std.mem.eql(u8, status_str, "200")) return error.ProxyConnectFailed;
            terminal.logDebug(io, "[tunnel] CONNECT response: {s}", .{resp});
        }

        // 4. TLS 握手
        terminal.logDebug(io, "[tunnel] starting TLS handshake...", .{});
        const tls_read_buf_len = self.client.tls_buffer_size + self.client.read_buffer_size;
        const tls_alloc_size = tls_read_buf_len + self.client.tls_buffer_size +
            self.client.write_buffer_size + self.client.tls_buffer_size;
        const tls_buf = try allocator.alignedAlloc(u8, .of(std.crypto.tls.Client), tls_alloc_size);
        errdefer allocator.free(tls_buf);

        const tls_read_buf = tls_buf[0..tls_read_buf_len];
        const tls_write_buf = tls_buf[tls_read_buf_len..][0..self.client.tls_buffer_size];
        const socket_write_buf = tls_buf[tls_read_buf_len + self.client.tls_buffer_size ..][0..self.client.write_buffer_size];
        const socket_read_buf = tls_buf[tls_read_buf_len + self.client.tls_buffer_size + self.client.write_buffer_size ..][0..self.client.tls_buffer_size];

        // stream_writer 缓冲区用 tls_write_buf, TLS write_buffer 用 socket_write_buf
        // 与 std.http.Client.Connection.Tls.create 一致
        var stream_writer = stream.writer(io, tls_write_buf);
        var stream_reader = stream.reader(io, socket_read_buf);

        var random_buf: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        io.random(&random_buf);

        const now = self.client.now.?;
        var tls_client = std.crypto.tls.Client.init(
            &stream_reader.interface,
            &stream_writer.interface,
            .{
                .host = .{ .explicit = target_host.bytes },
                .ca = .{ .bundle = .{
                    .gpa = allocator,
                    .io = io,
                    .lock = &self.client.ca_bundle_lock,
                    .bundle = &self.client.ca_bundle,
                } },
                .read_buffer = tls_read_buf,
                .write_buffer = socket_write_buf,
                .entropy = &random_buf,
                .realtime_now = now,
                .allow_truncation_attacks = true,
            },
        ) catch return error.TlsInitializationFailed;
        terminal.logDebug(io, "[tunnel] TLS handshake completed", .{});
        const method_str = switch (method) {
            .GET => "GET",
            .POST => "POST",
            else => "GET",
        };
        const path = uri.path.percent_encoded;
        const query = if (uri.query) |q| q.percent_encoded else "";

        {
            var req_buf: [8192]u8 = undefined;
            var req_writer = std.Io.Writer.fixed(&req_buf);
            // path 可能已以 / 开头，需要避免双斜杠
            const req_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
            if (query.len > 0) {
                req_writer.print("{s} /{s}?{s} HTTP/1.1\r\nHost: {s}\r\n", .{
                    method_str, req_path, query, target_host.bytes,
                }) catch return error.InvalidRequest;
            } else {
                req_writer.print("{s} /{s} HTTP/1.1\r\nHost: {s}\r\n", .{
                    method_str, req_path, target_host.bytes,
                }) catch return error.InvalidRequest;
            }
            for (extra_headers) |h| {
                req_writer.print("{s}: {s}\r\n", .{ h.name, h.value }) catch return error.InvalidRequest;
            }
            if (body) |b| {
                const ct = content_type orelse "application/x-www-form-urlencoded";
                req_writer.print("Content-Type: {s}\r\nContent-Length: {d}\r\n", .{ ct, b.len }) catch return error.InvalidRequest;
            }
            req_writer.writeAll("Connection: close\r\n\r\n") catch return error.InvalidRequest;
            const req_data = req_writer.buffered();
            terminal.logDebug(io, "[tunnel] sending HTTP request ({} bytes)...", .{req_data.len});
            tls_client.writer.writeAll(req_data) catch return error.TlsWriteFailed;
        }
        terminal.logDebug(io, "[tunnel] HTTP request sent", .{});

        // 发送 body
        if (body) |b| {
            tls_client.writer.writeAll(b) catch return error.TlsWriteFailed;
        }
        try tls_client.writer.flush();
        // TLS flush 将密文写入 stream_writer 缓冲区，还需要刷新 socket
        try stream_writer.interface.flush();

        // 6. 读取 HTTP 响应
        // TLS Client 的 readIndirect 将解密数据放入 reader 内部 buffer，
        // 并返回 0（不是实际字节数）。需要用 peekGreedy/take 来触发 fill 再取数据。
        terminal.logDebug(io, "[tunnel] reading HTTP response...", .{});
        var resp_data: std.ArrayListUnmanaged(u8) = .empty;
        errdefer resp_data.deinit(allocator);
        var read_chunks: usize = 0;
        while (true) {
            // peekGreedy(1) 触发一次 readVec -> readIndirect，返回所有已缓冲数据
            const available = tls_client.reader.peekGreedy(1) catch |err| {
                terminal.logDebug(io, "[tunnel] peek error: {}", .{err});
                break;
            };
            if (available.len == 0) break;
            read_chunks += 1;
            try resp_data.appendSlice(allocator, available);
            tls_client.reader.toss(available.len);
        }
        terminal.logDebug(io, "[tunnel] read {} chunks, {} bytes total", .{ read_chunks, resp_data.items.len });

        // 7. 解析响应
        if (resp_data.items.len == 0) return error.InvalidResponse;

        // 找到 header/body 分界
        const header_end = std.mem.indexOf(u8, resp_data.items, "\r\n\r\n") orelse return error.InvalidResponse;
        const header_section = resp_data.items[0..header_end];

        // 解析状态行: HTTP/1.x CODE REASON
        const status_line_end = std.mem.indexOfScalar(u8, header_section, '\r') orelse return error.InvalidResponse;
        const status_line = header_section[0..status_line_end];
        const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.InvalidResponse;
        const status_code_str = status_line[first_space + 1 ..][0..3];
        const status_code = std.fmt.parseInt(u16, status_code_str, 10) catch return error.InvalidResponse;
        const status: std.http.Status = @enumFromInt(status_code);

        const body_start = header_end + 4;
        const raw_body = if (body_start < resp_data.items.len) resp_data.items[body_start..] else "";

        // 检查是否为 chunked transfer encoding
        const is_chunked = std.mem.indexOf(u8, header_section, "Transfer-Encoding: chunked") != null or
            std.mem.indexOf(u8, header_section, "transfer-encoding: chunked") != null;

        const body_copy = if (is_chunked)
            try decodeChunked(allocator, raw_body)
        else
            try allocator.dupe(u8, raw_body);

        // 清理
        allocator.free(tls_buf);
        resp_data.deinit(allocator);
        stream.close(io);

        return .{ .status = status, .body = body_copy, .allocator = allocator };
    }
};
