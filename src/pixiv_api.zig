//! Pixiv API 客户端模块
//! 模拟 Pixiv Android 应用的 API 请求，包含认证头构造、重试/限流逻辑。
//!
//! 认证头:
//!   App-OS: android
//!   App-OS-Version: 9.0
//!   App-Version: 5.0.234
//!   User-Agent: PixivAndroidApp/5.0.234 (Android 9.0; Pixel 3)
//!   X-Client-Time: ISO 8601 时间戳
//!   X-Client-Hash: MD5(X-Client-Time + HASH_SECRET)
//!   Authorization: Bearer {access_token}
//!
//! 重试策略:
//!   - ECONNRESET: 无限重试，间隔 3 秒
//!   - Rate limit: 暂停 10 分钟
//!   - 其他错误: 最多重试 2 次，间隔 1 秒

const std = @import("std");
const http_client = @import("http_client.zig");
const json_utils = @import("json_utils.zig");
const crypto = @import("crypto.zig");

/// Pixiv Android 应用 OAuth 凭据
pub const CLIENT_ID = "MOBrBDS8blbauoSck0ZfDbtuzpyT";
pub const CLIENT_SECRET = "lsACyCD94FhDUtGTXi3QzcFE2uU1hqtDaKeqrdwj";

/// X-Client-Hash 签名密钥
pub const HASH_SECRET = "28c1fdd170a5204386cb1313c7077b34f83e4aaf4aa829ce78c231e05b0bae2c";

/// API 基础 URL
pub const BASE_URL = "https://app-api.pixiv.net";

/// OAuth 令牌端点
pub const TOKEN_URL = "https://oauth.secure.pixiv.net/auth/token";

/// 默认重试次数

/// 将键值对编码为 application/x-www-form-urlencoded 格式
fn formEncode(allocator: std.mem.Allocator, pairs: []const struct { []const u8, []const u8 }) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    for (pairs, 0..) |pair, i| {
        if (i > 0) try result.append(allocator, '&');
        for (pair[0]) |ch| {
            try result.append(allocator, switch (ch) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => ch,
                else => ch, // keys are always safe literals
            });
        }
        try result.append(allocator, '=');
        for (pair[1]) |ch| {
            switch (ch) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                    try result.append(allocator, ch);
                },
                else => {
                    const hex = "0123456789ABCDEF";
                    try result.appendSlice(allocator, &[_]u8{ '%', hex[ch >> 4], hex[ch & 0x0F] });
                },
            }
        }
    }
    return result.toOwnedSlice(allocator);
}
const DEFAULT_RETRY: u32 = 2;

/// 将当前时间格式化为 ISO 8601 字符串 (YYYY-MM-DDTHH:MM:SS+00:00)
fn formatIso8601(io: std.Io, buf: []u8) ![]u8 {
    const ts = std.Io.Clock.now(.real, io);
    const secs: u64 = @intCast(ts.toSeconds());
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        year_day.year,
        @intFromEnum(month_day.month),
        @as(u5, @intCast(month_day.day_index + 1)),
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// 计算 MD5 并返回小写十六进制字符串
fn md5Hex(data: []const u8, buf: *[33]u8) []const u8 {
    var out: [16]u8 = undefined;
    crypto.md5(data, &out);
    const result = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        out[0],  out[1],  out[2],  out[3],
        out[4],  out[5],  out[6],  out[7],
        out[8],  out[9],  out[10], out[11],
        out[12], out[13], out[14], out[15],
    }) catch unreachable;
    return result;
}

