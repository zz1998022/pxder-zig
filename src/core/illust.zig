//! 插画数据模型模块
//! 处理插画数据的解析、URL 构造和文件名生成。
//! Pixiv 插画分为三种类型:
//!   - 单图 (meta_single_page): 一张原图
//!   - 多图/漫画 (meta_pages): 多张原图，文件名带 _p0, _p1 后缀
//!   - 动图/Ugoira: 下载为 ZIP 压缩包，URL 从 img-original 转换为 img-zip-ugoira
//!
//! 文件名格式:
//!   单图:   (12345)标题.jpg
//!   多图:   (12345)标题_p0.png
//!   动图:   (12345)标题@100ms.zip  或  (12345)标题.zip

const std = @import("std");
const json_utils = @import("../shared/json_utils.zig");

/// 插画类型
pub const IllustType = enum {
    single,
    multi,
    ugoira,
};

/// 插画数据结构，表示一个待下载的文件
pub const Illust = struct {
    id: u64, // 插画 PID
    title: []const u8, // 清洗后的标题
    url: []const u8, // 下载 URL（原图或 ZIP）
    file: []const u8, // 本地文件名
    illust_type: IllustType, // 插画类型

    /// 释放所有分配的字符串字段
    pub fn deinit(self: *const Illust, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.file);
    }
};

/// 清洗插画标题，去除文件名中的非法字符
/// 移除: 控制字符 (0x00-0x1F, 0x7F) 和文件名不安全字符 / \ : * ? " < > | . & $
/// 同时去除尾部空格
pub fn sanitizeTitle(allocator: std.mem.Allocator, title: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);

    for (title) |ch| {
        if (ch <= 0x1F or ch == 0x7F) continue;
        if (ch == '/' or ch == '\\' or ch == ':' or ch == '*' or
            ch == '?' or ch == '"' or ch == '<' or ch == '>' or
            ch == '|' or ch == '.' or ch == '&' or ch == '$')
        {
            continue;
        }
        try result.append(allocator, ch);
    }

    while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
        _ = result.pop();
    }

    return result.toOwnedSlice(allocator);
}

/// 清洗画师名称
/// 先去除 @ 及其之后的内容（通常是同人展信息），再调用 sanitizeTitle
pub fn sanitizeArtistName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var end: usize = name.len;
    for (name, 0..) |ch, i| {
        if (ch == '@') {
            if (i > 0) {
                end = i;
                break;
            }
        }
    }
    return sanitizeTitle(allocator, name[0..end]);
}

/// 从 URL 中提取文件扩展名（含点号）
/// 例: "https://i.pximg.net/img/.../image.jpg" → ".jpg"
fn extractExtension(url: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, url, '.')) |dot_idx| {
        // 确保点号后面没有路径分隔符或查询参数
        const ext = url[dot_idx..];
        if (std.mem.indexOfScalar(u8, ext, '/') == null and
            std.mem.indexOfScalar(u8, ext, '?') == null and
            std.mem.indexOfScalar(u8, ext, '#') == null)
        {
            return ext;
        }
    }
    return ".jpg"; // 默认扩展名
}

/// 将 ugoira 原始 URL 转换为 ZIP 下载 URL
/// img-original/.../_ugoira0.ext → img-zip-ugoira/.../_ugoira1920x1080.zip
fn ugoiraZipUrl(allocator: std.mem.Allocator, original_url: []const u8) ![]const u8 {
    // 替换 img-original 为 img-zip-ugoira
    const replaced = std.mem.replaceOwned(u8, allocator, original_url, "img-original", "img-zip-ugoira") catch
        return allocator.dupe(u8, original_url);
    errdefer allocator.free(replaced);

    // 替换 _ugoira0.??? 后缀为 _ugoira1920x1080.zip
    if (std.mem.lastIndexOfScalar(u8, replaced, '_')) |underscore_idx| {
        const base = replaced[0..underscore_idx];
        const final_url = try std.fmt.allocPrint(allocator, "{s}_ugoira1920x1080.zip", .{base});
        allocator.free(replaced);
        return final_url;
    }
    return replaced;
}

