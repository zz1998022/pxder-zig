//! 工具函数模块
//! 提供文件下载、临时目录管理、UgoiraDir 辅助类等功能。

const std = @import("std");
const http_client = @import("../infra/http/http_client.zig");

/// 创建目录路径（mkdir -p），已存在时忽略
pub fn ensureDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
}

/// 检查文件是否存在
pub fn fileExists(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    cwd.access(io, path, .{ .read = true }) catch return false;
    return true;
}

/// 删除文件，忽略错误
pub fn deleteFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

/// 重命名/移动文件
pub fn moveFile(io: std.Io, old_path: []const u8, new_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.rename(cwd, old_path, cwd, new_path, io) catch return error.RenameFailed;
}

/// 从 URL 下载文件到指定目录
/// allocator: 内存分配器
/// io: std.Io 实例
/// client: HTTP 客户端
/// url: 下载 URL
/// dir: 目标目录
/// filename: 目标文件名
/// referer: Referer 头（Pixiv 防盗链）
pub fn downloadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: *http_client.HttpClient,
    url: []const u8,
    dir: []const u8,
    filename: []const u8,
    referer: []const u8,
) !void {
    // 确保目录存在
    ensureDir(io, dir);

    // 构造完整路径
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, filename });
    defer allocator.free(full_path);

    // 发送带 Referer 的 GET 请求
    const headers = [_]std.http.Header{
        .{ .name = "Referer", .value = referer },
    };
    var resp = try client.get(url, &headers);
    defer resp.deinit();

    if (resp.status != .ok) {
        return error.DownloadFailed;
    }

    // 写入文件
    const file = try std.Io.Dir.cwd().createFile(io, full_path, .{ .read = true });
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var w = file.writer(io, &buf);
    try w.interface.writeAll(resp.body);
    try w.flush();
}

/// 去除 ugoira 文件名中的 @NNms 后缀
/// "(12345)title@100ms.zip" → "(12345)title.zip"
fn stripUgoiraDelaySuffix(name: []const u8) []const u8 {
    // 查找 .zip 前的 @NNms 模式
    if (std.mem.lastIndexOfScalar(u8, name, '@')) |at_idx| {
        // 确认 @ 后面是数字 + "ms" 并且在 .zip 之前
        const after_at = name[at_idx + 1 ..];
        if (std.mem.endsWith(u8, after_at, "ms.zip")) {
            return name[0..at_idx];
        }
    }
    return name;
}

/// Ugoira 目录扫描器
/// 扫描目录中的 .zip 文件，通过去除 @NNms 后缀来判断动图是否已存在
pub const UgoiraDir = struct {
    /// 存储去除了 @NNms 后缀的文件名列表
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    allocator: std.mem.Allocator,

    /// 初始化：扫描目录中的 .zip 文件
    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !UgoiraDir {
        var self = UgoiraDir{
            .allocator = allocator,
        };
        errdefer self.deinit();

        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
            // 目录不存在，返回空列表
            return self;
        };
        defer dir.close(io);

        var iter = dir.iterate();
        while (iter.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zip")) continue;

            // 去除 @NNms 后缀并存储
            const stripped = stripUgoiraDelaySuffix(entry.name);
            const owned = try allocator.dupe(u8, stripped);
            self.names.append(allocator, owned) catch {
                allocator.free(owned);
                continue;
            };
        }

        return self;
    }

    /// 释放资源
    pub fn deinit(self: *UgoiraDir) void {
        for (self.names.items) |name| {
            self.allocator.free(name);
        }
        self.names.deinit(self.allocator);
    }

    /// 检查文件是否存在（自动去除 @NNms 后缀进行匹配）
    pub fn exists(self: *const UgoiraDir, filename: []const u8) bool {
        const stripped = stripUgoiraDelaySuffix(filename);
        for (self.names.items) |name| {
            if (std.mem.eql(u8, name, stripped)) return true;
        }
        return false;
    }
};

/// 从文件安全读取 JSON，失败返回默认值
pub fn readJsonSafely(allocator: std.mem.Allocator, io: std.Io, path: []const u8, default_value: std.json.Value) !std.json.Value {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
        return default_value;
    };
    defer file.close(io);

    const contents = file.readPositionalAllAlloc(io, allocator, 0, 10 * 1024 * 1024) catch {
        return default_value;
    };
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch {
        return default_value;
    };

    // 注意: parsed.value 中的子节点使用了 parsed 的 arena,
    // 需要将整个 parsed 返回，但函数签名返回 Value。
    // 为避免泄漏，克隆一份独立于 arena 的值。
    const cloned = try cloneJsonValue(allocator, parsed.value);
    parsed.deinit();
    return cloned;
}

