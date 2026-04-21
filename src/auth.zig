//! OAuth PKCE 认证模块
//! 实现 Pixiv 登录所需的 PKCE (Proof Key for Code Exchange) 流程。
//!
//! 流程:
//!   1. 生成 32 字节随机数 → base64url(无填充) → code_verifier (43 字符)
//!   2. SHA-256(code_verifier) → base64url → code_challenge (43 字符)
//!   3. 构造登录 URL 并在浏览器中打开
//!   4. 用户授权后获取 authorization code
//!   5. 用 code + code_verifier 交换 access_token 和 refresh_token

const std = @import("std");
const crypto = @import("shared/crypto.zig");

/// PKCE 参数，包含登录所需的所有数据
pub const PkceParams = struct {
    code_verifier: []const u8, // PKCE code verifier，43 字符 base64url
    code_challenge: []const u8, // PKCE code challenge，43 字符 base64url
    login_url: []const u8, // 完整的 Pixiv 登录 URL
};

/// 生成 PKCE 参数
/// 返回的三个字符串都需要调用者通过 deinitPkce 释放
pub fn generatePkce(allocator: std.mem.Allocator, io: std.Io) !PkceParams {
    // 步骤 1: 生成 32 字节密码学安全随机数
    var random_bytes: [32]u8 = undefined;
    crypto.randomBytes(io, &random_bytes);

    // 步骤 2: base64url 编码（无填充）得到 code_verifier
    const code_verifier = try crypto.base64UrlEncodeNoPadding(allocator, &random_bytes);

    // 步骤 3: SHA-256 哈希 code_verifier，再 base64url 编码得到 code_challenge
    var hash: [32]u8 = undefined;
    crypto.sha256(code_verifier, &hash);
    const code_challenge = try crypto.base64UrlEncodeNoPadding(allocator, &hash);

    // 步骤 4: 构造登录 URL
    const login_url = try std.fmt.allocPrint(allocator,
        "https://app-api.pixiv.net/web/v1/login?code_challenge={s}&code_challenge_method=S256&client=pixiv-android",
        .{code_challenge},
    );

    return .{
        .code_verifier = code_verifier,
        .code_challenge = code_challenge,
        .login_url = login_url,
    };
}

/// 释放 PkceParams 中分配的所有字符串
pub fn deinitPkce(allocator: std.mem.Allocator, pkce: PkceParams) void {
    allocator.free(pkce.code_verifier);
    allocator.free(pkce.code_challenge);
    allocator.free(pkce.login_url);
}

test "generatePkce produces valid output" {
    var io_threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_threaded.deinit();
    const pkce = try generatePkce(std.testing.allocator, io_threaded.io());
    defer deinitPkce(std.testing.allocator, pkce);
    // base64url(32字节) = 43 字符（无填充）
    try std.testing.expectEqual(@as(usize, 43), pkce.code_verifier.len);
    try std.testing.expectEqual(@as(usize, 43), pkce.code_challenge.len);
    try std.testing.expect(pkce.login_url.len > 0);
}
