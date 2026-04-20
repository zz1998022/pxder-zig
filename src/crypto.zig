//! 加密工具模块
//! 提供 SHA-256、MD5 哈希、base64url 编码和密码学安全随机数生成。
//! 主要用于 Pixiv OAuth PKCE 认证流程和 API 请求签名。

const std = @import("std");

/// 计算数据的 SHA-256 哈希值
/// data: 输入数据
/// out: 32 字节输出缓冲区
pub fn sha256(data: []const u8, out: *[32]u8) void {
    std.crypto.hash.sha2.Sha256.hash(data, out, .{});
}

/// 计算数据的 MD5 哈希值
/// 用于构造 Pixiv API 请求头中的 X-Client-Hash 字段
/// 算法: MD5(ISO时间戳 + HASH_SECRET)
pub fn md5(data: []const u8, out: *[16]u8) void {
    std.crypto.hash.Md5.hash(data, out, .{});
}

/// 使用密码学安全随机数生成器填充缓冲区
/// 用于 PKCE code_verifier 的生成
pub fn randomBytes(io: std.Io, buf: []u8) void {
    io.random(buf);
}

const base64_url_charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Base64 URL 安全编码（带填充）
pub fn base64UrlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const out_len = (data.len + 2) / 3 * 4;
    const buf = try allocator.alloc(u8, out_len);
    _ = std.base64.url_safe_no_pad.encode(buf, data);
    return buf;
}

/// Base64 URL 安全编码（无填充）
/// PKCE 规范要求 base64url 编码不使用 = 填充
/// 32 字节随机数 → 43 字符的 code_verifier
pub fn base64UrlEncodeNoPadding(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const out_len = std.base64.url_safe_no_pad.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, out_len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(buf, data);
    return buf;
}

test "sha256 known vector" {
    var out: [32]u8 = undefined;
    sha256("hello", &out);
    const expected_hex = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    var expected: [32]u8 = undefined;
    for (0..32) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "md5 known vector" {
    var out: [16]u8 = undefined;
    md5("hello", &out);
    const expected_hex = "5d41402abc4b2a76b9719d911017c592";
    var expected: [16]u8 = undefined;
    for (0..16) |i| {
        expected[i] = std.fmt.parseInt(u8, expected_hex[i * 2 .. i * 2 + 2], 16) catch unreachable;
    }
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "base64url encode no padding" {
    const result = try base64UrlEncodeNoPadding(std.testing.allocator, "hello");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("aGVsbG8", result);
}

test "base64url encode 32 bytes" {
    var input: [32]u8 = undefined;
    @memset(&input, 0xAB);
    const result = try base64UrlEncodeNoPadding(std.testing.allocator, &input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 43), result.len);
}
