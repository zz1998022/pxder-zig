//! JSON 工具模块
//! 提供对 std.json.Value 动态 JSON 树的安全字段提取和文件读写。
//! Pixiv API 响应使用 snake_case 字段名，这里用动态解析而非类型绑定。

const std = @import("std");

/// 从 JSON 对象中安全提取字符串字段，类型不匹配返回 null
pub fn getFieldString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

/// 从 JSON 对象中安全提取整数字段（支持 integer 和 float 类型）
pub fn getFieldInt(obj: std.json.Value, key: []const u8) ?i64 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    switch (val) {
        .integer => |i| return i,
        .float => |f| return @intFromFloat(f),
        else => return null,
    }
}

/// 从 JSON 对象中安全提取布尔字段
pub fn getFieldBool(obj: std.json.Value, key: []const u8) ?bool {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .bool) return null;
    return val.bool;
}

/// 从 JSON 对象中安全提取数组字段
pub fn getFieldArray(obj: std.json.Value, key: []const u8) ?std.json.Array {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .array) return null;
    return val.array;
}

/// 从 JSON 对象中安全提取嵌套对象字段
pub fn getFieldObject(obj: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .object) return null;
    return val.object;
}

/// 从文件读取并解析 JSON，失败返回 null
/// 返回的值通过深拷贝独立于 arena，调用者需用 deinitJsonValue 释放
pub fn readJsonFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ?std.json.Value {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const contents = file.readPositionalAllAlloc(io, allocator, 0, 10 * 1024 * 1024) catch return null;
    defer allocator.free(contents);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    defer parsed.deinit();
    // Deep clone to detach from arena so the caller owns the memory
    return cloneJsonValue(allocator, parsed.value) catch null;
}

/// 从文件安全读取 JSON，失败时返回默认值
pub fn readJsonFileSafely(allocator: std.mem.Allocator, io: std.Io, path: []const u8, default: std.json.Value) std.json.Value {
    return readJsonFile(allocator, io, path) orelse default;
}

/// 将 JSON Value 写入文件
pub fn writeJsonFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, value: std.json.Value) !void {
    _ = allocator;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [65536]u8 = undefined;
    var fw = file.writer(io, &buf);
    try writeJsonValueToWriter(&fw.interface, value);
    try fw.flush();
}

/// 递归将 JSON Value 直接写入 writer（不使用 Stringify 状态机）
fn writeJsonValueToWriter(w: *std.Io.Writer, value: std.json.Value) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |str| {
            try std.json.Stringify.encodeJsonString(str, .{}, w);
        },
        .array => |arr| {
            try w.writeAll("[");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeAll(",");
                try writeJsonValueToWriter(w, item);
            }
            try w.writeAll("]");
        },
        .object => |obj| {
            try w.writeAll("{");
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try w.writeAll(",");
                first = false;
                try std.json.Stringify.encodeJsonString(entry.key_ptr.*, .{}, w);
                try w.writeAll(":");
                try writeJsonValueToWriter(w, entry.value_ptr.*);
            }
            try w.writeAll("}");
        },
        .number_string => |ns| try w.writeAll(ns),
    }
}

/// 深拷贝 JSON Value 使其独立于 arena 分配器
pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
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
                for (new_arr.items) |item| deinitJsonValue(allocator, item);
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
                    deinitJsonValue(allocator, entry.value_ptr.*);
                }
                new_obj.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                new_obj.put(allocator, key, val) catch {
                    allocator.free(key);
                    deinitJsonValue(allocator, val);
                    continue;
                };
            }
            return .{ .object = new_obj };
        },
    }
}

/// 递归释放 cloneJsonValue 分配的 JSON Value
pub fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .string => |s| allocator.free(s),
        .number_string => |ns| allocator.free(ns),
        .array => |arr| {
            for (arr.items) |item| deinitJsonValue(allocator, item);
            arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            obj.deinit(allocator);
        },
    }
}

test "getFieldString" {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"name":"test","count":42}
    , .{});
    defer json.deinit();
    try std.testing.expectEqualStrings("test", getFieldString(json.value, "name").?);
    try std.testing.expect(getFieldString(json.value, "missing") == null);
}

test "getFieldInt" {
    const json = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"count":42}
    , .{});
    defer json.deinit();
    try std.testing.expectEqual(@as(i64, 42), getFieldInt(json.value, "count").?);
}