/// 从 Pixiv API 返回的单个插画 JSON 解析出下载任务列表
/// 一张插画可能产生多个下载任务（多图情况下）
/// json: API 返回的单个插画对象（std.json.Value）
/// no_ugoira_meta: 为 true 时跳过 ugoira 延迟信息（直接用 .zip 而非 @NNms.zip）
/// ugoira_delay: ugoira 的帧延迟（毫秒），从 ugoiraMetaData 获取，null 时默认 0
pub fn parseIllusts(allocator: std.mem.Allocator, json: std.json.Value, ugoira_delay: ?u32) ![]Illust {
    var result: std.ArrayListUnmanaged(Illust) = .empty;
    errdefer {
        for (result.items) |item| item.deinit(allocator);
        result.deinit(allocator);
    }

    const id = json_utils.getFieldInt(json, "id") orelse return error.InvalidIllustJson;
    const raw_title = json_utils.getFieldString(json, "title") orelse "";
    const illust_type_str = json_utils.getFieldString(json, "type") orelse "illust";
    const clean_title = try sanitizeTitle(allocator, raw_title);

    // 获取 meta_single_page 和 meta_pages
    const meta_single = json_utils.getFieldObject(json, "meta_single_page");
    const meta_pages_val = json_utils.getFieldArray(json, "meta_pages");

    if (std.mem.eql(u8, illust_type_str, "ugoira")) {
        // === Ugoira 动图 ===
        const original_url: []const u8 = blk: {
            if (meta_single) |obj| {
                if (obj.get("original_image_url")) |val| {
                    if (val == .string) break :blk val.string;
                }
            }
            break :blk "";
        };

        if (original_url.len == 0) return error.InvalidIllustJson;

        const zip_url = try ugoiraZipUrl(allocator, original_url);
        const file_name = if (ugoira_delay) |delay|
            try std.fmt.allocPrint(allocator, "({d}){s}@{d}ms.zip", .{ id, clean_title, delay })
        else
            try std.fmt.allocPrint(allocator, "({d}){s}.zip", .{ id, clean_title });

        try result.append(allocator, .{
            .id = @intCast(id),
            .title = clean_title,
            .url = zip_url,
            .file = file_name,
            .illust_type = .ugoira,
        });
    } else if (meta_pages_val) |pages| {
        if (pages.items.len > 0) {
            // === 多图 ===
            for (pages.items, 0..) |page_val, page_idx| {
                if (page_val != .object) continue;
                const images = page_val.object.get("image_urls") orelse continue;
                if (images != .object) continue;
                const original = images.object.get("original") orelse continue;
                if (original != .string) continue;

                const ext = extractExtension(original.string);
                const page_title = try allocator.dupe(u8, clean_title);
                const file_name = try std.fmt.allocPrint(allocator, "({d}){s}_p{d}{s}", .{ id, clean_title, page_idx, ext });
                const url_copy = try allocator.dupe(u8, original.string);

                try result.append(allocator, .{
                    .id = @intCast(id),
                    .title = page_title,
                    .url = url_copy,
                    .file = file_name,
                    .illust_type = .multi,
                });
            }
            // 多图分支复制了 title，释放原始 clean_title
            allocator.free(clean_title);
        } else {
            // meta_pages 为空但不是 ugoira → 单图
            try parseSingleImage(allocator, id, clean_title, meta_single, &result);
        }
    } else {
        // === 单图 ===
        try parseSingleImage(allocator, id, clean_title, meta_single, &result);
        // parseSingleImage 复制了 title，需要释放原始 clean_title
        allocator.free(clean_title);
    }

    return result.toOwnedSlice(allocator);
}

/// 解析单张图片
fn parseSingleImage(allocator: std.mem.Allocator, id: i64, clean_title: []const u8, meta_single: ?std.json.ObjectMap, result: *std.ArrayListUnmanaged(Illust)) !void {
    const original_url: []const u8 = blk: {
        if (meta_single) |obj| {
            if (obj.get("original_image_url")) |val| {
                if (val == .string) break :blk val.string;
            }
        }
        break :blk "";
    };

    if (original_url.len == 0) return;

    const ext = extractExtension(original_url);
    const title_copy = try allocator.dupe(u8, clean_title);
    const url_copy = try allocator.dupe(u8, original_url);
    const file_name = try std.fmt.allocPrint(allocator, "({d}){s}{s}", .{ id, clean_title, ext });

    try result.append(allocator, .{
        .id = @intCast(id),
        .title = title_copy,
        .url = url_copy,
        .file = file_name,
        .illust_type = .single,
    });
}

/// 释放 parseIllusts 返回的数组中所有 Illust 的字符串字段和数组本身
pub fn deinitIllusts(allocator: std.mem.Allocator, illusts: []Illust) void {
    for (illusts) |item| item.deinit(allocator);
    allocator.free(illusts);
}

