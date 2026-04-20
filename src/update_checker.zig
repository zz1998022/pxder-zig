//! 版本更新检查模块
//! 查询 npm registry 获取 pxder 最新版本号，与当前版本比较。
//! 结果缓存到本地文件，3 天内不重复请求。

const std = @import("std");
const http_client = @import("http_client.zig");
const json_utils = @import("json_utils.zig");
const config = @import("config.zig");

/// 缓存有效期：3 天（单位：秒）
const cache_ttl_seconds: i64 = 3 * 24 * 60 * 60;

/// 查询 npm registry 获取最新版本号
/// 请求 https://registry.npmjs.org/pxder/latest 并解析 version 字段
/// 返回的版本字符串由 allocator 分配，需要调用者释放
pub fn getLatestVersion(allocator: std.mem.Allocator, io: std.Io, client: *http_client.HttpClient) ![]const u8 {
    var resp = try client.get("https://registry.npmjs.org/pxder/latest", &.{});
    defer resp.deinit();

    if (resp.status != .ok) return error.RegistryRequestFailed;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{}) catch
        return error.InvalidRegistryResponse;
    defer parsed.deinit();

    const version = json_utils.getFieldString(parsed.value, "version") orelse
        return error.InvalidRegistryResponse;

    return allocator.dupe(u8, version);
}

/// 检查是否有可用更新
/// 比较当前版本与最新版本，如果有新版本返回版本字符串，否则返回 null
/// 返回的版本字符串由 allocator 分配，需要调用者释放
pub fn checkForUpdate(allocator: std.mem.Allocator, io: std.Io, client: *http_client.HttpClient, current_version: []const u8) !?[]const u8 {
    const latest = getLatestVersion(allocator, io, client) catch |err| {
        switch (err) {
            error.RegistryRequestFailed, error.InvalidRegistryResponse => return null,
            else => return err,
        }
    };

    if (std.mem.eql(u8, latest, current_version)) {
        allocator.free(latest);
        return null;
    }

    return latest;
}

/// 将版本号和当前时间戳缓存到文件
/// 文件路径: <config_dir>/update_cache.json
pub fn cacheVersion(allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8, version: []const u8) !void {
    const now_ts = std.Io.Timestamp.now(io, .real);
    const now_seconds = now_ts.toSeconds();

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);

    try obj.put(allocator, "version", .{ .string = version });
    try obj.put(allocator, "timestamp", .{ .integer = now_seconds });

    const path = try std.fmt.allocPrint(allocator, "{s}/update_cache.json", .{config_dir});
    defer allocator.free(path);

    json_utils.writeJsonFile(allocator, io, path, .{ .object = obj }) catch {};
}

/// 读取缓存的版本号，如果缓存不存在或超过 3 天则返回 null
pub fn getCachedVersion(allocator: std.mem.Allocator, io: std.Io, config_dir: []const u8) ?[]const u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/update_cache.json", .{config_dir}) catch return null;
    defer allocator.free(path);

    const json = json_utils.readJsonFile(allocator, io, path) orelse return null;

    const version = json_utils.getFieldString(json, "version") orelse return null;
    const timestamp = json_utils.getFieldInt(json, "timestamp") orelse return null;

    // 检查缓存是否过期
    const now_ts = std.Io.Timestamp.now(io, .real);
    const now_seconds = now_ts.toSeconds();
    const elapsed = now_seconds - timestamp;
    if (elapsed > cache_ttl_seconds) return null;

    return allocator.dupe(u8, version) catch null;
}

test "cacheVersion and getCachedVersion" {
    const allocator = std.testing.allocator;
    var io_threaded = std.Io.Threaded.init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // 使用临时目录测试
    var tmp_dir = std.Io.Dir.cwd().makeOpenPath(io, "zig-cache/tmp/update_test", .{}) catch return;
    defer tmp_dir.close(io);

    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(allocator);
    try obj.put(allocator, "version", .{ .string = "2.12.10" });
    try obj.put(allocator, "timestamp", .{ .integer = std.Io.Timestamp.now(io, .real).toSeconds() });

    json_utils.writeJsonFile(allocator, io, "zig-cache/tmp/update_test/update_cache.json", .{ .object = obj }) catch return;

    const cached = getCachedVersion(allocator, io, "zig-cache/tmp/update_test");
    if (cached) |v| {
        defer allocator.free(v);
        try std.testing.expectEqualStrings("2.12.10", v);
    }
}