/// Pixiv API 客户端
pub const PixivApi = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    http: http_client.HttpClient,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, http: http_client.HttpClient) PixivApi {
        return .{
            .allocator = allocator,
            .io = io,
            .http = http,
        };
    }

    pub fn deinit(self: *PixivApi) void {
        if (self.access_token) |t| self.allocator.free(t);
        if (self.refresh_token) |t| self.allocator.free(t);
    }

    /// 设置认证令牌（会复制字符串）
    pub fn setTokens(self: *PixivApi, access_token: ?[]const u8, refresh_token: ?[]const u8) !void {
        if (self.access_token) |t| self.allocator.free(t);
        if (self.refresh_token) |t| self.allocator.free(t);
        self.access_token = if (access_token) |t| try self.allocator.dupe(u8, t) else null;
        self.refresh_token = if (refresh_token) |t| try self.allocator.dupe(u8, t) else null;
    }

    /// 构造 Pixiv API 请求所需的 HTTP 头
    /// 时间戳和签名在每次请求时重新生成
    /// 返回的分配字符串通过 arena 管理
    fn buildAuthHeaders(self: *PixivApi, arena: std.mem.Allocator) !struct { items: []std.http.Header, bearer: ?[]const u8 } {
        // 生成 ISO 8601 时间戳
        var time_buf: [64]u8 = undefined;
        const time_str = try formatIso8601(self.io, &time_buf);

        // 计算 X-Client-Hash = MD5(time_str + HASH_SECRET)
        var hash_input_buf: [256]u8 = undefined;
        const hash_input = try std.fmt.bufPrint(&hash_input_buf, "{s}{s}", .{ time_str, HASH_SECRET });
        var md5_buf: [33]u8 = undefined;
        const client_hash = md5Hex(hash_input, &md5_buf);

        // 复制到 arena 分配的内存（header 字符串需要稳定指针）
        const ts_copy = try arena.dupe(u8, time_str);
        const hash_copy = try arena.dupe(u8, client_hash);

        // 构造 Bearer token
        var bearer: ?[]const u8 = null;
        const auth_value: []const u8 = if (self.access_token) |token| blk: {
            const b = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
            bearer = b;
            break :blk b;
        } else "";

        const headers = try arena.alloc(std.http.Header, 8);
        headers[0] = .{ .name = "App-OS", .value = "android" };
        headers[1] = .{ .name = "App-OS-Version", .value = "9.0" };
        headers[2] = .{ .name = "App-Version", .value = "5.0.234" };
        headers[3] = .{ .name = "User-Agent", .value = "PixivAndroidApp/5.0.234 (Android 9.0; Pixel 3)" };
        headers[4] = .{ .name = "Accept-Language", .value = "en-us" };
        headers[5] = .{ .name = "X-Client-Time", .value = ts_copy };
        headers[6] = .{ .name = "X-Client-Hash", .value = hash_copy };
        headers[7] = .{ .name = "Authorization", .value = auth_value };

        return .{ .items = headers, .bearer = bearer };
    }

    /// 发送 GET 请求到 Pixiv API（含重试逻辑）
    /// path: 完整 URL 或相对路径（相对于 BASE_URL）
    /// retry: 剩余重试次数
    /// 返回 Parsed(JSON Value)，调用者需调用 .deinit() 释放内存
    pub fn callApi(self: *PixivApi, path: []const u8, retry: u32) !std.json.Parsed(std.json.Value) {
        const url = if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://"))
            path
        else
            try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ BASE_URL, path });
        defer {
            if (!std.mem.eql(u8, url, path)) self.allocator.free(@constCast(url));
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const header_result = try self.buildAuthHeaders(arena.allocator());

        const resp = self.http.get(url, header_result.items) catch |err| {
            if (err == error.ConnectionResetByPeer or err == error.ConnectionTimedOut) {
                std.Io.sleep(self.io, .fromSeconds(3), .real) catch {};
                return self.callApi(path, retry);
            }
            if (retry > 0) {
                std.Io.sleep(self.io, .fromSeconds(1), .real) catch {};
                return self.callApi(path, retry - 1);
            }
            return err;
        };
        defer resp.deinit();

        // 检查 HTTP 状态码
        if (@intFromEnum(resp.status) >= 500) {
            if (retry > 0) {
                std.Io.sleep(self.io, .fromSeconds(1), .real) catch {};
                return self.callApi(path, retry - 1);
            }
            return error.ServerError;
        }

        // 解析 JSON
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch {
            if (retry > 0) {
                std.Io.sleep(self.io, .fromSeconds(1), .real) catch {};
                return self.callApi(path, retry - 1);
            }
            return error.InvalidResponse;
        };

        // 检查 rate limit（在 parsed 的 body 中查找 "rate limit" 字样）
        if (std.mem.indexOf(u8, resp.body, "rate limit") != null) {
            parsed.deinit();
            std.Io.sleep(self.io, .fromSeconds(600), .real) catch {};
            return self.callApi(path, retry);
        }

        return parsed;
    }

    /// 使用 refresh_token 刷新 access_token
    pub fn refreshAccessToken(self: *PixivApi, refresh_token_str: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const header_result = try self.buildAuthHeaders(arena.allocator());

        const body = try formEncode(arena.allocator(), &.{
            .{ "client_id", CLIENT_ID },
            .{ "client_secret", CLIENT_SECRET },
            .{ "grant_type", "refresh_token" },
            .{ "refresh_token", refresh_token_str },
        });

        const resp = try self.http.post(TOKEN_URL, body, header_result.items);
        defer resp.deinit();

        if (@intFromEnum(resp.status) != 200) return error.TokenRefreshFailed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch
            return error.InvalidTokenResponse;
        defer parsed.deinit();

        const response = parsed.value;
        if (response != .object) return error.InvalidTokenResponse;

        const new_access = json_utils.getFieldString(response, "access_token") orelse
            return error.InvalidTokenResponse;
        const new_refresh = json_utils.getFieldString(response, "refresh_token") orelse
            return error.InvalidTokenResponse;

        try self.setTokens(new_access, new_refresh);
    }

    /// 通过 authorization code 交换 token（OAuth PKCE 流程的最后一步）
    pub fn exchangeToken(self: *PixivApi, code: []const u8, code_verifier: []const u8) !void {
        std.log.debug("[exchangeToken] starting token exchange...", .{});
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const header_result = try self.buildAuthHeaders(arena.allocator());

        const body = try formEncode(arena.allocator(), &.{
            .{ "client_id", CLIENT_ID },
            .{ "client_secret", CLIENT_SECRET },
            .{ "grant_type", "authorization_code" },
            .{ "code", code },
            .{ "code_verifier", code_verifier },
            .{ "redirect_uri", "https://app-api.pixiv.net/web/v1/users/auth/pixiv/callback" },
        });

        std.log.debug("[exchangeToken] POST {s} body={s}", .{ TOKEN_URL, body });
        const resp = try self.http.post(TOKEN_URL, body, header_result.items);
        defer resp.deinit();

        std.log.debug("[exchangeToken] status: {} body: {s}", .{ resp.status, resp.body });

        if (@intFromEnum(resp.status) != 200) return error.TokenExchangeFailed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch
            return error.InvalidTokenResponse;
        defer parsed.deinit();

        const response = parsed.value;
        if (response != .object) return error.InvalidTokenResponse;

        const new_access = json_utils.getFieldString(response, "access_token") orelse
            return error.InvalidTokenResponse;
        const new_refresh = json_utils.getFieldString(response, "refresh_token") orelse
            return error.InvalidTokenResponse;

        try self.setTokens(new_access, new_refresh);
    }

    // ==================== API 端点 ====================

    /// 获取用户插画列表
    pub fn userIllusts(self: *PixivApi, user_id: u64) !std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(self.allocator, "/v1/user/illusts?user_id={d}", .{user_id});
        defer self.allocator.free(path);
        return self.callApi(path, DEFAULT_RETRY);
    }

    /// 获取用户收藏插画
    pub fn userBookmarksIllust(self: *PixivApi, user_id: u64) !std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(self.allocator, "/v1/user/bookmarks/illust?user_id={d}&restrict=public", .{user_id});
        defer self.allocator.free(path);
        return self.callApi(path, DEFAULT_RETRY);
    }

    /// 获取插画详情
    pub fn illustDetail(self: *PixivApi, illust_id: u64) !std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(self.allocator, "/v1/illust/detail?illust_id={d}", .{illust_id});
        defer self.allocator.free(path);
        return self.callApi(path, DEFAULT_RETRY);
    }

    /// 获取 Ugoira 动图元数据
    pub fn ugoiraMetaData(self: *PixivApi, illust_id: u64) !std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(self.allocator, "/v1/ugoira/metadata?illust_id={d}", .{illust_id});
        defer self.allocator.free(path);
        return self.callApi(path, DEFAULT_RETRY);
    }

    /// 获取用户详情
    pub fn userDetail(self: *PixivApi, user_id: u64) !std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(self.allocator, "/v1/user/detail?user_id={d}", .{user_id});
        defer self.allocator.free(path);
        return self.callApi(path, DEFAULT_RETRY);
    }

    /// 获取关注用户的最新插画
    pub fn illustFollow(self: *PixivApi) !std.json.Parsed(std.json.Value) {
        return self.callApi("/v2/illust/follow?restrict=all", DEFAULT_RETRY);
    }

    /// 获取用户关注的画师列表
    pub fn userFollowing(self: *PixivApi, user_id: u64, restrict: []const u8) !std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(self.allocator, "/v1/user/following?user_id={d}&restrict={s}", .{ user_id, restrict });
        defer self.allocator.free(path);
        return self.callApi(path, DEFAULT_RETRY);
    }

    /// 获取下一页数据（通过 API 返回的 next_url）
    pub fn nextPage(self: *PixivApi, url: []const u8) !std.json.Parsed(std.json.Value) {
        return self.callApi(url, DEFAULT_RETRY);
    }
};