/// 深拷贝 JSON Value 使其独立于 arena 分配器
fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .number_string => |ns| return .{ .number_string = try allocator.dupe(u8, ns) },
        .array => |arr| {
            var new_arr: std.json.Array = .init(allocator);
            errdefer {
                for (new_arr.items) |item| destroyJsonValue(allocator, item);
                new_arr.deinit();
            }
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj: std.json.ObjectMap = .empty;
            errdefer {
                var it = new_obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    destroyJsonValue(allocator, entry.value_ptr.*);
                }
                new_obj.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                new_obj.put(allocator, key, val) catch {
                    allocator.free(key);
                    destroyJsonValue(allocator, val);
                    continue;
                };
            }
            return .{ .object = new_obj };
        },
    }
}

/// 递归释放 cloneJsonValue 分配的 JSON Value
fn destroyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .string => |s| allocator.free(s),
        .number_string => |ns| allocator.free(ns),
        .array => |arr| {
            for (arr.items) |item| destroyJsonValue(allocator, item);
            arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                destroyJsonValue(allocator, entry.value_ptr.*);
            }
            obj.deinit(allocator);
        },
    }
}

// ============================================================
// Tests
// ============================================================

test "fileExists detects existing and missing files" {
    const io = std.testing.io;

    // 创建临时文件
    const tmp_path = "test_tools_exists_tmp.txt";
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    file.close(io);
    defer _ = std.Io.Dir.cwd().deleteFile(io, tmp_path);

    try std.testing.expect(fileExists(io, tmp_path));
    try std.testing.expect(!fileExists(io, "nonexistent_file_abcdef.txt"));
}

test "stripUgoiraDelaySuffix strips @NNms" {
    try std.testing.expectEqualStrings("(12345)title", stripUgoiraDelaySuffix("(12345)title@100ms.zip"));
    try std.testing.expectEqualStrings("(12345)title", stripUgoiraDelaySuffix("(12345)title@0ms.zip"));
    try std.testing.expectEqualStrings("(12345)title", stripUgoiraDelaySuffix("(12345)title"));
    try std.testing.expectEqualStrings("(99)test", stripUgoiraDelaySuffix("(99)test@50ms.zip"));
}

test "UgoiraDir exists matches stripped filenames" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 创建临时目录和测试文件
    const tmp_dir = "test_tools_ugoira_tmp";
    std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch {};

    // 创建测试 zip 文件
    const file1_path = try std.fmt.allocPrint(allocator, "{s}/(111)title@100ms.zip", .{tmp_dir});
    defer allocator.free(file1_path);
    const f1 = try std.Io.Dir.cwd().createFile(io, file1_path, .{});
    f1.close(io);

    const file2_path = try std.fmt.allocPrint(allocator, "{s}/(222)other.zip", .{tmp_dir});
    defer allocator.free(file2_path);
    const f2 = try std.Io.Dir.cwd().createFile(io, file2_path, .{});
    f2.close(io);

    defer {
        _ = std.Io.Dir.cwd().deleteFile(io, file1_path);
        _ = std.Io.Dir.cwd().deleteFile(io, file2_path);
        _ = std.Io.Dir.cwd().deleteDir(io, tmp_dir);
    }

    var udir = try UgoiraDir.init(allocator, io, tmp_dir);
    defer udir.deinit();

    // 带 @NNms 后缀的查询应匹配
    try std.testing.expect(udir.exists("(111)title@100ms.zip"));
    // 不带后缀的查询也应匹配
    try std.testing.expect(udir.exists("(111)title.zip"));
    // 同一 ID 不同延迟应匹配
    try std.testing.expect(udir.exists("(111)title@200ms.zip"));
    // 不带 @NNms 的文件也应匹配
    try std.testing.expect(udir.exists("(222)other.zip"));
    // 不存在的文件不应匹配
    try std.testing.expect(!udir.exists("(333)nope.zip"));
}

test "deleteFile ignores errors" {
    const io = std.testing.io;
    // 删除不存在的文件不应崩溃
    deleteFile(io, "nonexistent_file_xyz.txt");
}