test "sanitizeTitle removes unsafe chars" {
    const result = try sanitizeTitle(std.testing.allocator, "Hello*World?.txt");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("HelloWorldtxt", result);
}

test "sanitizeTitle trims trailing spaces" {
    const result = try sanitizeTitle(std.testing.allocator, "hello   ");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "extractExtension returns correct extension" {
    try std.testing.expectEqualStrings(".jpg", extractExtension("https://example.com/image.jpg"));
    try std.testing.expectEqualStrings(".png", extractExtension("https://example.com/path/image.png"));
    try std.testing.expectEqualStrings(".jpg", extractExtension("no_ext"));
}

test "ugoiraZipUrl transforms URL correctly" {
    const url = try ugoiraZipUrl(std.testing.allocator, "https://i.pximg.net/img-original/img/2024/01/15/12/00/00/12345_ugoira0.jpg");
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "img-zip-ugoira") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "_ugoira1920x1080.zip") != null);
}

test "parseIllusts parses single image" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "id", .{ .integer = 12345 });
    try obj.put(std.testing.allocator, "title", .{ .string = "Test Image" });
    try obj.put(std.testing.allocator, "type", .{ .string = "illust" });

    var meta: std.json.ObjectMap = .empty;
    defer meta.deinit(std.testing.allocator);
    try meta.put(std.testing.allocator, "original_image_url", .{ .string = "https://i.pximg.net/img-original/img/test.jpg" });
    try obj.put(std.testing.allocator, "meta_single_page", .{ .object = meta });

    var empty_pages: std.json.Array = .init(std.testing.allocator);
    defer empty_pages.deinit();
    try obj.put(std.testing.allocator, "meta_pages", .{ .array = empty_pages });

    const illusts = try parseIllusts(std.testing.allocator, .{ .object = obj }, null);
    defer deinitIllusts(std.testing.allocator, illusts);

    try std.testing.expectEqual(@as(usize, 1), illusts.len);
    try std.testing.expectEqual(@as(u64, 12345), illusts[0].id);
    try std.testing.expectEqualStrings("Test Image", illusts[0].title);
    try std.testing.expectEqual(IllustType.single, illusts[0].illust_type);
    try std.testing.expect(std.mem.endsWith(u8, illusts[0].file, ".jpg"));
    try std.testing.expect(std.mem.startsWith(u8, illusts[0].file, "(12345)Test Image"));
}

test "parseIllusts parses multi-page image" {
    var obj: std.json.ObjectMap = .empty;
    defer obj.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "id", .{ .integer = 67890 });
    try obj.put(std.testing.allocator, "title", .{ .string = "Multi" });
    try obj.put(std.testing.allocator, "type", .{ .string = "manga" });

    // meta_single_page: empty
    var meta_single: std.json.ObjectMap = .empty;
    defer meta_single.deinit(std.testing.allocator);
    try obj.put(std.testing.allocator, "meta_single_page", .{ .object = meta_single });

    // meta_pages: 2 pages
    var page0_images: std.json.ObjectMap = .empty;
    defer page0_images.deinit(std.testing.allocator);
    try page0_images.put(std.testing.allocator, "original", .{ .string = "https://i.pximg.net/img/page0.png" });

    var page0: std.json.ObjectMap = .empty;
    defer page0.deinit(std.testing.allocator);
    try page0.put(std.testing.allocator, "image_urls", .{ .object = page0_images });

    var page1_images: std.json.ObjectMap = .empty;
    defer page1_images.deinit(std.testing.allocator);
    try page1_images.put(std.testing.allocator, "original", .{ .string = "https://i.pximg.net/img/page1.png" });

    var page1: std.json.ObjectMap = .empty;
    defer page1.deinit(std.testing.allocator);
    try page1.put(std.testing.allocator, "image_urls", .{ .object = page1_images });

    var pages: std.json.Array = .init(std.testing.allocator);
    defer pages.deinit();
    try pages.append(.{ .object = page0 });
    try pages.append(.{ .object = page1 });
    try obj.put(std.testing.allocator, "meta_pages", .{ .array = pages });

    const illusts = try parseIllusts(std.testing.allocator, .{ .object = obj }, null);
    defer deinitIllusts(std.testing.allocator, illusts);

    try std.testing.expectEqual(@as(usize, 2), illusts.len);
    try std.testing.expectEqual(IllustType.multi, illusts[0].illust_type);
    try std.testing.expect(std.mem.indexOf(u8, illusts[0].file, "_p0.png") != null);
    try std.testing.expect(std.mem.indexOf(u8, illusts[1].file, "_p1.png") != null);
}