test "formatIso8601 produces valid timestamp" {
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var buf: [64]u8 = undefined;
    const ts = try formatIso8601(io, &buf);

    // 应为 "YYYY-MM-DDTHH:MM:SS+00:00" 格式（25 字符）
    try std.testing.expectEqual(@as(usize, 25), ts.len);
    try std.testing.expectEqual(@as(u8, '-'), ts[4]);
    try std.testing.expectEqual(@as(u8, '-'), ts[7]);
    try std.testing.expectEqual(@as(u8, 'T'), ts[10]);
    try std.testing.expectEqual(@as(u8, ':'), ts[13]);
    try std.testing.expectEqual(@as(u8, ':'), ts[16]);
    // 年份应以 20 开头（合理的现代日期）
    try std.testing.expect(ts[0] == '2' and ts[1] == '0');
}

test "md5Hex produces correct hash" {
    var buf: [33]u8 = undefined;
    const result = md5Hex("hello", &buf);
    try std.testing.expectEqualStrings("5d41402abc4b2a76b9719d911017c592", result);
}

test "PixivApi setTokens copies strings" {
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();

    var http = try http_client.HttpClient.init(std.testing.allocator, io_threaded.io(), null);
    defer http.deinit();

    var api = PixivApi.init(std.testing.allocator, io_threaded.io(), http);
    defer api.deinit();

    try api.setTokens("test_access_token", "test_refresh_token");

    try std.testing.expectEqualStrings("test_access_token", api.access_token.?);
    try std.testing.expectEqualStrings("test_refresh_token", api.refresh_token.?);
}
